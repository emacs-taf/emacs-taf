;;; etaf-youtube-theme.el --- Palette and ETAF UI theme for etaf-youtube -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:

(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-youtube-error "YouTube application error")
(defgroup etaf-youtube nil "Native YouTube client built with ETAF and Ebox." :group 'applications)

(defconst etaf-youtube--palettes
  (list
   (cons 'dark (etaf-ui-host-theme-palette
                :mode 'dark :curated t :aliases t :bg "#0B0C0F" :fg "#ECEFF4"
                :surface-1 "#12141A" :surface-2 "#181B23" :surface-3 "#222632" :track "#222632"
                :accent "#FF3D3D" :accent-fg "#FFFFFF" :accent-soft "#31161A" :info "#58A6FF"
                :extras '(:accent-strong "#E02828" :link "#58A6FF" :avatar-bg "#2A3040"
                          :badge "#090B0E" :badge-ink "#F4F6FA" :scrim "#050608")))
   (cons 'light (etaf-ui-host-theme-palette
                 :mode 'light :curated t :aliases t :bg "#F2F3F7" :fg "#11141B"
                 :surface-1 "#FFFFFF" :surface-2 "#F7F8FB" :surface-3 "#E8EBF1" :track "#E8EBF1"
                 :accent "#D91E18" :accent-fg "#FFFFFF" :accent-soft "#FDEAEB" :info "#0969DA"
                 :extras '(:accent-strong "#B81410" :link "#0969DA" :avatar-bg "#667085"
                           :badge "#11141B" :badge-ink "#FFFFFF" :scrim "#050608"))))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-youtube-theme-mode 'dark
  "Appearance used by a new application session: `dark' or `light'."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-youtube)

(defconst etaf-youtube--surface-modes '((light . "亮") (dark . "暗")) "Host switch modes.")

(defun etaf-youtube-colors (mode)
  "Return MODE's common palette as one plist for direct style use."
  (let ((v (or mode etaf-youtube-theme-mode)))
    (copy-sequence (cdr (assq (if (assq v etaf-youtube--palettes) v 'dark) etaf-youtube--palettes)))))

(defun etaf-youtube-color (key &optional mode)
  "Return the palette color named KEY, signaling `etaf-youtube-error' if unknown."
  (or (and (keywordp key) (plist-get (etaf-youtube-colors mode) key))
      (signal 'etaf-youtube-error (list (format "Unknown color: %S" key)))))

(defun etaf-youtube-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE."
  (let* ((p (etaf-youtube-colors mode))
         (p2 (plist-get p :panel2)) (ink (plist-get p :ink)) (hover (plist-get p :hover)))
    (etaf-ui-host-theme-tokens
     :palette (plist-put (copy-sequence p) :surface-1 p2)
     :overrides (list :ink ink :paper (plist-get p :bg) :panel p2 :line (plist-get p :line)
                      :muted (plist-get p :muted) :accent (plist-get p :accent)
                      :accent-soft (plist-get p :accent-soft)
                      :ui-button-secondary-fg ink :ui-button-secondary-bg p2
                      :ui-button-secondary-hover-bg hover :ui-button-ghost-fg ink
                      :ui-button-ghost-hover-bg hover :ui-search-bg p2 :ui-search-fg ink))))

(provide 'etaf-youtube-theme)
;;; etaf-youtube-theme.el ends here
