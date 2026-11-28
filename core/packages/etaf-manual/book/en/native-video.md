# Native Video

Native video playback lives in the `etaf-media` package (`(require 'etaf-media)`). A video is an ordinary Component whose canvas shows live frames instead of text the application re-renders. The canvas has a fixed cell size, a playback session behind it owns the frame producer and the optional audio sidecar, and each presented frame updates only the canvas Host through the retained content route — so a running video never pays for a full application render. Frames come from a local file, an HTTP(S) stream, the built-in test pattern or a metadata plist that was probed once; audio is off unless it is asked for; and the decoder, metadata prober and audio player are external programs that can be replaced per variable. This chapter defines the canvas Component, the source metadata, the playback handle, the callbacks a session reports, the render modes and their presentation rules, the audio sidecar, and what happens when an external program is missing. [Runtime](runtime.md) defines the retained Host content update each frame uses; [Installation and Loading](installation-and-loading.md) lists the optional programs and the degradation each one causes.

## The video canvas

<!-- index: etaf-video; video canvas; render mode; autoplay; handle; device pixel ratio -->

The `etaf-video` Component renders one video source into a fixed `COLUMNS` by `ROWS` cell canvas. A mounted Component starts a playback session: the session decodes the source into frames, keeps only the newest complete frame for the display timer, and hands each presented frame to the canvas. The canvas is a normal box in the surrounding layout; the placement properties are declared on the canvas node itself, and unpublished space is hidden rather than reflowed, so a video keeps its intrinsic cell size next to ordinary siblings.

`mode` chooses how one frame becomes canvas text. `image` shows one scaled JPEG per frame as an image cell and needs the buffer to be displayed in a graphical frame; anywhere else it falls back to `ascii`, so a layout written for one environment still renders in the other. `ascii` maps each pixel to one density-ramp character, and `color` shows two full-color pixels per `▀` half-block cell. The canvas text is the same number of lines in every mode, which is what lets application chrome sit below the video.

#### Component: etaf-video (&key src (columns 100) (rows 30) (mode 'image) (ramp etaf-video-density-ramp) (audio etaf-video-audio) (volume etaf-video-audio-volume) (speed 1) (autoplay t) handle device-pixel-ratio display-fps position left top z-index)

Render a live video source in a fixed COLUMNS by ROWS canvas.

**Arguments.** SRC is nil for the built-in demo, a local file name, an HTTP(S) URL, or a source plist (see `etaf-video-source-info`). COLUMNS and ROWS are the canvas size in character cells and default to 100 and 30. MODE is `image`, `ascii` or `color`. RAMP is the density ramp for `ascii` and defaults to `etaf-video-density-ramp`. AUDIO, VOLUME and SPEED configure playback and default to `etaf-video-audio`, `etaf-video-audio-volume` and 1. AUTOPLAY starts playback when the Component mounts; with nil the first frame is shown paused. DISPLAY-FPS is nil or a positive integer and defaults to `etaf-video-display-fps`. DEVICE-PIXEL-RATIO is nil or a positive number and defaults to the display's scale factor. HANDLE is a symbol that registers the mounted video for the `etaf-video-play` family. POSITION, LEFT, TOP and Z-INDEX place the canvas.

**Semantics.** Mounting creates the playback session, registers HANDLE, and either plays or presents the first frame. A change to SRC, COLUMNS, ROWS, MODE, RAMP, DEVICE-PIXEL-RATIO or DISPLAY-FPS rebuilds the session: at the current position, or from the beginning for a new SRC, and a paused session stays paused. A source that had ended and is shown paused is rebuilt one frame before its end so a size change redraws the last picture at the new size. AUDIO, VOLUME and SPEED may each be a ref or computed value; changing them updates the running session in place without rebuilding the canvas, and their identity can stay fixed while a shared control updates the value. Each presented frame updates the canvas Host's content directly; the old frame image is released after the new one is committed. Unmounting stops the producer and the audio sidecar, releases the frame cache and unregisters HANDLE.

**Returns.** A View.

