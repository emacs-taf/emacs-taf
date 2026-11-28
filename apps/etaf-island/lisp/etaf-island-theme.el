;;; etaf-island-theme.el --- Calm restrained theme tokens for ETAF Island -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Semantic theme derivation for `etaf-island'.  Follows the active Emacs frame
;; theme (`auto') or explicit `dark' / `light' polarity with desaturated dark
;; accents, whisper-soft borders and three-tier neutral surfaces.

;;; Code:
(require 'cl-lib)
(require 'color)
(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-island-error "Invalid ETAF Island operation")

(defvar etaf-island--theme-epoch (etaf-ref 0 :name 'island-theme-epoch)
  "Reactive counter bumped whenever an Emacs theme is enabled or disabled.")

(defvar etaf-island--token-cache nil
  "Cached (KEY . TOKENS) for `etaf-island--tokens'.")

(defun etaf-island--on-host-theme-change (&rest _)
  "Invalidate cached tokens and notify mounted ETAF Island views."
  (setq etaf-island--token-cache nil)
  (when (etaf-ref-p etaf-island--theme-epoch)
    (ignore-errors
      (setf (etaf-value etaf-island--theme-epoch)
            (1+ (etaf-untracked (etaf-value etaf-island--theme-epoch)))))))

(add-hook 'enable-theme-functions #'etaf-island--on-host-theme-change)
(add-hook 'disable-theme-functions #'etaf-island--on-host-theme-change)

(defun etaf-island--theme-frame ()
  "Return the frame showing the current buffer, or the selected frame."
  (or (let ((win (get-buffer-window (current-buffer) t)))
        (and win (window-frame win)))
      (selected-frame)))

