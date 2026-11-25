;;; etaf-video-mpv.el --- Cross-platform libmpv playback backend -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Optional libmpv playback backend for `etaf-video'.  Loads the thin native
;; module `native/etaf-video-mpv.{dylib,so,dll}' on demand; when libmpv or the
;; compiled module is unavailable, `etaf-video-mpv-available-p' returns nil and
;; `etaf-video' falls back cleanly to the ffmpeg backend.  All media decoding,
;; A/V synchronization, seamless volume/speed/seek, multi-track audio and
;; subtitles (including libass ASS/SSA, PGS and dual secondary subtitles),
;; hardware decode and video filters live inside libmpv.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-video-source)

(declare-function etaf-video-mpv--native-available-p "etaf-video-mpv" (&optional library))
(declare-function etaf-video-mpv--native-version "etaf-video-mpv" ())
(declare-function etaf-video-mpv--native-create "etaf-video-mpv" (&optional options))
(declare-function etaf-video-mpv--native-destroy "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-command "etaf-video-mpv" (handle args))
(declare-function etaf-video-mpv--native-set-property "etaf-video-mpv" (handle name value))
(declare-function etaf-video-mpv--native-get-property "etaf-video-mpv" (handle name &optional type))
(declare-function etaf-video-mpv--native-poll-events "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-frame-ready-p "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-render-ppm "etaf-video-mpv" (handle width height))
(declare-function etaf-video-mpv--native-render-canvas "etaf-video-mpv" (handle canvas width height))
(declare-function etaf-video-mpv--native-render-raw "etaf-video-mpv" (handle width height mode))

(defvar etaf-video-engine 'auto
  "Playback engine used by `etaf-video' Components: `auto', `mpv' or `ffmpeg'.
`auto' selects `mpv' on graphical frames in `image' mode when the optional
libmpv native module and shared library are available, and falls back to
`ffmpeg' otherwise.  `mpv' requires libmpv; `ffmpeg' forces the subprocess
pipeline.")

(defvar etaf-video-mpv-library nil
  "Optional explicit path to the libmpv shared library (`dylib', `so' or `dll').
When nil, the native module searches standard system library paths.")

(defvar etaf-video-mpv--module-file nil
  "Loaded path of the `etaf-video-mpv' dynamic module, or nil.")

(defvar etaf-video-mpv--module-failed nil
  "Non-nil after loading the `etaf-video-mpv' module failed once.")

(defun etaf-video-mpv--module-extension ()
  "Return the native dynamic module extension for the current platform."
  (pcase system-type
    ('darwin "dylib")
    ('windows-nt "dll")
    (_ "so")))

(defun etaf-video-mpv--load-module ()
  "Load the optional `etaf-video-mpv' dynamic module once, or return nil."
  (unless etaf-video-mpv--module-failed
    (or etaf-video-mpv--module-file
        (let* ((root (or (ignore-errors
                           (file-name-directory (locate-library "etaf")))
                         (and load-file-name
                              (expand-file-name
                               ".." (file-name-directory load-file-name)))))
               (file (and root
                          (expand-file-name
                           (format "native/etaf-video-mpv.%s"
                                   (etaf-video-mpv--module-extension))
                           root))))
          (if (and file (file-exists-p file)
                   (fboundp 'module-load)
                   (condition-case nil
                       (progn (module-load file) t)
                     (error nil)))
              (setq etaf-video-mpv--module-file file)
            (setq etaf-video-mpv--module-failed t)
            nil)))))

;;;###autoload
(defun etaf-video-mpv-available-p ()
  "Return non-nil when the cross-platform libmpv native backend is ready."
  (and (etaf-video-mpv--load-module)
       (fboundp 'etaf-video-mpv--native-available-p)
       (etaf-video-mpv--native-available-p etaf-video-mpv-library)
       t))

(cl-defstruct (etaf-video-mpv--session (:constructor etaf-video-mpv--session--make))
  "A live libmpv playback session."
  ctx spec format width height display-fps speed audio volume
  timer playing ended buffering error received presented dropped
  on-frame on-state canvas-spec-fn last-pos last-dur file-loaded)

(defun etaf-video-mpv--session-options (spec speed audio volume start playing)
  "Build pre-initialization libmpv option alist for SPEC."
  (let ((opts (list (cons "pause" (if playing "no" "yes"))
                    (cons "mute" (if audio "no" "yes"))
                    (cons "volume" (format "%g" (max 0 (min 150 (or volume 100)))))
                    (cons "speed" (format "%g" (or speed 1))))))
    (when (and (numberp start) (> start 0))
      (push (cons "start" (format "%.3f" start)) opts))
    (when (eq (plist-get spec :kind) 'url)
      (when-let* ((proxy (plist-get spec :proxy)))
        (push (cons "http-proxy" proxy) opts))
      (when-let* ((headers (plist-get spec :headers)))
        (let ((pairs (etaf-video--header-pairs headers))
              rest)
          (dolist (pair pairs)
            (if (string= (downcase (car pair)) "user-agent")
                (push (cons "user-agent" (cdr pair)) opts)
              (push (format "%s: %s" (car pair) (cdr pair)) rest)))
          (when rest
            (push (cons "http-header-fields"
                        (mapconcat #'identity (nreverse rest) ","))
                  opts)))))
    (when-let* ((audio-url (plist-get spec :audio-url)))
      (push (cons "audio-files" audio-url) opts))
    (nreverse opts)))

(defun etaf-video-mpv--notify (session)
  "Call SESSION's `:on-state' callback when present."
  (when-let* ((cb (etaf-video-mpv--session-on-state session)))
    (funcall cb session)))

(defun etaf-video-mpv--render-frame (session)
  "Render one frame from SESSION and deliver it to `:on-frame'."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (let* ((fmt (etaf-video-mpv--session-format session))
           (w (max 1 (etaf-video-mpv--session-width session)))
           (h (max 1 (etaf-video-mpv--session-height session)))
           (frame
            (pcase fmt
              ('canvas
               (when-let* ((fn (etaf-video-mpv--session-canvas-spec-fn session))
                           (canvas (funcall fn)))
                 (and (etaf-video-mpv--native-render-canvas ctx canvas w h)
                      canvas)))
              ('ppm (etaf-video-mpv--native-render-ppm ctx w h))
              ('rgb24 (etaf-video-mpv--native-render-raw ctx w h 'rgb24))
              (_ (etaf-video-mpv--native-render-raw ctx w h 'gray)))))
      (when frame
        (cl-incf (etaf-video-mpv--session-received session))
        (cl-incf (etaf-video-mpv--session-presented session))
        (setf (etaf-video-mpv--session-buffering session) nil)
        (when-let* ((cb (etaf-video-mpv--session-on-frame session)))
          (funcall cb frame session))))))

(defun etaf-video-mpv--drain-events (session)
  "Process pending libmpv events and EOF/buffering transitions on SESSION."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (let ((changed nil))
      (dolist (ev (etaf-video-mpv--native-poll-events ctx))
        (pcase (plist-get ev :event)
          ('file-loaded
           (setf (etaf-video-mpv--session-file-loaded session) t
                 (etaf-video-mpv--session-ended session) nil
                 (etaf-video-mpv--session-error session) nil)
           (when-let* ((dur (etaf-video-mpv--native-get-property ctx "duration" 'float)))
             (setf (etaf-video-mpv--session-last-dur session) dur))
           (setq changed t))
          ('end-file
           (pcase (plist-get ev :reason)
             ('error
              (setf (etaf-video-mpv--session-error session)
                    (or (plist-get ev :error) "libmpv playback error")
                    (etaf-video-mpv--session-ended session) t
                    (etaf-video-mpv--session-playing session) nil
                    (etaf-video-mpv--session-buffering session) nil)
              (setq changed t))
             ('eof
              (setf (etaf-video-mpv--session-ended session) t
                    (etaf-video-mpv--session-playing session) nil
                    (etaf-video-mpv--session-buffering session) nil)
              (setq changed t))))
          ('playback-restart
           (setf (etaf-video-mpv--session-buffering session) nil)
           (setq changed t))))
      (let ((eof (and (etaf-video-mpv--session-file-loaded session)
                      (etaf-video-mpv--native-get-property ctx "eof-reached" 'bool)))
            (buf (etaf-video-mpv--native-get-property ctx "paused-for-cache" 'bool)))
        (when (and eof (not (etaf-video-mpv--session-ended session)))
          (setf (etaf-video-mpv--session-ended session) t
                (etaf-video-mpv--session-playing session) nil
                (etaf-video-mpv--session-buffering session) nil)
          (setq changed t))
        (unless (eq (and buf t) (and (etaf-video-mpv--session-buffering session) t))
          (setf (etaf-video-mpv--session-buffering session) (and buf t))
          (setq changed t)))
      (when changed
        (etaf-video-mpv--notify session)))))

(defun etaf-video-mpv--tick (session)
  "Display timer tick for libmpv SESSION."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--drain-events session)
    (when (etaf-video-mpv--native-frame-ready-p ctx)
      (etaf-video-mpv--render-frame session))))

(cl-defun etaf-video-mpv--session-create
    (spec &key (format 'ppm) width height (speed 1) (fps 30) (start 0)
          (audio nil) (volume 100) (playing t) on-frame on-state canvas-spec-fn)
  "Create and start a libmpv playback session for normalized SPEC."
  (unless (etaf-video-mpv-available-p)
    (user-error "libmpv is not available; build native/etaf-video-mpv and install libmpv"))
  (let* ((target (or (plist-get spec :target)
                     (plist-get spec :file)
                     (plist-get spec :url)))
         (opts (etaf-video-mpv--session-options
                spec speed audio volume start playing))
         (ctx (etaf-video-mpv--native-create opts)))
    (unless target
      (when ctx (etaf-video-mpv--native-destroy ctx))
      (user-error "libmpv backend requires a local file or HTTP(S) URL source"))
    (unless ctx
      (user-error "Failed to initialize libmpv playback context"))
    (let* ((rate (max 1 (round (or fps 30))))
           (session (etaf-video-mpv--session--make
                     :ctx ctx :spec spec :format format
                     :width (max 1 (or width 640))
                     :height (max 1 (or height 360))
                     :display-fps rate
                     :speed speed :audio (and audio t) :volume volume
                     :playing (and playing t)
                     :buffering (and playing t)
                     :received 0 :presented 0 :dropped 0
                     :on-frame on-frame :on-state on-state
                     :canvas-spec-fn canvas-spec-fn
                     :last-pos (float (or start 0))
                     :last-dur (plist-get spec :duration))))
      (etaf-video-mpv--native-command ctx (list "loadfile" target))
      (setf (etaf-video-mpv--session-timer session)
            (run-at-time 0.0 (/ 1.0 rate) #'etaf-video-mpv--tick session))
      session)))

(defun etaf-video-mpv--session-destroy (session)
  "Stop SESSION's timer and destroy its native libmpv context."
  (when-let* ((timer (etaf-video-mpv--session-timer session)))
    (cancel-timer timer)
    (setf (etaf-video-mpv--session-timer session) nil))
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-destroy ctx)
    (setf (etaf-video-mpv--session-ctx session) nil))
  t)

(defun etaf-video-mpv--session-resize (session width height)
  "Resize SESSION's render output to WIDTH by HEIGHT in place without restarting."
  (setf (etaf-video-mpv--session-width session) (max 1 width)
        (etaf-video-mpv--session-height session) (max 1 height))
  (when (etaf-video-mpv--session-file-loaded session)
    (etaf-video-mpv--render-frame session))
  t)

(defun etaf-video-mpv--session-play (session)
  "Start or resume libmpv SESSION."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (when (etaf-video-mpv--session-ended session)
      (etaf-video-mpv--native-command ctx '("seek" "0" "absolute"))
      (setf (etaf-video-mpv--session-ended session) nil
            (etaf-video-mpv--session-last-pos session) 0.0))
    (etaf-video-mpv--native-set-property ctx "pause" nil)
    (setf (etaf-video-mpv--session-playing session) t)
    (etaf-video-mpv--notify session))
  t)

(defun etaf-video-mpv--session-pause (session)
  "Pause libmpv SESSION."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-set-property ctx "pause" t)
    (setf (etaf-video-mpv--session-playing session) nil
          (etaf-video-mpv--session-buffering session) nil)
    (etaf-video-mpv--notify session))
  t)

(defun etaf-video-mpv--session-toggle (session)
  "Toggle libmpv SESSION between play and pause."
  (if (etaf-video-mpv--session-playing session)
      (etaf-video-mpv--session-pause session)
    (etaf-video-mpv--session-play session)))

(defun etaf-video-mpv--session-step (session)
  "Pause libmpv SESSION and step forward one frame."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (setf (etaf-video-mpv--session-playing session) nil)
    (etaf-video-mpv--native-command ctx '("frame-step"))
    (etaf-video-mpv--notify session))
  t)

(defun etaf-video-mpv--session-step-back (session)
  "Pause libmpv SESSION and step backward one frame."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (setf (etaf-video-mpv--session-playing session) nil
          (etaf-video-mpv--session-ended session) nil)
    (etaf-video-mpv--native-command ctx '("frame-back-step"))
    (etaf-video-mpv--notify session))
  t)

(defun etaf-video-mpv--session-seek (session seconds)
  "Seek libmpv SESSION to SECONDS."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (let* ((dur (or (etaf-video-mpv--native-get-property ctx "duration" 'float)
                    (etaf-video-mpv--session-last-dur session)))
           (target (max 0.0 (if (and (numberp dur) (> dur 0))
                                (min (float seconds) dur)
                              (float seconds)))))
      (if (etaf-video-mpv--session-file-loaded session)
          (etaf-video-mpv--native-command ctx (list "seek" (format "%.3f" target) "absolute"))
        (etaf-video-mpv--native-set-property ctx "start" (format "%.3f" target)))
      (setf (etaf-video-mpv--session-last-pos session) target
            (etaf-video-mpv--session-ended session) nil)
      (etaf-video-mpv--notify session)))
  t)

(defun etaf-video-mpv--session-set-speed (session speed)
  "Set libmpv SESSION playback rate to SPEED seamlessly."
  (unless (and (numberp speed) (> speed 0))
    (user-error "Playback speed must be a positive number: %S" speed))
  (setf (etaf-video-mpv--session-speed session) speed)
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-set-property ctx "speed" (float speed)))
  (etaf-video-mpv--notify session)
  t)

(defun etaf-video-mpv--session-set-volume (session volume)
  "Set libmpv SESSION audio volume to VOLUME seamlessly."
  (unless (and (numberp volume) (<= 0 volume 100))
    (user-error "Audio volume must be between 0 and 100: %S" volume))
  (setf (etaf-video-mpv--session-volume session) volume)
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-set-property ctx "volume" (float volume)))
  (etaf-video-mpv--notify session)
  t)

(defun etaf-video-mpv--session-set-audio (session audio)
  "Enable or mute libmpv SESSION audio seamlessly."
  (setf (etaf-video-mpv--session-audio session) (and audio t))
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-set-property ctx "mute" (not audio)))
  (etaf-video-mpv--notify session)
  t)

(defun etaf-video-mpv--session-set-property (session name value)
  "Set libmpv property NAME to VALUE on SESSION."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (let ((res (etaf-video-mpv--native-set-property ctx name value)))
      (when (and (eq res t) (etaf-video-mpv--session-file-loaded session)
                 (not (etaf-video-mpv--session-playing session)))
        ;; Repaint paused frame immediately when visual/subtitle properties change.
        (when (etaf-video-mpv--native-frame-ready-p ctx)
          (etaf-video-mpv--render-frame session)))
      res)))

(defun etaf-video-mpv--session-get-property (session name &optional type)
  "Read libmpv property NAME from SESSION using optional TYPE."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-get-property ctx name (or type 'node))))

(defun etaf-video-mpv--session-command (session args)
  "Run libmpv command list ARGS on SESSION."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-command ctx (mapcar (lambda (a) (format "%s" a)) args))))

(defun etaf-video-mpv--session-state (session)
  "Return libmpv SESSION's detached state plist."
  (etaf-video-mpv--drain-events session)
  (let* ((ctx (etaf-video-mpv--session-ctx session))
         (spec (etaf-video-mpv--session-spec session))
         (pos (or (and ctx (etaf-video-mpv--native-get-property ctx "time-pos" 'float))
                  (etaf-video-mpv--session-last-pos session)
                  0.0))
         (dur (or (and ctx (etaf-video-mpv--native-get-property ctx "duration" 'float))
                  (etaf-video-mpv--session-last-dur session)
                  (plist-get spec :duration)))
         (spd (or (and ctx (etaf-video-mpv--native-get-property ctx "speed" 'float))
                  (etaf-video-mpv--session-speed session)))
         (paused (if ctx
                     (etaf-video-mpv--native-get-property ctx "pause" 'bool)
                   (not (etaf-video-mpv--session-playing session))))
         (ended (and (etaf-video-mpv--session-ended session) t))
         (playing (and (not paused) (not ended) t))
         (sfps (or (and ctx (etaf-video-mpv--native-get-property ctx "container-fps" 'float))
                   (plist-get spec :fps))))
    (setf (etaf-video-mpv--session-last-pos session) pos
          (etaf-video-mpv--session-playing session) playing)
    (when dur (setf (etaf-video-mpv--session-last-dur session) dur))
    (list :engine 'mpv
          :source (or (plist-get spec :file) (plist-get spec :url) 'demo)
          :playing playing
          :position pos
          :duration dur
          :speed spd
          :format (etaf-video-mpv--session-format session)
          :width (etaf-video-mpv--session-width session)
          :height (etaf-video-mpv--session-height session)
          :display-fps (etaf-video-mpv--session-display-fps session)
          :source-fps sfps
          :received (etaf-video-mpv--session-received session)
          :presented (etaf-video-mpv--session-presented session)
          :dropped (etaf-video-mpv--session-dropped session)
          :audio (etaf-video-mpv--session-audio session)
          :buffering (and (etaf-video-mpv--session-buffering session) t)
          :error (etaf-video-mpv--session-error session)
          :ended ended)))

(provide 'etaf-video-mpv)
;;; etaf-video-mpv.el ends here
