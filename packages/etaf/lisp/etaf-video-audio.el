;;; etaf-video-audio.el --- Audio sidecar for native video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; ffplay plays a source's audio track as a sidecar: no video window, auto
;; exit at the end of the stream, started at a position and rate.  A playback
;; session owns at most one sidecar process.  Sources that report no audio
;; stream, the built-in demo and a missing ffplay all stay silent.  A source
;; with a separate `:audio-url' plays that stream instead of the video
;; stream, carrying the same `:headers' and `:proxy' as the video decoder.

;;; Code:

(require 'cl-lib)
(require 'etaf-video-source)

(defvar etaf-video-ffplay-program "ffplay"
  "Name or absolute path of the ffplay executable used for audio.
Part of the ffmpeg installation.")

(defvar etaf-video-audio nil
  "Whether new playback sessions play their source's audio by default.
A session's `:audio' argument overrides it.")

(defvar etaf-video-audio-volume 100
  "Default audio volume for new sessions, from 0 to 100.")

(defun etaf-video--audio-available-p ()
  "Return non-nil when an ffplay executable can be found."
  (and (executable-find etaf-video-ffplay-program) t))

(defun etaf-video--audio-arguments (spec position speed volume)
  "Return ffplay arguments for SPEC at POSITION, SPEED and VOLUME.
A separate `:audio-url' becomes the sidecar input, and the source's
`:headers' and `:proxy' precede it as input options, so an authenticated
stream plays the same track the video decoder was given."
  (append (list "-nodisp" "-autoexit" "-loglevel" "error"
                "-volume" (number-to-string
                           (max 0 (min 100 (round (or volume 100))))))
          (when (and (numberp position) (> position 0))
            (list "-ss" (number-to-string position)))
          (when (and (numberp speed) (not (= speed 1)))
            (list "-af" (format "atempo=%s" speed)))
          (let ((target (or (plist-get spec :audio-target)
                            (plist-get spec :target))))
            (if (etaf-video--url-p target)
                (append (etaf-video--http-arguments (plist-get spec :headers)
                                                    (plist-get spec :proxy))
                        (list "-reconnect" "1" "-reconnect_streamed" "1"
                              "-reconnect_delay_max" "5")
                        (list target))
              (list target)))))

(defun etaf-video--audio-start (spec position speed volume)
  "Start an ffplay sidecar for SPEC, or return nil when it is not needed.
POSITION is the start offset in seconds, SPEED the playback rate and VOLUME
the 0 to 100 level.  Sources without a reported audio stream and the built-in
demo stay silent."
  (when (and (plist-get spec :audio)
             (etaf-video--audio-available-p))
    (let ((buffer (generate-new-buffer " *etaf-video audio*")))
      (condition-case nil
          (make-process :name "etaf-video-audio"
                        :command (cons (executable-find etaf-video-ffplay-program)
                                       (etaf-video--audio-arguments
                                        spec position speed volume))
                        :buffer buffer
                        :coding '(no-conversion . no-conversion)
                        :connection-type 'pipe
                        :noquery t)
        (error (when (buffer-live-p buffer) (kill-buffer buffer)) nil)))))

(defun etaf-video--audio-stop (process)
  "Terminate the ffplay sidecar PROCESS and release its buffer."
  (when (process-live-p process) (delete-process process))
  (when-let* ((buffer (process-buffer process)))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(provide 'etaf-video-audio)
;;; etaf-video-audio.el ends here
