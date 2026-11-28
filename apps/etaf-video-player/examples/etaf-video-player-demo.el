;;; etaf-video-player-demo.el --- Runnable demo for etaf-video-player -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The built-in test pattern needs no file:
;;
;;   emacs -Q -L ../.. -L . -l examples/etaf-video-player-demo.el \
;;         -f etaf-video-player-demo-open
;;
;; Starting from this repository root instead, use `-L ../etaf -L ../ebox
;; -L ../ecss -L ..`.  Press SPC to pause, n to step, +/- to change the rate,
;; [/] for volume, a for sound, 1-4 to change the grid, d to replay and q to
;; close.

;;; Code:

(require 'etaf-video-player)

(defun etaf-video-player-demo-open ()
  "Open the built-in video player demo."
  (interactive)
  (etaf-video-player-demo))

(provide 'etaf-video-player-demo)
;;; etaf-video-player-demo.el ends here
