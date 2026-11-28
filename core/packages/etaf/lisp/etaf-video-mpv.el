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
(declare-function etaf-video-mpv--native-gpu-available-p "etaf-video-mpv" ())
(declare-function etaf-video-mpv--native-create-gpu "etaf-video-mpv" (&optional options))
(declare-function etaf-video-mpv--native-gpu-configure "etaf-video-mpv"
                  (handle title outer-x outer-y content-w content-h is-child x y w h visible &optional window-id))
(declare-function etaf-video-mpv--native-gpu-redraw "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-gpu-frame-count "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-gpu-snapshot-tiff-file "etaf-video-mpv"
                  (handle path width height))
(declare-function etaf-video-mpv--native-destroy "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-command "etaf-video-mpv" (handle args))
(declare-function etaf-video-mpv--native-set-property "etaf-video-mpv" (handle name value))
(declare-function etaf-video-mpv--native-get-property "etaf-video-mpv" (handle name &optional type))
(declare-function etaf-video-mpv--native-poll-events "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-frame-ready-p "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-render-ppm "etaf-video-mpv" (handle width height))
(declare-function etaf-video-mpv--native-render-tiff "etaf-video-mpv" (handle width height))
(declare-function etaf-video-mpv--native-render-tiff-file "etaf-video-mpv" (handle path width height))
(declare-function etaf-video-mpv--native-async-start "etaf-video-mpv" (handle prefix width height &optional max-fps))
(declare-function etaf-video-mpv--native-async-resize "etaf-video-mpv" (handle width height))
(declare-function etaf-video-mpv--native-async-take "etaf-video-mpv" (handle))
(declare-function etaf-video-mpv--native-render-canvas "etaf-video-mpv" (handle canvas width height))
(declare-function etaf-video-mpv--native-render-raw "etaf-video-mpv" (handle width height mode))
(defvar etaf-video-display-fps)

(defvar etaf-video-engine 'auto
  "Playback engine used by `etaf-video' Components: `auto', `mpv' or `ffmpeg'.
`auto' selects `mpv' on graphical frames in `image' mode when the optional
libmpv native module and shared library are available, and falls back to
`ffmpeg' otherwise.  `mpv' requires libmpv; `ffmpeg' forces the subprocess
pipeline.")

(defvar etaf-video-mpv-library nil
  "Optional explicit path to the libmpv shared library (`dylib', `so' or `dll').
When nil, the native module searches standard system library paths.")

(defconst etaf-video-mpv--native-version "2"
  "Native dynamic module ABI/content version expected by this Elisp layer.")

(defvar etaf-video-mpv--module-file nil
  "Loaded path of the `etaf-video-mpv' dynamic module, or nil.")

(defvar etaf-video-mpv--module-failed nil
  "Cons of (FILE . MTIME) when loading that `etaf-video-mpv' binary failed.")

(defun etaf-video-mpv--module-extension ()
  "Return the native dynamic module extension for the current platform."
  (pcase system-type
    ('darwin "dylib")
    ('windows-nt "dll")
    (_ "so")))

(defun etaf-video-mpv--native-cache-path ()
  "Return the unified user-cache path for the prebuilt `etaf-video-mpv' module."
  (let ((cache-root
         (or (and (boundp 'etaf-install-native-directory)
                  etaf-install-native-directory)
             (expand-file-name
              "emacs-taf/native"
              (or (let ((xdg (getenv "XDG_CACHE_HOME")))
                    (and xdg (not (string-empty-p xdg)) xdg))
                  (expand-file-name "~/.cache"))))))
    (expand-file-name
     (format "etaf-video-mpv.%s" (etaf-video-mpv--module-extension))
     (expand-file-name (concat "etaf/" etaf-video-mpv--native-version)
                       cache-root))))

(defun etaf-video-mpv--module-path ()
  "Return the `etaf-video-mpv' dynamic module path if present in checkout or cache."
  (let* ((root (or (let ((lib (ignore-errors (locate-library "etaf"))))
                     (and lib (not (string-suffix-p ".eln" lib))
                          (file-name-directory lib)))
                   (and load-file-name
                        (not (string-suffix-p ".eln" load-file-name))
                        (expand-file-name ".." (file-name-directory load-file-name)))))
         (ext (etaf-video-mpv--module-extension))
         (candidates (delq nil
                           (list (and root
                                      (expand-file-name
                                       (format "native/etaf-video-mpv.%s" ext) root))
                                 (etaf-video-mpv--native-cache-path)))))
    (cl-find-if #'file-exists-p candidates)))

(defun etaf-video-mpv--load-module ()
  "Load the optional `etaf-video-mpv' dynamic module once, or return nil."
  (cond
   (etaf-video-mpv--module-file etaf-video-mpv--module-file)
   ((fboundp 'etaf-video-mpv--native-available-p)
    (setq etaf-video-mpv--module-file (or (etaf-video-mpv--module-path) t)))
   (t
    (when-let* ((file (etaf-video-mpv--module-path))
                (mtime (file-attribute-modification-time (file-attributes file)))
                ((fboundp 'module-load))
                ((not (and (consp etaf-video-mpv--module-failed)
                           (equal (car etaf-video-mpv--module-failed) file)
                           (equal (cdr etaf-video-mpv--module-failed) mtime)))))
      (if (condition-case nil
              (progn (module-load file) t)
            (error nil))
          (progn
            (setq etaf-video-mpv--module-failed nil
                  etaf-video-mpv--module-file file)
            file)
        (setq etaf-video-mpv--module-failed (cons file mtime))
        nil)))))

;;;###autoload
(defun etaf-video-mpv-available-p ()
  "Return non-nil when the cross-platform libmpv native backend is ready."
  (and (etaf-video-mpv--load-module)
       (fboundp 'etaf-video-mpv--native-available-p)
       (etaf-video-mpv--native-available-p etaf-video-mpv-library)
       t))

(defun etaf-video-mpv--gpu-available-p ()
  "Return non-nil when the native GPU video overlay layer is ready."
  (and (not noninteractive)
       (etaf-video-mpv-available-p)
       (fboundp 'etaf-video-mpv--native-gpu-available-p)
       (fboundp 'etaf-video-mpv--native-create-gpu)
       (etaf-video-mpv--native-gpu-available-p)
       t))

(defconst etaf-video-mpv--ring-slots 12
  "Number of rotating file-backed frame slots used by `tiff-file' mode.")

(defvar etaf-video-mpv--ring-counter 0
  "Monotonic session counter for unique temporary frame-ring prefixes.")

(cl-defstruct (etaf-video-mpv--session (:constructor etaf-video-mpv--session--make))
  "A live libmpv playback session."
  ctx spec format width height display-fps speed audio volume
  timer playing ended buffering error received presented dropped
  on-frame on-state canvas-spec-fn visible-p last-pos last-dur file-loaded
  async-p sync-ring-prefix sync-ring-slot sync-ring-seq last-prop-check
  next-tick gpu-p gpu-sync-fn gpu-snapshot-path gpu-snapshot-seq)

(defun etaf-video-mpv--direct-media-url-p (spec)
  "Return non-nil when SPEC points to an already-resolved direct media stream.
Direct media streams (split `:audio-url', explicit HTTP `:headers', or known
CDN/media file paths) skip libmpv's `ytdl_hook' so transient network errors
reconnect through lavf instead of invoking `yt-dlp'."
  (let ((url (or (plist-get spec :url) (plist-get spec :target)))
        (audio-url (plist-get spec :audio-url)))
    (or (and (stringp audio-url) (> (length audio-url) 0))
        (and (plist-get spec :headers) t)
        (and (stringp url)
             (string-match-p
              (concat "\\(?:/videoplayback\\(?:[/?]\\|\\'\\)"
                      "\\|\\.\\(?:mp4\\|m4s\\|m4a\\|webm\\|mkv\\|mov\\|m3u8\\|mpd\\|ts\\|flv\\)\\(?:[?#]\\|\\'\\)\\)")
              (downcase url))))))

(defun etaf-video-mpv--session-options (spec speed audio volume start playing &optional gpu-p)
  "Build pre-initialization libmpv scalar option alist for SPEC.
When GPU-P is non-nil, omit software-scaler options so the native GPU shader
pipeline runs with zero CPU scaling overhead."
  (let ((opts (append
               (list (cons "pause" (if playing "no" "yes"))
                     (cons "mute" (if audio "no" "yes"))
                     (cons "volume" (format "%g" (max 0 (min 150 (or volume 100)))))
                     (cons "speed" (format "%g" (or speed 1)))
                     (cons "sub-ass" "yes"))
               (unless gpu-p
                 (list (cons "sws-allow-zimg" "yes")
                       (cons "zimg-scaler" "bicubic")
                       (cons "zimg-scaler-chroma" "bilinear")
                       (cons "zimg-dither" "no")
                       (cons "zimg-fast" "yes")
                       (cons "sws-scaler" "fast-bilinear")
                       (cons "sws-fast" "yes"))))))
    (when (and (numberp start) (> start 0))
      (push (cons "start" (format "%.3f" start)) opts))
    (when (or (eq (plist-get spec :kind) 'url)
              (and (stringp (plist-get spec :audio-url))
                   (> (length (plist-get spec :audio-url)) 0)))
      (push (cons "cache" "yes") opts)
      (push (cons "demuxer-readahead-secs" "20") opts)
      (push (cons "demuxer-max-bytes" "64MiB") opts)
      (push (cons "demuxer-max-back-bytes" "16MiB") opts)
      (push (cons "network-timeout" "15") opts)
      (push (cons "stream-lavf-o"
                  "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")
            opts)
      (when (etaf-video-mpv--direct-media-url-p spec)
        (push (cons "ytdl" "no") opts))
      (when-let* ((proxy (plist-get spec :proxy)))
        (when (and (stringp proxy) (> (length proxy) 0))
          (push (cons "http-proxy" proxy) opts)))
      (when-let* ((headers (plist-get spec :headers)))
        (dolist (pair (etaf-video--header-pairs headers))
          (when (string= (downcase (car pair)) "user-agent")
            (push (cons "user-agent" (cdr pair)) opts)))))
    (nreverse opts)))

(defun etaf-video-mpv--apply-list-options (ctx spec)
  "Apply list-valued HTTP headers and external audio URL to CTX for SPEC.
Uses `change-list' instead of `mpv_set_option_string' so URLs containing `:'
and headers containing `,' are never split."
  (when (or (eq (plist-get spec :kind) 'url)
            (and (stringp (plist-get spec :audio-url))
                 (> (length (plist-get spec :audio-url)) 0)))
    (when-let* ((headers (plist-get spec :headers)))
      (dolist (pair (etaf-video--header-pairs headers))
        (unless (string= (downcase (car pair)) "user-agent")
          (etaf-video-mpv--native-command
           ctx (list "change-list" "http-header-fields" "append"
                     (format "%s: %s" (car pair) (cdr pair))))))))
  (when-let* ((audio-url (plist-get spec :audio-url)))
    (when (and (stringp audio-url) (> (length audio-url) 0))
      (etaf-video-mpv--native-command
       ctx (list "change-list" "audio-files" "append" audio-url)))))

(defun etaf-video-mpv--notify (session)
  "Call SESSION's `:on-state' callback when present."
  (when-let* ((cb (etaf-video-mpv--session-on-state session)))
    (funcall cb session)))

(defun etaf-video-mpv--deliver-frame (session frame)
  "Account for rendered FRAME and deliver it to SESSION's `:on-frame'."
  (when frame
    (cl-incf (etaf-video-mpv--session-received session))
    (cl-incf (etaf-video-mpv--session-presented session))
    (setf (etaf-video-mpv--session-buffering session) nil)
    (when-let* ((cb (etaf-video-mpv--session-on-frame session)))
      (funcall cb frame session))))

(defun etaf-video-mpv--render-frame (session)
  "Render one frame from SESSION synchronously and deliver it to `:on-frame'."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (unless (etaf-video-mpv--session-async-p session)
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
                ('tiff-file
                 (when-let* ((prefix (etaf-video-mpv--session-sync-ring-prefix session)))
                   (let* ((slot (or (etaf-video-mpv--session-sync-ring-slot session) 0))
                          (seq (1+ (or (etaf-video-mpv--session-sync-ring-seq session) 0)))
                          (path (format "%s-%d.tif" prefix slot)))
                     (when (etaf-video-mpv--native-render-tiff-file ctx path w h)
                       (setf (etaf-video-mpv--session-sync-ring-slot session)
                             (% (1+ slot) etaf-video-mpv--ring-slots)
                             (etaf-video-mpv--session-sync-ring-seq session) seq)
                       (list slot path seq)))))
                ('tiff (etaf-video-mpv--native-render-tiff ctx w h))
                ('ppm (etaf-video-mpv--native-render-ppm ctx w h))
                ('rgb24 (etaf-video-mpv--native-render-raw ctx w h 'rgb24))
                (_ (etaf-video-mpv--native-render-raw ctx w h 'gray)))))
        (etaf-video-mpv--deliver-frame session frame)))))

(defun etaf-video-mpv--drain-events (session &optional force-props)
  "Process pending libmpv events and EOF/buffering transitions on SESSION.
When FORCE-PROPS is nil, throttle synchronous `eof-reached' and
`paused-for-cache' property queries to 4 Hz so normal frame ticks avoid
repeated cross-thread libmpv lock acquisitions."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (let ((changed nil)
          (had-event nil))
      (dolist (ev (etaf-video-mpv--native-poll-events ctx))
        (setq had-event t)
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
           (when (> (etaf-video-mpv--session-presented session) 0)
             (setf (etaf-video-mpv--session-buffering session) nil))
           (setq changed t))))
      (let ((now (float-time))
            (last (or (etaf-video-mpv--session-last-prop-check session) 0.0)))
        (when (or force-props had-event (>= (- now last) 0.25))
          (setf (etaf-video-mpv--session-last-prop-check session) now)
          (let* ((loaded (etaf-video-mpv--session-file-loaded session))
                 (eof (and loaded
                           (etaf-video-mpv--native-get-property ctx "eof-reached" 'bool)))
                 (pfc (etaf-video-mpv--native-get-property ctx "paused-for-cache" 'bool))
                 (seeking (etaf-video-mpv--native-get-property ctx "seeking" 'bool)))
            (when (and eof (not (etaf-video-mpv--session-ended session)))
              (setf (etaf-video-mpv--session-ended session) t
                    (etaf-video-mpv--session-playing session) nil
                    (etaf-video-mpv--session-buffering session) nil)
              (setq changed t))
            (let* ((ended (etaf-video-mpv--session-ended session))
                   (err (etaf-video-mpv--session-error session))
                   (playing (etaf-video-mpv--session-playing session))
                   (awaiting-first
                    (and (not ended) (not err)
                         (or (not loaded)
                             (zerop (etaf-video-mpv--session-presented session)))))
                   (effective-buf
                    (and (not ended) (not err)
                         (or awaiting-first
                             (and playing (or pfc seeking))))))
              (unless (eq (and effective-buf t)
                          (and (etaf-video-mpv--session-buffering session) t))
                (setf (etaf-video-mpv--session-buffering session)
                      (and effective-buf t))
                (setq changed t))))))
      (when changed
        (etaf-video-mpv--notify session)))))

(defun etaf-video-mpv--schedule-tick (session delay)
  "Schedule SESSION's next one-shot display tick after DELAY seconds."
  (when-let* ((old (etaf-video-mpv--session-timer session)))
    (cancel-timer old)
    (setf (etaf-video-mpv--session-timer session) nil))
  (when (etaf-video-mpv--session-ctx session)
    (setf (etaf-video-mpv--session-timer session)
          (run-at-time (max 0.004 delay) nil #'etaf-video-mpv--tick session))))

(defun etaf-video-mpv--gpu-schedule-redraw (session &optional delay)
  "Request an immediate (and optional delayed) GPU repaint on SESSION."
  (when (and (etaf-video-mpv--session-gpu-p session)
             (etaf-video-mpv--session-ctx session))
    (etaf-video-mpv--native-gpu-redraw (etaf-video-mpv--session-ctx session))
    (when (and (numberp delay) (> delay 0))
      (run-at-time delay nil
                   (lambda (sess)
                     (when-let* ((c (etaf-video-mpv--session-ctx sess)))
                       (when (etaf-video-mpv--session-gpu-p sess)
                         (etaf-video-mpv--native-gpu-redraw c))))
                   session))))

(defun etaf-video-mpv--session-gpu-configure
    (session title outer-x outer-y content-w content-h is-child x y w h visible
             &optional window-id)
  "Update SESSION's native GPU overlay geometry and visibility."
  (when (and (etaf-video-mpv--session-gpu-p session)
             (etaf-video-mpv--session-ctx session))
    (if window-id
        (etaf-video-mpv--native-gpu-configure
         (etaf-video-mpv--session-ctx session)
         title (float outer-x) (float outer-y) (float content-w) (float content-h)
         (and is-child t) (float x) (float y) (float w) (float h) (and visible t)
         window-id)
      (etaf-video-mpv--native-gpu-configure
       (etaf-video-mpv--session-ctx session)
       title (float outer-x) (float outer-y) (float content-w) (float content-h)
       (and is-child t) (float x) (float y) (float w) (float h) (and visible t)))))

(defun etaf-video-mpv--session-gpu-snapshot (session width height)
  "Capture one crisp RGB24 TIFF snapshot from GPU SESSION as `(PATH . SEQ)'."
  (when (and (etaf-video-mpv--session-gpu-p session)
             (etaf-video-mpv--session-ctx session)
             (fboundp 'etaf-video-mpv--native-gpu-snapshot-tiff-file))
    (let* ((seq (1+ (or (etaf-video-mpv--session-gpu-snapshot-seq session) 0)))
           (path (or (etaf-video-mpv--session-gpu-snapshot-path session)
                     (let ((p (expand-file-name
                               (format "etaf-mpv-snap-%d-%d.tif"
                                       (emacs-pid)
                                       (cl-incf etaf-video-mpv--ring-counter))
                               temporary-file-directory)))
                       (setf (etaf-video-mpv--session-gpu-snapshot-path session) p)
                       p))))
      (when (etaf-video-mpv--native-gpu-snapshot-tiff-file
             (etaf-video-mpv--session-ctx session)
             path (max 1 width) (max 1 height))
        (setf (etaf-video-mpv--session-gpu-snapshot-seq session) seq)
        (cons path seq)))))

(defun etaf-video-mpv--tick (session)
  "Adaptive one-shot display timer tick for libmpv SESSION."
  (setf (etaf-video-mpv--session-timer session) nil)
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (if (etaf-video-mpv--session-gpu-p session)
        (let* ((vis-fn (etaf-video-mpv--session-visible-p session))
               (visible (or (null vis-fn) (funcall vis-fn))))
          (etaf-video-mpv--drain-events session)
          (when-let* ((live-ctx (etaf-video-mpv--session-ctx session)))
            (when (etaf-video-mpv--session-file-loaded session)
              (let ((frames (etaf-video-mpv--native-gpu-frame-count live-ctx)))
                (when (> frames (etaf-video-mpv--session-presented session))
                  (let ((was-buf (etaf-video-mpv--session-buffering session)))
                    (setf (etaf-video-mpv--session-received session) frames
                          (etaf-video-mpv--session-presented session) frames
                          (etaf-video-mpv--session-buffering session) nil)
                    (when was-buf
                      (etaf-video-mpv--notify session))))))
            (when-let* ((sync-fn (etaf-video-mpv--session-gpu-sync-fn session)))
              (ignore-errors (funcall sync-fn)))
            (let ((delay
                   (cond
                    ((not visible) 0.25)
                    ((and (not (etaf-video-mpv--session-playing session))
                          (etaf-video-mpv--session-file-loaded session))
                     0.25)
                    ((zerop (etaf-video-mpv--session-presented session))
                     0.05)
                    (t 0.15))))
              (etaf-video-mpv--schedule-tick session delay))))
      (let* ((t0 (float-time))
             (vis-fn (etaf-video-mpv--session-visible-p session))
             (visible (or (null vis-fn) (funcall vis-fn)))
             (presented nil))
        (etaf-video-mpv--drain-events session)
        (when (and visible (etaf-video-mpv--session-ctx session))
          (if (etaf-video-mpv--session-async-p session)
              (when-let* ((frame (etaf-video-mpv--native-async-take ctx)))
                (setq presented t)
                (etaf-video-mpv--deliver-frame session frame))
            (when (etaf-video-mpv--native-frame-ready-p ctx)
              (setq presented t)
              (etaf-video-mpv--render-frame session))))
        (when (etaf-video-mpv--session-ctx session)
          (let* ((now (float-time))
                 (rate (max 1 (or (etaf-video-mpv--session-display-fps session) 24)))
                 (delay
                  (cond
                   ((not visible)
                    (setf (etaf-video-mpv--session-next-tick session) nil)
                    0.20)
                   ((and (not (etaf-video-mpv--session-playing session))
                         (etaf-video-mpv--session-file-loaded session))
                    (setf (etaf-video-mpv--session-next-tick session) nil)
                    0.10)
                   (presented
                    (let* ((interval (/ 1.0 rate))
                           (base (or (etaf-video-mpv--session-next-tick session) t0))
                           (target (+ base interval))
                           (floor (+ now 0.010)))
                      (when (< target floor)
                        (setq target floor))
                      (setf (etaf-video-mpv--session-next-tick session) target)
                      (- target now)))
                   (t
                    (setf (etaf-video-mpv--session-next-tick session) nil)
                    (max 0.012 (/ 0.5 rate))))))
            (etaf-video-mpv--schedule-tick session delay)))))))

(cl-defun etaf-video-mpv--session-create
    (spec &key (format 'ppm) width height (speed 1) fps (start 0)
          (audio nil) (volume 100) (playing t) on-frame on-state
          canvas-spec-fn visible-p gpu-sync-fn)
  "Create and start a libmpv playback session for normalized SPEC."
  (unless (etaf-video-mpv-available-p)
    (user-error "libmpv is not available; run M-x etaf-install-native (select etaf) and install libmpv"))
  (let* ((target (or (plist-get spec :target)
                     (plist-get spec :file)
                     (plist-get spec :url)))
         (want-gpu (and (eq format 'gpu) (etaf-video-mpv--gpu-available-p)))
         (gpu-p nil)
         (ctx (when want-gpu
                (etaf-video-mpv--native-create-gpu
                 (etaf-video-mpv--session-options
                  spec speed audio volume start playing t))))
         (eff-format format))
    (if ctx
        (setq gpu-p t
              eff-format 'gpu)
      (when want-gpu
        (setq eff-format (if (image-type-available-p 'tiff) 'tiff-file 'ppm)))
      (setq ctx (etaf-video-mpv--native-create
                 (etaf-video-mpv--session-options
                  spec speed audio volume start playing nil))))
    (unless target
      (when ctx (etaf-video-mpv--native-destroy ctx))
      (user-error "libmpv backend requires a local file or HTTP(S) URL source"))
    (unless ctx
      (user-error "Failed to initialize libmpv playback context"))
    (let* ((w (max 1 (or width 640)))
           (h (max 1 (or height 360)))
           (default-fps (or (and (boundp 'etaf-video-display-fps)
                                 (numberp etaf-video-display-fps)
                                 etaf-video-display-fps)
                            24))
           (rate (max 1 (round (or fps default-fps))))
           (async-p nil)
           (sync-prefix nil))
      (when (and (not gpu-p) (eq eff-format 'tiff-file))
        (let ((prefix (expand-file-name
                       (format "etaf-mpv-%d-%d"
                               (emacs-pid)
                               (cl-incf etaf-video-mpv--ring-counter))
                       temporary-file-directory)))
          (cond
           ((and (fboundp 'etaf-video-mpv--native-async-start)
                 (etaf-video-mpv--native-async-start
                  ctx prefix w h (max 1 (+ rate 1))))
            (setq async-p t))
           ((fboundp 'etaf-video-mpv--native-render-tiff-file)
            (setq sync-prefix prefix))
           (t
            (setq eff-format 'tiff)))))
      (let ((session (etaf-video-mpv--session--make
                      :ctx ctx :spec spec :format eff-format
                      :width w :height h
                      :display-fps rate
                      :speed speed :audio (and audio t) :volume volume
                      :playing (and playing t)
                      :buffering (and playing t)
                      :received 0 :presented 0 :dropped 0
                      :on-frame on-frame :on-state on-state
                      :canvas-spec-fn canvas-spec-fn
                      :visible-p visible-p
                      :gpu-p gpu-p
                      :gpu-sync-fn gpu-sync-fn
                      :async-p async-p
                      :sync-ring-prefix sync-prefix
                      :sync-ring-slot 0 :sync-ring-seq 0
                      :last-prop-check 0.0
                      :last-pos (float (or start 0))
                      :last-dur (plist-get spec :duration))))
        (etaf-video-mpv--apply-list-options ctx spec)
        (etaf-video-mpv--native-command ctx (list "loadfile" target))
        (etaf-video-mpv--schedule-tick session (if gpu-p 0.030 0.010))
        session))))

(defun etaf-video-mpv--session-destroy (session)
  "Stop SESSION's timer and destroy its native libmpv context."
  (when-let* ((timer (etaf-video-mpv--session-timer session)))
    (cancel-timer timer)
    (setf (etaf-video-mpv--session-timer session) nil))
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-destroy ctx)
    (setf (etaf-video-mpv--session-ctx session) nil))
  (when-let* ((snap (etaf-video-mpv--session-gpu-snapshot-path session)))
    (ignore-errors (delete-file snap))
    (setf (etaf-video-mpv--session-gpu-snapshot-path session) nil))
  (when-let* ((prefix (etaf-video-mpv--session-sync-ring-prefix session)))
    (dotimes (i etaf-video-mpv--ring-slots)
      (ignore-errors (delete-file (format "%s-%d.tif" prefix i))))
    (setf (etaf-video-mpv--session-sync-ring-prefix session) nil))
  t)

(defun etaf-video-mpv--session-resize (session width height)
  "Resize SESSION's render output to WIDTH by HEIGHT in place without restarting."
  (let ((w (max 1 width))
        (h (max 1 height)))
    (setf (etaf-video-mpv--session-width session) w
          (etaf-video-mpv--session-height session) h)
    (cond
     ((etaf-video-mpv--session-gpu-p session)
      (when-let* ((sync-fn (etaf-video-mpv--session-gpu-sync-fn session)))
        (ignore-errors (funcall sync-fn)))
      (etaf-video-mpv--gpu-schedule-redraw session 0.016))
     ((etaf-video-mpv--session-async-p session)
      (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
        (etaf-video-mpv--native-async-resize ctx w h)
        (etaf-video-mpv--schedule-tick session 0.012)))
     (t
      (when (etaf-video-mpv--session-file-loaded session)
        (etaf-video-mpv--render-frame session)))))
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
    (etaf-video-mpv--schedule-tick session 0.008)
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
    (etaf-video-mpv--gpu-schedule-redraw session 0.025)
    (etaf-video-mpv--schedule-tick session 0.012)
    (etaf-video-mpv--notify session))
  t)

(defun etaf-video-mpv--session-step-back (session)
  "Pause libmpv SESSION and step backward one frame."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (setf (etaf-video-mpv--session-playing session) nil
          (etaf-video-mpv--session-ended session) nil)
    (etaf-video-mpv--native-command ctx '("frame-back-step"))
    (etaf-video-mpv--gpu-schedule-redraw session 0.025)
    (etaf-video-mpv--schedule-tick session 0.012)
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
      (when (and (eq (plist-get (etaf-video-mpv--session-spec session) :kind) 'url)
                 (etaf-video-mpv--session-playing session))
        (setf (etaf-video-mpv--session-buffering session) t))
      (etaf-video-mpv--gpu-schedule-redraw session 0.030)
      (etaf-video-mpv--schedule-tick session 0.012)
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
        (cond
         ((etaf-video-mpv--session-gpu-p session)
          (etaf-video-mpv--gpu-schedule-redraw session 0.030))
         ((etaf-video-mpv--session-async-p session)
          (etaf-video-mpv--native-async-resize
           ctx
           (max 1 (etaf-video-mpv--session-width session))
           (max 1 (etaf-video-mpv--session-height session)))
          (etaf-video-mpv--schedule-tick session 0.012))
         ((etaf-video-mpv--native-frame-ready-p ctx)
          (etaf-video-mpv--render-frame session))))
      res)))

(defun etaf-video-mpv--session-get-property (session name &optional type)
  "Read libmpv property NAME from SESSION using optional TYPE."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (etaf-video-mpv--native-get-property ctx name (or type 'node))))

(defun etaf-video-mpv--session-command (session args)
  "Run libmpv command list ARGS on SESSION."
  (when-let* ((ctx (etaf-video-mpv--session-ctx session)))
    (let* ((str-args (mapcar (lambda (a) (format "%s" a)) args))
           (res (etaf-video-mpv--native-command ctx str-args)))
      (when (and (eql res 0)
                 (etaf-video-mpv--session-file-loaded session)
                 (not (etaf-video-mpv--session-playing session))
                 (member (car str-args) '("sub-add" "sub-remove" "sub-reload")))
        (cond
         ((etaf-video-mpv--session-gpu-p session)
          (etaf-video-mpv--gpu-schedule-redraw session 0.035))
         ((etaf-video-mpv--session-async-p session)
          (etaf-video-mpv--native-async-resize
           ctx
           (max 1 (etaf-video-mpv--session-width session))
           (max 1 (etaf-video-mpv--session-height session)))
          (etaf-video-mpv--schedule-tick session 0.012))
         ((etaf-video-mpv--native-frame-ready-p ctx)
          (etaf-video-mpv--render-frame session))))
      res)))

(defun etaf-video-mpv--session-state (session)
  "Return libmpv SESSION's detached state plist."
  (etaf-video-mpv--drain-events session t)
  (let* ((ctx (etaf-video-mpv--session-ctx session))
         (spec (etaf-video-mpv--session-spec session)))
    (when (and ctx (etaf-video-mpv--session-gpu-p session)
               (etaf-video-mpv--session-file-loaded session))
      (let ((frames (etaf-video-mpv--native-gpu-frame-count ctx)))
        (when (> frames (etaf-video-mpv--session-presented session))
          (setf (etaf-video-mpv--session-received session) frames
                (etaf-video-mpv--session-presented session) frames
                (etaf-video-mpv--session-buffering session) nil))))
    (let* ((pos (or (and ctx (etaf-video-mpv--native-get-property ctx "time-pos" 'float))
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
            :ended ended))))

(provide 'etaf-video-mpv)
;;; etaf-video-mpv.el ends here
