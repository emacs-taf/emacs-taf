;;; etaf-bili-theme.el --- Palette and ETAF UI theme for etaf-bili -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The client renders its own surface instead of borrowing the user's Emacs
;; theme, so it looks the same in every session.  `etaf-bili-color' is the
;; palette lookup used by the Views; `etaf-bili-theme-defaults' projects the
;; same palette onto the ETAF UI token contract consumed by etaf-ui
;; Components.  Both appearances share one layout and paint four depth steps
;; -- page, card, raised surface and control track -- so the columns stay
;; visually separated in either mode.  The accent is Bilibili pink.

;;; Code:

(require 'etaf)

(defgroup etaf-bili nil
  "Bilibili client built with ETAF and Ebox."
  :group 'applications)

(defconst etaf-bili--palettes
  '((dark
     :bg "#0A0D12" :surface "#141820" :panel2 "#1B202B" :panel3 "#232A38"
     :hover "#1D232F" :line "#2A303D"
     :ink "#E9EDF4" :muted "#9AA4B4" :dim "#6B7484"
     :accent "#FB7299" :accent-soft "#3A1D28"
     :gold "#E8B45C" :ok "#4FB477" :warn "#E8B45C"
     :danger "#FF7A7A" :danger-bg "#3A1D22" :info "#6FB4E8")
    (light
     :bg "#ECEEF2" :surface "#FFFFFF" :panel2 "#F5F6F9" :panel3 "#E3E6EC"
     :hover "#F0F2F6" :line "#DADEE5"
     :ink "#171A20" :muted "#5B6472" :dim "#8B93A0"
     :accent "#D64D7C" :accent-soft "#FCE8EF"
     :gold "#B07A16" :ok "#2E7D4F" :warn "#B07A16"
     :danger "#C0392B" :danger-bg "#FBE4E2" :info "#2C6FA8"))
  "Palette of every supported appearance, keyed by mode.
`:bg' is the page shell, `:surface' a pane or card, `:panel2' the header,
footer and transport, `:panel3' a control track.")

(defcustom etaf-bili-theme-mode 'dark
  "Appearance used by a new client.
`dark' (default) or `light', independent of the active Emacs theme."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-bili)

(defconst etaf-bili--theme-modes '((dark . "暗") (light . "亮"))
  "Appearances a client and the panel that frames it switch between.")

(defvar etaf-bili--theme-mode-ref (etaf-ref etaf-bili-theme-mode)
  "Appearance cell shared by the mounted client and the panel that frames it.
`etaf-bili-toggle-theme' and a panel's title-bar switch write it, so the card
grid and the surface around it repaint from one state.")

(defun etaf-bili-color (key &optional mode)
  "Return the palette color named KEY.
MODE defaults to `etaf-bili-theme-mode'.  An unknown KEY signals an error
instead of painting an invisible surface."
  (let* ((mode (if (eq (or mode etaf-bili-theme-mode) 'light) 'light 'dark))
         (palette (cdr (assq mode etaf-bili--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (error "Unknown etaf-bili color: %S" key))
    color))

(defun etaf-bili-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE.
The application passes the result to `etaf-theme-provide' so shared etaf-ui
Components use the same colors as the client's own Views."
  (let* ((dark (not (eq (or mode etaf-bili-theme-mode) 'light)))
         (bg (etaf-bili-color :bg mode))
         (surface (etaf-bili-color :surface mode))
         (panel2 (etaf-bili-color :panel2 mode))
         (panel3 (etaf-bili-color :panel3 mode))
         (ink (etaf-bili-color :ink mode))
         (line (etaf-bili-color :line mode))
         (muted (etaf-bili-color :muted mode))
         (dim (etaf-bili-color :dim mode))
         (accent (etaf-bili-color :accent mode))
         (accent-soft (etaf-bili-color :accent-soft mode))
         (ok (etaf-bili-color :ok mode))
         (ok-bg (if dark "#17301F" "#E3F3E8"))
         (ok-border (if dark "#2E5C3F" "#A9D8BB"))
         (danger (etaf-bili-color :danger mode))
         (danger-bg (etaf-bili-color :danger-bg mode))
         (danger-border (if dark "#7A2A2C" "#E8B4AE"))
         (warn (etaf-bili-color :warn mode))
         (warn-bg (if dark "#33280F" "#FBF0DA"))
         (warn-border (if dark "#6B5423" "#E0C48A"))
         (info (etaf-bili-color :info mode))
         (info-bg (if dark "#14232F" "#E4F0FA"))
         (info-border (if dark "#2C4E66" "#A8CBE6")))
    (list
     :ink ink :paper bg :panel surface :line line :muted muted
     :accent accent :accent-soft accent-soft
     :ui-fg ink :ui-bg bg :ui-border line :ui-muted-fg muted
     :ui-disabled-fg dim :ui-disabled-bg panel3 :ui-disabled-border line
     :ui-accent accent :ui-accent-fg "#FFFFFF" :ui-accent-soft-bg accent-soft
     :ui-button-primary-fg "#FFFFFF" :ui-button-primary-bg accent
     :ui-button-secondary-fg accent :ui-button-secondary-bg accent-soft
     :ui-button-ghost-fg muted
     :ui-success-fg ok :ui-success-bg ok-bg :ui-success-border ok-border
     :ui-danger-fg danger :ui-danger-bg danger-bg :ui-danger-border danger-border
     :ui-warning-fg warn :ui-warning-bg warn-bg :ui-warning-border warn-border
     :ui-info-fg info :ui-info-bg info-bg :ui-info-border info-border
     :ui-panel-fg ink :ui-panel-bg surface :ui-panel-border line
     :ui-search-bg panel2 :ui-search-fg ink
     :ui-divider-bg line :ui-progress-track panel3
     :ui-range-track panel3 :ui-range-fill accent
     :ui-table-border line :ui-table-selected-fg accent
     :ui-table-selected-bg accent-soft
     :ui-shell-bg panel2 :ui-shell-fg ink :ui-shell-muted-fg muted
     :ui-shell-item-fg muted :ui-shell-item-minimized-fg dim
     :ui-window-bg bg :ui-window-fg ink :ui-window-border line
     :ui-window-title-bg panel2 :ui-window-title-fg muted
     :ui-window-title-active-fg ink
     :ui-picker-item-bg surface :ui-picker-item-fg ink
     :ui-picker-item-muted-fg muted
     :ui-pagination-muted-fg muted
     :ui-data-grid-error-fg danger
     :ui-checkbox-enabled-fg ink :ui-checkbox-disabled-fg dim)))

(provide 'etaf-bili-theme)
;;; etaf-bili-theme.el ends here
