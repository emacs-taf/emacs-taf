;;; etaf-org-theme.el --- Palettes and color metrics for etaf-org -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Palettes of the Org document engine, harmonized with `etaf-md-theme'.
;; A palette is a plain alist of semantic color keys; views read every color
;; through the environment, so a palette change never leaves a half-updated
;; document.  The `auto' appearance derives its palette from the active
;; frame's own faces (`default', `shadow', `link', `button',
;; `font-lock-function-name-face', `outline-1', `font-lock-keyword-face', and
;; semantic status faces) with the same WCAG heading contrast guard as
;; `etaf-md', so headings and links keep real color even in themes whose
;; `link' face is unspecified (such as `material').
;;
;; All RGB, hex, luminance and WCAG contrast math runs directly on hex strings
;; and X11 color names rather than querying a terminal frame, so batch and GUI
;; sessions compute identical surfaces and contrasts.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defconst etaf-org-themes
  '((dark . ((:bg . "#191a1c")
             (:ink . "#e6edf3")
             (:muted . "#9198a1")
             (:faint . "#6e7681")
             (:accent . "#4493f8")
             (:accent-soft . "#152c4d")
             (:link . "#4493f8")
             (:border . "#303338")
             (:panel . "#212328")
             (:sunken . "#121316")
             (:panel2 . "#282b31")
             (:heading . "#e6edf3")
             (:heading-rule . "#303338")
             (:rule . "#303338")
             (:quote-bar . "#43464b")
             (:quote-bg . "#1d1f23")
             (:table-header . "#25282e")
             (:table-border . "#3d424a")
             (:table-stripe . "#1b1d20")
             (:ok . "#3fb950")
             (:ok-soft . "#12261e")
             (:warn . "#d29922")
             (:warn-soft . "#272115")
             (:danger . "#f85149")
             (:danger-soft . "#2a1518")
             (:important . "#a371f7")
             (:important-soft . "#221a38")
             (:info . "#4493f8")
             (:info-soft . "#152c4d")
             (:tag-bg . "#282b31")
             (:todo . "#d29922")
             (:todo-soft . "#272115")
             (:progress . "#4493f8")
             (:progress-soft . "#152c4d")
             (:done . "#3fb950")
             (:done-soft . "#12261e")
             (:hold . "#9198a1")
             (:hold-soft . "#25282e")
             (:urgent . "#f85149")
             (:urgent-soft . "#2a1518")
             (:date . "#79b8ff")))
    (light . ((:bg . "#ffffff")
              (:ink . "#1f2328")
              (:muted . "#59636e")
              (:faint . "#818b98")
              (:accent . "#0969da")
              (:accent-soft . "#ddf4ff")
              (:link . "#0969da")
              (:border . "#d1d9e0")
              (:panel . "#f6f8fa")
              (:sunken . "#eaeef2")
              (:panel2 . "#e6ebf1")
              (:heading . "#1f2328")
              (:heading-rule . "#d1d9e0")
              (:rule . "#d1d9e0")
              (:quote-bar . "#d1d9e0")
              (:quote-bg . "#f3f6fa")
              (:table-header . "#edf1f5")
              (:table-border . "#c5cfd9")
              (:table-stripe . "#f9fbfd")
              (:ok . "#1a7f37")
              (:ok-soft . "#dafbe1")
              (:warn . "#9a6700")
              (:warn-soft . "#fff8c5")
              (:danger . "#d1242f")
              (:danger-soft . "#ffebe9")
              (:important . "#8250df")
              (:important-soft . "#fbefff")
              (:info . "#0969da")
              (:info-soft . "#ddf4ff")
              (:tag-bg . "#eef1f4")
              (:todo . "#9a6700")
              (:todo-soft . "#fff8c5")
              (:progress . "#0969da")
              (:progress-soft . "#ddf4ff")
              (:done . "#1a7f37")
              (:done-soft . "#dafbe1")
              (:hold . "#59636e")
              (:hold-soft . "#eef1f4")
              (:urgent . "#d1242f")
              (:urgent-soft . "#ffebe9")
              (:date . "#2b6cb0")))
    (sepia . ((:bg . "#f5ecd9")
              (:ink . "#3b3024")
              (:muted . "#7a6a53")
              (:faint . "#9a8a72")
              (:accent . "#b3541e")
              (:accent-soft . "#efddc4")
              (:link . "#b3541e")
              (:border . "#d8c9ab")
              (:panel . "#fbf5e8")
              (:sunken . "#e6d8bc")
              (:panel2 . "#e9dcc2")
              (:heading . "#3b3024")
              (:heading-rule . "#d8c9ab")
              (:rule . "#d8c9ab")
              (:quote-bar . "#c9b694")
              (:quote-bg . "#efe4cd")
              (:table-header . "#eadbc0")
              (:table-border . "#c9b694")
              (:table-stripe . "#f2e9d6")
              (:ok . "#3f6212")
              (:ok-soft . "#e2ecd0")
              (:warn . "#92400e")
              (:warn-soft . "#f7e6c4")
              (:danger . "#9f1239")
              (:danger-soft . "#f5d6cf")
              (:important . "#6d28d9")
              (:important-soft . "#e9dcf5")
              (:info . "#b3541e")
              (:info-soft . "#efddc4")
              (:tag-bg . "#e9dcc2")
              (:todo . "#92400e")
              (:todo-soft . "#f7e6c4")
              (:progress . "#b3541e")
              (:progress-soft . "#efddc4")
              (:done . "#3f6212")
              (:done-soft . "#e2ecd0")
              (:hold . "#7a6a53")
              (:hold-soft . "#e9dcc2")
              (:urgent . "#9f1239")
              (:urgent-soft . "#f5d6cf")
              (:date . "#8c4a20"))))
  "Color palettes of `etaf-org', harmonized with `etaf-md'.")

