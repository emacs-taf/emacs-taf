# maillist manual

maillist is a mailing-list client for Emacs. It reads a public-inbox archive —
the index page that lists threads and the per-thread Atom document that carries
every message — and keeps the reader's own state (read, starred, cached bodies,
the last archive) in a local SQLite file. Sending goes through `message-mode`
and smtpmail.

The [root entry Commentary](../maillist.el) is the authoritative list of
supported functions, variables and the error type. This manual describes the
workflows and the contracts behind them; how the modules are organised is
documented in each module's own Commentary.

## Prerequisites

- Emacs 29.1 or newer, built with SQLite (`sqlite-available-p` returns
  non-nil). Without it the client still reads the archive, but nothing is
  stored between sessions.
- `etaf`, `etaf-ui`, `ebox`, `ecss` and `etaf-db` on `load-path` for a
  checkout; the archive install brings them in.

```elisp
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ui")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/etaf-db")
(add-to-list 'load-path "/path/to/maillist")
(require 'maillist)
```

## Opening the client

```elisp
M-x maillist-open
```

The client mounts in `maillist-buffer-name` (default `*ETAF Lists*`), hides the
mode line and fills the selected window. Every control is reachable from the
keyboard; the mouse works on the same elements.

`maillist-open` also takes `:list` (an archive name from `maillist-sources`)
and `:sync` — nil opens from the stored rows without contacting the archive,
which embedded hosts and the acceptance scenarios use.

The archive a client last opened is stored under the `last-list` setting, so a
later `M-x maillist-open` returns to it. `L` switches archive from inside the
client and remembers the choice as well.

```elisp
(maillist-open :list "emacs-bugs")   ; a named archive, with a sync
(maillist-open :sync nil)            ; from the stored rows only
M-x maillist-close                   ; close the window and dispose the session
```

Which lists exist is `maillist-sources`: each entry is
`(:name NAME :base URL :address LIST-ADDRESS)`. Add an archive by adding an
entry; the client needs nothing else from it than the public-inbox layout.

## Reading

The list shows one row per discussion with its newest author, message count,
date and subject, grouped by date. An unread row is drawn in the theme's link
colour, a starred row carries `*`, an unread one `+`, and a row whose subject
matched a local search carries the matched text beside it.

`j`/`k` move the selection and open the row; `RET` opens the focused row; a
pointer press opens the row it lands on.  `n` opens the next unread thread
after the selection and `G` the last row of the list. Below `maillist-narrow-width` the
window shows the list alone until a row is opened, and the reader carries a
`← 列表` row to go back (`u`).

The reader keeps its header (subject, message count, participants, last reply)
fixed while the body scrolls in its own box. Within a message:

- quoted lines keep their `>` depth and a quiet band,
- diff hunks are marked as meta, addition or deletion,
- the reply target of a message is named in the warm colour,
- every web address the message mentions is listed below it as a link; `RET`
  on the link, or a click, opens it in the browser.

`e` expands the messages a long thread holds back (`maillist-message-window`,
20 by default) — the thread opens with its newest ones. A thread larger than
`maillist-fast-open-threshold` messages shows its newest message from the
archive's search feed first, then the whole conversation.

`C` puts the archive's own page of the thread on the kill ring and `B` opens
it in the browser, so a discussion can be shared with someone who does not use
this client (`maillist-thread-url` builds that address).

## Marks

A thread is marked read when its body is on screen, not when the row is
selected: a fetch that never answers, or a row passed with `j`, leaves it
unread.

| Key | Action |
| --- | --- |
| `M-u` | mark the open thread unread |
| `A` | mark every row the current scope shows read |

`A` reports how many threads it changed and writes them in one transaction.
Marks live in their own table: a sync rewrites the archive cache and cannot
lose them, and a prune that drops a thread's row keeps its mark, so the thread
comes back with the state it had.

## Scopes

`1`, `2` and `3` switch between all threads, unread only and starred only.
A scope is a local filter over the stored rows; the thread being read stays in
the list so `j` carries on from it.

## Searching

`/` focuses the search field. `RET` runs the query, and an empty query returns
to the archive's own thread list.

The field takes mail-client syntax:

| Form | Effect |
| --- | --- |
| `from:` `to:` `subject:` `body:` `message:` | the matching archive field |
| `after:2026-10-01` `before:2026-10-10` | a date range |
| `is:unread` `is:starred` | local marks |
| `"two words"` | a phrase |

The first three forms compile into the archive's own query
(`maillist-compile-query`) and are answered by a search request; a query naming
only local marks filters the rows already in the list without a request. The
`is:` conditions keep applying to a remote answer.

The results are a view, not the stored list: opening a thread from a search
does not write the search page's date or subject back as the thread's facts.

When the archive cannot answer, the query falls back to the cached bodies
(`maillist-local-search-limit`, 50 rows) and says so in the notice area; the
row then carries the matched text. A search that neither the archive nor the
cache can answer reports the failure and leaves the reader as it was.

`M-p` and `M-n` walk the queries this client ran, newest first
(`maillist-recall-query`); past the oldest query the walk returns to the
archive's list.

