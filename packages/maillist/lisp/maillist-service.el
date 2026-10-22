;;; maillist-service.el --- Mailing-list archives backend for maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; One source is a public-inbox archive: an index page listing threads and a
;; per-thread Atom document carrying every message.  Any archive that serves
;; those endpoints works unchanged; a new list is a new source plist, not new
;; code.  A source is (:name NAME :base URL :address LIST-ADDRESS).
;;
;; Every request is asynchronous: CALLBACK receives (:ok VALUE) on success and
;; (:error MESSAGE) otherwise.  Parsing is pure and testable from a string, so
;; the network is never needed to verify the mapping.
;;
;; A parsed thread row is (:id :subject :date :count :depth); `:date' is an
;; ISO-8601 UTC stamp so it sorts and caches as text.  A parsed thread is
;; (:id :subject :messages :participants), each message
;; (:id :author :email :date :depth :subject :text) where `:text' is the raw
;; body.  `maillist-classify-lines' turns a body into display lines.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'xml)
(require 'mail-parse)
(require 'rfc2047)

(defgroup maillist nil
  "Mailing-list archive client."
  :group 'applications)

(defcustom maillist-sources
  '((:name "emacs-devel"
     :base "https://yhetil.org/emacs-devel/"
     :address "emacs-devel@gnu.org")
    (:name "emacs-user"
     :base "https://yhetil.org/emacs-user/"
     :address "help-gnu-emacs@gnu.org")
    (:name "emacs-bugs"
     :base "https://yhetil.org/emacs-bugs/"
     :address "bug-gnu-emacs@gnu.org")
    (:name "emacs-tangents"
     :base "https://yhetil.org/emacs-tangents/"
     :address "emacs-tangents@gnu.org"))
  "Archives this client can open.
A source is (:name NAME :base URL :address LIST-ADDRESS); optional `:index'
names a file the archive serves instead of its directory URL, which a local
mirror needs."
  :type '(repeat (plist :key-type symbol :value-type string))
  :group 'maillist)

(defconst maillist-default-source (car maillist-sources)
  "Archive opened by a new client.")

