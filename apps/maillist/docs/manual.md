# maillist manual

maillist is a mailing-list client for Emacs. It reads a public-inbox archive —
the index page that lists threads and the per-thread Atom document that carries
every message — and keeps the reader's own state (read, starred, last-read
snapshots, cached bodies, custom sources and preferences) in a local SQLite
file. Sending goes through `message-mode` and either smtpmail or Emacs's own
`message-send-mail-function`.

The [root entry Commentary](../maillist.el) is the authoritative list of
supported functions, variables and the error type. This manual describes the
workflows and the contracts behind them; how the modules are organised is
documented in each module's own Commentary.

## Prerequisites

- Emacs 29.1 or newer, built with SQLite (`sqlite-available-p` returns
  non-nil). Without it the client still reads the archive, but nothing is
  stored between sessions.
- `ecss`, `ebox`, `etaf`, `etaf-ui` and `etaf-db` (from `emacs-taf/etaf`) on
  `load-path` for a source checkout; the archive install brings them in.

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui" "etaf-db"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/maillist")
(require 'maillist)
```

## Opening and managing archives

```elisp
M-x maillist-open
```

The client mounts in `maillist-buffer-name` (default `*maillist*`), keeps the
user's original Emacs theme mode line and fills the selected window. Every
control is reachable from the keyboard; the mouse works on the same elements.

`maillist-open` also takes `:list` (an archive name from `maillist-sources`)
and `:sync` — nil opens from the stored rows without contacting the archive,
which embedded hosts and the acceptance scenarios use.

The archive a client last opened is stored under the `last-list` setting, so a
later `M-x maillist-open` returns to it. `L` switches archive from inside the
client and also offers `+ 添加新邮件列表…` (`maillist-add-source`) to add any
public-inbox archive and persist it in settings. `M-x maillist-remove-source`
removes a source.

```elisp
(maillist-open :list "emacs-bugs")   ; a named archive, with a sync
(maillist-open :sync nil)            ; from the stored rows only
M-x maillist-close                   ; close the window and dispose the session
```

Which lists exist is `maillist-sources`: each entry is
`(:name NAME :base URL :address LIST-ADDRESS)`, with optional `:index` for a
local mirror, `:reply-style debbugs` for GNU Debbugs lists (`emacs-bugs`
sets this by default), and `:nntp (:host HOST :port PORT :group GROUP)` for
fast persistent NNTP sync (all four built-in `yhetil.org` lists enable this).

## Reading and keyboard navigation

The list shows one row per discussion with its status markers (`*` starred,
`+` unread, both shown simultaneously when applicable), sender, message count,
date (`HH:MM`, `昨天`, `MM-DD` this year, or `YY-MM` for earlier years) and
subject, grouped by date.

| Key | Action |
| --- | --- |
| `j` / `k` | next / previous thread (in narrow list view moves selection without marking read off-screen) |
| `RET` or click | open the thread |
| `n` / `p` | open the next / previous unread thread |
| `<` / `G` | jump to the first / last row |
| `]` / `[` | focus next / previous message in the open thread (also sets reply/raw target) |
| `SPC` / `DEL` / `S-SPC` | page down / up inside the reader (or list in narrow list view) |
| `u` | back from the thread to the list (narrow layout) |
| `M-g` | ETAF region selector (`f` search bar, `t` thread list, `v` reader) |
| `Tab` / `S-Tab` | step across regions (the thread list is a single focus group) |
| `?` | open read-only in-buffer modal help with bindings and syntax reference |

The reader keeps its header (subject, message count, participants, last reply)
fixed while the body scrolls in its own box. Within a message:

- reply indentation pads only the left edge and caps at depth 6 so deep
  discussions stay readable,
- the focused message carries a subtle accent bar on the left,
- newly arrived replies in a previously read thread are separated by a `新回复`
  divider,
- quoted lines keep a continuous vertical bar across wrapped lines and
  distinguish nested quote depths (`Q` folds/unfolds runs of 3+ quoted lines),
- unified diff headers (`diff --git`, `---`, `+++`, `@@`) and `+`/`-` hunks
  are highlighted while RFC 3676 signatures (`-- `) dim cleanly and end hunks,
- the reply target of a message is named in the warm colour (preserved offline
  in SQLite),
- web addresses mentioned in non-quoted lines are listed below the message as
  clickable links, preserving balanced parentheses in URLs.

`e` expands the messages a long thread holds back (`maillist-message-window`,
20 by default), and `z` collapses or expands all visible messages at once. A
thread larger than `maillist-fast-open-threshold` messages shows its newest
message from the search feed first, then the full conversation.

Reopening a thread fetched within `maillist-thread-freshness` seconds (60 by
default) serves its cached messages immediately without re-fetching. When a
background refresh fails offline, cached messages remain on screen with an
`离线缓存` note instead of being replaced by an empty error placeholder.

`C` copies the archive page URL (`maillist-thread-url`), `B` opens it in the
browser, `m` copies the thread's `t.mbox.gz` URL (`maillist-thread-mbox-url`,
ready for `git am`), `w` copies the focused message's canonical `<Message-ID>`,
and `v` fetches and opens its raw RFC 5322 source and full headers in a
read-only `view-mode` buffer.

## Marks and new-reply detection

A thread is marked read once its body is on screen, recording the thread's
`:date` and `:count` in the `marks` table as the last-read snapshot and
clearing its `:new` highlight. On a later sync, if an already-read thread
receives replies (its archive timestamp or message count advances), it
automatically re-surfaces as unread and new, with the reader marking where the
new replies begin.

| Key | Action |
| --- | --- |
| `M-u` | mark the selected thread unread |
| `A` | mark every row the current scope shows read in one transaction |
| `s` | toggle star (starred threads are exempt from cache pruning) |

## Scopes

`1`, `2` and `3` switch between all threads, unread only and starred only.
A scope is a local filter over the visible rows; the selected/open row stays
visible while it is read so `j` carries on from it.

## Searching

`/` focuses the search field. Local-only mark queries filter live; remote
archive queries run when you press `RET` (avoiding mid-typing requests and
partial entries in history). Clearing the field (or clicking the clear icon)
immediately restores the cached archive list offline.

| Form | Effect |
| --- | --- |
| `from:` `to:` `subject:` `body:` `message:` | matching archive field (prefix `-` to exclude, e.g. `-from:bot`) |
| `after:2026-10-01` `before:2026-10-10` | date range |
| `is:unread` `is:read` `is:starred` | local marks (`-is:...` negates), no network request |
| `"two words"` | exact phrase |

Search results live in a view separate from `:archive-threads`: opening a
search result or receiving a background scheduled sync never writes search
rows into SQLite and never overwrites the visible search view.

When the archive cannot answer (network error or anti-bot challenge page),
the query falls back to structured local search over cached threads and bodies
for the current archive (`maillist-local-search-limit`, 50 rows), honouring
field clauses, negations, date bounds and escaped SQLite wildcards, and showing
a single-line snippet when a body matched.

`M-p` and `M-n` walk the submitted query history, newest first
(`maillist-recall-query`); past the oldest query the walk returns to the
archive list.

## Older mail

`o` extends the archive list with older mail:

- When the archive is backed by NNTP, `o` fetches the preceding
  `maillist-nntp-older-batch` (200) overview headers directly over the
  persistent connection.
- Otherwise, when the archive's index page exposes public-inbox's native
  `?t=...` `next (older)` cursor, `o` pages the thread index directly,
  preserving thread counts and nesting.
- Otherwise it queries the archive's date search using full timestamp
  comparison (so earlier same-day mail is not skipped) and automatically steps
  result offsets past high-volume days.

`o` is disabled while viewing search results so search rows never mix into the
archive cache.

## Automatic sync and caching

An open client syncs every `maillist-auto-refresh` seconds (300 by default;
nil syncs only on demand). The scheduled sync is quiet, counts newly added
threads and new replies in the summary (`6 个线程 · 2 未读 · 1 新 · 22:05 同步`),
and never clobbers an active search view.

- **Persistent NNTP fast path**: Sources declaring `:nntp` (all four default
  `yhetil.org` lists) sync incrementally via `GROUP` + `XOVER` over one
  persistent non-blocking socket — delivering authors, dates and threading in
  under a second without `/raw` storms — and fetch thread bodies via pipelined
  `ARTICLE <Message-ID>` commands, fetching only messages not already cached in
  SQLite. If NNTP is unreachable or blocked, the client falls back
  transparently to HTTP.
- **Authoritative cache hits & idle warmup**: Opening a cached thread whose
  message count and newest timestamp already cover the archive row renders in
  0 ms with zero network traffic (even across restarts, unless
  `maillist-thread-freshness` is 0). After each sync, up to
  `maillist-prefetch-bodies` (10) top uncached unread threads warm quietly in
  the background at low priority, yielding immediately to user navigation.
- **HTTP-only sources**: After the index arrives, `new.atom` fills newest
  authors and caches single-message bodies, then missing senders fetch gently
  (`maillist-prefetch-parallel` 1), yielding to user clicks.

## Sending

| Key | Action |
| --- | --- |
| `r` | reply to the list (or `<bug>@debbugs.gnu.org` in `emacs-bugs`) |
| `R` | reply to the list, copying the replied message's author (excluding self and list) |
| `C-u r` | reply privately to the replied message's author |
| `c` | post a new message to the list |

Replies target the currently focused message (`[` / `]`, defaulting to the
first new or newest message), build `In-Reply-To` from its canonical decoded
`<Message-ID>` and `References` from its RFC 5322 `:parent` ancestor chain
(keeping the thread root plus up to 9 nearest ancestors), format `From:` with
`user-full-name`, and place point directly in the message body.

Two sending modes are controlled by `maillist-send-mail-function`:

- `'smtpmail` (default): uses `maillist-smtp-server`, `maillist-smtp-service`
  and `maillist-smtp-stream-type` with auth-source credentials stored by
  `M-x maillist-mail-configure` (plaintext `~/.authinfo` is automatically set
  to mode `0600`).
- `'inherit`: leaves Emacs's own `message-send-mail-function` untouched (for
  `msmtp`, `sendmail`, `gmi`, etc.).

