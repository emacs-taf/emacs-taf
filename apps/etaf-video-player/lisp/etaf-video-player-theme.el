;;; etaf-video-player-theme.el --- Palette and ETAF UI theme for the video player -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:

(require 'etaf)
(require 'etaf-ui)

(defgroup etaf-video-player nil "Native video player built with ETAF and Ebox." :group 'multimedia)

(defconst etaf-video-player--palettes
  (list
   (cons 'dark (etaf-ui-host-theme-palette
                :mode 'dark :curated t :aliases t :bg "#111216" :fg "#F1F3F8"
                :surface-1 "#16181D" :surface-2 "#1B1D23" :surface-3 "#22252D" :track "#2C303A"
                :accent "#4C8DFF" :accent-fg "#FFFFFF" :accent-soft "#162542"
                :ok "#3DD68C" :warn "#F5B942" :danger "#FF6B72"
                :extras '(:stage "#08090C" :accent-text "#8BB4FF")))
   (cons 'light (etaf-ui-host-theme-palette
                 :mode 'light :curated t :aliases t :bg "#F7F8FA" :fg "#161922"
                 :surface-1 "#F2F4F8" :surface-2 "#FFFFFF" :surface-3 "#E9EDF4" :track "#D8DEE8"
                 :accent "#2563EB" :accent-fg "#FFFFFF" :accent-soft "#E3ECFF"
                 :ok "#1A7F4B" :warn "#B4690E" :danger "#C82834"
                 :extras '(:stage "#ECEFF4" :accent-text "#1D4ED8"))))
  "Obsidian Cinema (dark) and Alabaster Studio (light) palettes keyed by mode.")

(defcustom etaf-video-player-theme-mode 'dark
  "Appearance of the video player: `dark' or `light'."
  :type '(choice (const :tag "Dark (Obsidian Cinema)" dark)
                 (const :tag "Light (Alabaster Studio)" light))
  :group 'etaf-video-player)

(defun etaf-video-player--palette (&optional mode)
  "Return the palette plist for MODE or `etaf-video-player-theme-mode'."
  (cdr (assq (if (eq (or mode etaf-video-player-theme-mode) 'light) 'light 'dark)
             etaf-video-player--palettes)))

(defun etaf-video-player-color (key &optional mode)
  "Return the palette color named KEY for MODE."
  (unless mode (ignore-errors (etaf-theme-defaults)))
  (or (and (keywordp key) (plist-get (etaf-video-player--palette mode) key))
      (error "Unknown etaf-video-player color: %S" key)))

(defun etaf-video-player-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE."
  (let ((p (etaf-video-player--palette mode)))
    (etaf-ui-host-theme-tokens
     :palette p
     :overrides (list :ui-shell-bg (plist-get p :bg)
                      :ui-window-title-bg (plist-get p :panel2)
                      :ui-disabled-bg (plist-get p :panel3)))))

(provide 'etaf-video-player-theme)
;;; etaf-video-player-theme.el ends here
