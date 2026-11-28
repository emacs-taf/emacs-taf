;;; etaf-async.el --- Shared loader completion lifecycle -*- lexical-binding: t; -*-

;;; Commentary:
;; Resource and Data share one request lifecycle.  Adapters return a lazy
;; asynchronous operation; consumers retain their own value/publication model.

;;; Code:
(require 'cl-lib)
(require 'etaf-reactive)

(define-error 'etaf-async-error "Invalid ETAF asynchronous operation" 'etaf-reactive-error)
(define-error 'etaf-async-timeout "ETAF asynchronous operation timed out" 'etaf-async-error)
(define-error 'etaf-async-cancelled "ETAF asynchronous operation was cancelled" 'etaf-async-error)

(cl-defstruct (etaf--async (:constructor etaf--async-create)) start)

;;;###autoload
(defun etaf-async (start)
  "Describe a lazy asynchronous loader using START.
Return this value from a Resource loader or Data source operation.  START
receives RESOLVE and REJECT functions and may return a zero-argument cancel
function.  It starts work without blocking and completes once: RESOLVE takes
the ordinary loader result; REJECT takes Emacs condition data.  Returning nil
means the work cannot be cancelled, but obsolete completion is still ignored.
The owning Resource or Controller starts and releases the operation; this is
not a standalone promise.  Native timers and processes may call completion
functions later on the Emacs thread."
  (unless (functionp start)
    (signal 'wrong-type-argument (list 'functionp start)))
  (etaf--async-create :start start))

(cl-defstruct (etaf--load-task (:constructor etaf--load-task-create))
  scope success failure discard timeout timer cancel
  (pending-p t) completed-p aborted-p)

(defun etaf--load-check-timeout (timeout)
  "Require nil or a positive number of seconds for TIMEOUT."
  (unless (or (null timeout) (and (numberp timeout) (> timeout 0)))
    (signal 'etaf-async-error (list "Timeout must be nil or positive seconds" timeout))))

(defun etaf--load-release (task)
  "Release TASK's timer, cancellation handle and consumer closures."
  (when-let* ((timer (etaf--load-task-timer task))) (cancel-timer timer))
  (setf (etaf--load-task-timer task) nil
        (etaf--load-task-cancel task) nil
        (etaf--load-task-scope task) nil
        (etaf--load-task-success task) nil
        (etaf--load-task-failure task) nil))

(defun etaf--load-deliver (task result condition)
  "Deliver TASK's first RESULT or CONDITION, ignoring later completions."
  (unless (etaf--load-task-completed-p task)
    (setf (etaf--load-task-completed-p task) t)
    (if (not (etaf--load-task-pending-p task))
        (when (and (not condition) (etaf--load-task-discard task))
          (funcall (etaf--load-task-discard task) result))
      (let ((scope (etaf--load-task-scope task))
            (callback (if condition (etaf--load-task-failure task)
                        (etaf--load-task-success task))))
        (setf (etaf--load-task-pending-p task) nil)
        (etaf--load-release task)
        (etaf-scope-run scope (lambda () (funcall callback (or condition result))))
        t))))

(defun etaf--load-abort (task &optional condition)
  "Invalidate TASK and cancel its external work once.
When CONDITION is present, notify its consumer after invalidating the task.
Without CONDITION, cancellation is silent (replacement or owner disposal)."
  (when (and task (etaf--load-task-pending-p task))
    (let ((cancel (etaf--load-task-cancel task))
          (scope (etaf--load-task-scope task))
          (failure (etaf--load-task-failure task)))
      (setf (etaf--load-task-pending-p task) nil
            (etaf--load-task-aborted-p task) t)
      (etaf--load-release task)
      (unwind-protect
          (when cancel (funcall cancel))
        (when condition
          (etaf-scope-run scope (lambda () (funcall failure condition))))))
    t))

(defun etaf--load-start (task loader)
  "Call LOADER, then finish or start its asynchronous result for TASK.
Consumer publication errors are outside the loader error boundary."
  (when (etaf--load-task-pending-p task)
    (let (result condition)
      (condition-case err
          (setq result (etaf-scope-run (etaf--load-task-scope task) loader))
        ((error quit) (setq condition err)))
      (cond
       (condition (etaf--load-deliver task nil condition))
       ((not (etaf--async-p result)) (etaf--load-deliver task result nil))
       ((etaf--load-task-pending-p task)
        (let ((resolve (lambda (value) (etaf--load-deliver task value nil)))
              (reject
               (lambda (error-data)
                 (unless (and (consp error-data) (symbolp (car error-data))
                              (proper-list-p (cdr error-data)))
                   (setq error-data
                         (list 'etaf-async-error "Rejection must be condition data" error-data)))
                 (etaf--load-deliver task nil error-data)))
              cancel)
          (when-let* ((timeout (etaf--load-task-timeout task)))
            (setf (etaf--load-task-timer task)
                  (run-at-time timeout nil #'etaf--load-abort task
                               (list 'etaf-async-timeout timeout))))
          (condition-case err
              (setq cancel
                    (etaf-scope-run
                     (etaf--load-task-scope task)
                     (lambda () (funcall (etaf--async-start result) resolve reject))))
            ((error quit)
             (if (etaf--load-task-completed-p task)
                 (signal (car err) (cdr err))
               (funcall reject err))))
          (unless (or (null cancel) (functionp cancel))
            (let ((err (list 'etaf-async-error "START must return a cancellation function or nil" cancel)))
              (if (etaf--load-task-completed-p task)
                  (signal (car err) (cdr err))
                (funcall reject err))))
          (when (functionp cancel)
            (cond
             ((etaf--load-task-pending-p task)
              (setf (etaf--load-task-cancel task) cancel))
             ((etaf--load-task-aborted-p task) (funcall cancel)))))))))
  task)

(provide 'etaf-async)
;;; etaf-async.el ends here
