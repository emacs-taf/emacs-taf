;;; etaf-video-studio-backend.el --- CLI boundary of etaf-video-studio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application never reads or writes a project file itself: the
;; `video-project' skill owns the store and runs every backend job in a
;; `job-run' process group that survives this Emacs.  This module only turns
;; one CLI invocation, run by `etaf-process-run', into one parsed JSON result
;; and hands it to a callback with the application buffer current, so the command loop is never blocked
;; while a probe or a lock waits.  Requests are bounded: a request that
;; exceeds `etaf-video-studio-request-timeout' is killed and reported, and
;; closing the application cancels its in-flight requests without touching
;; the background jobs.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'etaf)

(defcustom etaf-video-studio-executable "pi-skill"
  "Program that provides the `video-project' and `video-edit' commands.
Set this to a fake program in tests; the application only passes it a
command name, its arguments and `--json'."
  :type 'string
  :group 'etaf-video-studio)

(defcustom etaf-video-studio-request-timeout 300
  "Seconds after which a single CLI request is killed and reported.
Background jobs started by the CLI are not affected; their own timeout
lives in the project task."
  :type 'integer
  :group 'etaf-video-studio)

(defvar etaf-video-studio-backend--live nil
  "Alist of application buffer to its in-flight CLI jobs.")

(defun etaf-video-studio-backend-cancel (buffer)
  "Stop every in-flight CLI request of BUFFER without running its callback."
  (let ((entry (assq buffer etaf-video-studio-backend--live)))
    (mapc #'etaf-process-cancel (cdr entry))
    (setq etaf-video-studio-backend--live
          (delq entry etaf-video-studio-backend--live))
    nil))

(defun etaf-video-studio-backend--register (buffer job)
  "Record JOB as an in-flight request of BUFFER."
  (let ((entry (assq buffer etaf-video-studio-backend--live)))
    (if entry
        (setcdr entry (cons job (cdr entry)))
      (push (list buffer job) etaf-video-studio-backend--live))))

(defun etaf-video-studio-backend--unregister (buffer job)
  "Forget JOB among BUFFER's in-flight requests."
  (let ((entry (assq buffer etaf-video-studio-backend--live)))
    (when entry
      (setcdr entry (delq job (cdr entry)))
      (unless (cdr entry)
        (setq etaf-video-studio-backend--live
              (delq entry etaf-video-studio-backend--live))))))

(defun etaf-video-studio-backend--parse (text)
  "Parse TEXT as one JSON value with keyword plists, or return nil.
JSON false and null both become nil, which suits the CLI's boolean
fields (`undo', `redo', `reused') and absent optional fields."
  (when (and (stringp text)
             (not (string-empty-p (string-trim text))))
    (condition-case nil
        (json-parse-string (string-trim text)
                           :object-type 'plist
                           :array-type 'list
                           :null-object nil
                           :false-object nil)
      (error nil))))

(defun etaf-video-studio-backend--result (exit-code stdout stderr)
  "Build the callback result for a finished request.
EXIT-CODE is the process exit status; STDOUT and STDERR are its captured
streams.  A zero exit parses STDOUT; a nonzero exit prefers the CLI's JSON
error object on STDOUT and falls back to its stderr."
  (let ((parsed (etaf-video-studio-backend--parse stdout)))
    (cond
     ((and (zerop exit-code) (not (null parsed)))
      (list :ok t :data parsed))
     ((and parsed (eq (plist-get parsed :ok) nil)
           (or (plist-get parsed :error) (plist-get parsed :message)))
      (list :ok nil
            :code (or (plist-get parsed :error) "internal")
            :message (or (plist-get parsed :message) "video-project 请求失败")
            :hint (or (plist-get parsed :hint) "")
            :need (plist-get parsed :need)))
     ((zerop exit-code)
      (list :ok nil :code "internal" :message "video-project 输出不是有效 JSON"
            :hint (string-trim (or stdout ""))))
     (t
      (list :ok nil :code "external"
            :message (or (and (stringp stderr) (not (string-empty-p (string-trim stderr)))
                              (string-trim stderr))
                         (format "video-project 退出状态 %s" exit-code)))))))

(defun etaf-video-studio-backend--outcome (settled)
  "Return the callback result for the SETTLED `etaf-process-run' plist."
  (pcase (plist-get settled :status)
    ('timeout
     (list :ok nil :code "timeout"
           :message (format "请求超过 %s 秒未完成" etaf-video-studio-request-timeout)
           :hint "可重试；后台任务仍在运行"))
    ('failed
     (list :ok nil :code "external"
           :message (or (plist-get settled :message) "video-project 无法启动")))
    (_ (etaf-video-studio-backend--result
        (plist-get settled :exit) (plist-get settled :output)
        (plist-get settled :stderr)))))

(defun etaf-video-studio-backend-call (buffer args callback)
  "Run the video CLI with ARGS for BUFFER and call CALLBACK with the result.
ARGS is a list of strings after the executable, for example
(\"video-project\" \"status\" DIRECTORY); `--json' is appended here.  The
CALLBACK runs with BUFFER current and receives `(:ok t :data JSON)' or
`(:ok nil :code CODE :message MESSAGE :hint HINT)'.  A missing executable
reports `deps' immediately; the request itself never signals."
  (let* ((value etaf-video-studio-executable)
         (executable (if (file-name-directory value)
                         (let ((path (expand-file-name value)))
                           (and (file-executable-p path) path))
                       (executable-find value))))
    (if (null executable)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (funcall callback
                     (list :ok nil :code "deps"
                           :message (format "找不到 %s；请先安装或设置 `etaf-video-studio-executable'"
                                            etaf-video-studio-executable)
                           :hint "pi-skill video-project check"))))
      (let (job)
        (setq job
              (etaf-process-run
               (cons executable (append args (list "--json")))
               :name "etaf-video-studio"
               :timeout etaf-video-studio-request-timeout
               :callback
               (lambda (settled)
                 (etaf-video-studio-backend--unregister buffer job)
                 ;; A dead application buffer discards the result.
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (funcall callback
                              (etaf-video-studio-backend--outcome settled)))))))
        (etaf-video-studio-backend--register buffer job)
        job))))

(provide 'etaf-video-studio-backend)
;;; etaf-video-studio-backend.el ends here
