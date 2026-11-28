;;; etaf-media-session.el --- Headless playback sessions for native video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One session owns a frame producer, the optional audio sidecar and the
;; display timer.  Each tick claims the newest complete frame and hands it to
;; the `:on-frame' callback; state changes call `:on-state'.  Nothing here
;; knows about buffers, Hosts or rendering, so the same session drives the
;; native `etaf-video' Component and any application that maps frames itself.

;;; Code:

(require 'cl-lib)
(require 'etaf-media-source)
(require 'etaf-media-audio)

(defvar etaf-video-display-fps 30
  "Display timer rate in frames per second for new sessions.
It caps the presented frame rate; the producer's own rate may be lower or
higher.  Values below 1 are raised to 1.")

(defconst etaf-video--stall-threshold 1.8
  "Seconds without a new decoded frame before network playback enters buffering.
Freezing the clock and stopping the audio sidecar during a stall prevents
audio and the progress indicator from drifting ahead of a stalled stream.")

(defconst etaf-video--audio-stats-grace 0.25
  "Seconds to wait for ffplay `-stats' before falling back to wall clock.
Real ffplay prints its first status line within ~100 ms; mock fixtures that
emit no stats never stall tests beyond this window.")

(defconst etaf-video--audio-ready-timeout 5.0
  "Maximum seconds to hold Frame 0 while waiting for ffplay's hardware clock.")

(cl-defstruct (etaf-video--session (:constructor etaf-video--session--make))
  "A headless playback session."
  spec format width height display-fps speed timer source base
  playing stepping ended finished on-frame on-state
  audio volume audio-process presented
  play-start last-frame-time buffering error audio-pending canvas
  audio-start-wall audio-stats-seen audio-clock-first audio-clock-val
  audio-clock-wall first-frame-shown last-presented-pts canvas-frame-index)

(defun etaf-video--session-output-fps (session)
  "Return the constant frame rate used by SESSION's video decoder."
  (let* ((display (float (max 1 (or (etaf-video--session-display-fps session) 30))))
         (src-fps (plist-get (etaf-video--session-spec session) :fps)))
    (if (and (numberp src-fps) (> src-fps 0))
        (min (float src-fps) display)
      display)))

(defun etaf-video--session-audio-live-clock (session &optional now)
  "Return the live hardware audio media clock in seconds, or nil.
`ffplay' reports post-`atempo' playback time, so multiplying elapsed audio
time since the first sample by SESSION's speed recovers exact source media
time even at 1.25x, 1.5x or 2x."
  (when-let* ((val (etaf-video--session-audio-clock-val session))
              (first (etaf-video--session-audio-clock-first session))
              (wall (etaf-video--session-audio-clock-wall session))
              (proc (etaf-video--session-audio-process session))
              ((process-live-p proc)))
    (let* ((now (or now (float-time)))
           ;; Cap wall interpolation so an audio buffer stall freezes video too.
           (interp (max 0.0 (min 0.25 (- now wall))))
           (elapsed (+ (- val first) interp)))
      (+ first (* elapsed (etaf-video--session-speed session))))))

(defun etaf-video--session-waiting-audio-p (session now)
  "Return non-nil while SESSION should hold video waiting for live audio clock."
  (let ((proc (etaf-video--session-audio-process session))
        (started (etaf-video--session-audio-start-wall session)))
    (and (etaf-video--session-audio session)
         (process-live-p proc)
         (null (etaf-video--session-audio-clock-val session))
         started
         (let ((age (- now started)))
           (if (etaf-video--session-audio-stats-seen session)
               (< age etaf-video--audio-ready-timeout)
             (< age etaf-video--audio-stats-grace))))))