## Older mail

The archive's index page names only its newest threads. `o` asks the archive's
own date search for every message before the oldest date the client holds,
groups the answer by subject (the newest message of each discussion stands for
it), skips what the list already has and adds up to `maillist-older-batch`
rows. The notice says how many joined, or that there is nothing older.

Each added row is a message; opening it fetches the thread it belongs to.

## Automatic sync

An open client syncs every `maillist-auto-refresh` seconds (300 by default;
nil syncs only when asked). The scheduled sync is quiet: it stays out of the
notice area, counts the threads the archive added in the summary (`6 个线程 ·
2 未读 · 1 新 · 22:05 同步`) and tints those rows. A failure still reports —
a client that hides its errors cannot be trusted with mail. The timer belongs
to the session and is cancelled by `maillist-close`.

## Sending

| Key | Action |
| --- | --- |
| `r` | reply to the list |
| `R` | reply to the list, copying the last message's author |
| `C-u r` | reply to the last message's author |
| `c` | post a new message |

Replies carry `In-Reply-To` and `References`, so they stay in the thread both in
the archive and in other mail clients. The draft opens in the current window
under `message-mode`; `C-c C-c` sends it, `C-c C-k` discards it.

Sending uses smtpmail:

```elisp
(setq maillist-mail-address "you@gmail.com")
;; M-x maillist-mail-configure, then paste the account's application password
```

The password is looked up in auth-source when the mail goes out, so a reply can
be written before the account is configured; sending then fails with the
lookup error. `maillist-smtp-server`, `maillist-smtp-service` and
`maillist-smtp-stream-type` choose the endpoint (Gmail with SSL on port 465 by
default). A GNU list holds posts from an address that is not subscribed for
moderation; the archive will not show the message until a moderator releases
it.

## Storage

Everything the client keeps lives in `maillist-store-file`
(`~/.emacs.d/maillist/store.sqlite3`):

| Table | Contents |
| --- | --- |
| `threads` | the archive cache: one row per thread and archive |
| `messages` | fetched bodies, keyed by thread |
| `marks` | read and starred state |
| `settings` | the last archive and anything else the client remembers |

The file is switched to WAL at open, and every connection waits up to five
seconds for a writer instead of failing at once, so a second Emacs can prune or
search while the first saves a list.

The cache is bounded and rebuildable:

- `maillist-thread-limit` (2000) — threads kept per archive;
- `maillist-body-limit` (400) — threads that keep a cached body.

Both keep the newest rows. `maillist-store-prune` runs at open and after each
sync, and never touches `marks`. A large prune vacuums the file so its size
follows what it still stores.

A file written by an incompatible earlier version is moved aside to
`store.sqlite3.rebuild-<time>` and rebuilt; the notice names the backup, which
still holds the marks. Delete the file (or the backup) to start from scratch:
the archive cache is fetched again, marks and the remembered archive are not.

## Network

`maillist-network-route` decides the leading route:

| Value | Leading route | Falls back to |
| --- | --- | --- |
| `auto` (default) | direct | the proxy |
| `proxy` | the proxy | direct |
| `direct` | direct | — |

The leading route hands the request to the other one when it cannot connect,
stops answering for `maillist-route-attempt-timeout` seconds (10), or answers
with something the client cannot use. That is why a proxy client that is not
running does not take the archive offline, and a blocked direct path still has
the proxy to use.

The proxy is `maillist-proxy` (`HOST:PORT`); when it is nil the client takes
`url-proxy-services` or the environment's `HTTP(S)_PROXY`. A `file:` archive
never takes a proxy route, and neither does an archive the proxy has no path
to.

A request that reaches nothing names what it tried:

```
同步失败：无法连接代理 127.0.0.1:7890；无法连接档案 yhetil.org:443 · 按 g 重试
```

HTTP answers report their status (`档案返回 HTTP 403`) instead of url.el's
internal error shape.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `maillist-sources` | four `yhetil.org` archives | archives the client can open |
| `maillist-default-list` | `"emacs-devel"` | archive used when nothing was opened yet |
| `maillist-buffer-name` | `"*ETAF Lists*"` | buffer the client mounts in |
| `maillist-store-file` | `~/.emacs.d/maillist/store.sqlite3` | SQLite file |
| `maillist-thread-limit` | 2000 | threads kept per archive |
| `maillist-body-limit` | 400 | threads that keep a cached body |
| `maillist-message-window` | 20 | messages a long thread shows first |
| `maillist-fast-open-threshold` | 40 | messages that make a thread open on the search feed first |
| `maillist-prefetch-threads` | 500 | threads whose sender is fetched after a sync |
| `maillist-prefetch-parallel` | 3 | sender requests kept in flight |
| `maillist-auto-refresh` | 300 | seconds between automatic syncs, nil for on demand |
| `maillist-older-batch` | 50 | rows one `o` adds |
| `maillist-local-search-limit` | 50 | cached rows a fallback search reports |
| `maillist-narrow-width` | 104 | columns below which the layout is one column |
| `maillist-route-attempt-timeout` | 10 | seconds the leading route may stall |
| `maillist-network-route` | `auto` | `auto`, `proxy` or `direct` |
| `maillist-proxy` | nil | `HOST:PORT` of the proxy |
| `maillist-mail-address` | `user-mail-address` | address mail is sent from |
| `maillist-smtp-server` | `smtp.gmail.com` | SMTP host |
| `maillist-smtp-service` | 465 | SMTP port |
| `maillist-smtp-stream-type` | `ssl` | `ssl`, `starttls` or nil |

