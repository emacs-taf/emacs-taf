;;; -*- lexical-binding: t; -*-
;;; etaf-xiangqi-theme.el --- Paper and slate palettes for a xiangqi table
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)

(defconst etaf-xiangqi--light-theme
  '(:ui-bg "#F5F5F2" :ui-fg "#29333B" :ui-muted-fg "#77817F"
    :ui-panel-bg "#FFFFFF" :ui-panel-fg "#29333B" :ui-panel-border "#DCE2DE"
    :ui-border "#DCE2DE" :ui-accent "#A93A32" :ui-accent-fg "#FFFFFF"
    :ui-button-primary-bg "#A93A32" :ui-button-primary-fg "#FFFFFF"
    :ui-button-secondary-bg "#E5EBE6" :ui-button-secondary-fg "#345448"
    :ui-button-ghost-fg "#53665D" :ui-disabled-bg "#EBEEEA" :ui-disabled-fg "#A0ABA4"
    :ui-disabled-border "#DCE2DE" :ui-divider-bg "#DCE2DE"
    :ui-info-bg "#E6EEEB" :ui-info-fg "#386658" :ui-info-border "#CADAD1"
    :ui-success-bg "#E5F0E7" :ui-success-fg "#35764B" :ui-success-border "#C9DECC"
    :ui-warning-bg "#F7EFD8" :ui-warning-fg "#8B6E2E" :ui-warning-border "#E7D9B4"
    :ui-danger-bg "#F9E7E4" :ui-danger-fg "#A63B34" :ui-danger-border "#EACBC6"
    :ui-progress-track "#E1E7E2"
    :xq-paper "#F0E2C6" :xq-line "#A98956" :xq-edge "#C6AC7D"
    :xq-river "#967E54" :xq-piece "#FFF8E7" :xq-shadow "#655139"
    :xq-red "#AD3830" :xq-black "#30424A" :xq-accent "#278574")
  "Light paper table, engraved lines and ivory pieces.")

(defconst etaf-xiangqi--dark-theme
  '(:ui-bg "#191a1c" :ui-fg "#E6ECEB" :ui-muted-fg "#8E9DA2"
    :ui-panel-bg "#202225" :ui-panel-fg "#E6ECEB" :ui-panel-border "#303338"
    :ui-border "#303338" :ui-accent "#DD8272" :ui-accent-fg "#241715"
    :ui-button-primary-bg "#DD8272" :ui-button-primary-fg "#241715"
    :ui-button-secondary-bg "#2C4143" :ui-button-secondary-fg "#BAD7CE"
    :ui-button-ghost-fg "#BAC9CA" :ui-disabled-bg "#202225" :ui-disabled-fg "#62767B"
    :ui-disabled-border "#303338" :ui-divider-bg "#303338"
    :ui-info-bg "#283B43" :ui-info-fg "#ACCED7" :ui-info-border "#3A5661"
    :ui-success-bg "#263C32" :ui-success-fg "#A1D5B6" :ui-success-border "#3D5B49"
    :ui-warning-bg "#3E382C" :ui-warning-fg "#DEC58A" :ui-warning-border "#5C5138"
    :ui-danger-bg "#422C32" :ui-danger-fg "#EEA2AD" :ui-danger-border "#67404A"
    :ui-progress-track "#303338"
    :xq-paper "#24343E" :xq-line "#6C8288" :xq-edge "#506B73"
    :xq-river "#90A5AA" :xq-piece "#EAE1CE" :xq-shadow "#061117"
    :xq-red "#AC382F" :xq-black "#2D414B" :xq-accent "#79CDB8")
  "Slate night board with warm ivory pieces and a jade selection ring.")

(defun etaf-xiangqi--color (token)
  "Read reactive TOKEN from this instance's scoped theme."
  (etaf-theme-token token (plist-get etaf-xiangqi--light-theme token)))

(provide 'etaf-xiangqi-theme)
;;; etaf-xiangqi-theme.el ends here
