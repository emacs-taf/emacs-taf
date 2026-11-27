;;; etaf-agenda-theme.el --- Theme-derived palette and tokens of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Every colour etaf-agenda paints is derived from the active Emacs theme on
;; the application's frame and cached per theme/frame signature.  A theme
;; switch invalidates the cache via `enable-theme-functions` and bumps ETAF's
;; theme generation, so both application surfaces and `etaf-ui` catalog
;; components repaint in place without hardcoding a second palette.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-agenda-error "ETAF Agenda error")

(defvar etaf-agenda--palette-cache nil
  "Cached (KEY . PALETTE) for `etaf-agenda-palette'.")

(defun etaf-agenda--theme-frame ()
  "Return the frame showing the current buffer, or the selected frame."
  (or (let ((window (get-buffer-window (current-buffer) t)))
        (and window (window-frame window)))
      (selected-frame)))

(defun etaf-agenda--valid-color (value)
  "Return VALUE when it is a valid colour string, else nil."
  (and (stringp value)
       (not (member value '("unspecified" "unspecified-bg" "unspecified-fg")))
       (color-name-to-rgb value)
       value))

(defun etaf-agenda--face-color (face attribute &optional fallback)
  "Return FACE's ATTRIBUTE colour on the application frame, or FALLBACK."
  (let* ((frame (etaf-agenda--theme-frame))
         (value (and (facep face) (face-attribute face attribute frame t))))
    (or (etaf-agenda--valid-color value) fallback)))

(defun etaf-agenda--luminance (hex)
  "Return rough perceived luminance (0..1) of colour HEX."
  (pcase-let ((`(,r ,g ,b) (or (color-name-to-rgb hex) '(0.5 0.5 0.5))))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun etaf-agenda--dark-bg-p (bg)
  "Return non-nil when background colour BG is dark."
  (< (etaf-agenda--luminance bg) 0.45))

(defun etaf-agenda--mix (from to amount)
  "Mix colour FROM toward TO by AMOUNT (0..1), returning a hex string."
  (let ((a (or (color-name-to-rgb from) '(0.0 0.0 0.0)))
        (b (or (color-name-to-rgb to) '(1.0 1.0 1.0))))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (x y) (+ (* x (- 1.0 amount)) (* y amount))) a b)
                   (list 2)))))

(defun etaf-agenda--warm-yellow-p (hex)
  "Return non-nil when HEX has a warm yellow or ochre hue."
  (pcase-let ((`(,r ,g ,b) (or (color-name-to-rgb hex) '(0.0 0.0 0.0))))
    (and (> r 0.40) (> g 0.30)
         (>= r (* 0.85 g))
         (> (- (min r g) b) 0.16))))

(defun etaf-agenda--rgb-distance (c1 c2)
  "Return Euclidean RGB distance between colours C1 and C2."
  (pcase-let ((`(,r1 ,g1 ,b1) (or (color-name-to-rgb c1) '(0.0 0.0 0.0)))
              (`(,r2 ,g2 ,b2) (or (color-name-to-rgb c2) '(0.0 0.0 0.0))))
    (sqrt (+ (expt (- r1 r2) 2)
             (expt (- g1 g2) 2)
             (expt (- b1 b2) 2)))))

(defun etaf-agenda--legible-on (color surfaces ratio)
  "Return COLOR tightened to meet RATIO against every surface in SURFACES."
  (let ((c color))
    (dolist (s surfaces c)
      (when (etaf-agenda--valid-color s)
        (setq c (etaf-ui-color-legible c s ratio))))))

(defun etaf-agenda--calm-accent (bg accent dark-p &optional min-ratio)
  "Return ACCENT adjusted so it stays calm and legible on BG.
Avoids blinding neon accents on dark surfaces and enforces WCAG legibility."
  (let* ((raw (or (etaf-agenda--valid-color accent)
                  (if dark-p "#4dd0e1" "#005e8b")))
         ;; Calibrate overly bright neon cyan/yellow on dark backgrounds.
         (calmed (if (and dark-p (> (etaf-agenda--luminance raw) 0.72))
                     (etaf-agenda--mix bg raw 0.72)
                   raw)))
    (etaf-ui-color-legible calmed bg (or min-ratio (if dark-p 4.5 4.8)))))

(defun etaf-agenda--palette-key ()
  "Return the cache key for the current theme and frame."
  (let ((frame (etaf-agenda--theme-frame)))
    (list (etaf-theme-current-mode)
          (frame-parameter frame 'background-color)
          (frame-parameter frame 'foreground-color)
          custom-enabled-themes
          (and (facep 'shadow) (face-attribute 'shadow :foreground frame t))
          (and (facep 'link) (face-attribute 'link :foreground frame t))
          (and (facep 'font-lock-function-name-face)
               (face-attribute 'font-lock-function-name-face :foreground frame t))
          (and (facep 'font-lock-type-face)
               (face-attribute 'font-lock-type-face :foreground frame t))
          (and (facep 'font-lock-builtin-face)
               (face-attribute 'font-lock-builtin-face :foreground frame t))
          (and (facep 'hl-line) (face-attribute 'hl-line :background frame t))
          (and (facep 'error) (face-attribute 'error :foreground frame t))
          (and (facep 'warning) (face-attribute 'warning :foreground frame t))
          (and (facep 'success) (face-attribute 'success :foreground frame t)))))

(defun etaf-agenda--clear-palette-cache (&rest _)
  "Invalidate the cached palette on theme changes."
  (setq etaf-agenda--palette-cache nil))

(add-hook 'enable-theme-functions #'etaf-agenda--clear-palette-cache)
(add-hook 'disable-theme-functions #'etaf-agenda--clear-palette-cache)

(defun etaf-agenda--pick-info-seed (dark-p accent warning)
  "Pick a crisp cool info colour distinct from WARNING on light and dark themes."
  (let* ((type-c (etaf-agenda--face-color 'font-lock-type-face :foreground))
         (built-c (etaf-agenda--face-color 'font-lock-builtin-face :foreground))
         (fallback (if dark-p "#68c4d8" "#0c6a7d"))
         (bad-p (lambda (c)
                  (or (not c)
                      (and (not dark-p) (etaf-agenda--warm-yellow-p c))
                      (< (etaf-agenda--rgb-distance c warning) 0.22)))))
    (cond
     ((not (funcall bad-p type-c)) type-c)
     ((and (not (funcall bad-p built-c))
           (>= (etaf-agenda--rgb-distance built-c accent) 0.12))
      built-c)
     (t fallback))))

(defun etaf-agenda--derive-palette ()
  "Derive a complete tonal and semantic palette from the active Emacs theme."
  (let* ((bg (etaf-agenda--face-color 'default :background "#263238"))
         (dark-p (etaf-agenda--dark-bg-p bg))
         (ink (etaf-agenda--face-color 'default :foreground
                                       (if dark-p "#ffffff" "#1a1a1a")))
         ;; Surfaces and hairlines first so every text role can check against them.
         (surface (etaf-agenda--mix bg ink (if dark-p 0.04 0.036)))
         (surface2 (etaf-agenda--mix bg ink (if dark-p 0.085 0.075)))
         (line (etaf-agenda--mix bg ink (if dark-p 0.14 0.16)))
         (line-soft (etaf-agenda--mix bg ink (if dark-p 0.09 0.10)))
         (select (or (let ((hl (etaf-agenda--face-color 'hl-line :background)))
                       (and hl
                            (> (etaf-ui-color-contrast hl bg) 1.06)
                            (< (etaf-ui-color-contrast hl bg) 2.1)
                            hl))
                     (etaf-agenda--mix bg ink (if dark-p 0.10 0.085))))
         (hover (etaf-agenda--mix bg ink (if dark-p 0.065 0.045)))
         ;; Tonal text ladder: strict WCAG AA floors on light themes; calm
         ;; restful hierarchy on dark themes so idle grid cells recede softly.
         (raw-muted (or (let ((s (etaf-agenda--face-color 'shadow :foreground)))
                          (and s (>= (etaf-ui-color-contrast s bg)
                                     (if dark-p 4.4 5.4))
                               s))
                        (etaf-agenda--mix bg ink (if dark-p 0.60 0.68))))
         (muted (etaf-agenda--legible-on
                 (etaf-ui-color-legible raw-muted bg (if dark-p 4.6 5.6))
                 (list surface) (if dark-p 4.2 5.0)))
         (raw-dim (etaf-agenda--mix bg ink (if dark-p 0.42 0.58)))
         (dim (etaf-agenda--legible-on
               (etaf-ui-color-legible raw-dim bg (if dark-p 3.4 4.5))
               (list surface) (if dark-p 3.1 4.1)))
         ;; Semantic palette: high contrast on both bg and each role's -soft pill.
         (sem-floor (if dark-p 4.5 4.8))
         (pill-floor (if dark-p 4.2 4.5))
         (soft-ratio (if dark-p 0.17 0.11))
         (raw-accent (or (etaf-agenda--face-color 'link :foreground)
                         (etaf-agenda--face-color 'font-lock-function-name-face :foreground)
                         (etaf-agenda--face-color 'font-lock-keyword-face :foreground)
                         (if dark-p "#4dd0e1" "#005e8b")))
         (accent0 (etaf-agenda--calm-accent bg raw-accent dark-p sem-floor))
         (accent-soft (etaf-agenda--mix bg accent0 soft-ratio))
         (accent (etaf-ui-color-legible accent0 accent-soft pill-floor))
         (ok0 (etaf-agenda--calm-accent
               bg
               (or (etaf-agenda--face-color 'success :foreground)
                   (etaf-agenda--face-color 'font-lock-string-face :foreground)
                   (if dark-p "#8bc34a" "#006800"))
               dark-p sem-floor))
         (ok-soft (etaf-agenda--mix bg ok0 soft-ratio))
         (ok (etaf-ui-color-legible ok0 ok-soft pill-floor))
         (warning0 (etaf-agenda--calm-accent
                    bg
                    (or (etaf-agenda--face-color 'warning :foreground)
                        (if dark-p "#ff9800" "#884900"))
                    dark-p sem-floor))
         (warning-soft (etaf-agenda--mix bg warning0 soft-ratio))
         (warning (etaf-ui-color-legible warning0 warning-soft pill-floor))
         (danger0 (etaf-agenda--calm-accent
                   bg
                   (or (etaf-agenda--face-color 'error :foreground)
                       (if dark-p "#f36c60" "#a60000"))
                   dark-p sem-floor))
         (danger-soft (etaf-agenda--mix bg danger0 soft-ratio))
         (danger (etaf-ui-color-legible danger0 danger-soft pill-floor))
         (info0 (etaf-agenda--calm-accent
                 bg
                 (etaf-agenda--pick-info-seed dark-p accent warning)
                 dark-p sem-floor))
         (info-soft (etaf-agenda--mix bg info0 soft-ratio))
         (info (etaf-ui-color-legible info0 info-soft pill-floor)))
    (list :dark dark-p
          :bg bg
          :surface surface
          :surface2 surface2
          :line line
          :line-soft line-soft
          :select select
          :hover hover
          :ink ink
          :muted muted
          :dim dim
          :accent accent
          :accent-soft accent-soft
          :ok ok
          :ok-soft ok-soft
          :warning warning
          :warning-soft warning-soft
          :danger danger
          :danger-soft danger-soft
          :info info
          :info-soft info-soft
          ;; Clearly distinct on both :bg and :select across dark & light themes
          :bar-track (etaf-agenda--mix bg ink (if dark-p 0.16 0.16))
          :heat0 (etaf-agenda--mix bg ink (if dark-p 0.18 0.19))
          :heat1 (etaf-agenda--mix bg ok (if dark-p 0.36 0.30))
          :heat2 (etaf-agenda--mix bg ok (if dark-p 0.66 0.60))
          :heat3 ok)))

(defun etaf-agenda-palette ()
  "Return the cached semantic palette for the active theme and frame."
  (let ((key (etaf-agenda--palette-key)))
    (if (equal key (car-safe etaf-agenda--palette-cache))
        (cdr etaf-agenda--palette-cache)
      (let ((palette (etaf-agenda--derive-palette)))
        (setq etaf-agenda--palette-cache (cons key palette))
        palette))))

(defun etaf-agenda-color (role)
  "Return the colour string for semantic ROLE (keyword or symbol)."
  (let* ((key (if (keywordp role) role (intern (concat ":" (symbol-name role)))))
         (value (plist-get (etaf-agenda-palette) key)))
    (unless value
      (signal 'etaf-agenda-error (list (format "Unknown agenda colour role: %S" role))))
    value))

(defun etaf-agenda-area-color (index)
  "Return a harmonious semantic colour for area INDEX."
  (let ((cycle '(:info :accent :ok :warning :danger)))
    (etaf-agenda-color (nth (mod (max 0 index) (length cycle)) cycle))))

(defun etaf-agenda-theme-defaults ()
  "Return the complete `etaf-ui' theme token plist for the current theme."
  (let* ((p (etaf-agenda-palette))
         (bg (plist-get p :bg))
         (surface (plist-get p :surface))
         (surface2 (plist-get p :surface2))
         (ink (plist-get p :ink))
         (muted (plist-get p :muted))
         (dim (plist-get p :dim))
         (line (plist-get p :line))
         (select (plist-get p :select))
         (accent (plist-get p :accent))
         (accent-soft (plist-get p :accent-soft))
         (ok (plist-get p :ok))
         (ok-soft (plist-get p :ok-soft))
         (warning (plist-get p :warning))
         (warning-soft (plist-get p :warning-soft))
         (danger (plist-get p :danger))
         (danger-soft (plist-get p :danger-soft))
         (base (etaf-ui-theme-tokens
                (list :bg bg :fg ink :panel surface :track surface2
                      :border line :muted muted :dim dim
                      :accent accent :accent-fg bg :accent-soft accent-soft))))
    (append
     base
     (list :ui-bg bg
           :ui-fg ink
           :ui-panel-bg surface
           :ui-panel-fg ink
           :ui-panel-border line
           :ui-divider-bg line
           :ui-button-padding '((lh 0) (ch 2))
           :ui-input-padding '((lh 0) (ch 1))
           :ui-input-bg bg
           :ui-input-fg ink
           :ui-input-border line
           :ui-input-placeholder dim
           :ui-input-radius '(px 0)
           :ui-hover-bg (plist-get p :hover)
           :ui-selected-bg select
           :ui-selected-fg ink
           :ui-accent accent
           :ui-accent-soft accent-soft
           :ui-success ok
           :ui-success-soft ok-soft
           :ui-warning warning
           :ui-warning-soft warning-soft
           :ui-danger danger
           :ui-danger-soft danger-soft))))

(defun etaf-agenda-theme ()
  "Return a reactive computed holding `etaf-ui' theme tokens."
  (etaf-computed
   (lambda ()
     (etaf-theme-current-mode)
     (etaf-agenda-theme-defaults))
   :test #'equal
   :name 'etaf-agenda-theme-tokens))

(provide 'etaf-agenda-theme)
;;; etaf-agenda-theme.el ends here
