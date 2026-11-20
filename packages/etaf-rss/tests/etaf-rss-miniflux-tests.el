;;; etaf-rss-miniflux-tests.el --- Acceptance tests for the Miniflux backend -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public behaviour tests for the server backend.  The scenarios drive the
;; reader through the interfaces declared in `etaf-rss.el' and answer the
;; backend with recorded Miniflux wire data through the documented transport
;; function, so the whole stack (request mapping, decoding, reply shaping,
;; read and star writes) runs without a server and without the network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-rss)

(defun etaf-rss-miniflux-tests--wait (predicate &optional timeout)
  "Wait until PREDICATE is non-nil for at most TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (sleep-for 0.01))
    (funcall predicate)))

(defun etaf-rss-miniflux-tests--object (&rest pairs)
  "Return a hash table of PAIRS, the shape a decoded JSON object has."
  (let ((table (make-hash-table :test 'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) table))
    table))

(defun etaf-rss-miniflux-tests--server ()
  "Return a mutable Miniflux server double for the transport.
The plist holds the recorded REQUESTS and the mutable ENTRIES; FEEDS and
CATEGORIES mirror the API, and FAILURE names a path that answers HTTP 401."
  (list :requests nil
        :failure nil
        :entries (list (etaf-rss-miniflux-tests--object
                        "id" 5 "status" "unread" "starred" :false
                        "title" "沙箱里的 ETAF"
                        "url" "https://example.com/etaf"
                        "author" "Kinney"
                        "published_at" "2026-10-01T10:00:00Z"
                        "content" "<p>第一段。</p><p>第二段。</p>"
                        "feed" (etaf-rss-miniflux-tests--object
                                "id" 7 "title" "ETAF 博客"))
                       (etaf-rss-miniflux-tests--object
                        "id" 6 "status" "read" "starred" :false
                        "title" "窗口适配"
                        "url" "https://example.com/layout"
                        "author" ""
                        "published_at" "2026-09-30T10:00:00Z"
                        "content" "<p>正文。</p>"
                        "feed" (etaf-rss-miniflux-tests--object
                                "id" 7 "title" "ETAF 博客")))))

(defun etaf-rss-miniflux-tests--feed (server)
  "Return SERVER's single feed in the API shape."
  (ignore server)
  (etaf-rss-miniflux-tests--object
   "id" 7 "title" "ETAF 博客" "feed_url" "https://example.com/feed"
   "site_url" "https://example.com"
   "category" (etaf-rss-miniflux-tests--object "id" 1 "title" "技术")))

(defun etaf-rss-miniflux-tests--entries-reply (server query)
  "Return the entries reply of QUERY for SERVER.
The reader sends `status' once per accepted state, so a scope without
`unread' accepts both states."
  (let* ((statuses (mapcar #'cadr (cl-remove-if-not
                                   (lambda (pair) (equal (car pair) "status"))
                                   query)))
         (starred (equal "true" (cadr (assoc "starred" query))))
         (matching (cl-remove-if-not
                    (lambda (entry)
                      (and (or (not starred)
                               (eq t (gethash "starred" entry)))
                           (or (null statuses)
                               (member (gethash "status" entry) statuses))))
                    (plist-get server :entries))))
    (etaf-rss-miniflux-tests--object
     "total" (length matching) "entries" (vconcat matching))))

(defun etaf-rss-miniflux-tests--unreads (server)
  "Return the per-feed unread counters of SERVER."
  (let ((table (make-hash-table :test 'equal))
        (count 0))
    (dolist (entry (plist-get server :entries))
      (when (equal "unread" (gethash "status" entry))
        (cl-incf count)))
    (puthash "7" count table)
    table))

(defun etaf-rss-miniflux-tests--answer (server method path query body)
  "Return the reply of METHOD PATH for SERVER, recording the request."
  (push (list method path query body) (plist-get server :requests))
  (cond
   ((equal path (plist-get server :failure))
    (list :error "Miniflux 拒绝了这次请求（密钥无效或权限不足）"
          :hint "检查 API 密钥；HTTP 401"))
   ((and (equal method "GET") (equal path "/v1/categories"))
    (list :ok (vector (etaf-rss-miniflux-tests--object "id" 1 "title" "技术"))))
   ((and (equal method "GET") (equal path "/v1/feeds"))
    (list :ok (vector (etaf-rss-miniflux-tests--feed server))))
   ((and (equal method "GET") (equal path "/v1/me"))
    (list :ok (etaf-rss-miniflux-tests--object "id" 1 "username" "pilot")))
   ((and (equal method "GET") (equal path "/v1/feeds/counters"))
    (list :ok (etaf-rss-miniflux-tests--object
               "unreads" (etaf-rss-miniflux-tests--unreads server)
               "reads" (make-hash-table :test 'equal))))
   ((and (equal method "GET") (equal path "/v1/entries"))
    (list :ok (etaf-rss-miniflux-tests--entries-reply server query)))
   ((and (equal method "GET") (string-match "\\`/v1/entries/\\([0-9]+\\)\\'" path))
    (let ((id (string-to-number (match-string 1 path))))
      (list :ok (cl-find-if (lambda (entry) (= id (gethash "id" entry)))
                            (plist-get server :entries)))))
   ((and (equal method "PUT") (string-match "\\`/v1/entries/\\([0-9]+\\)/bookmark\\'" path))
    (let* ((id (string-to-number (match-string 1 path)))
           (data (json-parse-string body :false-object nil :null-object nil))
           (bookmark (eq t (gethash "bookmark" data))))
      (dolist (entry (plist-get server :entries))
        (when (= id (gethash "id" entry))
          (puthash "starred" (if bookmark t :false) entry)))
      (list :ok nil)))
   ((and (equal method "PUT") (equal path "/v1/entries"))
    (let* ((data (json-parse-string body :false-object nil :null-object nil))
           (ids (append (gethash "entry_ids" data) nil))
           (status (gethash "status" data)))
      (dolist (entry (plist-get server :entries))
        (when (member (gethash "id" entry) ids)
          (puthash "status" status entry)))
      (list :ok nil)))
   ((and (equal method "PUT")
         (string-match "\\`/v1/users/\\([0-9]+\\)/mark-all-as-read\\'" path))
    (dolist (entry (plist-get server :entries))
      (puthash "status" "read" entry))
    (list :ok nil))
   ((and (equal method "PUT") (string-match "\\`/v1/feeds/\\([0-9]+\\)/mark-all-as-read\\'" path))
    (dolist (entry (plist-get server :entries))
      (puthash "status" "read" entry))
    (list :ok nil))
   ((and (equal method "PUT") (string-match "\\`/v1/feeds/\\([0-9]+\\)/refresh\\'" path))
    (list :ok nil))
   ((and (equal method "PUT") (equal path "/v1/feeds/refresh"))
    (list :ok nil))
   ((and (equal method "POST") (equal path "/v1/feeds"))
    (let ((data (json-parse-string body :false-object nil :null-object nil)))
      (list :ok (etaf-rss-miniflux-tests--object
                 "feed" (etaf-rss-miniflux-tests--feed server)
                 "feed_url" (gethash "feed_url" data)))))
   (t (list :error (format "unexpected %s %s" method path) :hint "test"))))

