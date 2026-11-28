;;; etaf-ncm-theme.el --- Palette and ETAF UI theme for etaf-ncm -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:

(require 'etaf)
(require 'etaf-ui)

(defgroup etaf-ncm nil "NetEase Cloud Music player built with ETAF and Ebox." :group 'applications)

(defconst etaf-ncm--palettes
  (list
   (cons 'dark (etaf-ui-host-theme-palette
                :mode 'dark :curated t :aliases t :bg "#191a1c" :fg "#E9ECF1"
                :surface-1 "#202225" :surface-2 "#25272b" :surface-3 "#2b2e33" :track "#2b2e33"
                :accent "#EC4141" :accent-fg "#FFFFFF" :accent-soft "#2A1619"
                :ok "#4FB477" :warn "#E8B45C" :danger "#FF7A7A" :info "#6FB4E8"
                :extras '(:gold "#E8B45C" :playing "#EC4141" :selected "#25272b" :meter "#EC4141" :cover "#2b2e33")))
   (cons 'light (etaf-ui-host-theme-palette
                 :mode 'light :curated t :aliases t :bg "#FFFFFF" :fg "#1B1F24"
                 :surface-1 "#F6F7F9" :surface-2 "#EFF1F4" :surface-3 "#E4E7EB" :track "#E4E7EB"
                 :accent "#D8232A" :accent-fg "#FFFFFF" :accent-soft "#FBE9EA"
                 :ok "#2E7D4F" :warn "#B07A16" :danger "#C0392B" :info "#2C6FA8"
                 :extras '(:gold "#B07A16" :playing "#D8232A" :selected "#EFF1F4" :meter "#D8232A" :cover "#E4E7EB"))))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-ncm-theme-mode 'auto
  "Appearance a new Emacs session starts with: `auto', `dark' or `light'."
  :type '(choice (const :tag "Follow the host" auto) (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-ncm)

(defvar etaf-ncm--theme-mode (etaf-ref etaf-ncm-theme-mode) "Live appearance of the player.")
(defconst etaf-ncm--theme-modes '((light . "亮") (auto . "随") (dark . "暗")) "Host switch modes.")

(defun etaf-ncm--effective-mode (&optional mode)
  "Return `light' or `dark' for MODE, the player's mode or the host appearance."
  (let* ((m (or mode (etaf-value etaf-ncm--theme-mode)))
         (m (if (eq m 'auto) (etaf-appearance) m)))
    (if (eq m 'light) 'light 'dark)))

(defun etaf-ncm-color (key &optional mode)
  "Return the palette color named KEY, signaling `etaf-ncm-error' if unknown."
  (or (and (keywordp key) (plist-get (cdr (assq (etaf-ncm--effective-mode mode) etaf-ncm--palettes)) key))
      (signal 'etaf-ncm-error (list (format "Unknown color: %S" key)))))

(defun etaf-ncm-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE."
  (etaf-ui-host-theme-tokens :palette (cdr (assq (etaf-ncm--effective-mode mode) etaf-ncm--palettes))))

(provide 'etaf-ncm-theme)
;;; etaf-ncm-theme.el ends here
