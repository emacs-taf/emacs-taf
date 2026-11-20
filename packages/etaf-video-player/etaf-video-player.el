;;; etaf-video-player.el --- Play video with sound in an ETAF buffer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.1
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0") (etaf-db "0.1.0"))
;; Keywords: multimedia, ui
;; URL: https://github.com/emacs-taf/etaf-video-player

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-video-player) after adding this
;; repository and the ETAF and Ebox roots to `load-path'.  The player shows a
;; local video or HTTP(S) stream in an ETAF buffer as sharp image frames with
;; sound.  The native `etaf-video' Component (see the ETAF manual) decodes at
;; the display's device pixel ratio so Retina screens stay sharp, plays the
;; source's audio through an ffplay sidecar, and publishes every frame through
;; the retained Host content boundary; this application owns the buffer, the
;; canvas size, the status line and the keys.  Without a graphical frame the
;; Canvas Component falls back to a density-ramp canvas, so the same command
;; still shows the video in a terminal.  ffmpeg, ffprobe and ffplay must be
;; installed; ffprobe supplies duration and size, and ffplay is only needed
;; for sound.
;;
;; A session is one buffer (`*Video Player*') with one player.
;; `etaf-video-player-open', `etaf-video-player-open-file' and
;; `etaf-video-player-demo' create it, the functions below drive it,
;; `etaf-video-player-state' reports it as plain data, and
;; `etaf-video-player-close' releases it.  The buffer is an ETAF application
;; (see `etaf-app-open'): its root keys bind the same commands, the canvas
;; follows each settled window resize and the appearance, and closing or
;; killing the buffer releases the player once.  A subtitle track beside a
;; local video loads automatically; press c to hide, show or load one.  The
;; keys are SPC play/pause, n step, f/b seek five seconds, +/- speed, [ and ]
;; volume, a sound, 1-4 grid presets, C render mode, F fit, o open, u url,
;; c subtitles, d demo, ? help and q close.
;;
;; `etaf-video-player-render-mode' picks the picture for new players: a
;; scaled image per frame, one density-ramp character per pixel, or true-color
;; half blocks.  The same player can switch at any time, so a terminal session
;; and a graphical one use one application.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions,
;; and the manual contains workflows.
;;
;; Function: etaf-video-player-doctor ()
;; Return capability facts for playback.  The shape matches
;; `etaf-install-doctor': :required and :optional lists of
;; (LABEL AVAILABLE REMEDY).  ffmpeg decodes, ffprobe reads metadata and
;; SQLite stores the playback history.
;; Function: etaf-video-player-open (&optional source)
;;;###autoload (autoload 'etaf-video-player-open "etaf-video-player" nil t)
;; Open the player and return its buffer.
;; SOURCE is nil for the built-in demo, a file name, an HTTP(S) URL, or a
;; plist: `(:file PATH)' for a local video, `(:url URL)' for a network stream
;; and `(:demo)' for the generated test pattern.  All forms accept the hints
;; `:columns' and `:rows' (canvas size in character cells), `:speed'
;; (playback rate), `:audio' and `:volume' (0 to 100).  `:playlist SOURCES'
;; opens several items (each SOURCES element is anything this function
;; accepts) with `:index' selecting the first one, and `:loop'
;; (`none'/`all'/`one') plus `:shuffle' initialize the queue policy.  The
;; canvas is fitted to the selected window unless both size hints are given.
;; An existing player is closed first; unreadable files, non-HTTP(S) URLs and
;; unsupported sources signal `user-error' before any process starts.
;; Called interactively it plays the built-in demo and reads nothing;
;; `etaf-video-player-open-file' and `etaf-video-player-open-url' are the
;; commands that read a file name or a URL.
;;
;; Function: etaf-video-player-open-file (file)
;;;###autoload (autoload 'etaf-video-player-open-file "etaf-video-player" nil t)
;; Play the local video FILE with sound.
;; The prompt reads FILE the way `find-file' does, so a pasted absolute or
;; `~' name is accepted and a relative one resolves against the calling
;; buffer's `default-directory'.
;;
;; Function: etaf-video-player-open-url (url)
;;;###autoload (autoload 'etaf-video-player-open-url "etaf-video-player" nil t)
;; Play the HTTP(S) video stream URL with sound.
;; ffmpeg decodes the stream directly, so nothing is downloaded first.
;; Seeking needs server range support, and a dropped connection is retried
;; for up to five seconds.
;;
;; Function: etaf-video-player-demo ()
;;;###autoload (autoload 'etaf-video-player-demo "etaf-video-player" nil t)
;; Play a generated 30 second test pattern that needs no file.
;;
;; Function: etaf-video-player-close ()
;;;###autoload (autoload 'etaf-video-player-close "etaf-video-player" nil t)
;; Close the player in the current buffer.
;; A local video saves its playback position, the status timer is cancelled,
;; the native session and its audio sidecar are destroyed, and the ETAF
;; Runtime is unmounted before the buffer is killed.  Killing the buffer
;; releases the player the same way.  Signals `user-error' outside a player
;; buffer.
;;
;; Function: etaf-video-player-toggle-playback ()
;; Toggle the current player between playing and paused.
;; Pausing releases the producer and the audio sidecar; playing after the end
;; restarts at zero.
;;
;; Function: etaf-video-player-step ()
;; Pause the current player and present exactly one more frame.
;;
;; Function: etaf-video-player-seek (seconds)
;; Move the current player to SECONDS and restart decoding there.
;; Negative targets are clamped to zero and targets beyond the known duration
;; to its end.  A paused player stays paused.
;;
;; Function: etaf-video-player-set-speed (speed)
;; Set the playback rate to SPEED, a positive number.
;; The session restarts at the current position; the display rate stays
;; `etaf-video-player-display-fps' and extra decoded frames are dropped.
;;
;; Function: etaf-video-player-set-volume (volume)
;; Set the audio volume to VOLUME, from 0 to 100.
;; A playing source restarts its audio sidecar at the current position, so the
;; new level takes effect at once.
;;
;; Function: etaf-video-player-set-audio (audio)
;; Turn the current player's audio on (non-nil) or off (nil).
;; Sources without a reported audio stream stay silent.
;;
;; Function: etaf-video-player-set-render-mode (mode)
;; Switch the current player to render MODE.
;; MODE is `image' (a scaled picture per frame, falling back to `ascii' on a
;; terminal), `ascii' (one density-ramp character per pixel) or `color' (two
;; full-color pixels per `▀' half-block cell, capped at
;; `etaf-video-player-color-columns' columns).  The video continues at its
;; current position with the same rate and audio state.
;;
;; Function: etaf-video-player-cycle-render-mode ()
;; Cycle the current player through `image', `ascii' and `color'.
;; The order starts from the player's current mode, so a terminal player
;; switches between the two character modes after its first change.
;;
;; Function: etaf-video-player-set-grid (columns rows)
;; Resize the canvas to COLUMNS by ROWS character cells.
;; The session restarts at the current position with the new scale, so the
;; video aspect ratio follows the canvas only when the caller keeps it.
;;
;; Function: etaf-video-player-fit ()
;; Fit the current player's canvas to the window showing it.
;; Six rows are reserved for the header, transport and footer.  The playlist
;; column appears from about 100 character columns and the details pane from
;; about 143; their widths are subtracted from the canvas budget.
;;
;; Function: etaf-video-player-next ()
;;;###autoload (autoload 'etaf-video-player-next "etaf-video-player" nil t)
;; Play the next playlist item, wrapping to the first one at the end.
;; The current item keeps playing if it was playing.
;;
;; Function: etaf-video-player-previous ()
;;;###autoload (autoload 'etaf-video-player-previous "etaf-video-player" nil t)
;; Play the previous playlist item, wrapping around at the first one.
;;
;; Function: etaf-video-player-play-index (index)
;;;###autoload (autoload 'etaf-video-player-play-index "etaf-video-player" nil t)
;; Play playlist item INDEX from the beginning.
;;
;; Function: etaf-video-player-enqueue (source)
;;;###autoload (autoload 'etaf-video-player-enqueue "etaf-video-player" nil t)
;; Append SOURCE to the current player's playlist.
;; SOURCE is anything `etaf-video-source-info' accepts; the running item is
;; not interrupted.
;;
;; Function: etaf-video-player-remove (index)
;;;###autoload (autoload 'etaf-video-player-remove "etaf-video-player" nil t)
;; Remove playlist item INDEX from the current player.
;; Removing the running item selects the nearest remaining one; the last
;; remaining item signals `user-error' instead of leaving an empty queue.
;;
;; Function: etaf-video-player-toggle-loop ()
;;;###autoload (autoload 'etaf-video-player-toggle-loop "etaf-video-player" nil t)
;; Cycle the current player's loop mode: `none', `all', `one'.
;;
;; Function: etaf-video-player-toggle-shuffle ()
;;;###autoload (autoload 'etaf-video-player-toggle-shuffle "etaf-video-player" nil t)
;; Toggle shuffle playback for the current player.
;;
;; Function: etaf-video-player-cycle-speed ()
;;;###autoload (autoload 'etaf-video-player-cycle-speed "etaf-video-player" nil t)
;; Cycle the current player through the supported playback rates.
;;
;; Function: etaf-video-player-subtitle-parse (file)
;; Parse FILE into a sorted list of cues.
;; FILE must be a readable SubRip (`.srt') or WebVTT (`.vtt') track; each cue
;; is `(START END TEXT)' with START and END in playback seconds and TEXT one
;; display line.  Malformed blocks are skipped and inline markup is stripped,
;; so a track with a few bad cues still plays; an unreadable file signals
;; `etaf-video-player-subtitle-error'.
;;
;; Function: etaf-video-player-subtitle-text-at (cues seconds)
;; Return the text of the cue in CUES covering playback SECONDS, or nil.
;;
;; Function: etaf-video-player-subtitle-beside (video)
;; Return the first readable subtitle file beside VIDEO, or nil.
;; The probe checks the suffixes in `etaf-video-player-subtitle-extensions'
;; in order, so `movie.zh.srt' wins over a bare track only when listed first.
;;
;; Function: etaf-video-player-subtitle-load (file)
;;;###autoload (autoload 'etaf-video-player-subtitle-load "etaf-video-player" nil t)
;; Load the subtitle FILE into the current player and return its cues.
;; The track replaces any current one and starts shown.  A local video loads a
;; matching track beside it automatically; pressing c hides the current track,
;; shows it again, or asks for a file when none is loaded.
;;
;; Error: etaf-video-player-subtitle-error
;; Signaled when a subtitle file cannot be read or parsed.
;;
;; Function: etaf-video-player-save-screenshot (&optional file)
;;;###autoload (autoload 'etaf-video-player-save-screenshot "etaf-video-player" nil t)
;; Save the current video frame as a PNG image and return the output path.
;; FILE names the image; nil writes a timestamped PNG beside the playing
;; file (or in the temporary directory for a stream).  The frame decodes in
;; the background and the echo area reports the result; the built-in demo
;; signals `user-error' because it has no frame to capture.
;;
;; Function: etaf-video-player-history-position (path)
;; Return PATH's saved playback record as `(POSITION . DURATION)', or nil.
;; A missing database, a missing row and any read failure all return nil.
;;
;; Function: etaf-video-player-history-record (path position duration)
;; Save PATH's playback POSITION and source DURATION; returns POSITION.
;; A row already present for PATH is replaced, and an unavailable database
;; returns nil instead of signaling.  Local videos record their position
;; while playing and when they close; reopening resumes when the position is
;; past five seconds and not within ten seconds of the end.
;;
;; Function: etaf-video-player-state ()
;; Return the current player's state as a detached plist.
;; Keys are `:source', `:playing', `:position', `:duration', `:speed',
;; `:columns', `:rows', `:mode' (the requested render mode), `:render-mode'
;; (the effective mode, `ascii' when the frame cannot show images), `:fps'
;; (display timer rate), `:presented-fps', `:source-fps', `:source-width',
;; `:source-height', `:received', `:presented', `:dropped', `:audio',
;; `:volume', `:title', `:queue-length', `:index', `:loop', `:shuffle',
;; `:subtitle-file', `:subtitle-on' and `:ended'.  It reads the live player
;; without changing it, and signals `user-error' outside a player buffer.
;;
;; Variable: etaf-video-player-audio
;; Whether new players play their source's audio track.
;; The default is t; ffplay and a sound card are required, and a source
;; without an audio stream stays silent.
;;
;; Variable: etaf-video-player-device-pixel-ratio
;; Device pixels per logical pixel for image frames.
;; Nil derives it from `frame-scale-factor' (2 on Retina), so frames are
;; produced at device resolution instead of being upscaled and blurred;
;; 1 forces logical-pixel frames.
;;
;; Variable: etaf-video-player-display-fps
;; Maximum presentation rate for new players, default 24 frames per second.
;; This cap does not lower the source resolution or the device pixel ratio;
;; it is not a guarantee of the achieved frame rate.
;;
;; Variable: etaf-video-player-subtitle-extensions
;; File suffixes probed beside a video when it opens.
;; The default checks `.srt' and `.vtt' first, then the common Chinese
;; language suffixes; repoint it to prefer a different naming scheme.
;;
;; Variable: etaf-video-player-history-file
;; Database file holding saved playback positions.
;; Nil uses `etaf-video-player/history.sqlite3' under the Emacs user
;; directory; a value that cannot be opened disables history instead of
;; failing.
;;
;; Variable: etaf-video-player-theme-mode
;; New-player appearance: `dark' (default) or `light', independent of Emacs's
;; theme.  Press T to switch the running player; the stage follows the
;; appearance while letterbox frames stay black.
;;
;; Variable: etaf-video-player-render-mode
;; Render mode of new players: `image' (default), `ascii' or `color'.
;; `image' draws one scaled picture per frame in a graphical frame and falls
;; back to `ascii' elsewhere, `ascii' maps each pixel to one density-ramp
;; character and `color' draws two full-color pixels per `▀' half-block cell.
;; A `:mode' hint when opening a player overrides it; press C to switch a
;; running player without losing its position.
;;
;; Variable: etaf-video-player-color-columns
;; Column limit applied while the render mode is `color', default 32.
;; Color content carries one `face' property per cell and the renderer
;; publishes one property operation per run, so a wide grid costs
;; proportionally more per frame; nil fits the window like the other modes.
;;
;; Variable: etaf-video-player-grid-presets
;; Canvas widths reached by the `1' to `4' keys.
;; Keys are characters and values are widths in character cells, so a user can
;; repoint the presets without touching the keymap.
;;
;; Variable: etaf-video-player-volume
;; Initial audio volume for new players, from 0 to 100.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-video-player-app)

(defun etaf-video-player-doctor ()
  "Return capability facts for playing video in ETAF.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Nothing is installed or changed."
  (list :required
        (list (list "ffmpeg" (and (executable-find "ffmpeg") t)
                    "Install ffmpeg with your system package manager, for example brew install ffmpeg or apt install ffmpeg.")
              (list "ffprobe" (and (executable-find "ffprobe") t)
                    "ffprobe ships with ffmpeg; install ffmpeg and reopen the player.")
              )
        :optional
        (list (list "Playback history (etaf-db with SQLite)"
                    (and (fboundp 'etaf-sqlite-database)
                         (fboundp 'sqlite-available-p) (sqlite-available-p))
                    "Optional: install etaf-db and use an Emacs build with SQLite to resume playback."))))


(provide 'etaf-video-player)
;;; etaf-video-player.el ends here