**Errors.** A prop outside its contract signals `etaf-component-call-error` naming the property and the expected value; the nine checked properties are COLUMNS, ROWS, MODE, RAMP, VOLUME, SPEED, HANDLE, DISPLAY-FPS and DEVICE-PIXEL-RATIO. A handle already mounted by another video signals `user-error` with `"An etaf-video is already mounted for handle %s"`. An unusable SRC signals `user-error` as `etaf-video-source-info` describes, before any decoder starts. A missing decoder signals `user-error` with `"ffmpeg is not available: %s"`. When a canvas update fails while playing, the session is destroyed and the failure is written to `*Messages*`; the last picture stays on the canvas.

**Example.** A paused terminal-friendly canvas.

```elisp
(etaf-video :src nil :mode 'ascii :columns 40 :rows 12
            :handle 'player :autoplay nil)
```

**See also.** `etaf-video-source-info`, `etaf-video-play`, `etaf-video-state`.

## Sources and metadata

<!-- index: etaf-video-source-info; source kinds; probe defaults; normalized metadata -->

A source is described once and then used by value: probing returns a plist that the Component accepts directly, so an application that reads dimensions or duration before mounting does not probe twice. A video source may split its video and audio into two HTTP(S) streams, and carries request headers and a proxy for authenticated playback.

#### Function: etaf-video-source-info (source)

Return SOURCE's normalized playback metadata as a plist.

