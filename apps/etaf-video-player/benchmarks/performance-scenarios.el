;;; performance-scenarios.el --- Video playback and control latency -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Measured public application operations, run by the workspace performance
;; driver.  TAF_VIDEO_SOURCE selects a local test clip; absent it, use the
;; generated demo.  All playback remains muted during automated measurement.

;;; Code:
(require 'cl-lib)
(require 'etaf-video-player)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-video-player-benchmark--fixture (operation)
  "Create the public player fixture for OPERATION."
  (let* ((source (or (getenv "TAF_VIDEO_SOURCE") '(:demo)))
         (etaf-video-player-audio nil)
         (buffer (etaf-video-player-open source))
         (expected nil)
         (previous 0))
    (unless (eq operation 'frame)
      (with-current-buffer buffer
        (when (plist-get (etaf-video-player-state) :playing)
          (etaf-video-player-toggle-playback))))
    (list
     :buffer buffer
     :environment (lambda () (list :source (format "%s" source) :operation (symbol-name operation)))
     :invoke
     (lambda (index)
       (with-current-buffer buffer
         (pcase operation
           ('frame (setq previous (plist-get (etaf-video-player-state) :presented)))
           ('volume
            (setq expected (if (cl-evenp index) 35 75))
            (etaf-video-player-set-volume expected))
           ('mute
            (setq expected (cl-evenp index))
            (etaf-video-player-set-audio expected)))))
     :settled (lambda () (or (not (eq operation 'frame))
                            (> (with-current-buffer buffer
                                 (plist-get (etaf-video-player-state) :presented))
                               previous)))
     :verify (lambda ()
               (with-current-buffer buffer
                 (let ((state (etaf-video-player-state)))
                   (pcase operation
                     ('frame (if (and (plist-get state :playing)
                                      (> (plist-get state :presented) previous)) t "No new frame"))
                     ('volume (if (= expected (plist-get state :volume)) t "Wrong volume"))
                     ('mute (if (eq expected (plist-get state :audio)) t "Wrong sound state"))))))
     :outcome (lambda ()
                (with-current-buffer buffer
                  (let ((state (etaf-video-player-state)))
                    (list :presented (plist-get state :presented)
                          :dropped (plist-get state :dropped)
                          :position (plist-get state :position)
                          :fps (plist-get state :fps)
                          :volume (plist-get state :volume)))))
     :cleanup (lambda ()
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer (etaf-video-player-close)))))))

(dolist (operation '(frame volume mute))
  (let ((operation operation))
    (taf-benchmark-register
     (format "video-player.%s" operation)
     :version 1 :modes '(gui) :isolation 'series :impact 'local
     :budget-ms (if (eq operation 'frame) 85 50)
     :description (format "Native video player %s with real media and a visible window" operation)
     :setup (lambda (_mode) (etaf-video-player-benchmark--fixture operation)))))

;;; performance-scenarios.el ends here
