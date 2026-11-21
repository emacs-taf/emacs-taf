# Changelog

All notable user-visible changes to maillist are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [0.4.1] - 2026-11-22

### Fixed

- Restored symmetric vertical breathing space (`:height '(lh 3)` in wide mode
  and top/search row spacing in narrow mode) in `maillist-appbar` so the search
  bar and list header sit centered instead of flush against the top edge.

## [0.4.0] - 2026-11-22

Reliable daily reading across real public-inbox archives: UTF-8 HTTP decoding,
offline cache preservation, new-reply detection, Debbugs reply routing,
per-message focus and replies, composite SQLite keys with in-place migration,
and full ETAF region navigation and help integration.

### Added

- **New-reply detection**: `marks` now records `:read-date` and `:read-count`
  when a thread is read; a later sync that advances a read thread's date or
  message count re-surfaces it as unread and new, with a `新回复` divider in
  the reader.
- **Per-message focus and actions**: `[` / `]` (`maillist-move-message`,
  `maillist-select-message`) select any message in an open thread as the target
  for `r` / `R` / `C-u r`, raw RFC 5322 viewing (`v`, `maillist-fetch-raw`)
  and copying canonical `<Message-ID>` (`w`).
- **Debbugs routing**: `emacs-bugs` (or any source with `:reply-style debbugs`)
  automatically addresses replies to `<bug>@debbugs.gnu.org` parsed from the
  subject instead of filing a new bug at `bug-gnu-emacs@gnu.org`.
- **Reading & workflow controls**: `p` (`maillist-prev-unread`), `<` (jump to
  first row), `SPC` / `DEL` / `S-SPC` (page reader from anywhere), `z`
  (`maillist-toggle-all-messages`), `Q` (`maillist-toggle-quotes` for 3+ line
  quote blocks), `m` (`maillist-thread-mbox-url` for `t.mbox.gz`), and
  persistent custom archive sources (`maillist-add-source`,
  `maillist-remove-source`, and `+ 添加新邮件列表…` inside `L`).
- **Flexible mail transport**: `maillist-send-mail-function` (`smtpmail` or
  `inherit`) lets users reuse Emacs's existing `message-send-mail-function`.
- **ETAF keyboard contract**: declared `search` (`f`), `threads` (`t`, with
  `:focus-group vertical`) and `reader` (`v`) regions for `M-g` and single-step
  `Tab` traversal, plus in-buffer `?` help notes.
- **Persistent NNTP fast transport** (`maillist-transport`, default `auto`):
  all four built-in `yhetil.org` lists now sync incrementally over persistent
  non-blocking NNTP (`GROUP` + `XOVER` with full RFC 2047 authors & threading,
  eliminating `/raw` storms and anti-bot tarpits) and pipeline `ARTICLE <mid>`
  bursts with full RFC 5322 / MIME decoding, falling back transparently to HTTP
  if NNTP is unreachable.
- **0 ms authoritative cache hits & idle body warmup**: reopening a cached
  thread whose count and timestamp already cover the archive row renders
  immediately without a network round-trip; `maillist-prefetch-bodies` (10 by
  default) quietly pre-caches top uncached unread threads on idle at low
  priority while yielding to user clicks.
- **Preserved Emacs mode-line & clearer buffer name**: `maillist-open` now
  passes `:mode-line t` to `etaf-app-open` so the buffer retains the user's
  original Emacs theme mode-line, and `maillist-buffer-name` defaults to
  `"*maillist*"` instead of `"*ETAF Lists*"`.
- **Box-model search & action toasts**: replaced the rounded pill search input
  with a clean rectangular box search field matching the segmented controls;
  `s` (star/unstar), `e`, `[`/`]` boundaries and manual `g` refresh now show
  crisp rectangular bottom-right notices; switching to `未读`/`已收藏` no longer
  drags unrelated rows from `全部` and shows context-specific empty states;
  focused messages keep fixed horizontal alignment with theme-native `:select`
  highlighting and a `* 已收藏` badge in the reader header.
- **Native index pagination**: `o` (`maillist-load-older`) pages via NNTP
  `XOVER` on NNTP-backed lists, follows public-inbox `?t=...` next-page cursors
  on HTTP lists, and steps offsets past high-volume days when falling back to
  date search.

