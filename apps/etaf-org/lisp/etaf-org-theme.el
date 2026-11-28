;;; etaf-org-theme.el --- Palettes and color metrics for etaf-org -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defun etaf-org--hex-color (color)
  "Return COLOR as #rrggbb, or COLOR unchanged when it does not resolve."
  (cond ((and (stringp color) (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color)) color)
        ((when-let* ((e (and (stringp color) (assoc-string color color-name-rgb-alist t))))
           (apply #'format "#%02x%02x%02x" (mapcar (lambda (v) (ash v -8)) (cl-subseq (cdr e) 0 3)))))
        (t color)))

(defun etaf-org--mix-color (base overlay weight)
  "Return BASE mixed toward OVERLAY by WEIGHT (0 to 1) as #rrggbb."
  (etaf-ui-color-mix (etaf-org--hex-color base) (etaf-org--hex-color overlay) weight))

(defun etaf-org--contrast-ratio (first second)
  "Return the WCAG contrast ratio between FIRST and SECOND, or nil."
  (let ((r (etaf-ui-color-contrast (etaf-org--hex-color first) (etaf-org--hex-color second)))) (and (> r 0) r)))

(defun etaf-org--alist (p heading &optional date)
  "Convert host-theme palette P, HEADING and DATE into an `etaf-org' alist."
  (let ((bg (plist-get p :surface-0)) (ink (plist-get p :ink-1)) (bdr (plist-get p :border))
        (acc (plist-get p :accent)) (asoft (plist-get p :accent-soft)))
    (append (list (cons :link acc) (cons :heading heading) (cons :heading-rule bdr) (cons :rule bdr)
                  (cons :quote-bar (etaf-ui-color-mix bg ink 0.22)) (cons :quote-bg (etaf-ui-color-mix bg ink 0.045))
                  (cons :table-header (etaf-ui-color-mix bg ink 0.08)) (cons :table-border (etaf-ui-color-mix bg ink 0.22))
                  (cons :table-stripe (etaf-ui-color-mix bg ink 0.022)) (cons :info acc) (cons :info-soft asoft)
                  (cons :tag-bg (plist-get p :surface-2)) (cons :todo (plist-get p :warn))
                  (cons :todo-soft (plist-get p :warn-soft)) (cons :progress acc) (cons :progress-soft asoft)
                  (cons :done (plist-get p :ok)) (cons :done-soft (plist-get p :ok-soft))
                  (cons :hold (plist-get p :ink-2)) (cons :hold-soft (etaf-ui-color-mix bg ink 0.07))
                  (cons :urgent (plist-get p :danger)) (cons :urgent-soft (plist-get p :danger-soft))
                  (cons :date (or date (etaf-ui-color-mix acc ink 0.22))))
            (cl-loop for (k v) on p by #'cddr collect (cons k v)))))

(defconst etaf-org-themes
  (mapcar (lambda (s) (cons (car s) (etaf-org--alist (apply #'etaf-ui-host-theme-palette :curated t :aliases t (cddr s))
                                                     (plist-get (cddr s) :fg) (cadr s))))
          '((dark  "#79b8ff" :mode dark  :bg "#191a1c" :fg "#e6edf3" :ink-2 "#9198a1" :ink-3 "#6e7681" :accent "#4493f8"
                   :accent-soft "#152c4d" :border "#303338" :surface-1 "#212328" :sunken "#121316" :surface-2 "#282b31"
                   :important "#a371f7")
            (light "#2b6cb0" :mode light :bg "#ffffff" :fg "#1f2328" :ink-2 "#59636e" :ink-3 "#818b98" :accent "#0969da"
                   :accent-soft "#ddf4ff" :border "#d1d9e0" :surface-1 "#f6f8fa" :sunken "#eaeef2" :surface-2 "#e6ebf1")
            (sepia "#8c4a20" :mode light :bg "#f5ecd9" :fg "#3b3024" :ink-2 "#7a6a53" :ink-3 "#9a8a72" :accent "#b3541e"
                   :accent-soft "#efddc4" :border "#d8c9ab" :surface-1 "#fbf5e8" :sunken "#e6d8bc" :surface-2 "#e9dcc2"
                   :ok "#3f6212" :warn "#92400e" :danger "#9f1239" :important "#6d28d9")))
  "Color palettes of `etaf-org', harmonized with `etaf-md'.")

(defconst etaf-org--surface-modes '((light . "亮") (auto . "随") (dark . "暗") (sepia . "纸")) "Host switch modes.")
(defcustom etaf-org-theme 'auto "Initial palette of `etaf-org-create'."
  :type '(choice (const :tag "Follow the Emacs theme" auto) (const :tag "Dark page" dark)
                 (const :tag "Light page" light) (const :tag "Sepia page" sepia)) :group 'etaf-org)

(defun etaf-org--palette-from-faces (&optional frame)
  "Return a palette derived from FRAME's own faces via `etaf-ui-host-theme'."
  (etaf-appearance)
  (let* ((p (etaf-ui-host-theme-palette :mode 'auto :frame frame :calm-dark nil :aliases t))
         (raw-h (let ((v (ignore-errors (face-attribute 'outline-1 :foreground frame t))))
                  (and (stringp v) (not (string-prefix-p "unspecified" v)) v))))
    (etaf-org--alist p (if (and raw-h (>= (etaf-ui-color-contrast raw-h (plist-get p :ink-1)) 1.35))
                           (etaf-org--hex-color raw-h)
                         (etaf-org--mix-color (plist-get p :accent) (plist-get p :surface-0) 0.35)))))

(defun etaf-org-color (key palette)
  "Return PALETTE's color for semantic KEY."
  (or (cdr (assq key palette)) (plist-get palette key) (error "Unknown etaf-org color: %S" key)))

(defun etaf-org--cell-metrics ()
  "Return (CELL-WIDTH . CELL-HEIGHT) in pixels from `etaf-display-metrics'."
  (let* ((m (ignore-errors (etaf-display-metrics)))
         (cw (and (listp m) (plist-get m :cell-width))) (ch (and (listp m) (plist-get m :cell-height))))
    (cons (max 1 (if (and (numberp cw) (> cw 1)) cw 8)) (max 1 (if (and (numberp ch) (> ch 1)) ch 16)))))

(defun etaf-org--base-pixels () "Return pixel size of page text." (cdr (etaf-org--cell-metrics)))

(defun etaf-org-theme-tokens (theme-or-palette)
  "Return the ETAF UI token plist for THEME-OR-PALETTE."
  (etaf-ui-host-theme-tokens
   :palette (cond ((eq theme-or-palette 'auto) (etaf-org--palette-from-faces))
                  ((symbolp theme-or-palette)
                   (or (cdr (assq theme-or-palette etaf-org-themes))
                       (signal 'etaf-org-error (list (format "Unknown org theme: %S" theme-or-palette)))))
                  ((listp theme-or-palette) theme-or-palette)
                  (t (etaf-org--palette-from-faces)))))

(provide 'etaf-org-theme)
;;; etaf-org-theme.el ends here
