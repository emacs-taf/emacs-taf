;;; etaf-balatro-theme.el --- Host-following and curated theme tokens for ETAF Balatro -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Theme token derivation for `etaf-balatro'.  Supports three appearance modes:
;; `auto' (default, derived live from the active Emacs theme on the frame),
;; `dark' (curated obsidian slate) and `light' (curated bright paper/stone).
;; Subscribes to `enable-theme-functions' and `disable-theme-functions' through
;; a reactive epoch ref so open buffers repaint surfaces, borders, semantic
;; badges and the buffer default face immediately on `M-x load-theme'.

;;; Code:
(require 'cl-lib)
(require 'color)
(require 'etaf)
(require 'etaf-ui)

(defvar etaf-balatro--theme-epoch (etaf-ref 0 :name 'balatro-theme-epoch)
  "Reactive counter bumped whenever an Emacs theme is enabled or disabled.")

(defvar etaf-balatro--token-cache nil
  "Cached (KEY . TOKENS) for `etaf-balatro--tokens'.")

(defun etaf-balatro--on-host-theme-change (&rest _)
  "Invalidate cached tokens and notify open ETAF Balatro views."
  (setq etaf-balatro--token-cache nil)
  (when (etaf-ref-p etaf-balatro--theme-epoch)
    (ignore-errors
      (setf (etaf-value etaf-balatro--theme-epoch)
            (1+ (etaf-untracked (etaf-value etaf-balatro--theme-epoch)))))))

(add-hook 'enable-theme-functions #'etaf-balatro--on-host-theme-change)
(add-hook 'disable-theme-functions #'etaf-balatro--on-host-theme-change)

(defun etaf-balatro--theme-frame ()
  "Return the frame showing the current buffer, or the selected frame."
  (or (let ((win (get-buffer-window (current-buffer) t)))
        (and win (window-frame win)))
      (selected-frame)))