### Fixed

- **HTTP keep-alive stalls & dead-proxy double-retries**: disabled
  `url-http-attempt-keepalives` per request to eliminate 15–45 s hung-socket
  stalls behind `yhetil.org`'s `go-away` proxy, guarded route fallback against
  duplicate retries, cached the healthy network route for 5 minutes so a closed
  proxy is not retried on every request, cached single-message bodies from
  `new.atom`, and lowered HTTP `maillist-prefetch-parallel` default to `1`.
- **UTF-8 HTTP decoding**: HTTP responses from `url-retrieve` are now decoded
  using the declared `Content-Type` charset (default UTF-8) instead of staying
  raw unibyte octets, eliminating mojibake on real online archives.
- **Offline cached reading**: reopening a cached thread when the network fails
  keeps its cached body visible (`离线缓存`) instead of replacing it with an
  empty error placeholder; freshly fetched threads skip redundant reloads
  within `maillist-thread-freshness` (60 s) without skeleton flicker.
- **Search / archive isolation**: search results no longer overwrite
  `:archive-threads`; clearing a search restores the full cached list
  immediately offline, and background syncs or `o` never contaminate SQLite
  with search rows. Remote queries run on `RET` instead of firing mid-typing
  requests that polluted `:query-history`.
- **Canonical Message-IDs & RFC 5322 headers**: percent-encoded IDs from archive
  links decode canonically and encode once in URLs; `References` walks the
  `:parent` ancestor chain (root + up to 9 recent ancestors); `R` excludes the
  sender's own address and list address from Cc; `From:` includes
  `user-full-name`; draft point lands in the body; plaintext `~/.authinfo` is
  set to mode `0600`.
- **Deep threads & layout bounds**: message indentation pads only the left edge
  and caps at depth 6; the appbar uses flex allocation instead of an
  absolutely-positioned summary so medium-wide windows never overlap; dragged
  `:list-width` clamps on window shrink and persists in settings; status
  markers display `*` (starred) and `+` (unread) simultaneously in sync with
  the manual; footer hints budget to viewport width with distinct labels.
- **SQLite integrity & local fallback search**: `threads` and `messages` use
  composite keys `(list_name, id)` and `(thread, id)` with indexes and in-place
  migration from v0.3.0 (preserving marks and `:parent`); removed hardcoded
  5000-mark and 2000-thread read caps; pruning is per-list, exempts starred
  threads and uses non-blocking incremental vacuum; offline local search
  evaluates structured query clauses across subjects, authors and bodies with
  escaped LIKE wildcards and thread deduplication.
- **Parsing, diffs, links & proxy**: `maillist-parse-thread` parses XML once
  via `libxml-parse-xml-region` when available; diff headers (`diff --git`,
  `---`, `+++`) and RFC 3676 `-- ` signatures classify cleanly; quote bars span
  wrapped lines via `:border-left`; link extraction skips quoted lines and
  preserves balanced parentheses; proxy detection ignores `socks*://` and
  `no_proxy`-only `url-proxy-services`; `new.atom` finishes before batched
  `/raw` sender prefetch; narrow list moves no longer mark unseen threads read.

## [0.3.0] - 2026-10-30

Reading a mailing list continuously: several archives, scheduled syncs, read
marks that go both ways, mail older than the index page, and a search that
answers when the archive does not.

### Added

- `L` switches archive inside the client, and the client remembers the one it
  opened last (`maillist-store-setting`), so the next start returns to it.
  `maillist-open` takes `:list`.

- `1`, `2` and `3` switch between all threads, unread only and starred only;
  `n` opens the next unread thread and `G` the last row of the list.

- `R` replies to the list and copies the last message's author; `r` stays the
  answer to the list alone and `C-u r` the answer to the author alone.

- `maillist-store-search-bodies`, `maillist-store-prune` and the mark writes
  read the SQLite file the store was opened on rather than the default one, so
  a caller that opens a store over another file gets that file's answers.

- Moving through a long list is several times faster: the theme palette is
  derived once per theme instead of once per row (300 threads: 50 ms per move
  became 12 ms, 1000 threads: 162 ms became 32 ms, measured without redisplay).
  The shared components take their tokens from a computed value, so switching
  the Emacs theme now repaints the search field and buttons with the rest.


