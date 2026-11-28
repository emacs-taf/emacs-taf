;;; etaf-md-theme.el --- Palettes for etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Internal palettes of the markdown previewer.  A palette is a plain alist of
;; semantic color keys; the views read every color through
;; `etaf-md-color', so both palettes share one layout and a palette
;; change never leaks a half-updated set of colors.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui)

(defconst etaf-md-themes
  '((dark . ((:bg . "#191a1c")
             (:ink . "#e6edf3")
             (:muted . "#9198a1")
             (:faint . "#6e7681")
             (:accent . "#4493f8")
             (:accent-soft . "#152c4d")
             (:border . "#303338")
             (:panel . "#212328")
             (:sunken . "#121316")
             (:panel2 . "#282b31")
             (:quote-bar . "#43464b")
             (:quote-bg . "#1d1f23")
             (:table-header . "#25282e")
             (:table-stripe . "#1b1d20")
             (:heading . "#e6edf3")
             (:heading-rule . "#303338")
             (:ok . "#3fb950")
             (:ok-soft . "#12261e")
             (:warn . "#d29922")
             (:warn-soft . "#272115")
             (:danger . "#f85149")
             (:danger-soft . "#2a1518")
             (:important . "#a371f7")
             (:important-soft . "#221a38")))
    (light . ((:bg . "#ffffff")
              (:ink . "#1f2328")
              (:muted . "#59636e")
              (:faint . "#818b98")
              (:accent . "#0969da")
              (:accent-soft . "#ddf4ff")
              (:border . "#d1d9e0")
              (:panel . "#f6f8fa")
              (:sunken . "#eaeef2")
              (:panel2 . "#e6ebf1")
              (:quote-bar . "#d1d9e0")
              (:quote-bg . "#f3f6fa")
              (:table-header . "#edf1f5")
              (:table-stripe . "#f9fbfd")
              (:heading . "#1f2328")
              (:heading-rule . "#d1d9e0")
              (:ok . "#1a7f37")
              (:ok-soft . "#dafbe1")
              (:warn . "#9a6700")
              (:warn-soft . "#fff8c5")
              (:danger . "#d1242f")
              (:danger-soft . "#ffebe9")
              (:important . "#8250df")
              (:important-soft . "#fbefff")))
    (sepia . ((:bg . "#f5ecd9")
              (:ink . "#3b3024")
              (:muted . "#7a6a53")
              (:faint . "#9a8a72")
              (:accent . "#b3541e")
              (:accent-soft . "#efddc4")
              (:border . "#d8c9ab")
              (:panel . "#fbf5e8")
              (:sunken . "#e6d8bc")
              (:panel2 . "#e9dcc2")
              (:quote-bar . "#c9b694")
              (:quote-bg . "#efe4cd")
              (:table-header . "#eadbc0")
              (:table-stripe . "#f2e9d6")
              (:heading . "#3b3024")
              (:heading-rule . "#d8c9ab")
              (:ok . "#3f6212")
              (:ok-soft . "#e2ecd0")
              (:warn . "#92400e")
              (:warn-soft . "#f7e6c4")
              (:danger . "#9f1239")
              (:danger-soft . "#f5d6cf")
              (:important . "#6d28d9")
              (:important-soft . "#e9dcf5"))))
  "Color palettes of the markdown previewer.")

(defconst etaf-md--surface-modes
  '((light . "亮") (auto . "随") (dark . "暗") (sepia . "纸"))
  "Appearance modes the preview offers its host, in display order.
`auto' derives the document colors from the active Emacs theme; the other
three paint a fixed page palette.")

(defcustom etaf-md-theme 'auto
  "Initial palette of `etaf-md-create' and the page it paints.
`auto' derives the document colors from the active frame's own faces
\\(`default', `shadow', `outline-1' and the semantic faces) and paints no page
background, so the preview matches whatever Emacs theme is active.  `dark',
`light' and `sepia' select a fixed palette explicitly, including its page
background; `etaf-md-set-theme' selects `auto' or a fixed palette, and
`etaf-md-cycle-theme' cycles `dark' -> `light' -> `sepia' -> `auto'."
  :type '(choice (const :tag "Follow the Emacs theme" auto)
                 (const :tag "Dark page" dark)
                 (const :tag "Light page" light)
                 (const :tag "Sepia page" sepia))
  :group 'etaf-md)

