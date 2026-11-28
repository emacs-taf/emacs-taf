;;; etaf-actions.el --- Named ETAF mutation actions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An Action is one named, testable business mutation entry.  It is not a
;; View node and does not own rendering; the current Runtime owns the event
;; boundary and reactive values own publication after an action mutates them.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)
(require 'etaf-runtime)

(defvar etaf--current-runtime)
(defvar etaf--observer-context)

(declare-function etaf-runtime-observer "etaf-runtime" (runtime))
(declare-function etaf-runtime-call-operation
                  "etaf-runtime" (runtime kind label function))

(define-error 'etaf-action-error "Invalid ETAF Action")

(cl-defstruct (etaf-action-spec
               (:constructor etaf--action-spec-create))
  "Registered named Action."
  name
  function)

(defvar etaf--action-registry (make-hash-table :test #'eq)
  "Action name -> `etaf-action-spec' table.")

(defvar etaf--allow-action-redefinition nil
  "Non-nil only inside `etaf-action-redefine-run'.")

(defun etaf--action-assert-definition-available (name)
  "Signal when Action NAME cannot be defined in the current boundary."
  (when (and (gethash name etaf--action-registry)
             (not etaf--allow-action-redefinition))
    (signal 'etaf-action-error
            (list (format "Duplicate ETAF Action: %S" name)))))

(defun etaf-action-register (name function)
  "Register FUNCTION as named Action NAME and return NAME."
  (etaf--assert-not-rendering 'register-action)
  (unless (and (symbolp name) (not (keywordp name)) (functionp function))
    (signal 'etaf-action-error
            (list (format "Invalid Action registration: %S" name))))
  (etaf--action-assert-definition-available name)
  (puthash name (etaf--action-spec-create :name name :function function)
           etaf--action-registry)
  name)

(defmacro etaf-action-define (name arguments &rest body)
  "Define and register named Action NAME with ARGUMENTS and BODY.

The generated function receives RUNTIME as its first argument when called
through `etaf-dispatch'."
  (declare (indent 2) (debug defun))
  (unless (symbolp name)
    (signal 'etaf-action-error (list "Action name must be a symbol")))
  (let ((docstring (when (stringp (car body)) (pop body)))
        (function-symbol (intern (format "%s--etaf-action" name))))
    `(progn
       (etaf--action-assert-definition-available ',name)
       (defun ,function-symbol ,arguments
         ,(or docstring (format "Run ETAF Action `%s'." name))
         ,@body)
       (etaf-action-register ',name #',function-symbol)
       ',name)))

;;;###autoload
(defun etaf-action-redefine-run (function)
  "Run FUNCTION while allowing intentional Action redefinition.

Normal duplicate registrations remain errors.  This dynamic authoring
boundary replaces only the process-global name binding used by future
`etaf-dispatch' calls; it does not flush or rerender mounted Runtimes."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let ((etaf--allow-action-redefinition t))
    (funcall function)))

;;;###autoload
(defun etaf-dispatch (action &rest arguments)
  "Dispatch named ACTION through the active Runtime with ARGUMENTS.

An explicit Runtime may be supplied as the first argument: `(etaf-dispatch
RUNTIME ACTION ...)'.  Action functions receive Runtime first."
  (etaf--assert-not-rendering 'dispatch-action)
  (let* ((explicit-runtime (etaf-runtime-p action))
         (runtime (if explicit-runtime
                      action
                    (and (boundp 'etaf--current-runtime)
                         etaf--current-runtime)))
         (action (if explicit-runtime
                     (pop arguments)
                   action))
         (spec (gethash action etaf--action-registry)))
    (unless (symbolp action)
      (signal 'etaf-action-error
              (list "Action name must be a symbol")))
    (unless (and runtime (etaf-runtime-p runtime)
                 (etaf-runtime-mounted-p runtime))
      (signal 'etaf-runtime-error
              (list "ETAF runtime is not mounted")))
    (unless spec
      (signal 'etaf-action-error
              (list (format "Unknown ETAF Action: %S" action))))
    (let ((run
           (lambda ()
             (etaf-call-with-batch
              (lambda ()
                (let ((etaf--current-runtime runtime))
                  (apply (etaf-action-spec-function spec)
                         runtime arguments)))))))
      (if (or etaf--observer-context (etaf-runtime-observer runtime))
          (etaf-runtime-call-operation
           runtime 'action (format "%S" action) run)
        (funcall run)))))

;;;###autoload
(defun etaf-action-undefine (name)
  "Remove named Action NAME and return NAME."
  (etaf--assert-not-rendering 'undefine-action)
  (remhash name etaf--action-registry)
  name)

(provide 'etaf-actions)

;;; etaf-actions.el ends here
