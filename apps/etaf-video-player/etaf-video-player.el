;;; etaf-video-player.el --- Play video with sound in an ETAF buffer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.19") (etaf-ui "0.3.14") (etaf-db "0.1.4"))
;; Keywords: multimedia, ui
;; URL: https://github.com/emacs-taf/etaf-video-player

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-video-player) after adding this
;; repository and the ETAF and Ebox roots to `load-path'.  The player opens on
;; a clean Welcome / Continue Watching home screen when called with no source
;; and plays local videos, directories, `.m3u'/`.m3u8' playlists, or HTTP(S)
;; streams (including yt-dlp URLs on libmpv) inside an ETAF buffer.  Powered by
;; ETAF's cross-platform `libmpv' engine when available (with automatic fallback
;; to `ffmpeg'/`ffplay' and terminal density-ramp/half-block modes), it offers
;; collapsible Cinema Theater and 4-tab Studio drawers (Queue/Chapters/Bookmarks
;; /History and Playback/Tracks/Video/Media Info) plus Finder drag-and-drop.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions,
;; and the manual contains workflows.
;;
;; Function: etaf-video-player-doctor ()
;; Return capability facts for playback matching `etaf-install-doctor'.
;; Checks `libmpv' (recommended native engine), `ffmpeg' (required fallback),
;; `ffprobe', `ffplay', `yt-dlp' and SQLite.
;;
;; Function: etaf-video-player-open (&optional source)
;;;###autoload (autoload 'etaf-video-player-open "etaf-video-player" nil t)
;; Open the player and return its buffer.
;; When SOURCE is nil, opens the Welcome / Continue Watching launcher screen.
;; SOURCE may also be a file name, a directory of videos, a `.m3u'/`.m3u8'
;; playlist, an HTTP(S) URL, or a plist (`:file', `:url', `:demo', `:playlist')
;; with optional `:columns', `:rows', `:speed', `:audio', `:volume', `:mode',
;; `:layout', `:index', `:loop' and `:shuffle'.
;;
;; Function: etaf-video-player-open-file (file)
;;;###autoload (autoload 'etaf-video-player-open-file "etaf-video-player" nil t)
;; Play local video FILE, directory of videos, or `.m3u'/`.m3u8' playlist.
;;
;; Function: etaf-video-player-open-url (url)
;;;###autoload (autoload 'etaf-video-player-open-url "etaf-video-player" nil t)
;; Play HTTP(S) video stream or yt-dlp supported URL with sound.
;;
;; Function: etaf-video-player-demo ()
;;;###autoload (autoload 'etaf-video-player-demo "etaf-video-player" nil t)
;; Play a generated 30 second test pattern that needs no file.
;;
;; Function: etaf-video-player-close ()
;;;###autoload (autoload 'etaf-video-player-close "etaf-video-player" nil t)
;; Close the player in the current buffer, saving its playback position.
;;
;; Function: etaf-video-player-toggle-theater ()
;; Toggle Cinema Theater mode, collapsing or restoring both side drawers.
;;
;; Function: etaf-video-player-toggle-fullscreen ()
;; Toggle in-window pure cinema fullscreen mode (`W' / `C-c f').
;;
;; Function: etaf-video-player-toggle-frame-fullscreen ()
;; Toggle dedicated OS/frame fullscreen mode (`Z' / `C-c F'), saving and
;; restoring Emacs window splits, frame state and mode-line cleanly.
;;
;; Function: etaf-video-player-toggle-media-panel ()
;; Toggle the left Media drawer (Queue, Chapters, Bookmarks and Watch History).
;;
;; Function: etaf-video-player-toggle-inspector ()
;; Toggle the right Studio drawer (Playback, Tracks, Video and Media Info).
;;
;; Function: etaf-video-player-toggle-pip ()
;; Toggle a floating adaptive Picture-in-Picture window for the active video.
;;
;; Function: etaf-video-player-toggle-playback ()
;; Toggle the current player between playing and paused.
;;
;; Function: etaf-video-player-step ()
;; Pause the current player and present one frame forward.
;;
;; Function: etaf-video-player-step-back ()
;; Pause the current player and step one frame backward.
;;
;; Function: etaf-video-player-seek (seconds)
;; Move the current player to SECONDS.
;;
;; Function: etaf-video-player-goto-time (time)
;; Seek the current player to TIME (`SS', `MM:SS', `H:MM:SS', `50%' or `+15').
;;
;; Function: etaf-video-player-copy-timestamp ()
;; Copy the current playback timestamp to `kill-ring'.
;;
;; Function: etaf-video-player-toggle-stop-after-current ()
;; Toggle pausing automatically when the current video finishes.
;;
;; Function: etaf-video-player-set-ab-start (&optional seconds)
;; Set the A-B loop start point to SECONDS or the current playback position.
;;
;; Function: etaf-video-player-set-ab-end (&optional seconds)
;; Set the A-B loop end point to SECONDS or the current position (or clear an
;; active loop when called interactively with no argument).
;;
;; Function: etaf-video-player-clear-ab ()
;; Clear any active A-B loop range on the current player.
;;
;; Function: etaf-video-player-add-bookmark (&optional note)
;; Save a persistent SQLite timestamp bookmark at the current position.
;;
;; Function: etaf-video-player-next-chapter ()
;; Jump to the next embedded container chapter.
;;
;; Function: etaf-video-player-previous-chapter ()
;; Jump to the previous embedded container chapter.
;;
;; Function: etaf-video-player-set-audio-track (track-id)
;; Select embedded audio TRACK-ID on the libmpv engine.
;;
;; Function: etaf-video-player-cycle-audio-track ()
;; Cycle through available embedded audio tracks on the libmpv engine.
;;
;; Function: etaf-video-player-set-subtitle-track (track-id)
;; Select primary subtitle TRACK-ID (or nil to hide) on the libmpv engine.
;;
;; Function: etaf-video-player-set-secondary-subtitle (track-id)
;; Select bilingual secondary subtitle TRACK-ID (or nil to disable) on libmpv.
;;
;; Function: etaf-video-player-cycle-subtitle-track ()
;; Cycle through available embedded or external subtitle tracks.
;;
;; Function: etaf-video-player-rotate (&optional degrees)
;; Rotate video to DEGREES or cycle 0 -> 90 -> 180 -> 270 -> 0 on libmpv.
;;
;; Function: etaf-video-player-set-speed (speed)
;; Set the playback rate to SPEED, a positive number.
;;
;; Function: etaf-video-player-set-volume (volume)
;; Set the audio volume to VOLUME, from 0 to 100.
;;
;; Function: etaf-video-player-set-audio (audio)
;; Turn the current player's audio on (non-nil) or off (nil).
;;
;; Function: etaf-video-player-set-render-mode (mode)
;; Switch the current player to render MODE (`image', `ascii' or `color').
;;
;; Function: etaf-video-player-cycle-render-mode ()
;; Cycle the current player through supported render modes.
;;
;; Function: etaf-video-player-set-grid (columns rows)
;; Resize the canvas to COLUMNS by ROWS character cells.
;;
;; Function: etaf-video-player-fit ()
;; Fit the current player's canvas to the window showing it.
;;
;; Function: etaf-video-player-next ()
;;;###autoload (autoload 'etaf-video-player-next "etaf-video-player" nil t)
;; Play the next playlist item, wrapping to the first one at the end.
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
;; Append SOURCE (file, directory or `.m3u') to the current player's playlist.
;;
;; Function: etaf-video-player-enqueue-siblings ()
;; Add all sibling video files in the active video's directory to the queue.
;;
;; Function: etaf-video-player-sort-queue ()
;; Sort the current playlist alphabetically by title, preserving active item.
;;
;; Function: etaf-video-player-remove (index)
;;;###autoload (autoload 'etaf-video-player-remove "etaf-video-player" nil t)
;; Remove playlist item INDEX from the current player.
;;
;; Function: etaf-video-player-move-up ()
;; Move the currently active item one slot up in the playlist.
;;
;; Function: etaf-video-player-move-down ()
;; Move the currently active item one slot down in the playlist.
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
;;
;; Function: etaf-video-player-subtitle-text-at (cues seconds)
;; Return the text of the cue in CUES covering playback SECONDS, or nil.
;;
;; Function: etaf-video-player-subtitle-beside (video)
;; Return the first readable subtitle file beside VIDEO, or nil.
;;
;; Function: etaf-video-player-subtitle-load (file)
;;;###autoload (autoload 'etaf-video-player-subtitle-load "etaf-video-player" nil t)
;; Load external subtitle FILE into the current player.
;;
;; Error: etaf-video-player-subtitle-error
;; Signaled when a subtitle file cannot be read or parsed.
;;
;; Function: etaf-video-player-save-screenshot (&optional file)
;;;###autoload (autoload 'etaf-video-player-save-screenshot "etaf-video-player" nil t)
;; Save the current video frame as a PNG image and return the output path.
;;
;; Function: etaf-video-player-history-position (path)
;; Return PATH's saved playback record as `(POSITION . DURATION)', or nil.
;;
;; Function: etaf-video-player-history-record (path position &optional duration)
;; Save PATH's playback POSITION and optional source DURATION.
;;
;; Function: etaf-video-player-history-recent (&optional limit)
;; Return up to LIMIT recent playback history records, newest first.
;;
;; Function: etaf-video-player-history-delete (path)
;; Delete the saved playback history entry for PATH.
;;
;; Function: etaf-video-player-history-clear ()
;; Remove all saved playback history entries from the database.
;;
;; Function: etaf-video-player-bookmarks (path)
;; Return saved timestamp bookmarks for PATH ordered by playback position.
;;
;; Function: etaf-video-player-bookmark-add (path position &optional note)
;; Store a timestamp bookmark at POSITION seconds for PATH with optional NOTE.
;;
;; Function: etaf-video-player-bookmark-remove (id)
;; Delete bookmark ID from the SQLite database.
;;
;; Function: etaf-video-player-state ()
;; Return the current player's state as a detached plist.
;; Keys include `:welcome', `:engine', `:render-backend', `:source', `:playing', `:position',
;; `:duration', `:speed', `:columns', `:rows', `:mode', `:render-mode',
;; `:fps', `:presented-fps', `:source-fps', `:source-width', `:source-height',
;; `:received', `:presented', `:dropped', `:audio', `:volume', `:title',
;; `:queue-length', `:index', `:loop', `:shuffle', `:stop-after-current',
;; `:ab-loop', `:theater', `:media-panel', `:inspector', `:chapters',
;; `:bookmarks', `:tracks', `:rotate', `:aspect', `:subtitle-file',
;; `:subtitle-on', `:buffering', `:error' and `:ended'.
;;
;; Variable: etaf-video-player-default-layout
;; Initial drawer layout: `auto' (theater for single video, media panel for
;; playlists), `theater', `media' or `studio'.
;;
;; Variable: etaf-video-player-audio
;; Whether new players play their source's audio track (default t).
;;
;; Variable: etaf-video-player-device-pixel-ratio
;; Device pixels per logical pixel for image frames (nil follows frame).
;;
;; Variable: etaf-video-player-display-fps
;; Maximum presentation rate for new players, default 24 frames per second.
;;
;; Variable: etaf-video-player-subtitle-extensions
;; File suffixes probed beside a video when it opens.
;;
;; Variable: etaf-video-player-history-file
;; Database file holding saved playback positions and timestamp bookmarks.
;;
;; Variable: etaf-video-player-theme-mode
;; New-player appearance: `dark' (Obsidian Cinema) or `light' (Alabaster Studio).
;;
;; Variable: etaf-video-player-render-mode
;; Render mode of new players: `image' (default), `ascii' or `color'.
;;
;; Variable: etaf-video-player-color-columns
;; Column limit applied while the render mode is `color', default 32.
;;
;; Variable: etaf-video-player-grid-presets
;; Canvas widths reached by the `1' to `4' keys.
;;
;; Variable: etaf-video-player-volume
;; Initial audio volume for new players, from 0 to 100.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-video-player")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-video-player.el" dir))
                                (file-exists-p (expand-file-name "etaf-video-player.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-video-player-app)

(defun etaf-video-player-doctor ()
  "Return capability facts for playing video in ETAF.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Nothing is installed or changed."
  (let ((mpv-ok (etaf-video-mpv-available-p))
        (gpu-ok (and (fboundp 'etaf-video-gpu-available-p)
                     (etaf-video-gpu-available-p))))
    (list :required
          (list (list "ffmpeg (or libmpv native backend)"
                      (or mpv-ok (and (executable-find etaf-video-ffmpeg-program) t))
                      "Install ffmpeg, or install libmpv and run M-x etaf-install-native (select etaf)."))
          :optional
          (list (list "libmpv native engine (multi-track, ASS/dual subs, filters, hwdec)"
                      mpv-ok
                      "Install libmpv (brew install mpv / apt install libmpv2) and run M-x etaf-install-native (select etaf).")
                (list "Native hardware GPU video layer (zero-copy overlay)"
                      gpu-ok
                      "Run in GUI Emacs on macOS with libmpv and etaf-video-mpv native module v2 (M-x etaf-install-native) for ~5% CPU playback.")
                (list "ffprobe (metadata and chapters fallback)"
                      (and (executable-find etaf-video-ffprobe-program) t)
                      "Optional: install ffprobe (ships with ffmpeg) or set `etaf-video-ffprobe-program'.")
                (list "ffplay (ffmpeg-backend audio)"
                      (and (executable-find etaf-video-ffplay-program) t)
                      "Optional: install ffplay (ships with ffmpeg) or set `etaf-video-ffplay-program'.")
                (list "yt-dlp (YouTube / Bilibili URL playback via libmpv)"
                      (and (executable-find "yt-dlp") t)
                      "Optional: install yt-dlp to play web video URLs directly on libmpv.")
                (list "Playback history and bookmarks (etaf-db with SQLite)"
                      (and (fboundp 'etaf-sqlite-database)
                           (fboundp 'sqlite-available-p) (sqlite-available-p))
                      "Optional: install etaf-db and use an Emacs build with SQLite for history and bookmarks.")))))

;;;###autoload
(with-eval-after-load 'etaf
  (etaf-app-register 'etaf-video-player
    :title "视频播放器"
    :icon "V"
    :category 'media
    :feature 'etaf-video-player
    :open 'etaf-video-player-open
    :doctor 'etaf-video-player-doctor
    :file-extensions '("mp4" "mkv" "webm" "mov" "avi" "m3u" "m3u8")
    :hosts '(buffer)))

(provide 'etaf-video-player)
;;; etaf-video-player.el ends here
