;;; etaf-rss-miniflux.el --- Read a Miniflux server through etaf-rss -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A second backend for the reader: the same interface, model and views read a
;; self-hosted Miniflux instance instead of the local JSON store.  The server
;; owns subscriptions, articles and read state; this module translates the
;; reader's request protocol into the Miniflux REST API and shapes the replies
;; the reader already understands.
;;
;; The client is a plist (:call FUNCTION [:cancel FUNCTION]), which
;; `etaf-rss-client-call' accepts next to the local client, so no view or model
;; code knows which backend answered.  `etaf-rss-backend' selects it for
;; interactive sessions.
;;
;; A transport function can stand in for the HTTP transfer
;; (METHOD PATH QUERY BODY CALLBACK answering (:ok DATA) or (:error MESSAGE
;; :hint HINT)), which is how the acceptance suite exercises every operation
;; without a server.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'url-util)
(require 'json)
(require 'iso8601)
(require 'etaf-rss-parse)

(declare-function url-http-response-status "url-http" (&optional noerror))

(defcustom etaf-rss-miniflux-url nil
  "Base URL of the Miniflux instance.
When nil, `etaf-rss-miniflux-config-file' is consulted and then the
MINIFLUX_URL environment variable; the fallback is a server on the default
port of the local machine."
  :type '(choice (const :tag "From config file or environment" nil) string)
  :group 'etaf-rss)

(defcustom etaf-rss-miniflux-token nil
  "API token used to authenticate against Miniflux.
When nil, `etaf-rss-miniflux-config-file' is consulted and then the
MINIFLUX_TOKEN environment variable.  The token comes from the Miniflux web
interface under Settings > API Keys."
  :type '(choice (const :tag "From config file or environment" nil) string)
  :group 'etaf-rss)

(defcustom etaf-rss-miniflux-config-file
  (locate-user-emacs-file "etaf-miniflux.json")
  "JSON file with the instance URL and API token.
The file looks like {\"url\": \"http://127.0.0.1:8090\", \"token\": \"…\"};
explicit configuration and the environment take precedence over it.  The name
stays as it was when the Miniflux reader was its own package, so an existing
configuration keeps working."
  :type 'file
  :group 'etaf-rss)

(defcustom etaf-rss-miniflux-request-timeout 20
  "Seconds before one Miniflux request is abandoned.
The transfer is killed, so a hung tunnel cannot leave a load pending forever;
the caller sees a readable timeout error."
  :type 'number
  :group 'etaf-rss)

(defcustom etaf-rss-miniflux-list-limit 200
  "Most entries one scope loads from the server in one request.
The list shows what the server returned; a scope with more entries reports
the server's total separately."
  :type 'integer
  :group 'etaf-rss)

(defconst etaf-rss-miniflux--user-agent "etaf-rss-miniflux/0.1"
  "User-Agent header sent with every request.")

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defun etaf-rss-miniflux--config-value (key)
  "Return KEY from `etaf-rss-miniflux-config-file', or nil.
KEY is a string naming the field; a missing or unreadable file yields nil
instead of an error, because a session without configuration is still a
useful session with a readable failure."
  (when (and (stringp etaf-rss-miniflux-config-file)
             (file-readable-p etaf-rss-miniflux-config-file))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents etaf-rss-miniflux-config-file)
        (goto-char (point-min))
        (let ((data (json-parse-buffer :false-object nil :null-object nil)))
          (and (hash-table-p data) (gethash key data)))))))

(defun etaf-rss-miniflux--resolve (value custom environment default)
  "Return VALUE, then CUSTOM, the config file entry named ENVIRONMENT,
the ENVIRONMENT variable, then DEFAULT."
  (or (and (stringp value) (not (string-empty-p value)) value)
      (etaf-rss-miniflux--config-value environment)
      custom
      (let ((env (getenv environment)))
        (and (stringp env) (not (string-empty-p env)) env))
      default))

(defun etaf-rss-miniflux--resolve-url (url)
  "Return the Miniflux base URL: URL, config file, environment, then default."
  (let ((resolved (etaf-rss-miniflux--resolve
                   url etaf-rss-miniflux-url "url" "http://127.0.0.1:8090")))
    (string-trim resolved "/")))

(defun etaf-rss-miniflux--resolve-token (token)
  "Return the Miniflux API token: TOKEN, config file, then environment."
  (etaf-rss-miniflux--resolve token etaf-rss-miniflux-token "token" nil))

;;; ---------------------------------------------------------------------------
;;; Transport
;;; ---------------------------------------------------------------------------

(defun etaf-rss-miniflux--body-start ()
  "Return the position where the response body begins in the current buffer."
  (goto-char (point-min))
  (if (re-search-forward "^$" nil t)
      (1+ (point))
    (point-max)))

(defun etaf-rss-miniflux--response-code ()
  "Return the HTTP status of the response in the current buffer, or 0.
The status line is read from the response itself: `url-http-response-status'
is gone from Emacs 31, and every supported version starts a response buffer
with the HTTP version and its code."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "\\`HTTP/[0-9.]+\\(?: +\\|\\)\\([0-9]\\{3\\}\\)" nil t)
        (string-to-number (match-string 1))
      0)))

(cl-defun etaf-rss-miniflux--http (state method path &key query body callback)
  "Send METHOD PATH for the server described by STATE.
QUERY is an alist of parameters, BODY a JSON string and CALLBACK receives
(:ok DATA) with the decoded object or (:error MESSAGE :hint HINT).  STATE
carries the URL, the token, the deadline and the pending transfers, and may
carry a `:transport' function instead of the real transfer."
  (let* ((url (concat (plist-get state :url) path
                      (when query
                        (concat "?" (url-build-query-string query)))))
         (transport (plist-get state :transport))
         (headers (append (list (cons "Accept" "application/json")
                                (cons "User-Agent" etaf-rss-miniflux--user-agent))
                          (when (plist-get state :token)
                            (list (cons "X-Auth-Token" (plist-get state :token))))
                          (when body
                            (list (cons "Content-Type" "application/json"))))))
    (if transport
        (funcall transport method path query body callback)
      (etaf-rss-miniflux--transfer state url method headers body callback))))

(defun etaf-rss-miniflux--finish (job result)
  "Deliver RESULT to JOB's callback exactly once and cancel its timer."
  (unless (plist-get job :done)
    (setf (plist-get job :done) t)
    (when-let* ((timer (plist-get job :timer)))
      (when (timerp timer) (cancel-timer timer))
      (setf (plist-get job :timer) nil))
    (ignore-errors (funcall (plist-get job :callback) result))))

(defun etaf-rss-miniflux--settle (job status)
  "Read the finished transfer JOB from the current buffer and answer it.
STATUS is the `url-retrieve' status plist."
  (let ((state (plist-get job :state))
        (url (plist-get job :url))
        (buffer (current-buffer)))
    (unwind-protect
        (cond
         ((plist-get status :error)
          (let ((error (plist-get status :error)))
            (etaf-rss-miniflux--finish
             job
             (list :error (format "无法连接 Miniflux：%s"
                                  (if (consp error) (cdr error) error))
                   :hint (format "服务地址 %s：确认服务在跑"
                                 (plist-get state :url))))))
         ((zerop (etaf-rss-miniflux--response-code))
          (etaf-rss-miniflux--finish
           job (list :error "Miniflux 没有返回状态码" :hint url)))
         (t (etaf-rss-miniflux--finish
             job (etaf-rss-miniflux--parse-response url))))
      (when (buffer-live-p buffer)
        (setf (plist-get state :pending)
              (delq buffer (plist-get state :pending)))
        (kill-buffer buffer)))))

(defun etaf-rss-miniflux--transfer (state url method headers body callback)
  "Transfer URL for STATE with METHOD, HEADERS and BODY, answering CALLBACK.
The job is cancelled after the deadline, and STATE tracks the live buffers so
closing the reader abandons them."
  (let* ((job (list :done nil :timer nil :callback callback
                    :state state :url url))
         (timeout (plist-get state :timeout))
         (buffer nil))
    (condition-case error
        (setq buffer
              (let ((url-request-method method)
                    (url-request-extra-headers headers)
                    (url-request-data body))
                (url-retrieve
                 url (lambda (status) (etaf-rss-miniflux--settle job status)) nil t)))
      (error (etaf-rss-miniflux--finish
              job (list :error (error-message-string error) :hint url))))
    (when buffer
      (setf (plist-get state :pending) (cons buffer (plist-get state :pending)))
      (when (and timeout (> timeout 0))
        (setf (plist-get job :timer)
              (run-at-time
               timeout nil
               (lambda ()
                 (when-let* ((retrieval (plist-get job :buffer)))
                   (ignore-errors (delete-process (get-buffer-process retrieval))))
                 (etaf-rss-miniflux--finish
                  job (list :error
                            (format "Miniflux 请求超时（%s 秒）" timeout)
                            :hint url)))))))
    nil))

(defun etaf-rss-miniflux--parse-response (url)
  "Return the reply (:ok DATA) or an error for the response in this buffer.
URL names the request for the hint."
  (let ((code (etaf-rss-miniflux--response-code))
        (data nil)
        (parse-error nil))
    (goto-char (etaf-rss-miniflux--body-start))
    (when (< (point) (point-max))
      (condition-case error
          (let ((text (decode-coding-string
                       (buffer-substring-no-properties (point) (point-max))
                       'utf-8)))
            (unless (string-empty-p (string-trim text))
              (setq data (json-parse-string text :false-object nil :null-object nil))))
        (error (setq parse-error (error-message-string error)))))
    (cond
     (parse-error (list :error "无法解析 Miniflux 的响应" :hint parse-error))
     ((<= 200 code 299) (list :ok data))
     ((memq code '(401 403))
      (list :error "Miniflux 拒绝了这次请求（密钥无效或权限不足）"
            :hint (format "检查 API 密钥；HTTP %d" code)))
     (t (list :error (format "Miniflux 返回 HTTP %d" code)
              :hint (if (and (hash-table-p data)
                             (gethash "error_message" data))
                        (gethash "error_message" data)
                      url))))))

(defun etaf-rss-miniflux--cancel (state)
  "Abandon every in-flight request of STATE; the client stays reusable."
  (dolist (buffer (plist-get state :pending))
    (when (buffer-live-p buffer)
      (when-let* ((process (get-buffer-process buffer)))
        (delete-process process))
      (kill-buffer buffer)))
  (setf (plist-get state :pending) nil))

;;; ---------------------------------------------------------------------------
;;; Wire values
;;; ---------------------------------------------------------------------------

(defun etaf-rss-miniflux--get (table key)
  "Return KEY from JSON TABLE (a hash table), or nil."
  (and (hash-table-p table) (gethash key table)))

(defun etaf-rss-miniflux--true (value)
  "Return non-nil when VALUE is truthy on the wire (JSON true).
A JSON parser may keep false as `:false', which is truthy in Lisp, so every
boolean read goes through this helper."
  (and value (not (eq value :false)) t))

(defun etaf-rss-miniflux--time (value)
  "Return VALUE, an ISO-8601 timestamp, as a float time, or nil."
  (when (and (stringp value) (not (string-empty-p value)))
    (or (ignore-errors (float-time (date-to-time (string-trim value))))
        (ignore-errors (float-time (encode-time (iso8601-parse (string-trim value)))))
        (etaf-rss-parse-time value))))

(defun etaf-rss-miniflux--folder (category)
  "Return CATEGORY's title, or an empty string for the root category."
  (or (etaf-rss-miniflux--get category "title") ""))

(defun etaf-rss-miniflux--feed (wire unread)
  "Return Miniflux FEED as the reader's sidebar plist.
UNREAD is its unread count, from the server's counters."
  (let ((category (etaf-rss-miniflux--get wire "category")))
    (list :id (etaf-rss-miniflux--get wire "id")
          :title (or (etaf-rss-miniflux--get wire "title") "")
          :url (or (etaf-rss-miniflux--get wire "feed_url") "")
          :site (or (etaf-rss-miniflux--get wire "site_url") "")
          :folder (etaf-rss-miniflux--folder category)
          :unread (or unread 0)
          :total (+ (or unread 0) 0))))

(defun etaf-rss-miniflux--row (entry)
  "Return Miniflux ENTRY as the reader's article row.
The reader reads `:id', `:feed', `:feed-title', `:title', `:url', `:author',
`:published', `:added', `:summary', `:content', `:read' and `:starred'."
  (let* ((feed (etaf-rss-miniflux--get entry "feed"))
         (published (etaf-rss-miniflux--time
                     (etaf-rss-miniflux--get entry "published_at"))))
    (list :id (etaf-rss-miniflux--get entry "id")
          :feed (etaf-rss-miniflux--get feed "id")
          :feed-title (or (etaf-rss-miniflux--get feed "title") "")
          :title (or (etaf-rss-miniflux--get entry "title") "")
          :url (or (etaf-rss-miniflux--get entry "url") "")
          :author (or (etaf-rss-miniflux--get entry "author") "")
          :published published
          :added published
          :summary (or (etaf-rss-miniflux--get entry "summary") "")
          :content (or (etaf-rss-miniflux--get entry "content") "")
          :read (equal "read" (etaf-rss-miniflux--get entry "status"))
          :starred (etaf-rss-miniflux--true (etaf-rss-miniflux--get entry "starred")))))

(defun etaf-rss-miniflux--sidebar (feeds counters starred)
  "Return the sidebar reply built from the server's replies.
FEEDS is the API list, COUNTERS the per-feed unread counts and STARRED the
total of the starred scope."
  (let ((unreads (or (etaf-rss-miniflux--get counters "unreads")
                     (make-hash-table :test 'equal)))
        (members nil)
        (total 0))
    (dolist (wire (append feeds nil))
      (let* ((id (format "%s" (etaf-rss-miniflux--get wire "id")))
             (unread (or (gethash id unreads) 0)))
        (setq total (+ total unread))
        (push (etaf-rss-miniflux--feed wire unread) members)))
    (list :feeds (vconcat (nreverse members))
          :total total
          :unread total
          :starred (or starred 0)
          ;; The server owns the appearance preference, so the reader keeps
          ;; its own; a snapshot without a theme leaves the current one.
          :theme nil)))

(defun etaf-rss-miniflux--scope-query (scope &optional limit)
  "Return the entries query parameters for SCOPE with LIMIT.
The category of a folder scope is resolved by the caller."
  (let ((status '(("status" "read") ("status" "unread"))))
    (append
     (pcase (plist-get scope :kind)
       (:unread '(("status" "unread")))
       (:starred '(("starred" "true")))
       (:feed (append status (list (list "feed_id"
                                         (format "%s" (plist-get scope :id))))))
       (:search (append status (list (list "search"
                                           (or (plist-get scope :query) "")))))
       (_ status))
     (list (list "order" "published_at")
           (list "direction" "desc")
           (list "limit" (format "%d" (or limit etaf-rss-miniflux-list-limit)))))))

;;; ---------------------------------------------------------------------------
;;; Requests
;;; ---------------------------------------------------------------------------

(defun etaf-rss-miniflux--all (state requests callback)
  "Send REQUESTS together and deliver every reply to CALLBACK as one list.
Each REQUEST is (KEY METHOD PATH &optional QUERY BODY); the reply is
(:ok ((KEY . DATA) …)) or the first failure."
  (let ((remaining (length requests))
        (results nil)
        (failure nil))
    (if (= remaining 0)
        (funcall callback (list :ok nil))
      (dolist (request requests)
        (pcase-let ((`(,key ,method ,path ,query ,body) request))
          (etaf-rss-miniflux--http
           state method path :query query :body body
           :callback
           (lambda (reply)
             (cond ((not (eq (car reply) :ok))
                    (unless failure (setq failure reply)))
                   ((not failure) (push (cons key (cadr reply)) results)))
             (cl-decf remaining)
             (when (<= remaining 0)
               (funcall callback (or failure (list :ok results)))))))))))

