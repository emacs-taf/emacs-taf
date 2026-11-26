;;; maillist.el --- Mailing-list archive client -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.4.4
;; Package-Requires: ((emacs "29.1") (etaf "0.3.6") (etaf-ui "0.3.4") (etaf-db "0.1.0"))
;; Keywords: mail
;; URL: https://github.com/emacs-taf/maillist

;;; Commentary:

;; maillist reads public-inbox archives as a mail client: the thread list,
;; the open conversation and the reader's own read and starred marks.  The
;; archive cache, cached bodies, marks (with last-read snapshots to detect new
;; replies on previously read threads) and settings live in one SQLite file.
;; Replies target the focused message (or newest message), keep canonical
;; `In-Reply-To' and RFC 5322 `References' ancestor chains, route GNU Debbugs
;; replies to `<bug>@debbugs.gnu.org', and leave through smtpmail or Emacs's
;; own `message-send-mail-function'.
;;
;; Load this package with (require 'maillist) after adding this repository
;; root and the ETAF, ETAF UI, Ebox, ECSS and ETAF DB roots to `load-path'.
;; Then use M-x maillist-open.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  This Commentary is the authoritative export
;; list; implementations and precise docstrings remain beside their
;; definitions.
;;
;; Function: maillist-open (&key (sync t) list)
;;;###autoload (autoload 'maillist-open "maillist" nil t)
;; Mount the client in its own buffer and return that buffer.  SYNC nil opens
;; from the local cache without contacting the archive, and LIST names the
;; archive to read; without it the client opens the one it opened last.
;;
;; Function: maillist-close ()
;;;###autoload (autoload 'maillist-close "maillist" nil t)
;; Close the mounted client and kill its buffer.
;;
;; Function: maillist-create (&key list)
;; Create a client session over the archive LIST (a `maillist-sources' name)
;; and return it; without LIST it opens the archive this client opened last,
;; then `maillist-default-list'.  The open merges saved custom sources and
;; prunes what the store no longer needs.  The session holds reactive refs
;; `:threads', `:groups', `:open', `:selected', `:focused-message',
;; `:hide-quotes', `:scope', `:query', `:search-input', `:summary', `:status',
;; `:reading' and `:viewport', plus `:source' and `:store'.
;;
;; Function: maillist-dispose (session)
;; Release SESSION's store, cancel timers and ignore late archive answers.
;; Closing the mounted buffer does the same; use this with a session that has
;; no buffer.
;;
;; Function: maillist-refresh (session &optional quiet)
;; Reload SESSION's thread list from its archive; the request is asynchronous
;; and `:status' carries `loading', `idle' or `error' while it runs.  Rows
;; merge into `:archive-threads' so older cached rows stay and previously read
;; threads with newer replies re-surface as unread.  When a search is active,
;; the archive cache updates without replacing the visible search results.
;;
;; Function: maillist-select (session id &optional no-mark)
;; Open the thread ID of SESSION, fetching its body when uncached or stale,
;; and return the open-thread value.  Unless NO-MARK is non-nil, the thread
;; becomes read once its body is on screen.  A failed refresh keeps cached
;; messages on screen instead of wiping the reader.
;;
;; Function: maillist-move (session delta &optional no-open)
;; Move the selection by DELTA rows and open the new row, or only move the
;; selection highlight when NO-OPEN is non-nil.
;;
;; Function: maillist-next-unread (session)
;; Open the first unread row after SESSION's selection and return its id, or
;; nil when nothing after it is unread.
;;
;; Function: maillist-prev-unread (session)
;; Open the nearest unread row before SESSION's selection and return its id,
;; or nil when nothing before it is unread.
;;
;; Function: maillist-select-edge (session edge &optional no-open)
;; Select the first or last row SESSION shows (`first' or `last') and return
;; its id; when NO-OPEN is non-nil, only move the selection highlight.
;;
;; Function: maillist-select-message (session id)
;; Focus message ID inside SESSION's open thread so subsequent reply, raw-view
;; and copy commands target it.
;;
;; Function: maillist-move-message (session delta)
;; Move the focused message inside SESSION's open thread by DELTA and return
;; the newly focused message id.
;;
;; Function: maillist-toggle-message (session id)
;; Fold or unfold message ID of the open thread, focus it and return the new
;; collapsed state.
;;
;; Function: maillist-toggle-all-messages (session)
;; Collapse every visible message in SESSION's open thread when any is
;; expanded, otherwise expand all; return the new collapsed state.
;;
;; Function: maillist-toggle-quotes (session)
;; Toggle collapsing long quoted blocks (3+ lines) inside SESSION's reader
;; and return the new state.
;;
;; Function: maillist-reply (session &optional private message-id)
;; Reply to SESSION's open thread in `message-mode', targeting MESSAGE-ID,
;; `:focused-message' or the newest message.  With PRIVATE non-nil reply to
;; the message's author instead of the list; Debbugs lists address
;; `<bug>@debbugs.gnu.org'.  Keeps canonical `In-Reply-To' and `References'.
;;
;; Function: maillist-reply-all (session &optional message-id)
;; Reply to SESSION's open thread and copy the replied message's author in Cc
;; (excluding the sender's own address and the list address).
;;
;; Function: maillist-compose (session)
;; Write a new post to SESSION's list in a `message-mode' buffer.
;;
;; Function: maillist-mail-configure ()
;;;###autoload (autoload 'maillist-mail-configure "maillist" nil t)
;; Store the SMTP application password of the sending account in auth-source
;; with 0600 permissions for plaintext `~/.authinfo'.
;;
;; Function: maillist-add-source (name base address &optional reply-style)
;;;###autoload (autoload 'maillist-add-source "maillist" nil t)
;; Add or update a public-inbox archive source NAME at BASE with list ADDRESS
;; (and optional REPLY-STYLE such as `debbugs') and persist it in settings.
;;
;; Function: maillist-remove-source (name)
;;;###autoload (autoload 'maillist-remove-source "maillist" nil t)
;; Remove archive NAME from `maillist-sources' and saved custom sources.
;;
;; Function: maillist-toggle-star (session)
;; Star or unstar the selected row, persist the choice and return the new state.
;;
;; Function: maillist-set-read (session id read)
;; Set thread ID read or unread, persist the mark (and read snapshot when read)
;; and return the new state.
;;
;; Function: maillist-mark-all-read (session)
;; Mark every row SESSION shows read in one store transaction and return how
;; many changed.
;;
;; Function: maillist-load-earlier (session)
;; Grow the open thread's message window by `maillist-message-window' and
;; return the new window size.
;;
;; Function: maillist-set-scope (session scope)
;; Show only SCOPE's rows: `all', `unread' or `starred'.
;;
;; Function: maillist-search (session text)
;; Search the archive for TEXT, or restore `:archive-threads' when TEXT is
;; empty.  TEXT may name `from:', `to:', `subject:', `body:' and `message:'
;; (with optional leading `-'), `after:'/`before:', and local marks
;; `is:unread', `is:read', `is:starred' (or `-is:...').  When the archive
;; cannot answer, cached threads and bodies answer locally using the
;; structured terms.
;;
;; Function: maillist-load-older (session)
;; Add mail older than `:archive-threads'.  Uses the archive index's native
;; `?t=...' next-page cursor when available, otherwise falls back to date
;; search with timestamp comparison and automatic offset stepping.
;;
;; Function: maillist-recall-query (session &optional forward)
;; Search SESSION again with an older (FORWARD nil) or newer query from its
;; history and return the query now shown, empty for the archive list.
;;
;; Function: maillist-thread-url (session id)
;; Return the archive's own page for thread ID of SESSION.
;;
;; Function: maillist-thread-mbox-url (session id)
;; Return the downloadable `t.mbox.gz' archive URL for thread ID of SESSION.
;;
;; Function: maillist-rows (session)
;; Return the rows SESSION shows, in list order, honouring `:filters' and
;; `:scope'.
;;
;; Function: maillist-row (session id)
;; Return the row of SESSION named ID, or nil.
;;
;; Function: maillist-selected-row (session)
;; Return the row SESSION currently shows, or nil.
;;
;; Function: maillist-source (name)
;; Return the source named NAME from `maillist-sources'; an unknown name is an
;; error.
;;
;; Function: maillist-parse-index (html)
;; Parse a public-inbox index page into thread rows
;; (:id :subject :date :count :depth), newest first, with decoded canonical
;; Message-IDs.
;;
;; Function: maillist-decode-entities (text)
;; Return TEXT with named and numeric HTML entities decoded.
;;
;; Function: maillist-parse-search (html)
;; Parse a public-inbox search page into message rows (:id :subject :date
;; :author), newest first.
;;
;; Function: maillist-parse-thread (xml-text &optional fallback-subject)
;; Parse a public-inbox thread Atom document in a single pass into
;; (:id :subject :participants :messages).
;;
;; Function: maillist-parse-author (text)
;; Return the sender display name of the raw message TEXT, or nil.
;;
;; Function: maillist-parse-recent (xml-text)
;; Parse a public-inbox new-messages feed into (MESSAGE-ID . AUTHOR) hints.
;;
;; Function: maillist-classify-lines (text &optional prefix)
;; Split a message body into (:id :kind :text ...) lines.  KIND is `body',
;; `blank', `quote' (with `:quote-depth'), `signature', `patch-meta',
;; `patch-add' or `patch-del'.
;;
;; Function: maillist-message-links (text &optional include-quotes)
;; Return the web addresses of message TEXT in order without repeats, skipping
;; quoted lines unless INCLUDE-QUOTES is non-nil and preserving balanced
;; parentheses inside URLs.
;;
;; Function: maillist-thread-subject (subject)
;; Return SUBJECT without leading reply prefixes.
;;
;; Function: maillist-fetch-index (source callback)
;; Fetch SOURCE's thread list and call CALLBACK with (:ok ROWS) or (:error MSG).
;;
;; Function: maillist-fetch-thread (source id callback &optional subject)
;; Fetch thread ID and call CALLBACK with (:ok THREAD) or (:error MSG).
;;
;; Function: maillist-fetch-search (source query callback &optional offset)
;; Search SOURCE for QUERY (optionally at result OFFSET) and call CALLBACK
;; with (:ok ROWS) or (:error MSG).
;;
;; Function: maillist-compile-query (text)
;; Compile search TEXT into (:query REMOTE :filters FILTERS :terms TERMS).
;;
;; Function: maillist-fetch-subject (source subject callback)
;; Fetch every message whose subject matches SUBJECT and call CALLBACK with
;; (:ok THREAD).
;;
;; Function: maillist-fetch-message (source id callback)
;; Fetch message ID alone and call CALLBACK with (:ok THREAD).
;;
;; Function: maillist-fetch-author (source id callback)
;; Fetch the sender of message ID and call CALLBACK with (:ok AUTHOR).
;;
;; Function: maillist-fetch-raw (source id callback)
;; Fetch the raw RFC 5322 message ID and call CALLBACK with (:ok TEXT).
;;
;; Function: maillist-fetch-recent (source callback)
;; Fetch SOURCE's newest messages and call CALLBACK with (:ok HINTS).
;;
;; Function: maillist-time-label (stamp)
;; Return STAMP read as a list label: clock today, `昨天' yesterday, `MM-DD'
;; this year, or `YY-MM' for earlier years.
;;
;; Function: maillist-day-label (stamp)
;; Return the group label of STAMP: `今天', `昨天', `本周' or `更早'.
;;
;; Function: maillist-long-label (stamp)
;; Return STAMP as a readable date for the reader header.
;;
;; Function: maillist-store-open ()
;; Open the client's SQLite file, migrating compatible legacy tables in place
;; or retiring unreadable files to a `.rebuild-*' backup.
;;
;; Function: maillist-store-close (store)
;; Release STORE's Data Controllers.
;;
;; Function: maillist-store-adopt-threads (store list)
;; Tag stored rows that carry no list name with LIST.
;;
;; Function: maillist-store-threads (store list)
;; Return every stored row of LIST, newest first.
;;
;; Function: maillist-store-save-threads (store list rows)
;; Write ROWS of LIST in one transaction; an empty ROWS writes nothing.
;;
;; Function: maillist-store-thread-messages (store id)
;; Return the cached messages of thread ID, oldest first, including `:parent'.
;;
;; Function: maillist-store-save-thread-messages (store id messages)
;; Cache MESSAGES as thread ID in one transaction, removing stale messages of
;; the same thread; empty MESSAGES is a no-op.
;;
;; Function: maillist-store-marks (store)
;; Return every reader mark as an alist of ID to
;; (:read BOOLEAN :starred BOOLEAN :read-date STAMP :read-count INT).
;;
;; Function: maillist-store-save-mark (store id read starred &optional read-date read-count)
;; Store the mark and optional last-read snapshot of thread ID.
;;
;; Function: maillist-store-save-marks (store marks)
;; Store MARKS in one transaction and return how many rows it wrote.
;;
;; Function: maillist-store-prune (store list)
;; Prune threads and bodies of LIST beyond limits while keeping starred
;; threads, other lists' cached bodies and all marks.
;;
;; Function: maillist-store-search-bodies (store text limit &optional list)
;; Scan cached bodies (optionally scoped to LIST) for TEXT with wildcards
;; escaped, deduplicated per thread, returning (THREAD-ID . SNIPPET) pairs.
;;
;; Function: maillist-store-setting (key &optional store)
;; Return the value stored under KEY in STORE (or `maillist-store-file').
;;
;; Function: maillist-store-save-setting (key value &optional store)
;; Store VALUE under KEY in STORE (or `maillist-store-file') and return VALUE.
;;
;; Function: maillist-palette ()
;; Return the palette derived from the active Emacs theme.
;;
;; Function: maillist-color (key)
;; Return the palette color named KEY; an unknown KEY signals `maillist-error'.
;;
;; Function: maillist-theme-defaults ()
;; Return the ETAF UI token plist for the current theme.
;;
;; Error: maillist-error
;; Signalled when `maillist-color' is asked for an unknown palette key.
;;
;; Variable: maillist-sources
;; Archives the client can open; entries may declare `:index', `:reply-style'
;; and `:nntp' (`(:host HOST :port PORT :group GROUP)').
;;
;; Variable: maillist-transport
;; Transport used for sync and reading: `auto' (NNTP when declared, falling
;; back to HTTP), `nntp' or `http'.
;;
;; Variable: maillist-nntp-sync-window
;; Number of recent articles fetched on an initial NNTP sync.
;;
;; Variable: maillist-nntp-older-batch
;; Number of older articles fetched per `maillist-load-older' over NNTP.
;;
;; Variable: maillist-nntp-connect-timeout
;; Seconds to wait for an NNTP connection before falling back to HTTP.
;;
;; Variable: maillist-default-list
;; Archive a new client opens, by default "emacs-devel".
;;
;; Variable: maillist-buffer-name
;; Buffer name of a mounted client, by default "*maillist*".
;;
;; Variable: maillist-auto-refresh
;; Seconds between automatic syncs of an open client; nil syncs only on demand.
;;
;; Variable: maillist-older-batch
;; How many older messages one `maillist-load-older' adds in date-search mode.
;;
;; Variable: maillist-local-search-limit
;; How many cached threads a search reports when the archive cannot answer.
;;
;; Variable: maillist-store-file
;; SQLite file holding the thread list, marks, cached bodies and settings.
;;
;; Variable: maillist-thread-limit
;; How many threads of one list the client keeps (starred threads are exempt).
;;
;; Variable: maillist-body-limit
;; How many threads per list keep a cached body (starred threads are exempt).
;;
;; Variable: maillist-message-window
;; How many of the newest messages a thread shows at first.
;;
;; Variable: maillist-thread-freshness
;; Seconds a freshly fetched thread stays fresh without re-fetching `t.atom'.
;;
;; Variable: maillist-fast-open-threshold
;; Thread size from which the newest mail is shown while the full thread loads.
;;
;; Variable: maillist-prefetch-threads
;; How many threads without an author to warm after each sync.
;;
;; Variable: maillist-prefetch-parallel
;; How many raw sender requests to keep in flight at once on HTTP sources.
;;
;; Variable: maillist-prefetch-bodies
;; How many uncached unread/recent threads to pre-cache quietly on idle.
;;
;; Variable: maillist-narrow-width
;; Viewport width below which the client shows one column.
;;
;; Variable: maillist-network-route
;; `auto', `proxy' or `direct'; a failing route falls back to the other one.
;;
;; Variable: maillist-proxy
;; Proxy address (HOST:PORT) of archive requests; empty falls back to
;; `url-proxy-services' or HTTP(S)_PROXY.
;;
;; Variable: maillist-route-attempt-timeout
;; Seconds the leading route may stall before the other one answers.
;;
;; Variable: maillist-mail-address
;; Address the client sends from.
;;
;; Variable: maillist-send-mail-function
;; `smtpmail' (built-in SMTP settings) or `inherit' (Emacs's own mail transport).
;;
;; Variable: maillist-smtp-server
;; SMTP host used when `maillist-send-mail-function' is `smtpmail'.
;;
;; Variable: maillist-smtp-service
;; SMTP port used when `maillist-send-mail-function' is `smtpmail'.
;;
;; Variable: maillist-smtp-stream-type
;; Transport of the SMTP connection: `ssl', `starttls' or nil.

;;; Code:

;; Consumers that only add this repository root to `load-path' (the manual's
;; installation path) reach the submodules through this entry, so the `lisp/'
;; directory is added here instead of asking every caller for it.
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name
                "lisp"
                (file-name-directory
                 (or (and load-file-name
                          ;; A native-compiled file lives in `eln-cache', where
                          ;; no sibling `lisp' directory exists.
                          (not (string-suffix-p ".eln" load-file-name))
                          (file-directory-p (expand-file-name "lisp" (file-name-directory load-file-name)))
                          load-file-name)
                     (bound-and-true-p byte-compile-current-file)
                     (locate-library "maillist")
                     buffer-file-name)))))

(require 'maillist-app)
(require 'maillist-mail)
(require 'maillist-model)
(require 'maillist-nntp)
(require 'maillist-service)

(provide 'maillist)
;;; maillist.el ends here