(defun etaf-rss-miniflux-tests--session (server)
  "Return a reader session reading SERVER through a scripted transport."
  (etaf-rss-create
   :client (etaf-rss-miniflux-client
            :url "http://miniflux.test" :token "token"
            :transport (lambda (method path query body callback)
                         (funcall callback
                                  (etaf-rss-miniflux-tests--answer
                                   server method path query body))))))

(defun etaf-rss-miniflux-tests--requests (server &optional method path)
  "Return SERVER's recorded requests, optionally only METHOD and PATH."
  (cl-remove-if-not
   (lambda (request)
     (and (or (null method) (equal method (nth 0 request)))
          (or (null path) (equal path (nth 1 request)))))
   (reverse (plist-get server :requests))))

(defun etaf-rss-miniflux-tests--state (session)
  "Return SESSION's state."
  (etaf-rss-state session))

(defun etaf-rss-miniflux-tests--rows (session)
  "Return SESSION's loaded rows as a list."
  (append (plist-get (etaf-rss-miniflux-tests--state session) :rows) nil))

(ert-deftest etaf-rss-tests-miniflux-backend-reads-a-server ()
  "The reader shows a Miniflux server's feeds, folders and articles.
One request protocol drives both backends, so the sidebar, the scope
subtitle and the list come from the server's categories, counters and
entries."
  (let* ((server (etaf-rss-miniflux-tests--server))
         (session (etaf-rss-miniflux-tests--session server)))
    (etaf-rss-refresh session)
    (should (etaf-rss-miniflux-tests--wait
             (lambda () (> (length (etaf-rss-miniflux-tests--rows session)) 0))))
    (let ((state (etaf-rss-miniflux-tests--state session)))
      (should (= 1 (length (plist-get state :feeds))))
      (should (= 1 (plist-get state :unread)))
      (should (= 1 (plist-get state :total)))
      (should (equal "技术" (plist-get (car (plist-get state :feeds)) :folder)))
      (should (equal "ETAF 博客"
                     (plist-get (car (plist-get state :feeds)) :title)))
      (should (equal '("沙箱里的 ETAF" "窗口适配")
                     (mapcar (lambda (row) (plist-get row :title))
                             (etaf-rss-miniflux-tests--rows session))))
      (should (equal "ETAF 博客"
                     (plist-get (car (etaf-rss-miniflux-tests--rows session))
                                :feed-title))))
    ))

