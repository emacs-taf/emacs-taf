;;; maillist-theme.el --- Theme of maillist -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:

(require 'etaf)
(require 'etaf-ui)

(defgroup maillist nil "Mail archive client built with ETAF." :group 'applications)
(define-error 'maillist-error "Mail client error")

(defvar maillist--palette-cache nil "Cached ((HOST-PALETTE . SHADOW) . PALETTE).")

(defun maillist-palette ()
  "Return the cached palette derived from the current Emacs theme."
  (let* ((p (etaf-ui-host-theme-palette :mode 'auto :aliases t))
         (shadow (let ((v (and (facep 'shadow) (face-attribute 'shadow :foreground nil t))))
                   (and (stringp v) (not (string-prefix-p "unspecified" v)) v)))
         (key (cons p shadow)))
    (if (equal key (car-safe maillist--palette-cache))
        (cdr maillist--palette-cache)
      (let* ((bg (plist-get p :surface-0)) (ink (plist-get p :ink-1))
             (accent (plist-get p :accent))
             (out (append (list :muted (or shadow (plist-get p :ink-2))
                                :dim (etaf-ui-color-mix bg (plist-get p :ink-2) 0.55)
                                :surface-soft (plist-get p :surface-2)
                                :quote-bg (etaf-ui-color-mix bg ink 0.035)
                                :subject (etaf-ui-color-mix bg accent 0.62))
                          p)))
        (setq maillist--palette-cache (cons key out))
        out))))

(defun maillist-color (key)
  "Return the palette color named KEY, signaling `maillist-error' if unknown."
  (or (plist-get (maillist-palette) key)
      (signal 'maillist-error (list (format "Unknown color: %S" key)))))

(defun maillist-theme-defaults ()
  "Return the ETAF UI token plist for the current theme."
  (let* ((p (maillist-palette)) (bg (plist-get p :bg)) (ink (plist-get p :ink))
         (line (plist-get p :line)) (s2 (plist-get p :surface-soft)))
    (etaf-ui-host-theme-tokens
     :palette p
     :overrides (list :ui-panel-bg bg :ui-panel-fg ink :ui-panel-border line
                      :ui-divider-bg line :ui-picker-item-bg (plist-get p :select)
                      :ui-picker-item-fg ink :ui-picker-item-muted-fg (plist-get p :muted)
                      :ui-search-bg s2 :ui-search-fg ink :ui-input-bg bg :ui-input-border line
                      :ui-disabled-bg bg :ui-disabled-border line :ui-button-secondary-bg s2
                      :ui-button-ghost-bg bg :ui-success-bg bg :ui-danger-bg bg :ui-warning-bg bg))))

(provide 'maillist-theme)
;;; maillist-theme.el ends here
