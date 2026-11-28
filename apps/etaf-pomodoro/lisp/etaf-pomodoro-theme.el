;;; etaf-pomodoro-theme.el --- Palettes of the Pomodoro surfaces -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Compact light and dark timer palettes backed by `etaf-ui-host-theme'.

;;; Code:

(require 'etaf-ui)

(defconst etaf-pomodoro--light-tokens
  (etaf-ui-host-theme-tokens
   :mode 'light :curated t :bg "#FAFAFA" :fg "#383A42" :surface-1 "#F2F2F2"
   :ink-2 "#86878B" :border "#D4D4D5" :accent "#2F6FE4" :accent-fg "#FFFFFF"
   :accent-soft "#D6E2FA"
   :overrides '(:ui-mode light :ui-disabled-bg "#D4D4D5" :ui-button-ghost-fg "#383A42"))
  "Light tokens of the timer surfaces.")

(defconst etaf-pomodoro--dark-tokens
  (etaf-ui-host-theme-tokens
   :mode 'dark :curated t :bg "#16191D" :fg "#E9F0F4" :surface-1 "#1B2226"
   :ink-2 "#93A3AA" :border "#424344" :accent "#6CB6FF" :accent-fg "#101418"
   :accent-soft "#233A42"
   :overrides '(:ui-mode dark :ui-disabled-bg "#39464C" :ui-button-ghost-fg "#E9F0F4"))
  "Dark tokens of the timer surfaces.")

(defun etaf-pomodoro--tokens (mode)
  "Return the token plist of the timer surfaces for MODE."
  (copy-sequence (if (eq mode 'dark) etaf-pomodoro--dark-tokens etaf-pomodoro--light-tokens)))

(provide 'etaf-pomodoro-theme)
;;; etaf-pomodoro-theme.el ends here
