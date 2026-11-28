;;; etaf-youtube-theme.el --- Palette and ETAF UI theme for etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application paints its own four-tier Obsidian Cinema (dark) and
;; Editorial Daylight (light) surfaces instead of borrowing the user's Emacs
;; theme, while keeping the cinema video stage pure dark (#050608) in both
;; modes.  `etaf-youtube-color' is the palette lookup used by Views;
;; `etaf-youtube-theme-defaults' projects the same palette onto the ETAF UI
;; token contract consumed by shared etaf-ui Components.

;;; Code:

(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-youtube-error "YouTube application error")

(defgroup etaf-youtube nil
  "Native YouTube client built with ETAF and Ebox."
  :group 'applications)

(defconst etaf-youtube--palettes
  '((dark
     :bg "#0B0C0F" :panel "#12141A" :surface "#12141A"
     :panel2 "#181B23" :panel3 "#222632"
     :hover "#1E222E" :selected "#242938"
     :line "#252A37" :line-soft "#1B1F2A"
     :ink "#ECEFF4" :muted "#9EA7B8" :dim "#6B7487" :avatar-bg "#2A3040"
     :accent "#FF3D3D" :accent-strong "#E02828" :accent-soft "#31161A"
     :link "#58A6FF" :ok "#3FB950" :danger "#F85149" :danger-bg "#2D1418"
     :success-bg "#11281B" :warn "#E3B341" :warn-bg "#2B220F"
     :badge "#090B0E" :badge-ink "#F4F6FA" :scrim "#050608")
    (light
     :bg "#F2F3F7" :panel "#FFFFFF" :surface "#FFFFFF"
     :panel2 "#F7F8FB" :panel3 "#E8EBF1"
     :hover "#ECEFF5" :selected "#E2E6EF"
     :line "#DFE3EC" :line-soft "#ECEFF5"
     :ink "#11141B" :muted "#555E6F" :dim "#828C9F" :avatar-bg "#667085"
     :accent "#D91E18" :accent-strong "#B81410" :accent-soft "#FDEAEB"
     :link "#0969DA" :ok "#1A7F37" :danger "#CF222E" :danger-bg "#FFEBE9"
     :success-bg "#DAFBE1" :warn "#9A6700" :warn-bg "#FFF8C5"
     :badge "#11141B" :badge-ink "#FFFFFF" :scrim "#050608"))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-youtube-theme-mode 'dark
  "Appearance used by a new application session.
`dark' (default) renders the Obsidian Cinema dark surface and `light' the
Editorial Daylight surface; this is independent of the active Emacs theme.
The running choice is the session's mode cell, which the header toggle and a
panel's switch both write."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-youtube)

(defconst etaf-youtube--surface-modes
  '((light . "亮") (dark . "暗"))
  "Appearance modes the client offers its host, in display order.")

(defun etaf-youtube-color (key &optional mode)
  "Return the palette color named KEY.
MODE defaults to `etaf-youtube-theme-mode'; an unknown mode falls back to
`dark'.  An unknown KEY signals `etaf-youtube-error' instead of returning a
fallback, because a typo would otherwise paint an invisible surface."
  (let* ((mode (let ((mode (or mode etaf-youtube-theme-mode)))
                 (if (assq mode etaf-youtube--palettes) mode 'dark)))
         (palette (cdr (assq mode etaf-youtube--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (signal 'etaf-youtube-error (list (format "Unknown color: %S" key))))
    color))

(defun etaf-youtube-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE.
MODE defaults to `etaf-youtube-theme-mode'.  The result is passed to
`etaf-theme-provide' by the application so shared etaf-ui Components use the
same colors as the application's own Views."
  (let* ((dark (eq (or mode etaf-youtube-theme-mode) 'dark))
         (bg (etaf-youtube-color :bg mode))
         (panel (etaf-youtube-color :panel2 mode))
         (panel2 (etaf-youtube-color :panel3 mode))
         (ink (etaf-youtube-color :ink mode))
         (line (etaf-youtube-color :line mode))
         (muted (etaf-youtube-color :muted mode))
         (dim (etaf-youtube-color :dim mode))
         (accent (etaf-youtube-color :accent mode))
         (accent-soft (etaf-youtube-color :accent-soft mode))
         (link (etaf-youtube-color :link mode))
         (ok (etaf-youtube-color :ok mode))
         (ok-bg (etaf-youtube-color :success-bg mode))
         (ok-border (if dark "#2A573B" "#9AD5B0"))
         (danger (etaf-youtube-color :danger mode))
         (danger-bg (etaf-youtube-color :danger-bg mode))
         (danger-border (if dark "#7A2A2C" "#E8B4AE"))
         (warn (etaf-youtube-color :warn mode))
         (warn-bg (etaf-youtube-color :warn-bg mode))
         (warn-border (if dark "#6B5423" "#E0C48A"))
         (info-bg (if dark "#142336" "#E6F1FC"))
         (info-border (if dark "#2C4E73" "#A8CBEB")))
    (append
     (list :ink ink :paper bg :panel panel :line line :muted muted
           :accent accent :accent-soft accent-soft
           :ui-button-secondary-fg ink :ui-button-secondary-bg panel
           :ui-button-secondary-hover-bg (etaf-youtube-color :hover mode)
           :ui-button-ghost-fg ink
           :ui-button-ghost-hover-bg (etaf-youtube-color :hover mode)
           :ui-search-bg panel :ui-search-fg ink)
     (etaf-ui-theme-tokens
      (list :bg bg :fg ink :panel panel :track panel2 :border line
            :muted muted :dim dim :accent accent :accent-fg "#FFFFFF"
            :accent-soft accent-soft
            :success ok :success-bg ok-bg :success-border ok-border
            :warning warn :warning-bg warn-bg :warning-border warn-border
            :danger danger :danger-bg danger-bg :danger-border danger-border
            :info link :info-bg info-bg :info-border info-border)))))

(defun etaf-youtube-colors (mode)
  "Return MODE's common palette as one plist for direct style use."
  (list :bg (etaf-youtube-color :bg mode)
        :panel (etaf-youtube-color :panel mode)
        :surface (etaf-youtube-color :surface mode)
        :panel2 (etaf-youtube-color :panel2 mode)
        :panel3 (etaf-youtube-color :panel3 mode)
        :hover (etaf-youtube-color :hover mode)
        :selected (etaf-youtube-color :selected mode)
        :line (etaf-youtube-color :line mode)
        :line-soft (etaf-youtube-color :line-soft mode)
        :ink (etaf-youtube-color :ink mode)
        :muted (etaf-youtube-color :muted mode)
        :dim (etaf-youtube-color :dim mode)
        :accent (etaf-youtube-color :accent mode)
        :accent-strong (etaf-youtube-color :accent-strong mode)
        :accent-soft (etaf-youtube-color :accent-soft mode)
        :link (etaf-youtube-color :link mode)
        :danger (etaf-youtube-color :danger mode)
        :danger-bg (etaf-youtube-color :danger-bg mode)
        :ok (etaf-youtube-color :ok mode)
        :warn (etaf-youtube-color :warn mode)
        :avatar-bg (etaf-youtube-color :avatar-bg mode)
        :badge (etaf-youtube-color :badge mode)
        :badge-ink (etaf-youtube-color :badge-ink mode)
        :scrim (etaf-youtube-color :scrim mode)))

(provide 'etaf-youtube-theme)
;;; etaf-youtube-theme.el ends here
