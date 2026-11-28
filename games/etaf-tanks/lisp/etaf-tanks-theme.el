;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-theme.el --- Interface palettes around the battlefield
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)
(require 'etaf-ui)

(defconst etaf-tanks--light-theme
  (etaf-ui-host-theme-tokens
   :mode 'light :curated t :bg "#F4F5F1" :fg "#293A3A" :surface-1 "#FFFFFF"
   :border "#DCE3D9" :track "#DCE5D9" :ink-2 "#7B8982" :ink-3 "#9EAEA2"
   :accent "#347C68" :accent-fg "#FFFFFF" :accent-soft "#DEEAE2"
   :ok "#37794C" :warn "#8B6D2B" :danger "#A85246" :info "#3D6E60"
   :overrides '(:ui-disabled-bg "#E8ECE5" :ui-button-secondary-fg "#365D50" :ui-button-ghost-fg "#546D61"))
  "Daylight interface palette around the light battlefield.")

(defconst etaf-tanks--dark-theme
  (etaf-ui-host-theme-tokens
   :mode 'dark :curated t :bg "#191a1c" :fg "#E0E9E8" :surface-1 "#202225"
   :border "#303338" :track "#303338" :ink-2 "#8B9DA4" :ink-3 "#607880"
   :accent "#81CDB6" :accent-fg "#17382C" :accent-soft "#324C4B"
   :ok "#AED7B8" :warn "#E4CB8E" :danger "#EDB0A6" :info "#A9CED4"
   :overrides '(:ui-button-secondary-fg "#BDDED3" :ui-button-ghost-fg "#B1C5C8"))
  "Night interface palette around the dark battlefield.")

(defun etaf-tanks--color (token)
  "Read reactive TOKEN from this instance's scoped theme."
  (etaf-theme-token token (plist-get etaf-tanks--light-theme token)))

(provide 'etaf-tanks-theme)
;;; etaf-tanks-theme.el ends here
