;;; ecss-file.el --- Static rule data for ECSS -*- lexical-binding: t; -*-

;;; Commentary:
;; A `.ecss' file contains one unevaluated rule list, without a quote wrapper:
;; ((".card" :color "red") ("& > .title" :font-weight bold))
;; Consumers validate property values through their own schemas.

;;; Code:

(require 'ecss-cascade)
(require 'elisp-mode)
(defvar read-eval)

(defun ecss-validate-rules (rules)
  "Validate ordered static RULES and return them without evaluating values.
RULES is a proper list of (SELECTOR PROPERTY VALUE ...) rules.  SELECTOR is
an ECSS selector string; PROPERTY is a non-nil symbol.  Empty lists and
empty declarations are allowed.  Property names and values are validated
later against the consumer's schema.  No input is mutated."
  (unless (proper-list-p rules)
    (user-error "ECSS rules must be a proper list"))
  (dolist (rule rules)
    (unless (and (consp rule) (proper-list-p rule) (stringp (car rule))
                 (zerop (% (length (cdr rule)) 2)))
      (user-error "Invalid ECSS rule: %S" rule))
    (ecss-selector-parse (car rule))
    (cl-loop for (property _value) on (cdr rule) by #'cddr
             unless (and property (symbolp property))
             do (user-error "ECSS property must be a non-nil symbol: %S" property)))
  rules)

(defun ecss-read-rules (source)
  "Read exactly one inert rule list from string SOURCE.
Comments and whitespace are allowed around the list.  Empty input,
wrappers, trailing expressions and malformed rules are rejected.  This
never evaluates Lisp or calls declaration values.  Property semantics are
validated by the consumer's schema after reading."
  (with-temp-buffer
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (insert source)
    (goto-char (point-min))
    (let* ((read-eval nil)
           (form (read (current-buffer))))
      (forward-comment (point-max))
      (unless (eobp)
        (user-error "ECSS source must contain one rule list"))
      (ecss-validate-rules form))))

(defun ecss-file-read (file)
  "Read FILE as one inert rule list through `ecss-read-rules'.
FILE must be readable.  Return the rules in source order; no outer quote
or styles wrapper is accepted.  No declaration value is evaluated."
  (unless (file-readable-p file)
    (user-error "ECSS file is not readable: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (ecss-read-rules (buffer-string))))

(provide 'ecss-file)
;;; ecss-file.el ends here
