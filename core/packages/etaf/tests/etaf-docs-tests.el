;;; etaf-docs-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'json)
(require 'macroexp)

(defconst etaf-docs-test--root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name
                                                 buffer-file-name))))
  "Absolute path of the ETAF repository under test.")

(defun etaf-docs-test--read (relative-file)
  "Return the contents of RELATIVE-FILE in the repository."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file etaf-docs-test--root))
    (buffer-string)))

(defun etaf-docs-test--marked-examples (contents)
  "Extract named executable documentation examples from CONTENTS."
  (with-temp-buffer
    (insert contents)
    (goto-char (point-min))
    (let (examples)
      (while (re-search-forward
              "^<!-- etaf-example: \\([^ ]+\\) -->\n```elisp\n" nil t)
        (let ((name (match-string 1))
              (start (point)))
          (unless (re-search-forward "^```$" nil t)
            (error "Unclosed executable example %s" name))
          (push (cons name (buffer-substring-no-properties
                            start (match-beginning 0)))
                examples)))
      (nreverse examples))))

(defun etaf-docs-test--run-fresh (source assertions)
  "Run exact example SOURCE and ASSERTIONS in a fresh core-only Emacs."
  (let ((script (make-temp-file "etaf-readme-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert source "\n")
            (prin1 assertions (current-buffer))
            (insert "\n(should-not (featurep 'etaf-ui))\n"
                    "(should-not (featurep 'etaf-playground))\n"))
          (with-temp-buffer
            (let ((status
                   (apply #'call-process
                          (expand-file-name invocation-name invocation-directory)
                          nil (current-buffer) nil "-Q" "--batch"
                          (append
                           (cl-loop for directory in '("." "../ebox"
                                                       "../ecss")
                                    append (list "-L" (expand-file-name
                                                       directory
                                                       etaf-docs-test--root)))
                           (list "--eval"
                                 (prin1-to-string
                                  '(progn
                                     (require 'ert)
                                     (require 'jka-compr)
                                     (setq load-suffixes '(".el" ".elc")
                                           load-prefer-newer t)))
                                 "-l" script)))))
              (unless (equal status 0)
                (ert-fail (format "Documentation child exited %S:\n%s"
                                  status (buffer-string)))))))
      (delete-file script))))

(ert-deftest etaf-docs-readme-examples-mount-and-dispatch-in-fresh-emacs ()
  "Both READMEs must work from their exact requires in isolated processes."
  (dolist (file '("README.md" "README.zh-CN.md"))
    (let ((examples (etaf-docs-test--marked-examples
                     (etaf-docs-test--read file))))
      (should (equal '("hello" "card" "counter") (mapcar #'car examples)))
      (dolist (example examples)
        (etaf-docs-test--run-fresh
         (cdr example)
         (pcase (car example)
           ("hello"
            '(let ((runtime (etaf-runtime-for-buffer "*etaf-hello*")))
               (should runtime)
               (should (equal "Hello ETAF"
                              (etaf-dispatch-event runtime 'hello 'press)))
               (etaf-unmount runtime)))
           ("card"
            '(let ((runtime (etaf-runtime-for-buffer "*etaf-card*")))
               (should runtime)
               (with-current-buffer "*etaf-card*"
                 (should (string-match-p
                          "Account[[:space:]]+Connected[[:space:]]+Footer"
                          (buffer-string))))
               (etaf-unmount runtime)))
           ("counter"
            '(let ((runtime (etaf-runtime-for-buffer "*etaf-counter*")))
               (should runtime)
               (etaf-focus-next runtime)
               (etaf-activate runtime)
               (with-current-buffer "*etaf-counter*"
                 (should (string-match-p "Count: 1" (buffer-string))))
               (etaf-unmount runtime)))))))))

(provide 'etaf-docs-tests)
;;; etaf-docs-tests.el ends here
