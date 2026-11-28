;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-session.el --- Asynchronous game adapter lifecycle

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'etaf)
(defvar etaf-gamekit-request-timeout)
(declare-function etaf-gamekit--mount "etaf-gamekit-view" (session))

(cl-defstruct (etaf-gamekit--session (:constructor etaf-gamekit--make-session))
  process buffer stderr timer deadline reaper presentation validator game-info (input "") (next-id 0) pending
  displayed
  (revision 0) (published-at 0) capabilities observation error (status 'starting)
  (view-ref (etaf-ref nil :test #'equal)) (capabilities-ref (etaf-ref nil :test #'equal)) (status-ref (etaf-ref "Starting game…"))
  (error-ref (etaf-ref "")))

(defun etaf-gamekit-status (session)
  "Return SESSION's current connection state."
  (etaf-value (etaf-gamekit--session-status-ref session))
  (etaf-gamekit--session-status session))

(defun etaf-gamekit-buffer (session)
  "Return SESSION's application buffer."
  (etaf-gamekit--session-buffer session))

(defun etaf-gamekit-last-error (session)
  "Return SESSION's latest rejection or transport error."
  (etaf-value (etaf-gamekit--session-error-ref session))
  (etaf-gamekit--session-error session))

(defun etaf-gamekit--copy (value)
  "Detach JSON VALUE from session ownership."
  (cond ((stringp value) (copy-sequence value))
        ((vectorp value) (vconcat (mapcar #'etaf-gamekit--copy value)))
        ((hash-table-p value)
         (let ((result (copy-hash-table value)))
           (maphash (lambda (key item)
                      (remhash key result)
                      (puthash (etaf-gamekit--copy key) (etaf-gamekit--copy item) result)) value)
           result))
        ((consp value) (mapcar #'etaf-gamekit--copy value))
        (t value)))

(defun etaf-gamekit-observation (session)
  "Return a detached copy of SESSION's latest accepted backend observation."
  (etaf-gamekit--copy (etaf-gamekit--session-observation session)))

(defun etaf-gamekit-view (session &optional field)
  "Read SESSION's coalesced display observation, reactively; optionally FIELD."
  (let ((view (etaf-value (etaf-gamekit--session-view-ref session))))
    (etaf-gamekit--copy (if field (plist-get view field) view))))

(defun etaf-gamekit-capabilities (session)
  "Return a detached list of SESSION's advertised actions, reactively."
  (etaf-gamekit--copy (etaf-value (etaf-gamekit--session-capabilities-ref session))))

(defun etaf-gamekit--publish (session)
  "Publish SESSION's newest accepted projection in one reactive batch."
  (setf (etaf-gamekit--session-timer session) nil
        (etaf-gamekit--session-published-at session) (float-time))
  (etaf-batch
    (setf (etaf-value (etaf-gamekit--session-view-ref session))
          (etaf-gamekit--session-observation session)
          (etaf-value (etaf-gamekit--session-status-ref session))
          (pcase (etaf-gamekit-status session)
            ('starting "Starting game…") ('busy "Applying action…")
            ('failed "Game disconnected") ('closed "Closed") (_ "Ready"))
          (etaf-value (etaf-gamekit--session-error-ref session))
          (or (etaf-gamekit-last-error session) "")
          (etaf-value (etaf-gamekit--session-capabilities-ref session))
          (etaf-gamekit--session-capabilities session))))

(defun etaf-gamekit--schedule (session &optional immediate)
  "Coalesce streamed observations; publish acknowledged input promptly."
  (when (and immediate (etaf-gamekit--session-timer session))
    (cancel-timer (etaf-gamekit--session-timer session))
    (setf (etaf-gamekit--session-timer session) nil))
  (unless (etaf-gamekit--session-timer session)
    (let* ((period (/ 1.0 60))
           (remaining (- period (- (float-time) (etaf-gamekit--session-published-at session))))
           (delay (if immediate 0 (min period (max 0 remaining)))))
      (setf (etaf-gamekit--session-timer session)
            (run-at-time delay nil #'etaf-gamekit--publish session)))))

(defun etaf-gamekit--fail (session message)
  "Record MESSAGE and release SESSION's failed transport."
  (unless (eq (etaf-gamekit-status session) 'closed)
    (when-let* ((deadline (etaf-gamekit--session-deadline session)))
      (cancel-timer deadline) (setf (etaf-gamekit--session-deadline session) nil))
    (setf (etaf-gamekit--session-status session) 'failed
          (etaf-gamekit--session-error session) message
          (etaf-gamekit--session-pending session) nil)
    (etaf-gamekit--terminate session)
    (etaf-gamekit--schedule session)))

(defun etaf-gamekit--terminate (session)
  "Close SESSION's stdin, then reap a child that fails to exit promptly."
  (when-let* ((process (etaf-gamekit--session-process session)))
    (when (process-live-p process)
      (process-send-eof process)
      (unless (etaf-gamekit--session-reaper session)
        (setf (etaf-gamekit--session-reaper session)
              (run-at-time 0.75 nil
                           (lambda ()
                             (setf (etaf-gamekit--session-reaper session) nil)
                             (when (process-live-p process) (delete-process process)))))))))

(defun etaf-gamekit--decode (value)
  "Convert parsed JSON VALUE to detached keyword plists and lists."
  (cond ((hash-table-p value)
         (let (result)
           (maphash (lambda (key item)
                      (setq result (nconc result
                                          (list (intern (concat ":" key))
                                                (etaf-gamekit--decode item))))) value)
           result))
        ((vectorp value) (mapcar #'etaf-gamekit--decode value))
        (t value)))

(defun etaf-gamekit--deadline (session)
  "Arm SESSION's deadline for its oldest outstanding request."
  (when-let* ((timer (etaf-gamekit--session-deadline session)))
    (cancel-timer timer))
  (setf (etaf-gamekit--session-deadline session) nil)
  (when-let* ((pending (car (etaf-gamekit--session-pending session))))
    (setf (etaf-gamekit--session-deadline session)
          (run-at-time (max 0 (- (cdr pending) (float-time))) nil
                       (lambda ()
                         (etaf-gamekit--fail session "Engine response timed out"))))))

(defun etaf-gamekit--accept (session message)
  "Validate and accept one decoded adapter MESSAGE for SESSION."
  (unless (hash-table-p message)
    (signal 'etaf-gamekit-error '("Adapter response must be a JSON object")))
  (let* ((id (gethash "id" message)) (revision (gethash "revision" message))
         (raw (gethash "observation" message))
         (observation (etaf-gamekit--decode raw))
         (capabilities (gethash "capabilities" message))
         (failure (gethash "error" message))
         (validator (etaf-gamekit--session-validator session)))
    (unless (and (cl-every (lambda (key)
                             (not (eq (gethash key message 'absent) 'absent)))
                           '("version" "id" "revision" "capabilities" "observation" "error"))
                 (equal (gethash "version" message) 1)
                 (integerp revision) (> revision (etaf-gamekit--session-revision session))
                 (or (null id) (equal id (caar (etaf-gamekit--session-pending session))))
                 (hash-table-p raw)
                 (or (null validator)
                     (eq t (condition-case problem
                               (funcall validator (etaf-gamekit--copy observation))
                             (error (signal 'etaf-gamekit-error
                                            (list (concat "Observation validator failed: "
                                                          (error-message-string problem))))))))
                 (vectorp capabilities) (cl-every #'stringp capabilities)
                 (or (null failure)
                     (and id (stringp failure) (not (string-empty-p failure)))))
      (signal 'etaf-gamekit-error '("Malformed, stale or uncorrelated adapter response")))
    (setf (etaf-gamekit--session-revision session) revision
          (etaf-gamekit--session-observation session) observation
          (etaf-gamekit--session-capabilities session) (append capabilities nil))
    (when id
      (setf (etaf-gamekit--session-error session) failure
            (etaf-gamekit--session-pending session) (cdr (etaf-gamekit--session-pending session))
            (etaf-gamekit--session-status session)
            (if (etaf-gamekit--session-pending session) 'busy 'ready))
      (etaf-gamekit--deadline session))
    (etaf-gamekit--schedule session id)))

(defun etaf-gamekit--filter (session chunk)
  "Decode bounded JSON-lines from adapter CHUNK for SESSION."
  (unless (memq (etaf-gamekit-status session) '(closed failed))
    (condition-case failure
        (let ((pending (concat (etaf-gamekit--session-input session) chunk)))
          (while (string-match "\n" pending)
            (let ((line (substring pending 0 (match-beginning 0))))
              (setq pending (substring pending (match-end 0)))
              (when (> (string-bytes line) (* 1024 1024))
                (signal 'etaf-gamekit-error '("Adapter message exceeds 1 MiB")))
              (unless (string-empty-p line)
                (etaf-gamekit--accept
                 session (json-parse-string line :object-type 'hash-table :array-type 'array
                                            :null-object nil :false-object :false)))))
          (when (> (string-bytes pending) (* 1024 1024))
            (signal 'etaf-gamekit-error '("Unterminated adapter message exceeds 1 MiB")))
          (setf (etaf-gamekit--session-input session) pending))
      ((json-parse-error etaf-gamekit-error)
       (etaf-gamekit--fail session (error-message-string failure))))))

(defun etaf-gamekit--send (session operation arguments)
  "Send validated OPERATION and ARGUMENTS to SESSION."
  (let* ((id (1+ (etaf-gamekit--session-next-id session)))
         (encoded (condition-case failure
                      (concat (json-serialize
                               (list :version 1 :id id :op operation
                                     :args (or arguments (make-hash-table)))
                               :false-object :false) "\n")
                    (error (signal 'etaf-gamekit-error
                                   (list (error-message-string failure)))))))
    (when (> (1- (string-bytes encoded)) (* 1024 1024))
      (signal 'etaf-gamekit-error '("Request exceeds 1 MiB")))
    (setf (etaf-gamekit--session-next-id session) id
          (etaf-gamekit--session-pending session)
          (append (etaf-gamekit--session-pending session)
                  (list (cons id (+ (float-time) etaf-gamekit-request-timeout)))))
    (unless (eq (etaf-gamekit-status session) 'starting)
      (setf (etaf-gamekit--session-status session) 'busy))
    (condition-case failure
        (process-send-string (etaf-gamekit--session-process session) encoded)
      (error
       (etaf-gamekit--fail session (error-message-string failure))
       (signal 'etaf-gamekit-error (list (error-message-string failure)))))
    (etaf-gamekit--deadline session)
    (etaf-gamekit--schedule session)
    id))

(defun etaf-gamekit-action (session operation &optional arguments)
  "Send SESSION an advertised OPERATION with keyword-plist ARGUMENTS."
  (unless (and (memq (etaf-gamekit-status session) '(ready busy))
               (< (length (etaf-gamekit--session-pending session)) 8)
               (member operation (etaf-gamekit--session-capabilities session))
               (proper-list-p arguments) (zerop (% (length arguments) 2))
               (cl-loop for (key _value) on arguments by #'cddr always (keywordp key)))
    (signal 'etaf-gamekit-error '("Action needs a live session with queue capacity, an advertised operation and keyword arguments")))
  (etaf-gamekit--send session operation arguments))

(defun etaf-gamekit-close (session)
  "Release SESSION's process, timer and mount, preserving its buffer."
  (unless (eq (etaf-gamekit-status session) 'closed)
    (when-let* ((deadline (etaf-gamekit--session-deadline session)))
      (cancel-timer deadline) (setf (etaf-gamekit--session-deadline session) nil))
    (setf (etaf-gamekit--session-status session) 'closed
          (etaf-gamekit--session-pending session) nil)
    (when-let* ((timer (etaf-gamekit--session-timer session)))
      (cancel-timer timer) (setf (etaf-gamekit--session-timer session) nil))
    (etaf-gamekit--terminate session)
    (when (buffer-live-p (etaf-gamekit--session-stderr session))
      (kill-buffer (etaf-gamekit--session-stderr session)))
    (when (buffer-live-p (etaf-gamekit-buffer session))
      (when-let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
        (etaf-unmount runtime))))
  nil)

(defun etaf-gamekit-dispose (session)
  "Close SESSION idempotently and kill its backing buffer when live."
  (etaf-gamekit-close session)
  (when-let* ((buffer (etaf-gamekit-buffer session)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  nil)

(defun etaf-gamekit--start (command buffer view validate game-info &optional display)
  "Create one game instance with COMMAND, BUFFER, VIEW, VALIDATE and GAME-INFO.
DISPLAY non-nil mounts the presentation into BUFFER; a hosted session passes
nil and lets its one host render the same session instead."
  (unless (and (numberp etaf-gamekit-request-timeout) (> etaf-gamekit-request-timeout 0)
               (consp command) (proper-list-p command) (cl-every #'stringp command)
               (or (null view) (functionp view))
               (or (null validate) (functionp validate)))
    (signal 'etaf-gamekit-error '("Command must be a nonempty program/argument list")))
  (let* ((buffer (if buffer (get-buffer-create buffer)
                   (generate-new-buffer "*ETAF Game*")))
         (session (etaf-gamekit--make-session :buffer buffer :presentation view :validator validate
                                             :game-info game-info)))
    (unless (and (zerop (buffer-size buffer)) (not (etaf-runtime-for-buffer buffer)))
      (signal 'etaf-gamekit-error '("The game buffer must be empty and unmounted")))
    (condition-case failure
        (progn
          (setf (etaf-gamekit--session-stderr session) (generate-new-buffer " *Game engine stderr*"))
          (when display (etaf-gamekit--mount session))
          (setf (etaf-gamekit--session-displayed session) (and display t))
          (setf (etaf-gamekit--session-process session)
                (make-process
                 :name (generate-new-buffer-name "etaf-gamekit-engine")
                 :command command :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :stderr (etaf-gamekit--session-stderr session)
                 :filter (lambda (_process text) (etaf-gamekit--filter session text))
                 :sentinel
                 (lambda (process event)
                   (when (memq (process-status process) '(exit signal failed))
                     (when-let* ((reaper (etaf-gamekit--session-reaper session)))
                       (cancel-timer reaper)
                       (setf (etaf-gamekit--session-reaper session) nil)))
                   (when (and (memq (process-status process) '(exit signal failed))
                              (not (memq (etaf-gamekit-status session) '(closed failed))))
                     (etaf-gamekit--fail
                      session
                      (concat (string-trim event)
                              (when (buffer-live-p (etaf-gamekit--session-stderr session))
                                (with-current-buffer (etaf-gamekit--session-stderr session)
                                  (concat ": " (buffer-substring-no-properties
                                                (max (point-min) (- (point-max) 2000))
                                                (point-max)))))))))))
          ;; The stderr pipe is a process of its own.  Without a sentinel Emacs
          ;; writes "Process ... finished" into its buffer when the engine
          ;; exits, and that line would be read back as part of the failure.
          (when-let* ((pipe (get-buffer-process (etaf-gamekit--session-stderr session))))
            (set-process-sentinel pipe #'ignore))
          (etaf-gamekit--send session "start" nil)
          session)
      (error
       (etaf-gamekit-close session)
       (signal (car failure) (cdr failure))))))

(provide 'etaf-gamekit-session)
;;; etaf-gamekit-session.el ends here
