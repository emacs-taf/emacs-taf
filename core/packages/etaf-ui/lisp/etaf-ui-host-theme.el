;;; etaf-ui-host-theme.el --- Host-adaptive semantic theme engine -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Unified host-adaptive and seed-driven theme engine for ETAF applications.
;; Samples the active Emacs frame's faces (or accepts explicit curated seeds),
;; normalizes colors deterministically across batch, TTY and GUI frames, calms
;; overly saturated dark-mode accents in OKLCH space, enforces WCAG AA
;; legibility, caches per frame/theme signature with shared theme-switch
;; invalidation, and projects onto `etaf-ui-theme-tokens' and `--etaf-*' ECSS
;; custom properties.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'etaf)
(require 'etaf-ui-style)

(defvar etaf-ui-host-theme--epoch
  (etaf-ref 0 :name 'etaf-ui-host-theme-epoch)
  "Reactive counter bumped when Emacs enables or disables a theme.")

(defvar etaf-ui-host-theme--epoch-counter 0
  "Monotonic integer mirroring `etaf-ui-host-theme--epoch' without tracking.")

(defvar etaf-ui-host-theme--cache (make-hash-table :test #'equal)
  "Bounded cache mapping (SIGNATURE . OPTIONS) to derived palette plists.")

(defconst etaf-ui-host-theme--cache-limit 128
  "Maximum cached palette entries before clearing.")

(defconst etaf-ui-host-theme--palette-options
  '(:mode :frame :bg :fg :surface-1 :surface-2 :surface-3 :sunken
    :ink-2 :ink-3 :border :border-subtle :border-strong :select :hover :track
    :accent :accent-fg :accent-soft :accent-border
    :ok :ok-soft :ok-border
    :warn :warn-soft :warn-border
    :danger :danger-soft :danger-border
    :info :info-soft :info-border
    :important :important-soft :important-border
    :curated :calm-dark :aliases :extras)
  "Accepted option keywords for `etaf-ui-host-theme-palette'.")

(defconst etaf-ui-host-theme--css-var-map
  '((:surface-0 . --etaf-surface-0)
    (:surface-1 . --etaf-surface-1)
    (:surface-2 . --etaf-surface-2)
    (:surface-3 . --etaf-surface-3)
    (:sunken . --etaf-sunken)
    (:ink-1 . --etaf-ink-1)
    (:ink-2 . --etaf-ink-2)
    (:ink-3 . --etaf-ink-3)
    (:border . --etaf-border)
    (:border-subtle . --etaf-border-subtle)
    (:border-strong . --etaf-border-strong)
    (:accent . --etaf-accent)
    (:accent-fg . --etaf-accent-fg)
    (:accent-soft . --etaf-accent-soft)
    (:ok . --etaf-ok)
    (:ok-soft . --etaf-ok-soft)
    (:warn . --etaf-warn)
    (:warn-soft . --etaf-warn-soft)
    (:danger . --etaf-danger)
    (:danger-soft . --etaf-danger-soft)
    (:info . --etaf-info)
    (:info-soft . --etaf-info-soft)
    (:important . --etaf-important)
    (:important-soft . --etaf-important-soft)
    (:select . --etaf-select)
    (:hover . --etaf-hover)
    (:track . --etaf-track))
  "Mapping from semantic palette keys to `--etaf-*' ECSS custom properties.")

(defun etaf-ui-host-theme--on-theme-change (&rest _)
  "Clear cached palettes and notify reactive theme consumers."
  (clrhash etaf-ui-host-theme--cache)
  (when (etaf-ref-p etaf-ui-host-theme--epoch)
    (ignore-errors
      (etaf-batch
       (setf (etaf-value etaf-ui-host-theme--epoch)
             (cl-incf etaf-ui-host-theme--epoch-counter))))))

(add-hook 'enable-theme-functions #'etaf-ui-host-theme--on-theme-change)
(add-hook 'disable-theme-functions #'etaf-ui-host-theme--on-theme-change)

;;; Color normalization & OKLab / OKLCH math

(defun etaf-ui-host-theme--hex (color)
  "Normalize COLOR to `#RRGGBB', or return nil when unspecified or invalid.
Resolves `#RRGGBB', `#RGB' and X11 names directly from `color-name-rgb-alist'
before consulting the frame palette so batch and GUI sessions agree."
  (when (and (stringp color)
             (not (equal color "unspecified"))
             (not (string-prefix-p "unspecified-" color)))
    (cond
     ((string-match
       "\\`#\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\'"
       color)
      color)
     ((string-match
       "\\`#\\([[:xdigit:]]\\)\\([[:xdigit:]]\\)\\([[:xdigit:]]\\)\\'"
       color)
      (let ((r (match-string 1 color))
            (g (match-string 2 color))
            (b (match-string 3 color)))
        (format "#%s%s%s%s%s%s" r r g g b b)))
     ((when-let* ((entry (assoc-string color color-name-rgb-alist t)))
        (cl-destructuring-bind (r g b) (cdr entry)
          (format "#%02X%02X%02X" (ash r -8) (ash g -8) (ash b -8)))))
     (t (etaf-ui--color-hex color)))))

(defun etaf-ui-host-theme--srgb-to-linear (c)
  "Convert sRGB channel C in [0, 1] to linear light."
  (if (<= c 0.04045)
      (/ c 12.92)
    (expt (/ (+ c 0.055) 1.055) 2.4)))

(defun etaf-ui-host-theme--linear-to-srgb (c)
  "Convert linear light C to sRGB channel clamped to [0, 1]."
  (let ((x (max 0.0 (min 1.0 c))))
    (if (<= x 0.0031308)
        (* 12.92 x)
      (- (* 1.055 (expt x (/ 1.0 2.4))) 0.055))))

(defun etaf-ui-host-theme--cbrt (x)
  "Return the real cube root of X."
  (cond ((= x 0.0) 0.0)
        ((< x 0.0) (- (expt (- x) (/ 1.0 3.0))))
        (t (expt x (/ 1.0 3.0)))))

(defun etaf-ui-host-theme--hex-to-oklch (hex)
  "Return (L C H) in OKLCH space for `#RRGGBB' string HEX, or nil."
  (when-let* ((channels (etaf-ui--color-channels hex)))
    (let* ((r (etaf-ui-host-theme--srgb-to-linear (/ (nth 0 channels) 255.0)))
           (g (etaf-ui-host-theme--srgb-to-linear (/ (nth 1 channels) 255.0)))
           (b (etaf-ui-host-theme--srgb-to-linear (/ (nth 2 channels) 255.0)))
           (l (etaf-ui-host-theme--cbrt (+ (* 0.4122214708 r)
                                           (* 0.5363325363 g)
                                           (* 0.0514459929 b))))
           (m (etaf-ui-host-theme--cbrt (+ (* 0.2119034982 r)
                                           (* 0.6806995451 g)
                                           (* 0.1073969566 b))))
           (s (etaf-ui-host-theme--cbrt (+ (* 0.0883024619 r)
                                           (* 0.2817188376 g)
                                           (* 0.6299787005 b))))
           (L (+ (* 0.2104542553 l) (* 0.7936177850 m) (* -0.0040720468 s)))
           (a (+ (* 1.9779984951 l) (* -2.4285922050 m) (* 0.4505937099 s)))
           (bk (+ (* 0.0259040371 l) (* 0.7827717662 m) (* -0.8086757660 s)))
           (C (sqrt (+ (* a a) (* bk bk))))
           (H (atan bk a)))
      (list L C H))))

(defun etaf-ui-host-theme--oklch-to-hex (L C H)
  "Convert OKLCH (L C H) back to `#RRGGBB', clamping to the sRGB gamut."
  (let* ((a (* C (cos H)))
         (bk (* C (sin H)))
         (l (+ L (* 0.3963377774 a) (* 0.2158037573 bk)))
         (m (+ L (* -0.1055613458 a) (* -0.0638541728 bk)))
         (s (+ L (* -0.0894841775 a) (* -1.2914855480 bk)))
         (l3 (* l l l))
         (m3 (* m m m))
         (s3 (* s s s))
         (r (etaf-ui-host-theme--linear-to-srgb
             (+ (* 4.0767416621 l3) (* -3.3077115913 m3) (* 0.2309699292 s3))))
         (g (etaf-ui-host-theme--linear-to-srgb
             (+ (* -1.2684380046 l3) (* 2.6097574011 m3) (* -0.3413193965 s3))))
         (b (etaf-ui-host-theme--linear-to-srgb
             (+ (* -0.0041960863 l3) (* -0.7034186147 m3) (* 1.7076147010 s3)))))
    (format "#%02X%02X%02X"
            (max 0 (min 255 (round (* r 255.0))))
            (max 0 (min 255 (round (* g 255.0))))
            (max 0 (min 255 (round (* b 255.0)))))))

(defun etaf-ui-host-theme--calm (color surface dark-p &optional min-ratio)
  "Calm overly saturated dark-mode COLOR in OKLCH and enforce WCAG legibility.
Preserves hue while capping chroma and lightness on dark surfaces so neon
theme faces become comfortable accents that still pass MIN-RATIO over SURFACE."
  (let* ((hex (etaf-ui-host-theme--hex color))
         (bg (etaf-ui-host-theme--hex surface))
         (ratio (or min-ratio (if dark-p 4.5 4.8))))
    (if (not (and hex bg))
        (or hex color)
      (let ((calmed
             (if (and dark-p (etaf-ui-host-theme--hex-to-oklch hex))
                 (cl-destructuring-bind (L C H) (etaf-ui-host-theme--hex-to-oklch hex)
                   (if (or (> C 0.165) (> L 0.80))
                       (etaf-ui-host-theme--oklch-to-hex (min L 0.80) (min C 0.165) H)
                     hex))
               hex)))
        (etaf-ui-color-legible calmed bg ratio)))))

(defun etaf-ui-host-theme--legible-on (color surfaces ratio)
  "Tighten COLOR so it reaches RATIO contrast against every surface in SURFACES."
  (let ((c (or (etaf-ui-host-theme--hex color) color)))
    (dolist (s surfaces c)
      (when-let* ((bg (etaf-ui-host-theme--hex s)))
        (setq c (etaf-ui-color-legible c bg ratio))))))

(defun etaf-ui-host-theme--best-fg (bg)
  "Return high-contrast text color (`#FFFFFF' or `#0F172A') for fill BG."
  (let ((white-c (etaf-ui-color-contrast "#FFFFFF" bg))
        (dark-c (etaf-ui-color-contrast "#0F172A" bg)))
    (if (>= white-c dark-c) "#FFFFFF" "#0F172A")))

;;; Frame-safe face sampling

(defun etaf-ui-host-theme--frame (&optional frame)
  "Return FRAME, or the frame showing the current buffer, or `selected-frame'."
  (or (and (frame-live-p frame) frame)
      (let ((win (get-buffer-window (current-buffer) t)))
        (and win (window-frame win)))
      (selected-frame)))

(defun etaf-ui-host-theme--face (face attr frame &optional fallback)
  "Return FACE's ATTR color on FRAME as `#RRGGBB', or FALLBACK."
  (let ((val (and (facep face)
                  (ignore-errors (face-attribute face attr frame t)))))
    (or (etaf-ui-host-theme--hex val) fallback)))

(defun etaf-ui-host-theme--signature (frame)
  "Return the cache key for FRAME's current theme and sampled faces."
  (list (frame-parameter frame 'background-mode)
        (frame-parameter frame 'background-color)
        (frame-parameter frame 'foreground-color)
        custom-enabled-themes
        (mapcar (lambda (spec)
                  (and (facep (car spec))
                       (ignore-errors
                         (face-attribute (car spec) (cdr spec) frame t))))
                '((default . :background)
                  (default . :foreground)
                  (shadow . :foreground)
                  (link . :foreground)
                  (button . :foreground)
                  (hl-line . :background)
                  (success . :foreground)
                  (warning . :foreground)
                  (error . :foreground)
                  (font-lock-function-name-face . :foreground)
                  (font-lock-keyword-face . :foreground)
                  (font-lock-type-face . :foreground)
                  (font-lock-builtin-face . :foreground)
                  (font-lock-string-face . :foreground)))))

(defun etaf-ui-host-theme--validate-plist (plist allowed fn-name)
  "Validate PLIST is an even keyword plist whose keys are in ALLOWED."
  (unless (and (proper-list-p plist) (cl-evenp (length plist)))
    (signal 'wrong-type-argument (list 'plistp plist)))
  (cl-loop for (k _v) on plist by #'cddr
           do (unless (and (keywordp k) (memq k allowed))
                (signal 'wrong-type-argument
                        (list (cons 'member allowed) k fn-name)))))

(defun etaf-ui-host-theme--rgb-distance (c1 c2)
  "Return normalized Euclidean sRGB distance between hex colors C1 and C2."
  (let ((a (etaf-ui--color-channels c1))
        (b (etaf-ui--color-channels c2)))
    (if (and a b)
        (sqrt (+ (expt (/ (- (nth 0 a) (nth 0 b)) 255.0) 2)
                 (expt (/ (- (nth 1 a) (nth 1 b)) 255.0) 2)
                 (expt (/ (- (nth 2 a) (nth 2 b)) 255.0) 2)))
      1.0)))

(defun etaf-ui-host-theme--warm-yellow-p (hex)
  "Return non-nil when HEX has a warm yellow or ochre hue."
  (when-let* ((ch (etaf-ui--color-channels hex)))
    (let ((r (/ (nth 0 ch) 255.0))
          (g (/ (nth 1 ch) 255.0))
          (b (/ (nth 2 ch) 255.0)))
      (and (> r 0.40) (> g 0.30)
           (>= r (* 0.85 g))
           (> (- (min r g) b) 0.16)))))

(defun etaf-ui-host-theme--pick-info-seed (frame dark-p accent warn)
  "Pick a cool info color from FRAME distinct from WARN."
  (let* ((type-c (etaf-ui-host-theme--face 'font-lock-type-face :foreground frame))
         (built-c (etaf-ui-host-theme--face 'font-lock-builtin-face :foreground frame))
         (fallback (if dark-p "#68C4D8" "#0C6A7D"))
         (bad-p (lambda (c)
                  (or (not c)
                      (and (not dark-p) (etaf-ui-host-theme--warm-yellow-p c))
                      (< (etaf-ui-host-theme--rgb-distance c warn) 0.22)))))
    (cond
     ((not (funcall bad-p type-c)) type-c)
     ((and (not (funcall bad-p built-c))
           (>= (etaf-ui-host-theme--rgb-distance built-c accent) 0.12))
      built-c)
     (t fallback))))

(defun etaf-ui-host-theme--derive (frame mode options)
  "Derive a complete semantic palette plist for FRAME, MODE and OPTIONS."
  (let* ((curated (plist-get options :curated))
         (opt (lambda (k) (plist-get options k)))
         (opt-hex (lambda (k)
                    (when-let* ((v (plist-get options k)))
                      (or (etaf-ui-host-theme--hex v)
                          (signal 'wrong-type-argument (list 'stringp k v))))))
         (sample-host (and (not curated) (eq mode 'auto)))
         (raw-host-bg (when sample-host
                        (etaf-ui-host-theme--face 'default :background frame)))
         (raw-bg (or (funcall opt-hex :bg) raw-host-bg))
         (dark-p
          (cond
           ((eq mode 'dark) t)
           ((eq mode 'light) nil)
           (raw-bg (< (or (etaf-ui--color-luminance raw-bg) 0.5) 0.45))
           (t (eq (frame-parameter frame 'background-mode) 'dark))))
         (resolved-mode (if dark-p 'dark 'light))
         (calm-dark (if (plist-member options :calm-dark)
                        (plist-get options :calm-dark)
                      (not curated)))
         (surface-0 (or raw-bg (if dark-p "#191A1C" "#FFFFFF")))
         (raw-fg (or (funcall opt-hex :fg)
                     (and sample-host
                          (etaf-ui-host-theme--face 'default :foreground frame))
                     (if dark-p "#E6EDF3" "#1F2328")))
         ;; Surface ladder (three neutral elevations + recessed sunken)
         (surface-1 (or (funcall opt-hex :surface-1)
                        (etaf-ui-color-mix surface-0 raw-fg
                                           (if dark-p 0.045 0.036))))
         (surface-2 (or (funcall opt-hex :surface-2)
                        (etaf-ui-color-mix surface-0 raw-fg
                                           (if dark-p 0.085 0.075))))
         (surface-3 (or (funcall opt-hex :surface-3)
                        (etaf-ui-color-mix surface-0 raw-fg
                                           (if dark-p 0.125 0.11))))
         (sunken (or (funcall opt-hex :sunken)
                     (if dark-p
                         (etaf-ui-color-mix surface-0 "#000000" 0.28)
                       (etaf-ui-color-mix surface-0 raw-fg 0.09))))
         ;; Borders & interactive surfaces
         (border (or (funcall opt-hex :border)
                     (etaf-ui-color-mix surface-0 raw-fg (if dark-p 0.16 0.16))))
         (border-subtle (or (funcall opt-hex :border-subtle)
                            (etaf-ui-color-mix surface-0 raw-fg
                                               (if dark-p 0.10 0.095))))
         (border-strong (or (funcall opt-hex :border-strong)
                            (etaf-ui-color-mix surface-0 raw-fg
                                               (if dark-p 0.26 0.25))))
         (select (or (funcall opt-hex :select)
                     (when sample-host
                       (let ((hl (etaf-ui-host-theme--face 'hl-line :background frame)))
                         (and hl
                              (> (etaf-ui-color-contrast hl surface-0) 1.06)
                              (< (etaf-ui-color-contrast hl surface-0) 2.2)
                              hl)))
                     (etaf-ui-color-mix surface-0 raw-fg (if dark-p 0.10 0.085))))
         (hover (or (funcall opt-hex :hover)
                    (etaf-ui-color-mix surface-0 raw-fg (if dark-p 0.07 0.045))))
         (track (or (funcall opt-hex :track)
                    (etaf-ui-color-mix surface-0 raw-fg (if dark-p 0.15 0.15))))
         ;; Text hierarchy with WCAG AA floors
         (ink-1 (if curated
                    raw-fg
                  (etaf-ui-host-theme--legible-on raw-fg (list surface-0 surface-1) 6.0)))
         (raw-ink-2
          (or (funcall opt-hex :ink-2)
              (when sample-host
                (let ((sh (etaf-ui-host-theme--face 'shadow :foreground frame)))
                  (and sh (>= (etaf-ui-color-contrast sh surface-0)
                              (if dark-p 4.4 5.4))
                       sh)))
              (etaf-ui-color-mix surface-0 ink-1 (if dark-p 0.62 0.68))))
         (ink-2 (if (and curated (funcall opt :ink-2))
                    raw-ink-2
                  (etaf-ui-host-theme--legible-on
                   raw-ink-2 (list surface-0 surface-1) (if dark-p 4.5 5.4))))
         (raw-ink-3 (or (funcall opt-hex :ink-3)
                        (etaf-ui-color-mix surface-0 ink-1 (if dark-p 0.44 0.58))))
         (ink-3 (if (and curated (funcall opt :ink-3))
                    raw-ink-3
                  (etaf-ui-host-theme--legible-on
                   raw-ink-3 (list surface-0 surface-1) (if dark-p 3.2 4.5))))
         ;; Semantic roles
         (soft-ratio (if dark-p 0.16 0.11))
         (bdr-ratio (if dark-p 0.38 0.35))
         (sem-floor (if dark-p 4.5 4.8))
         (pill-floor (if dark-p 4.5 4.5))
         (derive-role
          (lambda (key soft-key bdr-key raw-seed)
            (let* ((explicit (funcall opt-hex key))
                   (base (cond
                          ((and curated explicit) explicit)
                          (calm-dark
                           (etaf-ui-host-theme--calm
                            (or explicit raw-seed) surface-0 dark-p sem-floor))
                          (t (etaf-ui-color-legible
                              (or explicit raw-seed) surface-0 sem-floor))))
                   (soft (or (funcall opt-hex soft-key)
                             (etaf-ui-color-mix surface-0 base soft-ratio)))
                   (bdr (or (funcall opt-hex bdr-key)
                            (etaf-ui-color-mix surface-0 base bdr-ratio)))
                   (final (if (and curated explicit)
                              base
                            (etaf-ui-host-theme--legible-on
                             base (list surface-0 surface-1 soft) pill-floor))))
              (list final soft bdr))))
         (accent-seed (or (funcall opt-hex :accent)
                          (and sample-host
                               (or (etaf-ui-host-theme--face 'link :foreground frame)
                                   (etaf-ui-host-theme--face 'button :foreground frame)
                                   (etaf-ui-host-theme--face
                                    'font-lock-function-name-face :foreground frame)
                                   (etaf-ui-host-theme--face
                                    'font-lock-keyword-face :foreground frame)))
                          (if dark-p "#58A6FF" "#0969DA")))
         (accent-trio (funcall derive-role :accent :accent-soft :accent-border accent-seed))
         (accent (nth 0 accent-trio))
         (accent-fg (or (funcall opt-hex :accent-fg)
                        (etaf-ui-host-theme--best-fg accent)))
         (ok-seed (or (funcall opt-hex :ok)
                      (and sample-host
                           (or (etaf-ui-host-theme--face 'success :foreground frame)
                               (etaf-ui-host-theme--face
                                'font-lock-string-face :foreground frame)))
                      (if dark-p "#3FB950" "#1A7F37")))
         (ok-trio (funcall derive-role :ok :ok-soft :ok-border ok-seed))
         (warn-seed (or (funcall opt-hex :warn)
                        (and sample-host
                             (etaf-ui-host-theme--face 'warning :foreground frame))
                        (if dark-p "#D29922" "#9A6700")))
         (warn-trio (funcall derive-role :warn :warn-soft :warn-border warn-seed))
         (danger-seed (or (funcall opt-hex :danger)
                          (and sample-host
                               (etaf-ui-host-theme--face 'error :foreground frame))
                          (if dark-p "#F85149" "#D1242F")))
         (danger-trio (funcall derive-role :danger :danger-soft :danger-border danger-seed))
         (info-seed (or (funcall opt-hex :info)
                        (and sample-host
                             (etaf-ui-host-theme--pick-info-seed
                              frame dark-p accent (nth 0 warn-trio)))
                        accent))
         (info-trio (funcall derive-role :info :info-soft :info-border info-seed))
         (imp-seed (or (funcall opt-hex :important)
                       (and sample-host
                            (etaf-ui-host-theme--face
                             'font-lock-keyword-face :foreground frame))
                       (if dark-p "#A371F7" "#8250DF")))
         (imp-trio (funcall derive-role :important :important-soft :important-border imp-seed))
         (palette
          (list :mode resolved-mode
                :dark-p dark-p
                :surface-0 surface-0
                :surface-1 surface-1
                :surface-2 surface-2
                :surface-3 surface-3
                :sunken sunken
                :ink-1 ink-1
                :ink-2 ink-2
                :ink-3 ink-3
                :border border
                :border-subtle border-subtle
                :border-strong border-strong
                :select select
                :hover hover
                :track track
                :accent accent
                :accent-fg accent-fg
                :accent-soft (nth 1 accent-trio)
                :accent-border (nth 2 accent-trio)
                :ok (nth 0 ok-trio)
                :ok-soft (nth 1 ok-trio)
                :ok-border (nth 2 ok-trio)
                :warn (nth 0 warn-trio)
                :warn-soft (nth 1 warn-trio)
                :warn-border (nth 2 warn-trio)
                :danger (nth 0 danger-trio)
                :danger-soft (nth 1 danger-trio)
                :danger-border (nth 2 danger-trio)
                :info (nth 0 info-trio)
                :info-soft (nth 1 info-trio)
                :info-border (nth 2 info-trio)
                :important (nth 0 imp-trio)
                :important-soft (nth 1 imp-trio)
                :important-border (nth 2 imp-trio)))
         (aliases
          (when (funcall opt :aliases)
            (list :dark dark-p :bg surface-0 :ink ink-1 :muted ink-2 :dim ink-3 :faint ink-3
                  :panel surface-1 :surface surface-1 :panel2 surface-2 :surface2 surface-2
                  :panel3 surface-3 :line border :line-soft border-subtle :hairline border-subtle
                  :line-strong border-strong :selected select :warning (nth 0 warn-trio)
                  :warning-soft (nth 1 warn-trio) :ok-bg (nth 1 ok-trio) :success-bg (nth 1 ok-trio)
                  :warn-bg (nth 1 warn-trio) :danger-bg (nth 1 danger-trio)))))
    (append (funcall opt :extras) palette aliases)))

;;; Public API

;;;###autoload
(defun etaf-ui-host-theme-palette (&rest options)
  "Return a semantic color palette derived from the active Emacs frame or seeds.

OPTIONS is a keyword plist:
- `:mode': `auto' (default, follow Emacs frame faces), `appearance' (follow
  `etaf-appearance'), `dark', or `light'.
- `:frame': frame to sample faces from (default current buffer's frame or
  `selected-frame').
- `:bg', `:fg', `:accent', `:surface-1', `:surface-2', `:surface-3', `:sunken',
  `:ink-2', `:ink-3', `:border', `:border-subtle', `:border-strong', `:select',
  `:hover', `:track', `:accent-fg', `:accent-soft', `:accent-border', and
  status seeds `:ok', `:warn', `:danger', `:info', `:important' (plus `-soft'
  and `-border' variants): explicit `#RRGGBB' or X11 color overrides.
- `:curated': when non-nil, keep explicit color seeds verbatim instead of
  re-sampling frame faces or adjusting calibrated brand hues, while still
  deriving every omitted surface, border, soft tint and contrast role.
- `:calm-dark': when non-nil (default when `:curated' is nil), calm overly
  saturated dark-mode accents in OKLCH space while keeping WCAG AA contrast.
- `:aliases': when non-nil, include common short role aliases (`:bg', `:ink',
  `:muted', `:dim', `:panel', `:surface', `:panel2', `:panel3', `:line',
  `:line-soft', `:selected', `:danger-bg', etc.) for direct app lookups.
- `:extras': optional plist of extra application keys prepended to the result.

Returns a plist containing `:mode', `:dark-p', `:surface-0', `:surface-1',
`:surface-2', `:surface-3', `:sunken', `:ink-1', `:ink-2', `:ink-3', `:border',
`:border-subtle', `:border-strong', `:select', `:hover', `:track', `:accent',
`:accent-fg', `:accent-soft', `:accent-border', `:ok', `:ok-soft', `:ok-border',
`:warn', `:warn-soft', `:warn-border', `:danger', `:danger-soft',
`:danger-border', `:info', `:info-soft', `:info-border', `:important',
`:important-soft', and `:important-border'."
  (etaf-ui-host-theme--validate-plist
   options etaf-ui-host-theme--palette-options 'etaf-ui-host-theme-palette)
  (let* ((raw-mode (or (plist-get options :mode) 'auto))
         (mode (pcase raw-mode
                 ('auto
                  (etaf-theme-current-mode)
                  (etaf-value etaf-ui-host-theme--epoch)
                  'auto)
                 ('appearance
                  (etaf-value etaf-ui-host-theme--epoch)
                  (etaf-appearance))
                 ((or 'dark 'light) raw-mode)
                 (_ (signal 'wrong-type-argument
                            (list '(member auto appearance dark light)
                                  raw-mode)))))
         (frame (etaf-ui-host-theme--frame (plist-get options :frame)))
         (cache-key (list mode
                          (when (and (eq mode 'auto)
                                     (not (plist-get options :curated)))
                            (etaf-ui-host-theme--signature frame))
                          options)))
    (or (gethash cache-key etaf-ui-host-theme--cache)
        (progn
          (when (>= (hash-table-count etaf-ui-host-theme--cache)
                    etaf-ui-host-theme--cache-limit)
            (clrhash etaf-ui-host-theme--cache))
          (puthash cache-key
                   (etaf-ui-host-theme--derive frame mode options)
                   etaf-ui-host-theme--cache)))))

;;;###autoload
(defun etaf-ui-host-theme-tokens (&rest options)
  "Return a complete `etaf-ui' Theme token plist from host theme or seeds.

Accepts all keyword OPTIONS of `etaf-ui-host-theme-palette', plus:
- `:palette': a precomputed palette plist from `etaf-ui-host-theme-palette'.
- `:overrides': a Theme plist placed before the derived catalog tokens so
  application-specific keys and overrides take precedence.

The returned plist is ready to pass directly to `etaf-theme-provide'."
  (let* ((palette (plist-get options :palette))
         (overrides (plist-get options :overrides))
         (pal-opts (let (out (tail options))
                     (while tail
                       (let ((k (pop tail)) (v (pop tail)))
                         (unless (memq k '(:palette :overrides))
                           (push k out)
                           (push v out))))
                     (nreverse out)))
         (p (or palette (apply #'etaf-ui-host-theme-palette pal-opts)))
         (alist-p (consp (car-safe p)))
         (get (lambda (&rest keys)
                (cl-some (lambda (k)
                           (let ((v (if alist-p (cdr (assq k p)) (plist-get p k))))
                             (and (stringp v) (or (etaf-ui-host-theme--hex v) v))))
                         keys)))
         (roles nil)
         (put (lambda (role &rest keys)
                (when-let* ((v (apply get keys)))
                  (setq roles (plist-put roles role v))))))
    (funcall put :bg :surface-0 :bg)
    (funcall put :fg :ink-1 :ink :fg)
    (funcall put :panel :surface-1 :panel :surface)
    (funcall put :track :track :surface-2 :panel2 :surface-3 :panel3)
    (funcall put :border :border :line)
    (funcall put :muted :ink-2 :muted)
    (funcall put :dim :ink-3 :dim :faint)
    (funcall put :accent :accent)
    (funcall put :accent-fg :accent-fg)
    (funcall put :accent-soft :accent-soft)
    (funcall put :success :ok :success)
    (funcall put :success-bg :ok-soft :ok-bg :success-bg)
    (funcall put :success-border :ok-border :success-border)
    (funcall put :warning :warn :warning)
    (funcall put :warning-bg :warn-soft :warn-bg :warning-soft)
    (funcall put :warning-border :warn-border :warning-border)
    (funcall put :danger :danger)
    (funcall put :danger-bg :danger-soft :danger-bg)
    (funcall put :danger-border :danger-border)
    (funcall put :info :info :accent)
    (funcall put :info-bg :info-soft :info-bg :accent-soft)
    (funcall put :info-border :info-border :border :line)
    (funcall put :important :important)
    (funcall put :important-bg :important-soft :important-bg)
    (funcall put :important-border :important-border)
    (let ((base (etaf-ui-theme-tokens roles)))
      (if overrides (append overrides base) base))))

;;;###autoload
(defun etaf-ui-host-theme-css-vars (&rest options)
  "Return an ECSS `--etaf-*' custom-property declaration plist.

Accepts `:palette' (a palette plist from `etaf-ui-host-theme-palette') or any
option accepted by `etaf-ui-host-theme-palette'.  The returned plist uses
`--etaf-*' custom-property symbols suitable for `ecss-compute-style'
`:declarations' or root Component `:styles' rules."
  (let* ((palette (plist-get options :palette))
         (pal-opts (let (out (tail options))
                     (while tail
                       (let ((k (pop tail)) (v (pop tail)))
                         (unless (eq k :palette)
                           (push k out)
                           (push v out))))
                     (nreverse out)))
         (p (or palette (apply #'etaf-ui-host-theme-palette pal-opts)))
         (out nil))
    (dolist (entry etaf-ui-host-theme--css-var-map (nreverse out))
      (when-let* ((val (plist-get p (car entry))))
        (push (cdr entry) out)
        (push val out)))))

;;;###autoload
(defun etaf-ui-host-theme-ref (&rest options)
  "Return a reactive `etaf-computed' holding host-adaptive Theme tokens.

Accepts all keyword OPTIONS of `etaf-ui-host-theme-tokens', plus:
- `:mode-ref': optional ref or computed supplying the live `:mode' symbol.
- `:transform': optional function `(palette tokens)' returning the final Theme
  plist provided to `etaf-theme-provide'.
- `:name': optional debug name symbol for the returned computed.

Subscribes automatically to Emacs theme switches and `:mode-ref', recomputing
the Theme plist in place without duplicating theme hooks in applications."
  (let* ((mode-ref (plist-get options :mode-ref))
         (transform (plist-get options :transform))
         (name (or (plist-get options :name) 'etaf-ui-host-theme))
         (overrides (plist-get options :overrides))
         (pal-opts (let (out (tail options))
                     (while tail
                       (let ((k (pop tail)) (v (pop tail)))
                         (unless (memq k '(:mode-ref :transform :name :overrides :palette))
                           (push k out)
                           (push v out))))
                     (nreverse out))))
    (when (and transform (not (functionp transform)))
      (signal 'wrong-type-argument (list 'functionp transform)))
    (etaf-computed
     (lambda ()
       (let* ((live-mode (when mode-ref (etaf-value mode-ref)))
              (opts (if live-mode
                        (plist-put (copy-sequence pal-opts) :mode live-mode)
                      pal-opts))
              (palette (apply #'etaf-ui-host-theme-palette opts))
              (tokens (etaf-ui-host-theme-tokens
                       :palette palette :overrides overrides)))
         (if transform
             (funcall transform palette tokens)
           tokens)))
     :test #'equal
     :name name)))

(provide 'etaf-ui-host-theme)
;;; etaf-ui-host-theme.el ends here
