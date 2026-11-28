;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-theme.el --- Interface palettes around the battlefield
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)
(defconst etaf-tanks--light-theme
  '(:ui-bg "#F4F5F1" :ui-fg "#293A3A" :ui-muted-fg "#7B8982"
    :ui-panel-bg "#FFFFFF" :ui-panel-fg "#293A3A" :ui-panel-border "#DCE3D9"
    :ui-border "#DCE3D9" :ui-accent "#347C68" :ui-accent-fg "#FFFFFF"
    :ui-button-primary-bg "#347C68" :ui-button-primary-fg "#FFFFFF"
    :ui-button-secondary-bg "#DEEAE2" :ui-button-secondary-fg "#365D50"
    :ui-button-ghost-fg "#546D61" :ui-disabled-bg "#E8ECE5" :ui-disabled-fg "#9EAEA2"
    :ui-disabled-border "#DCE3D9" :ui-divider-bg "#DCE3D9"
    :ui-info-bg "#E2ECE8" :ui-info-fg "#3D6E60" :ui-info-border "#CADCD4"
    :ui-success-bg "#E3EFE5" :ui-success-fg "#37794C" :ui-success-border "#C7DFCB"
    :ui-warning-bg "#F6EBD0" :ui-warning-fg "#8B6D2B" :ui-warning-border "#E7D7AF"
    :ui-danger-bg "#F6E4DF" :ui-danger-fg "#A85246" :ui-danger-border "#E4C7C0"
    :ui-progress-track "#DCE5D9")
  "Daylight interface palette around the light battlefield.")

(defconst etaf-tanks--dark-theme
  '(:ui-bg "#191a1c" :ui-fg "#E0E9E8" :ui-muted-fg "#8B9DA4"
    :ui-panel-bg "#202225" :ui-panel-fg "#E0E9E8" :ui-panel-border "#303338"
    :ui-border "#303338" :ui-accent "#81CDB6" :ui-accent-fg "#17382C"
    :ui-button-primary-bg "#81CDB6" :ui-button-primary-fg "#17382C"
    :ui-button-secondary-bg "#324C4B" :ui-button-secondary-fg "#BDDED3"
    :ui-button-ghost-fg "#B1C5C8" :ui-disabled-bg "#202225" :ui-disabled-fg "#607880"
    :ui-disabled-border "#303338" :ui-divider-bg "#303338"
    :ui-info-bg "#29434B" :ui-info-fg "#A9CED4" :ui-info-border "#3E5E66"
    :ui-success-bg "#294335" :ui-success-fg "#AED7B8" :ui-success-border "#42664E"
    :ui-warning-bg "#423A2D" :ui-warning-fg "#E4CB8E" :ui-warning-border "#655639"
    :ui-danger-bg "#47343A" :ui-danger-fg "#EDB0A6" :ui-danger-border "#715049"
    :ui-progress-track "#303338")
  "Night interface palette around the dark battlefield.")

(defun etaf-tanks--color (token)
  "Read reactive TOKEN from this instance's scoped theme."
  (etaf-theme-token token (plist-get etaf-tanks--light-theme token)))
(provide 'etaf-tanks-theme)
;;; etaf-tanks-theme.el ends here