## Storage

Everything the client keeps lives in `maillist-store-file`
(`~/.emacs.d/maillist/store.sqlite3`) in WAL mode with a 5-second busy timeout:

| Table | Contents |
| --- | --- |
| `threads` | archive cache keyed by `(list_name, id)` with `(list_name, date)` index |
| `messages` | cached bodies (including `:parent`) keyed by `(thread, id)` with `(thread, position)` index |
| `marks` | read, starred, `read_date` and `read_count` snapshot per thread |
| `settings` | `last-list`, `list-width`, `custom-sources` |
| `nntp_articles` | NNTP article numbers, `Message-ID`s, normalized thread roots and `References` |

Valid v0.3.0 stores migrate in place to composite keys without losing threads
or marks. An incompatible or torn file is moved aside to
`store.sqlite3.rebuild-<time>` and rebuilt with a notice naming the backup.

`maillist-store-prune` enforces `maillist-thread-limit` (2000) and
`maillist-body-limit` (400) per list, exempts starred threads and never drops
other lists' cached bodies, reclaiming space incrementally via
`PRAGMA incremental_vacuum` and `wal_checkpoint(PASSIVE)`.

## Network

`maillist-transport` selects `'auto` (default: persistent NNTP when the source
declares `:nntp` with automatic HTTP fallback), `'nntp` or `'http`. Remote
full-text search always uses public-inbox's HTTP Xapian endpoint.

