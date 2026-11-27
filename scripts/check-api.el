;;; check-api.el --- Verify declared public entry bindings -*- lexical-binding: t; -*-

;;; Commentary:
;; Run in a fresh batch Emacs with the package and provider roots on load-path.
;; The root entry Commentary is the only public API inventory.

;;; Code:
(require 'cl-lib)
  (let* ((root default-directory)
         (entry (car (directory-files root t "\\`[^.][^/]*\\.el\\'")))
         (count 0)
         (signatures (make-hash-table :test #'eq))
         (defined-commands (make-hash-table :test #'eq))
         (declared-functions (make-hash-table :test #'eq)))
    (unless entry (error "Missing root entry"))
    (load-file entry)
    ;; Compare written signatures with maintained definitions, including cl-defun
    ;; keyword/default arguments that byte-code introspection can lose.
    (dolist (file (cons entry
                        (when (file-directory-p (expand-file-name "lisp" root))
                          (directory-files (expand-file-name "lisp" root) t "\\.el\\'"))))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case nil
            (while t
              (let* ((form (read (current-buffer)))
                     (head (car-safe form))
                     (sym (nth 1 form)))
                (cond
                 ((memq head '(defun cl-defun defmacro cl-defmacro defsubst))
                  (puthash sym (cons t (nth 2 form)) signatures)
                  (when (memq head '(defun cl-defun))
                    (puthash sym t defined-commands)))
                 ((memq head '(define-derived-mode define-minor-mode
                               define-globalized-minor-mode define-generic-mode))
                  (when (symbolp sym)
                    (puthash sym t defined-commands)))
                 ((and (eq head 'defalias)
                       (eq (car-safe sym) 'quote)
                       (symbolp (cadr sym)))
                  (puthash (cadr sym) t defined-commands)))))
          (end-of-file nil))))
    (with-temp-buffer
      (insert-file-contents entry)
      (goto-char (point-min))
      (let ((end (save-excursion (search-forward ";;; Code:"))))
        (while (re-search-forward
                "^;; \\(Function\\|Macro\\|Variable\\|Hook\\|Error\\|Component\\): \\([^ ()\n]+\\)\\(.*\\)$" end t)
          (let* ((kind (match-string 1))
                 (symbol (intern (match-string 2)))
                 (signature (match-string 3))
                 (valid
                  (pcase kind
                    ("Function" (and (fboundp symbol) (not (macrop symbol))))
                    ("Macro" (macrop symbol))
                    ((or "Variable" "Hook") (boundp symbol))
                    ("Error" (get symbol 'error-conditions))
                    ("Component" (boundp (intern (format "%s--etaf-component-definition" symbol)))))))
            (unless valid (error "Declared %s %s is unavailable after loading the entry" kind symbol))
            (when (equal kind "Function")
              (puthash symbol t declared-functions))
            (when-let* ((definition (gethash symbol signatures)))
              (when (member kind '("Function" "Macro"))
                (unless (equal (read signature) (cdr definition))
                  (error "Public signature drift for %s: documented %s, defined %S"
                         symbol signature (cdr definition)))))
            (cl-incf count)))))
    (when (zerop count) (error "Empty public API inventory"))
    ;; Reject private (`--') or undeclared interactive commands/modes, because
    ;; Emacs M-x completes every named `commandp' symbol regardless of dashes.
    (let (private-commands undeclared-commands)
      (maphash (lambda (symbol _v)
                 (when (commandp symbol)
                   (cond
                    ((string-match-p "--" (symbol-name symbol))
                     (push symbol private-commands))
                    ((not (gethash symbol declared-functions))
                     (push symbol undeclared-commands)))))
               defined-commands)
      (when private-commands
        (error "Private interactive command(s) leak into M-x: %s (remove `(interactive)' / pass `:interactive nil' to internal modes, and wrap keymap handlers in anonymous lambdas or uninterned `make-symbol' commands)"
               (mapconcat #'symbol-name
                          (sort private-commands (lambda (a b)
                                                   (string< (symbol-name a)
                                                            (symbol-name b))))
                          ", ")))
      (when undeclared-commands
        (error "Undeclared interactive command(s) leak into M-x: %s (either declare in root Commentary as `;; Function:' or make non-interactive)"
               (mapconcat #'symbol-name
                          (sort undeclared-commands (lambda (a b)
                                                      (string< (symbol-name a)
                                                               (symbol-name b))))
                          ", "))))
    (message "Public entry API: %d declarations verified" count))
;;; check-api.el ends here
