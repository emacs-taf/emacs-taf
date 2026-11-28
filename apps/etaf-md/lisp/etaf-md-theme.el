;;; etaf-md-theme.el --- Palettes for etaf-md -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defun etaf-md--hex-color (color)
  "Return COLOR as #rrggbb, or COLOR unchanged when it does not resolve."
  (cond ((and (stringp color) (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color)) color)
        ((when-let* ((e (and (stringp color) (assoc-string color color-name-rgb-alist t))))
           (apply #'format "#%02x%02x%02x" (mapcar (lambda (v) (ash v -8)) (cl-subseq (cdr e) 0 3)))))
        (t color)))

(defun etaf-md--mix-color (base overlay weight)
  "Return BASE mixed toward OVERLAY by WEIGHT (0 to 1) as #rrggbb."
  (etaf-ui-color-mix (etaf-md--hex-color base) (etaf-md--hex-color overlay) weight))

(defun etaf-md--alist (p heading)
  "Convert host-theme palette P and HEADING into an `etaf-md' palette alist."
  (let ((bg (plist-get p :surface-0)) (ink (plist-get p :ink-1)) (bdr (plist-get p :border)))
    (append (list (cons :heading heading) (cons :heading-rule bdr)
                  (cons :quote-bar (etaf-ui-color-mix bg ink 0.22)) (cons :quote-bg (etaf-ui-color-mix bg ink 0.045))
                  (cons :table-header (etaf-ui-color-mix bg ink 0.08)) (cons :table-stripe (etaf-ui-color-mix bg ink 0.022)))
            (cl-loop for (k v) on p by #'cddr collect (cons k v)))))

(defconst etaf-md-themes
  (mapcar (lambda (s) (cons (car s) (etaf-md--alist (apply #'etaf-ui-host-theme-palette :curated t :aliases t (cdr s))
                                                    (plist-get (cdr s) :fg))))
          '((dark  :mode dark  :bg "#191a1c" :fg "#e6edf3" :ink-2 "#9198a1" :ink-3 "#6e7681" :accent "#4493f8"
                   :accent-soft "#152c4d" :border "#303338" :surface-1 "#212328" :sunken "#121316" :surface-2 "#282b31")
            (light :mode light :bg "#ffffff" :fg "#1f2328" :ink-2 "#59636e" :ink-3 "#818b98" :accent "#0969da"
                   :accent-soft "#ddf4ff" :border "#d1d9e0" :surface-1 "#f6f8fa" :sunken "#eaeef2" :surface-2 "#e6ebf1")
            (sepia :mode light :bg "#f5ecd9" :fg "#3b3024" :ink-2 "#7a6a53" :ink-3 "#9a8a72" :accent "#b3541e"
                   :accent-soft "#efddc4" :border "#d8c9ab" :surface-1 "#fbf5e8" :sunken "#e6d8bc" :surface-2 "#e9dcc2"
                   :ok "#3f6212" :warn "#92400e" :danger "#9f1239" :important "#6d28d9")))
  "Color palettes of the markdown previewer.")

(defconst etaf-md--surface-modes '((light . "亮") (auto . "随") (dark . "暗") (sepia . "纸")) "Host switch modes.")
(defcustom etaf-md-theme 'auto "Initial palette of `etaf-md-create'."
  :type '(choice (const :tag "Follow the Emacs theme" auto) (const :tag "Dark page" dark)
                 (const :tag "Light page" light) (const :tag "Sepia page" sepia)) :group 'etaf-md)

(defun etaf-md-auto-theme () "Return the palette matching the host appearance." (etaf-appearance))

(defun etaf-md--palette-from-faces (&optional frame)
  "Return a palette derived from FRAME's own faces via `etaf-ui-host-theme'."
  (etaf-appearance)
  (let* ((raw-bg (let ((v (ignore-errors (face-attribute 'default :background frame t))))
                   (and (stringp v) (not (string-prefix-p "unspecified" v)) v)))
         (p (apply #'etaf-ui-host-theme-palette :mode 'auto :frame frame :calm-dark nil :aliases t
                   (unless raw-bg (list :bg "#ffffff"))))
         (raw-h (let ((v (ignore-errors (face-attribute 'outline-1 :foreground frame t))))
                  (and (stringp v) (not (string-prefix-p "unspecified" v)) v))))
    (etaf-md--alist p (if (and raw-h (>= (etaf-ui-color-contrast raw-h (plist-get p :ink-1)) 1.35))
                          raw-h (etaf-md--mix-color (plist-get p :accent) (plist-get p :surface-0) 0.35)))))

(defun etaf-md-color (key theme)
  "Return THEME's color for semantic KEY, signaling `etaf-md-error' if unknown."
  (let ((pal (or (cdr (assq theme etaf-md-themes))
                 (signal 'etaf-md-error (list (format "Unknown markdown preview theme: %S" theme))))))
    (or (cdr (assq key pal)) (signal 'etaf-md-error (list (format "Unknown markdown preview color: %S" key))))))

(declare-function etaf-display-metrics "etaf-runtime" (&optional runtime))
(declare-function etaf-image-kitty-available-p "etaf-runtime" (&optional frame))

(defun etaf-md--cell-metrics ()
  "Return (CHAR-WIDTH . LINE-HEIGHT) in pixels of the page's own text."
  (let* ((m (ignore-errors (etaf-display-metrics)))
         (cw (or (and m (plist-get m :char-width)) (ignore-errors (frame-char-width))))
         (ch (or (and m (plist-get m :line-height)) (ignore-errors (frame-char-height)))))
    (cond ((and (numberp cw) (> cw 1) (numberp ch) (> ch 1)) (cons cw ch))
          ((let* ((c (and (fboundp 'etaf-image-kitty-available-p) (ignore-errors (etaf-image-kitty-available-p))))
                  (kw (and c (plist-get c :cell-width))) (kh (and c (plist-get c :cell-height))))
             (and (numberp kw) (> kw 0) (numberp kh) (> kh 0) (cons kw kh))))
          (t (cons 8 16)))))

(defun etaf-md--base-pixels () "Return pixel size of page text." (if (display-graphic-p) (cdr (etaf-md--cell-metrics)) 16))

(defun etaf-md-theme-tokens (theme &optional palette)
  "Return the ETAF UI token plist for palette THEME or face PALETTE."
  (etaf-ui-host-theme-tokens
   :palette (or palette (cdr (assq theme etaf-md-themes))
                (signal 'etaf-md-error (list (format "Unknown markdown preview theme: %S" theme))))))

(provide 'etaf-md-theme)
;;; etaf-md-theme.el ends here