- `M-u` marks the open thread unread and `A` marks every row the current scope
  shows read, in one store transaction (`maillist-set-read`,
  `maillist-mark-all-read`).

- `o` loads mail older than the list: the archive's own date search answers
  with the messages before the oldest date the client holds, which are grouped
  by discussion and capped at `maillist-older-batch` (`maillist-load-older`).

- An open client syncs every `maillist-auto-refresh` seconds. The scheduled
  sync is quiet, counts the threads the archive added in the summary and tints
  those rows; a failure still reports.

- A search the archive cannot answer falls back to the cached bodies
  (`maillist-local-search-limit`) and the row names the text that matched.

- `M-p` and `M-n` walk the queries this client ran (`maillist-recall-query`),
  ending at the archive's list.

- `C` copies the archive's page of the thread and `B` opens it in the browser
  (`maillist-thread-url`), so a discussion can be shared.

- Every message lists the web addresses it mentions as links a reader can open
  (`maillist-message-links`).

- `make gui` runs `scripts/maillist-gui-scenarios.el` on the shared GUI
  verifier: the documented keys, then the wide, narrow and short sizes, with
  assertions and frame captures for each step.

### Fixed

- The client stays inside its window. The canvas took its width from the
  viewport the mount was opened with, so after a resize the hint row and the
  summary ran under the canvas edge; the appbar summary is now placed on its
  row instead of being pushed out by a growing spacer, and the reader column
  takes the room the list leaves instead of the whole row, which had clipped
  its paragraphs.

- The client no longer draws a text cursor on whatever cell the pointer last
  landed on.

- A `file:` archive never takes a proxy route, so a local mirror is read even
  when the configured route is the proxy.

- A store file a crash left unreadable — a write cut short by a full disk, or
  a file truncated later — is moved aside and rebuilt, with a notice naming the
  backup that still holds the marks.  Before, the client opened it, failed its
  first statement and ran without persistence for the rest of the session.

### Changed

- The store uses WAL with a busy timeout, so two Emacs instances can read and
  write the same file. It gained a settings table, batch mark writes and a
  retention pass: `maillist-thread-limit` threads per archive and
  `maillist-body-limit` cached bodies, newest kept, marks always kept
  (`maillist-store-prune`, `maillist-store-save-marks`,
  `maillist-store-search-bodies`).

- `README.md` and `docs/manual.md` cover the workflows, every variable, the
  storage layout and what to do when a sync, a search or a send fails.

## [0.2.0] - 2026-10-30

First release in the ETAF package archive
(`https://etaf.top/packages/`), so `M-x etaf-install` installs the client
with the providers it needs.

### Added

- `maillist-proxy` names the proxy archive requests use, so a client can reach
  the archive through its own proxy without exporting a proxy variable for
  every Emacs request.  An `auto` route whose direct attempt stops answering
  now retries through that proxy after 10 seconds instead of waiting for the
  45-second request timeout.

- Search takes mail-client syntax: `from:`, `to:`, `subject:`, `body:`,
  `message:`, `after:` and `before:` compile into the archive's own query,
  while `is:unread` and `is:starred` filter the rows locally without a
  request.  A query naming only local marks filters the current list.

- `C-u r` replies to the last message's author instead of the list, keeping
  the thread's `In-Reply-To` and `References`.


- Read a public-inbox archive as a mail client: date-grouped thread list,
  unread and starred scopes, remote search, and a reader that keeps the
  thread header fixed while the body scrolls inside its own box.

- Read and starred marks plus thread bodies are stored in one SQLite file, so
  a restart shows the list before the archive answers.

- Long threads open with their newest messages and grow on demand (`e`), so a
  thousand-message thread stays responsive.

- Reply (`r`) and new post (`c`) open in `message-mode` with `In-Reply-To`
  and `References`, sending through smtpmail with an application password
  stored by `M-x maillist-mail-configure` in auth-source.

- The pane divider can be dragged to resize the thread list, and the layout
  collapses to one column below `maillist-narrow-width`.

- Every thread's sender fills in after a sync: the index names none, so the
  client reads one raw message per unknown sender, three at a time, and stores
  the name.  Rows waiting for a name show `…`.

