;;; etaf-ui-docs-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf-ui)

(defconst etaf-ui-docs-test--root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name
                                                 buffer-file-name))))
  "Absolute path of the UI repository under test.")

(defun etaf-ui-docs-test--example (file)
  "Extract the complete marked preferences example from README FILE."
  (with-temp-buffer
    (insert-file-contents (expand-file-name
       (if (and (string-suffix-p ".el" file) (not (file-name-directory file)))
           (concat "lisp/" file) file) etaf-ui-docs-test--root))
    (goto-char (point-min))
    (should (search-forward
             "<!-- etaf-example: preferences -->\n```elisp\n" nil t))
    (let ((start (point)))
      (should (re-search-forward "^```$" nil t))
      (buffer-substring-no-properties start (match-beginning 0)))))

(defun etaf-ui-docs-test--run-fresh (source)
  "Mount exact README SOURCE and exercise its controls in a fresh Emacs."
  (let ((script (make-temp-file "etaf-ui-readme-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert source "\n")
            (prin1
             '(let ((runtime (etaf-runtime-for-buffer "*etaf-preferences*")))
                (should runtime)
                (with-current-buffer "*etaf-preferences*"
                  (should (string-match-p "Pending" (buffer-string)))
                  (should (string-match-p "Unsaved" (buffer-string))))
                (etaf-dispatch-event runtime 'done-checkbox 'press)
                ;; The NumberInput is edited natively in the application buffer:
                ;; replace its "3" with "7" as the user would, then submit.
                (etaf-dispatch-event runtime 'rows-input 'press)
                (should (etaf-text-input-active-p runtime))
                (switch-to-buffer "*etaf-preferences*")
                (execute-kbd-macro (kbd "DEL 7 RET"))
                (should-not (etaf-text-input-active-p runtime))
                (etaf-dispatch-event runtime 'save-button 'press)
                (with-current-buffer "*etaf-preferences*"
                  (should (string-match-p "Complete" (buffer-string)))
                  (should (string-match-p "Rows[^0-9]*7" (buffer-string)))
                  (should (string-match-p "Saved" (buffer-string))))
                (etaf-dispatch-event runtime 'done-checkbox 'press)
                (with-current-buffer "*etaf-preferences*"
                  (should (string-match-p "Pending" (buffer-string))))
                (should-not (featurep 'etaf-playground))
                (etaf-unmount runtime))
             (current-buffer)))
          (with-temp-buffer
            (let ((status
                   (apply #'call-process
                          (expand-file-name invocation-name invocation-directory)
                          nil (current-buffer) nil "-Q" "--batch"
                          (append
                           (cl-loop for directory in '("." "../etaf" "../ebox"
                                                       "../ecss")
                                    append (list "-L" (expand-file-name
                                                       directory
                                                       etaf-ui-docs-test--root)))
                           (list "--eval"
                                 (prin1-to-string
                                  '(progn
                                     (require 'ert)
                                     (require 'jka-compr)
                                     (setq load-suffixes '(".el" ".elc")
                                           load-prefer-newer t)))
                                 "-l" script)))))
              (unless (equal status 0)
                (ert-fail (format "UI README child exited %S:\n%s"
                                  status (buffer-string)))))))
      (delete-file script))))

(ert-deftest etaf-ui-docs-readmes-mount-and-dispatch-in-fresh-emacs ()
  "Both catalog READMEs use real names and complete mounted interactions."
  (dolist (file '("README.md" "README.zh-CN.md"))
    (etaf-ui-docs-test--run-fresh (etaf-ui-docs-test--example file))))

(provide 'etaf-ui-docs-tests)
;;; etaf-ui-docs-tests.el ends here
