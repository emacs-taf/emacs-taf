;;; etaf-bili-account.el --- Bilibili sign-in, sign-out and status -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Signing in stays inside the running client: `etaf-ui-qr-login' paints one
;; centered panel over the library, which keeps its content and only dims.
;; The backend is `backends/bili/bili.mjs' in this repository: Node.js only,
;; sharing the exact `cookies.txt' jar configured by `etaf-bili-state-directory'.
;; Timers are owned per-session so multiple embedded hosts never collide.

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

(defun etaf-bili--package-root ()
  "Return the root directory of the installed or checked-out `etaf-bili' package."
  (let* ((desc (and (boundp 'package-alist)
                    (cadr (assq 'etaf-bili package-alist))))
         (pkg-dir (and desc (fboundp 'package-desc-dir) (package-desc-dir desc)))
         (candidates
          (delq nil
                (list (and pkg-dir (file-directory-p pkg-dir) pkg-dir)
                      (let ((lib (ignore-errors (locate-library "etaf-bili"))))
                        (and lib (not (string-suffix-p ".eln" lib))
                             (file-name-directory lib)))
                      (let ((src (or load-file-name buffer-file-name)))
                        (when (and src (not (string-suffix-p ".eln" src)))
                          (let ((dir (file-name-directory src)))
                            (if (string-suffix-p "/lisp/" dir)
                                (expand-file-name ".." dir)
                              dir))))))))
    (or (cl-find-if (lambda (dir)
                      (file-directory-p (expand-file-name "backends/bili" dir)))
                    candidates)
        (car candidates)
        default-directory)))

(defcustom etaf-bili-backend-directory
  (expand-file-name "backends/bili" (etaf-bili--package-root))
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

(declare-function etaf-bili-open "etaf-bili-app" ())

;;; Backend transport

(defun etaf-bili--backend-command ()
  "Return the command prefix that runs the account backend."
  (or etaf-bili-backend-command
      (list etaf-bili-node-program
            (expand-file-name "bili.mjs" etaf-bili-backend-directory))))

(defun etaf-bili--backend-reply (result)
  "Return the parsed backend reply for etaf-process RESULT."
  (if (eq (plist-get result :status) 'failed)
      (list :ok nil :error "internal"
            :message (or (plist-get result :message)
                         "Bilibili 后端没有返回结果"))
    (let* ((text (string-trim (or (plist-get result :output) "")))
           (failure (string-trim (or (plist-get result :stderr) "")))
           (reply (condition-case nil
                      (json-parse-string text :object-type 'plist :array-type 'list
                                         :null-object nil :false-object nil)
                    (error nil))))
      (or reply
          (list :ok nil :error "internal"
                :message (if (string-empty-p failure)
                             "Bilibili 后端没有返回结果"
                           failure))))))

(defun etaf-bili--backend (args callback &optional session)
  "Run ARGS through the account backend and deliver CALLBACK a parsed plist.
Passes `ETAF_BILI_STATE_DIRECTORY' and `ETAF_BILI_COOKIE_FILE' so the backend
and curl always share the same cookie jar."
  (let* ((state-dir (expand-file-name
                     (or (and session
                              (listp (etaf-bili--session-client session))
                              (plist-get (etaf-bili--session-client session) :state-directory))
                         etaf-bili-state-directory)))
         (cookie-file (expand-file-name "cookies.txt" state-dir))
         (process-environment
          (append (list (format "ETAF_BILI_STATE_DIRECTORY=%s" state-dir)
                        (format "ETAF_BILI_COOKIE_FILE=%s" cookie-file))
                  process-environment)))
    (etaf-process-run
     (append (etaf-bili--backend-command) args)
     :name "etaf-bili-backend"
     :output 'string
     :coding '(utf-8 . utf-8)
     :callback (lambda (result)
                 (funcall callback (etaf-bili--backend-reply result)))))
  nil)

;;; Session state

(defun etaf-bili--session ()
  "Return the client session of the current buffer, if it has one."
  (or (and (bound-and-true-p etaf-bili--session) etaf-bili--session)
      (let ((st (ignore-errors (etaf-app-state))))
        (and (etaf-bili--session-p st) st))))

(defun etaf-bili--open-session ()
  "Return the current session, opening the client when none is mounted."
  (or (etaf-bili--session)
      (progn (etaf-bili-open) (etaf-bili--session))))

(defun etaf-bili--reload-sessions ()
  "Invalidate stream caches and reload every mounted Bilibili session."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when-let* ((session (etaf-bili--session)))
        (unless (etaf-bili--session-disposed session)
          (etaf-bili--invalidate-play-cache session)
          (condition-case nil
              (etaf-bili-reload session)
            (error nil)))))))

(defun etaf-bili--account-set (session name &optional mid vip)
  "Publish account NAME, MID and VIP flag on SESSION; nil means signed out."
  (setf (etaf-bili--session-account-mid session) (and name mid)
        (etaf-bili--session-account-vip session) (and name vip t))
  (etaf-set-value (etaf-bili--session-account-ref session) name)
  name)

(defun etaf-bili--login-state (session &rest changes)
  "Return SESSION's sign-in state with CHANGES applied and publish it."
  (let ((state (copy-sequence (or (etaf-value (etaf-bili--session-login-ref session))
                                  (list :open nil :qr nil :status "")))))
    (while changes
      (setq state (plist-put state (pop changes) (pop changes))))
    (etaf-set-value (etaf-bili--session-login-ref session) state)
    state))

(defun etaf-bili--login-stop (&optional session)
  "Stop SESSION's polling timer; the panel and its state stay as they are."
  (when (and session (timerp (etaf-bili--session-login-timer session)))
    (cancel-timer (etaf-bili--session-login-timer session))
    (setf (etaf-bili--session-login-timer session) nil)))

(defun etaf-bili--login-close (session)
  "Close SESSION's sign-in panel and stop polling."
  (etaf-bili--login-stop session)
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
When QUIET is non-nil, failures stay silent instead of spamming the minibuffer."
  (etaf-bili--backend
   (list "check")
   (lambda (reply)
     (unless (etaf-bili--session-disposed session)
       (cond
        ((not (plist-get reply :ok))
         (unless quiet
           (message "%s" (or (plist-get reply :message) "账号查询失败"))))
        ((plist-get reply :signed_in)
         (etaf-bili--account-set session
                                 (or (plist-get reply :name) "已登录")
                                 (plist-get reply :account)
                                 (plist-get reply :vip)))
        (t
         (etaf-bili--account-set session nil nil nil)))))
   session))

;;; QR polling

(defun etaf-bili--login-schedule-poll (session key deadline)
  "Schedule SESSION's next sign-in poll of KEY before DEADLINE."
  (etaf-bili--login-stop session)
  (setf (etaf-bili--session-login-timer session)
        (run-at-time etaf-bili-login-poll-interval nil
                     #'etaf-bili--login-poll session key deadline)))

(defun etaf-bili--login-poll (session key deadline)
  "Poll SESSION's sign-in KEY until DEADLINE, then report the result."
  (cond
   ((or (etaf-bili--session-disposed session)
        (null (etaf-bili--session-login-timer session))
        (not (plist-get (etaf-value (etaf-bili--session-login-ref session)) :open)))
    (etaf-bili--login-stop session))
   ((> (float-time) deadline)
    (etaf-bili--login-stop session)
    (etaf-bili--login-status session "二维码已超时，请重新登录"))
   (t
    (etaf-bili--backend
     (list "login-poll" key)
     (lambda (reply)
       (when (and (not (etaf-bili--session-disposed session))
                  (plist-get (etaf-value (etaf-bili--session-login-ref session)) :open))
         (pcase (and (plist-get reply :ok) (plist-get reply :state))
           ("signed-in"
            (etaf-bili--login-close session)
            (etaf-bili--account-set session
                                    (or (plist-get reply :name) "已登录")
                                    (plist-get reply :account)
                                    (plist-get reply :vip))
            (message "已登录哔哩哔哩：%s" (or (plist-get reply :name) "当前账号"))
            (etaf-bili--reload-sessions))
           ("expired"
            (etaf-bili--login-stop session)
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
            (etaf-bili--login-schedule-poll session key deadline)))))
     session))))

(defun etaf-bili--login-start (session)
  "Fetch a fresh code for SESSION and begin polling it."
  (etaf-bili--login-stop session)
  (etaf-bili--login-state session :status "正在获取二维码…" :qr nil)
  (etaf-bili--backend
   (list "login-start")
   (lambda (reply)
     (when (and (not (etaf-bili--session-disposed session))
                (plist-get (etaf-value (etaf-bili--session-login-ref session)) :open))
       (if (or (not (plist-get reply :ok)) (null (plist-get reply :rows)))
           (etaf-bili--login-status session (or (plist-get reply :message) "无法获取二维码"))
         (let ((deadline (+ (float-time) etaf-bili-login-timeout))
               (key (plist-get reply :key)))
           (etaf-bili--login-state
            session
            :qr (etaf-ui-qr-paint (plist-get reply :rows))
            :status "等待扫码…")
           (etaf-bili--login-schedule-poll session key deadline)))))
   session))

;;; Public commands

;;;###autoload
(defun etaf-bili-login (&optional session)
  "Show the Bilibili sign-in code over the running client.
SESSION defaults to the current buffer's session."
  (interactive)
  (when-let* ((session (or session (etaf-bili--open-session))))
    (etaf-set-value (etaf-bili--session-account-menu-ref session) nil)
    (when (plist-get (etaf-value (etaf-bili--session-login-ref session)) :open)
      (etaf-bili--login-close session))
    (etaf-bili--login-state session :open t :qr nil :status "正在获取二维码…")
    (etaf-bili--login-start session)))

;;;###autoload
(defun etaf-bili-account-cancel (session)
  "Close SESSION's sign-in panel and stop polling for its code."
  (etaf-bili--login-close session))

;;;###autoload
(defun etaf-bili-logout (&optional session)
  "Sign out of Bilibili and drop the stored cookies.
SESSION defaults to the current or open buffer's session if any."
  (interactive)
  (let ((session (or session (etaf-bili--session))))
    (when (yes-or-no-p "退出哔哩哔哩登录并清除本地 cookie？")
      (when session
        (etaf-set-value (etaf-bili--session-account-menu-ref session) nil))
      (etaf-bili--backend
       (list "logout")
       (lambda (reply)
         (if (plist-get reply :ok)
             (progn
               (when session
                 (etaf-bili--login-close session)
                 (etaf-bili--account-set session nil nil nil)
                 (etaf-bili--invalidate-play-cache session))
               (message "已退出哔哩哔哩登录")
               (etaf-bili--reload-sessions))
           (message "%s" (or (plist-get reply :message) "退出失败"))))
       session))))

;;;###autoload
(defun etaf-bili-account (&optional session)
  "Report the Bilibili account the stored cookies belong to.
SESSION defaults to the current or open buffer's session if any."
  (interactive)
  (let ((live (or session (etaf-bili--session))))
    (etaf-bili--backend
     (list "check")
     (lambda (reply)
       (cond
        ((not (plist-get reply :ok))
         (message "%s" (or (plist-get reply :message) "账号查询失败")))
        ((plist-get reply :signed_in)
         (when live
           (etaf-bili--account-set live
                                   (or (plist-get reply :name) "已登录")
                                   (plist-get reply :account)
                                   (plist-get reply :vip)))
         (message "哔哩哔哩：%s%s"
                  (or (plist-get reply :name) "已登录")
                  (if (plist-get reply :vip) "（大会员）" "")))
        (t
         (when live (etaf-bili--account-set live nil nil nil))
         (message "哔哩哔哩未登录：在页头按「登录」把扫码面板叠在应用上"))))
     live)))

(provide 'etaf-bili-account)
;;; etaf-bili-account.el ends here