(ert-deftest etaf-rss-tests-miniflux-backend-opens-an-article ()
  "Opening an article loads its HTML from the server and renders it.
The detail request is the reader's own `:article' operation, so the reader
pane works unchanged on a server backend."
  (let* ((server (etaf-rss-miniflux-tests--server))
         (session (etaf-rss-miniflux-tests--session server)))
    (etaf-rss-refresh session)
    (should (etaf-rss-miniflux-tests--wait
             (lambda () (> (length (etaf-rss-miniflux-tests--rows session)) 0))))
    (etaf-rss-activate-selection session)
    (should (etaf-rss-miniflux-tests--wait
             (lambda ()
               (let ((state (etaf-rss-miniflux-tests--state session)))
                 (and (plist-get state :reader-lines)
                      (> (length (plist-get state :reader-lines)) 0))))))
    (should (equal '("GET" "/v1/entries/5")
                   (list (nth 0 (car (etaf-rss-miniflux-tests--requests
                                      server "GET" "/v1/entries/5")))
                         (nth 1 (car (etaf-rss-miniflux-tests--requests
                                      server "GET" "/v1/entries/5"))))))
    (should (string-match-p
             "第一段"
             (string-join
              (mapcar (lambda (line) (plist-get line :text))
                      (plist-get (etaf-rss-miniflux-tests--state session)
                                 :reader-lines))
              "\n")))
    ))

(ert-deftest etaf-rss-tests-miniflux-backend-writes-read-and-star ()
  "Reading, starring and marking all read reach the server's endpoints.
The reader updates its own rows and counters from the replies, so the
interface never waits for a reload."
  (let* ((server (etaf-rss-miniflux-tests--server))
         (session (etaf-rss-miniflux-tests--session server)))
    (etaf-rss-refresh session)
    (should (etaf-rss-miniflux-tests--wait
             (lambda () (> (length (etaf-rss-miniflux-tests--rows session)) 0))))
    (etaf-rss-toggle-star session)
    (should (etaf-rss-miniflux-tests--wait
             (lambda ()
               (etaf-rss-miniflux-tests--requests
                server "PUT" "/v1/entries/5/bookmark"))))
    (let ((request (car (etaf-rss-miniflux-tests--requests
                         server "PUT" "/v1/entries/5/bookmark"))))
      (should (eq t (gethash "bookmark"
                             (json-parse-string (nth 3 request)
                                                :false-object nil
                                                :null-object nil)))))
    (should (= 1 (plist-get (etaf-rss-miniflux-tests--state session)
                            :starred-count)))
    (etaf-rss-mark-all-read session)
    (should (etaf-rss-miniflux-tests--wait
             (lambda ()
               (etaf-rss-miniflux-tests--requests
                server "PUT" "/v1/users/1/mark-all-as-read"))))
    (should (etaf-rss-miniflux-tests--wait
             (lambda ()
               (equal "read"
                      (gethash "status" (car (plist-get server :entries)))))))
    (etaf-rss-locate session (list :kind :feed :id 7))
    (should (etaf-rss-miniflux-tests--wait
             (lambda () (> (length (etaf-rss-miniflux-tests--rows session)) 0))))
    (etaf-rss-mark-all-read session)
    (should (etaf-rss-miniflux-tests--wait
             (lambda ()
               (etaf-rss-miniflux-tests--requests
                server "PUT" "/v1/feeds/7/mark-all-as-read"))))))

(ert-deftest etaf-rss-tests-miniflux-backend-reports-a-server-failure ()
  "A rejected request becomes the reader's readable error, not a hang.
The session stays usable, so a wrong token can be fixed without restarting
Emacs."
  (let* ((server (etaf-rss-miniflux-tests--server))
         (session (etaf-rss-miniflux-tests--session server)))
    (setf (plist-get server :failure) "/v1/entries")
    (etaf-rss-refresh session)
    (should (etaf-rss-miniflux-tests--wait
             (lambda ()
               (let ((error (plist-get (etaf-rss-miniflux-tests--state session)
                                       :error)))
                 (and error (string-match-p "密钥" error))))))
    (setf (plist-get server :failure) nil)
    (etaf-rss-locate session :all)
    (should (etaf-rss-miniflux-tests--wait
             (lambda () (> (length (etaf-rss-miniflux-tests--rows session)) 0))))
    ))

(provide 'etaf-rss-miniflux-tests)
;;; etaf-rss-miniflux-tests.el ends here
