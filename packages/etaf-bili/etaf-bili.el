;;; etaf-bili.el --- Bilibili video client built with ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.15") (etaf-ui "0.3.8") (etaf-db "0.1.0"))
;; Keywords: multimedia, ui
;; URL: https://github.com/emacs-taf/etaf-bili

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-bili) after adding this repository
;; and the ETAF, ETAF UI, ETAF DB, Ebox and ECSS roots to `load-path'.  The
;; client browses Bilibili and plays videos inside one ETAF buffer: a
;; responsive cover gallery (popular, partitioned ranking, personalized
;; recommendations, dynamic feed, Watch Later, watch history, favorites, UP
;; space and WBI search with direct BV/URL navigation) paired with a dedicated
;; Watch View offering WBI-signed DASH streams, quality/codec switching,
;; multi-part/collection episodes, local and cloud resume, CC/AI subtitles
;; with searchable transcript jump, danmaku, hot comments with timestamp jump,
;; related videos, zero-CPU background audio mode, Picture-in-Picture and
;; external mpv handoff.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions.
;;
;; Function: etaf-bili-doctor ()
;;;###autoload (autoload 'etaf-bili-doctor "etaf-bili" nil nil)
;; Return capability facts for `etaf-bili' matching `etaf-install-doctor'.
;;
;; Function: etaf-bili-open (&optional fresh)
;;;###autoload (autoload 'etaf-bili-open "etaf-bili" nil t)
;; Open or focus the client buffer (`*Bili*') preserving the user's mode-line.
;; Reuses an already-open session unless FRESH is non-nil.
;;
;; Function: etaf-bili-open-video (bvid-or-url &optional start-seconds cid)
;;;###autoload (autoload 'etaf-bili-open-video "etaf-bili" nil t)
;; Open BVID-OR-URL directly in Watch View at optional START-SECONDS and CID.
;;
;; Function: etaf-bili-close ()
;;;###autoload (autoload 'etaf-bili-close "etaf-bili" nil t)
;; Tear down the runtime and kill the client buffer.
;;
;; Function: etaf-bili-create ()
;;;###autoload (autoload 'etaf-bili-create "etaf-bili" nil t)
;; Create a headless client session to mount through `etaf-bili-view'.
;;
;; Function: etaf-bili-view (session)
;;;###autoload (autoload 'etaf-bili-view "etaf-bili" nil t)
;; Return SESSION's embeddable View, adapting to `(etaf-viewport)'.
;;
;; Function: etaf-bili-login (&optional session)
;;;###autoload (autoload 'etaf-bili-login "etaf-bili" nil t)
;; Show the Bilibili QR sign-in overlay over SESSION.
;;
;; Function: etaf-bili-account-cancel (session)
;;;###autoload (autoload 'etaf-bili-account-cancel "etaf-bili" nil nil)
;; Close SESSION's sign-in panel and stop its polling timer.
;;
;; Function: etaf-bili-logout (&optional session)
;;;###autoload (autoload 'etaf-bili-logout "etaf-bili" nil t)
;; Ask for confirmation, sign out through the backend and clear cookies.
;;
;; Function: etaf-bili-account (&optional session)
;;;###autoload (autoload 'etaf-bili-account "etaf-bili" nil t)
;; Report the account the stored cookies belong to and publish it to SESSION.
;;
;; Function: etaf-bili-next ()
;; Select and focus the next video in the gallery.
;;
;; Function: etaf-bili-previous ()
;; Select and focus the previous video in the gallery.
;;
;; Function: etaf-bili-play ()
;; Resolve the selected video's stream and open it in Watch View.
;;
;; Function: etaf-bili-search (session keyword &optional order)
;; Search videos for KEYWORD (optional sort ORDER) and show results in SESSION.
;;
;; Function: etaf-bili-search-prompt ()
;; Begin native editing of the in-page SearchField (accepts keywords or BV/URL).
;;
;; Function: etaf-bili-details ()
;; Open the selected video's metadata in a catalog Drawer.
;;
;; Function: etaf-bili-open-author-space ()
;; Open the current or selected video creator's upload space.
;;
;; Function: etaf-bili-return-to-watch ()
;; Return to Watch View for the active video.
;;
;; Function: etaf-bili-popular ()
;; Load the currently popular videos.
;;
;; Function: etaf-bili-ranking ()
;; Load the ranking feed.
;;
;; Function: etaf-bili-rcmd ()
;; Load personalized home recommendations.
;;
;; Function: etaf-bili-dynamic ()
;; Load followed creators' dynamic video feed.
;;
;; Function: etaf-bili-toview ()
;; Load the Watch Later list.
;;
;; Function: etaf-bili-history ()
;; Load watch history.
;;
;; Function: etaf-bili-favorites ()
;; Load the signed-in user's favorite folders and videos.
;;
;; Function: etaf-bili-refresh ()
;; Reload the current buffer's active gallery channel.
;;
;; Function: etaf-bili-toggle-theme ()
;; Switch the client between the dark and light palette.
;;
;; Function: etaf-bili-watch-toggle ()
;; Toggle play/pause in Watch View or background audio mode.
;;
;; Function: etaf-bili-watch-back-10 ()
;; Seek backward 10 seconds in Watch View.
;;
;; Function: etaf-bili-watch-forward-10 ()
;; Seek forward 10 seconds in Watch View.
;;
;; Function: etaf-bili-watch-step ()
;; Step one frame while paused in Watch View.
;;
;; Function: etaf-bili-watch-cycle-speed ()
;; Cycle playback speed in Watch View.
;;
;; Function: etaf-bili-watch-speed-up ()
;; Increase playback speed one step.
;;
;; Function: etaf-bili-watch-speed-down ()
;; Decrease playback speed one step.
;;
;; Function: etaf-bili-watch-volume-down ()
;; Decrease playback volume by 10%.
;;
;; Function: etaf-bili-watch-volume-up ()
;; Increase playback volume by 10%.
;;
;; Function: etaf-bili-watch-toggle-audio ()
;; Mute or unmute playback sound.
;;
;; Function: etaf-bili-watch-quality-menu ()
;; Open or close the quality and CDN failover dialog.
;;
;; Function: etaf-bili-watch-cycle-subtitle ()
;; Toggle or cycle CC/AI subtitle tracks.
;;
;; Function: etaf-bili-watch-toggle-danmaku ()
;; Toggle danmaku display.
;;
;; Function: etaf-bili-watch-toggle-theater ()
;; Toggle wide theater mode (hide/show side panel).
;;
;; Function: etaf-bili-watch-toggle-fullscreen ()
;; Toggle in-window pure cinema fullscreen mode in Watch View (`f').
;;
;; Function: etaf-bili-watch-toggle-frame-fullscreen ()
;; Toggle dedicated OS/frame fullscreen mode in Watch View (`F'), saving and
;; restoring Emacs window splits, frame state and mode-line cleanly.
;;
;; Function: etaf-bili-watch-toggle-drawer ()
;; Open or close the side panel Drawer in narrow/theater viewports.
;;
;; Function: etaf-bili-watch-toggle-audio-only ()
;; Toggle zero-CPU background audio-only mode.
;;
;; Function: etaf-bili-watch-toggle-pip ()
;; Toggle floating Picture-in-Picture child-frame video.
;;
;; Function: etaf-bili-watch-toggle-auto-next ()
;; Toggle auto-advance on video completion.
;;
;; Function: etaf-bili-watch-next ()
;; Advance to the next part, episode or gallery video.
;;
;; Function: etaf-bili-watch-previous ()
;; Move to the previous part, episode or gallery video.
;;
;; Function: etaf-bili-watch-back ()
;; Leave Watch View and return to the Gallery (keeping audio-only alive).
;;
;; Function: etaf-bili-watch-escape ()
;; Dismiss the topmost Watch overlay or return to the Gallery.
;;
;; Function: etaf-bili-watch-jump-digit ()
;; Jump to 0%..90% of video duration according to the pressed digit key.
;;
;; Function: etaf-bili-open-external ()
;; Launch the configured external player (e.g. mpv) at the current second.
;;
;; Function: etaf-bili-open-in-browser ()
;; Open the current video in the system web browser at the current timestamp.
;;
;; Function: etaf-bili-copy-org-link ()
;; Copy an Org-mode timestamp link reopening this video at the current second.
;;
;; Function: etaf-bili-session-create (&key client)
;; Create a headless session with backend CLIENT.
;;
;; Function: etaf-bili-session-state (session)
;; Return SESSION's public state as a detached plist.
;;
;; Function: etaf-bili-load-popular (session)
;; Load the popular feed into SESSION.
;;
;; Function: etaf-bili-load-ranking (session &optional rid)
;; Load the ranking feed (optional partition RID) into SESSION.
;;
;; Function: etaf-bili-load-rcmd (session)
;; Load personalized home recommendations into SESSION.
;;
;; Function: etaf-bili-load-dynamic (session)
;; Load followed creators' dynamic videos into SESSION.
;;
;; Function: etaf-bili-load-toview (session)
;; Load Watch Later into SESSION.
;;
;; Function: etaf-bili-load-history (session)
;; Load watch history into SESSION.
;;
;; Function: etaf-bili-load-favorites (session &optional folder-id)
;; Load favorites (optional FOLDER-ID) into SESSION.
;;
;; Function: etaf-bili-load-space (session mid &optional name)
;; Load videos uploaded by creator MID into SESSION.
;;
;; Function: etaf-bili-load-more (session)
;; Load the next page of SESSION's current paginated channel.
;;
;; Function: etaf-bili-reload (session)
;; Reload SESSION's current gallery view.
;;
;; Function: etaf-bili-move (session delta)
;; Move SESSION's selection by DELTA items, clamped to bounds.
;;
;; Function: etaf-bili-selected-row (session)
;; Return SESSION's selected video row plist, or nil.
;;
;; Function: etaf-bili-play-selected (session on-ready)
;; Resolve SESSION's selected stream and deliver the source plist to ON-READY.
;;
;; Function: etaf-bili-play-target (session target on-ready &optional cid qn force-refresh)
;; Resolve stream for TARGET plist (`:bvid' or `:aid') and deliver to ON-READY.
;;
;; Function: etaf-bili-parse-target (input)
;; Parse INPUT string as a BV id, av number, video URL or b23.tv short URL.
;;
;; Function: etaf-bili-subtitle-at (cues seconds)
;; Binary-search sorted subtitle CUES for the cue active at SECONDS.
;;
;; Function: etaf-bili-danmaku-window (entries seconds &optional span limit)
;; Return up to LIMIT danmaku entries visible around SECONDS within SPAN.
;;
;; Function: etaf-bili-extract-timestamps (text)
;; Extract `(SECONDS . LABEL)' timestamp jumps from comment TEXT.
;;
;; Function: etaf-bili-store-progress-put (bvid cid position duration &optional title)
;; Save local resume POSITION and DURATION for BVID and CID.
;;
;; Function: etaf-bili-store-progress-get (bvid &optional cid)
;; Return saved `(POSITION . DURATION)' for BVID and CID, or nil.
;;
;; Function: etaf-bili-store-resume-seconds (bvid &optional cid cloud-seconds duration)
;; Compute the effective resume second from local and cloud progress.
;;
;; Function: etaf-bili-store-pref-put (key value)
;; Persist viewing preference KEY with VALUE.
;;
;; Function: etaf-bili-store-pref-get (key &optional default)
;; Return persisted viewing preference KEY or DEFAULT.
;;
;; Function: etaf-bili-store-search-history-add (keyword)
;; Record KEYWORD in recent search history.
;;
;; Function: etaf-bili-store-search-history ()
;; Return recent search keywords.
;;
;; Function: etaf-bili-make-client (&key state-directory timeout)
;; Create the default curl-backed backend client.
;;
;; Function: etaf-bili-wbi-query (params mixin-key &optional wts)
;; Sign PARAMS with MIXIN-KEY and return the WBI query string with `w_rid'.
;;
;; Function: etaf-bili-parse-videos (data)
;; Parse a video list response DATA into normalized row plists.
;;
;; Function: etaf-bili-client-call (client request callback)
;; Perform one backend REQUEST and deliver `(:ok DATA)' or `(:error MSG)' to CALLBACK.
;;
;; Variable: etaf-bili-client-factory
;; Function returning the backend client used by new sessions (nil for curl).
;;
;; Error: etaf-bili-error
;; Signaled for client-level failures such as unusable WBI keys or non-JSON bodies.
;;
;; Variable: etaf-bili-state-directory
;; Directory holding the cookie jar, cover cache and local SQLite state.
;;
;; Variable: etaf-bili-store-file
;; Optional override path for the SQLite watch-progress and preferences database.
;;
;; Variable: etaf-bili-request-timeout
;; Seconds before one backend request is abandoned (default 20).
;;
;; Variable: etaf-bili-curl-program
;; curl executable used for every request.
;;
;; Variable: etaf-bili-preferred-quality
;; Preferred Bilibili quality id when opening a video (default 80 = 1080P).
;;
;; Variable: etaf-bili-preferred-codecs
;; Ordered DASH video codec prefix preference (default H.264, HEVC, AV1).
;;
;; Variable: etaf-bili-external-player
;; External video player executable launched by `etaf-bili-open-external' (default "mpv").
;;
;; Variable: etaf-bili-theme-mode
;; New-session appearance: `dark' (default) or `light'.
;;
;; Variable: etaf-bili-node-program
;; Node.js executable that runs the bundled account backend ("node" by default).
;;
;; Variable: etaf-bili-backend-directory
;; Directory of the bundled account backend (`backends/bili').
;;
;; Variable: etaf-bili-backend-command
;; Command prefix overriding the bundled backend (nil by default).
;;
;; Variable: etaf-bili-login-poll-interval
;; Seconds between two sign-in polls (default 2).
;;
;; Variable: etaf-bili-login-timeout
;; Seconds QR sign-in waits for confirmation (default 180).

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-bili")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-bili.el" dir))
                                (file-exists-p (expand-file-name "etaf-bili.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-bili-account)
(require 'etaf-bili-app)

(provide 'etaf-bili)
;;; etaf-bili.el ends here