(defun etaf-island--valid-color (value)
  "Return VALUE when it is a parseable colour string, else nil."
  (and (stringp value)
       (not (member value '("unspecified" "unspecified-bg" "unspecified-fg")))
       (color-name-to-rgb value)
       value))

(defun etaf-island--face-color (face attr &optional fallback)
  "Return FACE's ATTR colour on the active frame, or FALLBACK."
  (let* ((frame (etaf-island--theme-frame))
         (val (and (facep face) (face-attribute face attr frame t))))
    (or (etaf-island--valid-color val) fallback)))

(defun etaf-island--luminance (hex)
  "Return perceived luminance (0..1) of colour HEX."
  (pcase-let ((`(,r ,g ,b) (or (color-name-to-rgb hex) '(0.5 0.5 0.5))))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun etaf-island--mix (from to amount)
  "Blend colour FROM toward TO by AMOUNT (0..1), returning #RRGGBB."
  (let ((a (or (color-name-to-rgb from) '(0.0 0.0 0.0)))
        (b (or (color-name-to-rgb to) '(1.0 1.0 1.0))))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (x y) (+ (* x (- 1.0 amount)) (* y amount))) a b)
                   (list 2)))))

(defun etaf-island--calm-hue (raw surface fg dark-p &optional min-contrast)
  "Desaturate RAW slightly in DARK-P mode and ensure legibility over SURFACE."
  (let* ((base (or raw (if dark-p "#64B5F6" "#2563EB")))
         (soft (if dark-p
                   (let* ((d (etaf-island--mix base fg 0.24))
                          (l (etaf-island--luminance d)))
                     (if (> l 0.68) (etaf-island--mix d surface 0.22) d))
                 base)))
    (etaf-ui-color-legible soft surface (or min-contrast 4.0))))

(defun etaf-island--host-bg-fg ()
  "Return (BG FG DARK-P) detected from the active Emacs frame."
  (let* ((frame (etaf-island--theme-frame))
         (mode-param (frame-parameter frame 'background-mode))
         (raw-bg (etaf-island--face-color 'default :background nil))
         (dark-p (if raw-bg
                     (< (etaf-island--luminance raw-bg) 0.45)
                   (not (eq mode-param 'light))))
         (bg (or raw-bg (if dark-p "#263238" "#FFFFFF")))
         (fg (etaf-island--face-color 'default :foreground
                                      (if dark-p "#E6EEF2" "#1E293B"))))
    (list bg fg dark-p)))

(defun etaf-island--resolved-mode (appearance)
  "Resolve APPEARANCE (`auto', `dark' or `light') to `dark' or `light'."
  (pcase appearance
    ('dark 'dark)
    ('light 'light)
    (_ (if (nth 2 (etaf-island--host-bg-fg)) 'dark 'light))))

(defun etaf-island--build-tokens (bg fg dark-p &optional curated)
  "Build calm three-tier `etaf-island' + `etaf-ui' token plist."
  (let* ((lum (etaf-island--luminance bg))
         (canvas (cond
                  (curated bg)
                  ((and (not dark-p) (> lum 0.95)) (etaf-island--mix bg fg 0.03))
                  (t bg)))
         (surface (cond
                   ((and curated dark-p) "#2D3B42")
                   ((and curated (not dark-p)) "#FFFFFF")
                   (dark-p (etaf-island--mix canvas fg 0.05))
                   (t "#FFFFFF")))
         (card (cond
                ((and curated dark-p) "#324149")
                ((and curated (not dark-p)) "#F8FAFC")
                (dark-p (etaf-island--mix canvas fg 0.085))
                (t (etaf-island--mix surface fg 0.03))))
         (card-selected (cond
                         ((and curated dark-p) "#374953")
                         ((and curated (not dark-p)) "#F1F5F9")
                         (dark-p (etaf-island--mix canvas fg 0.125))
                         (t (etaf-island--mix surface fg 0.055))))
         (ctrl (cond
                ((and curated dark-p) "#3B4D57")
                ((and curated (not dark-p)) "#EEF2F7")
                (dark-p (etaf-island--mix canvas fg 0.135))
                (t (etaf-island--mix surface fg 0.075))))
         (border (etaf-island--mix surface fg (if dark-p 0.16 0.16)))
         (border-soft (etaf-island--mix surface fg (if dark-p 0.11 0.10)))
         (track (etaf-island--mix surface fg (if dark-p 0.14 0.15)))
         (hover (etaf-island--mix surface fg (if dark-p 0.075 0.05)))
         (ink (etaf-ui-color-legible fg surface 6.5))
         (muted (etaf-ui-color-legible (etaf-island--mix ink surface (if dark-p 0.32 0.36))
                                       surface 4.2))
         (dim (etaf-ui-color-legible (etaf-island--mix ink surface (if dark-p 0.48 0.50))
                                     surface 3.1))
         (raw-accent (or (unless curated (etaf-island--face-color 'link :foreground nil))
                         (if dark-p "#64B5F6" "#2563EB")))
         (accent (etaf-island--calm-hue raw-accent surface ink dark-p 4.2))
         (accent-fill (if dark-p
                          (etaf-island--mix accent canvas 0.54)
                        accent))
         (accent-fg (if (>= (etaf-ui-color-contrast "#F8FAFC" accent-fill) 4.5)
                        "#F8FAFC"
                      "#0F172A"))
         (accent-soft (etaf-island--mix surface accent (if dark-p 0.14 0.10)))
         (success (etaf-island--calm-hue (if dark-p "#81C784" "#15803D") surface ink dark-p 4.0))
         (success-bg (etaf-island--mix surface success (if dark-p 0.13 0.11)))
         (warning (etaf-island--calm-hue (if dark-p "#FFB74D" "#B45309") surface ink dark-p 4.0))
         (warning-bg (etaf-island--mix surface warning (if dark-p 0.13 0.11)))
         (danger (etaf-island--calm-hue (if dark-p "#F36C60" "#DC2626") surface ink dark-p 4.0))
         (danger-bg (etaf-island--mix surface danger (if dark-p 0.13 0.11)))
         (spectrum (etaf-island--calm-hue (if dark-p "#7FB5B5" "#0D9488") surface ink dark-p 3.8))
         (palette
          (list :bg canvas :fg ink :panel surface :track track :border border
                :muted muted :dim dim
                :accent accent :accent-fg accent-fg :accent-soft accent-soft
                :success success :success-bg success-bg :success-border border-soft
                :warning warning :warning-bg warning-bg :warning-border border-soft
                :danger danger :danger-bg danger-bg :danger-border border-soft
                :info accent :info-bg accent-soft :info-border border-soft))
         (base (etaf-ui-theme-tokens palette)))
    (append
     (list :ui-mode (if dark-p 'dark 'light)
           :island-bg canvas
           :island-surface surface
           :island-card card
           :island-card-selected card-selected
           :island-ctrl ctrl
           :island-border border
           :island-border-soft border-soft
           :island-fg ink
           :island-muted muted
           :island-dim dim
           :island-accent accent
           :island-accent-fill accent-fill
           :island-accent-fg accent-fg
           :island-accent-soft accent-soft
           :island-spectrum spectrum
           :island-focus success
           :island-focus-soft success-bg
           :island-warn warning
           :island-warn-soft warning-bg
           :island-danger danger
           :island-danger-soft danger-bg
           :island-track track
           :island-hover hover)
     base)))

(defun etaf-island--tokens (mode)
  "Return the ETAF Theme token plist for MODE (`auto', `dark' or `light')."
  (let* ((m (if (memq mode '(auto dark light)) mode 'auto))
         (host (when (eq m 'auto) (etaf-island--host-bg-fg)))
         (key (list m host custom-enabled-themes
                    (etaf-untracked (etaf-value etaf-island--theme-epoch)))))
    (if (equal key (car-safe etaf-island--token-cache))
        (cdr etaf-island--token-cache)
      (let ((tok
             (pcase m
               ('dark (etaf-island--build-tokens "#263238" "#E6EEF2" t t))
               ('light (etaf-island--build-tokens "#F1F5F9" "#1E293B" nil t))
               (_ (etaf-island--build-tokens (nth 0 host) (nth 1 host) (nth 2 host) nil)))))
        (setq etaf-island--token-cache (cons key tok))
        tok))))

(defun etaf-island--variant-colors (tokens variant)
  "Return (FG BG LABEL) for notification VARIANT in TOKENS."
  (pcase variant
    ('success (list (plist-get tokens :island-focus)
                    (plist-get tokens :island-focus-soft)
                    "完成"))
    ('warning (list (plist-get tokens :island-warn)
                    (plist-get tokens :island-warn-soft)
                    "提醒"))
    ('danger  (list (plist-get tokens :island-danger)
                    (plist-get tokens :island-danger-soft)
                    "告警"))
    (_        (list (plist-get tokens :island-accent)
                    (plist-get tokens :island-accent-soft)
                    "通知"))))

(provide 'etaf-island-theme)
;;; etaf-island-theme.el ends here