(defun maillist-source (name)
  "Return the source description named NAME.
NAME defaults to the first known archive; an unknown name is an error."
  (or (cl-find (or name (plist-get maillist-default-source :name))
               maillist-sources
               :key (lambda (source) (plist-get source :name))
               :test #'equal)
      (user-error "未知邮件列表：%s" name)))

;;; ---------------------------------------------------------------------------
;;; Dates
;;; ---------------------------------------------------------------------------

(defun maillist--time-value (stamp)
  "Return STAMP parsed as a time value, or nil when it is not a timestamp."
  (when (stringp stamp)
    (ignore-errors (date-to-time stamp))))

(defun maillist-time-label (stamp)
  "Return the list label of STAMP: a clock today, a date before that."
  (if-let* ((time (maillist--time-value stamp)))
      (cond
       ((equal (format-time-string "%Y-%m-%d" time)
               (format-time-string "%Y-%m-%d"))
        (format-time-string "%H:%M" time))
       ((equal (format-time-string "%Y-%m-%d" time)
               (format-time-string "%Y-%m-%d" (time-subtract nil 86400)))
        "昨天")
       (t (format-time-string "%m-%d" time)))
    ""))

(defun maillist-day-label (stamp)
  "Return the group label of STAMP: today, yesterday, this week or older."
  (if-let* ((time (maillist--time-value stamp)))
      (cond
       ((equal (format-time-string "%Y-%m-%d" time)
               (format-time-string "%Y-%m-%d"))
        "今天")
       ((equal (format-time-string "%Y-%m-%d" time)
               (format-time-string "%Y-%m-%d" (time-subtract nil 86400)))
        "昨天")
       ((time-less-p (time-subtract nil (* 7 86400)) time)
        "本周")
       (t "更早"))
    "更早"))

(defun maillist-long-label (stamp)
  "Return STAMP as a readable date for the reader header."
  (if-let* ((time (maillist--time-value stamp)))
      (format-time-string "%Y-%m-%d %H:%M" time)
    ""))

;;; ---------------------------------------------------------------------------
;;; Thread index
;;; ---------------------------------------------------------------------------

(defun maillist-decode-entities (text)
  "Return TEXT with the HTML entities a public-inbox page emits."
  (let ((text (or text "")))
    (setq text (replace-regexp-in-string "&#34;" "\"" text t t))
    (setq text (replace-regexp-in-string "&#39;" "'" text t t))
    (setq text (replace-regexp-in-string "&quot;" "\"" text t t))
    (setq text (replace-regexp-in-string "&lt;" "<" text t t))
    (setq text (replace-regexp-in-string "&gt;" ">" text t t))
    (replace-regexp-in-string "&amp;" "&" text t t)))

(defconst maillist--index-link
  "<a[ \t\r\n]+href=\"\\([^\"]+\\)/T/#[tu]\"\\(?:[^>]*\\)>"
  "Start of one thread entry in a public-inbox index page.")

(defun maillist--index-count (text)
  "Return the message count reported in TEXT, or nil."
  (when (string-match "\\([0-9]+\\)\\(?:\\+\\)? message" text)
    (string-to-number (match-string 1 text))))

(defun maillist--index-stamp (text)
  "Return the ISO-8601 UTC timestamp reported in TEXT, or nil."
  (when (string-match (concat "\\([0-9]\\{4\\}\\)-\\([0-9][0-9]\\)-\\([0-9][0-9]\\)"
                              "[ ]+\\([0-9][0-9]?\\):\\([0-9][0-9]\\)")
                      text)
    (format "%s-%s-%sT%02d:%s:00Z"
            (match-string 1 text) (match-string 2 text) (match-string 3 text)
            (string-to-number (match-string 4 text)) (match-string 5 text))))

(defun maillist--index-meta (start)
  "Return the metadata text that follows an entry beginning at START."
  (save-excursion
    (goto-char start)
    (let ((tail-end (line-end-position))
          (next-end (progn (forward-line 1) (line-end-position))))
      (concat (buffer-substring-no-properties start tail-end) " "
              (buffer-substring-no-properties (line-beginning-position) next-end)))))

(defun maillist-parse-index (html)
  "Parse a public-inbox index page into thread rows.
Each row is (:id :subject :date :count :depth), newest first.  A buried
sub-thread is marked with `:depth' 1 and keeps the archive's own subject."
  (let ((rows '()) (seen (make-hash-table :test #'equal)) (last-date nil))
    (with-temp-buffer
      (insert (or html ""))
      (goto-char (point-min))
      (while (re-search-forward maillist--index-link nil t)
        (let* ((href (match-string 1))
               (prefix (save-excursion
                         (goto-char (match-beginning 0))
                         (buffer-substring-no-properties
                          (line-beginning-position) (point))))
               (subject-start (point))
               (subject-end (or (and (search-forward "</a>" nil t)
                                     (match-beginning 0))
                                (point-max)))
               (subject (maillist-decode-entities
                         (string-trim
                          (buffer-substring-no-properties subject-start subject-end))))
               (meta (maillist--index-meta subject-end))
               (id (file-name-nondirectory (directory-file-name href)))
               (depth (if (string-match-p "`" prefix) 1 0))
               (date (maillist--index-stamp meta)))
          (unless (gethash id seen)
            (puthash id t seen)
            (setq last-date (or date last-date))
            (push (list :id id
                        :subject subject
                        :date (or date last-date)
                        :count (maillist--index-count meta)
                        :depth depth)
                  rows)))))
    (nreverse rows)))

;;; ---------------------------------------------------------------------------
;;; Thread Atom
;;; ---------------------------------------------------------------------------