(defun etaf-md-auto-theme ()
  "Return the palette matching the host appearance."
  (etaf-appearance))

(defun etaf-md--face-color (face attribute fallback &optional frame)
  "Return FACE's ATTRIBUTE color, or FALLBACK when it is unspecified.
FRAME selects the frame to ask; nil asks the selected frame, which is right
for a headless session that has no window of its own."
  (let ((value (ignore-errors (face-attribute face attribute frame t))))
    (if (and (stringp value) (not (equal value "unspecified")))
        value
      fallback)))

(defun etaf-md--color-rgb (color)
  "Return COLOR's red, green and blue as 16-bit values, or nil.
A hex value and an X11 name are read from the color itself; `color-values' has
to ask the frame, and a batch session has none, so it answers from the
terminal's own palette and turns a color into the nearest one it can show."
  (cond
   ((and (stringp color)
         (string-match
          "\\`#\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\'" color))
    (list (* 257 (string-to-number (match-string 1 color) 16))
          (* 257 (string-to-number (match-string 2 color) 16))
          (* 257 (string-to-number (match-string 3 color) 16))))
   ((and (stringp color) (assoc-string color color-name-rgb-alist t))
    (cdr (assoc-string color color-name-rgb-alist t)))
   (t (ignore-errors (color-values color)))))

