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
          (maillist-prefetch-bodies 0)
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
    ;; Switching to starred when nothing is starred must not drag an unstarred row.
    (maillist-set-scope session 'starred)
    (should (= 0 (length (maillist-rows session))))
    (maillist-set-scope session 'all)
    (maillist-select session "alpha@example.com")
    (maillist-toggle-star session)
    (maillist-set-scope session 'starred)
    (let ((rows (maillist-rows session)))
      (should (= 1 (length rows)))
      (should (equal "alpha@example.com" (plist-get (car rows) :id))))
    ;; Switching to unread must not drag read alpha into the unread queue.
    (maillist-set-scope session 'unread)
    (let ((rows (maillist-rows session)))
      (should (cl-find "beta@example.com" rows
                       :key (lambda (row) (plist-get row :id)) :test #'equal))
      (should (cl-every (lambda (row) (plist-get row :unread)) rows)))
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
          (should (equal "*maillist*" (buffer-name buffer)))
          (should (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (should mode-line-format)
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

(ert-deftest maillist-tests-palette-is-shared-while-the-theme-holds ()
  "The palette is derived once and follows a face the theme changes."
  (let ((first (maillist-palette)))
    (should (stringp (plist-get first :bg)))
    (should (eq first (maillist-palette)))
    (let ((before (and (facep 'shadow) (face-attribute 'shadow :foreground nil t))))
      (unwind-protect
          (progn
            (set-face-attribute 'shadow nil :foreground "#123456")
            (should (equal "#123456" (plist-get (maillist-palette) :muted)))
            (should-not (eq first (maillist-palette))))
        (set-face-attribute 'shadow nil :foreground (or before 'unspecified)))
      (should (equal before (and (facep 'shadow)
                                 (face-attribute 'shadow :foreground nil t)))))))

(ert-deftest maillist-tests-a-store-queries-its-own-file ()
  "Search and marks answer from the file the store was opened on.
A caller may open a store over a chosen file while another one is current;
the quiet queries must read that file, not the default one."
  (let* ((first-file (maillist-tests--store))
         (second-file (maillist-tests--store))
         (row (list :id "one@example.com" :subject "One" :date "2026-10-21"
                    :count 1 :author "A" :depth 0 :participants 1))
         (message (list :id "one@example.com.0" :author "A" :email "a@example.org"
                        :date "2026-10-21" :depth 0 :position 0
                        :subject "One" :text "Only the first store has this body.")))
    (unwind-protect
        (progn
          (let ((maillist-store-file first-file))
            (let ((store (maillist-store-open)))
              (maillist-store-save-threads store "bench" (list row))
              (maillist-store-save-thread-messages store "one@example.com"
                                                   (list message))
              (maillist-store-save-marks store '(("one@example.com" t nil)))
              (maillist-store-close store)))
          (let ((maillist-store-file second-file))
            (let ((store (maillist-store-open)))
              (should-not (maillist-store-search-bodies store "first store" 10))
              (should-not (maillist-store-marks store))
              (maillist-store-close store)))
          (let ((maillist-store-file first-file))
            (let ((store (maillist-store-open)))
              (should (= 1 (length (maillist-store-search-bodies
                                    store "first store" 10))))
              (should (eq t (plist-get (cdr (assoc "one@example.com"
                                                   (maillist-store-marks store)))
                                       :read)))
              (maillist-store-close store))))
      (ignore-errors (delete-file first-file))
      (ignore-errors (delete-file second-file)))))

;;; ---------------------------------------------------------------------------
;;; v0.4.0 regressions: encoding, offline resilience, Debbugs, new replies,
;;; search isolation, SQLite migration, structured local search and regions
;;; ---------------------------------------------------------------------------

(ert-deftest maillist-tests-http-utf8-response-is-decoded ()
  "An HTTP response carrying UTF-8 bytes decodes cleanly without mojibake."
  (let* ((html (encode-coding-string
                (concat "<html><body><pre><a\nhref=\"utf8@example.com/T/#t\">"
                        "Jörg Müller — 中文主题</a>\n"
                        " 2026-10-21 09:15 UTC  (2+ messages)\n"
                        "</pre></body></html>")
                'utf-8))
         (server (maillist-tests--server
                  (lambda (process chunk)
                    (let ((req (concat (or (process-get process :request) "") chunk)))
                      (process-put process :request req)
                      (when (string-match-p "\r\n\r\n" req)
                        (process-send-string
                         process
                         (concat "HTTP/1.1 200 OK\r\n"
                                 "Content-Type: text/html; charset=utf-8\r\n"
                                 (format "Content-Length: %d\r\n" (length html))
                                 "Connection: close\r\n\r\n"
                                 html))
                        (delete-process process))))))
         (maillist-network-route 'direct)
         (url-proxy-services nil)
         (source (list :name "utf8"
                       :base (format "http://127.0.0.1:%d/" (car server))
                       :address "utf8@example.org")))
    (unwind-protect
        (let* ((answer (maillist-tests--answer
                        (lambda (cb) (maillist-fetch-index source cb))))
               (rows (cadr answer))
               (subject (plist-get (car rows) :subject)))
          (should (eq :ok (car answer)))
          (should (equal "Jörg Müller — 中文主题" subject)))
      (delete-process (cdr server)))))

(ert-deftest maillist-tests-encoded-message-ids-decode-and-round-trip ()
  "Percent-encoded Message-IDs decode cleanly and encode once in URLs."
  (let* ((html (concat "<html><body><pre><a\nhref=\"a%2Bb%2Fc@gmail.com/T/#t\">"
                       "Encoded ID &#x2014; test</a>\n"
                       " 2026-10-21 09:15 UTC\n</pre></body></html>"))
         (rows (maillist-parse-index html))
         (row (car rows))
         (id (plist-get row :id)))
    (should (equal "a+b/c@gmail.com" id))
    (should (equal "Encoded ID — test" (plist-get row :subject)))
    (maillist-tests--with-session session
      (let ((url (maillist-thread-url session id))
            (mbox (maillist-thread-mbox-url session id)))
        (should (string-suffix-p "/a%2Bb%2Fc@gmail.com/" url))
        (should (string-suffix-p "/a%2Bb%2Fc@gmail.com/t.mbox.gz" mbox))))))

(ert-deftest maillist-tests-offline-cached-thread-survives-refresh-failure ()
  "Opening a cached thread while offline keeps the cached messages on screen."
  (let ((maillist-thread-freshness 0))
    (maillist-tests--with-session session
      (maillist-refresh session)
      (maillist-tests--wait session)
      (maillist-select session "alpha@example.com")
      (let ((first-open (maillist-tests--open session)))
        (should (= 3 (length (plist-get first-open :messages)))))
      ;; Point the source at a closed port so background refresh fails.
      (let ((dead (maillist-tests--closed-port))
            (maillist-network-route 'direct)
            (url-proxy-services nil))
        (plist-put (plist-get session :source) :base
                   (format "http://127.0.0.1:%d/" dead))
        (maillist-select session "alpha@example.com")
        (let ((tries 0) open)
          (while (and (< tries 100)
                      (progn
                        (setq open (etaf-value (plist-get session :open)))
                        (plist-get open :refreshing)))
            (sleep-for 0.05)
            (setq tries (1+ tries)))
          (should (= 3 (length (plist-get open :messages))))
          (should-not (plist-get open :error))
          (should (string-match-p "离线缓存" (plist-get open :meta))))))))

(ert-deftest maillist-tests-debbugs-reply-targets-bug-address ()
  "Replying in a Debbugs list addresses `<bug>@debbugs.gnu.org' instead of opening a new bug."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-mail-address "alice@example.com")
         (maillist-prefetch-threads 0)
         (bug-source (list :name "emacs-bugs"
                           :base (concat "file://" maillist-tests--fixtures "/")
                           :index "index.html"
                           :address "bug-gnu-emacs@gnu.org"
                           :reply-style 'debbugs))
         (maillist-sources (list bug-source))
         (session (maillist-create :list "emacs-bugs")))
    (unwind-protect
        (progn
          (maillist-store-save-threads
           (plist-get session :store) "emacs-bugs"
           (list (list :id "bug1@example.com"
                       :subject "bug#74123: widget default value"
                       :date "2026-10-21T09:15:00Z"
                       :count 2 :author "Alice Example" :depth 0 :participants 2)))
          (maillist-store-save-thread-messages
           (plist-get session :store) "bug1@example.com"
           (list (list :id "bug1@example.com" :author "Alice Example"
                       :email "alice@example.com" :date "2026-10-21T09:15:00Z"
                       :parent nil :depth 0 :subject "bug#74123: widget default value"
                       :text "Report")
                 (list :id "bug2@example.com" :author "Bob Example"
                       :email "bob@example.com" :date "2026-10-21T09:30:00Z"
                       :parent "bug1@example.com" :depth 1
                       :subject "Re: bug#74123: widget default value"
                       :text "Thanks")))
          (maillist-dispose session)
          (setq session (maillist-create :list "emacs-bugs"))
          (let ((maillist-thread-freshness 0))
            (maillist-select session "bug1@example.com"))
          ;; Reply to Bob (focused message defaults to newest): To is 74123@debbugs.gnu.org
          (let ((buf (maillist-reply session)))
            (unwind-protect
                (with-current-buffer buf
                  (should (equal "74123@debbugs.gnu.org" (message-fetch-field "To"))))
              (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
          ;; Focus Alice (own address) and reply-all: Cc excludes own address!
          (maillist-select-message session "bug1@example.com")
          (let ((buf (maillist-reply-all session)))
            (unwind-protect
                (with-current-buffer buf
                  (should (equal "74123@debbugs.gnu.org" (message-fetch-field "To")))
                  (should-not (message-fetch-field "Cc")))
              (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf))))
      (maillist-dispose session)
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-focused-message-reply-and-ancestor-references ()
  "Focusing an earlier message makes `maillist-reply' target it with its ancestor chain."
  (let ((maillist-mail-address "reader@example.org"))
    (maillist-tests--with-session session
      (maillist-refresh session)
      (maillist-tests--wait session)
      (maillist-select session "alpha@example.com")
      (maillist-tests--open session)
      ;; Move focus backward from msg 3 to msg 2 (`alpha-reply@example.com').
      (let ((prev (maillist-move-message session -1)))
        (should (equal "alpha-reply@example.com" prev)))
      (let ((buf (maillist-reply session)))
        (unwind-protect
            (with-current-buffer buf
              (should (equal "<alpha-reply@example.com>"
                             (message-fetch-field "In-Reply-To")))
              (should (equal "<alpha@example.com> <alpha-reply@example.com>"
                             (message-fetch-field "References"))))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest maillist-tests-new-replies-reopen-read-thread-and-mark-new ()
  "A read thread whose date or count advances on sync becomes unread and new again."
  (let* ((file (maillist-tests--store))
         (mirror (make-temp-file "maillist-replies" t))
         (index (expand-file-name "index.html" mirror))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (maillist-sources
          (list (list :name "fixture"
                      :base (concat "file://" mirror "/")
                      :index "index.html"
                      :address "fixture@example.org")))
         (session (maillist-create :list "fixture")))
    (unwind-protect
        (progn
          (write-region
           (concat "<html><body><pre><a\nhref=\"alpha@example.com/T/#t\">"
                   "[PATCH] Fix the widget default</a>\n"
                   " 2026-10-21 09:15 UTC  (3+ messages)\n</pre></body></html>")
           nil index nil 'silent)
          (maillist-refresh session)
          (maillist-tests--wait session)
          (maillist-set-read session "alpha@example.com" t)
          (let ((row (maillist-row session "alpha@example.com")))
            (should-not (plist-get row :unread))
            (should-not (plist-get row :new)))
          ;; Next sync reports newer date and higher count on the same thread.
          (write-region
           (concat "<html><body><pre><a\nhref=\"alpha@example.com/T/#t\">"
                   "[PATCH] Fix the widget default</a>\n"
                   " 2026-10-21 12:30 UTC  (5+ messages)\n</pre></body></html>")
           nil index nil 'silent)
          (maillist-refresh session)
          (maillist-tests--wait session)
          (let ((row (maillist-row session "alpha@example.com")))
            (should (plist-get row :unread))
            (should (plist-get row :new)))
          ;; Marking read again clears `:new' as well.
          (maillist-set-read session "alpha@example.com" t)
          (let ((row (maillist-row session "alpha@example.com")))
            (should-not (plist-get row :unread))
            (should-not (plist-get row :new))))
      (maillist-dispose session)
      (ignore-errors (delete-directory mirror t))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-search-isolation-and-instant-restore ()
  "Clearing a search restores the archive list offline without losing cached rows."
  (let* ((server (maillist-tests--server
                  (lambda (process chunk)
                    (maillist-tests--answer-with
                     process chunk (maillist-tests--read-literal "search.html")))))
         (maillist-network-route 'direct)
         (url-proxy-services nil))
    (unwind-protect
        (maillist-tests--with-session session
          (maillist-refresh session)
          (maillist-tests--wait session)
          (should (= 4 (length (maillist-rows session))))
          ;; Point to search server and run a remote query.
          (plist-put (plist-get session :source) :base
                     (format "http://127.0.0.1:%d/" (car server)))
          (maillist-search session "clutch")
          (maillist-tests--wait session)
          (should (= 8 (length (maillist-rows session))))
          ;; Now cut the network completely and clear search: all 4 archive
          ;; threads must return immediately from memory/cache!
          (let ((dead (maillist-tests--closed-port)))
            (plist-put (plist-get session :source) :base
                       (format "http://127.0.0.1:%d/" dead))
            (maillist-search session "")
            (should (eq 'idle (plist-get (etaf-value (plist-get session :status)) :kind)))
            (should (= 4 (length (maillist-rows session))))))
      (delete-process (cdr server)))))

(ert-deftest maillist-tests-structured-local-search-handles-fields-and-wildcards ()
  "Offline local search honours `from:', `subject:', negation, `is:read' and LIKE escapes."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "alpha@example.com")
    (maillist-tests--open session)
    (let ((dead (maillist-tests--closed-port))
          (maillist-network-route 'direct)
          (url-proxy-services nil))
      (plist-put (plist-get session :source) :base
                 (format "http://127.0.0.1:%d/" dead))
      ;; Structured query compiles to f:alice s:widget, yet local fallback matches!
      (maillist-search session "from:alice subject:widget")
      (maillist-tests--wait session)
      (let ((rows (maillist-rows session)))
        (should (= 1 (length rows)))
        (should (equal "alpha@example.com" (plist-get (car rows) :id))))
      ;; Negated local filter is:read returns only the read thread (`alpha').
      (maillist-search session "is:read")
      (let ((rows (maillist-rows session)))
        (should (= 1 (length rows)))
        (should (equal "alpha@example.com" (plist-get (car rows) :id))))
      ;; Wildcard `%` in body search must not match unrelated bodies.
      (should-not (maillist-store-search-bodies
                   (plist-get session :store) "100%" 10 "fixture")))))

(ert-deftest maillist-tests-cross-posted-threads-and-shared-messages-stay-isolated ()
  "Same thread ID in two lists and shared messages in two threads do not clobber."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (store (maillist-store-open)))
    (unwind-protect
        (progn
          (maillist-store-save-threads
           store "list-a"
           (list (list :id "cross@example.com" :subject "Cross-posted A"
                       :date "2026-10-21T09:00:00Z" :count 2 :author "A")))
          (maillist-store-save-threads
           store "list-b"
           (list (list :id "cross@example.com" :subject "Cross-posted B"
                       :date "2026-10-21T09:00:00Z" :count 2 :author "A")))
          (should (= 1 (length (maillist-store-threads store "list-a"))))
          (should (= 1 (length (maillist-store-threads store "list-b"))))
          ;; Two thread caches sharing message `m2' both keep their messages and `:parent'.
          (let ((m1 (list :id "m1" :author "A" :email "a@x" :date "2026-10-21T09:00:00Z"
                          :parent nil :depth 0 :subject "S" :text "one"))
                (m2 (list :id "m2" :author "B" :email "b@x" :date "2026-10-21T09:10:00Z"
                          :parent "m1" :depth 1 :subject "Re: S" :text "two")))
            (maillist-store-save-thread-messages store "m1" (list m1 m2))
            (maillist-store-save-thread-messages store "m2" (list m1 m2))
            (let ((parent-msgs (maillist-store-thread-messages store "m1"))
                  (child-msgs (maillist-store-thread-messages store "m2")))
              (should (= 2 (length parent-msgs)))
              (should (= 2 (length child-msgs)))
              (should (equal "m1" (plist-get (nth 1 parent-msgs) :parent))))))
      (maillist-store-close store)
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-v3-store-migrates-in-place-preserving-marks ()
  "A valid v0.3.0 store upgrades to composite keys in place without losing marks."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (conn (sqlite-open file)))
    (unwind-protect
        (progn
          (sqlite-execute
           conn
           "CREATE TABLE threads (id TEXT PRIMARY KEY, subject TEXT, date TEXT,
              thread_count INTEGER, author TEXT, depth INTEGER, list_name TEXT,
              participants INTEGER)")
          (sqlite-execute
           conn
           "CREATE TABLE messages (id TEXT PRIMARY KEY, thread TEXT, author TEXT,
              email TEXT, date TEXT, depth INTEGER, position INTEGER, body TEXT,
              subject TEXT)")
          (sqlite-execute
           conn
           "CREATE TABLE marks (id TEXT PRIMARY KEY, read INTEGER, starred INTEGER)")
          (sqlite-execute
           conn
           "INSERT INTO threads VALUES ('legacy@x', 'Old subject', '2026-10-01T00:00:00Z', 1, 'Alice', 0, 'emacs-devel', 1)")
          (sqlite-execute
           conn
           "INSERT INTO marks VALUES ('legacy@x', 1, 1)")
          (sqlite-close conn)
          (let ((store (maillist-store-open)))
            (unwind-protect
                (progn
                  (should store)
                  (should-not (file-expand-wildcards (concat file ".rebuild-*")))
                  (let ((rows (maillist-store-threads store "emacs-devel"))
                        (marks (maillist-store-marks store)))
                    (should (= 1 (length rows)))
                    (should (equal "legacy@x" (plist-get (car rows) :id)))
                    (should (plist-get (cdr (assoc "legacy@x" marks)) :read))
                    (should (plist-get (cdr (assoc "legacy@x" marks)) :starred))))
              (maillist-store-close store))))
      (ignore-errors (sqlite-close conn))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-prune-protects-starred-and-other-lists ()
  "Pruning a list keeps starred threads and never drops another list's cached bodies."
  (maillist-tests--with-session session
    (maillist-refresh session)
    (maillist-tests--wait session)
    (maillist-select session "gamma@example.com")
    (maillist-tests--open session)
    (maillist-toggle-star session)
    (let ((store (plist-get session :store)))
      (maillist-store-save-threads
       store "other"
       (list (list :id "other-old@example.com" :subject "Quiet list"
                   :date "2020-01-01T00:00:00Z" :count 1 :author "Z")))
      (maillist-store-save-thread-messages
       store "other-old@example.com"
       (list (list :id "other-old@example.com" :author "Z" :email "z@x"
                   :date "2020-01-01T00:00:00Z" :depth 0 :subject "Quiet list"
                   :text "Kept in other list")))
      (let ((maillist-thread-limit 1)
            (maillist-body-limit 1))
        (maillist-store-prune store "fixture")
        ;; Starred `gamma' keeps both its thread row and its cached body.
        (should (maillist-store-thread-messages store "gamma@example.com"))
        ;; Quiet second list's cached body is untouched.
        (should (maillist-store-thread-messages store "other-old@example.com"))))))

(ert-deftest maillist-tests-classify-lines-and-links-handle-diffs-quotes-signatures ()
  "Diff headers, nested quote depths, signatures and balanced URLs classify cleanly."
  (let* ((body (concat "diff --git a/foo.el b/foo.el\n"
                       "--- a/foo.el\n"
                       "+++ b/foo.el\n"
                       "@@ -1 +1 @@\n"
                       "-old\n"
                       "+new\n\n"
                       "-- \n"
                       "- not a diff deletion\n"
                       ">> nested quote\n"))
         (lines (maillist-classify-lines body "p"))
         (kinds (mapcar (lambda (l) (plist-get l :kind)) lines)))
    (should (equal '("patch-meta" "patch-meta" "patch-meta" "patch-meta"
                     "patch-del" "patch-add" "blank" "signature"
                     "signature" "signature" "blank")
                   kinds)))
  (let* ((quoted (maillist-classify-lines "> one\n>> two\n> > two-sp" "q")))
    (should (equal '(1 2 2)
                   (mapcar (lambda (l) (plist-get l :quote-depth)) quoted))))
  (let ((links (maillist-message-links
                (concat "> https://quoted.example.org/ignored\n"
                        "See https://en.wikipedia.org/wiki/Emacs_(text_editor).\n"
                        "(and https://example.org/ok)"))))
    (should (equal '("https://en.wikipedia.org/wiki/Emacs_(text_editor)"
                     "https://example.org/ok")
                   links))))

(ert-deftest maillist-tests-prev-unread-folding-quotes-and-custom-sources ()
  "Previous-unread, collapse-all, quote toggle, inherit transport and custom sources work."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-sources (list (maillist-tests--source)))
         (maillist-prefetch-threads 0))
    (unwind-protect
        (progn
          (maillist-add-source "custom-list" "https://example.org/custom" "custom@example.org")
          (should (equal "https://example.org/custom/"
                         (plist-get (maillist-source "custom-list") :base)))
          ;; Persists across a fresh `maillist-create' even if removed from dynamic var.
          (let ((maillist-sources (list (maillist-tests--source))))
            (let ((s (maillist-create :list "custom-list")))
              (unwind-protect
                  (should (equal "custom-list"
                                 (plist-get (plist-get s :source) :name)))
                (maillist-dispose s))))
          (maillist-remove-source "custom-list")
          (let ((session (maillist-create :list "fixture")))
            (unwind-protect
                (progn
                  (maillist-refresh session)
                  (maillist-tests--wait session)
                  (maillist-select-edge session 'last)
                  (maillist-tests--open session)
                  (should (equal "beta-reply@example.com" (maillist-prev-unread session)))
                  (maillist-select session "alpha@example.com")
                  (maillist-tests--open session)
                  (should (eq t (maillist-toggle-all-messages session)))
                  (should (eq nil (maillist-toggle-all-messages session)))
                  (should (eq t (maillist-toggle-quotes session)))
                  (should (eq nil (maillist-toggle-quotes session)))
                  ;; Inherit send-mail-function leaves Emacs's own transport intact.
                  (let ((maillist-mail-address "me@example.org")
                        (maillist-send-mail-function 'inherit)
                        (message-send-mail-function #'message-send-mail-with-sendmail))
                    (let ((buf (maillist-reply session)))
                      (unwind-protect
                          (with-current-buffer buf
                            (should (eq #'message-send-mail-with-sendmail
                                        message-send-mail-function)))
                        (with-current-buffer buf (set-buffer-modified-p nil))
                        (kill-buffer buf)))))
              (maillist-dispose session))))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-native-index-cursor-loads-older-threads ()
  "When the index page exposes a `?t=...' next link, `maillist-load-older' pages threads natively."
  (let* ((page1 (concat "<html><body><pre><a\nhref=\"new1@example.com/T/#t\">"
                        "Newest thread</a>\n 2026-10-21 09:15 UTC  (3+ messages)\n"
                        "</pre><a href=\"?t=20261020000000\">next (older)</a></body></html>"))
         (page2 (concat "<html><body><pre><a\nhref=\"old1@example.com/T/#t\">"
                        "Native paged thread</a>\n 2026-10-15 11:00 UTC  (7+ messages)\n"
                        "</pre></body></html>"))
         (server (maillist-tests--server
                  (lambda (process chunk)
                    (let ((req (concat (or (process-get process :request) "") chunk)))
                      (process-put process :request req)
                      (when (string-match-p "\r\n\r\n" req)
                        (maillist-tests--answer-with
                         process ""
                         (if (string-match-p "\\?t=" req) page2 page1)))))))
         (file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (maillist-network-route 'direct)
         (url-proxy-services nil)
         (maillist-sources (list (list :name "paged"
                                       :base (format "http://127.0.0.1:%d/" (car server))
                                       :address "paged@example.org")))
         (session (maillist-create :list "paged")))
    (unwind-protect
        (progn
          (maillist-refresh session)
          (maillist-tests--wait session)
          (should (= 1 (length (maillist-rows session))))
          (maillist-load-older session)
          (maillist-tests--wait session)
          (let ((older (maillist-row session "old1@example.com")))
            (should (= 2 (length (maillist-rows session))))
            (should older)
            ;; Native index pagination preserves message count!
            (should (= 7 (plist-get older :count)))))
      (maillist-dispose session)
      (delete-process (cdr server))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-mounted-regions-and-help ()
  "The mounted client declares ETAF regions (`search', `threads', `reader') and help notes."
  (let* ((file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-narrow-width 40)
         (buffer (maillist-open :sync nil)))
    (unwind-protect
        (with-current-buffer buffer
          (let* ((rt (etaf-runtime-for-buffer buffer))
                 (help (etaf-help-data rt))
                 (notes (plist-get help :notes))
                 (groups (plist-get help :groups))
                 (region-group (cl-find 'regions groups
                                        :key (lambda (g) (plist-get g :kind))))
                 (search-target (etaf-region-focus 'search rt))
                 (threads-target (etaf-region-focus 'threads rt))
                 (reader-target (etaf-region-focus 'reader rt)))
            (should (consp notes))
            (should region-group)
            (should search-target)
            (should threads-target)
            (should reader-target)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (maillist-close)))
      (ignore-errors (delete-file file)))))

;;; ---------------------------------------------------------------------------
;;; NNTP fast transport, authoritative cache & HTTP resilience
;;; ---------------------------------------------------------------------------

(defun maillist-tests--nntp-server (state)
  "Start a loopback mock NNTP server backed by STATE plist.
STATE carries `:group' (string), `:articles' (list of plists with `:artnum',
`:subject', `:from', `:date', `:id', `:refs', `:raw') and `:log' (commands
received).  Return (PORT . SERVER-PROCESS)."
  (let* ((handle-client
          (lambda (client chunk)
            (let ((buf (concat (or (process-get client :buf) "") chunk)))
              (while (string-match "\r\n" buf)
                (let ((line (substring buf 0 (match-beginning 0))))
                  (setq buf (substring buf (match-end 0)))
                  (plist-put state :log (append (plist-get state :log) (list line)))
                  (let ((arts (plist-get state :articles)))
                    (cond
                     ((string-match "\\`GROUP[ \t]+\\(.+\\)\\'" line)
                      (let* ((nums (mapcar (lambda (a) (plist-get a :artnum)) arts))
                             (lo (if nums (apply #'min nums) 0))
                             (hi (if nums (apply #'max nums) 0)))
                        (process-send-string
                         client
                         (format "211 %d %d %d %s\r\n"
                                 (length arts) lo hi (match-string 1 line)))))
                     ((string-match "\\`XOVER[ \t]+\\([0-9]+\\)-\\([0-9]+\\)\\'" line)
                      (let* ((lo (string-to-number (match-string 1 line)))
                             (hi (string-to-number (match-string 2 line)))
                             (picked (seq-filter
                                      (lambda (a)
                                        (and (>= (plist-get a :artnum) lo)
                                             (<= (plist-get a :artnum) hi)))
                                      arts))
                             (body (mapconcat
                                    (lambda (a)
                                      (format "%d\t%s\t%s\t%s\t<%s>\t%s\t100\t5"
                                              (plist-get a :artnum)
                                              (plist-get a :subject)
                                              (plist-get a :from)
                                              (plist-get a :date)
                                              (plist-get a :id)
                                              (or (plist-get a :refs) "")))
                                    picked "\r\n")))
                        (process-send-string
                         client
                         (if (string-empty-p body)
                             "224 Overview follows\r\n.\r\n"
                           (concat "224 Overview follows\r\n" body "\r\n.\r\n")))))
                     ((string-match "\\`ARTICLE[ \t]+<\\([^>]+\\)>\\'" line)
                      (let* ((mid (match-string 1 line))
                             (found (cl-find mid arts
                                             :key (lambda (a) (plist-get a :id))
                                             :test #'equal)))
                        (if found
                            (let ((raw (replace-regexp-in-string
                                        "\n" "\r\n"
                                        (replace-regexp-in-string
                                         "\r\n" "\n" (plist-get found :raw) t t)
                                        t t)))
                              (process-send-string
                               client
                               (concat (format "220 0 <%s> article\r\n" mid)
                                       raw "\r\n.\r\n")))
                          (process-send-string
                           client "430 No such article\r\n"))))
                     ((string-match-p "\\`QUIT" line)
                      (process-send-string client "205 Bye\r\n")
                      (delete-process client))
                     (t
                      (process-send-string client "500 Unknown\r\n"))))))
              (process-put client :buf buf))))
         (server (make-network-process
                  :name "maillist-test-nntp"
                  :server t :host "127.0.0.1" :service 0
                  :family 'ipv4 :coding 'binary
                  :filter handle-client
                  :log (lambda (_server client _msg)
                         (process-send-string
                          client "201 mock nntp ready\r\n")))))
    (cons (process-contact server :service) server)))

(ert-deftest maillist-tests-nntp-sync-thread-older-and-incremental-update ()
  "NNTP sync fetches authors via XOVER, pipelines MIME articles, updates incrementally and pages older."
  (let* ((old-art
          (list :artnum 10
                :subject "Older archived discussion"
                :from "Dan Older <dan@example.org>"
                :date "Thu, 15 Oct 2026 10:00:00 +0000"
                :id "old-nntp@example.org"
                :refs ""
                :raw (concat "From: Dan Older <dan@example.org>\n"
                             "Subject: Older archived discussion\n"
                             "Date: Thu, 15 Oct 2026 10:00:00 +0000\n"
                             "Message-ID: <old-nntp@example.org>\n"
                             "Content-Type: text/plain; charset=utf-8\n\n"
                             "Earlier mail body.")))
         (art1
          (list :artnum 11
                :subject "=?UTF-8?B?5Lit5paH5Li76aKY?="
                :from "=?UTF-8?Q?St=C3=A9phane_Marks?= <stephane@example.org>"
                :date "Wed, 21 Oct 2026 09:00:00 +0000"
                :id "nntp-root@example.org"
                :refs ""
                :raw (concat "From: =?UTF-8?Q?St=C3=A9phane_Marks?= <stephane@example.org>\n"
                             "Subject: =?UTF-8?B?5Lit5paH5Li76aKY?=\n"
                             "Date: Wed, 21 Oct 2026 09:00:00 +0000\n"
                             "Message-ID: <nntp-root@example.org>\n"
                             "Content-Type: text/plain; charset=utf-8\n"
                             "Content-Transfer-Encoding: quoted-printable\n\n"
                             "Hello =E4=B8=96=E7=95=8C!\n")))
         (art2
          (list :artnum 12
                :subject "Re: =?UTF-8?B?5Lit5paH5Li76aKY?="
                :from "Bob Reply <bob@example.org>"
                :date "Wed, 21 Oct 2026 10:30:00 +0000"
                :id "nntp-reply1@example.org"
                :refs "<nntp-root@example.org>"
                :raw (concat "From: Bob Reply <bob@example.org>\n"
                             "Subject: Re: =?UTF-8?B?5Lit5paH5Li76aKY?=\n"
                             "Date: Wed, 21 Oct 2026 10:30:00 +0000\n"
                             "Message-ID: <nntp-reply1@example.org>\n"
                             "In-Reply-To: <nntp-root@example.org>\n"
                             "References: <nntp-root@example.org>\n"
                             "Content-Type: multipart/alternative; boundary=\"bnd42\"\n\n"
                             "--bnd42\n"
                             "Content-Type: text/plain; charset=utf-8\n\n"
                             "Plain reply text.\n"
                             "--bnd42\n"
                             "Content-Type: text/html; charset=utf-8\n\n"
                             "<p>HTML ignored</p>\n"
                             "--bnd42--\n")))
         (art3
          (list :artnum 13
                :subject "Re: =?UTF-8?B?5Lit5paH5Li76aKY?="
                :from "Carol Late <carol@example.org>"
                :date "Wed, 21 Oct 2026 12:00:00 +0000"
                :id "nntp-reply2@example.org"
                :refs "<nntp-root@example.org> <nntp-reply1@example.org>"
                :raw (concat "From: Carol Late <carol@example.org>\n"
                             "Subject: Re: =?UTF-8?B?5Lit5paH5Li76aKY?=\n"
                             "Date: Wed, 21 Oct 2026 12:00:00 +0000\n"
                             "Message-ID: <nntp-reply2@example.org>\n"
                             "In-Reply-To: <nntp-reply1@example.org>\n"
                             "References: <nntp-root@example.org> <nntp-reply1@example.org>\n\n"
                             "Brand new incremental reply.")))
         (state (list :group "test.list" :articles (list old-art art1 art2) :log nil))
         (srv (maillist-tests--nntp-server state))
         (dead-http (maillist-tests--closed-port))
         (file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-transport 'auto)
         (maillist-nntp-sync-window 2)
         (maillist-nntp-older-batch 5)
         (maillist-prefetch-threads 0)
         (maillist-prefetch-bodies 0)
         (maillist-sources
          (list (list :name "nntp-list"
                      :base (format "http://127.0.0.1:%d/" dead-http)
                      :address "nntp-list@example.org"
                      :nntp (list :host "127.0.0.1" :port (car srv) :group "test.list"))))
         (session (maillist-create :list "nntp-list")))
    (unwind-protect
        (progn
          ;; 1. Initial NNTP sync fetches only the latest 2 articles (art1 + art2)
          ;;    with decoded UTF-8 authors & subjects and zero HTTP requests.
          (maillist-refresh session)
          (let ((st (maillist-tests--wait session)))
            (should (eq 'idle (plist-get st :kind))))
          (let ((row (maillist-row session "nntp-root@example.org")))
            (should row)
            (should (equal "中文主题" (plist-get row :subject)))
            (should (equal "Stéphane Marks" (plist-get row :author)))
            (should (= 2 (plist-get row :count))))
          ;; 2. Open thread: pipelined ARTICLE fetches both & decodes QP + multipart.
          (maillist-select session "nntp-root@example.org")
          (let* ((open (maillist-tests--open session))
                 (msgs (plist-get open :messages)))
            (should (= 2 (length msgs)))
            (should (string-match-p "Hello 世界!" (plist-get (nth 0 msgs) :text)))
            (should (string-match-p "Plain reply text." (plist-get (nth 1 msgs) :text)))
            (should (equal '(0 1) (mapcar (lambda (m) (plist-get m :depth)) msgs))))
          ;; Thread is now read.  Append a 3rd reply on the NNTP server.
          (should-not (plist-get (maillist-row session "nntp-root@example.org") :unread))
          (plist-put state :articles (list old-art art1 art2 art3))
          (plist-put state :log nil)
          ;; 3. Incremental sync only runs XOVER 13-13 and re-surfaces the thread unread!
          (maillist-refresh session)
          (maillist-tests--wait session)
          (should (member "XOVER 13-13" (plist-get state :log)))
          (let ((row (maillist-row session "nntp-root@example.org")))
            (should (plist-get row :unread))
            (should (= 3 (plist-get row :count))))
          ;; Reopening fetches ONLY the missing 3rd article, merging with cached 1 & 2!
          (plist-put state :log nil)
          (maillist-select session "nntp-root@example.org")
          (let ((tries 0) open)
            (while (and (< tries 100)
                        (progn
                          (setq open (etaf-value (plist-get session :open)))
                          (< (length (plist-get open :messages)) 3)))
              (sleep-for 0.05)
              (setq tries (1+ tries)))
            (should (= 3 (length (plist-get open :messages))))
            (should (equal (list "ARTICLE <nntp-reply2@example.org>")
                           (plist-get state :log))))
          ;; 4. Load older over NNTP fetches article #10.
          (maillist-load-older session)
          (maillist-tests--wait session)
          (should (maillist-row session "old-nntp@example.org")))
      (maillist-dispose session)
      (delete-process (cdr srv))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-nntp-falls-back-to-http-when-unreachable ()
  "An unreachable NNTP port falls back transparently to the HTTP archive."
  (let* ((dead-nntp (maillist-tests--closed-port))
         (file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-transport 'auto)
         (maillist-nntp-connect-timeout 1)
         (maillist-prefetch-threads 0)
         (maillist-prefetch-bodies 0)
         (maillist-sources
          (list (list :name "fallback"
                      :base (concat "file://" maillist-tests--fixtures "/")
                      :index "index.html"
                      :address "fixture@example.org"
                      :nntp (list :host "127.0.0.1" :port dead-nntp :group "dead.group"))))
         (session (maillist-create :list "fallback")))
    (unwind-protect
        (progn
          (maillist-refresh session)
          (let ((st (maillist-tests--wait session)))
            (should (eq 'idle (plist-get st :kind))))
          (should (= 4 (length (maillist-rows session))))
          (maillist-select session "alpha@example.com")
          (let ((open (maillist-tests--open session)))
            (should (= 3 (length (plist-get open :messages))))))
      (maillist-dispose session)
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-unchanged-cached-thread-opens-without-network ()
  "Reopening an unchanged cached thread in a fresh session makes zero network requests."
  (let* ((hits 0)
         (server (maillist-tests--server
                  (lambda (process chunk)
                    (let ((req (concat (or (process-get process :request) "") chunk)))
                      (process-put process :request req)
                      (when (string-match-p "\r\n\r\n" req)
                        (cl-incf hits)
                        (maillist-tests--answer-with process "" ""))))))
         (file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-prefetch-threads 0)
         (maillist-prefetch-bodies 0)
         (maillist-thread-freshness 60)
         (maillist-network-route 'direct)
         (url-proxy-services nil))
    (unwind-protect
        (progn
          ;; Populate the store from the fixture archive.
          (let* ((maillist-sources (list (maillist-tests--source)))
                 (s1 (maillist-create :list "fixture")))
            (unwind-protect
                (progn
                  (maillist-refresh s1)
                  (maillist-tests--wait s1)
                  (maillist-select s1 "alpha@example.com")
                  (maillist-tests--open s1))
              (maillist-dispose s1)))
          ;; Reopen in a brand-new session backed by the counting HTTP server.
          (let* ((maillist-sources
                  (list (list :name "fixture"
                              :base (format "http://127.0.0.1:%d/" (car server))
                              :address "fixture@example.org")))
                 (s2 (maillist-create :list "fixture")))
            (unwind-protect
                (progn
                  (maillist-select s2 "alpha@example.com")
                  (sleep-for 0.15)
                  (let ((open (etaf-value (plist-get s2 :open))))
                    (should (= 3 (length (plist-get open :messages))))
                    (should-not (plist-get open :refreshing))
                    (should (= 0 hits))))
              (maillist-dispose s2))))
      (delete-process (cdr server))
      (ignore-errors (delete-file file)))))

(ert-deftest maillist-tests-dead-proxy-falls-back-once-and-learns-direct-route ()
  "A dead proxy falls back once (no duplicate direct hits) and subsequent requests use direct."
  (let* ((hits 0)
         (page (maillist-tests--read "index.html"))
         (server (maillist-tests--server
                  (lambda (process chunk)
                    (let ((req (concat (or (process-get process :request) "") chunk)))
                      (process-put process :request req)
                      (when (string-match-p "\r\n\r\n" req)
                        (cl-incf hits)
                        (maillist-tests--answer-with process "" page))))))
         (dead (maillist-tests--closed-port))
         (maillist-proxy (format "127.0.0.1:%d" dead))
         (maillist-network-route 'proxy)
         (url-proxy-services nil)
         (source (list :name "sticky"
                       :base (format "http://127.0.0.1:%d/" (car server))
                       :address "sticky@example.org")))
    (unwind-protect
        (progn
          (let ((first (maillist-tests--answer
                        (lambda (cb) (maillist-fetch-index source cb)))))
            (should (eq :ok (car first)))
            (should (= 4 (length (cadr first))))
            (sleep-for 0.1)
            (should (= 1 hits)))
          (let ((second (maillist-tests--answer
                         (lambda (cb) (maillist-fetch-index source cb)))))
            (should (eq :ok (car second)))
            (should (= 2 hits))))
      (delete-process (cdr server)))))

(ert-deftest maillist-tests-body-prefetch-warms-unread-threads-in-background ()
  "Idle background body prefetch warms top uncached unread threads into SQLite."
  (let* ((art1
          (list :artnum 1
                :subject "First unread thread"
                :from "Alice <alice@example.org>"
                :date "Wed, 21 Oct 2026 09:00:00 +0000"
                :id "warm1@example.org"
                :refs ""
                :raw "From: Alice <alice@example.org>\nSubject: First unread thread\nDate: Wed, 21 Oct 2026 09:00:00 +0000\nMessage-ID: <warm1@example.org>\n\nBody one."))
         (art2
          (list :artnum 2
                :subject "Second unread thread"
                :from "Bob <bob@example.org>"
                :date "Wed, 21 Oct 2026 10:00:00 +0000"
                :id "warm2@example.org"
                :refs ""
                :raw "From: Bob <bob@example.org>\nSubject: Second unread thread\nDate: Wed, 21 Oct 2026 10:00:00 +0000\nMessage-ID: <warm2@example.org>\n\nBody two."))
         (state (list :group "warm.list" :articles (list art1 art2) :log nil))
         (srv (maillist-tests--nntp-server state))
         (file (maillist-tests--store))
         (maillist-store-file file)
         (maillist-transport 'auto)
         (maillist-prefetch-threads 0)
         (maillist-prefetch-bodies 2)
         (maillist-sources
          (list (list :name "warm"
                      :base "http://127.0.0.1:1/"
                      :address "warm@example.org"
                      :nntp (list :host "127.0.0.1" :port (car srv) :group "warm.list"))))
         (session (maillist-create :list "warm")))
    (unwind-protect
        (progn
          (maillist-refresh session)
          (maillist-tests--wait session)
          (let ((tries 0)
                (store (plist-get session :store)))
            (while (and (< tries 80)
                        (not (and (maillist-store-thread-messages store "warm1@example.org")
                                  (maillist-store-thread-messages store "warm2@example.org"))))
              (sleep-for 0.05)
              (setq tries (1+ tries)))
            (should (maillist-store-thread-messages store "warm1@example.org"))
            (should (maillist-store-thread-messages store "warm2@example.org"))))
      (maillist-dispose session)
      (delete-process (cdr srv))
      (ignore-errors (delete-file file)))))

(provide 'maillist-tests)
;;; maillist-tests.el ends here
