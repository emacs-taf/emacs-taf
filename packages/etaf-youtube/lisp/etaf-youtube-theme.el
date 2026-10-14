;;; etaf-youtube-theme.el --- Palette and ETAF UI theme for etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application paints its own surfaces instead of borrowing the user's
;; Emacs theme, so it looks the same in every session.  `etaf-youtube-color'
;; is the palette lookup used by the Views; `etaf-youtube-theme-defaults'
;; projects the same palette onto the ETAF UI token contract consumed by the
;; shared etaf-ui Components.

;;; Code:

(require 'etaf)

(define-error 'etaf-youtube-error "YouTube application error")

(defgroup etaf-youtube nil
  "Native YouTube client built with ETAF and Ebox."
  :group 'applications)

(defconst etaf-youtube--palettes
  '((dark
     :bg "#0F0F0F" :panel "#0F0F0F" :panel2 "#212121" :panel3 "#272727"
     :hover "#272727" :selected "#303030" :line "#303030" :line-soft "#212121"
     :ink "#F1F1F1" :muted "#AAAAAA" :dim "#717171"
     :accent "#FF0000" :accent-strong "#D90000" :accent-soft "#2A0A0A"
     :link "#3EA6FF" :ok "#2BA640" :danger "#FF4E45" :danger-bg "#2B0F0E"
     :success-bg "#0F2A14" :warn "#F5B942" :warn-bg "#2B230B"
     :badge "rgba(0,0,0,0.8)" :badge-ink "#FFFFFF" :scrim "#0F0F0F")
    (light
     :bg "#FFFFFF" :panel "#FFFFFF" :panel2 "#F2F2F2" :panel3 "#E5E5E5"
     :hover "#E5E5E5" :selected "#D9D9D9" :line "#E5E5E5" :line-soft "#F2F2F2"
     :ink "#0F0F0F" :muted "#606060" :dim "#909090"
     :accent "#FF0000" :accent-strong "#CC0000" :accent-soft "#FCE7E7"
     :link "#065FD4" :ok "#1D7A2E" :danger "#C00" :danger-bg "#FBE4E2"
     :success-bg "#E3F3E8" :warn "#A86B14" :warn-bg "#FBF0DA"
     :badge "rgba(0,0,0,0.8)" :badge-ink "#FFFFFF" :scrim "#0F0F0F"))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-youtube-theme-mode 'dark
  "Appearance used by a new application session.
`dark' (default) renders the video site's dark surface and `light' the light
one; this is independent of the active Emacs theme."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-youtube)

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
         (accent (etaf-youtube-color :accent mode))
         (accent-soft (etaf-youtube-color :accent-soft mode))
         (link (etaf-youtube-color :link mode))
         (ok (etaf-youtube-color :ok mode))
         (ok-bg (etaf-youtube-color :success-bg mode))
         (ok-border (if dark "#2E5C3F" "#A9D8BB"))
         (danger (etaf-youtube-color :danger mode))
         (danger-bg (etaf-youtube-color :danger-bg mode))
         (danger-border (if dark "#7A2A2C" "#E8B4AE"))
         (warn (etaf-youtube-color :warn mode))
         (warn-bg (etaf-youtube-color :warn-bg mode))
         (warn-border (if dark "#6B5423" "#E0C48A"))
         (info-bg (if dark "#14232F" "#E4F0FA"))
         (info-border (if dark "#2C4E66" "#A8CBE6")))
    (list
     :ink ink :paper bg :panel panel :line line :muted muted
     :accent accent :accent-soft accent-soft
     :ui-fg ink :ui-bg bg :ui-border line :ui-muted-fg muted
     :ui-disabled-fg muted :ui-disabled-bg panel :ui-disabled-border line
     :ui-accent accent :ui-accent-fg "#FFFFFF" :ui-accent-soft-bg accent-soft
     :ui-button-primary-fg "#FFFFFF" :ui-button-primary-bg accent
     :ui-button-secondary-fg accent :ui-button-secondary-bg accent-soft
     :ui-button-ghost-fg muted
     :ui-search-bg panel :ui-search-fg ink
     :ui-success-fg ok :ui-success-bg ok-bg :ui-success-border ok-border
     :ui-danger-fg danger :ui-danger-bg danger-bg :ui-danger-border danger-border
     :ui-warning-fg warn :ui-warning-bg warn-bg :ui-warning-border warn-border
     :ui-info-fg link :ui-info-bg info-bg :ui-info-border info-border
     :ui-panel-fg ink :ui-panel-bg panel :ui-panel-border line
     :ui-divider-bg line
     :ui-progress-track panel2 :ui-progress-value accent
     :ui-table-border line :ui-table-selected-fg accent
     :ui-table-selected-bg accent-soft
     :ui-shell-bg panel :ui-shell-fg ink :ui-shell-muted-fg muted
     :ui-shell-item-fg muted :ui-shell-item-minimized-fg muted
     :ui-window-bg bg :ui-window-fg ink :ui-window-border line
     :ui-window-title-bg panel :ui-window-title-fg muted
     :ui-window-title-active-fg ink
     :ui-picker-item-bg panel :ui-picker-item-fg ink
     :ui-picker-item-muted-fg muted
     :ui-pagination-muted-fg muted
     :ui-data-grid-error-fg danger
     :ui-checkbox-enabled-fg ink :ui-checkbox-disabled-fg muted)))

(defun etaf-youtube-colors (mode)
  "Return MODE's common palette as one plist for direct style use.
Views read the values by keyword instead of calling `etaf-youtube-color'
separately for every cell, so one mode change repaints the whole surface."
  (list :bg (etaf-youtube-color :bg mode)
        :panel (etaf-youtube-color :panel mode)
        :panel2 (etaf-youtube-color :panel2 mode)
        :panel3 (etaf-youtube-color :panel3 mode)
        :hover (etaf-youtube-color :hover mode)
        :selected (etaf-youtube-color :selected mode)
        :line (etaf-youtube-color :line mode)
        :ink (etaf-youtube-color :ink mode)
        :muted (etaf-youtube-color :muted mode)
        :dim (etaf-youtube-color :dim mode)
        :accent (etaf-youtube-color :accent mode)
        :link (etaf-youtube-color :link mode)
        :danger (etaf-youtube-color :danger mode)
        :danger-bg (etaf-youtube-color :danger-bg mode)
        :ok (etaf-youtube-color :ok mode)
        :badge (etaf-youtube-color :badge mode)
        :badge-ink (etaf-youtube-color :badge-ink mode)))

(provide 'etaf-youtube-theme)
;;; etaf-youtube-theme.el ends here
