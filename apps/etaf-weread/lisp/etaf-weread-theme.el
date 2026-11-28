;;; etaf-weread-theme.el --- Palette and ETAF UI theme for etaf-weread -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:

(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-weread-error "WeChat Reading reader error")
(defgroup etaf-weread nil "WeChat Reading client built with ETAF and Ebox." :group 'applications)

(defconst etaf-weread--palettes
  (list
   (cons 'dark (etaf-ui-host-theme-palette
                :mode 'dark :curated t :aliases t :bg "#191a1c" :fg "#E8ECF2"
                :surface-1 "#202225" :surface-2 "#25272b" :surface-3 "#2b2e33" :track "#2b2e33"
                :accent "#5B8DEF" :accent-fg "#FFFFFF" :accent-soft "#1A2436"
                :ok "#4FBF8B" :warn "#E4B15E" :danger "#FF7A85" :info "#6FB4E8"
                :extras '(:gold "#E4B15E" :selected "#25272b" :meter "#5B8DEF" :cover "#2b2e33" :quote "#8EA8D8")))
   (cons 'light (etaf-ui-host-theme-palette
                 :mode 'light :curated t :aliases t :bg "#FFFFFF" :fg "#1C2330"
                 :surface-1 "#F7F8FA" :surface-2 "#EDF0F4" :surface-3 "#E1E6EC" :track "#E1E6EC"
                 :accent "#2F6FED" :accent-fg "#FFFFFF" :accent-soft "#E8EFFD"
                 :ok "#2E7D5B" :warn "#B07A16" :danger "#C0392B" :info "#2C6FA8"
                 :extras '(:gold "#B07A16" :selected "#EDF0F4" :meter "#2F6FED" :cover "#E1E6EC" :quote "#4A6FC0")))
   (cons 'sepia (etaf-ui-host-theme-palette
                 :mode 'light :curated t :aliases t :bg "#F4EBD9" :fg "#3B3225"
                 :surface-1 "#EFE4CD" :surface-2 "#E7D8BC" :surface-3 "#DCC9A6" :track "#DCC9A6"
                 :accent "#8A6A2F" :accent-fg "#FFFFFF" :accent-soft "#EDE0C4"
                 :ok "#4C7A54" :warn "#9A6B1F" :danger "#A5442F" :info "#4A6E8A"
                 :extras '(:gold "#8A6A2F" :selected "#E4D3B2" :meter "#8A6A2F" :cover "#DCC9A6" :quote "#7A6440"))))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-weread-theme-mode 'dark
  "Appearance a new Emacs session starts with: `dark', `light' or `sepia'."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light) (const :tag "Sepia" sepia))
  :group 'etaf-weread)

(defvar etaf-weread--theme-mode (etaf-ref etaf-weread-theme-mode) "Live appearance of the reader.")
(defconst etaf-weread--surface-modes '((light . "亮") (auto . "随") (dark . "暗")) "Host switch modes.")

(defun etaf-weread--current-mode (&optional mode)
  "Return the palette mode to paint MODE, or the reader's live mode."
  (let* ((m (or mode (etaf-value etaf-weread--theme-mode)))
         (r (if (eq m 'auto) (etaf-appearance) m)))
    (if (assq r etaf-weread--palettes) r 'dark)))

(defun etaf-weread-color (key &optional mode)
  "Return the palette color named KEY, signaling `etaf-weread-error' if unknown."
  (or (and (keywordp key) (plist-get (cdr (assq (etaf-weread--current-mode mode) etaf-weread--palettes)) key))
      (signal 'etaf-weread-error (list (format "Unknown color: %S" key)))))

(defun etaf-weread-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE."
  (etaf-ui-host-theme-tokens :palette (cdr (assq (etaf-weread--current-mode mode) etaf-weread--palettes))))

(provide 'etaf-weread-theme)
;;; etaf-weread-theme.el ends here
