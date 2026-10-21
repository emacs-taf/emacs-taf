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

(defun maillist-tests--source ()
  "Return the archive source of the local fixture mirror."
  (list :name "fixture"
        :base (concat "file://" maillist-tests--fixtures "/")
        :index "index.html"
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

(provide 'maillist-tests)
;;; maillist-tests.el ends here
