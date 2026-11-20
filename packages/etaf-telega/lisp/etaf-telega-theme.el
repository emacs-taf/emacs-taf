;;; etaf-telega-theme.el --- Palettes of etaf-telega -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Two maintained palettes behind one accessor.  `etaf-telega-color' reads the
;; palette selected by the client's live mode cell, so a theme switch can never
;; leak a half-updated set of colors and every view follows it automatically.
;; `T' and a panel's title-bar switch write that one cell.

;;; Code:

(require 'color)
(require 'cl-lib)

(defcustom etaf-telega-theme 'auto
  "Appearance a new client starts with.
`auto' follows the appearance the host provides, which is the frame's
background mode when the client stands alone; `dark' and `light' pin one of
the maintained palettes, and `native' derives every color from the current
Emacs theme's faces without painting any background of its own.
The running state is `etaf-telega--theme-mode'; this option only seeds it, so
`etaf-telega-toggle-theme' and a panel's title-bar switch both write the cell
the open client paints from."
  :type '(choice (const :tag "Follow the frame" auto)
                 (const :tag "Dark" dark)
                 (const :tag "Light" light)
                 (const :tag "Current Emacs theme" native))
  :group 'etaf-telega)

(defvar etaf-telega--theme-mode (etaf-ref etaf-telega-theme)
  "Live appearance of the client.
`T' writes this cell and so does the title-bar switch of a host that frames
the client, so the client and its panel show one state instead of two.
`native' is the client's own fourth palette and has no segment in the
standard three-mode switch.")

(defconst etaf-telega--surface-modes
  '((light . "亮") (auto . "随") (dark . "暗"))
  "Appearance modes the client offers its host, in display order.
They are the standard three a panel's title bar shows, so the client's switch
reads like every other panel's; `native' stays on `T'.")

(defconst etaf-telega-themes
  '((dark
     (:bg . "#191a1c")
     (:surface . "#191a1c")
     (:surface-2 . "#202225")
     (:canvas . "#17181a")
     (:ink . "#e9eef4")
     (:muted . "#8796a8")
     (:accent . "#5eacef")
     (:accent-soft . "#2b5278")
     (:border . "#303338")
     (:hairline . "#26282b")
     (:chat-bg . "#17181a")
     (:bubble-in . "#25272b")
     (:bubble-out . "#2b5278")
     (:selected . "#2b5278")
     (:danger . "#ef5b5b")
     (:ok . "#4fbf67")
     (:senders "#f48fb1" "#64b5f6" "#ce93d8" "#81c784"
               "#ffb74d" "#ef9a9a" "#4dd0e1" "#fff176"))
    (light
     (:bg . "#ffffff")
     (:surface . "#ffffff")
     (:surface-2 . "#f3f5f8")
     (:canvas . "#e9eef4")
     (:ink . "#111827")
     (:muted . "#6b7280")
     (:accent . "#2481cc")
     (:accent-soft . "#dbeafe")
     (:border . "#e3e8ee")
     (:hairline . "#eef2f6")
     (:chat-bg . "#e9eef4")
     (:bubble-in . "#ffffff")
     (:bubble-out . "#d9ecfb")
     (:selected . "#d9ecfb")
     (:danger . "#dc2626")
     (:ok . "#16a34a")
     (:senders "#d6336c" "#1d4ed8" "#7c3aed" "#15803d"
               "#b45309" "#b91c1c" "#0e7490" "#a16207")))
  "Maintained palettes: semantic colors plus sender accents per theme.
`:canvas' is the chat background color drawn by gaps and idle rules.")

(defvar etaf-telega--canvas-version (etaf-ref 0)
  "Palette generation, bumped when the client switches appearance.
Every palette read goes through `etaf-value' on this cell, so a mounted View
repaints all of its rows and panes from the new palette instead of keeping the
colors it rendered with; the application canvas reads it for the same reason.")

(defun etaf-telega--theme-name ()
  "Return the effective palette name: `dark', `light' or `native'.
The choice is read from the live mode cell, so a host's switch and a repaint
of a mounted View never disagree about the palette."
  (let ((choice (etaf-value etaf-telega--theme-mode)))
    (cond ((memq choice '(dark light native)) choice)
          ;; `auto' follows the appearance the host provides, which is the
          ;; parent frame's polarity inside a panel.
          ((eq (etaf-appearance) 'dark) 'dark)
          (t 'light))))

(defun etaf-telega--blend (from to ratio)
  "Return the color RATIO of the way from color FROM to color TO."
  (let ((a (color-name-to-rgb from))
        (b (color-name-to-rgb to)))
    (if (and a b)
        (apply #'color-rgb-to-hex
               (append (cl-mapcar (lambda (x y) (+ x (* ratio (- y x)))) a b)
                       (list 2)))
      to)))

(defun etaf-telega--native-palette ()
  "Return a palette derived from the current faces.
The background keys are nil, so the frame's own background shows through;
tints are blends of the default background with its foreground or links."
  (let* ((dark (eq (frame-parameter nil 'background-mode) 'dark))
         (bg (or (face-background 'default nil t) (if dark "#000000" "#ffffff")))
         (fg (or (face-foreground 'default nil t) (if dark "#ffffff" "#000000")))
         (accent (or (face-foreground 'link nil t) (if dark "#5eacef" "#2481cc"))))
    `((:bg) (:surface) (:chat-bg)
      (:canvas . ,bg)
      (:surface-2 . ,(etaf-telega--blend bg fg 0.06))
      (:ink . ,fg)
      (:muted . ,(or (face-foreground 'shadow nil t) (etaf-telega--blend bg fg 0.55)))
      (:accent . ,accent)
      (:accent-soft . ,(etaf-telega--blend bg accent 0.22))
      (:border . ,(etaf-telega--blend bg fg 0.16))
      (:hairline . ,(etaf-telega--blend bg fg 0.07))
      (:bubble-in . ,(etaf-telega--blend bg fg 0.08))
      (:bubble-out . ,(etaf-telega--blend bg accent 0.22))
      (:selected . ,(etaf-telega--blend bg accent 0.2))
      (:danger . ,(or (face-foreground 'error nil t) "#ef5b5b"))
      (:ok . ,(or (face-foreground 'success nil t) "#4fbf67"))
      (:senders . ,(cdr (assq :senders (alist-get (if dark 'dark 'light)
                                                  etaf-telega-themes)))))))

(defun etaf-telega--palette ()
  "Return the active palette.
The read tracks `etaf-telega--canvas-version', so a render or effect that
paints a color re-runs after the client switches appearance."
  (etaf-value etaf-telega--canvas-version)
  (let ((name (etaf-telega--theme-name)))
    (if (eq name 'native)
        (etaf-telega--native-palette)
      (or (alist-get name etaf-telega-themes)
          (alist-get 'dark etaf-telega-themes)))))

(defun etaf-telega-color (key)
  "Return the active palette's color for KEY.
The native palette returns nil for background keys, leaving them unpainted."
  (let ((entry (assq key (etaf-telega--palette))))
    (if entry
        (cdr entry)
      (if (eq (etaf-telega--theme-name) 'dark) "#e9eef4" "#111827"))))

(defun etaf-telega-sender-color (name)
  "Return the active palette's stable sender color for NAME."
  (let* ((colors (or (alist-get :senders (etaf-telega--palette))
                     (alist-get :senders (alist-get 'dark etaf-telega-themes))))
         (hash 0))
    (dolist (char (string-to-list (or name "")))
      (setq hash (mod (+ (* hash 31) char) 1000003)))
    (nth (mod hash (length colors)) colors)))

(defun etaf-telega-theme-defaults ()
  "Return the ETAF UI token plist for the active palette.
The application passes the result to `etaf-theme-provide' before mounting,
otherwise etaf-ui Components (buttons, badges, inputs, ranges) keep their
own light defaults and the app looks half-themed.  `etaf-ui-theme-tokens'
derives the catalog tokens; the entries before it keep this client's
denser, muted presentation of secondary surfaces and warnings."
  (let* ((bg (or (etaf-telega-color :bg) (etaf-telega-color :canvas)))
         (surface (or (etaf-telega-color :surface) bg))
         (panel (or (etaf-telega-color :surface-2) surface))
         (ink (etaf-telega-color :ink))
         (muted (etaf-telega-color :muted))
         (border (etaf-telega-color :border))
         (accent (etaf-telega-color :accent))
         (accent-soft (etaf-telega-color :accent-soft)))
    (append
     (list :ui-panel-bg panel :ui-panel-fg ink :ui-panel-border border
           :ui-divider-bg border
           :ui-picker-item-bg panel :ui-picker-item-fg ink
           :ui-picker-item-muted-fg muted
           :ui-search-bg panel :ui-search-fg ink
           :ui-disabled-bg surface :ui-disabled-border border
           :ui-button-secondary-bg accent-soft
           :ui-button-ghost-bg surface
           :ui-range-track border
           :ui-success-bg panel
           :ui-danger-fg muted :ui-danger-bg panel
           :ui-warning-fg muted :ui-warning-bg panel
           :ui-info-fg "#FFFFFF" :ui-info-bg accent)
     (etaf-ui-theme-tokens
      (list :bg bg :fg ink :panel panel :track border :border border
            :muted muted :dim muted :accent accent :accent-fg "#FFFFFF"
            :accent-soft accent-soft
            :success (etaf-telega-color :ok) :success-bg panel
            :success-border border
            :warning muted :warning-bg panel :warning-border border
            :danger (etaf-telega-color :danger) :danger-bg panel
            :danger-border border
            :info accent :info-bg accent :info-border accent)))))

(provide 'etaf-telega-theme)
;;; etaf-telega-theme.el ends here