(defun maillist--plain (node)
  "Return the text content of XML NODE."
  (cond ((stringp node) node)
        ((consp node)
         (mapconcat #'maillist--plain (cddr node) ""))
        (t "")))

(defun maillist--node (name node)
  "Return the first child of NODE whose tag is NAME."
  (car (xml-get-children node name)))

(defun maillist--attribute (node name)
  "Return NAME attribute of XML NODE as a string, or nil."
  (let ((value (xml-get-attribute-or-nil node name)))
    (and (stringp value) value)))

(defun maillist--message-id (href)
  "Return the message id named by HREF, or nil."
  (when (and (stringp href) (not (string-empty-p href)))
    (file-name-nondirectory (directory-file-name href))))

(defun maillist-classify-lines (text &optional prefix)
  "Split message TEXT into (:id :kind :text) lines.
PREFIX names the message so every line keeps a stable key.  Quoted lines keep
their `>' depth as `quote', a diff hunk becomes `patch-meta', `patch-add' or
`patch-del', and everything else is `body'."
  (let ((in-hunk nil) (index 0))
    (mapcar
     (lambda (line)
       (let ((kind
              (cond
               ((string-match "\\`\\(>+\\)" line) "quote")
               ((string-match "\\`@@ .*@@" line) (setq in-hunk t) "patch-meta")
               ((and in-hunk (string-prefix-p "+" line)) "patch-add")
               ((and in-hunk (string-prefix-p "-" line)) "patch-del")
               ((not (string-empty-p (string-trim line)))
                (unless (string-prefix-p " " line) (setq in-hunk nil))
                "body")
               (t "blank"))))
         (prog1 (list :id (format "%s-%d" (or prefix "") index)
                      :kind kind
                      :text (if (equal kind "blank") "" line))
           (cl-incf index))))
     (split-string (or text "") "\n"))))

(defun maillist--entry-depth (entry parents)
  "Return the nesting depth of ENTRY given the PARENTS message-id table."
  (let ((parent (maillist--message-id
                 (maillist--attribute
                  (car (xml-get-children entry 'thr:in-reply-to)) 'href))))
    (if parent (1+ (or (gethash parent parents) 0)) 0)))

(defun maillist-parse-thread (xml-text &optional fallback-subject)
  "Parse a public-inbox thread Atom document into a thread plist.
FALLBACK-SUBJECT names the thread when the feed does not.  The result is
(:id :subject :participants :messages); each message carries its raw `:text'
so it can be cached and classified again on load."
  (let* ((entries (with-temp-buffer
                    (insert (or xml-text ""))
                    (let ((xml (condition-case nil
                                   (xml-parse-region (point-min) (point-max))
                                 (error nil))))
                      (xml-get-children (car xml) 'entry))))
         (parents (make-hash-table :test #'equal))
         (authors (make-hash-table :test #'equal))
         (messages
          (mapcar
           (lambda (entry)
             (let* ((link (maillist--attribute (car (xml-get-children entry 'link)) 'href))
                    (author (maillist--node 'author entry))
                    (content (maillist--node 'content entry))
                    (pre (car (xml-get-children
                               (car (xml-get-children content 'div)) 'pre)))
                    (id (or (maillist--message-id link) ""))
                    (name (string-trim (maillist--plain (maillist--node 'name author))))
                    (depth (maillist--entry-depth entry parents)))
               (when (not (string-empty-p id))
                 (puthash id depth parents))
               (when (not (string-empty-p name))
                 (puthash name t authors))
               (list :id id
                     :author name
                     :email (string-trim (maillist--plain (maillist--node 'email author)))
                     :date (maillist--plain (maillist--node 'updated entry))
                     :parent (maillist--message-id
                              (maillist--attribute
                               (car (xml-get-children entry 'thr:in-reply-to)) 'href))
                     :depth depth
                     :subject (string-trim (maillist--plain (maillist--node 'title entry)))
                     :text (string-trim (maillist--plain pre) "\n" "\n"))))
           entries))
         (title (with-temp-buffer
                  (insert (or xml-text ""))
                  (let ((xml (condition-case nil
                                 (xml-parse-region (point-min) (point-max))
                               (error nil))))
                    (string-trim (maillist--plain (maillist--node 'title (car xml))))))))
    (unless messages
      (error "档案没有返回这个线程的邮件（可能暂时不可用，按 g 重试）"))
    (list :id (or (plist-get (car messages) :id) "")
          :subject (if (string-empty-p title)
                       (or fallback-subject
                           (plist-get (car messages) :subject)
                           "")
                     title)
          :participants (hash-table-count authors)
          :messages messages)))

(defun maillist-parse-recent (xml-text)
  "Parse a public-inbox new-messages feed into (MESSAGE-ID . AUTHOR) hints.
The feed names the sender of the newest messages only, which is enough to fill
the author column before a thread is opened."
  (let* ((entries (with-temp-buffer
                    (insert (or xml-text ""))
                    (let ((xml (condition-case nil
                                   (xml-parse-region (point-min) (point-max))
                                 (error nil))))
                      (xml-get-children (car xml) 'entry))))
         (hints '()))
    (dolist (entry entries (nreverse hints))
      (let* ((link (maillist--attribute
                    (car (xml-get-children entry 'link)) 'href))
             (id (maillist--message-id link))
             (author (string-trim
                      (maillist--plain
                       (maillist--node 'name (maillist--node 'author entry))))))
        (when (and id (not (string-empty-p author)))
          (push (cons id author) hints))))))

(defun maillist-parse-author (text)
  "Return the sender display name of the raw message TEXT, or nil.
The archive's index carries no sender, but one raw message is small enough to
fill the list's author column; folded and RFC 2047 encoded names are unfolded
and decoded."
  (with-temp-buffer
    (insert (or text ""))
    (goto-char (point-min))
    (when (looking-at "From ")
      (forward-line 1))
    (let ((case-fold-search t) from)
      (when (re-search-forward "^From:[ \t]*" nil t)
        (let ((start (point)))
          (end-of-line)
          (while (looking-at "\n[ \t]")
            (forward-line 1)
            (end-of-line))
          (setq from (buffer-substring-no-properties start (point)))))
      (when from
        (setq from (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " from)))
        (setq from (ignore-errors (rfc2047-decode-string from)))
        (when (and from (not (string-empty-p from)))
          (let* ((parsed (ignore-errors (mail-header-parse-address from)))
                 (first (car parsed))
                 (second (cdr parsed)))
            (cond
             ((null parsed) from)
             ;; Releases disagree on the pair's order, so the component with
             ;; an @ is the address and the other one is the display name.
             ((and first (string-match-p "@" first))
              (if (and second (not (string-empty-p second))) second from))
             ((and second (string-match-p "@" second))
              (if (and first (not (string-empty-p first))) first from))
             (t (or first from)))))))))

;;; ---------------------------------------------------------------------------
;;; Transport
;;; ---------------------------------------------------------------------------

(defun maillist--url (source path)
  "Return the URL of PATH inside SOURCE."
  (concat (plist-get source :base) path))

(defconst maillist-request-timeout 45
  "Seconds after which a stalled archive request is abandoned.")

(defcustom maillist-network-route 'auto
  "How archive requests reach the network.
`auto' tries a direct connection first and falls back to the proxy named by
the environment when the direct attempt cannot connect; `direct' never uses a
proxy and `proxy' always does."
  :type '(choice (const :tag "Direct, then the environment proxy" auto)
                 (const :tag "Always direct" direct)
                 (const :tag "Use the environment proxy" proxy))
  :group 'maillist)

(defun maillist--env-proxy-services ()
  "Return proxy services built from the environment, or nil.
url.el honours `url-proxy-services' rather than `NO_PROXY', so the client
chooses the route itself instead of inheriting an unreachable proxy."
  (when-let* ((value (or (getenv "HTTPS_PROXY") (getenv "https_proxy")
                         (getenv "HTTP_PROXY") (getenv "http_proxy")
                         (getenv "ALL_PROXY") (getenv "all_proxy")))
              (host (string-trim
                     (replace-regexp-in-string "\\`[a-zA-Z]+://" "" value) "/")))
    (when (string-match-p ":" host)
      (list (cons "https" host) (cons "http" host)))))

(defun maillist--proxy-services ()
  "Return the proxy services a request may use, or nil."
  (or (and (bound-and-true-p url-proxy-services)
           (consp (bound-and-true-p url-proxy-services))
           (bound-and-true-p url-proxy-services))
      (maillist--env-proxy-services)))

(defun maillist--response-body ()
  "Return the response body of the current url buffer.
A response without a header block (a local `file:' mirror) is all body."
  (goto-char (point-min))
  (if (re-search-forward "\r?\n\r?\n" nil t)
      (buffer-substring-no-properties (point) (point-max))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun maillist--request (url callback &optional route)
  "Fetch URL asynchronously and call CALLBACK with (:body TEXT) or (:error MSG).
Only the first completion is delivered: a timeout or a killed buffer after
the response never calls CALLBACK twice.  ROUTE is `direct', `proxy' or nil
for the first attempt of `maillist-network-route'."
  (let* ((services (pcase route
                     ('proxy (maillist--proxy-services))
                     ('direct nil)
                     (_ nil)))
         (state (list :done nil :timer nil :buffer nil))
         (finish (lambda (result)
                   (unless (plist-get state :done)
                     (plist-put state :done t)
                     (when-let* ((timer (plist-get state :timer)))
                       (cancel-timer timer))
                     (funcall callback result))))
         (abandon (lambda ()
                    (plist-put state :done t)
                    (when-let* ((timer (plist-get state :timer)))
                      (cancel-timer timer))))
         (url-proxy-services services))
    (plist-put
     state :buffer
     (condition-case err
         (url-retrieve
          url
          (lambda (status)
            (let ((failure (plist-get status :error))
                  (code (plist-get status :http-code))
                  (body (ignore-errors (maillist--response-body))))
              (let ((current (current-buffer)))
                (when (buffer-live-p current) (kill-buffer current)))
              (cond
               ((and failure (null code) (null route)
                     (eq maillist-network-route 'auto)
                     (maillist--proxy-services))
                (funcall abandon)
                (maillist--request url callback 'proxy))
               ((or failure (and code (/= code 200)))
                (funcall finish
                         (list :error (or (and failure
                                               (error-message-string failure))
                                          (format "HTTP %s" code)))))
               (t (funcall finish (list :body (or body "")))))))
          nil t t)
       (error
        (funcall finish (list :error (error-message-string err)))
        nil)))
    (when (and (buffer-live-p (plist-get state :buffer))
               (not (plist-get state :done)))
      (plist-put state :timer
                 (run-at-time
                  maillist-request-timeout nil
                  (lambda ()
                    (funcall finish (list :error "请求超时，按 g 重试"))
                    (let ((buffer (plist-get state :buffer)))
                      (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(defun maillist--on-body (url callback parse)
  "Fetch URL, call PARSE on the body, and pass the result to CALLBACK."
  (maillist--request
   url
   (lambda (result)
     (if (plist-get result :error)
         (funcall callback result)
       (funcall callback
                (condition-case err
                    (list :ok (funcall parse (plist-get result :body)))
                  (error (list :error (error-message-string err)))))))))

(defun maillist--index-url (source)
  "Return the thread-list URL of SOURCE."
  (maillist--url source (or (plist-get source :index) "")))

(defun maillist--index-answer (body)
  "Return the (:ok ROWS) or (:error MSG) answer of index BODY.
A public-inbox mirror always lists its threads, so a body that carries none is
no index: an empty body after a dropped connection, or a page that is not the
thread index.  Answering (:ok nil) would trade the client's rows for nothing."
  (if-let* ((rows (maillist-parse-index body)))
      (list :ok rows)
    (list :error (if (string-empty-p (string-trim (or body "")))
                     "档案返回了空响应"
                   "档案没有返回线程索引"))))

(defun maillist-fetch-index (source callback)
  "Fetch SOURCE's thread list and call CALLBACK with (:ok ROWS) or (:error MSG).
An answer carrying no thread row is fetched once more before it becomes an
error: the archive sometimes drops the connection after the status line, and
the retry is what tells a flake from a failure.  A failed answer stays an
error, so the caller keeps the rows it already has."
  (cl-labels
      ((attempt
        (retry)
        (maillist--request
         (maillist--index-url source)
         (lambda (result)
           (if-let* ((error (plist-get result :error)))
               (funcall callback (list :error error))
             (let ((answer (maillist--index-answer (plist-get result :body))))
               (cond
                ((eq (car answer) :ok) (funcall callback answer))
                (retry (run-at-time 1 nil (lambda () (attempt nil))))
                (t (funcall callback answer)))))))))
    (attempt t)))

(defun maillist-fetch-thread (source id callback &optional subject)
  "Fetch thread ID of SOURCE and call CALLBACK with (:ok THREAD).
SUBJECT names the thread when its feed does not."
  (maillist--on-body (maillist--url source (concat id "/t.atom"))
                     callback
                     (lambda (body) (maillist-parse-thread body subject))))

(defun maillist-thread-subject (subject)
  "Return SUBJECT without the reply prefixes a thread accumulates."
  (let ((text (string-trim (or subject ""))))
    (while (string-match "\\`re\\[[0-9]+\\]:[ \t]*\\|\\`re:[ \t]*" text)
      (setq text (string-trim (substring text (match-end 0)))))
    text))

(defun maillist-fetch-subject (source subject callback)
  "Fetch every message whose subject matches SUBJECT.
A merged or truncated thread document can lose the messages the index
announced; the subject feed still answers with them."
  (maillist--on-body
   (maillist--url source
                  (concat "?q="
                          (url-hexify-string
                           (format "s:\"%s\"" (maillist-thread-subject subject)))
                          "&x=A"))
   callback #'maillist-parse-thread))

(defun maillist-fetch-message (source id callback)
  "Fetch message ID alone and call CALLBACK with (:ok THREAD).
The search Atom feed answers with one entry, so this is a few kilobytes even
when the whole thread is huge; it lets the newest mail show while the rest
downloads."
  (maillist--on-body
   (maillist--url source (concat "?q=mid%3A" (url-hexify-string id) "&x=A"))
   callback #'maillist-parse-thread))

(defun maillist-fetch-author (source id callback)
  "Fetch the sender of message ID and call CALLBACK with (:ok AUTHOR)."
  (maillist--on-body (maillist--url source (concat id "/raw"))
                     callback #'maillist-parse-author))

(defun maillist-fetch-recent (source callback)
  "Fetch SOURCE's newest messages and call CALLBACK with (:ok HINTS)."
  (maillist--on-body (maillist--url source "new.atom")
                     callback #'maillist-parse-recent))

(defun maillist-fetch-search (source query callback)
  "Search SOURCE for QUERY and call CALLBACK with (:ok ROWS).
QUERY is the archive's own syntax, which `maillist-compile-query' builds
from what the reader types."
  (maillist--on-body (maillist--url source (concat "?q=" (url-hexify-string query)))
                     callback #'maillist-parse-index))

;;; ---------------------------------------------------------------------------
;;; Query syntax
;;; ---------------------------------------------------------------------------

(defconst maillist-query-fields
  '(("from" . "f") ("to" . "t") ("subject" . "s") ("body" . "b")
    ("message" . "mid"))
  "Fields this client compiles into the archive's own query prefixes.")

(defun maillist--query-tokens (text)
  "Split TEXT into search tokens, keeping a quoted phrase together.
A token ends at whitespace outside quotes; the quotes stay in the token, so
`maillist--query-term' can decide whether it is a phrase."
  (let ((index 0)
        (length (length text))
        tokens)
    (while (< index length)
      (if (memq (aref text index) '(?\s ?\t ?\n))
          (cl-incf index)
        (let ((start index)
              (quoted nil))
          ;; Consume characters until whitespace outside a quoted phrase.
          (while
              (let ((char (and (< index length) (aref text index))))
                (cond
                 ((null char) nil)
                 ((eq char ?\")
                  (setq quoted (not quoted))
                  (cl-incf index)
                  t)
                 ((and (not quoted) (memq char '(?\s ?\t ?\n))) nil)
                 (t (cl-incf index) t))))
          (push (substring text start index) tokens))))
    (nreverse tokens)))

(defun maillist--query-term (value)
  "Return VALUE as one archive term, quoted when it is a phrase.
The archive's search engine takes a quoted string as a phrase and a bare word
as one term; an empty value contributes nothing."
  (let ((text (string-trim (string-trim value) "\"" "\"")))
    (cond
     ((string-empty-p text) nil)
     ((string-match-p "[ \t\"]" text)
      (format "\"%s\"" (replace-regexp-in-string "\"" "" text)))
     (t text))))

(defun maillist--query-date-p (value)
  "Return non-nil when VALUE is an ISO date the archive's range accepts."
  (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\'" value))

(defun maillist-compile-query (text)
  "Compile the reader's search TEXT for a public-inbox archive.
Fields `from:', `to:', `subject:', `body:' and `message:' become the archive's
own prefixes, `after:' and `before:' become one date range, and bare words or
quoted phrases stay terms.  `is:unread' and `is:starred' are kept apart as
local filters: the archive does not know this reader's marks.
Return (:query REMOTE :filters (unread starred)); REMOTE is empty when TEXT
only names local filters."
  (let ((remote nil)
        (filters nil))
    (dolist (token (maillist--query-tokens (or text "")))
      (let* ((colon (string-match "\\`\\([a-zA-Z]+\\):" token))
             (field (and colon (downcase (match-string 1 token))))
             (value (and colon (substring token (match-end 0)))))
        (cond
         ((and field (equal field "is"))
          (pcase (downcase (string-trim (string-trim value) "\"" "\""))
            ("unread" (cl-pushnew 'unread filters))
            ("starred" (cl-pushnew 'starred filters))))
         ((and field (equal field "after") (maillist--query-date-p value))
          (push (format "d:%s.." value) remote))
         ((and field (equal field "before") (maillist--query-date-p value))
          (push (format "d:..%s" value) remote))
         ((and field (assoc field maillist-query-fields))
          (when-let* ((term (maillist--query-term value)))
            (push (format "%s:%s" (cdr (assoc field maillist-query-fields)) term)
                  remote)))
         (t
          (when-let* ((term (maillist--query-term token)))
            (push term remote))))))
    (list :query (string-join (nreverse remote) " ")
          :filters (nreverse filters))))

(provide 'maillist-service)
;;; maillist-service.el ends here
