;;; maillist-theme.el --- Theme of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The client paints no surface of its own: every color is derived from the
;; active Emacs theme, so the buffer keeps the theme's background, foreground
;; and accent instead of importing a second palette.  `maillist-palette'
;; reads the faces once per render pass; the Views never name a color literal.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'etaf)
(require 'etaf-ui)

(defgroup maillist nil
  "Mail archive client built with ETAF."
  :group 'applications)

(defun maillist--rgb (color fallback)
  "Return COLOR as a normalized rgb list, or FALLBACK's when it is not a color.
An `unspecified' face attribute and a terminal without a real palette both
land here, so the palette never signals over a missing surface color."
  (or (and (stringp color) (color-name-to-rgb color))
      (color-name-to-rgb fallback)))

(defun maillist--blend (first second ratio)
  "Mix colors FIRST and SECOND; RATIO is the share of SECOND (0..1)."
  (let ((a (maillist--rgb first "#000000"))
        (b (maillist--rgb second "#ffffff")))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (x y) (+ (* x (- 1 ratio)) (* y ratio))) a b)
                   (list 2)))))

(defun maillist--face (face attribute &optional fallback)
  "Return FACE's ATTRIBUTE color when the theme sets one, else FALLBACK."
  (let ((value (and (facep face) (face-attribute face attribute nil t))))
    (if (and (stringp value) (color-name-to-rgb value))
        value
      fallback)))

(defun maillist-palette ()
  "Return the palette derived from the current Emacs theme."
  (let* ((bg (or (face-attribute 'default :background) "#000000"))
         (ink (or (face-attribute 'default :foreground) "#ffffff"))
         (muted (or (maillist--face 'shadow :foreground)
                    (maillist--blend bg ink 0.62)))
         (accent (or (maillist--face 'link :foreground)
                     (maillist--face 'font-lock-function-name-face :foreground)
                     (maillist--face 'font-lock-keyword-face :foreground)
                     (maillist--blend bg ink 0.85)))
         (select (or (maillist--face 'hl-line :background)
                     (maillist--blend bg ink 0.07))))
    (let ((ok (or (maillist--face 'success :foreground) "#4fbf67"))
          (danger (or (maillist--face 'error :foreground) "#ef5b5b")))
      (list :bg bg
            :ink ink
            :muted muted
            :dim (maillist--blend bg muted 0.55)
            :line (maillist--blend bg ink 0.14)
            :line-soft (maillist--blend bg ink 0.07)
            :surface (maillist--blend bg ink 0.045)
            :surface-soft (maillist--blend bg ink 0.085)
            :quote-bg (maillist--blend bg ink 0.035)
            :select select
            :accent accent
            :accent-soft (maillist--blend bg accent 0.18)
            ;; The theme's link colour is often neon; dimming it toward the
            ;; surface keeps a whole list of subjects calm to read.
            :subject (maillist--blend bg accent 0.62)
            :ok ok
            :ok-soft (maillist--blend bg ok 0.14)
            :danger danger
            :danger-soft (maillist--blend bg danger 0.14)
            :warning (or (maillist--face 'warning :foreground) "#e8a33d")))))

(defun maillist-color (key)
  "Return the palette color named KEY.
An unknown KEY signals `maillist-error' instead of painting an invisible
surface, because a typo would otherwise be silent."
  (let ((value (plist-get (maillist-palette) key)))
    (unless value
      (signal 'maillist-error (list (format "Unknown color: %S" key))))
    value))

(define-error 'maillist-error "Mail client error")

(defun maillist-theme-defaults ()
  "Return the ETAF UI token plist for the current theme."
  (let* ((palette (maillist-palette))
         (bg (plist-get palette :bg))
         (ink (plist-get palette :ink))
         (muted (plist-get palette :muted))
         (accent (plist-get palette :accent))
         (line (plist-get palette :line))
         (select (plist-get palette :select))
         (surface (plist-get palette :surface))
         (surface-soft (plist-get palette :surface-soft)))
    (append
     (list :ui-panel-bg bg :ui-panel-fg ink :ui-panel-border line
           :ui-divider-bg line
           :ui-picker-item-bg select :ui-picker-item-fg ink
           :ui-picker-item-muted-fg muted
           :ui-search-bg surface-soft :ui-search-fg ink
           :ui-input-bg bg :ui-input-border line
           :ui-disabled-bg bg :ui-disabled-border line
           :ui-button-secondary-bg surface-soft
           :ui-button-ghost-bg bg
           :ui-success-bg bg :ui-danger-fg (plist-get palette :danger)
           :ui-danger-bg bg :ui-warning-fg (plist-get palette :warning)
           :ui-warning-bg bg)
     (etaf-ui-theme-tokens
      (list :bg bg :fg ink :panel surface :track line :border line
            :muted muted :dim muted :accent accent :accent-fg bg
            :accent-soft (plist-get palette :accent-soft)
            :success (plist-get palette :ok) :success-bg bg
            :success-border line
            :warning (plist-get palette :warning) :warning-bg bg
            :warning-border line
            :danger (plist-get palette :danger) :danger-bg bg
            :danger-border line
            :info accent :info-bg bg :info-border line)))))

(provide 'maillist-theme)
;;; maillist-theme.el ends here
