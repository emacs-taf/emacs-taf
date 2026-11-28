;;; etaf-install-tests.el --- Public acceptance tests for etaf-install -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Public behavior acceptance tests for `etaf-install'.

;;; Code:

(require 'ert)
(require 'json)
(require 'package)
(require 'etaf-install)

(ert-deftest etaf-install-test-public-commands-are-interactive ()
  "Verify every documented user entry point is bound and interactive."
  (dolist (cmd '(etaf-install
                 etaf-install-doctor
                 etaf-install-manage
                 etaf-install-update
                 etaf-install-remove
                 etaf-install-native))
    (should (fboundp cmd))
    (should (commandp cmd)))
  (should (fboundp 'etaf-install-status))
  (should (fboundp 'etaf-install-ensure)))

(ert-deftest etaf-install-test-doctor-reports-required-and-optional-facts ()
  "Verify `etaf-install-doctor' returns structured capability facts offline."
  (let* ((facts (etaf-install-doctor 'etaf-ui))
         (required (plist-get facts :required)))
    (should (eq (plist-get facts :package) 'etaf-ui))
    (should (plist-member facts :ready))
    (should (listp required))
    (should (assoc "Emacs 29.1 or newer" required))
    (should (listp (plist-get facts :optional)))))

(ert-deftest etaf-install-test-status-returns-catalog-rows ()
  "Verify `etaf-install-status' reports structured rows for all and one target."
  (let ((package-alist nil)
        (package-archive-contents nil))
    (let ((all (etaf-install-status))
          (one (etaf-install-status 'etaf-ui)))
      (should (listp all))
      (should (> (length all) 5))
      (should (eq (plist-get one :package) 'etaf-ui))
      (should (eq (plist-get one :group) 'framework))
      (should (plist-member one :installed))
      (should (plist-member one :available))
      (should (plist-member one :system-cli)))))

(ert-deftest etaf-install-test-manifest-catalog-discovery ()
  "Verify targets declared in archive manifest.json are discovered dynamically."
  (let* ((dir (make-temp-file "etaf-install-catalog-" t))
         (manifest
          `((schema . 2)
            (packages . [((name . "etaf-demo")
                          (version . "0.1.0")
                          (file . "etaf-demo-0.1.0.tar")
                          (sha256 . "0000")
                          (summary . "Dynamic demo app")
                          (requirements . [ ["emacs" "29.1"] ]))])
            (catalog . ((etaf-demo
                         . ((group . "application")
                            (label . "Dynamic demo app")
                            (open . "etaf-demo-open")
                            (capabilities . ["sqlite"])
                            (system_tools . ((optional . ["git"]))))))))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "manifest.json" dir)
            (insert (json-encode manifest)))
          (let ((etaf-install-archive-url (file-name-as-directory dir))
                (package-alist nil)
                (package-archive-contents nil))
            (let ((row (etaf-install-status 'etaf-demo))
                  (facts (etaf-install-doctor 'etaf-demo)))
              (should (eq (plist-get row :package) 'etaf-demo))
              (should (eq (plist-get row :group) 'application))
              (should (equal (plist-get row :label) "Dynamic demo app"))
              (should (assq 'git (plist-get (plist-get row :system-cli) :optional)))
              (should (eq (plist-get facts :package) 'etaf-demo))
              (should (assoc "SQLite built into Emacs" (plist-get facts :required)))
              (should (assoc "git" (plist-get facts :optional))))))
      (delete-directory dir t))))

(ert-deftest etaf-install-test-ensure-declarative-lifecycle ()
  "Verify `etaf-install-ensure' installs missing targets and stays offline once installed."
  (let* ((tmp (make-temp-file "etaf-install-ensure-" t))
         (archive-dir (expand-file-name "archive" tmp))
         (user-dir (expand-file-name "elpa" tmp))
         (manifest
          `((schema . 2)
            (packages . [((name . "etaf-demo-ensure")
                          (version . "0.1.0")
                          (file . "etaf-demo-ensure-0.1.0.el")
                          (sha256 . "0000")
                          (summary . "Declarative demo")
                          (requirements . [ ["emacs" "29.1"] ]))])
            (catalog . ((etaf-demo-ensure
                         . ((group . "application")
                            (label . "Declarative demo")
                            (open . "etaf-demo-ensure-open"))))))))
    (unwind-protect
        (progn
          (make-directory archive-dir t)
          (make-directory user-dir t)
          (with-temp-file (expand-file-name "manifest.json" archive-dir)
            (insert (json-encode manifest)))
          (with-temp-file (expand-file-name "archive-contents" archive-dir)
            (insert "(1\n (etaf-demo-ensure . [(0 1 0) ((emacs (29 1))) \"Declarative demo\" single nil]))\n"))
          (with-temp-file (expand-file-name "etaf-demo-ensure-0.1.0.el" archive-dir)
            (insert ";;; etaf-demo-ensure.el --- Declarative demo -*- lexical-binding: t; -*-\n"
                    ";; Version: 0.1.0\n"
                    ";; Package-Requires: ((emacs \"29.1\"))\n"
                    ";;;###autoload\n"
                    "(defun etaf-demo-ensure-open () (interactive) 'opened)\n"
                    "(provide 'etaf-demo-ensure)\n"))
          (let ((etaf-install-archive-url (file-name-as-directory archive-dir))
                (etaf-install-auto-native nil)
                (package-user-dir user-dir)
                (package-archives nil)
                (package-alist nil)
                (package-archive-contents nil)
                (package-selected-packages nil)
                (package--initialized t)
                (load-path (copy-sequence load-path))
                (features (copy-sequence features)))
            ;; Invalid arguments fail before any network/archive access.
            (should-error (etaf-install-ensure "etaf-demo-ensure") :type 'user-error)
            (should-error (etaf-install-ensure '(t)) :type 'user-error)
            ;; Empty list is an offline no-op.
            (let ((refreshes 0))
              (cl-letf (((symbol-function 'package-refresh-contents)
                         (lambda (&rest _) (setq refreshes (1+ refreshes)))))
                (should (equal (etaf-install-ensure nil)
                               '(:installed nil :already nil
                                 :native-installed nil :native-failed nil)))
                (should (= refreshes 0))))
            ;; First run installs missing package without opening it.
            (let ((res (etaf-install-ensure '(etaf-demo-ensure))))
              (should (equal (plist-get res :installed) '(etaf-demo-ensure)))
              (should (null (plist-get res :already)))
              (should (package-installed-p 'etaf-demo-ensure))
              (should (equal (cdr (assoc "etaf" package-archives))
                             (file-name-as-directory archive-dir))))
            ;; Second run performs zero network refreshes.
            (let ((refreshes 0))
              (cl-letf (((symbol-function 'package-refresh-contents)
                         (lambda (&rest _) (setq refreshes (1+ refreshes)))))
                (let ((res (etaf-install-ensure 'etaf-demo-ensure)))
                  (should (null (plist-get res :installed)))
                  (should (equal (plist-get res :already) '(etaf-demo-ensure)))
                  (should (= refreshes 0)))))))
      (delete-directory tmp t))))

(provide 'etaf-install-tests)
;;; etaf-install-tests.el ends here
