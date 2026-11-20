;;; etaf-org-preview-theme.el --- Palettes for etaf-org-preview -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Palettes of the previewer.  A palette is a plain alist of semantic color
;; keys; the views read every color through the environment, so a palette
;; change never leaves a half-updated document.  The `auto' appearance derives
;; its palette from the active frame's own faces, so the preview matches the
;; user's theme instead of painting a page of its own.
;;
;; Org adds a handful of semantic keys to the document palette: keyword
;; states, tags, dates, planning and the property surfaces.  They come from the
;; same theme tokens, so the shared ETAF UI components used inside the preview
;; follow the document colors.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defconst etaf-org-preview-themes
  '((dark . ((:bg . "#191a1c")
             (:ink . "#e6edf3")
             (:muted . "#9198a1")
             (:faint . "#6e7681")
             (:accent . "#4493f8")
             (:accent-soft . "#152c4d")
             (:link . "#9fb6c9")
             (:border . "#303338")
             (:panel . "#202225")
             (:panel2 . "#25272b")
             (:heading . "#8ec5ef")
             (:heading-rule . "#303338")
             (:rule . "#303338")
             (:quote-bar . "#43464b")
             (:quote-bg . "#1c1e21")
             (:table-header . "#202225")
             (:table-border . "#4b5763")
             (:table-stripe . "#1c1e21")
             (:ok . "#3fb950")
             (:ok-soft . "#12261e")
             (:warn . "#d29922")
             (:warn-soft . "#272115")
             (:danger . "#f85149")
             (:danger-soft . "#2a1518")
             (:info . "#4493f8")
             (:info-soft . "#152c4d")
             (:tag-bg . "#262a2e")
             (:todo . "#d29922")
             (:todo-soft . "#272115")
             (:progress . "#4493f8")
             (:progress-soft . "#152c4d")
             (:done . "#3fb950")
             (:done-soft . "#12261e")
             (:hold . "#9198a1")
             (:hold-soft . "#232527")
             (:urgent . "#f85149")
             (:urgent-soft . "#2a1518")
             (:date . "#9fb6c9")))
    (light . ((:bg . "#ffffff")
              (:ink . "#1f2328")
              (:muted . "#59636e")
              (:faint . "#818b98")
              (:accent . "#0969da")
              (:accent-soft . "#ddf4ff")
              (:link . "#3b6470")
              (:border . "#d1d9e0")
              (:panel . "#f6f8fa")
              (:panel2 . "#eef1f4")
              (:heading . "#1b5a7a")
              (:heading-rule . "#d1d9e0")
              (:rule . "#d1d9e0")
              (:quote-bar . "#d1d9e0")
              (:quote-bg . "#f9fbfd")
              (:table-header . "#f0f3f6")
              (:table-border . "#b8c4d0")
              (:table-stripe . "#fbfcfd")
              (:ok . "#1a7f37")
              (:ok-soft . "#dafbe1")
              (:warn . "#9a6700")
              (:warn-soft . "#fff8c5")
              (:danger . "#d1242f")
              (:danger-soft . "#ffebe9")
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
              (:date . "#3b6470")))
    (sepia . ((:bg . "#f5ecd9")
              (:ink . "#3b3024")
              (:muted . "#7a6a53")
              (:faint . "#9a8a72")
              (:accent . "#b3541e")
              (:accent-soft . "#efddc4")
              (:link . "#6b4a2f")
              (:border . "#d8c9ab")
              (:panel . "#efe3cc")
              (:panel2 . "#e9dcc2")
              (:heading . "#6b4423")
              (:heading-rule . "#d8c9ab")
              (:rule . "#d8c9ab")
              (:quote-bar . "#c9b694")
              (:quote-bg . "#f0e6d2")
              (:table-header . "#eadcc0")
              (:table-border . "#bfa982")
              (:table-stripe . "#f1e8d6")
              (:ok . "#3f6212")
              (:ok-soft . "#e2ecd0")
              (:warn . "#92400e")
              (:warn-soft . "#f7e6c4")
              (:danger . "#9f1239")
              (:danger-soft . "#f5d6cf")
              (:info . "#8a4b16")
              (:info-soft . "#efddc4")
              (:tag-bg . "#e9dcc2")
              (:todo . "#92400e")
              (:todo-soft . "#f7e6c4")
              (:progress . "#8a4b16")
              (:progress-soft . "#efddc4")
              (:done . "#3f6212")
              (:done-soft . "#e2ecd0")
              (:hold . "#7a6a53")
              (:hold-soft . "#e9dcc2")
              (:urgent . "#9f1239")
              (:urgent-soft . "#f5d6cf")
              (:date . "#6b4a2f"))))
  "Color palettes of the org previewer.")

(defconst etaf-org-preview--surface-modes
  '((light . "亮") (auto . "随") (dark . "暗") (sepia . "纸"))
  "Appearance modes the preview offers its host, in display order.")

(defun etaf-org-preview--face-color (face attribute fallback &optional frame)
  "Return FACE's ATTRIBUTE color, or FALLBACK when it is unspecified.
FRAME selects the frame to ask; nil asks the selected frame, which is right
for a headless session that has no window of its own."
  (let ((value (ignore-errors (face-attribute face attribute frame t))))
    (if (and (stringp value) (not (equal value "unspecified")))
        value
      fallback)))

(defun etaf-org-preview--mix-color (base overlay weight)
  "Return BASE mixed toward OVERLAY by WEIGHT (0 to 1) as #rrggbb."
  (let ((base-rgb (ignore-errors (color-values base)))
        (overlay-rgb (ignore-errors (color-values overlay))))
    (if (and base-rgb overlay-rgb)
        (let ((mixed (cl-loop for base-value in (cl-subseq base-rgb 0 3)
                              for overlay-value in (cl-subseq overlay-rgb 0 3)
                              collect (ash (round (+ (* base-value (- 1 weight))
                                                     (* overlay-value weight)))
                                           -8))))
          (apply #'format "#%02x%02x%02x" mixed))
      base)))

(defun etaf-org-preview--luminance (color)
  "Return the relative luminance of COLOR, or nil when it does not resolve."
  (when-let* ((values (ignore-errors (color-values color))))
    (cl-destructuring-bind (red green blue) values
      (+ (* 0.2126 (/ red 65535.0))
         (* 0.7152 (/ green 65535.0))
         (* 0.0722 (/ blue 65535.0))))))

(defconst etaf-org-preview--heading-contrast 1.12
  "Smallest contrast ratio that keeps a heading color apart from the body ink.")

(defun etaf-org-preview--heading-color (face-color ink accent background)
  "Return the heading color for FACE-COLOR over INK, ACCENT and BACKGROUND."
  (let ((face-luminance (etaf-org-preview--luminance face-color))
        (ink-luminance (etaf-org-preview--luminance ink)))
    (if (and face-luminance ink-luminance
             (>= (/ (+ (max face-luminance ink-luminance) 0.05)
                    (+ (min face-luminance ink-luminance) 0.05))
                 etaf-org-preview--heading-contrast))
        face-color
      (etaf-org-preview--mix-color accent background 0.35))))

(defun etaf-org-preview--palette-from-faces (&optional frame)
  "Return a palette derived from FRAME's own faces.
Every surface is a blend of the frame's background toward its foreground or a
semantic accent.  Reading `etaf-appearance' ties the derivation to the theme
switch Emacs reports, so a mounted preview re-derives its colors."
  (let* ((_appearance (etaf-appearance))
         (background (etaf-org-preview--face-color 'default :background "#ffffff" frame))
         (foreground (etaf-org-preview--face-color 'default :foreground "#1f2328" frame))
         (shadow (etaf-org-preview--face-color
                  'shadow :foreground
                  (etaf-org-preview--mix-color background foreground 0.55)
                  frame))
         (link (or (etaf-org-preview--face-color 'link :foreground nil frame)
                   (etaf-org-preview--face-color 'button :foreground nil frame)
                   foreground))
         (link-tone (etaf-org-preview--mix-color link foreground 0.28))
         (heading (etaf-org-preview--heading-color
                   (etaf-org-preview--face-color 'outline-1 :foreground foreground frame)
                   foreground link background))
         (ok (etaf-org-preview--face-color 'success :foreground "#1a7f37" frame))
         (warn (etaf-org-preview--face-color 'warning :foreground "#9a6700" frame))
         (danger (etaf-org-preview--face-color 'error :foreground "#d1242f" frame)))
    (list (cons :bg background)
          (cons :ink foreground)
          (cons :muted shadow)
          (cons :faint (etaf-org-preview--mix-color shadow background 0.4))
          (cons :accent link)
          (cons :accent-soft (etaf-org-preview--mix-color background link 0.18))
          (cons :link link-tone)
          (cons :border (etaf-org-preview--mix-color background foreground 0.18))
          (cons :panel (etaf-org-preview--mix-color background foreground 0.06))
          (cons :panel2 (etaf-org-preview--mix-color background foreground 0.10))
          (cons :heading heading)
          (cons :heading-rule (etaf-org-preview--mix-color background foreground 0.18))
          (cons :rule (etaf-org-preview--mix-color background foreground 0.18))
          (cons :quote-bar (etaf-org-preview--mix-color background foreground 0.24))
          (cons :quote-bg (etaf-org-preview--mix-color background foreground 0.03))
          (cons :table-header (etaf-org-preview--mix-color background foreground 0.07))
          (cons :table-border (etaf-org-preview--mix-color background foreground 0.32))
          (cons :table-stripe (etaf-org-preview--mix-color background foreground 0.03))
          (cons :ok ok)
          (cons :ok-soft (etaf-org-preview--mix-color background ok 0.14))
          (cons :warn warn)
          (cons :warn-soft (etaf-org-preview--mix-color background warn 0.14))
          (cons :danger danger)
          (cons :danger-soft (etaf-org-preview--mix-color background danger 0.14))
          (cons :info link)
          (cons :info-soft (etaf-org-preview--mix-color background link 0.14))
          (cons :tag-bg (etaf-org-preview--mix-color background foreground 0.08))
          (cons :todo warn)
          (cons :todo-soft (etaf-org-preview--mix-color background warn 0.14))
          (cons :progress link)
          (cons :progress-soft (etaf-org-preview--mix-color background link 0.14))
          (cons :done ok)
          (cons :done-soft (etaf-org-preview--mix-color background ok 0.14))
          (cons :hold shadow)
          (cons :hold-soft (etaf-org-preview--mix-color background foreground 0.06))
          (cons :urgent danger)
          (cons :urgent-soft (etaf-org-preview--mix-color background danger 0.14))
          (cons :date link-tone))))

(defun etaf-org-preview-color (key palette)
  "Return PALETTE's color for semantic KEY.
Signal `etaf-org-preview-error' when either is unknown; the previewer's
public error type lives in the model, so a missing color is reported as a
programming error here."
  (or (cdr (assq key palette))
      (error "Unknown org preview color: %S" key)))

(defun etaf-org-preview--base-pixels ()
  "Return the frame's default font size in CSS reference pixels."
  (let ((height (face-attribute 'default :height nil t)))
    (if (numberp height)
        (max 8 (round (/ (* height 4.0) 30.0)))
      16.0)))

(defun etaf-org-preview-theme-tokens (palette)
  "Return the ETAF UI token plist for PALETTE.
The application provides this plist through `etaf-theme-provide', so shared
ETAF UI Components follow the previewer's colors."
  (let ((get (lambda (key) (cdr (assq key palette)))))
    (etaf-ui-theme-tokens
     (list :bg (funcall get :bg)
           :fg (funcall get :ink)
           :panel (funcall get :panel)
           :track (funcall get :panel2)
           :border (funcall get :border)
           :muted (funcall get :muted)
           :accent (funcall get :accent)
           :accent-fg "#ffffff"
           :accent-soft (funcall get :accent-soft)
           :success (funcall get :ok)
           :success-bg (funcall get :ok-soft)
           :success-border (etaf-org-preview--mix-color
                            (funcall get :ok) (funcall get :bg) 0.4)
           :warning (funcall get :warn)
           :warning-bg (funcall get :warn-soft)
           :warning-border (etaf-org-preview--mix-color
                            (funcall get :warn) (funcall get :bg) 0.4)
           :danger (funcall get :danger)
           :danger-bg (funcall get :danger-soft)
           :danger-border (etaf-org-preview--mix-color
                           (funcall get :danger) (funcall get :bg) 0.4)
           :info (funcall get :info)
           :info-bg (funcall get :info-soft)
           :info-border (funcall get :border)))))

(provide 'etaf-org-preview-theme)
;;; etaf-org-preview-theme.el ends here
