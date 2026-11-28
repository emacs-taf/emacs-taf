;;; performance-scenarios.el --- Autonomous screensaver frame cadence -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run through the workspace performance.py driver.  Each sample waits for the
;; next autonomous frame, including timer wait, rendering and retained Host
;; publication.

;;; Code:
(require 'etaf-screensaver)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-screensaver-benchmark--fixture (scene &optional frame)
  "Return a seeded cadence fixture for SCENE with optional FRAME style."
  (let* ((etaf-screensaver-frame-rate 30)
         (buffer (etaf-screensaver-open
                  (list scene :duration 3600 :frame-rate 30 :frame (or frame 'full))
                  4242))
         (ticks 0))
    (list :buffer buffer
          :prepare (lambda () (setq ticks (plist-get (etaf-screensaver-status) :ticks)))
          :invoke #'ignore
          :settled (lambda ()
                     (let ((now (plist-get (etaf-screensaver-status) :ticks)))
                       (and now (> now ticks))))
          :verify (lambda ()
                    (let ((status (etaf-screensaver-status)))
                      (if (and (plist-get status :active)
                               (eq (plist-get status :scene) scene)
                               (> (plist-get status :ticks) ticks))
                          t "The autonomous scene did not publish another frame")))
          :cleanup #'etaf-screensaver-stop)))

(dolist (scene '(matrix snow plasma donut equalizer sand poems clock))
  (let ((scene scene))
    (taf-benchmark-register
     (format "etaf-screensaver.frame.%s" scene)
     :version 3 :modes '(batch gui) :isolation 'series :impact 'local
     :budget-ms 100
     :description (format "Wait for the next autonomous %s frame at a 30 fps cap" scene)
     :setup (lambda (_mode) (etaf-screensaver-benchmark--fixture scene)))))

(taf-benchmark-register
 "etaf-screensaver.frame.poems-card"
 :version 1 :modes '(batch gui) :isolation 'series :impact 'local
 :budget-ms 100
 :description "Autonomous poems frame with card border and caption"
 :setup (lambda (_mode) (etaf-screensaver-benchmark--fixture 'poems 'card)))

(provide 'etaf-screensaver-performance-scenarios)
;;; performance-scenarios.el ends here
