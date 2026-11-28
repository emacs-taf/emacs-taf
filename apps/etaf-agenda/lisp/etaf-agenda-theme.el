;;; etaf-agenda-theme.el --- Theme-derived palette and tokens of etaf-agenda -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-agenda-error "ETAF Agenda error")
(defvar etaf-agenda--palette-cache nil "Cached (HOST-PALETTE . AGENDA-PALETTE) pair.")

(defun etaf-agenda-palette ()
  "Return the cached semantic palette for the active theme and frame."
  (let ((p (etaf-ui-host-theme-palette :mode 'auto :aliases t)))
    (if (eq p (car-safe etaf-agenda--palette-cache)) (cdr etaf-agenda--palette-cache)
      (let* ((bg (plist-get p :surface-0)) (ink (plist-get p :ink-1))
             (ok (plist-get p :ok)) (dark-p (plist-get p :dark-p))
             (out (append (list :bar-track (etaf-ui-color-mix bg ink 0.16)
                                :heat0 (etaf-ui-color-mix bg ink (if dark-p 0.18 0.19))
                                :heat1 (etaf-ui-color-mix bg ok (if dark-p 0.36 0.30))
                                :heat2 (etaf-ui-color-mix bg ok (if dark-p 0.66 0.60)) :heat3 ok) p)))
        (setq etaf-agenda--palette-cache (cons p out)) out))))

(defun etaf-agenda-color (role)
  "Return the colour string for semantic ROLE (keyword or symbol)."
  (let ((key (if (keywordp role) role (intern (concat ":" (symbol-name role))))))
    (or (plist-get (etaf-agenda-palette) key)
        (signal 'etaf-agenda-error (list (format "Unknown agenda colour role: %S" role))))))

(defun etaf-agenda-area-color (index)
  "Return a harmonious semantic colour for area INDEX."
  (etaf-agenda-color (nth (mod (max 0 index) 5) '(:info :accent :ok :warning :danger))))

(defun etaf-agenda-theme-defaults ()
  "Return the complete `etaf-ui' theme token plist for the current theme."
  (let ((p (etaf-ui-host-theme-palette :mode 'auto)))
    (etaf-ui-host-theme-tokens :palette p
     :overrides (list :ui-button-padding '((lh 0) (ch 2)) :ui-input-padding '((lh 0) (ch 1))
                      :ui-input-bg (plist-get p :surface-0) :ui-input-fg (plist-get p :ink-1)
                      :ui-input-border (plist-get p :border) :ui-input-placeholder (plist-get p :ink-3)
                      :ui-input-radius '(px 0) :ui-hover-bg (plist-get p :hover) :ui-selected-bg (plist-get p :select)
                      :ui-selected-fg (plist-get p :ink-1) :ui-accent-soft (plist-get p :accent-soft)
                      :ui-success (plist-get p :ok) :ui-success-soft (plist-get p :ok-soft)
                      :ui-warning (plist-get p :warn) :ui-warning-soft (plist-get p :warn-soft)
                      :ui-danger (plist-get p :danger) :ui-danger-soft (plist-get p :danger-soft)))))

(defun etaf-agenda-theme ()
  "Return a reactive computed holding `etaf-ui' theme tokens."
  (etaf-ui-host-theme-ref :name 'etaf-agenda-theme-tokens :transform (lambda (_p _t) (etaf-agenda-theme-defaults))))

(provide 'etaf-agenda-theme)
;;; etaf-agenda-theme.el ends here