(defun etaf-rss-miniflux--load-sidebar (state callback)
  "Load STATE's categories, feeds, counters and starred total for CALLBACK."
  (etaf-rss-miniflux--all
   state
   (list (list :categories "GET" "/v1/categories")
         (list :feeds "GET" "/v1/feeds")
         (list :counters "GET" "/v1/feeds/counters")
         (list :starred "GET" "/v1/entries"
               '(("starred" "true") ("limit" "1"))))
   (lambda (reply)
     (if (not (eq (car reply) :ok))
         (funcall callback reply)
       (let* ((data (cadr reply))
              (starred (etaf-rss-miniflux--get (alist-get :starred data) "total")))
         (funcall callback
                  (list :ok (etaf-rss-miniflux--sidebar
                             (alist-get :feeds data)
                             (alist-get :counters data)
                             (or starred 0)))))))))

(defun etaf-rss-miniflux--with-sidebar (state reply callback)
  "Append the current sidebar to REPLY's data and deliver it to CALLBACK.\nREPLY is the (:ok DATA) of a mutation; a failed sidebar load keeps the\nmutation itself reported as the failure that matters."
  (if (not (eq (car reply) :ok))
      (funcall callback reply)
    (etaf-rss-miniflux--load-sidebar
     state
     (lambda (sidebar)
       (if (not (eq (car sidebar) :ok))
           (funcall callback sidebar)
         (funcall callback
                  (list :ok (append (cadr reply) (cadr sidebar)))))))))

(defun etaf-rss-miniflux--categories (state callback)
  "Deliver STATE's categories to CALLBACK as (:ok HASH-TABLE-BY-TITLE)."
  (etaf-rss-miniflux--http
   state "GET" "/v1/categories"
   :callback
   (lambda (reply)
     (if (not (eq (car reply) :ok))
         (funcall callback reply)
       (let ((table (make-hash-table :test 'equal)))
         (dolist (category (append (cadr reply) nil))
           (puthash (etaf-rss-miniflux--folder category)
                    (etaf-rss-miniflux--get category "id") table))
         (funcall callback (list :ok table)))))))

(defun etaf-rss-miniflux--category-id (state name callback)
  "Deliver the id of the category NAME, creating it when CALLBACK-CREATE.\nNAME is a folder title; an empty NAME means the root category (id 0)."
  (if (string-empty-p (or name ""))
      (funcall callback (list :ok 0))
    (etaf-rss-miniflux--categories
     state
     (lambda (reply)
       (if (not (eq (car reply) :ok))
           (funcall callback reply)
         (let ((known (gethash name (cadr reply))))
           (if known
               (funcall callback (list :ok known))
             (etaf-rss-miniflux--http
              state "POST" "/v1/categories"
              :body (json-encode (list :title name))
              :callback
              (lambda (created)
                (if (not (eq (car created) :ok))
                    (funcall callback created)
                  (funcall callback
                           (list :ok (etaf-rss-miniflux--get (cadr created) "id")))))))))))))

(defun etaf-rss-miniflux--articles (state request callback)
  "Load REQUEST's scope for STATE and deliver its rows."
  (let ((scope (plist-get request :scope)))
    (if (eq (plist-get scope :kind) :folder)
        (etaf-rss-miniflux--category-id
         state (plist-get scope :name)
         (lambda (reply)
           (if (not (eq (car reply) :ok))
               (funcall callback reply)
             (etaf-rss-miniflux--entries
              state (append (etaf-rss-miniflux--scope-query scope)
                            (list (list "category_id"
                                        (format "%s" (cadr reply)))))
              callback))))
      (etaf-rss-miniflux--entries
       state (etaf-rss-miniflux--scope-query scope) callback))))

(defun etaf-rss-miniflux--entries (state query callback)
  "Load STATE's entries matching QUERY and deliver (:ok (:rows VECTOR :total N))."
  (etaf-rss-miniflux--http
   state "GET" "/v1/entries" :query query
   :callback
   (lambda (reply)
     (if (not (eq (car reply) :ok))
         (funcall callback reply)
       (let ((data (cadr reply)))
         (funcall callback
                  (list :ok (list :total (or (etaf-rss-miniflux--get data "total") 0)
                                  :rows (vconcat
                                         (mapcar #'etaf-rss-miniflux--row
                                                 (append (etaf-rss-miniflux--get
                                                          data "entries")
                                                         nil)))))))))))

(defun etaf-rss-miniflux--article (state request callback)
  "Load REQUEST's article from STATE and deliver the row with its HTML."
  (etaf-rss-miniflux--http
   state "GET" (format "/v1/entries/%s" (plist-get request :id))
   :callback
   (lambda (reply)
     (if (not (eq (car reply) :ok))
         (funcall callback reply)
       (funcall callback (list :ok (etaf-rss-miniflux--row (cadr reply))))))))

(defun etaf-rss-miniflux--set-read (state request callback)
  "Mark REQUEST's entries read or unread on STATE."
  (etaf-rss-miniflux--http
   state "PUT" "/v1/entries"
   :body (json-encode (list :entry_ids (vconcat (plist-get request :ids))
                            :status (if (plist-get request :read) "read" "unread")))
   :callback
   (lambda (reply)
     (etaf-rss-miniflux--with-sidebar
      state (if (eq (car reply) :ok) (list :ok nil) reply) callback))))

(defun etaf-rss-miniflux--mark-all-read (state request callback)
  "Mark REQUEST's scope read on STATE, reporting the ids that changed."
  (let ((scope (plist-get request :scope)))
    (if (eq (plist-get scope :kind) :starred)
        (funcall callback (list :error "收藏范围不支持全部已读"
                                :hint "在服务器上逐条标记"))
      (etaf-rss-miniflux--entries
       state (etaf-rss-miniflux--scope-query scope)
       (lambda (loaded)
         (if (not (eq (car loaded) :ok))
             (funcall callback loaded)
           (let ((ids (mapcar (lambda (row) (plist-get row :id))
                              (append (plist-get (cadr loaded) :rows) nil))))
             (etaf-rss-miniflux--mark-all-read-call
              state scope
              (lambda (reply)
                (etaf-rss-miniflux--with-sidebar
                 state
                 (if (eq (car reply) :ok) (list :ok (list :ids ids)) reply)
                 callback))))))))))

(defun etaf-rss-miniflux--mark-all-read-call (state scope callback)
  "Ask STATE to mark SCOPE read and deliver the server's reply to CALLBACK."
  (pcase (plist-get scope :kind)
    (:feed
     (etaf-rss-miniflux--http
      state "PUT" (format "/v1/feeds/%s/mark-all-as-read" (plist-get scope :id))
      :callback callback))
    (:folder
     (etaf-rss-miniflux--category-id
      state (plist-get scope :name)
      (lambda (reply)
        (if (not (eq (car reply) :ok))
            (funcall callback reply)
          (etaf-rss-miniflux--http
           state "PUT"
           (format "/v1/categories/%s/mark-all-as-read" (cadr reply))
           :callback callback)))))
    ((or :all :unread) (etaf-rss-miniflux--mark-all-as-read-user state callback))
    (_ (funcall callback (list :error "这个范围不支持全部已读"
                               :hint "收藏范围请逐条标记")))))

(defun etaf-rss-miniflux--user-id (state callback)
  "Deliver STATE's user id to CALLBACK, loading it once when unknown."
  (if (plist-get state :user-id)
      (funcall callback (list :ok (plist-get state :user-id)))
    (etaf-rss-miniflux--http
     state "GET" "/v1/me"
     :callback
     (lambda (reply)
       (if (eq (car reply) :ok)
           (let ((id (etaf-rss-miniflux--get (cadr reply) "id")))
             (setf (plist-get state :user-id) id)
             (funcall callback (list :ok id)))
         (funcall callback reply))))))

(defun etaf-rss-miniflux--mark-all-as-read-user (state callback)
  "Mark every entry of STATE read through the user endpoint."
  (etaf-rss-miniflux--user-id
   state
   (lambda (reply)
     (if (not (eq (car reply) :ok))
         (funcall callback reply)
       (etaf-rss-miniflux--http
        state "PUT" (format "/v1/users/%s/mark-all-as-read" (cadr reply))
        :callback callback)))))

(defun etaf-rss-miniflux--star (state request callback)
  "Star or unstar REQUEST's entry on STATE."
  (etaf-rss-miniflux--http
   state "PUT" (format "/v1/entries/%s/bookmark" (plist-get request :id))
   :body (json-encode (list :bookmark (if (plist-get request :starred) t :false)))
   :callback
   (lambda (reply)
     (etaf-rss-miniflux--with-sidebar
      state (if (eq (car reply) :ok) (list :ok nil) reply) callback))))

(defun etaf-rss-miniflux--refresh (state request callback)
  "Ask STATE to fetch REQUEST's feed, or every feed when it names none."
  (etaf-rss-miniflux--http
   state "PUT"
   (if (plist-get request :id)
       (format "/v1/feeds/%s/refresh" (plist-get request :id))
     "/v1/feeds/refresh")
   :callback
   (lambda (reply)
     (etaf-rss-miniflux--with-sidebar
      state (if (eq (car reply) :ok) (list :ok (list :new 0)) reply) callback))))

(defun etaf-rss-miniflux--add-feed (state request callback)
  "Subscribe REQUEST's URL on STATE under its folder."
  (etaf-rss-miniflux--category-id
   state (or (plist-get request :folder) "")
   (lambda (category)
     (if (not (eq (car category) :ok))
         (funcall callback category)
       (etaf-rss-miniflux--http
        state "POST" "/v1/feeds"
        :body (json-encode (list :feed_url (plist-get request :url)
                                 :category_id (cadr category)))
        :callback
        (lambda (reply)
          (if (not (eq (car reply) :ok))
              (funcall callback reply)
            (let ((feed (etaf-rss-miniflux--get (cadr reply) "feed")))
              (etaf-rss-miniflux--with-sidebar
               state
               (list :ok (list :feed (etaf-rss-miniflux--feed feed 0)
                               :new 0))
               callback)))))))))

(defun etaf-rss-miniflux--remove-feed (state request callback)
  "Unsubscribe REQUEST's feed from STATE."
  (etaf-rss-miniflux--http
   state "DELETE" (format "/v1/feeds/%s" (plist-get request :id))
   :callback
   (lambda (reply)
     (etaf-rss-miniflux--with-sidebar
      state (if (eq (car reply) :ok) (list :ok nil) reply) callback))))

(defun etaf-rss-miniflux--move-feed (state request callback)
  "File REQUEST's feed under its folder on STATE."
  (etaf-rss-miniflux--category-id
   state (or (plist-get request :folder) "")
   (lambda (category)
     (if (not (eq (car category) :ok))
         (funcall callback category)
       (etaf-rss-miniflux--http
        state "PUT" (format "/v1/feeds/%s" (plist-get request :id))
        :body (json-encode (list :category_id (cadr category)))
        :callback
        (lambda (reply)
          (etaf-rss-miniflux--with-sidebar
           state (if (eq (car reply) :ok) (list :ok nil) reply) callback)))))))

(defun etaf-rss-miniflux--opml-import (state request callback)
  "Subscribe the feeds of REQUEST's OPML file on STATE.
Each created feed reports through the server; a feed that fails is counted as
skipped, so one bad subscription does not abandon the rest."
  (let* ((path (plist-get request :path))
         (text (condition-case error
                   (with-temp-buffer
                     (insert-file-contents path)
                     (buffer-string))
                 (error (funcall callback
                                 (list :error (format "无法读取 OPML：%s"
                                                      (error-message-string error))
                                       :hint path))
                        nil))))
    (when text
      (let ((entries (ignore-errors (etaf-rss-parse-opml text)))
            (added 0)
            (skipped 0))
        (if (not entries)
            (funcall callback (list :error "不是有效的 OPML 文件" :hint path))
          (cl-labels
              ((create (rest)
                 (if (null rest)
                     (etaf-rss-miniflux--with-sidebar
                      state (list :ok (list :added added :skipped skipped)) callback)
                   (pcase-let ((`(_ ,url ,folder) (car rest)))
                     (etaf-rss-miniflux--category-id
                      state (or folder "")
                      (lambda (category)
                        (if (not (eq (car category) :ok))
                            (cl-incf skipped)
                          (etaf-rss-miniflux--http
                           state "POST" "/v1/feeds"
                           :body (json-encode (list :feed_url url
                                                    :category_id (cadr category)))
                           :callback
                           (lambda (reply)
                             (if (eq (car reply) :ok)
                                 (cl-incf added)
                               (cl-incf skipped))
                             (create (cdr rest)))))))))))
            (create entries)))))))

(defun etaf-rss-miniflux--xml-escape (value)
  "Return VALUE with XML metacharacters escaped."
  (let ((text (or value "")))
    (setq text (string-replace "&" "&amp;" text))
    (setq text (string-replace "<" "&lt;" text))
    (setq text (string-replace ">" "&gt;" text))
    (setq text (string-replace "\"" "&quot;" text))
    text))

(defun etaf-rss-miniflux--opml-export (state request callback)
  "Write STATE's subscriptions to REQUEST's OPML file."
  (etaf-rss-miniflux--load-sidebar
   state
   (lambda (reply)
     (if (not (eq (car reply) :ok))
         (funcall callback reply)
       (let* ((path (expand-file-name (plist-get request :path)))
              (feeds (append (plist-get (cadr reply) :feeds) nil))
              (folders nil))
         (dolist (feed feeds)
           (let ((folder (or (plist-get feed :folder) "")))
             (unless (member folder folders) (push folder folders))))
         (setq folders (sort folders #'string-lessp))
         (condition-case error
             (let ((coding-system-for-write 'utf-8))
               (with-temp-file path
                 (insert "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                         "<opml version=\"2.0\">\n  <head>\n"
                         "    <title>etaf-rss 订阅</title>\n  </head>\n  <body>\n")
                 (dolist (folder folders)
                   (let ((members (seq-filter
                                   (lambda (feed)
                                     (equal (or (plist-get feed :folder) "") folder))
                                   feeds)))
                     (when (and (not (string-empty-p folder)) members)
                       (insert (format "    <outline text=\"%s\" title=\"%s\">\n"
                                       (etaf-rss-miniflux--xml-escape folder)
                                       (etaf-rss-miniflux--xml-escape folder))))
                     (dolist (feed members)
                       (insert (format "      <outline type=\"rss\" text=\"%s\" title=\"%s\" xmlUrl=\"%s\"%s/>\n"
                                       (etaf-rss-miniflux--xml-escape
                                        (plist-get feed :title))
                                       (etaf-rss-miniflux--xml-escape
                                        (plist-get feed :title))
                                       (etaf-rss-miniflux--xml-escape
                                        (plist-get feed :url))
                                       (if (string-empty-p (or (plist-get feed :site) ""))
                                           ""
                                         (format " htmlUrl=\"%s\""
                                                 (etaf-rss-miniflux--xml-escape
                                                  (plist-get feed :site)))))))
                     (when (and (not (string-empty-p folder)) members)
                       (insert "    </outline>\n"))))
                 (insert "  </body>\n</opml>\n"))
               (funcall callback (list :ok (list :path path :count (length feeds)))))
           (error
            (funcall callback
                     (list :error (format "无法写入 OPML：%s"
                                          (error-message-string error))
                           :hint path)))))))))

(defun etaf-rss-miniflux--dispatch (state request callback)
  "Answer REQUEST for STATE and deliver the result through CALLBACK."
  (pcase (plist-get request :op)
    ((or :snapshot :feeds) (etaf-rss-miniflux--load-sidebar state callback))
    (:articles (etaf-rss-miniflux--articles state request callback))
    (:article (etaf-rss-miniflux--article state request callback))
    (:mark-read (etaf-rss-miniflux--set-read state request callback))
    (:mark-read-scope (etaf-rss-miniflux--mark-all-read state request callback))
    (:star (etaf-rss-miniflux--star state request callback))
    (:refresh (etaf-rss-miniflux--refresh state request callback))
    (:add-feed (etaf-rss-miniflux--add-feed state request callback))
    (:remove-feed (etaf-rss-miniflux--remove-feed state request callback))
    (:move-feed (etaf-rss-miniflux--move-feed state request callback))
    (:opml-import (etaf-rss-miniflux--opml-import state request callback))
    (:opml-export (etaf-rss-miniflux--opml-export state request callback))
    ;; The server owns subscriptions and read state, so the appearance is the
    ;; only preference the reader keeps locally and there is nothing to flush.
    (:set-theme (funcall callback (list :ok nil)))
    (:flush (funcall callback (list :ok nil)))
    (_ (funcall callback (list :error (format "未知操作：%S" (plist-get request :op))
                               :hint "检查 service 层的 :op")))))

;;; ---------------------------------------------------------------------------
;;; Clients
;;; ---------------------------------------------------------------------------

(cl-defun etaf-rss-miniflux-client (&key url token timeout transport)
  "Return a client that reads the Miniflux server at URL.
URL, TOKEN and TIMEOUT default to `etaf-rss-miniflux-url',
`etaf-rss-miniflux-token' and `etaf-rss-miniflux-request-timeout', each with
its config-file and environment fallbacks.  TRANSPORT, a function of
(METHOD PATH QUERY BODY CALLBACK), replaces the HTTP transfer and is how a
test or a script drives the backend without a server.

The client is a plist `(:call FUNCTION [:cancel FUNCTION])', which
`etaf-rss-client-call' accepts beside the local client; pass it to
`etaf-rss-create :client' or bind `etaf-rss-backend' to `miniflux'."
  (let* ((state (list :url (etaf-rss-miniflux--resolve-url url)
                      :token (etaf-rss-miniflux--resolve-token token)
                      :timeout (or timeout etaf-rss-miniflux-request-timeout)
                      :transport transport
                      :user-id nil
                      :pending nil)))
    (list :call (lambda (request callback)
                  (etaf-rss-miniflux--dispatch state request callback))
          :cancel (lambda () (etaf-rss-miniflux--cancel state))
          :url (plist-get state :url))))

(provide 'etaf-rss-miniflux)
;;; etaf-rss-miniflux.el ends here