## When something fails

| Symptom | Cause and what to do |
| --- | --- |
| `同步失败：无法连接代理 …` | the proxy client is not running; the direct route was tried too and also failed. Start the proxy, or set `maillist-network-route` to `direct`. |
| `同步失败：档案返回 HTTP 403` | the archive answered a block page instead of the index — public-inbox installations front themselves with a challenge (Anubis, go-away) that a plain Emacs request cannot pass. Use an archive that answers without it, or open the page in a browser first. |
| `同步失败：档案没有返回线程索引` | the answer held no thread rows. Press `g`: the client fetches once more, then keeps the list and stored rows it has. |
| `搜索失败：…` | neither the archive nor the cached bodies answered. `g` re-runs the query; the rows stay as they were. |
| a thread shows `邮件数据不完整` | the archive no longer serves that thread document; the client shows the newest message it could reach from the search feed. |
| the list is shorter than expected | the archive's index names only recent threads and `maillist-thread-limit` prunes old rows. Press `o` for older mail, or raise the limit. |
| marks are gone after a start | the store was rebuilt from an incompatible file; the notice names the backup, which still holds them. |
| `Sending...failed` with an auth error | no application password in auth-source: run `M-x maillist-mail-configure`. Check `~/.authinfo` for the machine and port in `maillist-smtp-server`/`maillist-smtp-service`. |
| a sent message does not appear | GNU lists moderate posts from unsubscribed addresses; the archive shows it after release. |
| `没有打开的邮件列表` | the client buffer was closed; `M-x maillist-open` opens it again. |

## GUI acceptance

`make gui` drives `scripts/maillist-gui-scenarios.el` on the shared
`emacs-gui-verifier` engine against a loopback copy of the test fixtures. It
needs a running graphical Emacs server; pass `SERVER=<name>` to use a
dedicated instance, and the target prints the evidence directory of the run.

The scenario walks the documented keys — sync, selection, opening a thread,
copying and opening the archive page, starring, the three scopes, `M-u`, `A`,
search, search history, older mail, switching archives — and then the size
matrix (150×40, 120×32, 96×32 narrow, 120×16 short). Every checkpoint asserts
the visible text, the canvas filling its window, the painted width fitting the
window, and the row height staying within the frame's line height, and saves a
frame capture. The functional assertions certify behavior; the captured frames
are what appearance is reviewed against.

## Performance notes

- A sync merges the archive page into the stored rows in one transaction and
  repaints the list; a prune runs after the save, so the visible list does not
  wait for it.
- Opening a thread shows the stored body immediately when one is cached; a
  thread above `maillist-fast-open-threshold` shows its newest message from the
  search feed while the full document arrives.
- Sender names are fetched only for threads that have none, three at a time,
  and are stored, so a second sync of the same page does no requests for them.
- The scheduled sync sends one index request per period; it does not prefetch
  bodies.  Publishing the merged list costs a few milliseconds: a 50 ms timer
  probe in a graphical session (205×51, six threads, one reader open) measured
  a worst-case lateness of 11 ms both while idle and with a sync landing inside
  the window, so the periodic refresh does not interrupt typing.
- The palette is derived once per theme and frame colors, not once per row: a
  row asks for ten colors, and mixing them again for every row of a long list
  cost more than the list itself.  A theme switch, a changed face or another
  frame recomputes it, and the shared components re-read their tokens through a
  computed value, so a switch repaints the whole client.
- `benchmarks/performance-scenarios.el` holds three workloads registered with
  the workspace driver: scrolling a three-hundred-thread list, opening one
  thread after another from it, and searching nine hundred cached bodies.
  Run them against a graphical Emacs, which is where redisplay counts:

  ```sh
  python3 ~/emacs-taf/scripts/performance.py run \
    --scenario 'maillist.*' --mode gui --server maillist-gui \
    --samples 10 --output-dir /tmp/maillist-perf
  ```

  A run on a 300-thread store measured p50 26.4 ms per move, 22.4 ms per thread
  opened and 5.9 ms per cached-body search, each inside its 150-200 ms budget.
  The same store costs about a tenth of a millisecond per row to paint, so
  these numbers grow with `maillist-thread-limit`, not with the window.

## Development

```sh
make check     # structure, byte compilation, acceptance scenarios, public API
make test      # the acceptance scenarios only
make gui       # the GUI scenario on a running Emacs server
make clean
```

The scenarios read `tests/fixtures/archive` over `file:` URLs. A scenario that
needs a network path serves the fixtures from a loopback socket instead
(`maillist-tests--server`), so the suite runs offline and still exercises the
transport, the search page parser and the route fallback.
