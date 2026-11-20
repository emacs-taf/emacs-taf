;;; etaf-process-tests.el --- Run-to-completion subprocesses -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(defun etaf-process-test-run (command &rest options)
  "Run COMMAND with OPTIONS and return its result plist, waiting up to 5 s."
  (let* ((results nil)
         (job (apply #'etaf-process-run command
                     :callback (lambda (result) (push result results))
                     options))
         (deadline (+ (float-time) 5)))
    ;; The callback never runs before `etaf-process-run' returns.
    (should-not results)
    (while (and (null results) (< (float-time) deadline))
      (sleep-for 0.02))
    (sleep-for 0.1)
    (should (= (length results) 1))
    (should-not (etaf-process-live-p job))
    (car results)))

(ert-deftest etaf-process-run-reads-both-streams-after-exit ()
  "A finished command reports its exit code, stdout and stderr in full."
  (let ((result (etaf-process-test-run
                 '("sh" "-c" "printf hello; printf oops >&2; exit 3"))))
    (should (eq (plist-get result :status) 'exit))
    (should (= (plist-get result :exit) 3))
    (should (equal (plist-get result :output) "hello"))
    (should (equal (plist-get result :stderr) "oops"))))

(ert-deftest etaf-process-run-parses-json-output ()
  "JSON output arrives as plists and lists; invalid JSON arrives as nil."
  (should (equal (plist-get (etaf-process-test-run
                             '("sh" "-c" "printf '{\"a\":1,\"b\":null,\"c\":false,\"d\":[1,2]}\\n'")
                             :output 'json)
                            :output)
                 '(:a 1 :b nil :c :false :d (1 2))))
  (should-not (plist-get (etaf-process-test-run '("sh" "-c" "printf 'not json'")
                                                :output 'json)
                         :output)))

(ert-deftest etaf-process-run-applies-environment-and-directory ()
  "ENVIRONMENT overrides variables and DIRECTORY sets the working directory."
  (let* ((directory (file-truename (make-temp-file "etaf-process" t)))
         (result (unwind-protect
                     (etaf-process-test-run
                      '("sh" "-c" "printf '%s:%s' \"$ETAF_PROCESS_TEST\" \"$(pwd -P)\"")
                      :environment '("ETAF_PROCESS_TEST=yes")
                      :directory directory)
                   (delete-directory directory))))
    (should (equal (plist-get result :output)
                   (concat "yes:" (directory-file-name directory))))))

(ert-deftest etaf-process-run-times-out-and-reports-failures ()
  "A timeout stops the process; a missing program settles as `failed'."
  (let ((result (etaf-process-test-run '("sleep" "5") :timeout 0.2)))
    (should (eq (plist-get result :status) 'timeout))
    (should (stringp (plist-get result :message))))
  (let ((result (etaf-process-test-run '("etaf-process-test-missing-program"))))
    (should (eq (plist-get result :status) 'failed))
    (should (stringp (plist-get result :message)))))

(ert-deftest etaf-process-cancel-never-calls-back ()
  "Cancelling a running or failed job suppresses its callback."
  (dolist (command '(("sleep" "5") ("etaf-process-test-missing-program")))
    (let* ((called nil)
           (job (etaf-process-run command :callback (lambda (_) (setq called t)))))
      (should (etaf-process-live-p job))
      (should (etaf-process-cancel job))
      (should-not (etaf-process-cancel job))
      (should-not (etaf-process-live-p job))
      (sleep-for 0.2)
      (should-not called))))

;;; etaf-process-tests.el ends here