**Arguments.** SOURCE is nil for the built-in demo, a local file name, an HTTP(S) URL string, or a plist with `:file`, `:url` or `:demo`. A local file name may start with `~` or be relative to `default-directory`; it is expanded with `expand-file-name` before probing. A `:url` source may also name a separate audio stream with `:audio-url` and carry `:headers` (an alist, a hash table or one `Name: value' string) and `:proxy' for network access. A plist that already carries `:kind` is treated as authoritative metadata, which is what this function returns.

**Semantics.** The result holds `:kind` (`file`, `url` or `demo`), `:file`, `:url`, `:target` (the video stream ffmpeg opens), `:audio-url`, `:audio-target` (the stream the audio sidecar opens, falling back to `:target`), `:headers`, `:proxy`, `:width`, `:height`, `:duration`, `:fps` (the source frame rate) and `:audio` (whether the source reports an audio stream; a present `:audio-url` implies one). Only the video stream is probed, never the audio URL, and the probe carries the same `:headers` and `:proxy`. A missing prober keeps the documented defaults of 640 by 360 at 25 frames per second with no duration and no audio. The demo needs no program and reports 640 by 360, 30 frames per second and 30 seconds. An authoritative plist is copied as given, so its missing keys stay nil rather than being filled with defaults, except `:audio-target` and the `:audio` a present `:audio-url` implies. Each call probes; the result can be passed back later without another probe.

**Returns.** The metadata plist.

**Errors.** `error→ user-error` with `"Unsupported etaf-video source kind: %S"` for a `:kind` other than the three, `"Unsupported etaf-video source: %S"` for a value that is not a string, a source plist or nil, `"Video file is not readable: %S"` when a file is missing or unreadable, `"Video URL must be http or https: %S"` when a `:url` entry is not an HTTP(S) URL, `"Video audio URL must be http or https: %S"` when `:audio-url` is not, `"Video proxy must be an http or https URL: %S"` when `:proxy` is not, and `"Video header line is malformed: %S"`, `"Video headers must be name and value strings: %S"` or `"Video header names and values must not contain control characters: %S"` for a malformed header entry. A bare string that is neither an HTTP(S) URL nor a readable file is treated as a file name and reports the file error.

**Example.**

```elisp
(etaf-video-source-info nil)
;; ⇒ (:kind demo :file nil :url nil :target nil :audio-url nil
;;    :audio-target nil :headers nil :proxy nil :width 640 :height 360
;;    :duration 30 :fps 30 :audio nil)
```

A source with separate streams that needs headers and a proxy:

```elisp
(etaf-video-source-info
 '(:url "https://media.example/video.m4s"
   :audio-url "https://media.example/audio.m4s"
   :headers '(("User-Agent" . "MyApp/1.0"))
   :proxy "http://127.0.0.1:7890"))
```

**See also.** `etaf-video`, `etaf-video-state`, `etaf-video-seek`.

## Playback control

<!-- index: etaf-video-play; etaf-video-pause; etaf-video-toggle-playback; etaf-video-step; etaf-video-seek; etaf-video-set-speed; etaf-video-state; :on-state -->

The control functions address a mounted video by the HANDLE its Component registered. The video is a playback session with a small state machine: a producer may be running or released, a step may be pending, and the source may have ended. Every control returns the handle's new state through `etaf-video-state`, and a session reports state changes through the `:on-state` callback. Controls act immediately; nothing waits for the next display tick except the frame presentation itself.

#### Function: etaf-video-play (handle)

Start or resume the mounted video identified by HANDLE.

**Arguments.** HANDLE is the symbol registered by a mounted `etaf-video`.

**Semantics.** Playback starts a producer and the audio sidecar if the session is configured to play audio. A resume restarts the producer at the last presented position, so it never fast-forwards to catch up with wall-clock time. A pending manual step is cancelled, because playing supersedes it.

**Returns.** The handle.

**Errors.** `error→ user-error` with `"Video handle must be a symbol: %S"` for a non-symbol, and with `"No mounted etaf-video for handle %S"` when no mounted video owns HANDLE.

**See also.** `etaf-video-pause`, `etaf-video-toggle-playback`, `etaf-video-state`.

#### Function: etaf-video-pause (handle)

Pause the mounted video identified by HANDLE.

**Arguments.** HANDLE is the registered symbol.

**Semantics.** The producer and the audio sidecar are released; the last picture stays on the canvas and `etaf-video-state` keeps reporting the position it reached. A paused video presents nothing until a step, a seek or playback resumes.

**Returns.** The handle.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-play`, `etaf-video-step`, `etaf-video-seek`.

#### Function: etaf-video-toggle-playback (handle)

Toggle the mounted video identified by HANDLE between play and pause.

**Arguments.** HANDLE is the registered symbol.

**Semantics.** A playing video pauses; a paused video plays. A video that has ended restarts from its beginning, which makes the function the usual binding for a single play button.

**Returns.** The handle.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-play`, `etaf-video-state`.

#### Function: etaf-video-step (handle)

Pause the mounted video identified by HANDLE and present one more frame.

**Arguments.** HANDLE is the registered symbol.

**Semantics.** A playing video is paused first. The session then starts a producer for exactly one frame, presents it and releases the producer again. Closing the producer deliberately does not count as the video ending: `etaf-video-state` still reports `:ended` nil.

**Returns.** The handle.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-step-back`, `etaf-video-pause`, `etaf-video-seek`, `etaf-video-state`.

#### Function: etaf-video-step-back (handle)

Pause the mounted video identified by HANDLE and step backward one frame.

**Arguments.** HANDLE is the registered symbol.

**Semantics.** On the `mpv` engine this issues a frame-accurate backward step (`frame-back-step`); on the `ffmpeg` backend it pauses and seeks one second earlier.

**Returns.** `t`.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-step`, `etaf-video-seek`, `etaf-video-engine`.

#### Function: etaf-video-seek (handle seconds)

Move the mounted video identified by HANDLE to SECONDS.

**Arguments.** HANDLE is the registered symbol; SECONDS is a position in seconds, clamped to the source duration when one is known.

**Semantics.** A playing video restarts its producer at the new position and continues from there; a paused video presents the frame at the new position and stays paused. Seeking is how a progress bar or a scrub gesture moves a video.

**Returns.** The handle.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-step`, `etaf-video-state`, `etaf-video-source-info`.

#### Function: etaf-video-set-speed (handle speed)

Set the playback rate of the mounted video identified by HANDLE.

**Arguments.** HANDLE is the registered symbol; SPEED is a positive number, where 1 is the source rate.

**Semantics.** A playing video restarts its producer at the same position with the new read rate, so the change applies without losing the position; a paused video keeps the value for its next playback. The same value is the Component's SPEED input.

**Returns.** The handle.

**Errors.** `error→ user-error` with `"Playback speed must be a positive number: %S"` for a non-positive or non-numeric SPEED, plus the handle errors of `etaf-video-play`.

**See also.** `etaf-video-state`, `etaf-video`.

#### Function: etaf-video-state (handle)

Return the mounted video identified by HANDLE as a detached plist.

**Arguments.** HANDLE is the registered symbol.

**Semantics.** The plist describes the session at the call: `:handle`, `:engine` (`mpv` or `ffmpeg`), `:render-backend` (`gpu`, `canvas` or `image`), `:mode` (the effective render mode after the `image` fallback), `:source` (the file name, the URL string, or the symbol `demo`), `:playing`, `:position` (seconds; the seek base plus elapsed time while frames arrive, clamped to the duration), `:duration`, `:speed`, `:format` (the producer's frame format: `gpu`, `tiff-file`, `tiff`, `ppm`, `canvas`, `gray`, `rgb24`, `bgra` or `mjpeg`), `:width` and `:height` (producer pixels), `:display-fps`, `:source-fps`, `:received`, `:presented`, `:dropped`, `:audio`, `:buffering`, `:error` and `:ended`. The result does not address the session after it returns, so it is safe to store and compare. `:audio` reports the session's audio setting; a source without an audio stream stays silent even when it is true. `:buffering` is non-nil while waiting for the first frame or when a live stream stalls; `:error` holds the decoder diagnostic when the producer exits non-zero.

**Returns.** The detached state plist.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-play`, `etaf-video-seek`, `etaf-video-toggle-playback`.

#### Property: :on-state

The state callback of a video playback session.

**Arguments.** A function of one argument, the session; optional.

**Semantics.** The session calls it after every state change: when playback starts, pauses, steps, seeks or changes speed, volume or audio, and when the source ends. It runs after the state is updated, so the callback reads the new state. The native Component uses it to keep presentation and audio in step; an application that needs the same notification reads `etaf-video-state` on its own schedule.

**See also.** `etaf-video-state`, `etaf-video-play`, `:on-frame`.

## Audio

<!-- index: etaf-video-audio; etaf-video-audio-volume; etaf-video-set-volume; etaf-video-set-audio; audio sidecar -->

Audio plays through a separate player process, the *sidecar*, so decoding the picture and playing the sound stay independent. A source that names a separate `:audio-url` plays that stream; otherwise the sidecar opens the video source itself. The sidecar receives the same `:headers` and `:proxy` as the video decoder, so an authenticated source takes its picture and sound from one access description. A session owns at most one sidecar; it starts with playback and is released by pause, seek, speed change or unmount. A source that reports no audio stream, the built-in demo and a missing player all stay silent without an error.

#### Variable: etaf-video-audio

Whether new videos play their source's audio track by default.

**Semantics.** The variable defaults to nil, so a video is silent unless it is asked for sound; the `etaf-video` Component's AUDIO input overrides it per instance and may be a ref or computed value. The setting is a request, not a guarantee: a source without an audio stream stays silent.

**See also.** `etaf-video-audio-volume`, `etaf-video-set-audio`, `etaf-video`.

#### Variable: etaf-video-audio-volume

Default audio volume for new videos, from 0 to 100.

**Semantics.** The variable defaults to 100 and is the default for the Component's VOLUME input, which overrides it per instance. A volume change applies to the running sidecar without restarting the picture.

**See also.** `etaf-video-audio`, `etaf-video-set-volume`.

#### Function: etaf-video-set-volume (handle volume)

Set the audio volume of the mounted video identified by HANDLE.

**Arguments.** HANDLE is the registered symbol; VOLUME is from 0 to 100.

**Semantics.** A playing video restarts its audio sidecar at the same position with the new level; a paused video keeps the value for its next playback. A source with no audio stream is unaffected.

**Returns.** The handle.

**Errors.** `error→ user-error` with `"Audio volume must be between 0 and 100: %S"` for a value outside the range, plus the handle errors of `etaf-video-play`.

**See also.** `etaf-video-set-audio`, `etaf-video-audio-volume`, `etaf-video-state`.

#### Function: etaf-video-set-audio (handle audio)

Turn the audio sidecar of the mounted video identified by HANDLE on or off.

**Arguments.** HANDLE is the registered symbol; AUDIO non-nil enables sound, nil disables it.

**Semantics.** Enabling starts the sidecar when the video is playing; disabling stops it. A source without an audio stream stays silent whichever way the flag is set, and `etaf-video-state` still reports the requested setting.

**Returns.** The handle.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-set-volume`, `etaf-video-audio`, `etaf-video-state`.

## Presentation

<!-- index: :on-frame; etaf-video-density-ramp; etaf-video-display-fps; frame dropping; density ramp -->

The producer, the display timer and the canvas form a pipeline: the producer fills frames as fast as the decoder delivers them, the session keeps only the newest complete frame, and the display timer presents one frame per period. When frames arrive faster than the display rate, the extra frames are dropped and counted, never queued; the canvas shows the newest picture available at each tick. A presentation failure does not kill the session's producer silently: the session is destroyed and the failure is written to `*Messages*`, leaving the last picture in place.

#### Property: :on-frame

The frame callback of a video playback session.

**Arguments.** A function of two arguments, the frame and the session; optional.

**Semantics.** The session calls it once for each frame it presents, after the frame is claimed at the display tick. The frame is the producer's bytes: one grayscale byte per pixel in the `gray` format, three RGB bytes per pixel in `rgb24`, or one complete JPEG image in `mjpeg`. The native Component installs the callback that maps the frame into its canvas; the callback defines the handoff between decoding and display, and a frame that reaches it is the newest complete frame the producer had at that moment.

**See also.** `etaf-video-display-fps`, `etaf-video-density-ramp`, `:on-state`.

#### Variable: etaf-video-density-ramp

Characters used for one video pixel in the `ascii` render mode.

**Semantics.** The string maps darkness to density from left to right and must be nonempty and single-line; it defaults to `" .:-=+*#%@"`. Each grayscale byte selects the character nearest to its darkness, so a two-character ramp produces a hard threshold and a ten-character ramp ten levels. The variable supplies the default for videos that mount after the change; a mounted canvas keeps the ramp captured when it mounted unless the Component call is evaluated again with a new value, and a per-instance RAMP input overrides the variable.

**Errors.** `error→ user-error` with `"Video density ramp must be a nonempty single-line string: %S"` when the value is empty or contains a newline.

**See also.** `etaf-video`, `etaf-video-display-fps`.

#### Variable: etaf-video-display-fps

Display timer rate in frames per second for new video playback.

**Semantics.** The value defaults to 30, caps the presented frame rate, and is raised to 1 when it is below 1. It does not throttle the producer: the decoder runs at the rate playback speed asks for, and frames that arrive between display ticks are overwritten. A lower value trades smoothness for fewer publications and less per-tick work in the Emacs main thread. The Component's DISPLAY-FPS input overrides the variable per instance and must be a positive integer.

**See also.** `etaf-video`, `:on-frame`, `etaf-video-set-speed`.

#### Variable: etaf-video-render-backend

Rendering backend that puts a graphical video frame on screen.

**Semantics.** The value defaults to `auto`: on a live graphical frame it prefers the native hardware `gpu` video overlay when `libmpv` and the platform GPU layer are ready (a `CAOpenGLLayer` + VideoToolbox layer on macOS, a pass-through child `HWND` + WGL OpenGL surface on Windows, or an X11 `XShape` + EGL/GLX or Wayland `wl_subsurface` + EGL surface on Linux, requiring no Emacs recompilation), then `canvas` when the `canvas` image type and `native/etaf-video-canvas` module are available, and falls back to `image`; on compliant 24-bit text terminals `auto` selects `kitty` Unicode placeholder streaming in `image` mode. `gpu` requests the native GPU overlay (transparently passing mouse and keyboard input through to Emacs and yielding to a single-frame snapshot whenever an in-buffer modal or overlay covers the canvas). `canvas` reads BGRA frames into one Emacs canvas image and refreshes only its pixel buffer; build its module from the package root with `sh native/build-video-canvas-module.sh`. `kitty` requests Kitty terminal graphics on text frames, streaming raw RGB24 frames in place without rewriting buffers. `image` forces the pure-Emacs image pipeline (an asynchronous file-backed TIFF ring under `libmpv`, or scaled JPEGs under `ffmpeg`), working on any Emacs that can display images. Missing capabilities fall back cleanly. `ascii` and `color` modes ignore the setting.

**Performance.** The canvas buffer stays at logical resolution: the macOS NS backend re-uploads every pixel on refresh, so a device-resolution buffer would quadruple the per-frame cost for no visible gain in a text host.

**See also.** `etaf-video`, `etaf-video-display-fps`.

## External programs

<!-- index: etaf-video-ffmpeg-program; etaf-video-ffplay-program; etaf-video-ffprobe-program; optional dependency -->

Three variables name the external programs video playback uses. Each accepts an executable name resolved on the search path or an absolute file name, so a project can pin a version or point at a wrapper script. [Installation and Loading](installation-and-loading.md) lists the degradation each missing program causes.

#### Variable: etaf-video-engine

Playback engine used by `etaf-video`: `auto` (default), `mpv` or `ffmpeg`.

**Semantics.** `auto` uses the optional cross-platform `libmpv` dynamic module (`native/etaf-video-mpv`) on graphical frames in `image` mode when available, giving frame-accurate A/V sync, seamless live volume/speed/resize, multi-track audio, native `libass` / dual subtitles, hardware decoding and video filters; otherwise it falls back to the `ffmpeg` subprocess pipeline. `mpv` requires `libmpv`; `ffmpeg` forces the subprocess pipeline. Installing via `M-x etaf-install` automatically downloads and verifies the prebuilt module into the ETAF user cache without a compiler (and `M-x etaf-install-native` fetches or refreshes it on demand); from a source checkout, `sh native/build-video-mpv-module.sh` builds it locally using only `emacs-module.h` and resolves `libmpv` dynamically at runtime.

**See also.** `etaf-video-mpv-available-p`, `etaf-video-mpv-library`, `etaf-video-set-property`.

#### Variable: etaf-video-mpv-library

Optional explicit path to the `libmpv` shared library (`dylib`, `so` or `dll`).

**Semantics.** Defaults to nil, searching the platform's standard library locations (`libmpv.2.dylib` on macOS, `libmpv.so.2` on Linux, `libmpv-2.dll` on Windows) and `ETAF_VIDEO_MPV_LIBRARY`.

**See also.** `etaf-video-mpv-available-p`, `etaf-video-engine`.

#### Function: etaf-video-mpv-available-p ()

Return non-nil when the cross-platform `libmpv` native backend is available.

**Semantics.** Loads `native/etaf-video-mpv` once and verifies that `libmpv` can be dynamically opened. Returns nil without signaling when either is absent.

**Returns.** `t` when ready, nil otherwise.

**See also.** `etaf-video-gpu-available-p`, `etaf-video-engine`, `etaf-video-mpv-library`.

#### Function: etaf-video-gpu-available-p ()

Return non-nil when the native hardware GPU video layer is available.

**Semantics.** Verifies that `etaf-video-mpv-available-p` is ready and that the current graphical Emacs session supports the platform native GPU video surface (macOS `CAOpenGLLayer` + VideoToolbox, Windows child `HWND` + WGL OpenGL, or Linux X11 + EGL/GLX or Wayland `wl_subsurface` + EGL). Returns nil without signaling in terminal/batch sessions or on platforms without a native GPU surface.

**Returns.** `t` when ready, nil otherwise.

**See also.** `etaf-video-mpv-available-p`, `etaf-video-render-backend`, `etaf-video-state`.

#### Function: etaf-video-set-property (handle name value)

Set playback engine property NAME to VALUE on mounted video HANDLE.

**Arguments.** HANDLE is the registered symbol, NAME is an engine property name string such as `"aid"`, `"sid"`, `"secondary-sid"`, `"video-rotate"`, `"brightness"`, `"audio-delay"` or `"ab-loop-a"`, and VALUE is a boolean, integer, float or string.

**Semantics.** On the `mpv` engine this updates the running playback property in place without restarting decoding. On engines that do not expose properties it returns nil.

**Returns.** `t` on success, an `(ERROR-CODE . MESSAGE)` cons on rejection, or nil when unsupported.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-get-property`, `etaf-video-command`, `etaf-video-engine`.

#### Function: etaf-video-get-property (handle name &optional type)

Read playback engine property NAME from mounted video HANDLE.

**Arguments.** HANDLE is the registered symbol, NAME is an engine property name string, and optional TYPE is `node` (default, returning native Lisp values including lists and alists for structured properties like `"track-list"` and `"chapter-list"`), `string`, `bool`, `int` or `float`.

**Semantics.** Returns the current property value on the `mpv` engine, or nil when unavailable or unsupported.

**Returns.** The property value or nil.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-set-property`, `etaf-video-command`.

#### Function: etaf-video-command (handle &rest args)

Send engine command ARGS to mounted video HANDLE.

**Arguments.** HANDLE is the registered symbol; ARGS are command arguments coerced to strings (such as `"sub-add"`, `"screenshot-to-file"`, `"frame-back-step"`).

**Semantics.** Dispatches the command on the `mpv` engine and returns `0` on success or `(ERROR-CODE . MESSAGE)` on failure; returns nil on engines without commands.

**Returns.** `0`, an error cons, or nil.

**Errors.** The handle errors of `etaf-video-play`.

**See also.** `etaf-video-set-property`, `etaf-video-get-property`.

#### Variable: etaf-video-ffmpeg-program

Name or absolute path of the ffmpeg executable used to decode video.

**Semantics.** The variable defaults to `"ffmpeg"`. A wrapper script can add decoder options; the framework appends the input, the scale filter and the output format after the program name. Without a usable program, starting playback signals `user-error` before any process exists.

**Errors.** `error→ user-error` with `"ffmpeg is not available: %s"` when the program cannot be found or started.

**See also.** `etaf-video-ffprobe-program`, `etaf-video-ffplay-program`, `etaf-video-play`.

#### Variable: etaf-video-ffplay-program

Name or absolute path of the ffplay executable used for audio.

**Semantics.** The variable defaults to `"ffplay"` and is part of the ffmpeg installation. Without a usable program, videos play without sound and no error is signaled, because audio is a sidecar and never gates the picture.

**See also.** `etaf-video-audio`, `etaf-video-ffmpeg-program`.

#### Variable: etaf-video-ffprobe-program

Name or absolute path of the ffprobe executable used for metadata.

**Semantics.** The variable defaults to `"ffprobe"`. Without a usable program, `etaf-video-source-info` keeps the documented defaults instead of failing, so a video still mounts with its own size chosen from the canvas.

**See also.** `etaf-video-source-info`, `etaf-video-ffmpeg-program`.

## Errors and recovery

<!-- index: video failures; optional dependency degradation -->

Video playback can fail in four places: reading the source, validating the Component call, addressing a handle, and running an external program. None of them is an error condition of its own; the framework reports them as `user-error` or `etaf-component-call-error`, and a decoder failure is reported in the message buffer rather than signaled.

| Failure | What happens |
| --- | --- |
| A Component prop is outside its contract | `etaf-component-call-error` at the call, naming the property and the expected value; nothing is mounted |
| SRC is unsupported, unreadable, its URL scheme is not HTTP(S), or `:audio-url`, `:proxy` or `:headers` is malformed | `user-error` before any decoder starts |
| A handle names no mounted video or is not a symbol | `user-error` from every control function |
| The same handle is mounted twice | `user-error`; the second video does not mount |
| ffmpeg is missing or cannot start | `user-error` before any process exists; nothing plays |
| ffprobe is missing | `etaf-video-source-info` returns the documented default metadata |
| ffplay is missing | The video plays silently; no error is signaled |
| A frame arrives while the previous one is unclaimed | The previous frame is dropped and counted in `:dropped` |
| A canvas update fails while playing | The session is destroyed, the failure is written to `*Messages*`, and the last picture stays |
| The video is unmounted while playing | Producer, audio sidecar, handle registration and the frame cache are released |
