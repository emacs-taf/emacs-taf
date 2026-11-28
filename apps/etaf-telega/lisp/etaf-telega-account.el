;;; etaf-telega-account.el --- Telegram sign-in and sign-out from Emacs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Telega owns the Telegram session and its authorization prompts, so these
;; commands stay thin: `etaf-telega-login' opens Telega, whose own flow asks for
;; the phone number and the code, and `etaf-telega-logout' ends that session
;; after a confirmation.  The client then reuses the session Telega keeps.
;;
;; Only `etaf-telega-login' and `etaf-telega-logout' are public.

;;; Code:

(declare-function telega "telega" (&optional arg))
(declare-function telega-logout "telega-tdlib" ())

(defun etaf-telega--require-telega (function)
  "Signal a readable error unless telega provides FUNCTION."
  (unless (fboundp function)
    (user-error "Telega 未安装或未加载；先安装 telega 再试")))

;;;###autoload
(defun etaf-telega-login ()
  "Open Telegram and complete the sign-in there when it is needed.
Telega runs its own authorization flow (phone number, code, password); this
command only makes sure the client and that flow are reachable from here."
  (interactive)
  (etaf-telega--require-telega 'telega)
  (telega)
  (message "Telegram：已打开 Telega；未登录时按它的提示输入手机号与验证码"))

;;;###autoload
(defun etaf-telega-logout ()
  "Sign out of Telegram after a confirmation.
The stored session is removed through Telega's own logout, so the next start
asks for the phone number again."
  (interactive)
  (etaf-telega--require-telega 'telega-logout)
  (when (yes-or-no-p "退出 Telegram 登录？")
    (telega-logout)
    (message "Telegram：已退出登录")))

(provide 'etaf-telega-account)
;;; etaf-telega-account.el ends here
