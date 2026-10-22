;;; maillist.el --- Mailing-list archive client -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0") (etaf-db "0.1.0"))
;; Keywords: mail
;; URL: https://github.com/emacs-taf/maillist

;;; Commentary:

;; maillist reads a public-inbox archive as a mail client: the thread list,
;; the open conversation and the client's own read and starred marks.  The
;; archive cache, cached bodies and marks live in one SQLite file, so a restart
;; shows the list before the archive answers; the marks sit in their own table,
;; so a refresh cannot lose them.  A reply or a new post opens in `message-mode'
;; with the thread's message ids in `In-Reply-To' and `References', and leaves
;; through smtpmail with an application password from auth-source.
;;
;; Load this package with (require 'maillist) after adding this repository
;; root and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  Then use
;; M-x maillist-open.  The archive service below is usable without a buffer:
;; it parses a public-inbox document and fetches one asynchronously, so an
;; embedder can build its own client on the same data.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  This Commentary is the authoritative export
;; list; implementations and precise docstrings remain beside their
;; definitions.
;;
;; Function: maillist-open (&key (sync t))
;;;###autoload (autoload 'maillist-open "maillist" nil t)
;; Mount the client in its own buffer and return that buffer.  SYNC nil opens
;; from the local cache without contacting the archive.
;;
;; Function: maillist-close ()
;;;###autoload (autoload 'maillist-close "maillist" nil t)
;; Close the mounted client and kill its buffer.
;;
;; Function: maillist-create (&key (list maillist-default-list))
;; Create a client session over the archive LIST (a `maillist-sources' name)
;; and return it.  The session is the value a View reads: `:threads', `:groups',
;; `:open', `:selected', `:scope', `:query', `:summary', `:status', `:reading'
;; and `:viewport' are reactive refs; `:source' and `:store' are plain values.
;;
;; Function: maillist-dispose (session)
;; Release SESSION's store and ignore late archive answers.  Closing the
;; mounted buffer does the same; use this with a session that has no buffer.
;;
;; Function: maillist-refresh (session)
;; Reload SESSION's thread list from its archive; the request is asynchronous
;; and `:status' carries `loading', `idle' or `error' while it runs.  The index
;; page lists recent threads only, so its rows merge into the stored list: a
;; thread the page no longer names keeps its row and its marks.
;;
;; Function: maillist-select (session id &optional no-mark)
;; Open the thread ID of SESSION, fetching its body when uncached, and return
;; the open-thread value.  Unless NO-MARK is non-nil, the thread becomes read
;; once its body is on screen: a fetch that never answers leaves it unread.
;;
;; Function: maillist-move (session delta)
;; Move the selection by DELTA rows and open the new row.
;;
;; Function: maillist-toggle-star (session)
;; Star or unstar the selected row, persist the choice and return the new state.
;;
;; Function: maillist-toggle-message (session id)
;; Fold or unfold message ID of the open thread and return the new state.
;;
;; Function: maillist-load-earlier (session)
;; Grow the open thread's message window by `maillist-message-window' and
;; return the new window size.
;;
;; Function: maillist-set-scope (session scope)
;; Show only SCOPE's rows: `all', `unread' or `starred'.
;;
;; Function: maillist-search (session text)
;; Search the archive for TEXT, or return to the archive's own index when TEXT
;; is empty.  TEXT may name `from:', `to:', `subject:', `body:' and `message:',
;; a date range with `after:' and `before:', and the reader's own marks with
;; `is:unread' or `is:starred'; `maillist-compile-query' turns it into the
;; archive's query and the local filters.  A query naming only local marks
;; filters the rows already shown and contacts nothing.
;;
;; Function: maillist-rows (session)
;; Return the rows SESSION shows, in list order, honouring `:scope'.
;;
;; Function: maillist-row (session id)
;; Return the row of SESSION named ID, or nil.
;;
;; Function: maillist-selected-row (session)
;; Return the row SESSION currently shows, or nil.
;;
;; Function: maillist-source (name)
;; Return the source named NAME from `maillist-sources'; an unknown name is an
;; error.  A source is (:name NAME :base URL :address LIST-ADDRESS) with an
;; optional `:index' file name for a mirror that serves one.
;;
;; Function: maillist-parse-index (html)
;; Parse a public-inbox index page into thread rows
;; (:id :subject :date :count :depth), newest first.  `:date' is an ISO-8601
;; UTC stamp and a buried sub-thread has `:depth' 1.
;;
;; Function: maillist-parse-thread (xml-text &optional fallback-subject)
;; Parse a public-inbox thread Atom document into
;; (:id :subject :participants :messages).  Each message is
;; (:id :author :email :date :depth :subject :text), where `:text' is the raw
;; body that `maillist-classify-lines' renders.  A document without messages
;; signals an error instead of reporting an empty thread.
;;
;; Function: maillist-parse-author (text)
;; Return the sender display name of the raw message TEXT, or nil.  Folded
;; headers and RFC 2047 encoded names are unfolded and decoded.
;;
;; Function: maillist-parse-recent (xml-text)
;; Parse a public-inbox new-messages feed into (MESSAGE-ID . AUTHOR) hints.
;;
;; Function: maillist-classify-lines (text &optional prefix)
;; Split a message body into (:id :kind :text) lines.  KIND is `body',
;; `blank', `quote', `patch-meta', `patch-add' or `patch-del'; PREFIX names
;; the message so every line keeps a stable key.
;;
;; Function: maillist-fetch-index (source callback)
;; Fetch SOURCE's thread list and call CALLBACK with (:ok ROWS) or (:error MSG).
;; An answer that carries no thread row is fetched once more, then reported as
;; an error, not as an empty list: a mirror always lists its threads, so a
;; body-less answer or a page that is not the index means the archive did not
;; answer, and the caller keeps the rows it already has.
;;
;; Function: maillist-fetch-thread (source id callback &optional subject)
;; Fetch thread ID and call CALLBACK with (:ok THREAD) or (:error MSG).
;;
;; Function: maillist-fetch-search (source query callback)
;; Search SOURCE for QUERY and call CALLBACK with (:ok ROWS) or (:error MSG).
;; QUERY is the archive's own syntax; `maillist-compile-query' builds it.
;;
;; Function: maillist-compile-query (text)
;; Compile the reader's search TEXT for a public-inbox archive.  Fields
;; `from:', `to:', `subject:', `body:' and `message:' become the archive's own
;; prefixes, `after:' and `before:' become one date range, and bare words or
;; quoted phrases stay terms.  `is:unread' and `is:starred' are returned as
;; local filters, because the archive does not know this reader's marks.
;; Return (:query REMOTE :filters (unread starred)); REMOTE is empty when TEXT
;; only names local filters.
;;
;; Function: maillist-fetch-recent (source callback)
;; Fetch SOURCE's newest messages and call CALLBACK with (:ok HINTS).
;;
;; Function: maillist-time-label (stamp)
;; Return STAMP read as a list label: a clock today, `昨天' yesterday, a date
;; before that.
;;
;; Function: maillist-day-label (stamp)
;; Return the group label of STAMP: `今天', `昨天', `本周' or `更早'.
;;
;; Function: maillist-long-label (stamp)
;; Return STAMP as a readable date for the reader header.
;;
;; Function: maillist-reply (session &optional private)
;; Reply to SESSION's open thread in a `message-mode' buffer.  A private reply
;; goes to the last message's author instead of the list; both forms keep the
;; thread's `In-Reply-To' and `References'.
;;
;; Function: maillist-compose (session)
;; Write a new post to SESSION's list in a `message-mode' buffer.
;;
;; Function: maillist-mail-configure ()
;;;###autoload (autoload 'maillist-mail-configure "maillist" nil t)
;; Store the SMTP application password of the sending account in auth-source.
;;
;; Variable: maillist-sources
;; Archives the client can open; a source may name an `:index' file for a
;; local mirror.
;;
;; Variable: maillist-default-list
;; Archive a new client opens, by default "emacs-devel".
;;
;; Variable: maillist-store-file
;; SQLite file holding the thread list, read and starred marks and cached
;; bodies.
;;
;; Variable: maillist-message-window
;; How many of the newest messages a thread shows at first.
;;
;; Variable: maillist-prefetch-threads
;; How many threads without an author to warm after each sync.
;;
;; Variable: maillist-narrow-width
;; Viewport width below which the client shows one column.
;;
;; Variable: maillist-network-route
;; `auto' (direct, then the environment proxy), `direct' or `proxy'.
;;
;; Variable: maillist-mail-address
;; Address the client sends from; its password comes from auth-source under
;; `maillist-smtp-server'.
;;
;; Variable: maillist-smtp-server
;; SMTP host used for replies and new posts; default "smtp.gmail.com".
;;
;; Variable: maillist-smtp-service
;; SMTP port used for replies and new posts; default 465.
;;
;; Variable: maillist-smtp-stream-type
;; Transport of the SMTP connection: `ssl' (the default), `starttls' or nil.

;;; Code:

;; Consumers that only add this repository root to `load-path' (the manual's
;; installation path) reach the submodules through this entry, so the `lisp/'
;; directory is added here instead of asking every caller for it.
(add-to-list 'load-path
             (expand-file-name "lisp"
                               (file-name-directory (or load-file-name
                                                        buffer-file-name))))

(require 'maillist-app)
(require 'maillist-mail)
(require 'maillist-model)
(require 'maillist-service)

(provide 'maillist)
;;; maillist.el ends here