For HTTP requests, `maillist-network-route` picks the leading route (`auto`,
`proxy` or `direct`) with fallback after `maillist-route-attempt-timeout`
seconds (10); once a fallback route succeeds, it leads for 5 minutes so every
request does not stall against a down endpoint. HTTP/1.1 keep-alive reuse is
disabled per request to avoid reverse-proxy socket stalls, and HTTP responses
decode according to their declared `Content-Type` charset (defaulting to
UTF-8). `maillist-proxy` names an HTTP(S) proxy (`HOST:PORT`); when nil, the
client reads HTTP/HTTPS entries from `url-proxy-services` or `HTTP(S)_PROXY`
(ignoring `no_proxy`-only lists and `socks*://` addresses).

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `maillist-sources` | four `yhetil.org` archives | archives the client can open |
| `maillist-default-list` | `"emacs-devel"` | archive used when nothing was opened yet |
| `maillist-buffer-name` | `"*maillist*"` | buffer the client mounts in |
| `maillist-transport` | `auto` | `auto` (NNTP + HTTP fallback), `nntp` or `http` |
| `maillist-nntp-sync-window` | 250 | recent articles fetched on initial NNTP sync |
| `maillist-nntp-older-batch` | 200 | older articles fetched per NNTP `o` |
| `maillist-nntp-connect-timeout` | 6 | seconds before NNTP connect falls back to HTTP |
| `maillist-store-file` | `~/.emacs.d/maillist/store.sqlite3` | SQLite file |
| `maillist-thread-limit` | 2000 | threads kept per archive (starred exempt) |
| `maillist-body-limit` | 400 | threads per archive keeping cached bodies (starred exempt) |
| `maillist-message-window` | 20 | messages a long thread shows first |
| `maillist-thread-freshness` | 60 | seconds a fetched thread skips re-fetching (0 forces refresh) |
| `maillist-fast-open-threshold` | 40 | messages that make an HTTP thread open on the search feed first |
| `maillist-prefetch-threads` | 500 | HTTP threads whose sender is fetched after a sync |
| `maillist-prefetch-parallel` | 1 | HTTP sender requests kept in flight per batch |
| `maillist-prefetch-bodies` | 10 | uncached unread/recent threads warmed quietly on idle |
| `maillist-auto-refresh` | 300 | seconds between automatic syncs, nil for on demand |
| `maillist-older-batch` | 50 | rows one date-search `o` adds |
| `maillist-local-search-limit` | 50 | cached rows a fallback search reports |
| `maillist-narrow-width` | 104 | columns below which the layout is one column |
| `maillist-route-attempt-timeout` | 10 | seconds the leading route may stall |
| `maillist-network-route` | `auto` | `auto`, `proxy` or `direct` |
| `maillist-proxy` | nil | `HOST:PORT` of the HTTP(S) proxy |
| `maillist-mail-address` | `user-mail-address` | address mail is sent from |
| `maillist-send-mail-function` | `smtpmail` | `smtpmail` or `inherit` |
| `maillist-smtp-server` | `smtp.gmail.com` | SMTP host |
| `maillist-smtp-service` | 465 | SMTP port |
| `maillist-smtp-stream-type` | `ssl` | `ssl`, `starttls` or nil |

## When something fails

| Symptom | Cause and what to do |
| --- | --- |
| `同步失败：无法连接代理 …` | the proxy client is not running; the direct route failed too. Start the proxy or set `maillist-network-route` to `direct`. |
| `同步失败：档案返回 HTTP 403` | the archive served a challenge page (Anubis, go-away). Use another mirror or open the page in a browser. |
| `刷新失败（…），当前显示本地缓存` | offline or archive unreachable while reopening a cached thread; cached text remains readable. Press `g` when online. |
| `搜索失败：…` | neither the archive nor the local cache matched. Press `g` to retry or clear the search box to restore the list immediately. |
| `Sending...failed` with an auth error | run `M-x maillist-mail-configure` or set `maillist-send-mail-function` to `'inherit`. |
| a sent message does not appear | GNU lists moderate posts from unsubscribed addresses; archive mirrors also lag slightly behind list delivery. |
| `没有打开的邮件列表` | the client buffer was closed; `M-x maillist-open` opens it again. |

## Development

```sh
make check     # structure, byte compilation, acceptance scenarios, public API
make test      # acceptance scenarios only
make gui       # drive the GUI scenario on a running Emacs server
make clean
```
