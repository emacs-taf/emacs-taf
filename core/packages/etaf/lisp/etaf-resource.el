;;; etaf-resource.el --- Resource state and error boundary -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Resources own loaded values and their cleanup in one Scope.  Synchronous
;; and asynchronous work uses the shared loader lifecycle.  Completion writes
;; one reactive state cell; rendering and cleanup errors retain their own
;; boundaries rather than being treated as external loader failures.

;;; Code:

(require 'cl-lib)
(require 'etaf-observer)
(require 'etaf-reactive)
(require 'etaf-async)

(define-error 'etaf-resource-error "Invalid ETAF Resource operation"
  'etaf-reactive-error)

(cl-defstruct (etaf-resource
               (:constructor etaf--resource-create))
  "A Scope-owned resource with one current loader request."
  loader
  state
  scope
  cleanup
  name
  request
  timeout
  keep-value
  has-value-p
  (active-p t))

(cl-defstruct (etaf-resource-result
               (:constructor etaf--resource-result-create))
  "A Resource loader result with VALUE and optional CLEANUP."
  value
  cleanup)

(defun etaf--resource-state (status value error)
  "Return a Resource state plist for STATUS, VALUE, and ERROR."
  (list :status status :value value :error error))

(defun etaf--resource-parent-scope (scope)
  "Return explicit SCOPE or the current active Scope."
  (or scope (etaf-current-effect-scope)))

(defun etaf--resource-child-scope (scope name)
  "Create a Resource Scope named NAME under SCOPE when present, otherwise detached."
  (if scope
      (etaf-scope-run scope
       (lambda () (etaf-effect-scope :name name)))
    (etaf-effect-scope :detached t :name name)))

(defun etaf--resource-require-active (resource)
  "Return active RESOURCE or signal a Resource error."
  (unless (and (etaf-resource-p resource)
               (etaf-resource-active-p resource))
    (signal 'etaf-resource-error
            (list "ETAF Resource is not active")))
  resource)

(defun etaf--resource-set-state (resource status value error)
  "Set RESOURCE state to STATUS, VALUE, and ERROR."
  (setf (etaf-value (etaf-resource-state resource))
        (etaf--resource-state status value error)))

(defun etaf--resource-run-cleanup (resource)
  "Run RESOURCE's current cleanup once."
  (when-let* ((cleanup (etaf-resource-cleanup resource)))
    (setf (etaf-resource-cleanup resource) nil)
    (funcall cleanup)))

(defun etaf--resource-normalize-result (result)
  "Return (VALUE CLEANUP) from loader RESULT."
  (if (etaf-resource-result-p result)
      (list (etaf-resource-result-value result)
            (etaf-resource-result-cleanup result))
    (list result nil)))

;;;###autoload
(cl-defun etaf-resource-result (value &key cleanup)
  "Return a Resource loader result containing VALUE and optional CLEANUP.

CLEANUP must be nil or a zero-argument function.  The Resource runs it when
clearing or replacing the value and on disposal.  A first completion arriving
after cancellation is discarded and cleaned up; duplicate completions are
ignored.  A loader must transfer each result to only one Resource."
  (when (and cleanup (not (functionp cleanup)))
    (signal 'wrong-type-argument (list 'functionp cleanup)))
  (etaf--resource-result-create :value value :cleanup cleanup))

;;;###autoload
(cl-defun etaf-resource (loader &key (immediate t) scope name timeout keep-value)
  "Create a Scope-owned Resource backed by LOADER.
LOADER returns a value, `etaf-resource-result', or an `etaf-async'
operation.
IMMEDIATE starts loading before returning; otherwise status starts as `idle'.
TIMEOUT is nil or positive seconds, applied to asynchronous waiting only.
With KEEP-VALUE non-nil, reload reports `refreshing' and retains the last
successful value until a replacement succeeds.  Failure or cancellation also
retains it.  Otherwise reload clears and cleans up the old value immediately.
The Resource owns a child Scope under SCOPE or the current Scope; without a
parent it is detached and the caller must dispose it."
  (etaf--assert-not-rendering 'create-resource)
  (unless (functionp loader)
    (signal 'wrong-type-argument (list 'functionp loader)))
  (etaf--load-check-timeout timeout)
  (let* ((parent (etaf--resource-parent-scope scope))
         (owned-scope (etaf--resource-child-scope parent name))
         resource)
    (setq resource
          (etaf--resource-create
           :loader loader :timeout timeout :keep-value keep-value
           :state (etaf-ref (etaf--resource-state 'idle nil nil) :name name)
           :scope owned-scope :name name))
    (etaf-scope-run
     owned-scope
     (lambda ()
       (etaf-on-scope-dispose
        (lambda ()
          (setf (etaf-resource-active-p resource) nil)
          (unwind-protect
              (etaf--load-abort (etaf-resource-request resource))
            (setf (etaf-resource-request resource) nil)
            (etaf--resource-run-cleanup resource))))))
    (condition-case err
        (progn (when immediate (etaf-resource-load resource)) resource)
      ((error quit)
       (etaf-resource-dispose resource)
       (signal (car err) (cdr err))))))

;;;###autoload
(defun etaf-resource-status (resource)
  "Return RESOURCE status: idle, loading, refreshing, success, error or cancelled."
  (plist-get (etaf-value (etaf-resource-state resource)) :status))

;;;###autoload
(defun etaf-resource-value (resource)
  "Return RESOURCE's successful value, or nil before success."
  (plist-get (etaf-value (etaf-resource-state resource)) :value))

;;;###autoload
(defun etaf-resource-error (resource)
  "Return RESOURCE's current loader failure or cancellation condition, or nil."
  (plist-get (etaf-value (etaf-resource-state resource)) :error))

(defun etaf--resource-discard-result (result)
  "Release RESULT's cleanup after its request became obsolete."
  (when (and (etaf-resource-result-p result)
             (etaf-resource-result-cleanup result))
    (funcall (etaf-resource-result-cleanup result))))

(defun etaf--resource-accept (resource task result)
  "Install RESULT only while TASK remains RESOURCE's current request."
  (pcase-let ((`(,value ,cleanup) (etaf--resource-normalize-result result)))
    (condition-case err
        (etaf--resource-run-cleanup resource)
      ((error quit)
       (etaf--resource-discard-result result)
       (when (and (etaf-resource-active-p resource)
                  (eq task (etaf-resource-request resource)))
         (setf (etaf-resource-has-value-p resource) nil)
         (etaf--resource-set-state resource 'error nil err))
       (signal (car err) (cdr err))))
    ;; Cleanup is user code: it can dispose the owner or start a newer load.
    (if (and (etaf-resource-active-p resource)
             (eq task (etaf-resource-request resource)))
        (progn
          (setf (etaf-resource-cleanup resource) cleanup
                (etaf-resource-has-value-p resource) t)
          (etaf--resource-set-state resource 'success value nil))
      (etaf--resource-discard-result result))))

(defun etaf--resource-reject (resource condition)
  "Record RESOURCE's current loader failure or cancellation CONDITION."
  (etaf--resource-set-state
   resource (if (memq (car condition) '(etaf-async-cancelled quit)) 'cancelled 'error)
   (when (etaf-resource-has-value-p resource) (etaf-resource-value resource)) condition)
  (when (eq (car condition) 'quit) (signal 'quit (cdr condition))))

;;;###autoload
(defun etaf-resource-load (resource)
  "Reload RESOURCE and return it, without waiting for asynchronous completion.
Cancel the previous request before starting the next.  Only the current
request can publish a result.  Loader failures become observable state;
cleanup and rendering failures still signal normally.  Reload after error,
timeout or cancellation retries the loader; no automatic retry is performed."
  (etaf--assert-not-rendering 'load-resource)
  (etaf--resource-require-active resource)
  (let ((previous (etaf-resource-request resource)) task)
    (setq task
          (etaf--load-task-create
           :scope (etaf-resource-scope resource)
           :timeout (etaf-resource-timeout resource)
           :success (lambda (result) (etaf--resource-accept resource task result))
           :failure (lambda (condition)
                      (when (and (etaf-resource-active-p resource)
                                 (eq task (etaf-resource-request resource)))
                        (etaf--resource-reject resource condition)))
           :discard #'etaf--resource-discard-result))
    ;; Reserve ownership before invoking cancellation/cleanup or publishing
    ;; loading. Any of those callbacks can synchronously replace this request.
    (setf (etaf-resource-request resource) task)
    (condition-case err
        (progn
          (etaf--load-abort previous)
          (when (etaf--load-task-pending-p task)
            (unless (etaf-resource-keep-value resource)
              (setf (etaf-resource-has-value-p resource) nil)
              (etaf--resource-run-cleanup resource))
            (when (etaf--load-task-pending-p task)
              (etaf--resource-set-state
               resource (if (etaf-resource-has-value-p resource) 'refreshing 'loading)
               (when (etaf-resource-has-value-p resource) (etaf-resource-value resource)) nil)
              (etaf--load-start
               task (lambda ()
                      (etaf-observer-with-stage ('resource 'load)
                        (funcall (etaf-resource-loader resource))))))))
      ((error quit)
       (etaf--load-abort task)
       (signal (car err) (cdr err)))))
  resource)

;;;###autoload
(defun etaf-resource-cancel (resource)
  "Cancel RESOURCE's pending load without disposing it, and return RESOURCE.
The first late completion is discarded, even when external work cannot be
cancelled.  The Resource may be loaded again.  No pending request is a no-op."
  (etaf--assert-not-rendering 'cancel-resource)
  (etaf--resource-require-active resource)
  (etaf--load-abort (etaf-resource-request resource) '(etaf-async-cancelled))
  resource)

;;;###autoload
(defun etaf-resource-dispose (resource)
  "Dispose RESOURCE and return cleanup errors collected by its Scope."
  (etaf--assert-not-rendering 'dispose-resource)
  (unless (etaf-resource-p resource)
    (signal 'wrong-type-argument (list 'etaf-resource-p resource)))
  (when (etaf-resource-active-p resource)
    (setf (etaf-resource-active-p resource) nil)
    (etaf-scope-stop (etaf-resource-scope resource))))

;;;###autoload
(cl-defun etaf-error-boundary-run (function handler &key name)
  "Run FUNCTION and handle its signaled error with HANDLER.

HANDLER receives the raw condition object and its return value becomes the
boundary result.  NAME is accepted for caller diagnostics and does not change
control flow.  Errors signaled outside FUNCTION, or by HANDLER itself, are not
swallowed by this boundary."
  (ignore name)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (unless (functionp handler)
    (signal 'wrong-type-argument (list 'functionp handler)))
  (condition-case err
      (funcall function)
    (error
     (funcall handler err))))

(provide 'etaf-resource)

;;; etaf-resource.el ends here
