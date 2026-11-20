;;; etaf-video-session.el --- Headless playback sessions for native video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One session owns a frame producer, the optional audio sidecar and the
;; display timer.  Each tick claims the newest complete frame and hands it to
;; the `:on-frame' callback; state changes call `:on-state'.  Nothing here
;; knows about buffers, Hosts or rendering, so the same session drives the
;; native `etaf-video' Component and any application that maps frames itself.

;;; Code:

(require 'cl-lib)
(require 'etaf-video-source)
(require 'etaf-video-audio)

(defvar etaf-video-display-fps 30
  "Display timer rate in frames per second for new sessions.
It caps the presented frame rate; the producer's own rate may be lower or
higher.  Values below 1 are raised to 1.")

(cl-defstruct (etaf-video--session (:constructor etaf-video--session--make))
  "A headless playback session."
  spec format width height display-fps speed timer source base
  playing stepping ended finished on-frame on-state
  audio volume audio-process presented
  play-start audio-pending canvas)

(defun etaf-video-session-position (session)
  "Return SESSION's current position in seconds.
While a frame is on screen the position follows the wall clock from the
moment that frame arrived, so a slow decoder or a dropped display frame
never lets the picture clock drift away from the audio sidecar.  Between a
seek and the first frame, and while paused, it stays at the seek base."
  (let* ((base (etaf-video--session-base session))
         (start (etaf-video--session-play-start session))
         (position (if start
                       (+ base (* (- (float-time) start)
                                   (etaf-video--session-speed session)))
                     base))
         (duration (plist-get (etaf-video--session-spec session) :duration)))
    (if duration (min position duration) position)))

(defun etaf-video--session-notify (session)
  "Call SESSION's state callback, ignoring its value."
  (when-let* ((callback (etaf-video--session-on-state session)))
    (funcall callback session)))

(defun etaf-video--session-deliver (session frame)
  "Hand FRAME to SESSION's frame callback and count it."
  (cl-incf (etaf-video--session-presented session))
  (when-let* ((callback (etaf-video--session-on-frame session)))
    (funcall callback frame session)))

(defun etaf-video--session-stop-source (session)
  "Close SESSION's producer, keeping the position it reached.
The clock freezes here: a later producer starts again from the saved base."
  (when-let* ((source (etaf-video--session-source session)))
    (setf (etaf-video--session-base session)
          (etaf-video-session-position session)
          (etaf-video--session-play-start session) nil)
    (etaf-video--source-close source)
    (setf (etaf-video--session-source session) nil)))

(defun etaf-video--session-stop-audio (session)
  "Terminate SESSION's audio sidecar and cancel a pending start."
  (setf (etaf-video--session-audio-pending session) nil)
  (when-let* ((process (etaf-video--session-audio-process session)))
    (etaf-video--audio-stop process)
    (setf (etaf-video--session-audio-process session) nil)))

(defun etaf-video--session-start-audio (session)
  "Start SESSION's audio sidecar at its current position."
  (etaf-video--session-stop-audio session)
  (when (etaf-video--session-audio session)
    (setf (etaf-video--session-audio-process session)
          (etaf-video--audio-start
           (etaf-video--session-spec session)
           (etaf-video-session-position session)
           (etaf-video--session-speed session)
           (etaf-video--session-volume session)))))

(defun etaf-video--session-spawn (session &optional start)
  "Create SESSION's producer at START seconds, or at its base."
  (let ((source (etaf-video--source-start
                 (etaf-video--session-spec session)
                 (etaf-video--session-format session)
                 (etaf-video--session-width session)
                 (etaf-video--session-height session)
                 :speed (etaf-video--session-speed session)
                 :start (or start (etaf-video--session-base session)))))
    (setf (etaf-video--session-source session) source
          (etaf-video--session-base session) (or start (etaf-video--session-base session))
          (etaf-video--session-ended session) nil
          (etaf-video--session-finished session) nil)
    source))

(defun etaf-video--session-finish (session)
  "Stop SESSION after its producer ended, keeping the last state."
  (unless (etaf-video--session-finished session)
    (setf (etaf-video--session-ended session) t
          (etaf-video--session-finished session) t
          (etaf-video--session-playing session) nil
          (etaf-video--session-stepping session) nil)
    (when-let* ((timer (etaf-video--session-timer session)))
      (cancel-timer timer)
      (setf (etaf-video--session-timer session) nil))
    (etaf-video--session-stop-source session)
    (etaf-video--session-stop-audio session)
    (etaf-video--session-notify session)))

(defun etaf-video--session-tick (session)
  "One display tick: claim the newest frame and update the state machine."
  (let ((source (etaf-video--session-source session))
        (frame nil))
    (when (and source
               (or (etaf-video--session-playing session)
                   (etaf-video--session-stepping session)))
      (if (etaf-video--session-canvas session)
          ;; The canvas backend reads the fifo itself; the tick only says a
          ;; frame is due and the presenter refreshes the canvas.
          (setq frame t)
        (setq frame (etaf-video--source-claim source))))
    (when frame
      (etaf-video--session-deliver session frame)
      ;; The first presented frame starts the clock and, when the sidecar is
      ;; pending, the audio.  Starting audio earlier lets sound run ahead of
      ;; a picture whose decoder has not delivered its first frame yet.
      (unless (etaf-video--session-play-start session)
        (setf (etaf-video--session-play-start session) (float-time)))
      (when (etaf-video--session-audio-pending session)
        (setf (etaf-video--session-audio-pending session) nil)
        (etaf-video--session-start-audio session))
      (when (etaf-video--session-stepping session)
        (setf (etaf-video--session-stepping session) nil
              (etaf-video--session-playing session) nil)
        (etaf-video--session-stop-source session)
        (etaf-video--session-stop-audio session)
        ;; The producer was closed deliberately by the step, so its closed
        ;; process is not the end of the video; the finish check below must
        ;; only see a producer that ran out on its own.
        (setq source nil)
        (etaf-video--session-notify session)))
    (when (and (or (etaf-video--session-ended session)
                   (and source (etaf-video--source-ended source)))
               (or (null source) (null (etaf-video--source-latest source))))
      (etaf-video--session-finish session))))

(defun etaf-video--session-start-timer (session)
  "Start SESSION's display timer when it is not running."
  (unless (etaf-video--session-timer session)
    (setf (etaf-video--session-timer session)
          (run-at-time 0.0 (/ 1.0 (max 1 (round (etaf-video--session-display-fps session))))
                       #'etaf-video--session-tick session))))

(defun etaf-video-session-play (session)
  "Start (or resume) SESSION: producer, audio and display timer.
A pending manual step is cancelled: playing supersedes it, and leaving the
step flag set would make the next tick pause after one frame."
  (unless (etaf-video--session-source session)
    (etaf-video--session-spawn session))
  (etaf-video--session-start-timer session)
  (setf (etaf-video--session-playing session) t
        (etaf-video--session-stepping session) nil
        (etaf-video--session-play-start session) nil
        (etaf-video--session-audio-pending session)
        (and (etaf-video--session-audio session) t))
  (etaf-video--session-notify session)
  t)

(defun etaf-video-session-pause (session)
  "Pause SESSION: release the producer and the audio sidecar."
  (setf (etaf-video--session-playing session) nil
        (etaf-video--session-stepping session) nil)
  (etaf-video--session-stop-source session)
  (etaf-video--session-stop-audio session)
  (etaf-video--session-notify session)
  t)

(defun etaf-video-session-toggle (session)
  "Toggle SESSION between playing and paused."
  (if (etaf-video--session-playing session)
      (etaf-video-session-pause session)
    (when (etaf-video--session-ended session)
      (setf (etaf-video--session-base session) 0))
    (etaf-video-session-play session)))

(defun etaf-video-session-step (session)
  "Pause SESSION and present exactly one more frame."
  (when (etaf-video--session-playing session)
    (etaf-video-session-pause session))
  (unless (etaf-video--session-ended session)
    (unless (etaf-video--session-source session)
      (etaf-video--session-spawn session))
    (setf (etaf-video--session-stepping session) t)
    (etaf-video--session-start-timer session)
    (etaf-video--session-notify session))
  t)

(defun etaf-video-session-seek (session seconds)
  "Move SESSION to SECONDS and restart its producer there."
  (let* ((duration (plist-get (etaf-video--session-spec session) :duration))
         (target (max 0 (if duration (min seconds duration) seconds)))
         (playing (etaf-video--session-playing session)))
    (setf (etaf-video--session-base session) target)
    (if playing
        (progn
          (etaf-video--session-stop-source session)
          (setf (etaf-video--session-base session) target
                (etaf-video--session-play-start session) nil
                (etaf-video--session-audio-pending session)
                (and (etaf-video--session-audio session) t))
          (etaf-video--session-spawn session target)
          (etaf-video--session-start-timer session)
          (etaf-video--session-notify session))
      (etaf-video--session-stop-source session)
      (etaf-video--session-stop-audio session)
      (setf (etaf-video--session-base session) target
            (etaf-video--session-ended session) nil
            (etaf-video--session-finished session) nil)
      ;; A paused canvas shows the frame at the new position.
      (etaf-video-session-step session)))
  t)

(defun etaf-video-session-set-speed (session speed)
  "Set SESSION's playback rate to SPEED, a positive number."
  (unless (and (numberp speed) (> speed 0))
    (user-error "Playback speed must be a positive number: %S" speed))
  (setf (etaf-video--session-speed session) speed)
  (if (etaf-video--session-playing session)
      (progn
        (let ((position (etaf-video-session-position session)))
          (etaf-video--session-stop-source session)
          (setf (etaf-video--session-play-start session) nil
                (etaf-video--session-audio-pending session)
                (and (etaf-video--session-audio session) t))
          (etaf-video--session-spawn session position)))
    (etaf-video--session-notify session))
  t)

(defun etaf-video-session-set-volume (session volume)
  "Set SESSION's audio volume to VOLUME, from 0 to 100."
  (unless (and (numberp volume) (<= 0 volume 100))
    (user-error "Audio volume must be between 0 and 100: %S" volume))
  (setf (etaf-video--session-volume session) volume)
  (when (etaf-video--session-playing session)
    (etaf-video--session-start-audio session))
  (etaf-video--session-notify session)
  t)

(defun etaf-video-session-set-audio (session audio)
  "Turn SESSION's audio sidecar on (non-nil) or off (nil)."
  (setf (etaf-video--session-audio session) (and audio t))
  (if (etaf-video--session-playing session)
      (if audio
          (etaf-video--session-start-audio session)
        (etaf-video--session-stop-audio session))
    (etaf-video--session-stop-audio session))
  (etaf-video--session-notify session)
  t)

(defun etaf-video-session-state (session)
  "Return SESSION's state as a detached plist.
Keys are `:source', `:playing', `:position', `:duration', `:speed',
`:format', `:width', `:height', `:display-fps', `:source-fps', `:received',
`:presented', `:dropped', `:audio' and `:ended'."
  (let* ((spec (etaf-video--session-spec session))
         (source (etaf-video--session-source session)))
    (list :source (pcase (plist-get spec :kind)
                    ('file (plist-get spec :file))
                    ('url (plist-get spec :url))
                    (_ 'demo))
          :playing (and (etaf-video--session-playing session) t)
          :position (etaf-video-session-position session)
          :duration (plist-get spec :duration)
          :speed (etaf-video--session-speed session)
          :format (etaf-video--session-format session)
          :width (etaf-video--session-width session)
          :height (etaf-video--session-height session)
          :display-fps (etaf-video--session-display-fps session)
          :source-fps (plist-get spec :fps)
          :received (if source (etaf-video--source-received source) 0)
          :presented (etaf-video--session-presented session)
          :dropped (if source (etaf-video--source-dropped source) 0)
          :audio (and (etaf-video--session-audio session) t)
          :ended (and (etaf-video--session-ended session) t))))

(defun etaf-video-session-destroy (session)
  "Release SESSION's timer, producer and audio sidecar."
  (when-let* ((timer (etaf-video--session-timer session)))
    (cancel-timer timer)
    (setf (etaf-video--session-timer session) nil))
  (etaf-video--session-stop-source session)
  (etaf-video--session-stop-audio session)
  (setf (etaf-video--session-playing session) nil
        (etaf-video--session-stepping session) nil)
  t)

(cl-defun etaf-video-session-create (source &key format width height fps
                                            speed start (audio :default) volume
                                            canvas on-frame on-state)
  "Create a headless playback SESSION for SOURCE and return it.
SOURCE is nil for the built-in demo, a local file name, an HTTP(S) URL, or a
plist accepted by the source normalizer (`:file', `:url', `:demo').

FORMAT is `gray' (one byte per sample, the default), `rgb24' (three bytes per
pixel), `bgra' (four bytes per pixel, read from a fifo by the canvas backend)
or `mjpeg' (one complete JPEG image per frame).  WIDTH and HEIGHT are
the frame dimensions in the chosen format.  FPS caps the presented rate and
defaults to `etaf-video-display-fps'; SPEED defaults to 1 and START to 0.

AUDIO enables the ffplay sidecar; `:default' follows `etaf-video-audio' and
an explicit nil stays silent.  VOLUME sets its level (default
`etaf-video-audio-volume').  Sources that report no audio stream and the
built-in demo stay silent.

ON-FRAME receives each presented frame and the session as `(FRAME SESSION)';
ON-STATE runs after every state change.  The session starts paused: call
`etaf-video-session-play', or let the native `etaf-video' Component do it."
  (let* ((spec (etaf-video--normalize-source source))
         (format (or format 'gray))
         (width (or width 80))
         (height (or height 24)))
    (unless (memq format '(gray rgb24 bgra mjpeg))
      (user-error "Unsupported video frame format: %S" format))
    (unless (and (integerp width) (> width 0) (integerp height) (> height 0))
      (user-error "Frame size must be positive integers: %S by %S" width height))
    (when (and speed (not (and (numberp speed) (> speed 0))))
      (user-error "Playback speed must be a positive number: %S" speed))
    (etaf-video--session--make
     :spec spec :format format :width width :height height
     :display-fps (max 1 (round (or fps etaf-video-display-fps)))
     :speed (or speed 1)
     :base (or start 0)
     :playing nil :stepping nil :ended nil :finished nil
     :canvas (and canvas t)
     :on-frame on-frame :on-state on-state
     :audio (if (eq audio :default) (and etaf-video-audio t) (and audio t))
     :volume (or volume etaf-video-audio-volume)
     :presented 0)))

(provide 'etaf-video-session)
;;; etaf-video-session.el ends here
