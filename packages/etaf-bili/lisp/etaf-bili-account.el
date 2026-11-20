;;; etaf-bili-account.el --- Bilibili sign-in, sign-out and status -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Signing in stays inside the running client: `etaf-ui-qr-login' paints one
;; centered panel over the library, which keeps its content and only dims.  The
;; panel shows the code the site returned and one status line; the phone method
;; is absent because Bilibili puts a graphical captcha in front of its SMS
;; endpoint, which no terminal can answer.
;;
;; The backend is `backends/bili/bili.mjs' in this repository: Node.js only, no
;; external skill, and it reads and writes the same `cookies.txt' curl uses, so
;; one sign-in covers every later request.  This file owns the request cycle --
;; starting the code, polling it, closing the panel and refreshing the account
;; -- and touches no UI presentation beyond the session's login ref.
;;
;; Only `etaf-bili-login', `etaf-bili-logout' and `etaf-bili-account' are public.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-bili-theme)
(require 'etaf-bili-model)

(defcustom etaf-bili-node-program "node"
  "Node.js executable that runs the bundled account backend."
  :type 'string
  :group 'etaf-bili)

(defcustom etaf-bili-backend-directory
  (expand-file-name "backends/bili"
                    (file-name-directory (or (locate-library "etaf-bili")
                                             load-file-name
                                             buffer-file-name)))
  "Directory holding this package's bundled Bilibili backend."
  :type 'directory
  :group 'etaf-bili)

(defcustom etaf-bili-backend-command nil
  "Command prefix that runs the account backend, or nil for the bundled one."
  :type '(repeat string)
  :group 'etaf-bili)

(defcustom etaf-bili-login-timeout 180
  "Seconds `etaf-bili-login' waits for the phone to confirm the code."
  :type 'number
  :group 'etaf-bili)

