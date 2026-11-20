;;; etaf-rss.el --- RSS reader for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0"))
;; Keywords: news, hypermedia, ui
;; URL: https://github.com/emacs-taf/etaf-rss

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-rss) after adding this repository and
;; the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  The reader is a
;; complete RSS client for Emacs: it subscribes to RSS 2.0, Atom and JSON
;; Feed documents (a plain site page is searched for its advertised feed),
;; keeps every subscription and article in one local JSON store, browses the
;; all/unread/starred scopes and per-feed or per-folder lists, reads an
;; article's HTML as wrapped text, marks read state, stars, searches titles
;; and bodies, and imports and exports OPML.  Feeds refresh conditionally
;; (ETag / Last-Modified), one request at a time, in the background.
;;
;; Two backends answer the same requests: the local JSON store described
;; above, and a self-hosted Miniflux server (`etaf-rss-miniflux-client'),
;; where the server owns subscriptions, articles and read state.  Set
;; `etaf-rss-backend' to `miniflux' to read a server; the interface, the
;; layout and the keys are the same.
;;
;; A session is the unit of state.  `etaf-rss-create' builds one, the actions
;; below drive it asynchronously, `etaf-rss-state' reports it as plain data,
;; and `etaf-rss-app' or `etaf-rss-open' display it.  Every displayed value is
;; an ETAF reactive source, so a service reply repaints the mounted reader
;; without a refresh call.  The service layer accepts a scripted client, so a
;; whole session runs headless and offline.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Function: etaf-rss-open (&optional model)
;;;###autoload (autoload 'etaf-rss-open "etaf-rss" nil t)
;; Mount the reader in `etaf-rss-buffer-name' and return its buffer.
;; MODEL defaults to a session from `etaf-rss-create', so the reader opens on
;; every stored article.  A caller-provided MODEL keeps its scope, selection
;; and open article, and is revived when it was displayed before.  It replaces
;; the selected window instead of following `display-buffer' rules that might
;; split the frame.  The buffer is an ETAF application (see `etaf-app-open'):
;; its root keys replace the renderer's scrolling keys with reader commands,
;; RET reaches a focused control before it opens the selected article, the
;; mode line is hidden, and the layout follows each settled resize of the
;; window.  `C-c h' lists the keys.  Closing the buffer releases the session's
;; timers and pending requests, so a later `etaf-rss-open' with the same MODEL
;; works again.
;;
;; Function: etaf-rss-close ()
;;;###autoload (autoload 'etaf-rss-close "etaf-rss" nil t)
;; Unmount the reader and kill its buffer.
;; Unmounting releases the session's refresh timer and in-flight requests; the
;; session itself stays usable for a later mount.
;;
;; Function: etaf-rss-view (&optional model)
;;;###autoload (autoload 'etaf-rss-view "etaf-rss" nil t)
;; Return the reader View for MODEL, defaulting to a new session.
;; Use it to embed the reader in your own `etaf-mount' call, for example
;; inside a tab or a larger layout; `etaf-rss-open' is the shortcut that also
;; owns the buffer.
;;
;; Component: etaf-rss-app (&key model)
;; Render the mounted reader for MODEL and own its session lifecycle.
;; MODEL must come from `etaf-rss-create'.  Mounting provides the palette for
;; its subtree, fits the layout and loads the feed list; unmounting disposes
;; the session.  The Component reads every displayed value from the model, so
;; any action or service reply repaints it; prefer `etaf-rss-open' or
;; `etaf-rss-view' over mounting the Component directly.
;;
;; Function: etaf-rss-create (&key client)
;; Return a new reader session that talks to CLIENT.
;; CLIENT defaults to `etaf-rss-client-factory' when that is bound and
;; otherwise to `etaf-rss-make-client'.  The session owns no buffer and no
;; timer before it is mounted, so it is a complete headless reader for scripts
;; and tests.  Pass a CLIENT function to drive the same reader from another
;; backend.
;;
;; Function: etaf-rss-state (app)
;; Return APP's session state as a detached plist snapshot.
;; Keys are `:scope' (`:kind' and its parameters), `:scope-label',
;; `:scope-subtitle', `:title', `:feeds' (the sidebar rows), `:folders' (the
;; grouped tree), `:rows' (the loaded article rows), `:visible' (the rows on
;; the current page), `:selection', `:window-start', `:page-size',
;; `:rows-total' (loaded rows), `:list-total' (the scope's full count),
;; `:layout' (`wide', `medium' or `narrow'), `:pane' (`list' or `reader'),
;; `:reader-id', `:reader-title', `:reader-meta', `:reader-blocks' (the
;; rendered article), `:reader-lines' (its wrapped display lines),
;; `:reader-scroll', `:reader-rows', `:reader-total', `:reader-columns' (the
;; width the article was wrapped to), `:reader-wrapped', `:reader-loading',
;; `:reader-error', `:reader-read', `:reader-starred', `:reader-url',
;; `:query', `:loading', `:refreshing', `:refresh-done', `:refresh-total',
;; `:error', `:message', `:total' (stored articles), `:unread',
;; `:starred-count', `:theme-mode', `:viewport-width' (the pixel canvas the
;; reader mounts into).  The snapshot copies every value, so mutating it never
;; changes the reader; use it to render outside ETAF or to assert behavior in
;; tests.
;;
;; Function: etaf-rss-refresh (app)
;; Reload APP's sidebar and current list, then re-fetch its feeds.
;; The local reload paints at once; the network refresh runs feed by feed in
;; the background and reports its progress in the status line.  It also
;; re-fits the layout to the window that shows APP, so call it after a resize.
;; Every request is asynchronous and a reply belonging to a superseded load is
;; dropped, which makes repeated refreshes safe.
;;
;; Function: etaf-rss-refresh-feeds (app &optional scope)
;; Re-fetch the feeds SCOPE covers, one at a time.
;; SCOPE defaults to APP's current scope; `(:kind :all)' refreshes every
;; subscription.  Progress is reported in the status line and the visible list
;; is reloaded when the refresh ends.
;;
;; Function: etaf-rss-locate (app scope)
;; Show SCOPE of APP and load its rows.
;; SCOPE is `:all', `:unread', `:starred', `(:kind :feed :id ID)',
;; `(:kind :folder :name NAME)' or `(:kind :search :query TEXT)'.  An unknown
;; SCOPE signals `etaf-rss-error' and leaves APP unchanged.
;;
;; Function: etaf-rss-search (app keyword)
;; Search APP's stored articles for KEYWORD and show the matches.
;; KEYWORD is trimmed; a blank one signals `etaf-rss-error' without querying.
;; Matching is case-insensitive and every space-separated term must appear in
;; the title, the summary or the article body.
;;
;; Function: etaf-rss-move-selection (app delta)
;; Move APP's list selection by DELTA rows and keep it inside the visible page.
;; Selection stops at the first and last row; moving past a page boundary
;; scrolls the page so the new selection stays visible.  When the reading pane
;; is visible it follows the settled selection.
;;
;; Function: etaf-rss-select-first (app)
;; Select APP's first article.
;;
;; Function: etaf-rss-select-last (app)
;; Select APP's last article.
;;
;; Function: etaf-rss-next-unread (app delta)
;; Move APP's selection to the next unread article DELTA steps away.
;; DELTA is 1 for the next unread article and -1 for the previous one; when
;; there is none, the selection stays and the status line says so.
;;
;; Function: etaf-rss-press-row (app index)
;; Press list row INDEX (counting from 1) in APP.
;; Pressing another row selects it and previews its article; pressing the
;; selected row again opens the reading pane.  This is the gesture a click on
;; a row performs, which a programmatic caller can follow.  An out-of-range
;; INDEX signals `etaf-rss-error'.
;;
;; Function: etaf-rss-activate-selection (app)
;; Show the selected article in APP's reading pane.
;; A compact layout switches its single pane to the article; a wide layout
;; already shows the pane, so the pane is scrolled to the top.
;;
;; Function: etaf-rss-show-pane (app pane)
;; Show PANE in APP and return it.
;; PANE is `list' or `reader'; on a compact layout it names the single visible
;; pane, and on a wide layout it only records the choice because both columns
;; stay visible.  An unknown PANE signals `etaf-rss-error'.
;;
;; Function: etaf-rss-toggle-pane (app)
;; Switch APP between the article list and the reading pane and return the new one.
;;
;; Function: etaf-rss-scroll-reader (app delta)
;; Scroll APP's reading pane by DELTA lines.
;; The scroll clamps at both ends and the pane paints only the visible lines,
;; so scrolling never reflows the article.
;;
;; Function: etaf-rss-toggle-read (app)
;; Toggle the read state of APP's selected article and return it.
;; The toggle is optimistic: the row flips before the service confirms, so the
;; interface never waits on a disk write.
;;
;; Function: etaf-rss-toggle-star (app)
;; Toggle the star of APP's selected article and return it.
;; The toggle is optimistic, like `etaf-rss-toggle-read'.
;;
;; Function: etaf-rss-mark-all-read (app &optional unread-p)
;; Mark every article of APP's current scope read and return the count.
;; With UNREAD-P non-nil the scope is marked unread instead, which is how a
;; reader undoes an accidental "all read".  The change is optimistic and
;; confirmed by the service.
;;
;; Function: etaf-rss-mark-above-read (app)
;; Mark the selected article and everything above it read and return the count.
;;
;; Function: etaf-rss-add-feed (app url &optional folder)
;; Subscribe APP to URL and return non-nil when the request started.
;; The feed is fetched and parsed before it is added, so a wrong address is
;; reported instead of stored; a page that is not a feed is searched for its
;; advertised feed links.  FOLDER files the subscription when non-nil.  The
;; request is asynchronous and its failure is reported in the status line.
;;
;; Function: etaf-rss-remove-feed (app &optional id)
;; Unsubscribe the feed ID from APP, or the feed of the current scope.
;; Starred articles of the feed stay in the reader.  Return the removed feed's
;; title, or signal `etaf-rss-error' when there is no feed to remove.
;;
;; Function: etaf-rss-move-feed (app id folder)
;; File the feed ID under FOLDER in APP and return the file name.
;; An empty FOLDER moves the subscription back to the top level.
;;
;; Function: etaf-rss-toggle-folder (app name)
;; Collapse or expand the folder NAME in APP and return the open folders.
;;
;; Function: etaf-rss-import-opml (app path)
;; Add the subscriptions of the OPML file at PATH to APP and return the count.
;; Feeds already subscribed by URL are skipped; nothing is fetched by the
;; import itself, so the caller refreshes afterwards.
;;
;; Function: etaf-rss-export-opml (app path)
;; Write APP's subscriptions to the OPML file at PATH and return the path.
;;
;; Function: etaf-rss-open-article (app &optional row)
;; Open ROW's article, or APP's selected article, in the browser.
;; The reader keeps running; a row without a URL reports that in the status
;; line instead of signalling.
;;
;; Function: etaf-rss-set-theme (app mode)
;; Switch APP to the appearance MODE and return it.
;; MODE is `dark' or `light'; anything else signals `etaf-rss-error'.  The
;; choice becomes the reader's live appearance, so mounted rows repaint, and
;; it is remembered by the service; a panel's title-bar switch writes the same
;; cell.
;;
;; Function: etaf-rss-cycle-theme (app)
;; Switch APP to the other appearance and return it.
;;
;; Function: etaf-rss-parse-feed (text &optional url)
;; Parse feed document TEXT and return (:title :site :description :articles).
;; RSS 2.0, RSS 1.0 (RDF), Atom and JSON Feed are supported; URL names the
;; document and is only used to resolve an article identity when the feed has
;; none.  A document that is none of these signals `etaf-rss-error'.  Each
;; article is (:id :title :url :author :published :summary :content); the call
;; is pure, so callers parse stored text as well as fresh replies.
;;
;; Function: etaf-rss-parse-opml (text)
;; Parse OPML document TEXT and return its subscriptions.
;; Each entry is (:title :url :folder); FOLDER is the name of the nearest
;; enclosing outline without an `xmlUrl', or an empty string at the top level.
;; A document that is not OPML signals `etaf-rss-error'.
;;
;; Function: etaf-rss-render-html (html)
;; Render article HTML into reading blocks.
;; The result is a list of (:kind :text) plists; link blocks carry :url as
;; well.  Block kinds are `heading', `para', `quote', `item', `code', `row',
;; `separator' and `link'.  Scripts, styles and site chrome are dropped;
;; images become a short `[图]' marker; links are collected at the end.
;; Plain text that is not HTML becomes one paragraph.
;;
;; Function: etaf-rss-plain-text (html)
;; Return HTML as one plain-text string, or an empty string.
;;
;; Function: etaf-rss-wrap-blocks (blocks columns)
;; Wrap reading BLOCKS into display lines of at most COLUMNS columns.
;; The result is a list of (:key :text :kind) plists with sequential keys;
;; blank lines separate blocks so prose reads in paragraphs.  The reading pane
;; only slices this list, so a large article wraps once.
;;
;; Function: etaf-rss-parse-time (value)
;; Return VALUE as a float time, or nil when it carries no date.
;; RFC 822, ISO 8601 and plain `YYYY-MM-DD[ HH:MM[:SS]]' are accepted; an
;; unparseable value returns nil instead of signalling.
;;
;; Function: etaf-rss-format-time (time)
;; Return TIME as `YYYY-MM-DD HH:MM', or an empty string when it is nil.
;;
;; Function: etaf-rss-relative-time (time &optional now)
;; Return TIME as a short relative string against NOW (default the clock).
;; `刚刚', `N 分钟前', `N 小时前', `昨天 HH:MM', `N 天前' and finally
;; `YYYY-MM-DD' are used, so a list row stays narrow.
;;
;; Function: etaf-rss-article-id (feed-url identity)
;; Return the stable article ID of IDENTITY in FEED-URL.
;; The pair is hashed, so the same item keeps its ID across refreshes and its
;; read and starred state survives.
;;
;; Function: etaf-rss-html-title (html)
;; Return the <title> of an HTML document, trimmed, or nil.
;;
;; Function: etaf-rss-html-feed-links (html &optional base-url)
;; Return feed URLs advertised by an HTML page.
;; Alternate links whose type names RSS, Atom or JSON Feed are returned in
;; document order; relative hrefs resolve against BASE-URL.  It is how
;; subscribing to a site's home page finds its feed.
;;
;; Function: etaf-rss-color (key &optional mode)
;; Return the palette color named KEY, optionally reading MODE instead of
;; `etaf-rss-theme-mode'.
;; KEY is one of `:bg', `:panel', `:panel2', `:panel3', `:line',
;; `:line-soft', `:ink', `:muted', `:dim', `:accent', `:accent-soft',
;; `:gold', `:ok', `:warn', `:danger', `:danger-bg', `:info', `:selected',
;; `:unread', `:read', `:feed', `:quote' or `:time'; an unknown KEY signals
;; `etaf-rss-error'.
;;
;; Function: etaf-rss-theme-defaults (&optional mode)
;; Return the `:ui-*' theme defaults of MODE as a property plist.
;; The list is what the mounted reader provides to the ETAF UI controls in its
;; subtree, so buttons, inputs and badges follow the same palette.
;;
;; Function: etaf-rss-make-client (&key data-file timeout)
;; Create a service client whose store lives in DATA-FILE.
;; DATA-FILE and TIMEOUT default to `etaf-rss-data-file' and
;; `etaf-rss-request-timeout'.  The store is read lazily on the first request,
;; so constructing a client touches no disk.
;;
;; Variable: etaf-rss-client-factory
;; Function of no arguments returning the client of new sessions.
;; Bind it to drive `etaf-rss-create' with another backend, which is how the
;; acceptance scenarios read a scripted store without the network.
;;
;; Function: etaf-rss-client-call (client request callback)
;; Send REQUEST to CLIENT and deliver the reply to CALLBACK.
;; REQUEST is a plist starting with `:op':
;;
;;   :snapshot                      feeds, totals and preferences
;;   :feeds                         sidebar feeds with unread counts
;;   :articles :scope SCOPE         rows of one scope
;;   :article :id ID                one article with its HTML
;;   :mark-read :ids (…) :read BOOL set read state of articles
;;   :mark-read-scope :scope S :read BOOL
;;   :star :id ID :starred BOOL     set one article's star
;;   :set-theme :theme "dark"       remember the appearance
;;   :add-feed :url URL             subscribe (fetches and merges now)
;;   :refresh :id ID                re-fetch one feed (conditional GET)
;;   :remove-feed :id ID            unsubscribe (starred articles stay)
;;   :move-feed :id ID :folder NAME file a feed under a folder
;;   :opml-import :path FILE        add subscriptions from OPML
;;   :opml-export :path FILE        write subscriptions as OPML
;;   :flush                         persist pending changes now
;;
;; CALLBACK receives exactly one of (:ok DATA) or (:error MESSAGE :hint HINT);
;; local queries answer from a timer and fetches from the transfer callback,
;; so the call never blocks the caller.
;;
;; Function: etaf-rss-cancel (client)
;; Abandon CLIENT's queued and in-flight requests and persist its store.
;; Cancelled requests never run their callbacks, and the same client can be
;; used again afterwards.  Return the number of abandoned transfers.
;;
;; Function: etaf-rss-miniflux-client (&key url token timeout transport)
;; Create a client that reads a self-hosted Miniflux server.
;; It answers the same request protocol as the local store, so the reader's
;; model and views are identical on both backends; subscriptions, articles
;; and read state live on the server.  URL, TOKEN and TIMEOUT default to
;; `etaf-rss-miniflux-url', `etaf-rss-miniflux-token' and
;; `etaf-rss-miniflux-request-timeout'.  TRANSPORT, a function of (METHOD PATH
;; QUERY BODY CALLBACK), replaces the HTTP transfer, which is how tests drive
;; the backend without a server.  Pass the client to `etaf-rss-create :client'
;; or set `etaf-rss-backend' to `miniflux'.
;;
;; Variable: etaf-rss-backend
;; Backend new sessions read: `local' (default) or `miniflux'.
;; `local' keeps everything in `etaf-rss-data-file'; `miniflux' reads the
;; server configured by `etaf-rss-miniflux-url' and `etaf-rss-miniflux-token'.
;; Both show the same reader, and `etaf-rss-create :client' still overrides it.
;;
;; Variable: etaf-rss-miniflux-url
;; Base URL of the Miniflux instance used by the `miniflux' backend.
;; Nil consults `etaf-rss-miniflux-config-file', then the MINIFLUX_URL
;; environment variable, then a server on the default local port.
;;
;; Variable: etaf-rss-miniflux-token
;; API token for the Miniflux instance used by the `miniflux' backend.
;; Nil consults `etaf-rss-miniflux-config-file', then MINIFLUX_TOKEN.  The
;; token comes from the server's Settings > API Keys page.
;;
;; Variable: etaf-rss-miniflux-config-file
;; JSON file holding the Miniflux URL and token.
;; It reads {"url": "…", "token": "…"} and defaults to
;; `<user-emacs-directory>/etaf-miniflux.json'.
;;
;; Variable: etaf-rss-miniflux-request-timeout
;; Seconds before one Miniflux request is abandoned, default 20.
;;
;; Variable: etaf-rss-miniflux-list-limit
;; Most entries one scope loads from the server in one request, default 200.
;;
;; Variable: etaf-rss-buffer-name
;; Buffer `etaf-rss-open' mounts the reader into.
;;
;; Variable: etaf-rss-data-file
;; JSON file the reader stores subscriptions and article state in, default
;; `<user-emacs-directory>/etaf-rss/data.json'.  Bind it before creating a
;; session to keep several profiles apart or to use a disposable file.
;;
;; Variable: etaf-rss-request-timeout
;; Seconds before one feed request is abandoned, default 20.
;; The timer kills the transfer, so a hung server cannot leave a refresh
;; pending forever.
;;
;; Variable: etaf-rss-articles-per-feed
;; Newest articles kept for one feed, default 200.
;; Older articles are pruned, except starred ones.
;;
;; Variable: etaf-rss-starred-limit
;; Most starred articles the reader keeps, default 1000.
;;
;; Variable: etaf-rss-search-limit
;; Most rows one search returns, default 200.
;;
;; Variable: etaf-rss-save-delay
;; Seconds of quiet before a changed store is written to disk, default 1.5.
;; Read and star actions land immediately in memory; the debounce keeps a
;; burst of them from serializing the file once per keystroke.
;;
;; Variable: etaf-rss-user-agent
;; User-Agent header sent with every feed request.
;;
;; Variable: etaf-rss-theme-mode
;; Appearance a new reader starts with: `dark' (default) or `light'.  The
;; running choice is one live mode cell that `T' and a panel's title-bar
;; switch both write; `etaf-rss-color' and `etaf-rss-theme-defaults' read it,
;; so every painted surface takes the new palette at once.  This option only
;; seeds that cell.
;;
;; Variable: etaf-rss-reading-measure
;; Preferred width of the article reading column in columns, default 58.
;; The column is capped by what the pane can hold, so a narrow frame shrinks
;; it instead of clipping.
;;
;; Variable: etaf-rss-wide-columns
;; Frame width, in columns, that fits the sidebar, the list and the reader,
;; default 118.  At or above this width the reader shows all three columns.
;;
;; Variable: etaf-rss-medium-columns
;; Frame width, in columns, that still fits the narrow scope sidebar, default
;; 72.  At or above this width, but below `etaf-rss-wide-columns', one content
;; pane is shown at a time; below it the scopes move into a header strip.
;;
;; Variable: etaf-rss-page-size
;; Article rows shown at once by a headless session, default 14.
;; A mounted reader replaces it with the count that fits its window.
;;
;; Variable: etaf-rss-list-limit
;; Most rows one scope loads, default 300.
;; The list pages through them by viewport; a larger scope reports its full
;; total and the loaded count separately.
;;
;; Variable: etaf-rss-follow-delay
;; Seconds of quiet before the reading pane follows the selection, default
;; 0.45.  Browsing faster than this never loads an article only passed over.
;;
;; Variable: etaf-rss-mark-read-delay
;; Seconds an article stays open before it is marked read, default 1.0.
;; The delay keeps fast browsing from marking every article it passes.
;;
;; Variable: etaf-rss-refresh-interval
;; Seconds between automatic feed refreshes of a mounted reader, default 900.
;; The refresh runs in the background and never blocks the interface; set it
;; to nil to refresh only on request.
;;
;; Error: etaf-rss-error
;; Invalid reader operation, for example an unknown scope, a blank search
;; keyword, a missing feed or article, or malformed feed, OPML or store
;; content.  Asynchronous failures are reported in the session's `:error' and
;; `:message' instead of being signaled, because they happen while the reader
;; stays usable.

;;; Code:

(eval-and-compile
  (let ((directory (file-name-directory (or load-file-name
                                            (bound-and-true-p byte-compile-current-file)
                                            buffer-file-name))))
    (add-to-list 'load-path (expand-file-name "lisp" directory))))

(require 'etaf-rss-theme)
(require 'etaf-rss-parse)
(require 'etaf-rss-store)
(require 'etaf-rss-service)
(require 'etaf-rss-model)
(require 'etaf-rss-views)
(require 'etaf-rss-app)

(provide 'etaf-rss)
;;; etaf-rss.el ends here
