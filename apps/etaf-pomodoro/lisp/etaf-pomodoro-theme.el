;;; etaf-pomodoro-theme.el --- Palettes of the Pomodoro surfaces -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The timer keeps one compact palette per appearance.  The application
;; provides the palette of the appearance its host reports, so a panel inside a
;; dark frame can be light and the reverse, and a standalone buffer follows the
;; Emacs theme.  The keys are the subset of the ETAF token vocabulary this
;; application paints with.

;;; Code:

(require 'cl-lib)

(defconst etaf-pomodoro--light-tokens
  '(:ui-mode light
    :ui-bg "#FAFAFA"
    :ui-panel-bg "#F2F2F2"
    :ui-panel-fg "#383A42"
    :ui-muted-fg "#86878B"
    :ui-accent "#2F6FE4"
    :ui-accent-fg "#FFFFFF"
    :ui-accent-soft-bg "#D6E2FA"
    :ui-disabled-bg "#D4D4D5"
    :ui-panel-border "#D4D4D5"
    :ui-button-primary-fg "#FFFFFF"
    :ui-button-primary-bg "#2F6FE4"
    :ui-button-ghost-fg "#383A42")
  "Light tokens of the timer surfaces.")

(defconst etaf-pomodoro--dark-tokens
  '(:ui-mode dark
    :ui-bg "#16191D"
    :ui-panel-bg "#1B2226"
    :ui-panel-fg "#E9F0F4"
    :ui-muted-fg "#93A3AA"
    :ui-accent "#6CB6FF"
    :ui-accent-fg "#101418"
    :ui-accent-soft-bg "#233A42"
    :ui-disabled-bg "#39464C"
    :ui-panel-border "#424344"
    :ui-button-primary-fg "#101418"
    :ui-button-primary-bg "#6CB6FF"
    :ui-button-ghost-fg "#E9F0F4")
  "Dark tokens of the timer surfaces.")

(defun etaf-pomodoro--tokens (mode)
  "Return the token plist of the timer surfaces for MODE.
MODE is `light' or `dark'; anything else falls back to light."
  (copy-sequence (if (eq mode 'dark)
                     etaf-pomodoro--dark-tokens
                   etaf-pomodoro--light-tokens)))

(provide 'etaf-pomodoro-theme)
;;; etaf-pomodoro-theme.el ends here
