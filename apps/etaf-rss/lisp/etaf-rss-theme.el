;;; etaf-rss-theme.el --- Palette and ETAF UI theme for etaf-rss -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:

(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-rss-error "RSS reader error")
(defgroup etaf-rss nil "RSS reader built with ETAF and Ebox." :group 'applications)

(defconst etaf-rss--palettes
  (list
   (cons 'dark (etaf-ui-host-theme-palette
                :mode 'dark :curated t :aliases t :bg "#0E1116" :fg "#E9EDF3"
                :surface-1 "#141920" :surface-2 "#1A212B" :surface-3 "#222B37" :track "#222B37"
                :select "#1E2733" :accent "#E8A33D" :accent-fg "#FFFFFF" :accent-soft "#2B2317"
                :ok "#4FBF8B" :warn "#E8A33D" :danger "#FF7A85" :info "#6FB4E8"
                :extras '(:gold "#E8A33D" :unread "#E9EDF3" :read "#98A3B3" :feed "#6FB4E8" :quote "#9CB4D4" :time "#647080")))
   (cons 'light (etaf-ui-host-theme-palette
                 :mode 'light :curated t :aliases t :bg "#FFFFFF" :fg "#1B2431"
                 :surface-1 "#F7F8FA" :surface-2 "#EDF0F4" :surface-3 "#E2E7ED" :track "#E2E7ED"
                 :select "#F0F2F6" :accent "#B26A10" :accent-fg "#FFFFFF" :accent-soft "#FBF0DD"
                 :ok "#2E7D5B" :warn "#A86B14" :danger "#C0392B" :info "#2C6FA8"
                 :extras '(:gold "#A86B14" :unread "#1B2431" :read "#6C7686" :feed "#2C6FA8" :quote "#3F66A0" :time "#7A8494"))))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-rss-theme-mode 'dark
  "Appearance used by a new reader session: `dark' or `light'."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-rss)

(defconst etaf-rss--surface-modes '((light . "亮") (dark . "暗")) "Host switch modes.")
(defvar etaf-rss--theme-mode (etaf-ref etaf-rss-theme-mode) "Live appearance of the reader.")

(defun etaf-rss--palette (&optional mode)
  "Return the palette plist for MODE or the live mode."
  (let ((m (or mode (etaf-value etaf-rss--theme-mode))))
    (cdr (assq (if (assq m etaf-rss--palettes) m 'dark) etaf-rss--palettes))))

(defun etaf-rss-color (key &optional mode)
  "Return the palette color named KEY, signaling `etaf-rss-error' if unknown."
  (or (and (keywordp key) (plist-get (etaf-rss--palette mode) key))
      (signal 'etaf-rss-error (list (format "Unknown color: %S" key)))))

(defun etaf-rss-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE."
  (etaf-ui-host-theme-tokens :palette (etaf-rss--palette mode)))

(provide 'etaf-rss-theme)
;;; etaf-rss-theme.el ends here
