;;; -*- lexical-binding: t; -*-
;;; etaf-mario-art.el --- Colours for the stage's characters

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The stage is ordinary text: characters carry a face and nothing imitates a
;; bitmap.  Each theme is a plist of named colours the renderer asks for by
;; role, so a level changes its palette without touching the drawing code.

;;; Code:

(defconst etaf-mario-art--day
  '(:sky "#9BD3F0" :cloud "#9FB6C2" :hill "#6FA85E" :hill-shade "#4A8C42"
    :grass "#63B44B" :grass-shade "#3E7F31"
    :dirt "#B9793F" :dirt-shade "#94603A"
    :brick "#C4683B" :brick-shade "#8C4423"
    :gold "#F5B722" :gold-dark "#A96A0B"
    :pipe "#3AA64E" :pipe-shade "#1E6C34"
    :red "#E23A2C" :skin "#B8703A" :blue "#2E5FC0" :ink "#2A2A2A"
    :white "#FFFFFF" :lava "#E2542B" :castle "#8E7A6A" :castle-shade "#5E4C3E"
    :goomba "#A65D2E" :goomba-shade "#6E3A1B"
    :shell "#3FA34D" :shell-shade "#2A7237"
    :star "#E8B21C" :one-up "#4FA97E" :muted "#77858E")
  "Daylight colours for the stage's characters.")

(defconst etaf-mario-art--underground
  '(:sky "#111A33" :cloud "#7F93B5" :hill "#4E6E9E" :hill-shade "#2B4568"
    :grass "#4A6FA5" :grass-shade "#35527F"
    :dirt "#5A6E94" :dirt-shade "#3C4B69"
    :brick "#7E90B4" :brick-shade "#55648A"
    :gold "#F2B526" :gold-dark "#B0740D"
    :pipe "#2E9E92" :pipe-shade "#1A6A62"
    :red "#E23A2C" :skin "#B8703A" :blue "#3B68C4" :ink "#2A2A2A"
    :white "#F7F2E7" :lava "#E2542B" :castle "#8C9AB5" :castle-shade "#5A6780"
    :goomba "#8A5EA8" :goomba-shade "#5D3D72"
    :shell "#4FA97E" :shell-shade "#2F7D5E"
    :star "#E8B21C" :one-up "#4FA97E" :muted "#8C9AB5")
  "Underground colours: cool stone and bright marks.")

(defconst etaf-mario-art--castle
  '(:sky "#1B151C" :cloud "#9C8A7A" :hill "#7E6858" :hill-shade "#4E3E36"
    :grass "#8A6A50" :grass-shade "#644838"
    :dirt "#7A6250" :dirt-shade "#543E30"
    :brick "#A08874" :brick-shade "#6E5646"
    :gold "#F2B526" :gold-dark "#B0740D"
    :pipe "#B04630" :pipe-shade "#6E2A1C"
    :red "#E23A2C" :skin "#B8703A" :blue "#2C5CBC" :ink "#2A2A2A"
    :white "#F7F2E7" :lava "#FF5A2B" :castle "#8E7A6A" :castle-shade "#5E4C3E"
    :goomba "#A65D2E" :goomba-shade "#6E3A1B"
    :shell "#3FA34D" :shell-shade "#2A7237"
    :star "#E8B21C" :one-up "#4FA97E" :muted "#B9AC9E")
  "Castle colours: charred brick and warm lava.")

(defconst etaf-mario-art--night
  '(:sky "#1D2740" :cloud "#8FA3B8" :hill "#4E7F62" :hill-shade "#2C513B"
    :grass "#4E7F58" :grass-shade "#3A6144"
    :dirt "#6F5A3E" :dirt-shade "#4E3E2A"
    :brick "#8E6A44" :brick-shade "#63482C"
    :gold "#F2B526" :gold-dark "#B0740D"
    :pipe "#2E8E6E" :pipe-shade "#175E48"
    :red "#E23A2C" :skin "#B8703A" :blue "#3B62B8" :ink "#2A2A2A"
    :white "#F7F2E7" :lava "#E2542B" :castle "#8E8496" :castle-shade "#5E5668"
    :goomba "#A65D2E" :goomba-shade "#6E3A1B"
    :shell "#3FA34D" :shell-shade "#2A7237"
    :star "#E8B21C" :one-up "#4FA97E" :muted "#8C9AA3")
  "Night colours: moonlit grass and deep blue sky.")

(defconst etaf-mario-art--themes
  '((day . etaf-mario-art--day)
    (underground . etaf-mario-art--underground)
    (castle . etaf-mario-art--castle)
    (night . etaf-mario-art--night))
  "Level theme names and their colour plists.")

(defun etaf-mario-art-palette (theme)
  "Return THEME's colour plist, defaulting to daylight."
  (symbol-value (or (cdr (assq theme etaf-mario-art--themes))
                    'etaf-mario-art--day)))

(provide 'etaf-mario-art)
;;; etaf-mario-art.el ends here
