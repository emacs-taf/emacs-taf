;;; ebox-package-lint.el --- Batch package-lint entry point -*- lexical-binding: t; -*-

(require 'package)

(defconst ebox-package-lint--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root for package lint.")

(defun ebox-package-lint--install-requested-p ()
  "Return non-nil when package-lint should be installed if missing."
  (getenv "EBOX_PACKAGE_LINT_INSTALL"))

(defun ebox-package-lint--ensure-package ()
  "Ensure package-lint is available.
When `EBOX_PACKAGE_LINT_INSTALL' is set, install it through package archives.
Otherwise, skip cleanly if package-lint is not already available."
  (unless (require 'package-lint nil t)
    (if (not (ebox-package-lint--install-requested-p))
        (progn
          (message "package-lint is not on load-path; set EBOX_PACKAGE_LINT_INSTALL=1 to install it.")
          (kill-emacs 0))
      (setq package-user-dir
            (or (getenv "EBOX_PACKAGE_LINT_DIR")
                (expand-file-name "ebox-package-lint" temporary-file-directory)))
      (setq package-archives
            '(("gnu" . "https://elpa.gnu.org/packages/")
              ("melpa" . "https://melpa.org/packages/")))
      (package-initialize)
      (unless package-archive-contents
        (package-refresh-contents))
      (unless (package-installed-p 'package-lint)
        (package-install 'package-lint))
      (require 'package-lint))))

;;;###autoload
(defun ebox-package-lint-batch ()
  "Run package-lint against ebox.el in batch mode."
  (ebox-package-lint--ensure-package)
  (let ((command-line-args-left
         (list (expand-file-name "ebox.el" ebox-package-lint--root))))
    (package-lint-batch-and-exit)))

(provide 'ebox-package-lint)
;;; ebox-package-lint.el ends here