(defun etaf-video-session-position (session)
  "Return SESSION's current position in seconds.
When the ffplay sidecar reports a live hardware audio clock, that clock is
authoritative so picture, subtitles, progress bar and audio stay locked
together.  Otherwise the position follows wall clock from `play-start', and
freezes at `base' while paused or buffering."
  (let* ((live-audio (and (etaf-video--session-playing session)
                          (etaf-video--session-audio-live-clock session)))
         (base (etaf-video--session-base session))
         (start (etaf-video--session-play-start session))
         (position (cond
                    (live-audio (max 0.0 live-audio))
                    (start (+ base (* (- (float-time) start)
                                      (etaf-video--session-speed session))))
                    (t base)))
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
          (etaf-video--session-play-start session) nil
          (etaf-video--session-first-frame-shown session) nil
          (etaf-video--session-canvas-frame-index session) 0)
    (etaf-video--source-close source)
    (setf (etaf-video--session-source session) nil)))

(defun etaf-video--session-reset-audio-clock (session)
  "Clear live audio-clock telemetry on SESSION."
  (setf (etaf-video--session-audio-start-wall session) nil
        (etaf-video--session-audio-stats-seen session) nil
        (etaf-video--session-audio-clock-first session) nil
        (etaf-video--session-audio-clock-val session) nil
        (etaf-video--session-audio-clock-wall session) nil))

(defun etaf-video--session-stop-audio (session)
  "Terminate SESSION's audio sidecar and cancel a pending start."
  (setf (etaf-video--session-audio-pending session) nil)
  (etaf-video--session-reset-audio-clock session)
  (when-let* ((process (etaf-video--session-audio-process session)))
    (etaf-video--audio-stop process)
    (setf (etaf-video--session-audio-process session) nil)))

(defun etaf-video--session-start-audio (session &optional position)
  "Start SESSION's audio sidecar at POSITION (or current position)."
  (etaf-video--session-stop-audio session)
  (when (etaf-video--session-audio session)
    (let* ((pos (or position (etaf-video-session-position session)))
           (proc nil)
           (on-stats
            (lambda ()
              (when (eq proc (etaf-video--session-audio-process session))
                (setf (etaf-video--session-audio-stats-seen session) t))))
           (on-clock
            (lambda (clk now)
              (when (eq proc (etaf-video--session-audio-process session))
                (unless (etaf-video--session-audio-clock-first session)
                  (setf (etaf-video--session-audio-clock-first session) clk))
                (setf (etaf-video--session-audio-stats-seen session) t
                      (etaf-video--session-audio-clock-val session) clk
                      (etaf-video--session-audio-clock-wall session) now)))))
      (setq proc (etaf-video--audio-start
                  (etaf-video--session-spec session)
                  pos
                  (etaf-video--session-speed session)
                  (etaf-video--session-volume session)
                  on-clock on-stats))
      (when proc
        (setf (etaf-video--session-audio-process session) proc
              (etaf-video--session-audio-start-wall session) (float-time))))))

(defun etaf-video--session-spawn (session &optional start)
  "Create SESSION's producer at START seconds, or at its base."
  (let* ((target (or start (etaf-video--session-base session)))
         (source (etaf-video--source-start
                  (etaf-video--session-spec session)
                  (etaf-video--session-format session)
                  (etaf-video--session-width session)
                  (etaf-video--session-height session)
                  :speed (etaf-video--session-speed session)
                  :start target
                  :fps (etaf-video--session-output-fps session))))
    (setf (etaf-video--session-source session) source
          (etaf-video--session-base session) target
          (etaf-video--session-first-frame-shown session) nil
          (etaf-video--session-last-presented-pts session) nil
          (etaf-video--session-canvas-frame-index session) 0
          (etaf-video--session-ended session) nil
          (etaf-video--session-finished session) nil)
    source))

(defun etaf-video--session-finish (session)
  "Stop SESSION after its producer ended, keeping the last state."
  (unless (etaf-video--session-finished session)
    (let* ((source (etaf-video--session-source session))
           (err (and source (etaf-video--source-error-text source))))
      (setf (etaf-video--session-ended session) t
            (etaf-video--session-finished session) t
            (etaf-video--session-playing session) nil
            (etaf-video--session-stepping session) nil
            (etaf-video--session-buffering session) nil)
      (when err
        (setf (etaf-video--session-error session) err)))
    (when-let* ((timer (etaf-video--session-timer session)))
      (cancel-timer timer)
      (setf (etaf-video--session-timer session) nil))
    (etaf-video--session-stop-source session)
    (etaf-video--session-stop-audio session)
    (etaf-video--session-notify session)))

