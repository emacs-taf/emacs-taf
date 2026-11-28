;;; etaf-media.el --- Native video playback and media engine for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.20") (ebox "3.1.15"))
;; Keywords: multimedia, ui, tools
;; URL: https://github.com/emacs-taf/etaf

;;; Commentary:

;; Native video playback, libmpv/ffmpeg session engine, hardware GPU overlay
;; layer and the `etaf-video' Component for ETAF applications.
;;
;; Public API
;;
;; Load this package with (require 'etaf-media) after adding the repository
;; root to `load-path'.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; implementations and precise
;; docstrings remain beside their definitions.  The ETAF Reference Manual contains workflows.
;;
;; Component: etaf-video (&key src (columns 100) (rows 30) (mode 'image) (ramp etaf-video-density-ramp) (audio etaf-video-audio) (volume etaf-video-audio-volume) (speed 1) (autoplay t) handle device-pixel-ratio display-fps position left top z-index)
;; Render a live video source in a fixed COLUMNS by ROWS canvas.
;;
;; SRC is nil for the built-in demo, a local file name, an HTTP(S) URL, or a
;; plist accepted by the video source normalizer.  A plist may name separate
;; video and audio streams with `:audio-url' and carry `:headers' and
;; `:proxy' for authenticated playback; `etaf-video-source-info' documents
;; the normalized keys.  MODE is `image' (one scaled
;; JPEG per frame, graphical frames only, falling back to `ascii' elsewhere),
;; `ascii' (one density-ramp character per pixel) or `color' (two full-color
;; pixels per `▀' half-block cell).  RAMP defaults to
;; `etaf-video-density-ramp', AUDIO/VOLUME/SPEED configure playback, and
;; AUTOPLAY starts it at mount; without AUTOPLAY the first frame is shown
;; paused.  DEVICE-PIXEL-RATIO overrides the display's device pixel ratio for
;; `image' frames so Retina screens stay sharp.  DISPLAY-FPS is nil (use
;; `etaf-video-display-fps') or a positive integer presentation-rate cap.
;; `etaf-video-render-backend' selects how a graphical frame reaches the
;; screen: `auto' (the default) prefers the native hardware `gpu' video layer
;; (macOS `CAOpenGLLayer', Windows Win32/WGL, Linux X11/Wayland EGL) when
;; `libmpv' and the platform GPU surface are available in a live graphical
;; frame (giving browser-grade low-CPU playback without recompiling Emacs),
;; then `canvas' if the `canvas' image type and `native/etaf-video-canvas' are
;; built, and falls back to `image'.  `gpu', `canvas' and `image' select a
;; specific backend; missing capabilities silently keep the `image' path, so an
;; application runs unchanged on released Emacs versions.  `ascii' and `color'
;; modes ignore this setting.
;; Image frames share one image across row-height slices so adjacent content
;; and controls below the canvas retain their normal line heights.  POSITION,
;; LEFT, TOP and Z-INDEX place the canvas; they are declared on the canvas node
;; itself so the retained content route can prove an inline placement winner
;; even when the canvas sits deep in an application layout.
;; AUDIO, VOLUME and SPEED also accept refs/computed sources; the Component
;; reads them in its playback effect, not its View. Live volume must stay
;; within 0..100 and speed must remain positive. Their identity can stay fixed
;; while a shared UI control updates the value without rebuilding the shell.
;;
;; HANDLE is a symbol registered while mounted for the `etaf-video-play'
;; family of control functions; a video without a handle still plays itself.
;;
;; Function: etaf-video-play (handle)
;;;###autoload (autoload 'etaf-video-play "etaf-media" nil nil)
;; Start or resume the mounted video identified by HANDLE.
;;
;; Function: etaf-video-pause (handle)
;;;###autoload (autoload 'etaf-video-pause "etaf-media" nil nil)
;; Pause the mounted video identified by HANDLE, keeping the last picture.
;;
;; Function: etaf-video-toggle-playback (handle)
;;;###autoload (autoload 'etaf-video-toggle-playback "etaf-media" nil nil)
;; Toggle the mounted video identified by HANDLE between play and pause.
;;
;; Function: etaf-video-step (handle)
;;;###autoload (autoload 'etaf-video-step "etaf-media" nil nil)
;; Pause the mounted video identified by HANDLE and present one more frame.
;;
;; Function: etaf-video-step-back (handle)
;;;###autoload (autoload 'etaf-video-step-back "etaf-media" nil nil)
;; Pause the mounted video identified by HANDLE and step backward one frame.
;; On libmpv this steps backward frame-accurately; on ffmpeg it seeks back 1s.
;;
;; Function: etaf-video-seek (handle seconds)
;;;###autoload (autoload 'etaf-video-seek "etaf-media" nil nil)
;; Move the mounted video identified by HANDLE to SECONDS.  A playing video
;; continues from there; a paused video presents that frame and stays paused.
;;
;; Function: etaf-video-set-speed (handle speed)
;;;###autoload (autoload 'etaf-video-set-speed "etaf-media" nil nil)
;; Set the playback rate of the mounted video identified by HANDLE.
;;
;; Function: etaf-video-set-volume (handle volume)
;;;###autoload (autoload 'etaf-video-set-volume "etaf-media" nil nil)
;; Set the audio volume of the mounted video identified by HANDLE, 0 to 100.
;;
;; Function: etaf-video-set-audio (handle audio)
;;;###autoload (autoload 'etaf-video-set-audio "etaf-media" nil nil)
;; Turn the audio sidecar of the mounted video identified by HANDLE on or off.
;;
;; Function: etaf-video-set-property (handle name value)
;;;###autoload (autoload 'etaf-video-set-property "etaf-media" nil nil)
;; Set playback engine property NAME to VALUE on mounted video HANDLE.
;; Supported on the libmpv engine; returns nil on engines without properties.
;;
;; Function: etaf-video-get-property (handle name &optional type)
;;;###autoload (autoload 'etaf-video-get-property "etaf-media" nil nil)
;; Read playback engine property NAME from mounted video HANDLE.
;; TYPE is `node' (default), `string', `bool', `int' or `float'.
;;
;; Function: etaf-video-command (handle &rest args)
;;;###autoload (autoload 'etaf-video-command "etaf-media" nil nil)
;; Send engine command ARGS to mounted video HANDLE (libmpv engine).
;;
;; Function: etaf-video-mpv-available-p ()
;;;###autoload (autoload 'etaf-video-mpv-available-p "etaf-media" nil nil)
;; Return non-nil when the cross-platform libmpv native backend is available.
;;
;; Function: etaf-video-gpu-available-p ()
;;;###autoload (autoload 'etaf-video-gpu-available-p "etaf-media" nil nil)
;; Return non-nil when the native hardware GPU video layer is available.
;;
;; Function: etaf-video-source-info (source)
;;;###autoload (autoload 'etaf-video-source-info "etaf-media" nil nil)
;; Return SOURCE's normalized playback metadata as a plist.
;;
;; SOURCE is nil for the built-in demo, a local file name, an HTTP(S) URL, or
;; a plist accepted by the `etaf-video' Component.  A local file name may
;; start with `~' or be relative to `default-directory'; it is expanded to an
;; absolute `:file' and `:target' before the decoders run.  The result holds
;; `:kind', `:file', `:url', `:target', `:audio-url', `:audio-target',
;; `:headers', `:proxy', `:width', `:height', `:duration', `:fps' and
;; `:audio'.  A source
;; whose video and audio are separate HTTP(S) streams describes them with
;; `:audio-url'; `:headers' (an alist, a hash table or one `Name: value'
;; string) and `:proxy' apply to every request both decoders make.  A present
;; `:audio-url' implies `:audio'.  Values come from ffprobe when it runs; a
;; missing ffprobe keeps documented defaults.  The result is authoritative
;; metadata and can be passed back as the Component's `:src' without another
;; probe, so an application that resizes or restarts a video keeps them.
;; Unsupported sources, unreadable files and malformed network options signal
;; `user-error'.
;;
;; Function: etaf-video-state (handle)
;;;###autoload (autoload 'etaf-video-state "etaf-media" nil nil)
;; Return the mounted video identified by HANDLE as a detached plist.
;; Keys are `:handle', `:engine', `:render-backend', `:mode', `:source',
;; `:playing', `:position', `:duration', `:speed', `:format', `:width',
;; `:height', `:display-fps', `:source-fps', `:received', `:presented',
;; `:dropped', `:audio', `:buffering', `:error' and `:ended'.  A handle with
;; no mounted video signals `user-error'.
;;
;; Variable: etaf-video-audio
;; Whether new videos play their source's audio track by default.
;; A `etaf-video' Component's `:audio' property overrides it per instance.
;;
;; Variable: etaf-video-audio-volume
;; Default audio volume for new videos, from 0 to 100.
;;
;; Variable: etaf-video-density-ramp
;; Characters used for one video pixel in the `ascii' render mode,
;; from darkest to lightest; must be nonempty and single-line.
;;
;; Variable: etaf-video-display-fps
;; Display timer rate in frames per second for new video playback.
;; It caps the presented frame rate; values below 1 are raised to 1.
;;
;; Variable: etaf-video-render-backend
;; Rendering backend for `etaf-video' playback: `auto' (default), `gpu',
;; `canvas', `kitty' or `image'.
;; `auto' prefers the native hardware `gpu' video layer when `libmpv' and the
;; platform GPU surface are ready on a live graphical frame (macOS
;; `CAOpenGLLayer', Windows Win32/WGL, Linux X11/Wayland EGL), then `canvas'
;; when Emacs supports canvas images and `native/etaf-video-canvas' is built,
;; and falls back to `image'; on compliant 24-bit text terminals `auto' uses
;; `kitty' Unicode placeholder streaming in `image' mode.  `gpu' requests the
;; native GPU overlay and falls back to `image' when unavailable.  `canvas'
;; reads BGRA frames into one Emacs canvas image in place.  `kitty' requests
;; Kitty terminal graphics on text frames.  `image' forces the pure-Emacs
;; image frame pipeline (file-backed TIFF ring under `libmpv', JPEG under
;; `ffmpeg').  Missing capabilities fall back cleanly.  `ascii' and `color'
;; modes ignore this setting.
;;
;; Variable: etaf-video-engine
;; Playback engine for `etaf-video': `auto' (default), `mpv' or `ffmpeg'.
;; `auto' uses the optional cross-platform libmpv native module on graphical
;; frames in `image' mode and falls back to `ffmpeg' otherwise.
;;
;; Variable: etaf-video-mpv-library
;; Optional explicit path to the libmpv shared library (`dylib', `so' or `dll').
;;
;; Variable: etaf-video-ffmpeg-program
;; Name or absolute path of the ffmpeg executable used to decode video.
;;
;; Variable: etaf-video-ffplay-program
;; Name or absolute path of the ffplay executable used for audio.
;;
;; Variable: etaf-video-ffprobe-program
;; Name or absolute path of the ffprobe executable used for metadata.
;;
;;; Code:

(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-media")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-media.el" dir))
                                (file-exists-p (expand-file-name "etaf-media.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf)
(require 'ebox)
(require 'etaf-media-source)
(require 'etaf-media-audio)
(require 'etaf-media-mpv)
(require 'etaf-media-session)
(require 'etaf-media-video)

(provide 'etaf-media)
;;; etaf-media.el ends here
