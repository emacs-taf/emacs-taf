;;; etaf-balatro-theme.el --- Host-following and curated theme tokens for ETAF Balatro -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defvar etaf-balatro--theme-epoch (etaf-ui-host-theme-ref :name 'balatro-theme-epoch)
  "Reactive host-theme ref invalidated on Emacs theme switches.")

(defun etaf-balatro--appearance-label (appearance)
  "Return concise button label for APPEARANCE (`auto', `dark' or `light')."
  (pcase appearance ('dark "深色 · t") ('light "浅色 · t") (_ "跟随主题 · t")))

(defun etaf-balatro--tokens (appearance)
  "Return the ETAF theme token plist for APPEARANCE (`auto', `dark' or `light')."
  (let* ((p (pcase (if (memq appearance '(auto dark light)) appearance 'auto)
              ('dark (etaf-ui-host-theme-palette
                      :mode 'dark :curated t :bg "#0F141D" :fg "#F1F5F9" :surface-1 "#151C28"
                      :surface-2 "#1B2433" :surface-3 "#1E283A" :sunken "#121823" :border "#243044"
                      :border-subtle "#1E2838" :border-strong "#374966" :hover "#222E42" :track "#1E2838"
                      :accent "#2563EB" :accent-fg "#FFFFFF"))
              ('light (etaf-ui-host-theme-palette
                       :mode 'light :curated t :bg "#F3F5F9" :fg "#0F172A" :surface-1 "#FFFFFF"
                       :surface-2 "#F8FAFC" :surface-3 "#F1F5F9" :sunken "#F4F6FA" :border "#DDE3EC"
                       :border-subtle "#E5EAF2" :border-strong "#CBD5E1" :hover "#E9EFF7" :track "#E2E8F0"
                       :accent "#2563EB" :accent-fg "#FFFFFF"))
              (_ (etaf-ui-host-theme-palette :mode 'auto))))
         (dark-p (plist-get p :dark-p)) (s1 (plist-get p :surface-1)) (s2 (plist-get p :surface-2))
         (leg (lambda (d l &optional r)
                (etaf-ui-color-legible (etaf-ui-color-legible (if dark-p d l) s1 (or r 4.5)) s2 (or r 4.5))))
         (trios (cl-loop for (fk bk rk d l) in
                         '((:balatro-gold :balatro-gold-bg :balatro-gold-border "#F5B841" "#B45309")
                           (:balatro-chips-fg :balatro-chips-bg :balatro-chips-border "#60A5FA" "#1D4ED8")
                           (:balatro-mult-fg :balatro-mult-bg :balatro-mult-border "#FB7185" "#BE123C")
                           (:balatro-purple :balatro-purple-bg :balatro-purple-border "#C084FC" "#7E22CE")
                           (:balatro-green :balatro-green-bg :balatro-green-border "#4ADE80" "#15803D")
                           (:balatro-cyan :balatro-cyan-bg :balatro-cyan-border "#38BDF8" "#0E7490")
                           (:balatro-boss-fg :balatro-boss-bg :balatro-boss-border "#F87171" "#B91C1C"))
                         for seed = (if dark-p d l)
                         for soft = (etaf-ui-color-mix s1 seed (if dark-p 0.19 0.11))
                         for bdr = (etaf-ui-color-mix s1 seed (if dark-p 0.44 0.40))
                         for fg = (etaf-ui-color-legible (etaf-ui-color-legible seed s1 4.5) soft 4.5)
                         append (list fk fg bk soft rk bdr)))
         (chips (plist-get trios :balatro-chips-fg)))
    (etaf-ui-host-theme-tokens
     :palette p
     :overrides
     (append trios
             (list :ui-mode (plist-get p :mode) :ui-hover-bg (plist-get p :hover)
                   :ui-button-padding '((lh 0) (ch 2)) :ui-button-primary-bg "#2563EB"
                   :ui-button-primary-fg "#FFFFFF" :ui-button-primary-hover-bg "#1D4ED8"
                   :ui-button-secondary-bg s2 :ui-button-secondary-fg (if dark-p "#CBD5E1" "#334155")
                   :ui-button-secondary-hover-bg (plist-get p :hover) :ui-button-ghost-fg (plist-get p :ink-2)
                   :ui-button-ghost-hover-bg (plist-get p :hover) :ui-disabled-bg (plist-get p :sunken)
                   :ui-disabled-fg (plist-get p :ink-3) :balatro-dark dark-p :balatro-bg (plist-get p :surface-0)
                   :balatro-header s1 :balatro-surface s1 :balatro-card s2 :balatro-card-alt (plist-get p :surface-3)
                   :balatro-empty-bg (plist-get p :sunken) :balatro-border (plist-get p :border)
                   :balatro-border-soft (plist-get p :border-subtle) :balatro-border-strong (plist-get p :border-strong)
                   :balatro-fg (plist-get p :ink-1) :balatro-muted (plist-get p :ink-2) :balatro-dim (plist-get p :ink-3)
                   :balatro-hover (plist-get p :hover) :balatro-track (plist-get p :track) :balatro-bonus chips
                   :balatro-coach-bg (etaf-ui-color-mix s1 chips (if dark-p 0.10 0.06))
                   :balatro-coach-border (etaf-ui-color-mix s1 chips (if dark-p 0.28 0.22))
                   :balatro-glass (funcall leg "#F472B6" "#BE185D") :balatro-steel (funcall leg "#CBD5E1" "#334155")
                   :balatro-foil (funcall leg "#38BDF8" "#0369A1") :balatro-heart (funcall leg "#F87171" "#DC2626" 4.2)
                   :balatro-diamond (funcall leg "#FB923C" "#C2410C" 4.2) :balatro-spade (funcall leg "#E2E8F0" "#1E293B")
                   :balatro-club (funcall leg "#93C5FD" "#334155" 4.2) :ui-playing-card-bg (if dark-p "#FFFDF6" "#FAF8F2")
                   :ui-playing-card-hover-bg (if dark-p "#F6EED8" "#F1EDE0")
                   :ui-playing-card-border (if dark-p "#475569" "#B6C2D2") :ui-playing-card-selected-bg "#FEF3C7"
                   :ui-playing-card-selected-border (if dark-p "#F59E0B" "#D97706")
                   :ui-playing-card-red "#DC2626" :ui-playing-card-black "#0F172A")))))

(provide 'etaf-balatro-theme)
;;; etaf-balatro-theme.el ends here
