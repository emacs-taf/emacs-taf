;;; etaf-youtube-service.el --- YouTube skill transport -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The service runs the `youtube' skill through `pi-skill youtube COMMAND
;; ... --json' and returns parsed protocol 1 payloads.  Every call is
;; asynchronous, timeout-bounded and cancellable; a late reply from a call
;; that was cancelled or superseded never reaches its application callback.
;; The runner boundary is injectable, so the public suite drives a whole
;; session with canned JSON and no browser, process or network.
;;
;; Only `etaf-youtube-service-create', `etaf-youtube-service-call',
;; `etaf-youtube-service-cancel' and `etaf-youtube-service-close' are used
;; outside this file.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defcustom etaf-youtube-program "pi-skill"
  "Program that dispatches skill commands.
The youtube skill is invoked as PROGRAM youtube COMMAND ... --json."
  :type 'string
  :group 'etaf-youtube)

(defcustom etaf-youtube-request-timeout 95
  "Seconds before an unfinished skill request is cancelled.
The skill itself bounds most commands to 45 seconds and 90 at most, so a
request that outlives this window is a failed transport, not slow work."
  :type 'number
  :group 'etaf-youtube)

(cl-defstruct (etaf-youtube--call
               (:constructor etaf-youtube--call--make))
  "One in-flight skill request."
  id key cancel timer callback)

(cl-defstruct (etaf-youtube-service
               (:constructor etaf-youtube--service--make))
  "Transport that runs protocol 1 skill commands."
  runner timeout calls counter)

(defun etaf-youtube--decode-json (text)
  "Return TEXT as a protocol payload plist, or signal an error."
  (let ((trimmed (string-trim text)))
    (when (string-empty-p trimmed)
      (error "Empty response"))
    (json-parse-string trimmed
                       :object-type 'plist
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun etaf-youtube--failure (payload message hint)
  "Build the service failure result from PAYLOAD, MESSAGE and HINT."
  (list :status 'error
        :value payload
        :message (or (and (stringp message) (not (string-empty-p message)) message)
                     "YouTube request failed")
        :hint (and (stringp hint) (not (string-empty-p hint)) hint)))

(defun etaf-youtube--settle (service id result)
  "Deliver RESULT to the call ID in SERVICE, unless it was cancelled.
RESULT is the raw runner plist `:exit', `:stdout' and `:stderr'."
  (when-let* ((call (gethash id (etaf-youtube-service-calls service))))
    (remhash id (etaf-youtube-service-calls service))
    (when-let* ((timer (etaf-youtube--call-timer call)))
      (cancel-timer timer))
    (let* ((exit (plist-get result :exit))
           (stdout (or (plist-get result :stdout) ""))
           (stderr (or (plist-get result :stderr) ""))
           (transport (plist-get result :error))
           (payload nil)
           (decoded nil))
      (unless transport
        (condition-case nil
            (setq payload (etaf-youtube--decode-json stdout)
                  decoded t)
          (error nil)))
      (cond
       (transport
        (funcall (etaf-youtube--call-callback call)
                 (etaf-youtube--failure nil (format "Transport failed: %s" transport)
                                        nil)))
       ((not decoded)
        (funcall (etaf-youtube--call-callback call)
                 (etaf-youtube--failure nil (string-trim stderr)
                                        "The skill did not return JSON")))
       ((and (eq exit 0) (plist-get payload :ok))
        (funcall (etaf-youtube--call-callback call)
                 (list :status 'ok :value payload)))
       (t
        (funcall (etaf-youtube--call-callback call)
                 (etaf-youtube--failure payload
                                        (or (plist-get payload :message)
                                            (string-trim stderr))
                                        (plist-get payload :hint))))))))

(defun etaf-youtube--run-process (argv callback)
  "Start ARGV and call CALLBACK with its `:exit', `:stdout' and `:stderr'.
Return a cancel function that terminates the process.  This is the default
runner; the public suite replaces it."
  (let ((program (executable-find (car argv))))
    (if (null program)
        (progn
          (funcall callback (list :exit 127 :stdout ""
                                  :error (format "%s is not on PATH"
                                                 (car argv))))
          #'ignore)
      (let* ((out (generate-new-buffer " *etaf-youtube stdout*"))
             (err (generate-new-buffer " *etaf-youtube stderr*"))
             (process (make-process
                       :name "etaf-youtube"
                       :command (cons program (cdr argv))
                       :buffer out
                       :stderr err
                       :coding 'utf-8
                       :connection-type 'pipe
                       :noquery t))
             (done nil))
        ;; A stderr pipe needs its own sentinel, or Emacs queries about the
        ;; unread output when the process exits.
        (when-let* ((err-process (get-buffer-process err)))
          (set-process-sentinel err-process #'ignore))
        (set-process-sentinel
         process
         (lambda (proc _event)
           (when (and (not done)
                      (memq (process-status proc) '(exit signal failed)))
             (setq done t)
             ;; Drain both pipes before reading, or the tail of the output is
             ;; still in flight when the sentinel runs.
             (accept-process-output proc 0)
             (when-let* ((err-process (get-buffer-process err)))
               (accept-process-output err-process 0))
             (let ((result (list :exit (process-exit-status proc)
                                 :stdout (with-current-buffer out (buffer-string))
                                 :stderr (with-current-buffer err (buffer-string)))))
               (when (buffer-live-p out) (kill-buffer out))
               (when (buffer-live-p err) (kill-buffer err))
               (funcall callback result)))))
        (lambda ()
          (when (process-live-p process)
            (setq done t)
            (delete-process process)
            (when (buffer-live-p out) (kill-buffer out))
            (when (buffer-live-p err) (kill-buffer err))))))))

(cl-defun etaf-youtube-service-create (&key runner timeout)
  "Create a skill transport.
RUNNER defaults to the process runner; it receives ARGV and a CALLBACK and
returns a cancel function.  TIMEOUT defaults to
`etaf-youtube-request-timeout'."
  (etaf-youtube--service--make
   :runner (or runner #'etaf-youtube--run-process)
   :timeout (or timeout etaf-youtube-request-timeout)
   :calls (make-hash-table :test #'eql)
   :counter 0))

(defun etaf-youtube-service-call (service args callback &optional key)
  "Run skill ARGS through SERVICE and deliver the result to CALLBACK.
ARGS is a list of command words; `--json' is appended.  CALLBACK receives a
result plist whose `:status' is `ok', `error' or `timeout'; `:value' holds
the protocol payload on success, and `:message' and `:hint' describe a
failure.  KEY identifies the request: a new call with the same non-nil key
cancels the previous one, so only the newest reply reaches CALLBACK.

Return the opaque call id."
  (let ((id (cl-incf (etaf-youtube-service-counter service))))
    (when key
      (etaf-youtube-service-cancel service key))
    (let* ((call (etaf-youtube--call--make :id id :key key :callback callback))
           (runner (etaf-youtube-service-runner service))
           (argv (cons etaf-youtube-program
                       (append (list "youtube") args (list "--json")))))
      (puthash id call (etaf-youtube-service-calls service))
      (setf (etaf-youtube--call-cancel call)
            (condition-case error
                (funcall runner argv
                         (lambda (result)
                           (etaf-youtube--settle service id result)))
              (error
               (etaf-youtube--settle
                service id
                (list :exit 1 :stdout ""
                      :error (error-message-string error))))))
      (when-let* ((cancel (etaf-youtube--call-cancel call)))
        (setf (etaf-youtube--call-timer call)
              (run-at-time (etaf-youtube-service-timeout service) nil
                           (lambda ()
                             (when (gethash id (etaf-youtube-service-calls service))
                               (ignore-errors (funcall cancel))
                               (remhash id (etaf-youtube-service-calls service))
                               (funcall callback
                                        (etaf-youtube--failure
                                         nil "YouTube request timed out"
                                         "Retry when the connection recovers")))))))
      id)))

(defun etaf-youtube-service-cancel (service &optional key)
  "Cancel SERVICE's in-flight request for KEY, or every request when KEY is nil."
  (let ((ids (etaf-youtube-service-calls service)))
    (maphash
     (lambda (id call)
       (when (or (null key) (equal key (etaf-youtube--call-key call)))
         (when-let* ((timer (etaf-youtube--call-timer call)))
           (cancel-timer timer))
         (when-let* ((cancel (etaf-youtube--call-cancel call)))
           (ignore-errors (funcall cancel)))
         (remhash id ids)))
     (copy-hash-table ids))))

(defun etaf-youtube-service-close (service)
  "Cancel every request of SERVICE and release its state."
  (etaf-youtube-service-cancel service)
  (clrhash (etaf-youtube-service-calls service)))

(provide 'etaf-youtube-service)
;;; etaf-youtube-service.el ends here
