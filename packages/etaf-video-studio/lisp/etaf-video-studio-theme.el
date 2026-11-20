;;; etaf-video-studio-theme.el --- Semantic palette of etaf-video-studio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Two full palettes (dark and light) behind one accessor, so a palette
;; change can never leak a half-updated set of colors, plus the projection
;; into the ETAF UI token names used by the standard catalog.  Every view
;; reads colors through `etaf-video-studio-color'; `etaf-theme-provide'
;; receives the token plist from `etaf-video-studio-theme-defaults', which
;; derives the catalog tokens with `etaf-ui-theme-tokens'.  The
;; palette is four depth steps (page, card, bar, control) plus state
;; surfaces, so panes stay separated in both appearances.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defconst etaf-video-studio-palettes
  '((dark
     (:bg . "#0b0e14")
     (:panel . "#141922")
     (:panel2 . "#1a212d")
     (:panel3 . "#232c3a")
     (:hover . "#2a3446")
     (:stage . "#000000")
     (:ink . "#e8edf4")
     (:muted . "#9ba7b8")
     (:dim . "#6b7789")
     (:accent . "#4c9df3")
     (:accent-soft . "#16324f")
     (:accent-fg . "#ffffff")
     (:border . "#2c3644")
     (:frame . "#39455a")
     (:line . "#232c39")
     (:ok . "#4cc38a")
     (:ok-bg . "#123528")
     (:danger . "#f2777a")
     (:danger-bg . "#3a1d20")
     (:warning . "#e0af68")
     (:warning-bg . "#3a2f1a")
     (:info . "#7aa2f7")
     (:info-bg . "#1b2a46"))
    (light
     (:bg . "#eef2f7")
     (:panel . "#ffffff")
     (:panel2 . "#eaf0f7")
     (:panel3 . "#e2e8f0")
     (:hover . "#d7e1ec")
     (:stage . "#10141a")
     (:ink . "#263750")
     (:muted . "#5b6779")
     (:dim . "#8a95a6")
     (:accent . "#3b68b3")
     (:accent-soft . "#edf3fc")
     (:accent-fg . "#ffffff")
     (:border . "#ccd5e0")
     (:frame . "#c3cedd")
     (:line . "#dde4ec")
     (:ok . "#1f8a53")
     (:ok-bg . "#dcf3e6")
     (:danger . "#c04444")
     (:danger-bg . "#fbe3e3")
     (:warning . "#9a6b0f")
     (:warning-bg . "#faf0d7")
     (:info . "#2563eb")
     (:info-bg . "#e0ecff")))
  "Dark and light semantic palettes of the application.")

(defvar etaf-video-studio-theme-mode 'dark
  "Appearance of the application: `dark' (default) or `light'.")

(defun etaf-video-studio-color (key &optional mode)
  "Return KEY's raw color for explicit MODE, or a deferred Theme token.
Views keep the deferred value so retained Hosts follow palette changes
without relying on an unrelated snapshot projection being invalidated."
  (let* ((palette (or (alist-get (or mode etaf-video-studio-theme-mode)
                                etaf-video-studio-palettes)
                      (alist-get 'dark etaf-video-studio-palettes)))
         (color (or (alist-get key palette) (alist-get :ink palette))))
    (if mode color
      (etaf-theme-token (intern (concat ":video-studio-" (substring (symbol-name key) 1)))
                        color))))

(defun etaf-video-studio-theme-defaults (&optional mode)
  "Return the Theme token plist for MODE (default the current mode).
The application passes the result to `etaf-theme-provide' before mounting,
so etaf-ui Components (buttons, badges, inputs, ranges, help) share the
studio palette.  The palette's raw colors come first as `:video-studio-*'
tokens; the catalog tokens are derived by `etaf-ui-theme-tokens' after the
few values where the studio departs from the derived role."
  (let* ((mode (or mode etaf-video-studio-theme-mode))
         (c (lambda (key) (etaf-video-studio-color key mode)))
         (bg (funcall c :bg))
         (panel (funcall c :panel))
         (panel2 (funcall c :panel2))
         (panel3 (funcall c :panel3))
         (ink (funcall c :ink))
         (accent (funcall c :accent))
         (accent-fg (funcall c :accent-fg))
         (accent-soft (funcall c :accent-soft))
         (line (funcall c :line)))
    (append
     (cl-loop for (key . color) in (alist-get mode etaf-video-studio-palettes)
              append (list (intern (concat ":video-studio-" (substring (symbol-name key) 1)))
                           color))
     (list
      ;; Hovers are lighter or tonal steps of their resting fill.
      :ui-button-primary-hover-bg (etaf-video-studio--mix accent accent-fg 0.12)
      :ui-button-secondary-hover-bg
      (etaf-video-studio--mix accent-soft (funcall c :hover) 0.35)
      :ui-button-ghost-hover-bg panel3
      ;; Outlined fields are flat filled surfaces: no outline, no radius,
      ;; one standard row.
      :ui-input-padding '((lh 0) (ch 2))
      :ui-input-radius '(px 0)
      :ui-input-bg panel2
      :ui-input-border panel2
      :ui-search-bg panel3
      :ui-search-fg ink
      ;; Recessed controls sit one depth step above their panel, separators
      ;; use the quiet line and framed panels the stronger frame.
      :ui-picker-item-bg panel2
      :ui-disabled-bg panel2
      :ui-divider-bg line
      :ui-table-border line
      :ui-table-selected-fg ink
      :ui-panel-border (funcall c :frame)
      :ui-shell-bg bg
      :ui-shell-item-fg ink
      :ui-window-bg panel
      :ui-window-title-bg panel2)
     (etaf-ui-theme-tokens
      (list :bg bg :fg ink :panel panel :track panel3
            :border (funcall c :border) :muted (funcall c :muted)
            :dim (funcall c :dim) :accent accent :accent-fg accent-fg
            :accent-soft accent-soft
            :success (funcall c :ok) :success-bg (funcall c :ok-bg)
            :success-border (funcall c :ok)
            :warning (funcall c :warning) :warning-bg (funcall c :warning-bg)
            :warning-border (funcall c :warning)
            :danger (funcall c :danger) :danger-bg (funcall c :danger-bg)
            :danger-border (funcall c :danger)
            :info (funcall c :info) :info-bg (funcall c :info-bg)
            :info-border (funcall c :info))))))

(defun etaf-video-studio--mix (from to amount)
  "Return FROM mixed AMOUNT of the way toward TO.
Both colors must be `#RRGGBB' strings; any other spelling returns FROM so a
named color keeps working."
  (let ((a (etaf-video-studio--channels from))
        (b (etaf-video-studio--channels to)))
    (if (and a b)
        (apply #'format "#%02X%02X%02X"
               (cl-mapcar (lambda (x y)
                            (max 0 (min 255 (round (+ x (* (- y x) amount))))))
                          a b))
      from)))

(defun etaf-video-studio--channels (color)
  "Return COLOR's (RED GREEN BLUE) channels, or nil when it is not hex."
  (when (and (stringp color)
             (string-match "\\`#\\([0-9A-Fa-f]\\{2\\}\\)\\([0-9A-Fa-f]\\{2\\}\\)\\([0-9A-Fa-f]\\{2\\}\\)\\'" color))
    (mapcar (lambda (index) (string-to-number (match-string index color) 16))
            '(1 2 3))))

(provide 'etaf-video-studio-theme)
;;; etaf-video-studio-theme.el ends here
