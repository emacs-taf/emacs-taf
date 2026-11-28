;;; etaf-island-theme.el --- Calm restrained theme tokens for ETAF Island -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-island-error "Invalid ETAF Island operation")
(defvar etaf-island--theme-epoch (etaf-ui-host-theme-ref :name 'island-theme-epoch)
  "Reactive host-theme ref invalidated on Emacs theme switches.")

(defun etaf-island--tokens (mode)
  "Return the ETAF Theme token plist for MODE (`auto', `dark' or `light')."
  (let* ((p (pcase (if (memq mode '(auto dark light)) mode 'auto)
              ('dark (etaf-ui-host-theme-palette :mode 'dark :curated t :bg "#263238" :fg "#E6EEF2" :surface-1 "#2D3B42"
                      :surface-2 "#324149" :surface-3 "#3B4D57" :select "#374953" :accent "#64B5F6" :ok "#81C784" :warn "#FFB74D" :danger "#F36C60"))
              ('light (etaf-ui-host-theme-palette :mode 'light :curated t :bg "#F1F5F9" :fg "#1E293B" :surface-1 "#FFFFFF"
                       :surface-2 "#F8FAFC" :surface-3 "#EEF2F7" :select "#F1F5F9" :accent "#2563EB" :ok "#15803D" :warn "#B45309" :danger "#DC2626"))
              (_ (etaf-ui-host-theme-palette :mode 'auto))))
         (dark-p (plist-get p :dark-p)) (canvas (plist-get p :surface-0)) (surface (plist-get p :surface-1))
         (accent (plist-get p :accent)) (afill (if dark-p (etaf-ui-color-mix accent canvas 0.54) accent)))
    (etaf-ui-host-theme-tokens :palette p
     :overrides (list :ui-mode (plist-get p :mode) :island-bg canvas :island-surface surface
                      :island-card (plist-get p :surface-2) :island-card-selected (plist-get p :select)
                      :island-ctrl (plist-get p :surface-3) :island-border (plist-get p :border)
                      :island-border-soft (plist-get p :border-subtle) :island-fg (plist-get p :ink-1)
                      :island-muted (plist-get p :ink-2) :island-dim (plist-get p :ink-3) :island-accent accent
                      :island-accent-fill afill :island-accent-fg (if (>= (etaf-ui-color-contrast "#F8FAFC" afill) 4.5) "#F8FAFC" "#0F172A")
                      :island-accent-soft (plist-get p :accent-soft)
                      :island-spectrum (etaf-ui-color-legible (if dark-p "#7FB5B5" "#0D9488") surface 3.8)
                      :island-focus (plist-get p :ok) :island-focus-soft (plist-get p :ok-soft)
                      :island-warn (plist-get p :warn) :island-warn-soft (plist-get p :warn-soft)
                      :island-danger (plist-get p :danger) :island-danger-soft (plist-get p :danger-soft)
                      :island-track (plist-get p :track) :island-hover (plist-get p :hover)))))

(defun etaf-island--variant-colors (tokens variant)
  "Return (FG BG LABEL) for notification VARIANT in TOKENS."
  (pcase variant
    ('success (list (plist-get tokens :island-focus) (plist-get tokens :island-focus-soft) "完成"))
    ('warning (list (plist-get tokens :island-warn) (plist-get tokens :island-warn-soft) "提醒"))
    ('danger  (list (plist-get tokens :island-danger) (plist-get tokens :island-danger-soft) "告警"))
    (_        (list (plist-get tokens :island-accent) (plist-get tokens :island-accent-soft) "通知"))))

(provide 'etaf-island-theme)
;;; etaf-island-theme.el ends here