(defun etaf-balatro--valid-color (value)
  "Return VALUE when it is a parseable colour string, else nil."
  (and (stringp value)
       (not (member value '("unspecified" "unspecified-bg" "unspecified-fg")))
       (color-name-to-rgb value)
       value))

(defun etaf-balatro--face-color (face attr &optional fallback)
  "Return FACE's ATTR colour on the active frame, or FALLBACK."
  (let* ((frame (etaf-balatro--theme-frame))
         (val (and (facep face) (face-attribute face attr frame t))))
    (or (etaf-balatro--valid-color val) fallback)))

(defun etaf-balatro--luminance (hex)
  "Return perceived luminance (0..1) of colour HEX."
  (pcase-let ((`(,r ,g ,b) (or (color-name-to-rgb hex) '(0.5 0.5 0.5))))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun etaf-balatro--mix (from to amount)
  "Blend colour FROM toward TO by AMOUNT (0..1), returning #RRGGBB."
  (let ((a (or (color-name-to-rgb from) '(0.0 0.0 0.0)))
        (b (or (color-name-to-rgb to) '(1.0 1.0 1.0))))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (x y) (+ (* x (- 1.0 amount)) (* y amount))) a b)
                   (list 2)))))

(defun etaf-balatro--legible-on-both (color bg1 bg2 min-ratio)
  "Adjust COLOR so it meets MIN-RATIO contrast against both BG1 and BG2."
  (let* ((c1 (etaf-ui-color-legible color bg1 min-ratio))
         (c2 (if (>= (etaf-ui-color-contrast c1 bg2) min-ratio)
                 c1
               (etaf-ui-color-legible c1 bg2 min-ratio))))
    c2))

(defun etaf-balatro--semantic-trio (surface accent-seed dark-p)
  "Derive (FG SOFT-BG BORDER) from SURFACE and ACCENT-SEED for DARK-P."
  (let* ((soft-ratio (if dark-p 0.19 0.11))
         (border-ratio (if dark-p 0.44 0.40))
         (soft-bg (etaf-balatro--mix surface accent-seed soft-ratio))
         (border (etaf-balatro--mix surface accent-seed border-ratio))
         (fg (etaf-balatro--legible-on-both accent-seed soft-bg surface 4.5)))
    (list fg soft-bg border)))

(defun etaf-balatro--host-bg-fg ()
  "Return (BG FG DARK-P) detected from the active Emacs frame theme."
  (let* ((frame (etaf-balatro--theme-frame))
         (mode-param (frame-parameter frame 'background-mode))
         (raw-bg (etaf-balatro--face-color 'default :background nil))
         (dark-p (if raw-bg
                     (< (etaf-balatro--luminance raw-bg) 0.45)
                   (not (eq mode-param 'light))))
         (bg (or raw-bg (if dark-p "#0F141D" "#F3F5F9")))
         (fg (etaf-balatro--face-color 'default :foreground
                                    (if dark-p "#F1F5F9" "#0F172A"))))
    (list bg fg dark-p)))

(defun etaf-balatro--appearance-label (appearance)
  "Return concise button label for APPEARANCE (`auto', `dark' or `light')."
  (pcase appearance
    ('dark "深色 · t")
    ('light "浅色 · t")
    (_ "跟随主题 · t")))

(defun etaf-balatro--build-tokens (bg fg dark-p &optional curated)
  "Build full `etaf-balatro' + `etaf-ui' token plist from BG, FG and DARK-P.
When CURATED is non-nil, use curated v2 mockup surface elevations."
  (let* ((lum (etaf-balatro--luminance bg))
         ;; 3-level tonal surface hierarchy (Level 0 canvas -> Level 1 panels -> Level 2 slots)
         (canvas
          (cond
           (curated bg)
           ((and (not dark-p) (> lum 0.94))
            ;; On pure-white themes like modus-operandi, softly tint canvas so white cards float cleanly
            (etaf-balatro--mix bg fg 0.04))
           (t bg)))
         (surface
          (cond
           ((and curated dark-p) "#151C28")
           ((and curated (not dark-p)) "#FFFFFF")
           (dark-p (etaf-balatro--mix canvas fg 0.048))
           ((> lum 0.94) bg)
           (t (etaf-balatro--mix canvas "#FFFFFF" 0.55))))
         (header
          (cond
           ((and curated dark-p) "#151C28")
           ((and curated (not dark-p)) "#FFFFFF")
           (dark-p (etaf-balatro--mix canvas fg 0.04))
           (t surface)))
         (card
          (cond
           ((and curated dark-p) "#1B2433")
           ((and curated (not dark-p)) "#F8FAFC")
           (dark-p (etaf-balatro--mix canvas fg 0.09))
           (t (etaf-balatro--mix surface fg 0.032))))
         (card-alt
          (cond
           ((and curated dark-p) "#1E283A")
           ((and curated (not dark-p)) "#F1F5F9")
           (dark-p (etaf-balatro--mix canvas fg 0.12))
           (t (etaf-balatro--mix surface fg 0.06))))
         (empty-bg
          (cond
           ((and curated dark-p) "#121823")
           ((and curated (not dark-p)) "#F4F6FA")
           (dark-p (etaf-balatro--mix canvas fg 0.024))
           (t (etaf-balatro--mix surface fg 0.025))))
         (border-soft
          (cond
           ((and curated dark-p) "#1E2838")
           ((and curated (not dark-p)) "#E5EAF2")
           (t (etaf-balatro--mix surface fg (if dark-p 0.10 0.09)))))
         (border
          (cond
           ((and curated dark-p) "#243044")
           ((and curated (not dark-p)) "#DDE3EC")
           (t (etaf-balatro--mix surface fg (if dark-p 0.15 0.14)))))
         (border-strong
          (cond
           ((and curated dark-p) "#374966")
           ((and curated (not dark-p)) "#CBD5E1")
           (t (etaf-balatro--mix surface fg (if dark-p 0.25 0.24)))))
         (hover
          (cond
           ((and curated dark-p) "#222E42")
           ((and curated (not dark-p)) "#E9EFF7")
           (t (etaf-balatro--mix surface fg (if dark-p 0.11 0.07)))))
         (track
          (cond
           ((and curated dark-p) "#1E2838")
           ((and curated (not dark-p)) "#E2E8F0")
           (t (etaf-balatro--mix surface fg (if dark-p 0.14 0.12)))))
         (ink (etaf-ui-color-legible fg surface 7.0))
         (muted (etaf-balatro--legible-on-both
                 (etaf-balatro--mix surface ink (if dark-p 0.62 0.60))
                 surface card 4.2))
         (dim (etaf-balatro--legible-on-both
               (etaf-balatro--mix surface ink (if dark-p 0.45 0.44))
               surface card 3.0))
         ;; Calibrated semantic trios (FG SOFT-BG BORDER)
         (gold-trio (etaf-balatro--semantic-trio surface (if dark-p "#F5B841" "#B45309") dark-p))
         (chips-trio (etaf-balatro--semantic-trio surface (if dark-p "#60A5FA" "#1D4ED8") dark-p))
         (mult-trio (etaf-balatro--semantic-trio surface (if dark-p "#FB7185" "#BE123C") dark-p))
         (purple-trio (etaf-balatro--semantic-trio surface (if dark-p "#C084FC" "#7E22CE") dark-p))
         (green-trio (etaf-balatro--semantic-trio surface (if dark-p "#4ADE80" "#15803D") dark-p))
         (cyan-trio (etaf-balatro--semantic-trio surface (if dark-p "#38BDF8" "#0E7490") dark-p))
         (boss-trio (etaf-balatro--semantic-trio surface (if dark-p "#F87171" "#B91C1C") dark-p))
         (coach-bg (etaf-balatro--mix surface (nth 0 chips-trio) (if dark-p 0.10 0.06)))
         (coach-border (etaf-balatro--mix surface (nth 0 chips-trio) (if dark-p 0.28 0.22)))
         (accent (if dark-p "#2563EB" "#2563EB"))
         (accent-fg "#FFFFFF")
         (ui-palette
          (list :bg canvas
                :fg ink
                :panel surface
                :track track
                :border border
                :muted muted
                :dim dim
                :accent accent
                :accent-fg accent-fg
                :accent-soft (nth 1 chips-trio)
                :success (nth 0 green-trio)
                :success-bg (nth 1 green-trio)
                :success-border (nth 2 green-trio)
                :warning (nth 0 gold-trio)
                :warning-bg (nth 1 gold-trio)
                :warning-border (nth 2 gold-trio)
                :danger (nth 0 mult-trio)
                :danger-bg (nth 1 mult-trio)
                :danger-border (nth 2 mult-trio)
                :info (nth 0 chips-trio)
                :info-bg (nth 1 chips-trio)
                :info-border (nth 2 chips-trio))))
    (append
     (list
      :ui-mode (if dark-p 'dark 'light)
      :ui-bg canvas
      :ui-fg ink
      :ui-panel-bg surface
      :ui-panel-fg ink
      :ui-panel-border border
      :ui-hover-bg hover
      :ui-button-padding '((lh 0) (ch 2))
      ;; Restrained neutral secondary buttons so Primary Blue & Danger Red CTAs pop
      :ui-button-primary-bg "#2563EB"
      :ui-button-primary-fg "#FFFFFF"
      :ui-button-primary-hover-bg "#1D4ED8"
      :ui-button-secondary-bg card
      :ui-button-secondary-fg (if dark-p "#CBD5E1" "#334155")
      :ui-button-secondary-hover-bg hover
      :ui-button-ghost-fg muted
      :ui-button-ghost-hover-bg hover
      :ui-disabled-bg empty-bg
      :ui-disabled-fg dim
      :balatro-dark dark-p
      :balatro-bg canvas
      :balatro-header header
      :balatro-surface surface
      :balatro-card card
      :balatro-card-alt card-alt
      :balatro-empty-bg empty-bg
      :balatro-border border
      :balatro-border-soft border-soft
      :balatro-border-strong border-strong
      :balatro-fg ink
      :balatro-muted muted
      :balatro-dim dim
      :balatro-hover hover
      :balatro-track track
      :balatro-coach-bg coach-bg
      :balatro-coach-border coach-border
      :balatro-gold (nth 0 gold-trio)
      :balatro-gold-bg (nth 1 gold-trio)
      :balatro-gold-border (nth 2 gold-trio)
      :balatro-chips-fg (nth 0 chips-trio)
      :balatro-chips-bg (nth 1 chips-trio)
      :balatro-chips-border (nth 2 chips-trio)
      :balatro-mult-fg (nth 0 mult-trio)
      :balatro-mult-bg (nth 1 mult-trio)
      :balatro-mult-border (nth 2 mult-trio)
      :balatro-purple (nth 0 purple-trio)
      :balatro-purple-bg (nth 1 purple-trio)
      :balatro-purple-border (nth 2 purple-trio)
      :balatro-green (nth 0 green-trio)
      :balatro-green-bg (nth 1 green-trio)
      :balatro-green-border (nth 2 green-trio)
      :balatro-cyan (nth 0 cyan-trio)
      :balatro-cyan-bg (nth 1 cyan-trio)
      :balatro-cyan-border (nth 2 cyan-trio)
      :balatro-boss-fg (nth 0 boss-trio)
      :balatro-boss-bg (nth 1 boss-trio)
      :balatro-boss-border (nth 2 boss-trio)
      :balatro-glass (etaf-balatro--legible-on-both
                   (if dark-p "#F472B6" "#BE185D") surface card 4.5)
      :balatro-steel (etaf-balatro--legible-on-both
                   (if dark-p "#CBD5E1" "#334155") surface card 4.5)
      :balatro-foil (etaf-balatro--legible-on-both
                  (if dark-p "#38BDF8" "#0369A1") surface card 4.5)
      :balatro-bonus (nth 0 chips-trio)
      :balatro-heart (etaf-balatro--legible-on-both
                   (if dark-p "#F87171" "#DC2626") surface card 4.2)
      :balatro-diamond (etaf-balatro--legible-on-both
                     (if dark-p "#FB923C" "#C2410C") surface card 4.2)
      :balatro-spade (etaf-balatro--legible-on-both
                   (if dark-p "#E2E8F0" "#1E293B") surface card 4.5)
      :balatro-club (etaf-balatro--legible-on-both
                  (if dark-p "#93C5FD" "#334155") surface card 4.2)
      ;; Playing cards: tactile ivory face + crisp outline in both dark & light themes
      :ui-playing-card-bg (if dark-p "#FFFDF6" "#FAF8F2")
      :ui-playing-card-hover-bg (if dark-p "#F6EED8" "#F1EDE0")
      :ui-playing-card-border (if dark-p "#475569" "#B6C2D2")
      :ui-playing-card-selected-bg "#FEF3C7"
      :ui-playing-card-selected-border (if dark-p "#F59E0B" "#D97706")
      :ui-playing-card-red "#DC2626"
      :ui-playing-card-black "#0F172A")
     (etaf-ui-theme-tokens ui-palette))))

(defun etaf-balatro--tokens (appearance)
  "Return the ETAF theme token plist for APPEARANCE (`auto', `dark' or `light')."
  (let* ((mode (if (memq appearance '(auto dark light)) appearance 'auto))
         (host (when (eq mode 'auto) (etaf-balatro--host-bg-fg)))
         (key (list mode host custom-enabled-themes
                    (etaf-untracked (etaf-value etaf-balatro--theme-epoch)))))
    (if (equal key (car-safe etaf-balatro--token-cache))
        (cdr etaf-balatro--token-cache)
      (let ((tok
             (pcase mode
               ('dark (etaf-balatro--build-tokens "#0F141D" "#F1F5F9" t t))
               ('light (etaf-balatro--build-tokens "#F3F5F9" "#0F172A" nil t))
               (_ (etaf-balatro--build-tokens (nth 0 host) (nth 1 host) (nth 2 host) nil)))))
        (setq etaf-balatro--token-cache (cons key tok))
        tok))))

(provide 'etaf-balatro-theme)
;;; etaf-balatro-theme.el ends here