(defun etaf-video--session-tick (session)
  "One display tick: present the frame locked to the master clock."
  (let ((source (etaf-video--session-source session))
        (now (float-time))
        (delivered nil))
    (cond
     ;; 1. Single-frame step while paused: pop one frame immediately.
     ((and source (etaf-video--session-stepping session))
      (let ((frame (if (etaf-video--session-canvas session)
                       t
                     (cdr (etaf-video--source-pop source)))))
        (when frame
          (etaf-video--session-deliver session frame)
          (setf (etaf-video--session-last-frame-time session) now
                (etaf-video--session-buffering session) nil
                (etaf-video--session-error session) nil
                (etaf-video--session-stepping session) nil
                (etaf-video--session-playing session) nil)
          (etaf-video--session-stop-source session)
          (etaf-video--session-stop-audio session)
          (setq source nil
                delivered t)
          (etaf-video--session-notify session))))
     ;; 2. Active playback locked to CoreAudio master clock (or wall clock if muted).
     ((and source (etaf-video--session-playing session))
      (let* ((was-buffering (etaf-video--session-buffering session))
             (audio-clk (etaf-video--session-audio-live-clock session now))
             (waiting-audio (and (null audio-clk)
                                 (etaf-video--session-waiting-audio-p session now))))
        (cond
         ;; 2a. Audio sidecar is connecting: display Frame 0 immediately as a crisp
         ;; preview, then hold cleanly until CoreAudio emits its first sample so
         ;; audio and video begin in exact 0 ms lockstep.
         (waiting-audio
          (when (and (not (etaf-video--session-first-frame-shown session))
                     (if (etaf-video--session-canvas session)
                         t
                       (etaf-video--source-has-frames-p source)))
            (let* ((entry (unless (etaf-video--session-canvas session)
                            (etaf-video--source-pop source)))
                   (frame (if (etaf-video--session-canvas session) t (cdr entry)))
                   (vpts (if (etaf-video--session-canvas session)
                             (etaf-video--session-base session)
                           (car entry))))
              (etaf-video--session-deliver session frame)
              (setf (etaf-video--session-first-frame-shown session) t
                    (etaf-video--session-last-presented-pts session) vpts
                    (etaf-video--session-last-frame-time session) now)
              (when (etaf-video--session-canvas session)
                (cl-incf (etaf-video--session-canvas-frame-index session)))
              (setq delivered t))))
         ;; 2b. Master clock is active: present only frames whose PTS <= clock.
         (t
          (when (and (null (etaf-video--session-play-start session))
                     (or audio-clk
                         (etaf-video--session-canvas session)
                         (etaf-video--source-has-frames-p source)))
            (setf (etaf-video--session-play-start session) now)
            (when audio-clk
              (setf (etaf-video--session-base session) audio-clk)))
          (when (or audio-clk (etaf-video--session-play-start session))
            (let ((clock (or audio-clk
                             (+ (etaf-video--session-base session)
                                (* (- now (etaf-video--session-play-start session))
                                   (etaf-video--session-speed session))))))
              (if (etaf-video--session-canvas session)
                  (let* ((fps (etaf-video--session-output-fps session))
                         (idx (etaf-video--session-canvas-frame-index session))
                         (next-pts (+ (float (or (etaf-video--source-start-pts source) 0.0))
                                      (/ (float idx) fps))))
                    (when (<= next-pts (+ clock 0.008))
                      (etaf-video--session-deliver session t)
                      (cl-incf (etaf-video--session-canvas-frame-index session))
                      (setf (etaf-video--session-first-frame-shown session) t
                            (etaf-video--session-last-presented-pts session) next-pts
                            (etaf-video--session-last-frame-time session) now
                            (etaf-video--session-buffering session) nil
                            (etaf-video--session-error session) nil
                            delivered t)
                      (when was-buffering
                        (etaf-video--session-notify session))))
                (let ((entry (etaf-video--source-claim-for-clock source (+ clock 0.008))))
                  (cond
                   (entry
                    (etaf-video--session-deliver session (cdr entry))
                    (setf (etaf-video--session-first-frame-shown session) t
                          (etaf-video--session-last-presented-pts session) (car entry)
                          (etaf-video--session-last-frame-time session) now
                          (etaf-video--session-buffering session) nil
                          (etaf-video--session-error session) nil
                          delivered t)
                    (when was-buffering
                      (etaf-video--session-notify session)))
                   ;; Queue holds a future frame: intentionally waiting for audio clock.
                   ((etaf-video--source-peek-pts source)
                    (setf (etaf-video--session-last-frame-time session) now)
                    (when was-buffering
                      (setf (etaf-video--session-buffering session) nil)
                      (etaf-video--session-notify session)))
                   ;; Queue is empty: detect mid-stream video stall or severe lag.
                   ((and (not (etaf-video--source-ended source))
                         (etaf-video--session-last-frame-time session)
                         (not (etaf-video--session-buffering session))
                         (or (>= (- now (etaf-video--session-last-frame-time session))
                                 etaf-video--stall-threshold)
                             (and audio-clk
                                  (etaf-video--session-last-presented-pts session)
                                  (> (- audio-clk (etaf-video--session-last-presented-pts session))
                                     etaf-video--stall-threshold))))
                    (let ((resume-pos (or (etaf-video--session-last-presented-pts session)
                                          (etaf-video-session-position session))))
                      (setf (etaf-video--session-base session) resume-pos
                            (etaf-video--session-play-start session) nil
                            (etaf-video--session-buffering session) t)
                      (etaf-video--session-stop-source session)
                      (etaf-video--session-stop-audio session)
                      (etaf-video--session-spawn session resume-pos)
                      (when (etaf-video--session-audio session)
                        (etaf-video--session-start-audio session resume-pos))
                      (etaf-video--session-notify session)))))))))))))
    (ignore delivered)
    (when (and (or (etaf-video--session-ended session)
                   (and source (etaf-video--source-ended source)))
               (or (null source)
                   (not (etaf-video--source-has-frames-p source))))
      (etaf-video--session-finish session))))

