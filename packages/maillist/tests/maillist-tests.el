;;; maillist-tests.el --- Acceptance tests for maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour tests.  Every scenario drives the package through the
;; interfaces declared in `maillist.el': the archive parser, the session the
;; Views read, the mounted buffer.  A local `file:' mirror stands in for the
;; network, so a whole sync, a thread read and a restart run without a server.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'maillist)

(defconst maillist-tests--fixtures
  (expand-file-name "fixtures/archive"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Local archive mirror used by the acceptance scenarios.")

(defun maillist-tests--read (name)
  "Return the fixture file NAME as a string."
  (with-temp-buffer
    (insert-file-contents (expand-file-name name maillist-tests--fixtures))
    (buffer-string)))

(defun maillist-tests--source (&optional index)
  "Return the archive source of the local fixture mirror.
INDEX names the page the mirror serves instead of its own directory index."
  (list :name "fixture"
        :base (concat "file://" maillist-tests--fixtures "/")
        :index (or index "index.html")
        :address "fixture@example.org"))

(defun maillist-tests--store ()
  "Return a fresh store file for one scenario."
  (make-temp-file "maillist-test" nil ".sqlite3"))

(defun maillist-tests--wait (session)
  "Wait until SESSION's sync settles and return its status."
  (let ((tries 0) status)
    (while (and (< tries 200)
                (progn
                  (setq status (etaf-value (plist-get session :status)))
                  (eq (plist-get status :kind) 'loading)))
      (sleep-for 0.05)
      (setq tries (1+ tries)))
    status))

(defun maillist-tests--open (session)
  "Wait until SESSION's open thread carries messages and return it."
  (let ((tries 0) open)
    (while (and (< tries 200)
                (progn
                  (setq open (etaf-value (plist-get session :open)))
                  (or (plist-get open :loading)
                      (null (plist-get open :messages)))))
      (sleep-for 0.05)
      (setq tries (1+ tries)))
    open))

(defun maillist-tests--settle (session)
  "Wait until SESSION's open thread stops loading or reports its error."
  (let ((tries 0) open)
    (while (and (< tries 200)
                (progn
                  (setq open (etaf-value (plist-get session :open)))
                  (and open
                       (plist-get open :loading)
                       (not (plist-get open :error)))))
      (sleep-for 0.05)
      (setq tries (1+ tries)))
    open))

(defmacro maillist-tests--with-session (var &rest body)
  "Run BODY with VAR bound to a session over a temporary store.
The store file and the fixture source are installed for the body, and the
session is disposed afterwards."
  (declare (indent 1))
  `(let* ((file (maillist-tests--store))
          (maillist-store-file file)
          (maillist-sources (list (maillist-tests--source)))
          (maillist-prefetch-threads 0)
          (,var (maillist-create :list "fixture")))
     (unwind-protect
         (progn ,@body)
       (maillist-dispose ,var)
       (ignore-errors (delete-file file)))))

;;; ---------------------------------------------------------------------------
;;; Archive parsing
;;; ---------------------------------------------------------------------------

(ert-deftest maillist-tests-parse-index-reads-thread-rows ()
  "The index parser reports every thread with its date, size and nesting."
  (let* ((rows (maillist-parse-index (maillist-tests--read "index.html")))
         (first (car rows))
         (buried (nth 2 rows))
         (last (car (last rows))))
    (should (= 4 (length rows)))
    (should (equal "alpha@example.com" (plist-get first :id)))
    (should (equal "[PATCH] Fix the widget default" (plist-get first :subject)))
    (should (equal "2026-10-21T09:15:00Z" (plist-get first :date)))
    (should (= 3 (plist-get first :count)))
    (should (zerop (plist-get first :depth)))
    (should (equal "beta-reply@example.com" (plist-get buried :id)))
    (should (= 1 (plist-get buried :depth)))
    (should (equal "2026-10-20T18:02:00Z" (plist-get buried :date)))
    (should (equal "Question about quoting replies" (plist-get last :subject)))
    (should-not (plist-get last :count))))

(ert-deftest maillist-tests-parse-thread-keeps-messages-and-senders ()
  "A thread document yields its subject, senders and reply nesting."
  (let* ((thread (maillist-parse-thread
                  (maillist-tests--read "alpha@example.com/t.atom")))
         (messages (plist-get thread :messages))
         (first (car messages)))
    (should (equal "[PATCH] Fix the widget default" (plist-get thread :subject)))
    (should (= 2 (plist-get thread :participants)))
    (should (= 3 (length messages)))
    (should (equal "Alice Example" (plist-get first :author)))
    (should (equal "alice@example.com" (plist-get first :email)))
    (should (equal '(0 1 2) (mapcar (lambda (message) (plist-get message :depth))
                                    messages)))
    (should (string-match-p "widget-threshold" (plist-get first :text)))))

(ert-deftest maillist-tests-classify-lines-names-quotes-and-patches ()
  "Body classification marks quotes, diff hunks and prose, each with an id."
  (let* ((lines (maillist-classify-lines
                 "hello\n\n> quoted\n@@ -1 +1 @@\n-old\n+new\nplain" "m"))
         (kinds (mapcar (lambda (line) (plist-get line :kind)) lines)))
    (should (equal '("body" "blank" "quote" "patch-meta" "patch-del" "patch-add" "body")
                   kinds))
    (should (equal "m-0" (plist-get (car lines) :id)))
    (should (equal "m-6" (plist-get (car (last lines)) :id)))))

(ert-deftest maillist-tests-parse-author-reads-the-from-header ()
  "The sender comes from the raw message's From header, decoded and unfolded."
  (should (equal "Alice Example"
                 (maillist-parse-author
                  (maillist-tests--read "alpha@example.com/raw"))))
  (should (equal "Jörg Müller"
                 (maillist-parse-author
                  (concat "From: =?UTF-8?Q?J=C3=B6rg_M=C3=BCller?= <jorg@example.org>\n"
                          "Subject: folded\n\nbody\n"))))
  (should-not (maillist-parse-author "<html><body>502 Bad Gateway</body></html>")))

(ert-deftest maillist-tests-day-labels-follow-the-calendar ()
  "Timestamps read as a clock today, a date before that."
  (let ((today (format-time-string "%Y-%m-%dT%H:%M:%S" nil))
        (yesterday (format-time-string "%Y-%m-%dT%H:%M:%S"
                                       (time-subtract nil 86400))))
    (should (string-match-p "\\`[0-9][0-9]:[0-9][0-9]\\'" (maillist-time-label today)))
    (should (equal "今天" (maillist-day-label today)))
    (should (equal "昨天" (maillist-day-label yesterday)))
    (should (equal "昨天" (maillist-time-label yesterday)))))

;;; ---------------------------------------------------------------------------
;;; Sessions
;;; ---------------------------------------------------------------------------

(ert-deftest maillist-tests-session-syncs-a-local-archive ()
  "A session lists the archive's threads and opens one with its messages."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (should (equal 'idle (plist-get (maillist-tests--wait session) :kind)))
    (let ((rows (etaf-value (plist-get session :threads))))
      (should (= 4 (length rows)))
      (should (equal "[PATCH] Fix the widget default" (plist-get (car rows) :subject)))
      (should (equal "Alice Example" (plist-get (car rows) :author)))
      (should (string-match-p "个线程" (etaf-value (plist-get session :summary))))
      ;; The newest thread opens by itself, so it is read already.
      (should-not (plist-get (car rows) :unread))
      (should (plist-get (nth 1 rows) :unread)))
    (maillist-select session "alpha@example.com")
    (let ((open (maillist-tests--open session)))
      (should (equal "[PATCH] Fix the widget default" (plist-get open :subject)))
      (should (= 3 (plist-get open :total)))
      (should (string-match-p "3 封 · 2 人参与" (plist-get open :meta)))
      (should (= 3 (length (plist-get open :messages)))))))

(ert-deftest maillist-tests-read-and-star-survive-a-restart ()
  "An opened thread stays read and a starred thread stays starred."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-sources (list (maillist-tests--source)))
         (maillist-prefetch-threads 0))
    (unwind-protect
        (progn
          (let ((session (maillist-create :list "fixture")))
            (unwind-protect
                (progn
                  (maillist-refresh session)
                  (maillist-tests--wait session)
                  (maillist-select session "alpha@example.com")
                  (maillist-tests--open session)
                  (should (equal t (maillist-toggle-star session))))
              (maillist-dispose session)))
          (let ((session (maillist-create :list "fixture")))
            (unwind-protect
                (let* ((rows (etaf-value (plist-get session :threads)))
                       (alpha (seq-find (lambda (row)
                                          (equal "alpha@example.com"
                                                 (plist-get row :id)))
                                        rows)))
                  (should (= 4 (length rows)))
                  (should alpha)
                  (should-not (plist-get alpha :unread))
                  (should (plist-get alpha :starred)))
              (maillist-dispose session))))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-unanswered-index-keeps-the-list ()
  "An archive that answers without threads is a failed sync, not an empty list."
  (let* ((file (maillist-tests--store))
         (mirror (make-temp-file "maillist-answer" t))
         (index (expand-file-name "index.html" mirror))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (fixture (maillist-tests--source))
         (answer (list :name "fixture"
                       :base (concat "file://" mirror "/")
                       :index "index.html"
                       :address "answer@example.org")))
    (unwind-protect
        (progn
          ;; One real sync fills the store the next start reads.
          (let ((maillist-sources (list fixture)))
            (let ((session (maillist-create :list "fixture")))
              (unwind-protect
                  (progn
                    (maillist-refresh session)
                    (maillist-tests--wait session)
                    (should (= 4 (length (etaf-value (plist-get session :threads))))))
                (maillist-dispose session))))
          (let ((maillist-sources (list answer)))
            (let ((session (maillist-create :list "fixture")))
              (unwind-protect
                  (progn
                    (should (= 4 (length (etaf-value (plist-get session :threads)))))
                    ;; A body-less answer and a page that is not a thread index
                    ;; both leave the list the client already has.
                    (dolist (body '("" "<html><body>503 Service Unavailable</body></html>"))
                      (write-region body nil index nil 'silent)
                      (maillist-refresh session)
                      (let ((status (maillist-tests--wait session)))
                        (should (eq 'error (plist-get status :kind)))
                        (should (string-match-p "同步失败" (plist-get status :text))))
                      (should (= 4 (length (etaf-value (plist-get session :threads)))))))
                (maillist-dispose session))))
          ;; The stored rows survive the failed syncs.
          (let ((maillist-sources (list fixture)))
            (let ((session (maillist-create :list "fixture")))
              (unwind-protect
                  (should (= 4 (length (etaf-value (plist-get session :threads)))))
                (maillist-dispose session)))))
      (ignore-errors (delete-directory mirror t))
      (ignore-errors (delete-file file)))))

;;; ---------------------------------------------------------------------------
;;; Network route
;;; ---------------------------------------------------------------------------

(defvar maillist-tests--proxy-body ""
  "Body the fake proxy answers every request with.")

(defvar maillist-tests--proxy-hits 0
  "Requests the fake proxy answered in the current scenario.")

(defun maillist-tests--read-literal (name)
  "Return fixture file NAME as unibyte text."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally
     (expand-file-name name maillist-tests--fixtures))
    (buffer-string)))

(defun maillist-tests--answer-with (process chunk body &optional status)
  "Answer the request PROCESS receives with BODY and close the connection.
STATUS is the response status line, 200 by default."
  (let ((request (concat (or (process-get process :request) "") chunk)))
    (process-put process :request request)
    (when (string-match-p "\r\n\r\n" request)
      (process-send-string
       process
       (concat "HTTP/1.1 " (or status "200 OK") "\r\n"
               "Content-Type: text/html\r\n"
               (format "Content-Length: %d\r\n" (length body))
               "Connection: close\r\n\r\n"
               body))
      (delete-process process))))

(defun maillist-tests--proxy-answer (process chunk)
  "Answer the request PROCESS receives with `maillist-tests--proxy-body'."
  (when (string-match-p
         "\r\n\r\n" (concat (or (process-get process :request) "") chunk))
    (setq maillist-tests--proxy-hits (1+ maillist-tests--proxy-hits)))
  (maillist-tests--answer-with process chunk maillist-tests--proxy-body))

(defun maillist-tests--server (&optional filter)
  "Start a local TCP server using FILTER; return (PORT . PROCESS).
A nil FILTER accepts connections and never answers, which is how a blocked
host looks from the client: the connection stays open without a reply."
  (let ((server (make-network-process
                 :name "maillist-test-server"
                 :server t
                 :host "127.0.0.1"
                 :service t
                 :family 'ipv4
                 :coding 'binary
                 :noquery t
                 :filter filter)))
    (cons (process-contact server :service) server)))

(defun maillist-tests--closed-port ()
  "Return a local port nothing listens on."
  (let ((server (maillist-tests--server)))
    (prog1 (car server)
      (delete-process (cdr server)))))

(defun maillist-tests--answer (callback)
  "Run a fetch that calls CALLBACK and return its answer."
  (let ((answer nil) (tries 0))
    (funcall callback (lambda (result) (setq answer result)))
    (while (and (< tries 200) (null answer))
      (sleep-for 0.05)
      (setq tries (1+ tries)))
    answer))

(ert-deftest maillist-tests-proxy-route-answers-through-the-configured-proxy ()
  "A `proxy' route fetches through `maillist-proxy'.
The source names a host that does not resolve, so only the proxy can answer."
  (let* ((server (maillist-tests--server #'maillist-tests--proxy-answer))
         (maillist-tests--proxy-body (maillist-tests--read-literal "index.html"))
         (maillist-tests--proxy-hits 0)
         (maillist-proxy (format "127.0.0.1:%d" (car server)))
         (maillist-network-route 'proxy)
         (url-proxy-services nil)
         (source (list :name "proxy"
                       :base "http://archive.invalid/"
                       :address "proxy@example.org")))
    (unwind-protect
        (let ((answer (maillist-tests--answer
                       (lambda (callback)
                         (maillist-fetch-index source callback)))))
          (should (eq :ok (car answer)))
          (should (= 4 (length (cadr answer))))
          (should (= 1 maillist-tests--proxy-hits)))
      (delete-process (cdr server)))))

(ert-deftest maillist-tests-auto-retries-a-stalled-direct-attempt ()
  "A direct attempt that stops answering retries through the proxy.
The direct host accepts the connection and never replies, so the attempt can
only end at the direct attempt timeout."
  (let* ((proxy (maillist-tests--server #'maillist-tests--proxy-answer))
         (stalled (maillist-tests--server))
         (maillist-tests--proxy-body (maillist-tests--read-literal "index.html"))
         (maillist-tests--proxy-hits 0)
         (maillist-route-attempt-timeout 0.5)
         (maillist-proxy (format "127.0.0.1:%d" (car proxy)))
         (maillist-network-route 'auto)
         (url-proxy-services nil)
         (source (list :name "stalled"
                       :base (format "http://127.0.0.1:%d/" (car stalled))
                       :address "proxy@example.org")))
    (unwind-protect
        (let ((answer (maillist-tests--answer
                       (lambda (callback)
                         (maillist-fetch-index source callback)))))
          (should (eq :ok (car answer)))
          (should (= 4 (length (cadr answer))))
          (should (= 1 maillist-tests--proxy-hits)))
      (delete-process (cdr proxy))
      (delete-process (cdr stalled)))))

(ert-deftest maillist-tests-dead-proxy-route-still-reaches-the-archive ()
  "A `proxy' route falls back to the archive when the proxy is not running.
A local proxy client that is not running leaves its port closed, which is what
the leading route meets; the archive itself answers."
  (let* ((server (maillist-tests--server
                  (lambda (process chunk)
                    (maillist-tests--answer-with
                     process chunk (maillist-tests--read-literal "index.html")))))
         (maillist-proxy (format "127.0.0.1:%d" (maillist-tests--closed-port)))
         (maillist-network-route 'proxy)
         (url-proxy-services nil)
         (source (list :name "fallback"
                       :base (format "http://127.0.0.1:%d/" (car server))
                       :address "fallback@example.org")))
    (unwind-protect
        (let ((answer (maillist-tests--answer
                       (lambda (callback)
                         (maillist-fetch-index source callback)))))
          (should (eq :ok (car answer)))
          (should (= 4 (length (cadr answer)))))
      (delete-process (cdr server)))))

(ert-deftest maillist-tests-failed-routes-name-every-endpoint ()
  "A request that reaches nothing names each endpoint that did not answer.
url.el reports the refused connection as an `error' whose data is a property
list, so its own text is a `peculiar error' naming no host."
  (let* ((archive (maillist-tests--closed-port))
         (proxy (maillist-tests--closed-port))
         (maillist-proxy (format "127.0.0.1:%d" proxy))
         (maillist-network-route 'proxy)
         (url-proxy-services nil)
         (source (list :name "down"
                       :base (format "http://127.0.0.1:%d/" archive)
                       :address "down@example.org")))
    (let ((answer (maillist-tests--answer
                   (lambda (callback)
                     (maillist-fetch-index source callback)))))
      (should (eq :error (car answer)))
      (should (string-match-p (format "代理 127.0.0.1:%d" proxy) (cadr answer)))
      (should (string-match-p (format "档案 127.0.0.1:%d" archive) (cadr answer)))
      (should-not (string-match-p "peculiar" (cadr answer))))))

(ert-deftest maillist-tests-http-error-answer-is-readable ()
  "An archive that refuses the request reports the status it answered with.
url.el reports that as `(error http 403)', which `error-message-string' prints
as a `peculiar error' carrying the number."
  (let* ((server (maillist-tests--server
                  (lambda (process chunk)
                    (maillist-tests--answer-with
                     process chunk "" "403 Forbidden"))))
         (url-proxy-services nil)
         (source (list :name "forbidden"
                       :base (format "http://127.0.0.1:%d/" (car server))
                       :address "forbidden@example.org")))
    (unwind-protect
        (let ((answer (maillist-tests--answer
                       (lambda (callback)
                         (maillist-fetch-index source callback)))))
          (should (eq :error (car answer)))
          (should (string-match-p "HTTP 403" (cadr answer)))
          (should-not (string-match-p "peculiar" (cadr answer))))
      (delete-process (cdr server)))))

(ert-deftest maillist-tests-refresh-keeps-threads-the-index-dropped ()
  "A refresh merges the index page into the stored list instead of replacing it.
An index page names recent threads only, so a thread the page no longer lists
must stay visible, together with the mark the reader put on it."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (full (maillist-tests--source))
         (small (maillist-tests--source "index-small.html")))
    (unwind-protect
        (progn
          (let ((maillist-sources (list full)))
            (let ((session (maillist-create :list "fixture")))
              (unwind-protect
                  (progn
                    (maillist-refresh session)
                    (maillist-tests--wait session)
                    (should (= 4 (length (maillist-rows session))))
                    (maillist-select session "gamma@example.com")
                    (maillist-tests--open session)
                    (maillist-toggle-star session))
                (maillist-dispose session))))
          ;; A second start syncs against a page naming one thread.
          (let ((maillist-sources (list small)))
            (let ((session (maillist-create :list "fixture")))
              (unwind-protect
                  (progn
                    (maillist-refresh session)
                    (maillist-tests--wait session)
                    (let ((rows (maillist-rows session)))
                      (should (= 4 (length rows)))
                      (should (cl-find "gamma@example.com" rows
                                       :key (lambda (row) (plist-get row :id))
                                       :test #'equal)))
                    (let ((gamma (maillist-row session "gamma@example.com")))
                      (should (plist-get gamma :starred)))
                    ;; A buried reply keeps its place under the thread it answers.
                    (let ((ids (mapcar (lambda (row) (plist-get row :id))
                                       (maillist-rows session))))
                      (should (< (cl-position "beta@example.com" ids :test #'equal)
                                 (cl-position "beta-reply@example.com" ids
                                              :test #'equal)))))
                (maillist-dispose session)))))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-read-mark-waits-for-the-body ()
  "Selecting a row whose body never arrives leaves it unread."
  (let* ((maillist-sources (list (maillist-tests--source "index-ghost.html")))
         (file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (session (maillist-create :list "fixture")))
    (unwind-protect
        (progn
          (maillist-refresh session)
          (maillist-tests--wait session)
          (should (= 1 (length (maillist-rows session))))
          (maillist-select session "ghost@example.com")
          (let ((open (maillist-tests--settle session)))
            (should (plist-get open :error)))
          (should (plist-get (maillist-row session "ghost@example.com") :unread)))
      (maillist-dispose session)
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-search-rows-stay-out-of-the-cache ()
  "A displayed search row never becomes the stored fact of the archive cache."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (maillist-sources (list (maillist-tests--source)))
         (first (maillist-create :list "fixture")))
    (unwind-protect
        (progn
          (maillist-refresh first)
          (maillist-tests--wait first)
          ;; What a search view shows: the query is active and the row carries
          ;; the search feed's own facts instead of the index page's.
          (etaf-set-value (plist-get first :query) "widget")
          (etaf-set-value
           (plist-get first :threads)
           (mapcar (lambda (row)
                     (if (equal "alpha@example.com" (plist-get row :id))
                         (list :id "alpha@example.com"
                               :subject "[PATCH] Fix the widget default"
                               :date "1999-01-01T00:00:00Z"
                               :count 99
                               :depth 0
                               :author "Search Sender"
                               :participants 1
                               :unread nil
                               :starred nil)
                       row))
                   (etaf-value (plist-get first :threads))))
          (maillist-select first "alpha@example.com")
          (maillist-tests--open first))
      (maillist-dispose first))
    ;; A later start still reads the archive's own facts from the store.
    (let ((second (maillist-create :list "fixture")))
      (unwind-protect
          (let ((row (maillist-row second "alpha@example.com")))
            (should (= 3 (plist-get row :count)))
            (should (equal "[PATCH] Fix the widget default" (plist-get row :subject)))
            (should (equal "2026-10-21T09:15:00Z" (plist-get row :date))))
        (maillist-dispose second)))
    (ignore-errors (delete-file file))))

(ert-deftest maillist-tests-incompatible-cache-is-rebuilt ()
  "A cache file that cannot be read with today's columns is moved aside and rebuilt."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (maillist-sources (list (maillist-tests--source)))
         (old (sqlite-open file)))
    (unwind-protect
        (progn
          (sqlite-execute old "CREATE TABLE threads (subject TEXT)")
          (sqlite-close old)
          (let ((session (maillist-create :list "fixture")))
            (unwind-protect
                (progn
                  (should (plist-get session :store))
                  (maillist-refresh session)
                  (maillist-tests--wait session)
                  (should (= 4 (length (maillist-rows session)))))
              (maillist-dispose session)))
          ;; The unreadable file is kept, not deleted.
          (should (seq-find (lambda (name) (string-match-p "\\.rebuild-" name))
                            (directory-files (file-name-directory file)
                                             nil
                                             (concat "\\`"
                                                     (regexp-quote
                                                      (file-name-nondirectory file))
                                                     "\\.rebuild-")))))
      (ignore-errors (sqlite-close old))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-lists-do-not-share-stored-threads ()
  "Each archive's threads stay in their own part of the store."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (fixture (maillist-tests--source))
         (other (list :name "other"
                      :base (concat "file://" maillist-tests--fixtures "/")
                      :index "index-small.html"
                      :address "other@example.org")))
    (unwind-protect
        (progn
          (let ((maillist-sources (list fixture)))
            (let ((session (maillist-create :list "fixture")))
              (unwind-protect
                  (progn
                    (maillist-refresh session)
                    (maillist-tests--wait session)
                    (should (= 4 (length (maillist-rows session)))))
                (maillist-dispose session))))
          (let ((maillist-sources (list other)))
            (let ((session (maillist-create :list "other")))
              (unwind-protect
                  (should (zerop (length (maillist-rows session))))
                (maillist-dispose session))))
          (let ((maillist-sources (list fixture)))
            (let ((session (maillist-create :list "fixture")))
              (unwind-protect
                  (should (= 4 (length (maillist-rows session))))
                (maillist-dispose session)))))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-compile-query-maps-fields-and-marks ()
  "Reader search syntax becomes an archive query plus local mark filters."
  (should (equal "f:alice s:widget"
                 (plist-get (maillist-compile-query "from:alice subject:widget")
                            :query)))
  (should (equal "d:2026-10-01.. d:..2026-10-10"
                 (plist-get (maillist-compile-query
                             "after:2026-10-01 before:2026-10-10")
                            :query)))
  (should (equal "\"widget default\""
                 (plist-get (maillist-compile-query "\"widget default\"")
                            :query)))
  (should (equal "foo:bar"
                 (plist-get (maillist-compile-query "foo:bar") :query)))
  (let ((compiled (maillist-compile-query "is:unread patch")))
    (should (equal "patch" (plist-get compiled :query)))
    (should (equal '(unread) (plist-get compiled :filters))))
  (let ((compiled (maillist-compile-query "is:starred is:unread")))
    (should (string-empty-p (plist-get compiled :query)))
    (should (equal '("starred" "unread")
                   (sort (mapcar #'symbol-name (plist-get compiled :filters))
                         #'string<)))))

(ert-deftest maillist-tests-local-mark-filters-narrow-the-list ()
  "is:unread and is:starred filter the rows without asking the archive."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    (maillist-search session "is:unread")
    (should (eq 'idle (plist-get (etaf-value (plist-get session :status)) :kind)))
    (let ((rows (maillist-rows session)))
      (should (= 3 (length rows)))
      (should-not (cl-find "alpha@example.com" rows
                           :key (lambda (row) (plist-get row :id))
                           :test #'equal)))
    ;; The reader closes, because the thread it showed is not in this set.
    (should-not (etaf-value (plist-get session :open)))
    (should (equal "beta@example.com"
                   (etaf-value (plist-get session :selected))))
    ;; Reading a thread under the filter keeps it visible while it is open.
    (maillist-select session "beta@example.com")
    (maillist-tests--open session)
    (let ((rows (maillist-rows session)))
      (should (= 3 (length rows)))
      (should (cl-find "beta@example.com" rows
                       :key (lambda (row) (plist-get row :id))
                       :test #'equal)))
    (maillist-toggle-star session)
    (maillist-search session "is:starred")
    (let ((rows (maillist-rows session)))
      (should (= 1 (length rows)))
      (should (plist-get (car rows) :starred)))
    ;; An empty search returns to the archive's own list again.
    (maillist-search session "")
    (maillist-tests--wait session)
    (should (= 4 (length (maillist-rows session))))))

(ert-deftest maillist-tests-failed-search-keeps-the-open-thread ()
  "A search neither the archive nor the cache can answer leaves the reader alone.
The query names nothing the cached bodies hold, so the fallback has nothing to
show and the failure is reported instead of emptying the reader."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    (maillist-search session "term-the-cache-never-saw")
    (let ((status (maillist-tests--wait session)))
      (should (eq 'error (plist-get status :kind))))
    (should (equal "alpha@example.com"
                   (plist-get (etaf-value (plist-get session :open)) :id)))))

(ert-deftest maillist-tests-reply-targets-the-list-or-the-author ()
  "A reply addresses the list; a private reply addresses the last sender."
  (let ((maillist-mail-address "reader@example.org"))
    (maillist-tests--with-session session
      (maillist-refresh session)
      (maillist-tests--wait session)
      (maillist-select session "beta@example.com")
      (maillist-tests--open session)
      (let ((buffer (maillist-reply session)))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal "fixture@example.org"
                             (message-fetch-field "To")))
              (should (equal "Re: Widget default value"
                             (message-fetch-field "Subject")))
              (should (message-fetch-field "In-Reply-To")))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (let ((buffer (maillist-reply session t)))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal "carol@example.com"
                             (message-fetch-field "To")))
              (should (message-fetch-field "References")))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest maillist-tests-scope-shows-starred-and-unread-rows ()
  "The scope selector filters the rows the list shows."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    (maillist-toggle-star session)
    (maillist-set-scope session 'starred)
    (let ((rows (maillist-rows session)))
      (should (= 1 (length rows)))
      (should (equal "alpha@example.com" (plist-get (car rows) :id))))
    (maillist-set-scope session 'unread)
    (let ((rows (maillist-rows session)))
      (should (cl-find "beta@example.com" rows
                       :key (lambda (row) (plist-get row :id)) :test #'equal))
      (should (cl-every (lambda (row)
                          (or (plist-get row :unread)
                              (equal "alpha@example.com" (plist-get row :id))))
                        rows)))
    (maillist-set-scope session 'all)
    (should (= 4 (length (maillist-rows session))))))

(ert-deftest maillist-tests-long-thread-shows-newest-messages-first ()
  "A thread starts with a window of new messages and grows on demand."
  (let ((maillist-message-window 1))
    (maillist-tests--with-session session
      (maillist-refresh session)
      (maillist-tests--wait session)
      (maillist-select session "alpha@example.com")
      (let ((open (maillist-tests--open session)))
        (should (= 3 (plist-get open :total)))
        (should (= 2 (plist-get open :hidden)))
        (should (= 1 (length (plist-get open :messages))))
        (should (equal "Alice Example" (plist-get (car (plist-get open :messages))
                                                  :author))))
      (maillist-load-earlier session)
      (let ((open (etaf-value (plist-get session :open))))
        (should (= 1 (plist-get open :hidden)))
        (should (= 2 (length (plist-get open :messages)))))
      (maillist-load-earlier session)
      (let ((open (etaf-value (plist-get session :open))))
        (should (zerop (plist-get open :hidden)))
        (should (= 3 (length (plist-get open :messages))))))))

;;; ---------------------------------------------------------------------------
;;; The mounted buffer
;;; ---------------------------------------------------------------------------

(ert-deftest maillist-tests-open-mounts-and-close-releases ()
  "Opening mounted a live client; closing kills its buffer."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (buffer (unwind-protect
                     (maillist-open :sync nil)
                   (ignore-errors (delete-file file)))))
    (unwind-protect
        (progn
          (should (buffer-live-p buffer))
          (should (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "emacs-devel" text))
              (should (string-match-p "全部" text))
              (should (string-match-p "未读" text))
              (should (string-match-p "已收藏" text))
              (should (string-match-p "搜索" text)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (maillist-close)))
      (should-not (buffer-live-p buffer))
      (ignore-errors (delete-file file)))))


;;; ---------------------------------------------------------------------------
;;; Search pages, older mail, marks, retention
;;; ---------------------------------------------------------------------------

(defun maillist-tests--older-page (rows)
  "Return a search page naming ROWS as (ID SUBJECT DATE AUTHOR) lists."
  (concat
   "<html><body><form action=\"./\"><pre><a\nhref=\"?t=20261020220657\"><b>fixture</b></a></pre></form><pre>"
   (mapconcat
    (lambda (row)
      (format "     %d. <b><a\nhref=\"%s/\">%s</a></b>\n        - by %s @ %s UTC [99%%]\n\n"
              (1+ (cl-position row rows :test #'equal))
              (nth 0 row) (nth 1 row) (nth 3 row) (nth 2 row)))
    rows
    "")
   "</pre></body></html>"))

(ert-deftest maillist-tests-parse-search-reads-message-rows ()
  "A search page yields message rows, not thread rows.
The archive answers a query with the messages that matched, in markup the
index page does not share."
  (let* ((page (maillist-tests--read "search.html"))
         (rows (maillist-parse-search page))
         (first (car rows)))
    (should (= 8 (length rows)))
    (should (equal "87ik2wrpq7.fsf@posteo.net" (plist-get first :id)))
    (should (string-match-p "clutch" (plist-get first :subject)))
    (should (equal "2026-10-20T22:06:00Z" (plist-get first :date)))
    (should (equal "Philip Kaludercic" (plist-get first :author)))
    (should-not (plist-get first :count))
    ;; The same page is not a thread index, which is why the search parser is
    ;; a separate reader instead of a mode of the index parser.
    (should (zerop (length (maillist-parse-index page))))
    (should (string-match-p
             "The Kitty Keyboard Protocol and C-g"
             (mapconcat (lambda (row) (plist-get row :subject)) rows " ")))))

(ert-deftest maillist-tests-search-fetch-reads-the-archive-answer ()
  "A search request reads the answer with the search parser."
  (let* ((server (maillist-tests--server
                  (lambda (process chunk)
                    (maillist-tests--answer-with
                     process chunk (maillist-tests--read-literal "search.html")))))
         (maillist-network-route 'direct)
         (url-proxy-services nil)
         (source (list :name "search"
                       :base (format "http://127.0.0.1:%d/" (car server))
                       :address "search@example.org")))
    (unwind-protect
        (let ((answer (maillist-tests--answer
                       (lambda (callback)
                         (maillist-fetch-search source "widget" callback)))))
          (should (eq :ok (car answer)))
          (should (= 8 (length (cadr answer))))
          (should (equal "Re: [ELPA] New package: emacs-reader"
                         (plist-get (cadr (cadr answer)) :subject))))
      (delete-process (cdr server)))))

(ert-deftest maillist-tests-search-falls-back-to-cached-bodies ()
  "A search the archive cannot answer reports from the cached bodies.
The archive is down, so the reader still finds the thread whose body the
client cached, and the row says which text matched."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    (should (equal "alpha@example.com"
                   (plist-get (etaf-value (plist-get session :open)) :id)))
    (let ((dead (maillist-tests--closed-port)))
      (plist-put (plist-get session :source) :base
                 (format "http://127.0.0.1:%d/" dead))
      (let ((maillist-network-route 'direct)
            (url-proxy-services nil))
        (maillist-search session "widget-threshold")
        (let ((status (maillist-tests--wait session)))
          (should (eq 'idle (plist-get status :kind))))
        (let ((rows (maillist-rows session)))
          (should (= 1 (length rows)))
          (should (equal "alpha@example.com" (plist-get (car rows) :id)))
          (should (string-match-p "widget-threshold" (plist-get (car rows) :snippet))))
        (let ((toast (etaf-value (plist-get session :toast))))
          (should (string-match-p "本地缓存" (plist-get toast :text))))))))

(ert-deftest maillist-tests-unread-mark-survives-a-sync ()
  "Marking a thread unread survives the next sync and the next start.
Read state lives in the mark table, so the index page cannot undo it."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    (should-not (plist-get (maillist-row session "alpha@example.com") :unread))
    (should-not (maillist-set-read session "alpha@example.com" nil))
    (should (plist-get (maillist-row session "alpha@example.com") :unread))
    (maillist-refresh session)
    (maillist-tests--wait session)
    (should (plist-get (maillist-row session "alpha@example.com") :unread)))
  ;; A fresh session reads the mark from the store.
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-sources (list (maillist-tests--source)))
         (maillist-prefetch-threads 0)
         (first (maillist-create :list "fixture")))
    (unwind-protect
        (progn
          (maillist-refresh first)
          (maillist-tests--wait first)
          (maillist-set-read first "beta@example.com" nil)
          (maillist-dispose first)
          (let ((second (maillist-create :list "fixture")))
            (unwind-protect
                (should (plist-get (maillist-row second "beta@example.com") :unread))
              (maillist-dispose second))))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-mark-all-read-covers-the-shown-rows ()
  "Marking all read covers the scope the reader sees, and says how many.
A scope other than the whole list is what the command applies to."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "gamma@example.com")
    (maillist-tests--open session)
    (maillist-set-scope session 'unread)
    ;; The open thread stays in view under a scope, so the rows are not all
    ;; unread: what the command reports is the unread ones it changed.
    (let* ((shown (maillist-rows session))
           (before (seq-count (lambda (row) (plist-get row :unread)) shown)))
      (should (> before 0))
      (should (= before (maillist-mark-all-read session)))
      (should-not (seq-find (lambda (row) (plist-get row :unread))
                            (etaf-value (plist-get session :threads)))))
    ;; Nothing is unread now, so the command reports zero and changes nothing.
    (should (zerop (maillist-mark-all-read session)))
    (should-not (seq-find (lambda (row) (plist-get row :unread))
                          (etaf-value (plist-get session :threads))))))

(ert-deftest maillist-tests-older-mail-joins-the-list ()
  "The next page of mail comes from the archive's date search.
A search answers per message, so one discussion must not fill the list, and a
message the list already holds must not appear twice."
  (let* ((older (maillist-tests--older-page
                 '(("old-root@example.com" "Old discussion" "2026-10-01 08:00"
                    "Old Sender")
                   ("old-reply@example.com" "Re: Old discussion"
                    "2026-10-01 09:30" "Other Sender")
                   ("another@example.com" "Another old thread" "2026-09-28 12:00"
                    "Third Sender")
                   ("gamma@example.com" "Question about quoting replies"
                    "2026-10-10 09:00" "Gamma Sender")
                   ("too-new@example.com" "Newer than the list" "2026-10-22 09:00"
                    "Late Sender"))))
         (server (maillist-tests--server
                  (lambda (process chunk)
                    (maillist-tests--answer-with process chunk older)))))
    (unwind-protect
        (maillist-tests--with-session session
          (maillist-refresh session)
          (maillist-tests--wait session)
          (should (= 4 (length (maillist-rows session))))
          (plist-put (plist-get session :source) :base
                     (format "http://127.0.0.1:%d/" (car server)))
          (let ((maillist-network-route 'direct)
                (url-proxy-services nil))
            (maillist-load-older session)
            (maillist-tests--wait session)
            (let* ((rows (maillist-rows session))
                   (ids (mapcar (lambda (row) (plist-get row :id)) rows)))
              (should (= 6 (length rows)))
              ;; The newest of the discussion stands in for it, and the list
              ;; stays newest first.
              (should (equal "old-reply@example.com" (nth 4 ids)))
              (should (equal "another@example.com" (nth 5 ids)))
              (should (plist-get (nth 4 rows) :unread))
              (should-not (plist-get (nth 4 rows) :new))
              (should-not (cl-find "too-new@example.com" ids :test #'equal))
              (should-not (cl-find "old-root@example.com" ids :test #'equal))
              (should (= 1 (cl-count "old discussion" rows
                                     :key (lambda (row)
                                            (downcase
                                             (maillist-thread-subject
                                              (plist-get row :subject))))
                                     :test #'equal)))))
          (let ((toast (etaf-value (plist-get session :toast))))
            (should (string-match-p "2 封更早" (plist-get toast :text)))))
      (delete-process (cdr server)))))


(defun maillist-tests--literal (path)
  "Return the file at PATH as unibyte text."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defvar maillist-tests--requests 0
  "Requests the fixture server answered in the current scenario.")

(defun maillist-tests--archive-server (requests)
  "Answer the fixture archive on every path and record each request.
REQUESTS is a symbol whose value counts the requests answered; the count is
what a sync or a refresh does to the network."
  (maillist-tests--server
   (lambda (process chunk)
     (let ((request (concat (or (process-get process :request) "") chunk)))
       (process-put process :request request)
       (when (string-match-p "\r\n\r\n" request)
         (set requests (1+ (symbol-value requests)))
         (let* ((line (car (split-string request "\r\n")))
                (target (nth 1 (split-string line " ")))
                (path (url-unhex-string (or target "/")))
                (file (cond ((string-match "/t\\.atom\\'" path)
                             (expand-file-name
                              (concat (car (split-string path "/" 'omit-nulls))
                                      "/t.atom")
                              maillist-tests--fixtures))
                            ((string-match-p "raw\\'" path) nil)
                            (t (expand-file-name "index.html"
                                                 maillist-tests--fixtures)))))
           (if (and file (file-exists-p file))
               (maillist-tests--answer-with process "" (maillist-tests--literal file))
             (maillist-tests--answer-with process "" "" "404 Not Found"))))))))

;;; ---------------------------------------------------------------------------
;;; Storage and continuous reading
;;; ---------------------------------------------------------------------------

(ert-deftest maillist-tests-store-answers-while-another-writer-holds-the-file ()
  "A reader answers while another connection is mid-write.
The file is in WAL mode, so a second Emacs that is saving a list does not
block the one that is reading or searching."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (store (maillist-store-open)))
    (unwind-protect
        (let ((other (sqlite-open file)))
          (unwind-protect
              (progn
                (should (equal "wal"
                               (caar (sqlite-select other "PRAGMA journal_mode"))))
                (sqlite-execute other "PRAGMA busy_timeout = 5000")
                (sqlite-execute other "BEGIN IMMEDIATE")
                (sqlite-execute other
                                "INSERT INTO marks (id, read, starred)
                                 VALUES ('held@example.com', 1, 0)")
                ;; The store still reads: a `delete' journal would answer
                ;; `database is locked' here instead of the marks.
                (should (listp (maillist-store-marks store)))
                (should (listp (maillist-store-threads store "fixture")))
                (sqlite-execute other "COMMIT")
                (should (assoc "held@example.com" (maillist-store-marks store))))
            (ignore-errors (sqlite-close other))))
      (maillist-store-close store)
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-store-prune-keeps-the-newest-rows-and-the-marks ()
  "Retention keeps the newest rows, drops the bodies of the rest and keeps marks.
The cache is rebuildable, so pruning it is safe; the reader's own read and
starred state is not, so it survives a prune of the thread it belongs to."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    (maillist-select session "gamma@example.com")
    (maillist-tests--open session)
    (should (maillist-store-thread-messages (plist-get session :store)
                                            "gamma@example.com"))
    (let ((store (plist-get session :store))
          (before-rows (mapcar (lambda (row) (plist-get row :id))
                               (maillist-rows session)))
          (maillist-thread-limit 2)
          (maillist-body-limit 1))
      (let ((kept (maillist-store-prune store "fixture")))
        (should (= 2 (plist-get kept :threads))))
      (let* ((rows (maillist-store-threads store "fixture"))
             (ids (mapcar (lambda (row) (plist-get row :id)) rows))
             (newest (seq-take (sort before-rows
                                     (lambda (a b)
                                       (string> (plist-get (maillist-row session a) :date)
                                                (plist-get (maillist-row session b) :date))))
                               2)))
        (should (= 2 (length rows)))
        (should (equal (sort newest #'string<) (sort ids #'string<)))
        ;; The newest thread keeps its body; the pruned one loses it.
        (should (maillist-store-thread-messages store "alpha@example.com"))
        (should-not (maillist-store-thread-messages store "gamma@example.com")))
      ;; A mark outlives the row it marks: the archive can serve the thread
      ;; again, and the reader's state comes back with it.
      (should (plist-get (cdr (assoc "gamma@example.com"
                                    (maillist-store-marks store)))
                         :read)))))

(ert-deftest maillist-tests-store-settings-round-trip ()
  "A stored setting reads back, and a second write replaces it."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (store (maillist-store-open)))
    (unwind-protect
        (progn
          (should-not (maillist-store-setting "last-list"))
          (should (equal "emacs-user" (maillist-store-save-setting "last-list" "emacs-user")))
          (should (equal "emacs-user" (maillist-store-setting "last-list")))
          (maillist-store-save-setting "last-list" "emacs-bugs")
          (should (equal "emacs-bugs" (maillist-store-setting "last-list"))))
      (maillist-store-close store)
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-open-remembers-the-archive ()
  "A client started without a list opens the one it opened last."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (first (list :name "first" :base "file:///tmp/nowhere/"
                      :address "first@example.org"))
         (second (list :name "second" :base "file:///tmp/nowhere/"
                       :address "second@example.org")))
    (unwind-protect
        (progn
          (let ((maillist-sources (list first second)))
            (let ((session (maillist-create :list "second")))
              (maillist-dispose session)))
          (let ((maillist-sources (list first second)))
            (let ((session (maillist-create)))
              (unwind-protect
                  (should (equal "second"
                                 (plist-get (plist-get session :source) :name)))
                (maillist-dispose session)))))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-cached-body-search-names-the-match ()
  "Cached bodies answer a search with the thread and the text that matched."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    ;; A refresh opens its first row, so the newest thread is cached already;
    ;; a term no body holds still finds nothing.
    (should-not (maillist-store-search-bodies
                 (plist-get session :store) "term-no-body-holds" 10))
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    (let* ((store (plist-get session :store))
           (hits (maillist-store-search-bodies store "widget-threshold" 10)))
      (should (= 1 (length hits)))
      (should (equal "alpha@example.com" (car (car hits))))
      (should (string-match-p "widget-threshold" (cdr (car hits))))
      (should-not (maillist-store-search-bodies store "" 10)))))

(ert-deftest maillist-tests-message-links-lists-addresses-in-order ()
  "A message body yields the addresses a reader can open, without repeats."
  (should (equal '("https://example.org/a" "http://example.net/b?x=1")
                 (maillist-message-links
                  "See https://example.org/a. Also <http://example.net/b?x=1>, and https://example.org/a again.")))
  (should (equal '("https://example.org/patch")
                 (maillist-message-links
                  "Patch: https://example.org/patch)")))
  (should-not (maillist-message-links "No links here, only mail@example.org.")))

(ert-deftest maillist-tests-displayed-links-follow-the-message ()
  "An open thread carries the addresses its messages mention.
The reader acts on them from the same value the body renders from."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (let* ((open (maillist-tests--open session))
           (links (mapcar (lambda (message) (plist-get message :links))
                          (plist-get open :messages))))
      (should (seq-some #'identity links))
      (should (cl-every (lambda (link) (string-prefix-p "http" link))
                        (seq-mapcat #'identity links))))))

(ert-deftest maillist-tests-open-client-syncs-on-a-schedule ()
  "An open client syncs every `maillist-auto-refresh' seconds.
The timer belongs to the session: closing the client stops asking the archive."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-auto-refresh 0.3)
         (maillist-prefetch-threads 0)
         (maillist-network-route 'direct)
         (url-proxy-services nil)
         (server (maillist-tests--archive-server 'maillist-tests--requests))
         (maillist-sources (list (list :name "fixture"
                                       :base (format "http://127.0.0.1:%d/"
                                                     (car server))
                                       :address "fixture@example.org")))
         (buffer nil))
    (unwind-protect
        (progn
          (setq maillist-tests--requests 0)
          (setq buffer (maillist-open :sync t :list "fixture"))
          ;; Wait for the first sync the open itself starts.
          (let ((tries 0))
            (while (and (< tries 120) (zerop maillist-tests--requests))
              (sleep-for 0.05)
              (setq tries (1+ tries))))
          (let ((first maillist-tests--requests))
            (should (>= first 1))
            ;; One idle period later the client asked again, without the
            ;; reader pressing anything.
            (sleep-for 1.2)
            (should (> maillist-tests--requests first))
            (with-current-buffer buffer (maillist-close))
            (let ((closed maillist-tests--requests))
              (sleep-for 0.8)
              (should (= closed maillist-tests--requests)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (maillist-close)))
      (delete-process (cdr server))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-recall-query-walks-the-history ()
  "The history walk returns the queries the client ran, newest first.
Past the oldest query it comes back to the archive's own list, and the walk
does not repeat a query the reader already ran."
  (maillist-tests--with-session session
    (maillist-search session "is:unread")
    (maillist-search session "is:starred")
    (should (equal '("is:starred" "is:unread")
                   (plist-get session :query-history)))
    ;; The newest query is the one on screen, so the walk starts before it.
    (should (equal "is:unread" (maillist-recall-query session)))
    (should (equal "" (maillist-recall-query session)))
    ;; Past the oldest query the reader is back on the list; the next walk
    ;; starts again at the newest query.
    (should (equal "is:starred" (maillist-recall-query session)))
    (should (equal "" (maillist-recall-query session t)))))

(ert-deftest maillist-tests-thread-url-is-the-archive-page ()
  "A thread's shareable address is the archive's own page for it."
  (maillist-tests--with-session session
    (should (equal (concat "file://" maillist-tests--fixtures "/alpha@example.com/")
                   (maillist-thread-url session "alpha@example.com")))))

(ert-deftest maillist-tests-first-sync-marks-nothing-new ()
  "The sync that establishes the list reports no new thread.
A thread the archive names for the first time is new only to a client that
already had a list; otherwise a fresh start would call the whole archive new."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (should (= 4 (length (maillist-rows session))))
    (should-not (seq-find (lambda (row) (plist-get row :new))
                          (maillist-rows session)))
    ;; A later page that names a thread the client does not hold marks it.
    (plist-put (plist-get session :source) :index "index-added.html")
    (maillist-refresh session)
    (maillist-tests--wait session)
    (let ((new-row (maillist-row session "newcomer@example.com")))
      (should new-row)
      (should (plist-get new-row :new))
      (should-not (plist-get (maillist-row session "alpha@example.com") :new))
      (should (string-match-p "1 新"
                              (etaf-value (plist-get session :summary)))))))

(ert-deftest maillist-tests-file-archive-does-not-use-the-proxy ()
  "A `file:' archive is read directly even when the route pins the proxy.
A local mirror has no network path, so asking a proxy would only fail."
  (let* ((proxy (maillist-tests--server #'maillist-tests--proxy-answer))
         (maillist-tests--proxy-body (maillist-tests--read-literal "index.html"))
         (maillist-tests--proxy-hits 0)
         (maillist-proxy (format "127.0.0.1:%d" (car proxy)))
         (maillist-network-route 'proxy)
         (url-proxy-services nil)
         (source (maillist-tests--source)))
    (unwind-protect
        (let ((answer (maillist-tests--answer
                       (lambda (callback)
                         (maillist-fetch-index source callback)))))
          (should (eq :ok (car answer)))
          (should (= 4 (length (cadr answer))))
          (should (zerop maillist-tests--proxy-hits)))
      (delete-process (cdr proxy)))))

(ert-deftest maillist-tests-torn-store-is-rebuilt ()
  "A store file a crash left unreadable is set aside and rebuilt.
SQLite refuses a truncated or half-written file on its first statement, and
the client must not answer that by giving up persistence silently."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file))
    (unwind-protect
        (progn
          ;; A file with the right name and no database inside, which is what
          ;; a write cut short by a full disk leaves behind.
          (with-temp-file file
            (insert "SQLite format 3\0")
            (insert (make-string 200 0)))
          (let ((store (maillist-store-open)))
            (unwind-protect
                (progn
                  (should store)
                  ;; The unreadable file is kept beside the store, so the
                  ;; marks it held can still be recovered by hand.
                  (should (file-expand-wildcards (concat file ".rebuild-*")))
                  ;; The rebuilt file works: a mark written now comes back.
                  (maillist-store-save-mark store "kept@example.com" t nil)
                  (should (plist-get (cdr (assoc "kept@example.com"
                                                 (maillist-store-marks store)))
                                     :read)))
              (maillist-store-close store))))
      (ignore-errors (delete-file file))
      (dolist (backup (file-expand-wildcards (concat file ".rebuild-*")))
        (ignore-errors (delete-file backup))))))

(ert-deftest maillist-tests-reply-all-copies-the-last-author ()
  "A reply-all keeps the list as the recipient and copies the last sender.
The plain reply addresses the list alone, which is why the other form exists."
  (let ((maillist-mail-address "reader@example.org"))
    (maillist-tests--with-session session
      (maillist-refresh session)
      (maillist-tests--wait session)
      (maillist-select session "beta@example.com")
      (maillist-tests--open session)
      (let ((buffer (maillist-reply-all session)))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal "fixture@example.org"
                             (message-fetch-field "To")))
              (should (equal "carol@example.com"
                             (message-fetch-field "Cc")))
              (should (message-fetch-field "In-Reply-To"))
              (should (message-fetch-field "References")))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (let ((buffer (maillist-reply session)))
        (unwind-protect
            (with-current-buffer buffer
              (should-not (message-fetch-field "Cc")))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest maillist-tests-next-unread-visits-each-unread-thread-once ()
  "`n` walks the unread rows after the selection and stops at the end.
Read rows in between are skipped, and the walk does not wrap around."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    ;; Three of the four fixture threads are unread; beta comes next.
    (should (equal "beta@example.com" (maillist-next-unread session)))
    (should (equal "beta-reply@example.com" (maillist-next-unread session)))
    (should (equal "gamma@example.com" (maillist-next-unread session)))
    (should-not (maillist-next-unread session))
    (should (equal "gamma@example.com"
                   (etaf-value (plist-get session :selected))))))

(ert-deftest maillist-tests-select-edge-reaches-both-ends ()
  "The list can be jumped to its first and its last row."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (should (equal "gamma@example.com" (maillist-select-edge session 'last)))
    (should (equal "alpha@example.com" (maillist-select-edge session 'first)))
    (should (equal "alpha@example.com"
                   (plist-get (etaf-value (plist-get session :open)) :id)))))

(provide 'maillist-tests)
;;; maillist-tests.el ends here
