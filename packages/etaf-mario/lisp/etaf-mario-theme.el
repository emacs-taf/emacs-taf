;;; -*- lexical-binding: t; -*-
;;; etaf-mario-theme.el --- Interface palettes around the game canvas

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The canvas brings its own artwork colours from `etaf-mario-art'; these
;; tokens style the HUD, dialogs and footer around it, and follow the frame's
;; background mode unless the player pins one.

;;; Code:

(require 'etaf)

(defconst etaf-mario--light-theme
  '(:ui-bg "#F4F5F1" :ui-fg "#25313A" :ui-muted-fg "#77858E"
    :ui-panel-bg "#FFFFFF" :ui-panel-fg "#25313A" :ui-panel-border "#DDE3E6"
    :ui-border "#DDE3E6" :ui-accent "#C0392B" :ui-accent-fg "#FFFFFF"
    :ui-accent-soft-bg "#F7E5E1"
    :ui-button-primary-bg "#C0392B" :ui-button-primary-fg "#FFFFFF"
    :ui-button-secondary-bg "#E7ECE9" :ui-button-secondary-fg "#2F4A3E"
    :ui-button-ghost-fg "#51636C" :ui-disabled-bg "#EDF0F1" :ui-disabled-fg "#9AA7AE"
    :ui-disabled-border "#DDE3E6" :ui-divider-bg "#DDE3E6"
    :ui-info-bg "#E7EFF4" :ui-info-fg "#335D74" :ui-info-border "#CCDCE6"
    :ui-success-bg "#E6F1E7" :ui-success-fg "#33744A" :ui-success-border "#C9DFCC"
    :ui-warning-bg "#F7EFD8" :ui-warning-fg "#8B6E2E" :ui-warning-border "#E7D9B4"
    :ui-danger-bg "#F9E7E4" :ui-danger-fg "#A63B34" :ui-danger-border "#EACBC6"
    :ui-progress-track "#E1E7E2"
    :mario-sky "#9BD3F0":mario-gold "#C98A12" :mario-coin "#C98A12"
    :mario-hud "#25313A" :mario-hud-muted "#77858E" :mario-life "#B4453A"
    :mario-footer-bg "#ECEFEA")
  "Daylight interface palette around the canvas.")

(defconst etaf-mario--dark-theme
  '(:ui-bg "#191A1C" :ui-fg "#E4EAEC" :ui-muted-fg "#8C9AA3"
    :ui-panel-bg "#202225" :ui-panel-fg "#E4EAEC" :ui-panel-border "#303338"
    :ui-border "#303338" :ui-accent "#E4796C" :ui-accent-fg "#241513"
    :ui-accent-soft-bg "#3A2725"
    :ui-button-primary-bg "#E4796C" :ui-button-primary-fg "#241513"
    :ui-button-secondary-bg "#2E3B38" :ui-button-secondary-fg "#BFD8CE"
    :ui-button-ghost-fg "#B0C0C6" :ui-disabled-bg "#202225" :ui-disabled-fg "#62767E"
    :ui-disabled-border "#303338" :ui-divider-bg "#303338"
    :ui-info-bg "#273840" :ui-info-fg "#A9CBD7" :ui-info-border "#3B545F"
    :ui-success-bg "#273B31" :ui-success-fg "#A5D3B6" :ui-success-border "#3C5A47"
    :ui-warning-bg "#3E382C" :ui-warning-fg "#DEC58A" :ui-warning-border "#5C5138"
    :ui-danger-bg "#422C32" :ui-danger-fg "#EEA2AD" :ui-danger-border "#67404A"
    :ui-progress-track "#303338"
    :mario-sky "#111A33" :mario-gold "#E0A21A" :mario-coin "#E0A21A"
    :mario-hud "#E4EAEC" :mario-hud-muted "#8C9AA3" :mario-life "#E4796C"
    :mario-footer-bg "#141618")
  "Night interface palette around the canvas.")

(defun etaf-mario--color (token)
  "Read reactive TOKEN from this instance's scoped theme."
  (etaf-theme-token token (plist-get etaf-mario--light-theme token)))

(provide 'etaf-mario-theme)
;;; etaf-mario-theme.el ends here