- A thread whose fetch fails reports the error in the reader header instead of
  showing an empty conversation, and never replaces a cached body with nothing.

- The search field takes the space its query needs instead of wrapping a long
  address onto a second line, and an empty search result says so.

- Sync state, errors and search feedback appear as a floating notice at the
  top right and leave on their own, so a message never moves the list or the
  reader.

- Opening a thread larger than `maillist-fast-open-threshold` shows its newest
  mail from the small search feed at once, then replaces it with the whole
  conversation; a 72-message thread shows content in 0.4s instead of 3.2s.

- When the archive merges a thread into an older discussion (a reply with a
  broken References header), the reader keeps the conversation the index
  named: it shows the subject's messages and says the archive merged the
  thread, instead of a thousand old mails under the new subject.

- The thread list keeps one column grid: a buried sub-thread no longer shifts
  its author, count, time and subject by two cells.

- Colour now follows roles instead of decorating: authors stay neutral (ink
  when unread, muted when read), the list's unread subjects take the theme's
  link colour softened toward the surface, a reply names the person it
  answers in the theme's warm colour, and diff lines keep their green/red
  pair.  Backgrounds stay reserved for state and reading aids: the selected
  row, quoted and patch bands, and the floating notice.

### Fixed

- A proxy route no longer takes the client offline when the proxy is not
  running.  The route that leads hands the request to the other one when it
  cannot connect or stops answering, so `proxy' falls back to the direct
  connection and `auto' still reaches the archive when the direct path is
  blocked.  A request that reaches nothing now names what it could not
  connect to (`无法连接代理 127.0.0.1:7890；无法连接档案 yhetil.org:443`)
  instead of url.el's `peculiar error` carrying a property list.

  `maillist-direct-attempt-timeout` is now `maillist-route-attempt-timeout`,
  because it bounds whichever route leads.

- A search no longer opens its first result, so running a query cannot mark a
  thread read.  A search that the archive cannot answer reports the error and
  leaves the
  thread the reader had open, instead of emptying the reader while the
  request is in flight.  Reading a thread under `is:unread` or `is:starred`
  keeps that row visible while it is open.

- A refresh no longer shortens the list.  The archive's index page names only
  recent threads, so its rows now merge into the stored list instead of
  replacing it: a thread the page no longer lists keeps its row, its author and
  its marks.  Before, threads older than the first page vanished from the list
  until the next restart.

- Opening a thread marks it read only once its body is on screen.  An archive
  that never answered, or a row only passed through with `j`/`k`, keeps the
  thread unread; before, selecting the row marked it read before the fetch.

- A displayed search result can no longer become the stored fact of a thread.
  The search row's date, count and subject are no longer written back to the
  archive cache while a query is active.

- A buried reply no longer climbs above the message it answers after a
  restart.  The thread table now keeps the archive's depth, and a reply sorts
  after its parent when both carry one timestamp.

- A thread document the archive will not serve no longer leaves the reader on
  a loading placeholder and then a bare error.  The client shows the newest
  message it can reach from the archive's search feed, says the thread data is
  incomplete, and reports only when even that message is unavailable.

- A cache file written by an incompatible earlier version is moved aside and
  rebuilt at startup, with a notice naming the backup file, instead of leaving
  the client with no persistence.  `threads`, `messages` and the new `marks`
  table are created together.

- An archive answer that carries no thread row is no longer taken as an empty
  list.  Such an answer is fetched once more; if it stays unanswered the sync
  fails with a notice and the client keeps the list and the stored rows it
  already has.  Before, an empty body after a dropped connection wiped the
  visible list and then failed to save it.

### Changed

- Composing a reply or a new post no longer needs a stored SMTP password up
  front.  The password is read from auth-source when the mail goes out, so a
  reply can be written before the account is configured.

- The thread cache is kept per archive.  Rows stored before this change are
tagged with the first list opened, and rows of another list never appear in
the current one.

- Read and starred marks now live in their own `marks` table, written only when
  the reader changes them.  A refresh rewrites the archive cache and cannot
  lose them.  The first start after upgrading reads old files with the new
  schema, so previously read threads show as unread once.
