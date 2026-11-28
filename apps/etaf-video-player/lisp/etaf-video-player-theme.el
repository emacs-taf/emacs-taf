;;; etaf-video-player-theme.el --- Palette and ETAF UI theme for the video player -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Obsidian Cinema (dark) and Alabaster Studio (light) palettes for the video
;; player.  The player paints a calm four-step neutral surface hierarchy so the
;; video stage stays the visual focal point, paired with high-contrast semantic
;; tokens for live status pills, A-B loop brackets, bookmarks and active tabs.
;; `etaf-video-player-color' looks up named roles, and
;; `etaf-video-player-theme-defaults' projects the same palette onto the shared
;; `etaf-ui-theme-tokens' contract.

;;; Code:

(require 'etaf)
(require 'etaf-ui)

(defgroup etaf-video-player nil
  "Native video player built with ETAF and Ebox."
  :group 'multimedia)

(defconst etaf-video-player--palettes
  '((dark :bg "#111216" :stage "#08090C" :surface "#16181D" :panel2 "#1B1D23"
          :panel3 "#22252D" :track "#2C303A"
          :line "#2A2D38" :line-strong "#3A3F4D"
          :ink "#F1F3F8" :muted "#9AA3B2" :dim "#687080"
          :accent "#4C8DFF" :accent-fg "#FFFFFF" :accent-soft "#162542"
          :accent-text "#8BB4FF" :accent-border "#294B8A"
          :ok "#3DD68C" :ok-bg "#122B20" :ok-border "#23573E"
          :warn "#F5B942" :warn-bg "#2E230F" :warn-border "#664C1B"
          :danger "#FF6B72" :danger-bg "#35161B" :danger-border "#6E2831")
    (light :bg "#F7F8FA" :stage "#ECEFF4" :surface "#F2F4F8" :panel2 "#FFFFFF"
           :panel3 "#E9EDF4" :track "#D8DEE8"
           :line "#DDE2EA" :line-strong "#C7CFD9"
           :ink "#161922" :muted "#586170" :dim "#8790A0"
           :accent "#2563EB" :accent-fg "#FFFFFF" :accent-soft "#E3ECFF"
           :accent-text "#1D4ED8" :accent-border "#AFC8FF"
           :ok "#1A7F4B" :ok-bg "#E3F6EC" :ok-border "#A5DFC0"
           :warn "#B4690E" :warn-bg "#FEF3DC" :warn-border "#E9C783"
           :danger "#C82834" :danger-bg "#FDE8EA" :danger-border "#F2B6BC"))
  "Obsidian Cinema (dark) and Alabaster Studio (light) palettes keyed by mode.")

(defcustom etaf-video-player-theme-mode 'dark
  "Appearance of the video player: `dark' or `light'.
Press `T' in the player buffer to switch between dark and light mode."
  :type '(choice (const :tag "Dark (Obsidian Cinema)" dark)
                 (const :tag "Light (Alabaster Studio)" light))
  :group 'etaf-video-player)

(defun etaf-video-player--effective-mode (&optional mode)
  "Return `light' or `dark' for MODE or `etaf-video-player-theme-mode'."
  (if (eq (or mode etaf-video-player-theme-mode) 'light) 'light 'dark))

(defun etaf-video-player-color (key &optional mode)
  "Return the palette color named KEY for MODE.
When MODE is nil inside a Component render, reading `etaf-theme-defaults'
subscribes the calling Component to theme switches automatically."
  (unless mode
    (ignore-errors (etaf-theme-defaults)))
  (let* ((mode (etaf-video-player--effective-mode mode))
         (palette (cdr (assq mode etaf-video-player--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (error "Unknown etaf-video-player color: %S" key))
    color))

(defun etaf-video-player-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE."
  (let* ((mode (etaf-video-player--effective-mode mode))
         (bg (etaf-video-player-color :bg mode))
         (surface (etaf-video-player-color :surface mode))
         (panel2 (etaf-video-player-color :panel2 mode))
         (panel3 (etaf-video-player-color :panel3 mode))
         (track (etaf-video-player-color :track mode))
         (ink (etaf-video-player-color :ink mode))
         (line (etaf-video-player-color :line mode))
         (muted (etaf-video-player-color :muted mode))
         (dim (etaf-video-player-color :dim mode))
         (accent (etaf-video-player-color :accent mode))
         (accent-fg (etaf-video-player-color :accent-fg mode))
         (accent-soft (etaf-video-player-color :accent-soft mode))
         (ok (etaf-video-player-color :ok mode))
         (ok-bg (etaf-video-player-color :ok-bg mode))
         (ok-border (etaf-video-player-color :ok-border mode))
         (warn (etaf-video-player-color :warn mode))
         (warn-bg (etaf-video-player-color :warn-bg mode))
         (warn-border (etaf-video-player-color :warn-border mode))
         (danger (etaf-video-player-color :danger mode))
         (danger-bg (etaf-video-player-color :danger-bg mode))
         (danger-border (etaf-video-player-color :danger-border mode)))
    (append
     (list :ui-shell-bg bg
           :ui-window-title-bg panel2
           :ui-disabled-bg panel3)
     (etaf-ui-theme-tokens
      (list :bg bg :fg ink :panel surface :track track :border line
            :muted muted :dim dim
            :accent accent :accent-fg accent-fg :accent-soft accent-soft
            :success ok :success-bg ok-bg :success-border ok-border
            :warning warn :warning-bg warn-bg :warning-border warn-border
            :danger danger :danger-bg danger-bg :danger-border danger-border
            :info accent :info-bg accent-soft
            :info-border (etaf-video-player-color :accent-border mode))))))

(provide 'etaf-video-player-theme)
;;; etaf-video-player-theme.el ends here