(defun etaf-video--session-start-timer (session)
  "Start SESSION's display timer when it is not running.
Runs at least 60 Hz so master-clock frame presentation lands within ±8 ms
without extra work on ticks where no new frame is due."
  (unless (etaf-video--session-timer session)
    (let ((hz (max 60 (* 2 (max 1 (round (etaf-video--session-display-fps session)))))))
      (setf (etaf-video--session-timer session)
            (run-at-time 0.0 (/ 1.0 (float hz))
                         #'etaf-video--session-tick session)))))

(defun etaf-video-session-play (session)
  "Start (or resume) SESSION: producer, audio and display timer in lockstep.
Launching ffmpeg and ffplay simultaneously halves cold-start latency and lets
CoreAudio's live clock gate Frame 1 with zero startup offset."
  (let ((target (etaf-video--session-base session)))
    (unless (etaf-video--session-source session)
      (etaf-video--session-spawn session target))
    (etaf-video--session-start-timer session)
    (setf (etaf-video--session-playing session) t
          (etaf-video--session-stepping session) nil
          (etaf-video--session-play-start session) nil
          (etaf-video--session-last-frame-time session) nil
          (etaf-video--session-buffering session) t
          (etaf-video--session-error session) nil
          (etaf-video--session-audio-pending session) nil)
    (when (etaf-video--session-audio session)
      (etaf-video--session-start-audio session target))
    (etaf-video--session-notify session)
    t))

(defun etaf-video-session-pause (session)
  "Pause SESSION: release the producer and the audio sidecar."
  (setf (etaf-video--session-playing session) nil
        (etaf-video--session-stepping session) nil
        (etaf-video--session-buffering session) nil)
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
  "Move SESSION to SECONDS and restart video and audio together there."
  (let* ((duration (plist-get (etaf-video--session-spec session) :duration))
         (target (max 0 (if duration (min seconds duration) seconds)))
         (playing (etaf-video--session-playing session)))
    (setf (etaf-video--session-base session) target)
    (if playing
        (progn
          (etaf-video--session-stop-source session)
          (etaf-video--session-stop-audio session)
          (setf (etaf-video--session-base session) target
                (etaf-video--session-play-start session) nil
                (etaf-video--session-last-frame-time session) nil
                (etaf-video--session-buffering session) t
                (etaf-video--session-error session) nil
                (etaf-video--session-audio-pending session) nil)
          (etaf-video--session-spawn session target)
          (when (etaf-video--session-audio session)
            (etaf-video--session-start-audio session target))
          (etaf-video--session-start-timer session)
          (etaf-video--session-notify session))
      (etaf-video--session-stop-source session)
      (etaf-video--session-stop-audio session)
      (setf (etaf-video--session-base session) target
            (etaf-video--session-buffering session) nil
            (etaf-video--session-ended session) nil
            (etaf-video--session-finished session) nil)
      ;; A paused canvas shows the frame at the new position.
      (etaf-video-session-step session)))
  t)

(defun etaf-video-session-set-speed (session speed)
  "Set SESSION's playback rate to SPEED, a positive number."
  (unless (and (numberp speed) (> speed 0))
    (user-error "Playback speed must be a positive number: %S" speed))
  (let ((position (etaf-video-session-position session)))
    (setf (etaf-video--session-speed session) speed)
    (if (etaf-video--session-playing session)
        (progn
          (etaf-video--session-stop-source session)
          (etaf-video--session-stop-audio session)
          (setf (etaf-video--session-base session) position
                (etaf-video--session-play-start session) nil
                (etaf-video--session-last-frame-time session) nil
                (etaf-video--session-buffering session) t
                (etaf-video--session-audio-pending session) nil)
          (etaf-video--session-spawn session position)
          (when (etaf-video--session-audio session)
            (etaf-video--session-start-audio session position))
          (etaf-video--session-notify session))
      (etaf-video--session-notify session)))
  t)

(defun etaf-video-session-set-volume (session volume)
  "Set SESSION's audio volume to VOLUME, from 0 to 100.
Re-locks the video clock to the restarted ffplay sidecar so changing volume
never introduces audio startup drift."
  (unless (and (numberp volume) (<= 0 volume 100))
    (user-error "Audio volume must be between 0 and 100: %S" volume))
  (let ((position (or (etaf-video--session-last-presented-pts session)
                      (etaf-video-session-position session))))
    (setf (etaf-video--session-volume session) volume)
    (when (and (etaf-video--session-playing session)
               (etaf-video--session-audio session))
      (setf (etaf-video--session-base session) position
            (etaf-video--session-play-start session) nil)
      (etaf-video--session-start-audio session position))
    (etaf-video--session-notify session))
  t)

(defun etaf-video-session-set-audio (session audio)
  "Turn SESSION's audio sidecar on (non-nil) or off (nil).
Unmuting restarts audio at the last presented frame and re-locks the clock."
  (let ((position (or (etaf-video--session-last-presented-pts session)
                      (etaf-video-session-position session))))
    (setf (etaf-video--session-audio session) (and audio t))
    (if (etaf-video--session-playing session)
        (if audio
            (progn
              (setf (etaf-video--session-base session) position
                    (etaf-video--session-play-start session) nil)
              (etaf-video--session-start-audio session position))
          (setf (etaf-video--session-base session) position
                (etaf-video--session-play-start session) (float-time))
          (etaf-video--session-stop-audio session))
      (etaf-video--session-stop-audio session))
    (etaf-video--session-notify session))
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
          :buffering (and (etaf-video--session-buffering session) t)
          :error (etaf-video--session-error session)
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

(provide 'etaf-media-session)
;;; etaf-media-session.el ends here