(defun etaf-md--mix-color (base overlay weight)
  "Return BASE mixed toward OVERLAY by WEIGHT (0 to 1) as #rrggbb.
Unknown color names fall back to BASE so a theme with named colors still
resolves a usable surface."
  (let ((base-rgb (etaf-md--color-rgb base))
        (overlay-rgb (etaf-md--color-rgb overlay)))
    (if (and base-rgb overlay-rgb)
        (let ((mixed (cl-loop for base-value in (cl-subseq base-rgb 0 3)
                              for overlay-value in (cl-subseq overlay-rgb 0 3)
                              collect (ash (round (+ (* base-value (- 1 weight))
                                                     (* overlay-value weight)))
                                           -8))))
          (apply #'format "#%02x%02x%02x" mixed))
      base)))

(defun etaf-md--hex-color (color)
  "Return COLOR as #rrggbb, or COLOR unchanged when it does not resolve.
A theme may name a color the way X11 does (`SeaGreen2'), and a renderer that
parses its own colors cannot read that name."
  (let ((values (etaf-md--color-rgb color)))
    (if values
        (apply #'format "#%02x%02x%02x"
               (mapcar (lambda (value) (ash value -8)) (cl-subseq values 0 3)))
      color)))

(defun etaf-md--luminance-channel (value)
  "Return VALUE, a 0-65535 channel, as light.
A channel is stored gamma-encoded, so it is decoded first: the encoded values
understate the light a dark colour gives, and a contrast ratio measured without
the decoding calls two dark surfaces far more different than they look."
  (let ((scaled (/ value 65535.0)))
    (if (<= scaled 0.03928)
        (/ scaled 12.92)
      (expt (/ (+ scaled 0.055) 1.055) 2.4))))

(defun etaf-md--luminance (color)
  "Return the relative luminance of COLOR, or nil when it does not resolve.
The value is read from COLOR itself, so a batch session measures the color the
same way a frame does."
  (when-let* ((values (etaf-md--color-rgb color)))
    (cl-destructuring-bind (red green blue) values
      (+ (* 0.2126 (etaf-md--luminance-channel red))
         (* 0.7152 (etaf-md--luminance-channel green))
         (* 0.0722 (etaf-md--luminance-channel blue))))))

(defconst etaf-md--heading-contrast 1.35
  "Smallest contrast ratio that keeps a heading color apart from the body ink.
A heading a couple of percent away from the body text is a heading the reader
cannot see, so the step has to be a visible one; three to one is what the
shipped palettes already give, and a flat theme sits near one.
Several dark themes paint `outline-1' almost the body color, so honoring them
literally renders every heading flat; below this ratio the palette derives the
heading color from the accent instead.")

(defun etaf-md--contrast-ratio (first second)
  "Return the WCAG contrast ratio between FIRST and SECOND, or nil."
  (when-let* ((first-luminance (etaf-md--luminance first))
              (second-luminance (etaf-md--luminance second)))
    (/ (+ (max first-luminance second-luminance) 0.05)
       (+ (min first-luminance second-luminance) 0.05))))

(defun etaf-md--heading-color (face-color ink accent background)
  "Return the heading color for FACE-COLOR over INK, ACCENT and BACKGROUND.
FACE-COLOR is the theme's own heading color: it is kept when its contrast with
INK reaches `etaf-md--heading-contrast'.  Otherwise the accent is mixed
toward BACKGROUND, which keeps a hue that is neither the body text nor the
full-strength link color."
  (let ((ratio (etaf-md--contrast-ratio face-color ink)))
    (if (and ratio (>= ratio etaf-md--heading-contrast))
        face-color
      (etaf-md--mix-color accent background 0.35))))

(defun etaf-md--palette-from-faces (&optional frame)
  "Return a palette derived from FRAME's own faces.
Every surface is a blend of the frame's background toward its foreground or
a semantic accent, so `auto' matches whatever Emacs theme is active instead
of a fixed page palette.  Reading `etaf-appearance' also ties the derivation
to the switch Emacs reports through `enable-theme-functions', so a Theme
computed from this palette re-derives instead of keeping the colors of the
theme that was active when it was first read."
  (let* ((_appearance (etaf-appearance))
         (background (etaf-md--face-color 'default :background "#ffffff" frame))
         (foreground (etaf-md--face-color 'default :foreground "#1f2328" frame))
         (shadow (etaf-md--face-color
                  'shadow :foreground
                  (etaf-md--mix-color background foreground 0.55)
                  frame))
         (link (or (etaf-md--face-color 'link :foreground nil frame)
                   (etaf-md--face-color 'button :foreground nil frame)
                   (etaf-md--face-color
                    'font-lock-function-name-face :foreground nil frame)
                   foreground))
         (heading (etaf-md--heading-color
                   (etaf-md--face-color 'outline-1 :foreground foreground frame)
                   foreground link background))
         (ok (etaf-md--face-color 'success :foreground "#1a7f37" frame))
         (warn (etaf-md--face-color 'warning :foreground "#9a6700" frame))
         (danger (etaf-md--face-color 'error :foreground "#d1242f" frame))
         (important (etaf-md--face-color
                     'font-lock-keyword-face :foreground link frame)))
    (list (cons :bg background)
          (cons :ink foreground)
          (cons :muted shadow)
          (cons :faint (etaf-md--mix-color shadow background 0.4))
          (cons :accent link)
          (cons :accent-soft (etaf-md--mix-color background link 0.18))
          (cons :border (etaf-md--mix-color background foreground 0.18))
          (cons :panel (etaf-md--mix-color background foreground 0.06))
          (cons :sunken (if (< (or (etaf-md--luminance background) 1.0) 0.5)
                            (etaf-md--mix-color background "#000000" 0.28)
                          (etaf-md--mix-color background foreground 0.09)))
          (cons :panel2 (etaf-md--mix-color background foreground 0.11))
          (cons :quote-bar (etaf-md--mix-color background foreground 0.22))
          (cons :quote-bg (etaf-md--mix-color background foreground 0.045))
          (cons :table-header (etaf-md--mix-color background foreground 0.08))
          (cons :table-stripe (etaf-md--mix-color background foreground 0.022))
          (cons :heading heading)
          (cons :heading-rule (etaf-md--mix-color background foreground 0.18))
          (cons :ok ok)
          (cons :ok-soft (etaf-md--mix-color background ok 0.14))
          (cons :warn warn)
          (cons :warn-soft (etaf-md--mix-color background warn 0.14))
          (cons :danger danger)
          (cons :danger-soft (etaf-md--mix-color background danger 0.14))
          (cons :important important)
          (cons :important-soft (etaf-md--mix-color background important 0.14)))))

(defun etaf-md-color (key theme)
  "Return THEME's color for semantic KEY.
Signal `etaf-md-error' when either is unknown."
  (let ((palette (cdr (assq theme etaf-md-themes))))
    (unless palette
      (signal 'etaf-md-error
              (list (format "Unknown markdown preview theme: %S" theme))))
    (let ((color (cdr (assq key palette))))
      (unless color
        (signal 'etaf-md-error
                (list (format "Unknown markdown preview color: %S" key))))
      color)))

(declare-function etaf-display-metrics "etaf-runtime" (&optional runtime))
(declare-function etaf-image-kitty-available-p "etaf-runtime" (&optional frame))

(defun etaf-md--cell-metrics ()
  "Return (CHAR-WIDTH . LINE-HEIGHT) in pixels of the page's own text.
A picture is placed in cells, so its grid has to be measured in the cells the
page actually paints.  Text scaling changes them and a frame's default font
does not follow it, so reading the frame placed a picture in cells the page no
longer had and left it striped: slices cut for the old line height sat on
taller lines.  `etaf-display-metrics' is a reactive read, so the block that
placed a picture renders again when the scale settles.  On Kitty-capable text
terminals, uses the probed terminal cell pixel dimensions so pictures match
the terminal's real aspect ratio without letterboxing; on other terminal or
batch frames where dimensions are 1x1 character units, falls back to 8x16."
  (let* ((metrics (ignore-errors (etaf-display-metrics)))
         (cw (or (and metrics (plist-get metrics :char-width))
                 (ignore-errors (frame-char-width))))
         (ch (or (and metrics (plist-get metrics :line-height))
                 (ignore-errors (frame-char-height)))))
    (cond
     ((and (numberp cw) (> cw 1) (numberp ch) (> ch 1))
      (cons cw ch))
     ((let* ((caps (and (fboundp 'etaf-image-kitty-available-p)
                        (ignore-errors (etaf-image-kitty-available-p))))
             (kw (and caps (plist-get caps :cell-width)))
             (kh (and caps (plist-get caps :cell-height))))
        (and (numberp kw) (> kw 0) (numberp kh) (> kh 0)
             (cons kw kh))))
     (t
      (cons 8 16)))))

(defun etaf-md--base-pixels ()
  "Return the pixel size the page draws its own text at.
Text scaling changes it and a frame's default font does not follow the scale,
so a formula or a diagram typeset from the frame came out the wrong size beside
the text it stands in.  On text terminals, keep a standard 16px typographic
base rather than HiDPI physical cell heights."
  (if (display-graphic-p)
      (cdr (etaf-md--cell-metrics))
    16))

(defun etaf-md-theme-tokens (theme &optional palette)
  "Return the ETAF UI token plist for palette THEME.
PALETTE, when given, supplies the colors instead of THEME's named palette
\(used by the face-derived `auto' appearance).  The application provides this
plist through `etaf-theme-provide', so shared ETAF UI Components follow the
previewer's colors."
  (let* ((lookup (lambda (key)
                   (or (cdr (assq key palette))
                       (etaf-md-color key theme))))
         (bg (funcall lookup :bg))
         (panel (funcall lookup :panel))
         (panel2 (funcall lookup :panel2))
         (ink (funcall lookup :ink))
         (line (funcall lookup :border))
         (muted (funcall lookup :muted))
         (accent (funcall lookup :accent))
         (accent-soft (funcall lookup :accent-soft))
         (ok (funcall lookup :ok))
         (ok-soft (funcall lookup :ok-soft))
         (warn (funcall lookup :warn))
         (warn-soft (funcall lookup :warn-soft))
         (danger (funcall lookup :danger))
         (danger-soft (funcall lookup :danger-soft))
         (important (funcall lookup :important))
         (important-soft (funcall lookup :important-soft)))
    (etaf-ui-theme-tokens
     (list :bg bg :fg ink :panel panel :track panel2 :border line :muted muted
           :accent accent :accent-fg "#ffffff" :accent-soft accent-soft
           :success ok
           :success-bg ok-soft
           :success-border (etaf-md--mix-color bg ok 0.35)
           :warning warn
           :warning-bg warn-soft
           :warning-border (etaf-md--mix-color bg warn 0.35)
           :danger danger
           :danger-bg danger-soft
           :danger-border (etaf-md--mix-color bg danger 0.35)
           :important important
           :important-bg important-soft
           :important-border (etaf-md--mix-color bg important 0.35)
           :info accent :info-bg accent-soft :info-border line))))

(provide 'etaf-md-theme)
;;; etaf-md-theme.el ends here
