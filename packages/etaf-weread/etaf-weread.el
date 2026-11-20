;;; etaf-weread.el --- WeChat Reading client for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.5
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0") (etaf-db "0.1.0"))
;; Keywords: hypermedia, ui
;; URL: https://github.com/emacs-taf/etaf-weread

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-weread) after adding this repository
;; and the ETAF, ETAF UI, ETAF DB and Ebox roots to `load-path'.  The reader is
;; a WeChat Reading client for Emacs: it browses the signed-in account's shelf,
;; the notebook of books with highlights, per-book details with their table of
;; contents and reading progress, the store search and the aggregate reading
;; statistics, and it reads and exports the account's highlights and thoughts.
;; A local SQLite index of those highlights, built through ETAF DB, makes the
;; whole notebook searchable offline.
;;
;; A session is the unit of state.  `etaf-weread-create' builds one, the
;; actions below drive it asynchronously, `etaf-weread-state' reports it as
;; plain data, and `etaf-weread-app' or `etaf-weread-open' display it.  Every
;; displayed value is an ETAF reactive source, so a backend reply repaints the
;; mounted reader without a refresh call.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Function: etaf-weread-doctor ()
;; Return capability facts for the reading client.  The shape matches
;; `etaf-install-doctor': Node runs the bundled backend.
;; Function: etaf-weread-open (&optional model)
;;;###autoload (autoload 'etaf-weread-open "etaf-weread" nil t)
;; Mount the reader in `etaf-weread-buffer-name' and return its buffer.
;; MODEL defaults to a session from `etaf-weread-create', so the reader opens on
;; the shelf with the account of the stored login.  A caller-provided MODEL
;; keeps its section, selection and loaded detail, and is revived when it was
;; displayed before.  It replaces the selected window instead of following
;; `display-buffer' rules that might split the frame.  The buffer is an ETAF
;; application (see `etaf-app-open'): its root keys replace the renderer's
;; scrolling keys with reader commands, RET reaches a focused control before
;; it opens the selection, the mode line is hidden, and the layout and page
;; size follow each settled resize of the window.  `C-c h' lists
;; the keys.  Closing the buffer releases the session's timers and pending
;; requests, so a later `etaf-weread-open' with the same MODEL works again.
;;
;; Function: etaf-weread-close ()
;;;###autoload (autoload 'etaf-weread-close "etaf-weread" nil t)
;; Unmount the reader and kill its buffer.
;; Unmounting releases the session's follow timer, its SQLite Data Controller
;; and its in-flight backend requests; the session itself stays usable for a
;; later mount.
;;
;; Function: etaf-weread-login (&optional app)
;;;###autoload (autoload 'etaf-weread-login "etaf-weread" nil t)
;; Sign in to WeChat Reading and load the account again.
;; The bundled backend reuses its own signed-in browser, otherwise reads the
;; local Chrome session, and otherwise opens a browser window at the QR page and
;; waits up to `etaf-weread-login-timeout' seconds for the scan.  The browser
;; profile is owned by the package (Chrome, Edge, Brave or Chromium; set
;; `WEREAD_BROWSER' for another binary), so signing in needs no Pi skill or
;; other external tool.  APP defaults
;; to the mounted reader, whose status line reports the progress and whose
;; account, lists and statistics reload when the login succeeds; with no reader
;; open the reply is reported in the echo area and a reader opened meanwhile is
;; refreshed.  Return APP, or nil when the login ran without a session.
;;
;; Function: etaf-weread-logout (&optional app)
;;;###autoload (autoload 'etaf-weread-logout "etaf-weread" nil t)
;; Sign out of WeChat Reading and forget what was loaded from the account.
;; Only the login saved by the bundled backend is deleted; the WeChat Reading
;; account itself is unchanged.  APP defaults to the mounted reader and drops
;; its account, loaded lists and open book at once, naming
;; `etaf-weread-login' in its status line.  With no reader open the reply is
;; reported in the echo area.  Return APP, or nil when the logout ran without a
;; session.
;;
;; Function: etaf-weread-session (&optional buffer)
;;;###autoload (autoload 'etaf-weread-session "etaf-weread" nil nil)
;; Return the reader session mounted in BUFFER-OR-NAME, or nil.
;; BUFFER-OR-NAME defaults to the current buffer.  `etaf-weread-open` records
;; its session through `etaf-app-open`, and a host that mounts
;; `etaf-weread-view` records it when the View mounts, so a command or a host
;; finds the reader it acts on; a buffer without a mounted reader returns nil.
;;
;; Function: etaf-weread-view (&optional model)
;;;###autoload (autoload 'etaf-weread-view "etaf-weread" nil t)
;; Return the reader View for MODEL, defaulting to a new session.
;; Use it to embed the reader in your own `etaf-mount' call, for example inside
;; a tab or a larger layout; `etaf-weread-open' is the shortcut that also owns
;; the buffer.
;;
;; Component: etaf-weread-app (&key model)
;; Render the mounted reader for MODEL and own its session lifecycle.
;; MODEL must come from `etaf-weread-create'.  Mounting provides the palette for
;; its subtree, fits the layout and loads the current section; unmounting
;; disposes the session.  The Component reads every displayed value from the
;; model, so any action or backend reply repaints it; prefer `etaf-weread-open'
;; or `etaf-weread-view' over mounting the Component directly.
;;
;; Function: etaf-weread-create (&key client)
;; Return a new reader session that talks to CLIENT.
;; CLIENT defaults to `etaf-weread-client-factory' when that is bound and
;; otherwise to `etaf-weread-make-client'.  The session owns no buffer and no
;; timer before it is mounted, so it is a complete headless reader for scripts
;; and tests.  Pass a CLIENT function to drive the same reader from another
;; backend.
;;
;; Function: etaf-weread-state (app)
;; Return APP's session state as a detached plist snapshot.
;; Keys are `:section', `:filter', `:title', `:subtitle', `:mode', `:query',
;; `:items', `:visible', `:window-start', `:selection', `:page-size',
;; `:rows-total', `:list-total', `:layout', `:pane', `:pane-rows',
;; `:pane-scroll', `:pane-total', `:detail', `:notes', `:stats', `:account',
;; `:summary', `:index-query', `:index-syncing', `:theme', `:loading',
;; `:error', `:message' and `:viewport-width' (the pixel canvas the reader
;; mounts into).  The snapshot copies every value, so mutating it never changes
;; the reader; use it to render outside ETAF or to assert behavior in tests.
;; `:rows-total' counts loaded rows; `:list-total' keeps the backend's total
;; when reported and otherwise equals the loaded count.
;;
;; Function: etaf-weread-refresh (app)
;; Reload APP's current list, account and statistics.
;; It re-fits the layout to the window that shows APP, so call it after a
;; resize.  Every request is asynchronous and a reply belonging to a superseded
;; load is dropped, which makes repeated refreshes safe.
;;
;; Function: etaf-weread-locate (app section)
;; Show SECTION of APP and load its rows.
;; SECTION is one of the keys in `etaf-weread-sections': `:shelf', `:reading',
;; `:finished', `:notebook', `:search', `:index' or `:stats'.  An unknown
;; SECTION signals `etaf-weread-error' and leaves APP unchanged.
;;
;; Function: etaf-weread-set-filter (app filter)
;; Show the shelf books matching FILTER.
;; FILTER is `all', `reading' or `finished'; the matching section is shown and
;; any other value signals `etaf-weread-error'.
;;
;; Function: etaf-weread-search (app keyword)
;; Search the WeChat Reading store for KEYWORD and show the results.
;; The keyword is trimmed; a blank KEYWORD signals `etaf-weread-error' without
;; querying the backend.
;;
;; Function: etaf-weread-move-selection (app delta)
;; Move APP's list selection by DELTA rows and keep it inside the visible page.
;; Selection stops at the first and last row; moving past a page boundary
;; scrolls the page so the new selection stays visible.
;;
;; Function: etaf-weread-activate-selection (app)
;; Open the book APP's selection points at.
;; A book row shows its detail (or its highlights in the notebook section) and
;; does nothing on an empty list; an indexed highlight row opens the notes of
;; its book.
;;
;; Function: etaf-weread-press-row (app index)
;; Press list row INDEX (counting from 1): select it, or open it when it is the
;; selected row.  This is the gesture a click on a list row performs, which a
;; programmatic caller can use to follow the same sentence.  An out-of-range
;; INDEX signals `etaf-weread-error'.
;;
;; Function: etaf-weread-show-book (app item &optional pane)
;; Show the book ITEM in APP's side pane and load what is missing.
;; ITEM is a row or a book id.  PANE is `detail' (the default) or `notes'.  A
;; missing book id signals `etaf-weread-error'; cached data paints at once and
;; the rest loads in the background.
;;
;; Function: etaf-weread-show-pane (app pane)
;; Show PANE in APP and return it.
;; PANE is `detail' for the book card with its table of contents or `notes' for
;; the highlights and thoughts; any other value signals `etaf-weread-error'.  A
;; `wide' layout keeps every column visible, so there PANE is remembered
;; without removing anything; compact layouts show that single pane.
;;
;; Function: etaf-weread-toggle-pane (app)
;; Switch APP's side pane between the book detail and its highlights.
;;
;; Function: etaf-weread-scroll-pane (app delta)
;; Scroll APP's detail or highlight pane by DELTA rows.
;;
;; Function: etaf-weread-reader-url (item)
;; Return the WeChat Reading URL of ITEM, or nil.
;; ITEM is a book row or a book id; the backend's deep link is used when it has
;; one, and otherwise the id addresses the web reader.
;;
;; Function: etaf-weread-open-book (app &optional item)
;; Open ITEM, or APP's selected book, in the WeChat Reading web reader.
;; The browser opens through `browse-url', so the reader keeps running; a book
;; without a URL signals `etaf-weread-error'.
;;
;; Function: etaf-weread-export-notes (app &optional item)
;; Export the highlights and thoughts of ITEM, or the selected book, as Markdown.
;; The bundled backend writes the file under its configured export
;; directory and the reply is reported in the status line; a book without an
;; id signals `etaf-weread-error'.
;;
;; Function: etaf-weread-index-database ()
;; Return the SQLite database descriptor of the local notes index.
;; The descriptor declares the `highlights' table used by
;; `etaf-weread-index-notebook' and `etaf-weread-index-search'; pass it to
;; ETAF DB directly to inspect or query the index, and change
;; `etaf-weread-index-file' to move the database.
;;
;; Function: etaf-weread-index-notebook (app &optional refresh)
;; Index the highlights of every notebook book into APP's local SQLite index.
;; The notebook is listed once and the books not indexed yet are fetched one at
;; a time, so the progress is reported in the status line and the reader stays
;; usable.  REFRESH non-nil re-fetches books that are already indexed.  Like
;; every backend action the requests are asynchronous; a reply after the
;; session was disposed is dropped.
;;
;; Function: etaf-weread-index-search (app &optional keyword)
;; Filter the local highlight index by KEYWORD and show the results.
;; KEYWORD matches the highlight, the thought and the book title
;; case-insensitively; nil or an empty keyword shows every indexed highlight.
;; The section `:index' is shown, so callers can also use `etaf-weread-locate'.
;;
;; Variable: etaf-weread-sections
;; Sidebar groups and their sections, as (GROUP-NAME (SECTION LABEL ICON) ...).
;; Rebind it before mounting a session to show a different catalog of sections;
;; each SECTION must also be accepted by `etaf-weread-locate'.
;;
;; Variable: etaf-weread-buffer-name
;; Buffer `etaf-weread-open' mounts the reader into.
;;
;; Variable: etaf-weread-page-size
;; Book rows shown at once.  `etaf-weread-open' replaces it with the count that
;; fits the window, so the default only applies to a headless session.
;;
;; Variable: etaf-weread-wide-columns
;; Frame width, in columns, that fits the sidebar, the book list and the detail
;; pane at the same time.  At or above this width the reader uses the `wide'
;; layout.
;;
;; Variable: etaf-weread-medium-columns
;; Frame width, in columns, that still fits a glyph-only section rail.  At or
;; above this width, but below `etaf-weread-wide-columns', the reader keeps the
;; rail and shows a single pane; below it the sections move into a header strip.
;;
;; Variable: etaf-weread-library-refresh-interval
;; Seconds after which a cached sidebar list is refreshed in the background,
;; default 120.
;; A cached list is shown at once when a section is opened and then compared
;; with a fresh reply; the interval decides when the idle timer refreshes it.
;; Lower it for a more current sidebar, raise it for fewer requests.
;;
;; Variable: etaf-weread-prefetch-lists
;; Whether a mounted reader warms and refreshes sidebar lists while idle,
;; default t.
;; One list at a time is loaded in the background, so opening a section that
;; was never visited can paint from the cache.  Nil keeps the cache to the
;; sections the reader actually opens.
;;
;; Variable: etaf-weread-prefetch-interval
;; Seconds between two background list refreshes while the reader is idle,
;; default 15.
;; The timer only looks for work at this rhythm; a list is refreshed when it
;; is older than `etaf-weread-library-refresh-interval`.
;;
;; Variable: etaf-weread-list-limit
;; Rows requested for one list load, default 200.  Backend totals stay distinct
;; from loaded counts when the reply is partial.
;;
;; Variable: etaf-weread-search-count
;; Book results requested for one store search, default 25.
;;
;; Variable: etaf-weread-detail-follow-delay
;; Seconds of quiet before the detail pane follows the list selection, default
;; 0.3.  Browsing faster than this never requests a book that was only passed
;; over.
;;
;; Variable: etaf-weread-theme-mode
;; Palette a new Emacs session starts with: `dark' (default), `light' or
;; `sepia'.  The live mode is one reactive cell; the reader's T key and a
;; panel's title-bar switch write it, and `etaf-weread-color' and
;; `etaf-weread-theme-defaults' read it, so the reader and a panel framing it
;; share one appearance state.  The cell may also hold `auto', which follows
;; the appearance the host provides; a panel's standard 亮/随/暗 switch writes
;; that value, while `T' keeps cycling the reader's own three palettes.
;;
;; Variable: etaf-weread-settings-file
;; File that stores the chosen appearance between sessions, default
;; `<user-emacs-directory>/etaf-weread/settings.eld'.
;; A new session starts with the theme stored there.  Bind it before creating a
;; session to keep several profiles apart; the session remembers the file it
;; was created with, including when writing.
;;
;; Variable: etaf-weread-index-file
;; SQLite file of the local highlight index, default
;; `<user-emacs-directory>/etaf-weread/notes.sqlite3'.  Bind it before creating
;; a session to keep several accounts apart or to use a disposable database.
;;
;; Variable: etaf-weread-index-on-read
;; Whether reading a book's highlights stores them in the local index.  The
;; default t builds the index as the account browses; nil leaves the database
;; untouched until `etaf-weread-index-notebook' is called.
;;
;; Function: etaf-weread-color (key &optional mode)
;; Return the palette color for KEY, optionally reading MODE instead of the
;; reader's live mode.
;; KEY is one of `:bg', `:panel', `:panel2', `:panel3', `:line', `:ink',
;; `:muted', `:dim', `:accent', `:accent-soft', `:gold', `:ok', `:warn',
;; `:danger', `:danger-bg', `:info', `:selected', `:meter', `:cover' or
;; `:quote'; an unknown KEY signals `etaf-weread-error'.  Views use it to stay
;; readable in both palettes.
;;
;; Function: etaf-weread-theme-defaults (&optional mode)
;; Return the `:ui-*' theme defaults of MODE as a property plist.
;; The list is what the mounted reader provides to the ETAF UI controls in its
;; subtree, so buttons, inputs and progress meters follow the same palette.
;;
;; Function: etaf-weread-cycle-theme (app)
;;;###autoload (autoload 'etaf-weread-cycle-theme "etaf-weread" nil t)
;; Switch APP to the next appearance and return it.
;; The order is `dark', `light' then `sepia', and the choice is stored in
;; `etaf-weread-settings-file'.  The session's `:theme' value is updated so a
;; mounted view repaints; replacing the view of an already mounted buffer is
;; the caller's job, which is what the reader's T key does.
;;
;; Function: etaf-weread-make-client (&key backend-directory node-program timeout)
;; Return a client that calls the backend in BACKEND-DIRECTORY.
;; NODE-PROGRAM runs the backend script, and TIMEOUT is the seconds a request
;; may take before it fails.  Every argument defaults to the matching
;; `etaf-weread-' variable, and the returned client is usable with
;; `etaf-weread-client-call'.
;;
;; Variable: etaf-weread-client-factory
;; Function of no arguments returning the client of new sessions.
;; Bind it to drive `etaf-weread-create' with another backend, which is how the
;; acceptance scenarios read a scripted account without the network.
;;
;; Function: etaf-weread-client-call (client request callback)
;; Send REQUEST to CLIENT and call CALLBACK once with its reply.
;; REQUEST is a plist starting with `:op' (`:status', `:login', `:logout',
;; `:shelf', `:notebook', `:book', `:notes', `:search', `:stats' or `:export').  CALLBACK receives
;; `(:ok DATA)' on success and `(:error MESSAGE :hint HINT)' on failure, at
;; most once.  A failure the backend explains itself (its JSON `message' and
;; `error') keeps that message and code; only a crash without a reply falls
;; back to naming the exit status.  A client that cannot answer calls it
;; neither; a session that is disposed by `etaf-weread-cancel' drops late
;; replies.
;;
;; Function: etaf-weread-cancel (client)
;; Cancel CLIENT's pending requests and drop their late replies.
;;
;; Function: etaf-weread-format-duration (seconds)
;; Return SECONDS of reading time as a compact string such as \"1小时13分\".
;; Zero or missing time returns an empty string, so a row can omit the column.
;;
;; Function: etaf-weread-progress-bar (percent &optional width)
;; Return a text progress bar of WIDTH cells for PERCENT (0 to 100).
;; WIDTH defaults to 8; the filled part uses U+2588 and the remainder U+2591.
;;
;; Variable: etaf-weread-backend-directory
;; Directory of the backend scripts used by the default client. The backend
;; ships inside this package; point it elsewhere only to try a modified copy.
;;
;; Variable: etaf-weread-node-program
;; Program used to run the backend's Node.js script.
;;
;; Variable: etaf-weread-request-timeout
;; Seconds a backend request may take before it fails with a timeout error.
;;
;; Variable: etaf-weread-login-timeout
;; Seconds `etaf-weread-login' waits for the browser login, default 300.
;; The backend waits up to three minutes for a QR scan, so signing in needs a
;; wider deadline than `etaf-weread-request-timeout'.
;;
;; Variable: etaf-weread-export-directory
;; Directory `etaf-weread-export-notes' passes to the backend, or nil for the
;; backend's own configured default.
;;
;; Error: etaf-weread-error
;; Invalid reader operation, for example an unknown section, an empty search
;; keyword, a missing book id or an unknown pane.  Backend failures are
;; reported in the session's `:error' and `:message' instead of being signaled,
;; because they happen asynchronously while the reader stays usable.

;;; Code:

;; The archive compiles this entry from a script that is still being loaded, so
;; `load-file-name` names that script.  `byte-compile-current-file` names the
;; file being compiled and must win, then `lisp/` resolves while the compiler
;; works on the independent modules an archive install compiles one by one.
(eval-and-compile
  (let ((directory (file-name-directory
                    (or (bound-and-true-p byte-compile-current-file)
                        load-file-name
                        buffer-file-name))))
    (add-to-list 'load-path (expand-file-name "lisp" directory))))

(require 'etaf-weread-theme)
(require 'etaf-weread-service)

(defun etaf-weread-doctor ()
  "Return capability facts for the WeChat Reading client.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Nothing is installed or changed."
  (let ((backend (expand-file-name "weread.mjs" etaf-weread-backend-directory)))
    (list :required
          (list (list "Node.js" (and (executable-find etaf-weread-node-program) t)
                      "Install Node.js 22 or newer with your system package manager; the backend ships with this package.")
                (list "Bundled backend" (and (file-readable-p backend) t)
                      "Reinstall etaf-weread; its backend ships inside the package."))
          :optional nil)))

(require 'etaf-weread-index)
(require 'etaf-weread-model)
(require 'etaf-weread-views)
(require 'etaf-weread-app)

(provide 'etaf-weread)
;;; etaf-weread.el ends here