(defconst etaf-org--surface-modes
  '((light . "亮") (auto . "随") (dark . "暗") (sepia . "纸"))
  "Appearance modes the view offers its host, in display order.")

(defcustom etaf-org-theme 'auto
  "Initial palette of `etaf-org-create'.
`auto' derives the document colors from the active frame's own faces and
paints no page background.  `dark', `light' and `sepia' select a fixed
palette, including its page background."
  :type '(choice (const :tag "Follow the Emacs theme" auto)
                 (const :tag "Dark page" dark)
                 (const :tag "Light page" light)
                 (const :tag "Sepia page" sepia))
  :group 'etaf-org)

(defun etaf-org--face-color (face attribute fallback &optional frame)
  "Return FACE's ATTRIBUTE color, or FALLBACK when it is unspecified.
FRAME selects the frame to query; nil asks the selected frame."
  (let ((value (ignore-errors (face-attribute face attribute frame t))))
    (if (and (stringp value)
             (not (equal value "unspecified"))
             (not (string-prefix-p "unspecified-" value)))
        value
      fallback)))

(defun etaf-org--color-rgb (color)
  "Return COLOR's red, green and blue as 16-bit values, or nil.
Hex strings and X11 names resolve directly without querying a terminal palette."
  (cond
   ((and (stringp color)
         (string-match
          "\\`#\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\'"
          color))
    (list (* 257 (string-to-number (match-string 1 color) 16))
          (* 257 (string-to-number (match-string 2 color) 16))
          (* 257 (string-to-number (match-string 3 color) 16))))
   ((and (stringp color)
         (string-match
          "\\`#\\([[:xdigit:]]\\)\\([[:xdigit:]]\\)\\([[:xdigit:]]\\)\\'"
          color))
    (list (* 4369 (string-to-number (match-string 1 color) 16))
          (* 4369 (string-to-number (match-string 2 color) 16))
          (* 4369 (string-to-number (match-string 3 color) 16))))
   ((and (stringp color) (assoc-string color color-name-rgb-alist t))
    (cdr (assoc-string color color-name-rgb-alist t)))
   (t (ignore-errors (color-values color)))))