(defcustom etaf-bili-login-poll-interval 2
  "Seconds between two sign-in polls."
  :type 'number
  :group 'etaf-bili)

(defvar etaf-bili-account--process nil
  "Backend process currently answering an account request.")

(defvar etaf-bili--login-poll-timer nil
  "Timer polling the sign-in code the panel is showing.")

(declare-function etaf-bili-open "etaf-bili-app" ())

;;; Backend transport

(defun etaf-bili--backend-command ()
  "Return the command prefix that runs the account backend."
  (or etaf-bili-backend-command
      (list etaf-bili-node-program
            (expand-file-name "bili.mjs" etaf-bili-backend-directory))))

(defun etaf-bili--backend-settle (output errors callback)
  "Drain OUTPUT and ERRORS, then deliver the parsed backend reply to CALLBACK."
  (when-let* ((pipe (get-buffer-process errors)))
    (set-process-sentinel pipe #'ignore)
    (while (accept-process-output pipe 0)))
  (let* ((text (with-current-buffer output
                 (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
         (failure (with-current-buffer errors
                    (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
         (reply (condition-case nil
                    (json-parse-string text :object-type 'plist :array-type 'list
                                       :null-object nil :false-object nil)
                  (error nil))))
    (when (buffer-live-p output) (kill-buffer output))
    (when (buffer-live-p errors) (kill-buffer errors))
    (funcall callback
             (or reply
                 (list :ok nil :error "internal"
                       :message (if (string-empty-p failure)
                                    "Bilibili 后端没有返回结果"
                                  failure))))))

(defun etaf-bili--backend (args callback)
  "Run ARGS through the account backend and deliver CALLBACK a parsed plist."
  (let ((output (generate-new-buffer " *bili-backend*"))
        (errors (generate-new-buffer " *bili-backend-errors*")))
    (condition-case problem
        (setq etaf-bili-account--process
              (make-process
               :name "etaf-bili-backend" :buffer output :stderr errors
               :coding '(utf-8-unix . utf-8-unix) :noquery t
               :command (append (etaf-bili--backend-command) args)
               :sentinel (lambda (process _event)
                           (when (memq (process-status process) '(exit signal))
                             (while (accept-process-output process 0))
                             (setq etaf-bili-account--process nil)
                             (etaf-bili--backend-settle output errors callback)))))
      (error
       (kill-buffer output)
       (kill-buffer errors)
       (funcall callback (list :ok nil :error "internal"
                               :message (error-message-string problem)))))
    etaf-bili-account--process))

;;; Session state

(defun etaf-bili--session ()
  "Return the client session of the current buffer, if it has one."
  (and (bound-and-true-p etaf-bili--session) etaf-bili--session))

(defun etaf-bili--open-session ()
  "Return the current session, opening the client when none is mounted."
  (or (etaf-bili--session)
      (progn (etaf-bili-open) (etaf-bili--session))))

(defun etaf-bili--reload-sessions ()
  "Reload every mounted Bilibili session so new permissions apply."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when-let* ((session (etaf-bili--session)))
        (unless (etaf-bili--session-disposed session)
          (condition-case nil
              (etaf-bili-reload session)
            (error nil)))))))

(defun etaf-bili--account-set (session name)
  "Publish NAME as SESSION's account name; nil means signed out."
  (etaf-set-value (etaf-bili--session-account-ref session) name)
  name)

(defun etaf-bili--login-state (session &rest changes)
  "Return SESSION's sign-in state with CHANGES applied and publish it.
CHANGES is a plist merged into the current state, so callers name only the
keys they change: `:open', `:qr' and `:status'."
  (let ((state (copy-sequence (or (etaf-value (etaf-bili--session-login-ref session))
                                  (list :open nil :qr nil :status "")))))
    (while changes
      (setq state (plist-put state (pop changes) (pop changes))))
    (etaf-set-value (etaf-bili--session-login-ref session) state)
    state))

(defun etaf-bili--login-stop ()
  "Stop the polling timer; the panel and its state stay as they are."
  (when (timerp etaf-bili--login-poll-timer)
    (cancel-timer etaf-bili--login-poll-timer))
  (setq etaf-bili--login-poll-timer nil))

(defun etaf-bili--login-close (session)
  "Close SESSION's sign-in panel and stop polling."
  (etaf-bili--login-stop)
  (etaf-bili--login-state session :open nil))

(defun etaf-bili--login-status (session text)
  "Replace SESSION's sign-in status line with TEXT."
  (etaf-bili--login-state session :status text))

(defun etaf-bili--login-cancel (session)
  "Stop SESSION's sign-in and report the cancellation."
  (etaf-bili--login-close session)
  (message "已取消登录"))

;;; Accounts

(defun etaf-bili--account-query (session &optional quiet)
  "Ask the backend who SESSION belongs to and publish the answer.
QUIET reports only failures, which is what opening the client needs."
  (etaf-bili--backend
   (list "check")
   (lambda (reply)
     (unless (etaf-bili--session-disposed session)
       (cond
        ((not (plist-get reply :ok))
         (when quiet
           (message "%s" (or (plist-get reply :message) "账号查询失败"))))
        (t
         (etaf-bili--account-set session
                                 (and (plist-get reply :signed_in)
                                      (or (plist-get reply :name) "已登录")))))))))

;;; QR polling

(defun etaf-bili--login-schedule-poll (session key deadline)
  "Schedule SESSION's next sign-in poll of KEY before DEADLINE.
Every reply that leaves the panel open needs a new one-shot timer: the poll
runs once per timer, so a reply that only updates the status would stop
watching a code the phone has already scanned."
  (setq etaf-bili--login-poll-timer
        (run-at-time etaf-bili-login-poll-interval nil
                     #'etaf-bili--login-poll session key deadline)))

(defun etaf-bili--login-poll (session key deadline)
  "Poll SESSION's sign-in KEY until DEADLINE, then report the result."
  (cond
   ((or (null etaf-bili--login-poll-timer)
        (not (plist-get (etaf-value (etaf-bili--session-login-ref session)) :open)))
    (etaf-bili--login-stop))
   ((> (float-time) deadline)
    (etaf-bili--login-stop)
    (etaf-bili--login-status session "二维码已超时，请重新登录"))
   (t
    (etaf-bili--backend
     (list "login-poll" key)
     (lambda (reply)
       (when (plist-get (etaf-value (etaf-bili--session-login-ref session)) :open)
         (pcase (and (plist-get reply :ok) (plist-get reply :state))
           ("signed-in"
            (etaf-bili--login-close session)
            (etaf-bili--account-set session (or (plist-get reply :name) "已登录"))
            (message "已登录哔哩哔哩：%s" (or (plist-get reply :name) "当前账号"))
            (etaf-bili--reload-sessions))
           ("expired"
            (etaf-bili--login-stop)
            (etaf-bili--login-status session "二维码已过期，请重新登录"))
           ('nil
            (etaf-bili--login-status session (or (plist-get reply :message) "登录查询失败"))
            (etaf-bili--login-schedule-poll session key deadline))
           (_
            (etaf-bili--login-status
             session
             (if (equal "scanned" (plist-get reply :state))
                 "已扫码，请在手机上确认"
               "等待扫码…"))
            (etaf-bili--login-schedule-poll session key deadline)))))))))

(defun etaf-bili--login-start (session)
  "Fetch a fresh code for SESSION and begin polling it."
  (etaf-bili--login-stop)
  (etaf-bili--login-state session :status "正在获取二维码…" :qr nil)
  (etaf-bili--backend
   (list "login-start")
   (lambda (reply)
     (when (plist-get (etaf-value (etaf-bili--session-login-ref session)) :open)
       (if (or (not (plist-get reply :ok)) (null (plist-get reply :rows)))
           (etaf-bili--login-status session (or (plist-get reply :message) "无法获取二维码"))
         (let ((deadline (+ (float-time) etaf-bili-login-timeout))
               (key (plist-get reply :key)))
           (etaf-bili--login-state
            session
            :qr (etaf-ui-qr-paint (plist-get reply :rows))
            :status "等待扫码…")
           (etaf-bili--login-schedule-poll session key deadline)))))))
;;; Public commands

;;;###autoload
(defun etaf-bili-login (&optional session)
  "Show the Bilibili sign-in code over the running client.
SECTION defaults to the current buffer's session.  The code appears in the
`etaf-ui-qr-login' panel over the library, which keeps its content and only
dims; a phone (or a second Emacs on another machine) confirms the scan, and
the panel then closes, the account chip updates and the library reloads."
  (interactive)
  (when-let* ((session (or session (etaf-bili--open-session))))
    (when (plist-get (etaf-bili--session-login-ref session) :open)
      (etaf-bili--login-close session))
    (etaf-bili--login-state session :open t :qr nil :status "正在获取二维码…")
    (etaf-bili--login-start session)))

;;;###autoload
(defun etaf-bili-account-cancel (session)
  "Close SESSION's sign-in panel and stop polling for its code.
This is the dismissal the panel's own cancel button performs; callers use it
to release the poll when they close a session without confirming the scan."
  (etaf-bili--login-close session))

;;;###autoload
(defun etaf-bili-logout (&optional session)
  "Sign out of Bilibili and drop the stored cookies.
SESSION defaults to the current buffer's session."
  (interactive)
  (let ((session (or session (etaf-bili--open-session))))
    (when (yes-or-no-p "退出哔哩哔哩登录并清除本地 cookie？")
      (etaf-bili--backend
       (list "logout")
       (lambda (reply)
         (if (plist-get reply :ok)
             (progn
               (etaf-bili--login-close session)
               (etaf-bili--account-set session nil)
               (message "已退出哔哩哔哩登录")
               (etaf-bili--reload-sessions))
           (message "%s" (or (plist-get reply :message) "退出失败"))))))))

;;;###autoload
(defun etaf-bili-account (&optional session)
  "Report the Bilibili account the stored cookies belong to.
SESSION defaults to the current buffer's session."
  (interactive)
  (let ((live (or session (etaf-bili--session) (etaf-bili--open-session))))
    (etaf-bili--backend
     (list "check")
     (lambda (reply)
       (cond
        ((not (plist-get reply :ok))
         (message "%s" (or (plist-get reply :message) "账号查询失败")))
        ((plist-get reply :signed_in)
         (etaf-bili--account-set live (or (plist-get reply :name) "已登录"))
         (message "哔哩哔哩：%s" (or (plist-get reply :name) "已登录")))
        (t
         (etaf-bili--account-set live nil)
         (message "哔哩哔哩未登录：在页头按「登录」把扫码面板叠在应用上")))))))

(provide 'etaf-bili-account)
;;; etaf-bili-account.el ends here
