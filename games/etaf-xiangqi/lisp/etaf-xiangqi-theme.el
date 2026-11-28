;;; -*- lexical-binding: t; -*-
;;; etaf-xiangqi-theme.el --- Paper and slate palettes for a xiangqi table
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)
(require 'etaf-ui)

(defconst etaf-xiangqi--light-theme
  (etaf-ui-host-theme-tokens
   :mode 'light :curated t :bg "#F5F5F2" :fg "#29333B" :surface-1 "#FFFFFF"
   :border "#DCE2DE" :track "#E1E7E2" :ink-2 "#77817F" :ink-3 "#A0ABA4"
   :accent "#A93A32" :accent-fg "#FFFFFF" :accent-soft "#E5EBE6"
   :ok "#35764B" :warn "#8B6E2E" :danger "#A63B34" :info "#386658"
   :overrides '(:ui-disabled-bg "#EBEEEA" :ui-button-secondary-fg "#345448" :ui-button-ghost-fg "#53665D"
                :xq-paper "#F0E2C6" :xq-line "#A98956" :xq-edge "#C6AC7D" :xq-river "#967E54"
                :xq-piece "#FFF8E7" :xq-shadow "#655139" :xq-red "#AD3830" :xq-black "#30424A" :xq-accent "#278574"))
  "Light paper table, engraved lines and ivory pieces.")

(defconst etaf-xiangqi--dark-theme
  (etaf-ui-host-theme-tokens
   :mode 'dark :curated t :bg "#191a1c" :fg "#E6ECEB" :surface-1 "#202225"
   :border "#303338" :track "#303338" :ink-2 "#8E9DA2" :ink-3 "#62767B"
   :accent "#DD8272" :accent-fg "#241715" :accent-soft "#2C4143"
   :ok "#A1D5B6" :warn "#DEC58A" :danger "#EEA2AD" :info "#ACCED7"
   :overrides '(:ui-button-secondary-fg "#BAD7CE" :ui-button-ghost-fg "#BAC9CA"
                :xq-paper "#24343E" :xq-line "#6C8288" :xq-edge "#506B73" :xq-river "#90A5AA"
                :xq-piece "#EAE1CE" :xq-shadow "#061117" :xq-red "#AC382F" :xq-black "#2D414B" :xq-accent "#79CDB8"))
  "Slate night board with warm ivory pieces and a jade selection ring.")

(defun etaf-xiangqi--color (token)
  "Read reactive TOKEN from this instance's scoped theme."
  (etaf-theme-token token (plist-get etaf-xiangqi--light-theme token)))

(provide 'etaf-xiangqi-theme)
;;; etaf-xiangqi-theme.el ends here
