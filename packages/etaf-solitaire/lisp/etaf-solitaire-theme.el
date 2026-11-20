;;; -*- lexical-binding: t; -*-
;;; etaf-solitaire-theme.el --- Verdant card-table palette

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)
(defconst etaf-solitaire--light-theme
  '(:ui-bg "#F3F5F0" :ui-fg "#293B36" :ui-muted-fg "#73847B"
    :ui-panel-bg "#FFFFFF" :ui-panel-fg "#293B36" :ui-panel-border "#DDE5DC"
    :ui-border "#DDE5DC" :ui-accent "#287763" :ui-accent-fg "#FFFFFF"
    :ui-button-primary-bg "#287763" :ui-button-primary-fg "#FFFFFF"
    :ui-button-secondary-bg "#DFEBE3" :ui-button-secondary-fg "#326B57"
    :ui-button-ghost-fg "#50675B" :ui-disabled-bg "#E9EEE7" :ui-disabled-fg "#A0ADA3"
    :ui-disabled-border "#DDE5DC" :ui-divider-bg "#DDE5DC"
    :ui-info-bg "#E4EDE7" :ui-info-fg "#416B57" :ui-info-border "#CBDCD0"
    :ui-success-bg "#E0EEE2" :ui-success-fg "#38764C" :ui-success-border "#C4DCC9"
    :ui-danger-bg "#F9E8E8" :ui-danger-fg "#AF4050" :ui-danger-border "#E8C8CD"
    :ui-warning-bg "#F7EDCF" :ui-warning-fg "#8B6E2E" :ui-warning-border "#E4D6AC"
    :ui-progress-track "#DFE7DD"
    :ui-playing-card-bg "#FFFFFF" :ui-playing-card-black "#293D46"
    :ui-playing-card-red "#B44257" :ui-playing-card-back-bg "#D2E4DA"
    :ui-playing-card-back-fg "#789C89" :ui-playing-card-empty-bg "#E7EDE3"
    :ui-playing-card-empty-fg "#9BAC9E" :ui-playing-card-selected-bg "#F3DEAA"
    :ui-playing-card-hover-bg "#F6EDD5")
  "Ivory and sage light palette; no frame-global theme changes.")

(defconst etaf-solitaire--dark-theme
  '(:ui-bg "#181C23" :ui-fg "#E8ECF0" :ui-muted-fg "#8F9AA8"
    :ui-panel-bg "#222832" :ui-panel-fg "#E8ECF0" :ui-panel-border "#343D49"
    :ui-border "#343D49" :ui-accent "#83CDB6" :ui-accent-fg "#172D27"
    :ui-button-primary-bg "#83CDB6" :ui-button-primary-fg "#172D27"
    :ui-button-secondary-bg "#303F43" :ui-button-secondary-fg "#C0DED4"
    :ui-button-ghost-fg "#B4C0CC" :ui-disabled-bg "#222832" :ui-disabled-fg "#626E7C"
    :ui-disabled-border "#343D49" :ui-divider-bg "#343D49"
    :ui-info-bg "#283B49" :ui-info-fg "#AFCADD" :ui-info-border "#3D566A"
    :ui-success-bg "#263C34" :ui-success-fg "#A2D4B6" :ui-success-border "#3E5C4C"
    :ui-danger-bg "#452F38" :ui-danger-fg "#EFA1AC" :ui-danger-border "#71404F"
    :ui-warning-bg "#40392D" :ui-warning-fg "#DCC591" :ui-warning-border "#61543B"
    :ui-progress-track "#343D49"
    :ui-playing-card-bg "#E9EDF0" :ui-playing-card-black "#2B3C49"
    :ui-playing-card-red "#AD3F57" :ui-playing-card-back-bg "#354354"
    :ui-playing-card-back-fg "#788FA9" :ui-playing-card-empty-bg "#242D38"
    :ui-playing-card-empty-fg "#61768C" :ui-playing-card-selected-bg "#E5C98D"
    :ui-playing-card-hover-bg "#C9DDD6")
  "Graphite dark palette with restrained jade accents and clear card faces.")

(defun etaf-solitaire--color (token)
  "Read reactive TOKEN from this instance's scoped theme."
  (etaf-theme-token token (plist-get etaf-solitaire--light-theme token)))
(provide 'etaf-solitaire-theme)
;;; etaf-solitaire-theme.el ends here
