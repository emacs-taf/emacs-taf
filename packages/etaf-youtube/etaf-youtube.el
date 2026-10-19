;;; etaf-youtube.el --- Native YouTube client for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0") (ebox "3.0.0") (etaf-db "0.1.0"))
;; Keywords: multimedia, hypermedia, ui
;; URL: https://github.com/emacs-taf/etaf-youtube

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-youtube) after adding this
;; repository root and the ETAF, ETAF UI, Ebox, ECSS and ETAF DB roots to
;; `load-path'.  This is a native YouTube client for ETAF: it browses the
;; signed-in account's home, Shorts, subscriptions, history, playlists,
;; watch later, liked videos and live pages, searches with filters, opens
;; channels and playlists, reads a video with its comments and
;; recommendations, and plays the video with sound in the application's own
;; canvas.  Listings and playback come from the shared `youtube' skill
;; through its protocol 1 JSON interface; a controlled browser keeps the
;; account session, so the application never stores credentials.
;;
;; A session is the unit of state.  `etaf-youtube-create' builds one around an
;; injectable transport and thumbnail cache; the commands below drive it,
;; `etaf-youtube-state' reports it as plain data, and `etaf-youtube-view'
;; renders it into any ETAF Runtime.  `etaf-youtube-open' mounts the standard
;; buffer and `etaf-youtube-close' releases it.  Every displayed value is a
;; reactive source, so a reply repaints the smallest subtree that changed.
;;
;; Account writes (like, dislike, subscribe, save, comment) are explicit:
;; the public command only submits when its YES argument is non-nil, and the
;; mounted application asks for confirmation first.  A write that the skill
;; reports as submitted but unverified is shown as a warning and is never
;; retried automatically; a comment on an account without a YouTube channel
;; reports the blocked state instead of pretending to succeed.
;;
;; Two external programs matter.  Node.js runs the bundled backend in
;; `backends/youtube'; ffmpeg and ffplay decode the resolved
;; media through the ETAF native video Component.  Thumbnails download in the
;; background through `curl', honoring the proxy route the skill recorded.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Symbols whose docstrings live in the lisp/
;; modules are the same interfaces; this list is the authoritative inventory.
;;
;; Function: etaf-youtube-open ()
;;;###autoload (autoload 'etaf-youtube-open "etaf-youtube" nil t)
;; Mount the application in its own buffer and return that buffer.
;;
;; Function: etaf-youtube-close ()
;;;###autoload (autoload 'etaf-youtube-close "etaf-youtube" nil t)
;; Unmount the application buffer, release its session and kill the buffer.
;;
;; Variable: etaf-youtube-buffer-name
;; Buffer name of the mounted application, `"*YouTube*'" by default.
;;
;; Variable: etaf-youtube-region-shell
;; Region id of the whole application shell, for `etaf-region-focus' and
;; the `M-g' region selector.
;;
;; Variable: etaf-youtube-region-sidebar
;; Region id of the navigation sidebar, expanded or as the icon rail.
;;
;; Variable: etaf-youtube-region-content
;; Region id of the scrollable content area.
;;
;; Variable: etaf-youtube-region-comments
;; Region id of the watch page comment section.
;;
;; The application key surface is declared on the View, so `?' lists it with
;; the region hints and an active text input keeps the keys.  SPC plays and
;; pauses, f and b seek, [ and ] change the volume, m mutes, s folds the
;; sidebar, t toggles theater mode, d switches the palette, r refreshes, u
;; goes back, RET activates the selected row, / edits the search field, and
;; M-g or C-c s, C-c c and C-c m reach the sidebar, content and comment
;; regions.  The renderer keeps Escape, Tab, `?', the arrows and q.
;;
;; Function: etaf-youtube-create (&key service images store)
;; Create a session and return it.
;; SERVICE defaults to the skill transport, IMAGES to the thumbnail cache and
;; STORE to the SQLite store.  Pass `:store :none' for a session without
;; persistence, and an injected SERVICE or IMAGES for offline work.
;;
;; Function: etaf-youtube-destroy (app)
;; Cancel APP's requests and downloads and release its timer and store.
;;
;; Function: etaf-youtube-state (app)
;; Return APP's state as a detached plist.
;; Keys are `:view', `:params', `:account', `:feed-status', `:title',
;; `:items', `:next', `:selected', `:video', `:media-status', `:comments',
;; `:playing', `:position', `:duration', `:resume', `:volume', `:speed',
;; `:quality', `:muted', `:captions-on', `:sidebar', `:theater', `:theme' and
;; `:message'.  `:selected' is a zero-based index or nil when no item has
;; been selected; a fresh or replaced feed starts unselected.
;;
;; Function: etaf-youtube-locate (app view &optional args)
;; Navigate APP to VIEW with ARGS and load its content.
;; VIEW is `home', `shorts', `subscriptions', `history', `playlists',
;; `watch-later', `liked', `live', `search', `channel', `playlist' or
;; `watch'; `channel' takes `(:id ID :params PARAMS)' and `watch' takes
;; `(:id VIDEO-ID)'.
;;
;; Function: etaf-youtube-refresh (app)
;; Reload APP's current view.
;;
;; Function: etaf-youtube-load-more (app)
;; Append APP's next list page when the current payload has a cursor.
;;
;; Function: etaf-youtube-back (app)
;; Return APP to the previous view, or to the home feed.
;;
;; Function: etaf-youtube-search (app query &optional filter)
;; Search APP for QUERY and show the results.
;; FILTER is `all' (default), `videos', `channels', `playlists' or `live'.
;;
;; Function: etaf-youtube-set-filter (app filter)
;; Reload APP's search results with another FILTER.
;;
;; Function: etaf-youtube-apply-chip (app chip)
;; Follow CHIP from a payload's `:filters' or `:tabs' list.
;; A chip cursor reads the next list; chip params browse the channel tab.
;;
;; Function: etaf-youtube-open-video (app id)
;; Open video ID in APP: details, comments and a resolved media source.
;;
;; Function: etaf-youtube-select (app delta)
;; Move APP's list selection by DELTA, clamping at the ends.
;; Without a selection, negative DELTA selects the last item; zero or positive
;; DELTA selects the first.  An empty list remains unselected.
;;
;; Function: etaf-youtube-press-item (app index)
;; Activate APP's zero-based list item INDEX.
;;
;; Function: etaf-youtube-activate (app)
;; Activate APP's currently selected item, or do nothing when none is selected.
;;
;; Function: etaf-youtube-toggle-sidebar (app)
;; Fold or unfold APP's sidebar.
;;
;; Function: etaf-youtube-toggle-theater (app)
;; Switch APP's watch page between two columns and one.
;;
;; Function: etaf-youtube-set-theme (app mode)
;; Switch APP to the appearance MODE, `dark' or `light'.
;;
;; Function: etaf-youtube-cycle-theme (app)
;; Switch APP to the other appearance.
;;
;; Function: etaf-youtube-toggle-playback (app)
;; Toggle APP's video between playing and paused.
;;
;; Function: etaf-youtube-seek (app seconds)
;; Move APP's video to SECONDS.
;;
;; Function: etaf-youtube-seek-by (app delta)
;; Move APP's video DELTA seconds from its current position.
;;
;; Function: etaf-youtube-set-volume (app volume)
;; Set APP's volume to VOLUME between 0 and 100.
;;
;; Function: etaf-youtube-set-speed (app speed)
;; Set APP's playback rate to SPEED, a positive number.
;;
;; Function: etaf-youtube-set-quality (app quality)
;; Switch APP's video to QUALITY, one of `etaf-youtube-quality-choices'.
;;
;; Function: etaf-youtube-toggle-mute (app)
;; Toggle APP's audio.
;;
;; Function: etaf-youtube-toggle-captions (app)
;; Turn APP's subtitles on or off.
;;
;; Function: etaf-youtube-scrub (app value)
;; Preview APP's progress at VALUE seconds without seeking yet.
;;
;; Function: etaf-youtube-commit-scrub (app)
;; Seek APP's video to its scrubbed position and clear the preview.
;;
;; Function: etaf-youtube-media-src (app)
;; Return APP's resolved media as a normalized `etaf-video' source, or nil.
;;
;; Function: etaf-youtube-quality-choices (app)
;; Return the quality heights APP's current media offers for selection.
;;
;; Function: etaf-youtube-caption-text (app)
;; Return APP's subtitle text at the current position, or nil.
;;
;; Function: etaf-youtube-sort-comments (app cursor)
;; Read APP's comments in the order CURSOR names.
;;
;; Function: etaf-youtube-load-replies (app comment-id &optional cursor)
;; Load CURSOR's replies to COMMENT-ID in APP, or its first page.
;;
;; Function: etaf-youtube-replies (app comment-id)
;; Return APP's loaded replies for COMMENT-ID.
;;
;; Function: etaf-youtube-replies-cursor (app comment-id)
;; Return APP's stored replies cursor for COMMENT-ID, or nil.
;;
;; Function: etaf-youtube-like (app &optional yes)
;; Like APP's video; YES submits the write instead of its offline preview.
;;
;; Function: etaf-youtube-dislike (app &optional yes)
;; Dislike APP's video; YES submits the write.
;;
;; Function: etaf-youtube-unrate (app &optional yes)
;; Remove APP's rating; YES submits the write.
;;
;; Function: etaf-youtube-subscribe (app subscribe-p &optional yes)
;; Subscribe when SUBSCRIBE-P, otherwise unsubscribe; YES submits the write.
;;
;; Function: etaf-youtube-save (app &optional playlist yes)
;; Save APP's video to PLAYLIST, or the account's default list.
;; YES submits the write.
;;
;; Function: etaf-youtube-comment (app text &optional yes)
;; Post TEXT as a comment on APP's video; YES submits the write.
;;
;; Function: etaf-youtube-view (model)
;; Return the application View for MODEL.
;;
;; Function: etaf-youtube-service-create (&key runner timeout)
;; Create the skill transport.  RUNNER receives ARGV and a callback and
;; returns a cancel function, which is the injection point for offline tests.
;;
;; Function: etaf-youtube-service-call (service args callback &optional key)
;; Run skill ARGS through SERVICE and deliver the parsed result to CALLBACK.
;; The result plist has `:status' (`ok', `error' or `timeout'), `:value',
;; `:message' and `:hint'.  KEY supersedes earlier calls with the same key.
;;
;; Function: etaf-youtube-service-cancel (service &optional key)
;; Cancel SERVICE's in-flight request for KEY, or every request.
;;
;; Function: etaf-youtube-service-close (service)
;; Cancel every request of SERVICE and release its state.
;;
;; Function: etaf-youtube-images-create (&key directory fetcher proxy-fn)
;; Create a thumbnail cache.  FETCHER defaults to the curl downloader and is
;; the injection point for offline tests; PROXY-FN supplies an optional proxy.
;;
;; Function: etaf-youtube-images-request (images url)
;; Ensure URL is downloaded into IMAGES; return non-nil when it is new.
;;
;; Function: etaf-youtube-images-descriptor (images url)
;; Return URL's image descriptor from IMAGES, or nil while it is not ready.
;;
;; Function: etaf-youtube-images-version (images)
;; Return IMAGES's completion version ref.
;;
;; Function: etaf-youtube-images-cancel (images)
;; Cancel IMAGES's queued and in-flight downloads.
;;
;; Function: etaf-youtube-images-clear-error (images url)
;; Forget IMAGES's failed URL so a later request may retry it.
;;
;; Function: etaf-youtube-color (key &optional mode)
;; Return the palette color named KEY for MODE, defaulting to the dark theme.
;;
;; Function: etaf-youtube-colors (mode)
;; Return MODE's common palette as one plist for direct style use.
;;
;; Function: etaf-youtube-theme-defaults (&optional mode)
;; Return the ETAF UI token plist for MODE.
;;
;; Function: etaf-youtube-store-open ()
;; Open the local SQLite store, or return nil when SQLite is unavailable.
;;
;; Function: etaf-youtube-store-close (store)
;; Release STORE's Data Controller.
;;
;; Function: etaf-youtube-store-setting (store name)
;; Return STORE's string setting NAME, or nil.
;;
;; Function: etaf-youtube-store-set-setting (store name value)
;; Write STORE's setting NAME to VALUE.
;;
;; Function: etaf-youtube-store-resume (store video-id)
;; Return STORE's resume position for VIDEO-ID in seconds, or nil.
;;
;; Function: etaf-youtube-store-record-resume (store video-id position)
;; Record POSITION seconds as STORE's resume point for VIDEO-ID.
;;
;; Variable: etaf-youtube-theme-mode
;; Appearance a new session uses, `dark' (default) or `light'.
;;
;; Function: etaf-youtube-login (&optional model)
;; Sign in to YouTube in the controlled browser and refresh open sessions.
;; Opens (or reuses) the page through the bundled backend, then polls the
;; account for up to `etaf-youtube-login-timeout' seconds and reports the
;; signed-in name; the browser keeps the session, Emacs stores no credential.
;;
;; Function: etaf-youtube-logout (&optional model)
;; Ask for confirmation, then clear this site's cookies and storage in the
;; controlled browser and reload the open sessions.
;;
;; Function: etaf-youtube-account (&optional model)
;; Report the account the controlled browser is signed in to, or why not.
;;
;; Variable: etaf-youtube-node-program
;; Node.js executable that runs the bundled backend, `"node"' by default.
;;
;; Variable: etaf-youtube-backend-directory
;; Directory of the bundled YouTube backend (`backends/youtube' in this
;; repository); the backend speaks the versioned protocol 1 JSON interface
;; and needs only Node.js, so no external skill is involved.
;;
;; Variable: etaf-youtube-command
;; Command prefix overriding the bundled backend, nil by default; the public
;; suite injects a stand-in script through it.
;;
;; Variable: etaf-youtube-request-timeout
;; Seconds before an unfinished skill request is cancelled, 95 by default.
;;
;; Variable: etaf-youtube-images-directory
;; Directory holding cached thumbnail files.
;;
;; Variable: etaf-youtube-image-timeout
;; Seconds curl may spend on one thumbnail, 25 by default.
;;
;; Variable: etaf-youtube-image-workers
;; How many thumbnail downloads may run at once, 4 by default.
;;
;; Variable: etaf-youtube-store-file
;; SQLite file holding local preferences and resume positions.
;;
;; Variable: etaf-youtube-player-handle
;; Handle registered by the mounted video Component of the application.

;;; Code:

(eval-and-compile
  (let ((directory (file-name-directory (or load-file-name
                                            (bound-and-true-p byte-compile-current-file)
                                            buffer-file-name))))
    (add-to-list 'load-path (expand-file-name "lisp" directory))))

(require 'etaf-youtube-app)
(require 'etaf-youtube-images)
(require 'etaf-youtube-login)
(require 'etaf-youtube-model)
(require 'etaf-youtube-service)
(require 'etaf-youtube-store)
(require 'etaf-youtube-theme)
(require 'etaf-youtube-views)

(provide 'etaf-youtube)
;;; etaf-youtube.el ends here
