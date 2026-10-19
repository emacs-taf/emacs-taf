;;; etaf-youtube-login.el --- Sign in to YouTube from Emacs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Account access is one command inside Emacs.  The bundled backend owns the
;; browser: `etaf-youtube-login' opens (or reuses) the controlled Chrome page,
;; then polls the account until the page reports a signed-in session.  Nobody
;; has to leave Emacs and type a skill command, and no credential is stored in
;; Emacs -- the browser keeps the session, the backend reads it.
;;
;; Only `etaf-youtube-login' and `etaf-youtube-account' are public.  Both take
;; an optional session so a caller (and the public suite) can drive them
;; through its own transport instead of the standalone one.

;;; Code:

(require 'cl-lib)
(require 'etaf-youtube-service)

(defcustom etaf-youtube-login-timeout 180
  "Seconds `etaf-youtube-login' waits for the browser sign-in to finish."
  :type 'number
  :group 'etaf-youtube)

(defvar etaf-youtube--model)                  ; buffer-local, defined in etaf-youtube-app
(declare-function etaf-youtube-refresh "etaf-youtube-model" (app))
(declare-function etaf-youtube-check "etaf-youtube-model" (app))

(defvar etaf-youtube-login--service nil
  "Service used by the account commands outside a mounted application.")

(defun etaf-youtube--account-service (model)
  "Return the service for MODEL, or the standalone one when MODEL is nil."
  (or (and model (plist-get model :service))
      etaf-youtube-login--service
      (setq etaf-youtube-login--service (etaf-youtube-service-create))))

(defun etaf-youtube--signed-in (result)
  "Return the account payload of a successful RESULT, or nil."
  (let ((value (plist-get result :value)))
    (and (eq 'ok (plist-get result :status))
         (eq t (plist-get value :signed_in))
         value)))

(defun etaf-youtube--refresh-open-sessions ()
  "Reload every mounted YouTube session so new permissions apply."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (bound-and-true-p etaf-youtube--model)
                 (buffer-live-p buffer))
        (condition-case nil
            (etaf-youtube-refresh etaf-youtube--model)
          (error nil))))))

(defun etaf-youtube--login-report (model value)
  "Report VALUE as the signed-in account and refresh MODEL's session."
  (message "已登录 YouTube：%s" (or (plist-get value :name) "当前账号"))
  (if model
      (progn
        (condition-case nil (etaf-youtube-check model) (error nil))
        (condition-case nil (etaf-youtube-refresh model) (error nil)))
    (etaf-youtube--refresh-open-sessions)))

(defun etaf-youtube--login-poll (model deadline)
  "Poll MODEL's account until DEADLINE, reporting the sign-in result."
  (etaf-youtube-service-call
   (etaf-youtube--account-service model)
   '("check")
   (lambda (result)
     (cond
      ((etaf-youtube--signed-in result)
       (etaf-youtube--login-report model (plist-get result :value)))
      ((< (float-time) deadline)
       (run-at-time 2 nil #'etaf-youtube--login-poll model deadline))
      (t
       (message "仍未登录 YouTube：%s"
                (or (plist-get result :message)
                    "请在弹出的浏览器窗口里完成登录")))))
   'etaf-youtube-login))

;;;###autoload
(defun etaf-youtube-login (&optional model)
  "Sign in to YouTube in the controlled browser, then refresh.
With MODEL, drive that session's transport and reload it afterwards; without
one, open a YouTube page in the controlled browser and refresh every mounted
session.  The bundled backend keeps the browser session, so Emacs stores no
credential."
  (interactive)
  (let ((deadline (+ (float-time) etaf-youtube-login-timeout)))
    (message "正在打开受控浏览器…")
    (etaf-youtube-service-call
     (etaf-youtube--account-service model)
     '("login")
     (lambda (result)
       (if-let* ((value (etaf-youtube--signed-in result)))
           (etaf-youtube--login-report model value)
         (etaf-youtube--login-poll model deadline)))
     'etaf-youtube-login)
    nil))

;;;###autoload
(defun etaf-youtube-logout (&optional model)
  "Sign out of YouTube in the controlled browser.
The bundled backend clears this site's cookies and storage, then reloads the
open sessions so the signed-out account shows immediately."
  (interactive)
  (when (yes-or-no-p "退出 YouTube 登录（清除受控浏览器里的 YouTube 会话）？")
    (etaf-youtube-service-call
     (etaf-youtube--account-service model)
     '("logout")
     (lambda (result)
       (if (eq 'ok (plist-get result :status))
           (progn
             (message "已退出 YouTube 登录")
             (if model
                 (condition-case nil (etaf-youtube-check model) (error nil))
               (etaf-youtube--refresh-open-sessions)))
         (message "退出失败：%s" (or (plist-get result :message) "后端没有返回原因"))))
     'etaf-youtube-logout))
  nil)

;;;###autoload
(defun etaf-youtube-account (&optional model)
  "Report the YouTube account the controlled browser is signed in to.
MODEL selects a session's transport; without one the standalone transport is
used."
  (interactive)
  (etaf-youtube-service-call
   (etaf-youtube--account-service model)
   '("check")
   (lambda (result)
     (if-let* ((value (etaf-youtube--signed-in result)))
         (message "YouTube：%s" (or (plist-get value :name) "已登录"))
       (message "YouTube 未登录：%s"
                (or (plist-get result :message) "运行 M-x etaf-youtube-login"))))
   'etaf-youtube-account)
  nil)

(provide 'etaf-youtube-login)
;;; etaf-youtube-login.el ends here
