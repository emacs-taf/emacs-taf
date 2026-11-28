;;; etaf-observer.el --- Scoped ETAF Runtime observation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file defines the deliberately small observation port used by the ETAF
;; Runtime.  Observation is scoped to one dynamic operation; it is neither a
;; global subscription service nor publication authority.  When no context is
;; active, instrumented stages execute their original body directly.

;;; Code:

(require 'cl-lib)

(define-error 'etaf-observer-error "Invalid ETAF observer operation")

(defconst etaf-observer-report-format-version 1
  "Format version of flat ETAF observation reports.")

(defconst etaf--observer-context-keys
  '(:format-version :operation-id :sequence :runtime-id :buffer-name)
  "Report fields owned exclusively by the active operation context.")

(cl-defstruct (etaf--observer-context
               (:constructor etaf--observer-context--make))
  "Dynamic observation state for one ETAF Runtime operation."
  sink
  operation-id
  runtime-id
  buffer-name
  (sequence 0)
  diagnostic)

(defvar etaf--observer-context nil
  "Dynamically active ETAF observation context, or nil.")

(defun etaf--observer-provider-report-valid-p (report)
  "Return non-nil when REPORT is a valid provider report."
  (and (proper-list-p report)
       (zerop (% (length report) 2))
       (let ((tail report)
             keys
             valid)
         (setq valid t)
         (while (and tail valid)
           (let ((key (pop tail)))
             (pop tail)
             (setq valid
                   (and (keywordp key)
                        (not (memq key keys))
                        (not (memq key etaf--observer-context-keys))))
             (push key keys)))
         (and valid
              (plist-member report :provider)
              (let ((provider (plist-get report :provider)))
                (and provider (symbolp provider) (not (keywordp provider))))
              (plist-member report :stage)
              (let ((stage (plist-get report :stage)))
                (and stage (symbolp stage) (not (keywordp stage))))
              (or (not (plist-member report :status))
                  (memq (plist-get report :status) '(success error quit)))
              (plist-member report :duration-ms)
              (numberp (plist-get report :duration-ms))
              (>= (plist-get report :duration-ms) 0)))))

(defun etaf--observer-copy-value (value)
  "Return a defensive observation copy of VALUE."
  (cond
   ((stringp value) (copy-sequence value))
   ((consp value)
    (cons (etaf--observer-copy-value (car value))
          (etaf--observer-copy-value (cdr value))))
   ((vectorp value)
    (apply #'vector
           (mapcar #'etaf--observer-copy-value (append value nil))))
   (t value)))

(defun etaf--observer-report-copy (report)
  "Return an isolated snapshot of validated provider REPORT."
  (etaf--observer-copy-value report))

(defun etaf--observer-diagnose (kind condition)
  "Contain KIND and CONDITION with the active context diagnostic sink."
  (when-let* ((context etaf--observer-context)
              (diagnostic (etaf--observer-context-diagnostic context)))
    (let ((inhibit-quit t)
          (quit-flag nil))
      (condition-case nil
          (funcall diagnostic
                   (list :kind kind :condition (copy-tree condition)))
        ((error quit) nil))))
  nil)

(cl-defun etaf--observer-context-create
    (&key sink operation-id runtime-id buffer-name diagnostic)
  "Create scoped observer state for one Runtime operation.

SINK receives one defensive report snapshot.  OPERATION-ID and RUNTIME-ID are
stable scalar identities, BUFFER-NAME is a string or nil, and DIAGNOSTIC
receives contained observer-port failures.  This internal constructor is the
only Runtime entry point that allocates observation state."
  (unless (functionp sink)
    (signal 'etaf-observer-error '(Observer sink must be a function)))
  (unless (integerp operation-id)
    (signal 'etaf-observer-error '(Operation identity must be an integer)))
  (unless (integerp runtime-id)
    (signal 'etaf-observer-error '(Runtime identity must be an integer)))
  (unless (or (null buffer-name) (stringp buffer-name))
    (signal 'etaf-observer-error '(Buffer name must be a string or nil)))
  (unless (functionp diagnostic)
    (signal 'etaf-observer-error '(Diagnostic sink must be a function)))
  (etaf--observer-context--make
   :sink sink
   :operation-id operation-id
   :runtime-id runtime-id
   :buffer-name (and buffer-name (copy-sequence buffer-name))
   :diagnostic diagnostic))

(defun etaf--observer-call-with-context (context function)
  "Call FUNCTION with internal observer CONTEXT dynamically active."
  (unless (etaf--observer-context-p context)
    (signal 'etaf-observer-error '(Invalid observer context)))
  (unless (functionp function)
    (signal 'etaf-observer-error '(Observed operation must be a function)))
  (let ((etaf--observer-context context))
    (funcall function)))

(defun etaf-observer-emit (report)
  "Decorate and deliver immutable provider REPORT in the active context.

The observer receives a defensive copy.  Observer errors, quits, and invalid
reports are contained by the context diagnostic sink and never affect product
execution.  The dynamic context is cleared during delivery so an observer can
reenter ETAF without recursively observing itself."
  (when etaf--observer-context
    (if (not (etaf--observer-provider-report-valid-p report))
        (etaf--observer-diagnose 'invalid-report report)
      (let* ((context etaf--observer-context)
             (sequence (1+ (etaf--observer-context-sequence context)))
             (sink (etaf--observer-context-sink context))
             (provider-report (etaf--observer-report-copy report))
             (snapshot
              (append
               (list :format-version etaf-observer-report-format-version
                     :operation-id
                     (etaf--observer-context-operation-id context)
                     :sequence sequence
                     :runtime-id (etaf--observer-context-runtime-id context)
                     :buffer-name
                     (etaf--observer-copy-value
                      (etaf--observer-context-buffer-name context)))
               provider-report
               (unless (plist-member provider-report :status)
                 (list :status 'success))))
            (inhibit-quit t)
            (quit-flag nil))
        (setf (etaf--observer-context-sequence context) sequence)
        (condition-case condition
            (let ((etaf--observer-context nil))
              (funcall sink snapshot))
          ((error quit)
           (etaf--observer-diagnose 'observer-failure condition))))))
  nil)

(defun etaf--observer-finish-stage (provider stage metadata status started)
  "Emit PROVIDER STAGE with METADATA, STATUS, and STARTED timestamp."
  (let ((duration-ms (max 0.0 (* 1000.0 (- (float-time) started)))))
    (etaf-observer-emit
     (append (list :provider provider :stage stage :status status
                   :duration-ms duration-ms)
             metadata))))

(defun etaf--observer-call-stage (provider stage metadata function)
  "Call observed PROVIDER STAGE FUNCTION with METADATA."
  (let ((started (float-time)))
    (condition-case condition
        (prog1 (funcall function)
          (etaf--observer-finish-stage
           provider stage metadata 'success started))
      (quit
       (etaf--observer-finish-stage provider stage metadata 'quit started)
       (signal (car condition) (cdr condition)))
      (error
       (etaf--observer-finish-stage provider stage metadata 'error started)
       (signal (car condition) (cdr condition))))))

(cl-defmacro etaf-observer-with-stage
    ((provider stage &rest metadata) &rest body)
  "Execute BODY as PROVIDER STAGE with optional METADATA.

The nil path is a single branch directly to BODY: it takes no timestamp,
allocates no closure or report, and reads no garbage-collection state."
  (declare (indent 1) (debug ((form form &rest form) body)))
  `(if (null etaf--observer-context)
       (progn ,@body)
     (etaf--observer-call-stage
      ,provider ,stage (list ,@metadata) (lambda () ,@body))))

(provide 'etaf-observer)

;;; etaf-observer.el ends here