(defun etaf-org--mix-color (base overlay weight)
  "Return BASE mixed toward OVERLAY by WEIGHT (0 to 1) as #rrggbb."
  (let ((base-rgb (etaf-org--color-rgb base))
        (overlay-rgb (etaf-org--color-rgb overlay)))
    (if (and base-rgb overlay-rgb)
        (let ((mixed (cl-loop for base-value in (cl-subseq base-rgb 0 3)
                              for overlay-value in (cl-subseq overlay-rgb 0 3)
                              collect (ash (round (+ (* base-value (- 1 weight))
                                                     (* overlay-value weight)))
                                           -8))))
          (apply #'format "#%02x%02x%02x" mixed))
      base)))

(defun etaf-org--hex-color (color)
  "Return COLOR as #rrggbb, or COLOR unchanged when it does not resolve."
  (let ((values (etaf-org--color-rgb color)))
    (if values
        (apply #'format "#%02x%02x%02x"
               (mapcar (lambda (value) (ash value -8)) (cl-subseq values 0 3)))
      color)))

(defun etaf-org--luminance-channel (value)
  "Decode 0-65535 sRGB channel VALUE into linear light."
  (let ((scaled (/ value 65535.0)))
    (if (<= scaled 0.03928)
        (/ scaled 12.92)
      (expt (/ (+ scaled 0.055) 1.055) 2.4))))

(defun etaf-org--luminance (color)
  "Return the relative luminance of COLOR, or nil when it does not resolve."
  (when-let* ((values (etaf-org--color-rgb color)))
    (cl-destructuring-bind (red green blue) values
      (+ (* 0.2126 (etaf-org--luminance-channel red))
         (* 0.7152 (etaf-org--luminance-channel green))
         (* 0.0722 (etaf-org--luminance-channel blue))))))

(defun etaf-org--contrast-ratio (first second)
  "Return the WCAG contrast ratio between FIRST and SECOND, or nil."
  (when-let* ((first-lum (etaf-org--luminance first))
              (second-lum (etaf-org--luminance second)))
    (/ (+ (max first-lum second-lum) 0.05)
       (+ (min first-lum second-lum) 0.05))))

(defconst etaf-org--heading-contrast 1.35
  "Smallest contrast ratio that keeps a heading color apart from body ink.
Matches `etaf-md--heading-contrast': themes whose `outline-1' sits almost
on top of the body text derive their heading hue from the accent instead.")

(defun etaf-org--heading-color (face-color ink accent background)
  "Return the heading color for FACE-COLOR over INK, ACCENT and BACKGROUND."
  (let ((ratio (etaf-org--contrast-ratio face-color ink)))
    (if (and ratio (>= ratio etaf-org--heading-contrast))
        face-color
      (etaf-org--mix-color accent background 0.35))))

(defun etaf-org--palette-from-faces (&optional frame)
  "Return a palette derived from FRAME's own faces, matching `etaf-md'.
Reading `etaf-appearance' ties the derivation to Emacs theme switches."
  (let* ((appearance (etaf-appearance))
         (dark (eq appearance 'dark))
         (background (etaf-org--hex-color
                      (etaf-org--face-color 'default :background
                                            (if dark "#191a1c" "#ffffff") frame)))
         (foreground (etaf-org--hex-color
                      (etaf-org--face-color 'default :foreground
                                            (if dark "#e6edf3" "#1f2328") frame)))
         (shadow (etaf-org--hex-color
                  (etaf-org--face-color
                   'shadow :foreground
                   (etaf-org--mix-color background foreground 0.55)
                   frame)))
         (link (etaf-org--hex-color
                (or (etaf-org--face-color 'link :foreground nil frame)
                    (etaf-org--face-color 'button :foreground nil frame)
                    (etaf-org--face-color 'font-lock-function-name-face
                                          :foreground nil frame)
                    (if dark "#4493f8" "#0969da"))))
         (heading (etaf-org--hex-color
                   (etaf-org--heading-color
                    (etaf-org--face-color 'outline-1 :foreground foreground frame)
                    foreground link background)))
         (ok (etaf-org--hex-color
              (etaf-org--face-color 'success :foreground
                                    (if dark "#3fb950" "#1a7f37") frame)))
         (warn (etaf-org--hex-color
                (etaf-org--face-color 'warning :foreground
                                      (if dark "#d29922" "#9a6700") frame)))
         (danger (etaf-org--hex-color
                  (etaf-org--face-color 'error :foreground
                                        (if dark "#f85149" "#d1242f") frame)))
         (important (etaf-org--hex-color
                     (etaf-org--face-color
                      'font-lock-keyword-face :foreground
                      (if dark "#a371f7" "#8250df") frame)))
         (sunken (if (< (or (etaf-org--luminance background) 1.0) 0.5)
                     (etaf-org--mix-color background "#000000" 0.28)
                   (etaf-org--mix-color background foreground 0.09))))
    (list (cons :bg background)
          (cons :ink foreground)
          (cons :muted shadow)
          (cons :faint (etaf-org--mix-color shadow background 0.4))
          (cons :accent link)
          (cons :accent-soft (etaf-org--mix-color background link 0.18))
          (cons :link link)
          (cons :border (etaf-org--mix-color background foreground 0.18))
          (cons :panel (etaf-org--mix-color background foreground 0.06))
          (cons :sunken sunken)
          (cons :panel2 (etaf-org--mix-color background foreground 0.11))
          (cons :heading heading)
          (cons :heading-rule (etaf-org--mix-color background foreground 0.18))
          (cons :rule (etaf-org--mix-color background foreground 0.18))
          (cons :quote-bar (etaf-org--mix-color background foreground 0.22))
          (cons :quote-bg (etaf-org--mix-color background foreground 0.045))
          (cons :table-header (etaf-org--mix-color background foreground 0.08))
          (cons :table-border (etaf-org--mix-color background foreground 0.22))
          (cons :table-stripe (etaf-org--mix-color background foreground 0.022))
          (cons :ok ok)
          (cons :ok-soft (etaf-org--mix-color background ok 0.14))
          (cons :warn warn)
          (cons :warn-soft (etaf-org--mix-color background warn 0.14))
          (cons :danger danger)
          (cons :danger-soft (etaf-org--mix-color background danger 0.14))
          (cons :important important)
          (cons :important-soft (etaf-org--mix-color background important 0.14))
          (cons :info link)
          (cons :info-soft (etaf-org--mix-color background link 0.16))
          (cons :tag-bg (etaf-org--mix-color background foreground 0.09))
          (cons :todo warn)
          (cons :todo-soft (etaf-org--mix-color background warn 0.14))
          (cons :progress link)
          (cons :progress-soft (etaf-org--mix-color background link 0.16))
          (cons :done ok)
          (cons :done-soft (etaf-org--mix-color background ok 0.14))
          (cons :hold shadow)
          (cons :hold-soft (etaf-org--mix-color background foreground 0.07))
          (cons :urgent danger)
          (cons :urgent-soft (etaf-org--mix-color background danger 0.14))
          (cons :date (etaf-org--mix-color link foreground 0.22)))))

(defun etaf-org-color (key palette)
  "Return PALETTE's color for semantic KEY."
  (or (cdr (assq key palette))
      (plist-get palette key)
      (error "Unknown etaf-org color: %S" key)))

(defun etaf-org--cell-metrics ()
  "Return (CELL-WIDTH . CELL-HEIGHT) in pixels from `etaf-display-metrics'.
Reactive during render so text scaling repaints pictures cleanly."
  (let* ((metrics (ignore-errors (etaf-display-metrics)))
         (cw (and (listp metrics) (plist-get metrics :cell-width)))
         (ch (and (listp metrics) (plist-get metrics :cell-height))))
    (cons (max 1 (if (and (numberp cw) (> cw 1)) cw 8))
          (max 1 (if (and (numberp ch) (> ch 1)) ch 16)))))

(defun etaf-org--base-pixels ()
  "Return the pixel size the page draws its own text at."
  (cdr (etaf-org--cell-metrics)))

(defun etaf-org-theme-tokens (theme-or-palette)
  "Return the ETAF UI token plist for THEME-OR-PALETTE, aligned with `etaf-md'.
THEME-OR-PALETTE may be `dark', `light', `sepia', `auto', or a palette alist.
Every color token in the returned plist is normalized to a 6-digit `#RRGGBB'
hex string."
  (let* ((palette (cond
                   ((eq theme-or-palette 'auto)
                    (etaf-org--palette-from-faces))
                   ((symbolp theme-or-palette)
                    (or (cdr (assq theme-or-palette etaf-org-themes))
                        (signal 'etaf-org-error
                                (list (format "Unknown org theme: %S" theme-or-palette)))))
                   ((listp theme-or-palette) theme-or-palette)
                   (t (etaf-org--palette-from-faces))))
         (get (lambda (key)
                (etaf-org--hex-color
                 (or (cdr (assq key palette))
                     (plist-get palette key)
                     (cdr (assq key (cdr (assq 'light etaf-org-themes))))))))
         (bg (funcall get :bg))
         (ink (funcall get :ink))
         (panel (funcall get :panel))
         (panel2 (funcall get :panel2))
         (line (funcall get :border))
         (muted (funcall get :muted))
         (accent (funcall get :accent))
         (accent-soft (funcall get :accent-soft))
         (ok (funcall get :ok))
         (ok-soft (funcall get :ok-soft))
         (warn (funcall get :warn))
         (warn-soft (funcall get :warn-soft))
         (danger (funcall get :danger))
         (danger-soft (funcall get :danger-soft))
         (important (funcall get :important))
         (important-soft (funcall get :important-soft))
         (tokens
          (etaf-ui-theme-tokens
           (list :bg bg
                 :fg ink
                 :panel panel
                 :track panel2
                 :border line
                 :muted muted
                 :accent accent
                 :accent-fg "#ffffff"
                 :accent-soft accent-soft
                 :success ok
                 :success-bg ok-soft
                 :success-border (etaf-org--mix-color bg ok 0.35)
                 :warning warn
                 :warning-bg warn-soft
                 :warning-border (etaf-org--mix-color bg warn 0.35)
                 :danger danger
                 :danger-bg danger-soft
                 :danger-border (etaf-org--mix-color bg danger 0.35)
                 :important important
                 :important-bg important-soft
                 :important-border (etaf-org--mix-color bg important 0.35)
                 :info accent
                 :info-bg accent-soft
                 :info-border line))))
    (let ((out nil) (rest tokens))
      (while rest
        (let ((k (pop rest)) (v (pop rest)))
          (push k out)
          (push (if (and (stringp v) (etaf-org--color-rgb v))
                    (etaf-org--hex-color v)
                  v)
                out)))
      (nreverse out))))

(provide 'etaf-org-theme)
;;; etaf-org-theme.el ends here
