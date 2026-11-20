;;; etaf-bili.el --- Bilibili video client built with ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0"))
;; Keywords: multimedia, ui
;; URL: https://github.com/emacs-taf/etaf-bili

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-bili) after adding this repository
;; and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  The client
;; browses Bilibili in one ETAF buffer: a searchable video list (the popular
;; feed by default, the all-category ranking or search results), a details
;; column for the selected row, and playback of the selected video inside the
;; framework's `etaf-media-viewer' Component.  Streams are resolved through
;; the web API and played with the Referer and User-Agent headers the CDN
;; requires; curl performs every request asynchronously, so the interface
;; never blocks.
;;
;; A session is one buffer (`*Bili*') with one backend client and one
;; session record.  The commands below drive it, and the session-level
;; functions (also listed here) take the session record directly so tests and
;; scripts can drive them headless.  The default keymap binds the commands:
;; j/k or n/p select a row, RET plays it, / searches, 1 loads the popular
;; feed, 2 the ranking, g refreshes, T toggles the appearance, q closes.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions.
;;
;; Function: etaf-bili-login (&optional session)
;; Show the sign-in code as an `etaf-ui-qr-login' panel over the running
;; client: the library keeps its content and only dims.  SESSION defaults to
;; the current buffer's; without one the client opens first.  A phone
;; confirms the scan, then the panel closes, the header's account chip shows
;; the name and the library reloads.  The bundled backend (backends/bili,
;; Node.js only) updates the cookie jar every request uses.  The phone-number
;; method is absent because the site gates its SMS endpoint behind a graphical
;; captcha.
;;
;; Function: etaf-bili-account-cancel (session)
;; Close SESSION's sign-in panel and stop polling for its code; the dismissal
;; the panel's cancel button performs.
;;
;; Function: etaf-bili-logout (&optional session)
;; Ask for confirmation, sign out through the backend and drop the stored
;; Bilibili cookies; the account chip returns to the signed-out label.
;;
;; Function: etaf-bili-account (&optional session)
;; Report the account the stored cookies belong to, or that nobody is signed
;; in, and publish it to SESSION.
;;
;; Variable: etaf-bili-node-program
;; Node.js executable that runs the bundled account backend, "node" by
;; default.
;;
;; Variable: etaf-bili-backend-directory
;; Directory of the bundled account backend (backends/bili in this
;; repository).
;;
;; Variable: etaf-bili-backend-command
;; Command prefix overriding the bundled backend, nil by default; the public
;; suite injects a stand-in script through it.
;;

;; Variable: etaf-bili-login-poll-interval
;; Seconds between two sign-in polls, 2 by default.
;;
;; Variable: etaf-bili-login-timeout
;; Seconds the QR sign-in waits for confirmation, 180 by default.
;;
;; Function: etaf-bili-open ()
;;;###autoload (autoload 'etaf-bili-open "etaf-bili" nil t)
;; Open the client in its own buffer and return that buffer.
;; The popular feed starts loading immediately.
;;
;; Function: etaf-bili-close ()
;;;###autoload (autoload 'etaf-bili-close "etaf-bili" nil t)
;; Tear down the runtime and kill the client buffer.
;;
;; Function: etaf-bili-create ()
;;;###autoload (autoload 'etaf-bili-create "etaf-bili" nil t)
;; Create a client session to mount through `etaf-bili-view'.
;; A session is headless until a View is mounted and creation sends no
;; request, so a caller can build it before a window exists.  Every host gets
;; its own session, so a desktop window and a panel do not share selection or
;; playback.
;;
;; Function: etaf-bili-view (session)
;;;###autoload (autoload 'etaf-bili-view "etaf-bili" nil t)
;; Return SESSION's View for mounting in a host of your own.
;; The View lays out for the region it is given and follows that region's
;; resizes, so a desktop window or a floating panel reflows the card grid.
;; Mounting adopts the host buffer: the client's keys, the inline search and
;; the session-level commands find SESSION there.  The first mount loads the
;; popular feed; a session that already has a library only refits, so a panel
;; reopened with `:keep-alive' resumes where it was.  Unmounting stops the
;; session's transfers and polling but keeps its library, selection and
;; account for the next mount.
;;
;; Function: etaf-bili-next ()
;; Select and focus the next video; clamp at the last item.
;;
;; Function: etaf-bili-previous ()
;; Select and focus the previous video; clamp at the first item.
;;
;; Function: etaf-bili-play ()
;; Resolve the selected video's stream and open it in the media viewer.
;;
;; Function: etaf-bili-search (session keyword)
;; Search videos for KEYWORD and show the results in SESSION.
;; Empty or whitespace-only keywords are ignored.
;;
;; Function: etaf-bili-search-prompt ()
;; Begin native editing of the in-page SearchField. Return submits the query;
;; Escape keeps its draft. No minibuffer or additional window is opened.
;;
;; Function: etaf-bili-details ()
;; Open the selected video's metadata in a catalog Drawer. Escape closes it
;; and restores focus; no permanently empty side column is reserved.
;;
;; Function: etaf-bili-popular ()
;; Load the currently popular videos.
;;
;; Function: etaf-bili-ranking ()
;; Load the all-category ranking.
;;
;; Function: etaf-bili-refresh ()
;; Command: reload the current buffer's view.
;;
;; Function: etaf-bili-toggle-theme ()
;; Switch the client between the dark and light palette.
;;
;; Function: etaf-bili-session-create (&key client)
;; Create a session with the backend CLIENT.
;; CLIENT defaults to `etaf-bili-client-factory' when bound, otherwise the
;; default curl client.  The session starts empty on the popular feed.
;;
;; Function: etaf-bili-session-state (session)
;; Return SESSION's public state as a detached plist.
;; Keys are `:mode', `:keyword', `:status', `:loading', `:items', `:selected'
;; `:playback', `:error' and `:play-loading'; each `:items' row carries the fields documented on
;; `etaf-bili-selected-row'.
;;
;; Function: etaf-bili-load-popular (session)
;; Load the popular feed into SESSION.
;;
;; Function: etaf-bili-load-ranking (session)
;; Load the all-category ranking into SESSION.
;;
;; Function: etaf-bili-reload (session)
;; Reload SESSION's current view (popular, ranking or the last search).
;;
;; Function: etaf-bili-move (session delta)
;; Move SESSION's selection by DELTA rows, clamped to the list.
;;
;; Function: etaf-bili-selected-row (session)
;; Return SESSION's selected row plist, or nil when the list is empty.
;; Rows carry `:bvid', `:aid', `:title', `:author', `:duration' (seconds),
;; `:views' (a display string), `:date' and `:cover'.
;;
;; Function: etaf-bili-play-selected (session on-ready)
;; Resolve the selected video's stream and call ON-READY with a source plist.
;; The plist is an `etaf-video' source (`:url' plus the CDN `:headers') with
;; `:title', `:bvid' and `:duration'; failures only change SESSION's status.
;;
;; Function: etaf-bili-make-client (&key state-directory timeout)
;; Create the default curl-backed backend client.
;; STATE-DIRECTORY holds the cookie jar; both keywords default to the
;; corresponding defcustoms.  The client is returned as a plist which
;; `etaf-bili-client-call' accepts; a plain function accepting
;; (REQUEST CALLBACK) may be used in its place.
;;
;; Function: etaf-bili-wbi-query (params mixin-key &optional wts)
;; Sign PARAMS with MIXIN-KEY and return the query string with `w_rid'.
;; A `wts' timestamp (defaulting to the current time) is appended, keys are
;; sorted, values encode like `encodeURIComponent', and the MD5 covers the
;; query plus the mixin key.  Exposed so the signature contract is testable
;; without the network; a missing key signals `etaf-bili-error'.
;;
;; Function: etaf-bili-parse-videos (data)
;; Parse a video list response DATA into row plists.
;; DATA is the `data' object of a popular, ranking or search response parsed
;; by `json-parse-string' with an alist object type; rows match the contract
;; of `etaf-bili-selected-row'.
;;
;; Function: etaf-bili-client-call (client request callback)
;; Perform one backend REQUEST and deliver the result to CALLBACK.
;; REQUEST is a plist with an `:op': `(:op :popular :page N)',
;; `(:op :ranking)', `(:op :search :keyword K :page N)',
;; `(:op :video :bvid B)', `(:op :play :bvid B)' or `(:op :cover :url U)'.
;; The cover operation accepts Bilibili image CDN URLs and returns a local
;; cached image path. Downloads are capped at 2 MiB. CALLBACK receives
;; `(:ok DATA)' or `(:error MESSAGE :hint HINT)'.  The `:play' operation
;; chains the metadata and stream steps and returns the stream source.
;;
;; Variable: etaf-bili-client-factory
;; Function returning the backend client used by new sessions.
;; Nil (the default) selects the curl client; tests bind this to a fake.
;;
;; Error: etaf-bili-error
;; Signaled for client-level failures such as unusable WBI keys or a
;; non-JSON response body.
;;
;; Variable: etaf-bili-state-directory
;; Directory holding the client's cookie jar and other local state.
;;
;; Variable: etaf-bili-request-timeout
;; Seconds before one backend request is abandoned (default 20).
;;
;; Variable: etaf-bili-curl-program
;; curl executable used for every request.
;;
;; Variable: etaf-bili-theme-mode
;; New-session appearance: `dark' (default) or `light', independent of
;; Emacs's theme.  Press T to switch the running client.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-bili-account)
(require 'etaf-bili-app)

(provide 'etaf-bili)
;;; etaf-bili.el ends here
