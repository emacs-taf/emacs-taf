;;; etaf-process.el --- Run-to-completion subprocesses -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Applications reach their backends through command-line programs that run
;; once per request and reply on stdout.  This module owns the plumbing those
;; clients otherwise repeat: separate stdout and stderr streams, a complete
;; read of both after exit, an optional timeout, cancellation, and a single
;; settlement that reports one result plist.
;;
;; An exited process can still have output in flight, because stderr is a
;; pipe process of its own and the exit event can arrive before the data.
;; Settlement drains both streams with a zero timeout: the exit means the
;; writer finished, so its bytes are already in the kernel buffers, and a
;; zero timeout reads them without waiting (a timeout-less wait from a
;; sentinel prints "Blocking call to accept-process-output with quit
;; inhibited").  Draining can run timers, so settlement rechecks whether a
;; timeout or a cancellation already finished the job.  The stderr pipe gets
;; an ignoring sentinel, which keeps Emacs's "Process ... finished" line out
;; of the captured text.
;;
;; Protocols stay with their clients: what an exit code, a JSON field or a
;; stderr line means is decided by the caller that reads the result.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (etaf-process--job (:constructor etaf-process--job-create)
                                 (:copier nil))
  "One run-to-completion subprocess and its pending settlement."
  name process timer stdout stderr callback output settled)

(defun etaf-process--kill-streams (job)
  "Kill JOB's stream buffers."
  (dolist (buffer (list (etaf-process--job-stdout job)
                        (etaf-process--job-stderr job)))
    (when (buffer-live-p buffer)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defun etaf-process--text (buffer)
  "Return BUFFER's text, or an empty string when it is gone."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max)))
    ""))

(defun etaf-process--decode (text output)
  "Decode TEXT as the OUTPUT kind `string' or `json'."
  (if (eq output 'json)
      (let ((trimmed (string-trim text)))
        (unless (string-empty-p trimmed)
          (condition-case nil
              (json-parse-string trimmed
                                 :object-type 'plist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object :false)
            (error nil))))
    text))

(defun etaf-process--deliver (job result)
  "Settle JOB with RESULT and run its callback, at most once."
  (unless (etaf-process--job-settled job)
    (setf (etaf-process--job-settled job) t)
    (when-let* ((timer (etaf-process--job-timer job)))
      (cancel-timer timer))
    (when-let* ((callback (etaf-process--job-callback job)))
      (funcall callback result))))

(defun etaf-process--settle (job process)
  "Read the result of exited PROCESS and settle JOB."
  (let ((stderr (etaf-process--job-stderr job)))
    (unless (etaf-process--job-settled job)
      (while (accept-process-output process 0))
      (let ((pipe (and (buffer-live-p stderr) (get-buffer-process stderr))))
        (while (and pipe (accept-process-output pipe 0)))))
    (let ((output (etaf-process--text (etaf-process--job-stdout job)))
          (errors (etaf-process--text stderr)))
      (etaf-process--kill-streams job)
      ;; Draining may have run the timeout, which already settled the job.
      (etaf-process--deliver
       job (list :status (process-status process)
                 :exit (process-exit-status process)
                 :output (etaf-process--decode output (etaf-process--job-output job))
                 :stderr errors)))))

(defun etaf-process--expire (job timeout)
  "Settle JOB as timed out after TIMEOUT seconds and stop its process."
  (let ((process (etaf-process--job-process job)))
    (etaf-process--deliver
     job (list :status 'timeout
               :message (format "%s timed out after %ss"
                                (etaf-process--job-name job) timeout)
               :stderr (etaf-process--text (etaf-process--job-stderr job))))
    (when (process-live-p process)
      (delete-process process))))

;;;###autoload
(cl-defun etaf-process-run (command &key callback timeout environment directory
                                    (output 'string) (coding 'utf-8-unix) name)
  "Run COMMAND, a list of a program and its arguments, and return a job.
CALLBACK receives one result plist when the job settles, never before this
function returns and never after `etaf-process-cancel':
  :status  `exit', `signal', `timeout' or `failed' (the program did not start)
  :exit    the exit code or signal number, for `exit' and `signal'
  :output  stdout as a string, or with OUTPUT `json' its parsed value
           (objects as plists, arrays as lists, null as nil, false as
           :false), nil when it is empty or not valid JSON
  :stderr  the complete standard error text
  :message a description, for `timeout' and `failed'.
TIMEOUT, in seconds, stops the process and settles the job as `timeout'.
ENVIRONMENT is a list of \"NAME=VALUE\" strings that override
`process-environment'; DIRECTORY is the working directory.  CODING decodes
both streams.  NAME labels the process, by default after the program."
  (unless (and (consp command) (cl-every #'stringp command))
    (signal 'wrong-type-argument (list 'list-of-strings command)))
  (unless (memq output '(string json))
    (signal 'wrong-type-argument (list '(member string json) output)))
  (unless (or (null timeout) (and (numberp timeout) (> timeout 0)))
    (signal 'wrong-type-argument (list '(or null (number > 0)) timeout)))
  (let* ((name (or name (file-name-nondirectory (car command))))
         (job (etaf-process--job-create
               :name name :callback callback :output output
               :stdout (generate-new-buffer (format " *%s stdout*" name) t)
               :stderr (generate-new-buffer (format " *%s stderr*" name) t))))
    (condition-case error
        (let ((default-directory (if directory
                                     (file-name-as-directory (expand-file-name directory))
                                   default-directory))
              (process-environment (append environment process-environment)))
          (setf (etaf-process--job-process job)
                (make-process
                 :name name
                 :buffer (etaf-process--job-stdout job)
                 :stderr (etaf-process--job-stderr job)
                 :command command
                 :connection-type 'pipe
                 :noquery t
                 :coding coding
                 :sentinel (lambda (process _event)
                             (when (memq (process-status process) '(exit signal failed))
                               (etaf-process--settle job process)))))
          (when-let* ((pipe (get-buffer-process (etaf-process--job-stderr job))))
            (set-process-sentinel pipe #'ignore))
          (when timeout
            (setf (etaf-process--job-timer job)
                  (run-at-time timeout nil #'etaf-process--expire job timeout))))
      (error
       (etaf-process--kill-streams job)
       (let ((message (error-message-string error)))
         (setf (etaf-process--job-timer job)
               (run-at-time 0 nil #'etaf-process--deliver job
                            (list :status 'failed :message message))))))
    job))

;;;###autoload
(defun etaf-process-cancel (job)
  "Stop JOB without running its callback.
Return non-nil when JOB had not settled yet."
  (unless (etaf-process--job-settled job)
    (setf (etaf-process--job-settled job) t)
    (when-let* ((timer (etaf-process--job-timer job)))
      (cancel-timer timer))
    (let ((process (etaf-process--job-process job)))
      (if (process-live-p process)
          (delete-process process)
        (etaf-process--kill-streams job)))
    t))

;;;###autoload
(defun etaf-process-live-p (job)
  "Return non-nil while JOB has neither settled nor been cancelled."
  (and (etaf-process--job-p job)
       (not (etaf-process--job-settled job))))

(provide 'etaf-process)
;;; etaf-process.el ends here
