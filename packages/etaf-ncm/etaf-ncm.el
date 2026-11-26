;;; etaf-ncm.el --- NetEase Cloud Music player for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.7
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0") (ebox "3.0.0") (etaf-db "0.1.0"))
;; Keywords: multimedia, ui
;; URL: https://github.com/emacs-taf/etaf-ncm

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-ncm) after adding this repository and
;; the ETAF, ETAF UI, Ebox and ETAF DB roots to `load-path'.  The player is a complete
;; NetEase Cloud Music client for Emacs: it browses the signed-in account's
;; daily recommendation, liked songs, playlists, albums, artists, charts,
;; podcasts and recent plays, searches the catalog, drives playback through mpv,
;; shows the synchronized lyric with its translation, and edits the queue.
;;
;; A session is the unit of state.  `etaf-ncm-create' builds one, the actions
;; below drive it asynchronously, `etaf-ncm-state' reports it as plain data, and
;; `etaf-ncm-app' or `etaf-ncm-open' display it.  Every displayed value is an
;; ETAF reactive source, so a backend reply repaints the mounted player without
;; a refresh call.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list; implementations
;; and precise docstrings remain beside their definitions, and the manual
;; contains workflows.
;;
;; Function: etaf-ncm-doctor ()
;; Return capability facts for playing music.  The shape matches
;; `etaf-install-doctor': the backend, its Node.js and Python 3 helpers and mpv
;; are what a session needs; the account login is optional until the first
;; request, and a QR terminal is only needed for QR sign-in.
;;
;; Function: etaf-ncm-open (&optional model)
;;;###autoload (autoload 'etaf-ncm-open "etaf-ncm" nil t)
;; Mount the player in `etaf-ncm-buffer-name' and return its buffer.
;; MODEL defaults to a session from `etaf-ncm-create', so the player opens on the
;; daily recommendation with the account, playback status and queue of the
;; backend.  A caller-provided MODEL keeps its library, selection and queue, and
;; is revived when it was displayed before.  The app fills the selected window
;; instead of letting a display rule split the frame.  The buffer hides its
;; mode line and takes its keys from the view's ETAF `:keys'; closing the buffer releases the
;; session's polling and pending requests, so a later `etaf-ncm-open' with the
;; same MODEL works again.  ? opens searchable, read-only help in this buffer;
;; dismissing it restores focus without changing playback or the queue.
;;
;; Function: etaf-ncm-close ()
;;;###autoload (autoload 'etaf-ncm-close "etaf-ncm" nil t)
;; Unmount the player and kill its buffer; the backend player keeps playing.
;; Unmounting releases the session's reactive subscriptions, polling timer and
;; in-flight backend requests; the session itself stays usable for a later mount.
;;
;; Function: etaf-ncm-quit ()
;;;###autoload (autoload 'etaf-ncm-quit "etaf-ncm" nil t)
;; Stop the backend player and close the client.
;; The stop reaches mpv before the buffer is gone, so quitting leaves nothing
;; playing; `etaf-ncm-close' only closes the window.  Exiting Emacs stops a
;; player the app started as well, so mpv never survives the app as an orphan.
;;
;; Function: etaf-ncm-view (&optional model)
;;;###autoload (autoload 'etaf-ncm-view "etaf-ncm" nil t)
;; Return the player View for MODEL, defaulting to a new session.
;; Use it to embed the player in your own `etaf-mount' call, for example inside a
;; tab or a larger layout; `etaf-ncm-open' is the shortcut that also owns the
;; buffer.
;;
;; Component: etaf-ncm-app (&key model)
;; Render the mounted player for MODEL and own its session lifecycle.
;; MODEL must come from `etaf-ncm-create'.  Mounting provides the palette for its
;; subtree, starts playback polling and loads the current library; unmounting
;; disposes the session.  The Component reads every displayed value from the
;; model, so any action or backend reply repaints it; prefer `etaf-ncm-open' or
;; `etaf-ncm-view' over mounting the Component directly.
;;
;; Function: etaf-ncm-login (&optional app)
;;;###autoload (autoload 'etaf-ncm-login "etaf-ncm" nil t)
;; Sign in to the backend with a phone number and an SMS verification code.
;; APP defaults to the mounted player or the one in the current buffer.  The
;; phone number is read in the minibuffer, with the number the backend
;; remembers as the default; the code is read once the backend reports the text
;; went out.  On success the backend stores the cookie and the player reloads
;; its account and libraries.  It signals a `user-error' when no player is
;; available and `etaf-ncm-error' for a malformed phone number or code.
;;
;; Function: etaf-ncm-create (&key client cache-file)
;; Return a new player session that talks to CLIENT.
;; CLIENT defaults to `etaf-ncm-client-factory' when that is bound and otherwise
;; to `etaf-ncm-make-client'.  The session owns no buffer and no timer before it
;; is mounted, so it is a complete headless player for scripts and tests.  Pass a
;; CLIENT function to drive the same player from another backend. CACHE-FILE
;; optionally selects a disposable local sidebar snapshot, restored before mount.
;; The default client uses library-cache.eld in its state directory; injected
;; function clients stay in memory unless CACHE-FILE is supplied. Snapshots are
;; credential-scoped, size-bounded, atomically replaced and never evaluated.
;;
;; Function: etaf-ncm-now-geometry (columns rows char-width line-height &optional mode spectrum lyric-lines)
;; Return the playing page's cell geometry for a COLUMNS by ROWS region.
;; CHAR-WIDTH and LINE-HEIGHT are the frame's cell size in pixels.  MODE is
;; `auto', `immersive' — one picture across the page, with the text column over
;; its faded edge — or `split' — the picture in one pane and the text in the
;; other.  SPECTRUM is the bar text the page has to draw, or nil when the bars
;; take no rows; LYRIC-LINES is how many lyric rows the page must hold.
;; The plist carries `:mode', `:stacked', the picture band (`:hero-columns',
;; `:hero-rows'), the text column (`:panel-left', `:panel-top',
;; `:panel-columns', `:panel-rows', `:content-columns'), the square the sharp
;; cover keeps (`:art-columns', `:art-rows', `:art-left', `:art-top') and the
;; `:fade' edge.  The cover stays square in pixels, not in cells.
;;
;; Function: etaf-ncm-now-sections (rows &optional max-lyrics spectrum lyric-lines)
;; Return the playing page's parts for a window ROWS tall.
;; MAX-LYRICS caps the lyric block, and zero drops it; LYRIC-LINES answers
;; whether the song has words at all, so a poster on a small window keeps the
;; picture, the track and the controls without words crowded into the middle.
;; The plist carries `:header', `:artist', `:bars', `:title' and `:lyrics': the
;; page drops the spectrum, the artist line and finally the header as the panel
;; shrinks, and the lyric takes every row the fixed parts leave.
;;
;; Function: etaf-ncm-meter-start (source position &optional cache-key)
;; Start decoding SOURCE from POSITION seconds for the page's spectrum (nil when
;; it already reads that source).  SOURCE is the file or stream the backend is
;; playing; a seek restarts the decoder, and a missing ffmpeg is not an error.
;;
;; Function: etaf-ncm-meter-stop ()
;; Stop the spectrum decoder and forget its samples.
;;
;; Function: etaf-ncm-meter-live-p ()
;; Return non-nil while a decoder feeds the spectrum.
;;
;; Function: etaf-ncm-meter-levels (bars)
;; Return BARS audio levels in 0..1 for the newest decoded samples, each rising
;; at once and falling slowly.  Without a live decoder every level is silence.
;;
;; Function: etaf-ncm-state (app)
;; Return APP's session state as a detached plist snapshot.
;; Keys are `:section', `:title', `:subtitle', `:mode', `:query', `:items',
;; `:visible', `:window-start', `:selection', `:page-size', `:rows-total',
;; `:list-total', `:queue-rows', `:queue-start', `:lyric-rows',
;; `:status', `:queue', `:lyric', `:lyric-line', `:aside', `:theme', `:account',
;; `:downloads' (the local download registry), `:layout', `:pane', `:viewport-width' (the pixel canvas the player mounts
;; into), `:loading', `:error' and `:message'.  `:layout' is one of `wide',
;; `medium', `narrow', `card' or `tile': the card family is the small-size
;; player that keeps one pane, its switch and the transport, and shows no
;; header, library strip or player bar.  The snapshot copies
;; every value, so mutating it never changes the player; use it to render
;; outside ETAF or to assert behavior in tests.
;; `:status' includes normalized `:vip' and `:quality' when reported by the
;; backend; missing quality is nil. These describe the playing song.
;; `:rows-total' counts loaded library rows; `:list-total' keeps the backend's
;; total when reported and otherwise equals the loaded count.  `:queue-rows'
;; and `:lyric-rows' are panel line budgets (translations use lyric lines too);
;; `:queue-start' is the zero-based start of the loaded queue window.
;;
;; Function: etaf-ncm-refresh (app)
;; Reload APP's library, playback status, queue and account.
;; A mounted player fits its layout and row budgets to its viewport instead
;; of a refresh, so resizing the player's region needs no call.  Every request
;; is asynchronous and a reply belonging to a superseded load is dropped,
;; which makes repeated refreshes safe.
;;
;; Function: etaf-ncm-locate (app section)
;; Show SECTION of APP's library.
;; SECTION is one of the keys in `etaf-ncm-sections': `:daily', `:fm',
;; `:liked', `:playlists', `:albums', `:artists', `:charts', `:podcasts' or
;; `:recent'.  An unknown SECTION signals `etaf-ncm-error' and leaves APP
;; unchanged.
;;
;; Function: etaf-ncm-search (app keyword &optional scope)
;; Search KEYWORD and show the results as APP's library.
;; SCOPE is `song' (the default) or `album'/`artist'/`playlist' as accepted by
;; the backend.  A blank KEYWORD signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-play (app &optional item)
;; Play ITEM, or APP's current library when ITEM is nil.
;; ITEM is a library row as reported in `etaf-ncm-state' `:items'; a row carries
;; at least `:kind' and `:id'.  A song row in the daily, liked or FM library
;; queues the loaded ids and starts at that row in one backend command.
;; Other songs play directly, while a playlist, album,
;; artist, chart or podcast is resolved by the backend into its playable songs.
;; A row without a playable target signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-add-to-queue (app item)
;; Append the song ITEM to the queue.
;; The queue is the backend's queue file, so the running mpv session keeps
;; playing; a non-song ITEM signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-download (app item)
;; Download the song ITEM into APP's local library.
;; The backend fetches the best quality the account can play, stores the file
;; under its configured download directory and registers it.  Downloaded songs
;; get a check mark in the list, and the next queue for that song plays the
;; local file instead of fetching a fresh stream URL.  A song that is already
;; downloaded is refreshed in place; a non-song ITEM signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-download-selection (app)
;; Download the library row APP's selection points at.
;; An empty library does nothing.
;;
;; Function: etaf-ncm-row-action (app index key)
;; Run action KEY on library row INDEX (counting from 1) in APP.
;; KEY is `play', `queue' or `download'; the inline icon resolves the row when
;; pressed, so a list reply that moved in between cannot act on a stale row.
;; An out-of-range INDEX or unknown KEY signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-jump-queue (app index)
;; Play the queue entry at 1-based INDEX.
;; INDEX outside the queue signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-toggle-playback (app)
;; Pause APP's playback when it is playing and resume it otherwise.
;;
;; Function: etaf-ncm-next-track (app)
;; Play the next track of the queue.
;;
;; Function: etaf-ncm-previous-track (app)
;; Play the previous track of the queue.
;;
;; Function: etaf-ncm-stop (app)
;; Stop playback and leave the queue.
;;
;; Function: etaf-ncm-set-volume (app volume)
;; Set the backend volume to VOLUME, an integer from 0 to 100.
;; The backend clamps out-of-range values; the player reports the volume the
;; backend accepted after its next status poll.
;;
;; Function: etaf-ncm-seek (app seconds)
;; Seek SECONDS from the current position, positive forward and negative back.
;;
;; Function: etaf-ncm-set-shuffle (app on)
;; Turn shuffle mode on when ON is non-nil and off otherwise.
;;
;; Function: etaf-ncm-set-repeat (app on)
;; Turn list repeat (列表循环) on when ON is non-nil and off otherwise.
;; The existing backend repeat command controls mpv's loop-playlist.
;;
;; Function: etaf-ncm-like (app &optional unlike)
;; Add the current song to the liked songs, or remove it when UNLIKE is non-nil.
;;
;; Function: etaf-ncm-move-selection (app delta)
;; Move APP's library selection by DELTA rows and keep it inside the visible page.
;; Selection stops at the first and last row; moving past a page boundary scrolls
;; the page so the new selection stays visible.
;;
;; Function: etaf-ncm-activate-selection (app)
;; Play the row APP's selection points at, doing nothing on an empty library.
;;
;; Function: etaf-ncm-press-row (app index)
;; Press library row INDEX (counting from 1): select it, or play it when it is
;; the selected row or was pressed twice in quick succession.  This is the
;; gesture a click on a list row performs, which a programmatic caller can use
;; to follow the same sentence.  An out-of-range INDEX signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-toggle-aside (app)
;; Switch APP's side panel between the lyric and the queue.
;;
;; Function: etaf-ncm-show-pane (app pane)
;; Show PANE in APP and return it.
;; PANE is `list' for the library list or `aside' for the lyric and queue panel;
;; any other PANE signals `etaf-ncm-error'.  A `wide' layout keeps every column
;; visible, so there PANE is remembered without removing anything; medium,
;; narrow, `card' and `tile' layouts show that single pane.
;;
;; Variable: etaf-ncm-sections
;; Sidebar groups and their libraries, as (GROUP-NAME (SECTION LABEL ICON) ...).
;; ICON names a glyph of the shared `etaf-ui-icon' SVG set; rebind the variable
;; before mounting a session to show a different catalog of libraries, and keep
;; each SECTION accepted by `etaf-ncm-locate'.
;;
;; Variable: etaf-ncm-buffer-name
;; Buffer `etaf-ncm-open' mounts the player into.
;;
;; Variable: etaf-ncm-page-size
;; Library rows shown at once.  A mounted player replaces it with the count
;; that fits its viewport, so the default only applies to a headless session.
;;
;; Variable: etaf-ncm-render-limit
;; Rows the library list keeps in its scrolling canvas, default 1000.  The
;; canvas lays every rendered row out once, so the cap bounds the mount cost.
;;
;; Variable: etaf-ncm-wheel-rows
;; Library and queue rows one wheel tick scrolls, default 3.  It matches the
;; step the rest of the canvas uses, so a small card does not need one notch per
;; song.
;;
;; Variable: etaf-ncm-wide-columns
;; Region width, in columns, that fits the library sidebar, the song list and the
;; side panel at the same time.  At or above this width the player uses the
;; `wide' layout: one selection in the list and the panel always visible.
;;
;; Variable: etaf-ncm-medium-columns
;; Region width, in columns, that still fits a narrow library rail.  At or above
;; this width, but below `etaf-ncm-wide-columns', the player keeps the glyph-only
;; rail and shows a single pane; below it the libraries move into a header strip
;; and every pane uses the full width.
;;
;; Variable: etaf-ncm-fetch-limit
;; Lower bound on rows requested for one library load, retained for callers
;; that configured it before `etaf-ncm-list-limit'.
;;
;; Variable: etaf-ncm-list-limit
;; Rows requested for one library load, default 1000.  The actual request is
;; the maximum of this value, `etaf-ncm-fetch-limit' and three visible pages.
;; Backend totals stay distinct from loaded counts when the reply is partial.
;;
;; Variable: etaf-ncm-library-refresh-interval
;; Seconds after which a cached library list is refreshed in the background,
;; default 300.
;; A cached list is shown at once when a library is opened and then compared
;; with a fresh reply; this interval decides when the idle refresh is due.
;;
;; Variable: etaf-ncm-prefetch-libraries
;; Whether a mounted player warms and refreshes library lists while idle,
;; default t.
;; One list at a time is loaded in the background, so opening a library that
;; was never visited can paint from the cache; nil keeps the cache to the
;; libraries the listener actually opens.
;;
;; Variable: etaf-ncm-status-interval
;; Seconds between playback ticks while a song is playing.
;; Each tick advances the local clock for a smooth progress bar and asks the
;; backend for playback truth; requests never overlap.
;;
;; Variable: etaf-ncm-idle-poll-interval
;; Seconds between playback checks while nothing is playing.
;;
;; Variable: etaf-ncm-theme-mode
;; Palette a new Emacs session starts with: `auto' (default, follows the host
;; appearance), `dark' or `light'.  The live mode is one reactive cell; the
;; player's T key and a panel's title-bar switch write it, and
;; `etaf-ncm-color' and `etaf-ncm-theme-defaults' read it, so the player and a
;; panel framing it share one appearance state.
;;
;; Function: etaf-ncm-color (key &optional mode)
;; Return the palette color for KEY, optionally reading MODE instead of the
;; player's live mode.
;; KEY is one of `:bg', `:panel', `:panel2', `:panel3', `:line', `:ink',
;; `:muted', `:dim', `:accent', `:accent-soft', `:gold', `:ok', `:danger',
;; `:danger-bg', `:playing', `:selected', `:meter' or `:cover'; an unknown KEY
;; signals `etaf-ncm-error'.  Views use it to stay readable in both palettes.
;;
;; Function: etaf-ncm-theme-defaults (&optional mode)
;; Return the `:ui-*' theme defaults of MODE as a property plist.
;; The list is what the mounted player provides to the ETAF UI controls in its
;; subtree, so buttons, inputs and badges follow the same palette.
;;
;; Function: etaf-ncm-make-client (&key backend-directory state-directory node-program timeout)
;; Return a client that calls the backend in BACKEND-DIRECTORY.
;; STATE-DIRECTORY is where the backend keeps its queue and login state,
;; NODE-PROGRAM runs the backend scripts, and TIMEOUT is the seconds a request
;; may take before it fails.  Every argument defaults to the matching
;; `etaf-ncm-' variable, and the returned client is usable with
;; `etaf-ncm-client-call'.
;;
;; Variable: etaf-ncm-client-factory
;; Function of no arguments returning the client of new sessions.
;; Bind it to drive `etaf-ncm-create' with another backend, which is how the
;; acceptance scenarios play a scripted session without network or mpv.
;;
;; Function: etaf-ncm-client-call (client request callback)
;; Send REQUEST to CLIENT and call CALLBACK once with its reply.
;; REQUEST is a plist starting with `:op' (`:browse', `:search', `:lyric',
;; `:session', `:status', `:queue', `:play', `:add', `:jump', `:volume',
;; `:seek', `:pause', `:resume', `:toggle', `:next', `:previous', `:stop',
;; `:like', `:unlike', `:liked-ids', `:shuffle', `:repeat', `:queue-save',
;; `:queue-load', `:login-sms' or `:login-sms-code').
;; CALLBACK receives `(:ok DATA)' on success and `(:error MESSAGE :hint HINT)' on
;; failure, at most once.  A failure the backend explains itself (its refusal
;; report) keeps that explanation as MESSAGE and its code as `:code';
;; only a crash without a report falls back to naming the exit status.  A client
;; that cannot answer calls it neither; a session that is disposed by
;; `etaf-ncm-cancel' drops late replies.
;;
;; Function: etaf-ncm-cancel (client)
;; Cancel CLIENT's pending requests and drop their late replies.
;;
;; Function: etaf-ncm-parse-lyric (text &optional translation)
;; Parse LRC TEXT into a list of (SECONDS . LINE) pairs, earliest first.
;; Metadata tags and timestamp-only lines are skipped, so the result is directly
;; usable as the `:lines' of a lyric; an empty result means an instrumental
;; track.
;;
;; Variable: etaf-ncm-backend-directory
;; Directory of the backend scripts used by the default client. The backend
;; ships inside this package; point it elsewhere only to try a modified copy.
;;
;; Variable: etaf-ncm-state-directory
;; Directory holding the backend's queue and login state. The client passes it
;; to the backend as `NETEASE_MUSIC_STATE_DIR'.
;;
;; Variable: etaf-ncm-node-program
;; Program used to run the backend's Node.js scripts.
;;
;; Variable: etaf-ncm-request-timeout
;; Seconds a backend request may take before it fails with a timeout error.
;;
;; Error: etaf-ncm-error
;; Invalid player operation, for example an unknown library, an empty search
;; keyword or a row without a playable target.  Backend failures are reported in
;; the session's `:error' and `:message' instead of being signaled, because they
;; happen asynchronously while the player stays usable.

;;; Code:

;; The archive compiles this entry from a script that is still being loaded, so
;; `load-file-name` names that script.  `byte-compile-current-file` names the
;; file being compiled and must win, then `lisp/` resolves while the compiler
;; works on the independent modules an archive install compiles one by one.
(eval-and-compile
  (let ((directory (file-name-directory
                    (or (and load-file-name
                             (not (string-suffix-p ".eln" load-file-name))
                             (file-directory-p (expand-file-name "lisp" (file-name-directory load-file-name)))
                             load-file-name)
                        (bound-and-true-p byte-compile-current-file)
                        (locate-library "etaf-ncm")
                        buffer-file-name))))
    (add-to-list 'load-path (expand-file-name "lisp" directory))))

(require 'etaf-ncm-theme)
(require 'etaf-ncm-layout)
(require 'etaf-ncm-service)
(require 'etaf-ncm-model)
(require 'etaf-ncm-views)
(require 'etaf-ncm-app)

(defun etaf-ncm-doctor ()
  "Return capability facts for playing music.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Nothing is installed or changed."
  (let ((backend (expand-file-name "scripts/netease-music.sh"
                                   etaf-ncm-backend-directory))
        (api (expand-file-name "scripts/netease-api.mjs"
                               etaf-ncm-backend-directory))
        (state (expand-file-name "config.json" etaf-ncm-state-directory)))
    (list :required
          (list (list "Bundled backend"
                      (and (file-readable-p backend) (file-readable-p api))
                      "Reinstall etaf-ncm; its backend ships inside the package.")
                (list "Node.js" (and (executable-find etaf-ncm-node-program) t)
                      "Install Node.js 22 or newer with your system package manager.")
                (list "Python 3" (and (executable-find "python3") t)
                      "Install Python 3; the backend's queue, download and mpv helpers are Python scripts.")
                (list "mpv" (and (executable-find "mpv") t)
                      "Install mpv with your system package manager; playback runs through it."))
          :optional
          (list (list "qrencode" (and (executable-find "qrencode") t)
                      "Optional: install qrencode for the QR sign-in code; sms login works without it.")
                (list "Account login" (and (file-readable-p state) t)
                      "Sign in once with the bundled backend's login --sms command.")))))

(provide 'etaf-ncm)
;;; etaf-ncm.el ends here
