# maillist

A native mailing-list archive client for Emacs, built with
[ETAF](https://github.com/emacs-taf/etaf). Read, search and reply to
public-inbox archives (`emacs-devel`, `emacs-bugs`, `emacs-user`,
`emacs-tangents`, or any custom public-inbox source) directly in an ordinary
Emacs buffer (`*maillist*`) — with local read/star state, fast persistent NNTP
sync, SQLite caching, unified diff highlighting and automatic GNU Debbugs
reply routing, while preserving your Emacs theme and mode-line.

[Demo Video (1080p, 2 min)](https://www.bilibili.com/video/BV1oCyLzPEu8) ·
[Direct MP4](https://vhkd.top/share/maillist-demo-v0.4.2.mp4) ·
[ETAF Package Page](https://etaf.top/packages/maillist/) ·
[User Manual](docs/manual.md) ·
[Changelog](CHANGELOG.md)

![Live emacs-devel in maillist: date-grouped threads, unread/star marks, nested quotes, rectangular search bar, action toast and native mode-line](https://etaf.top/media/maillist/maillist-wide.webp)

## Why maillist?

- **Zero mail-sync boilerplate** — no `mbsync`, `notmuch`, IMAP folders or
  Gnus scoring rules to maintain; open `M-x maillist-open` and start reading
  live `emacs-devel` / `emacs-bugs` immediately.
- **Fast persistent NNTP + 0 ms SQLite cache** — syncs incrementally via
  non-blocking NNTP (`GROUP` + `XOVER` + pipelined `ARTICLE` bursts, with
  automatic HTTP fallback), reopens unchanged cached threads in 0 ms, warms
  unread bodies quietly on idle, and stays readable offline.
- **Built for mailing-list workflows** — detects new replies on previously read
  discussions, opens massive threads newest-first with incremental expansion
  (`e`), highlights inline patches, folds long quotes (`Q`), copies `t.mbox.gz`
  URLs (`m`), views raw RFC 5322 messages (`v`), and routes `emacs-bugs`
  replies straight to `<bug>@debbugs.gnu.org`.
- **Native Emacs citizen** — lives in a normal buffer (`*maillist*`), derives
  its entire palette dynamically from your active Emacs theme, keeps your
  original mode-line, and collapses cleanly into a single-column pane inside
  `C-x 3` splits.

## Visual tour

### Patch and unified diff review (`emacs-bugs`)

Inline patches and unified diffs (`diff --git`, `@@`, `-`, `+`) render with
semantic red/green highlighting, per-message focus (`[` / `]`), signature
dimming, extracted clickable links, raw RFC 5322 viewing (`v`) and one-key
`t.mbox.gz` copying (`m`):

![Reading a live src/xdisp.c patch on emacs-bugs with unified diff highlighting and focused follow-up reply](https://etaf.top/media/maillist/maillist-diff.webp)

### Automatic Debbugs routing and RFC 5322 threading

Pressing `r` (reply to list), `R` (reply all) or `C-u r` (reply privately)
targets the focused message in `message-mode`, preserves canonical
`In-Reply-To` and ancestor-chain `References`, and inside `emacs-bugs`
automatically addresses `<bug>@debbugs.gnu.org` instead of filing a new bug:

![Replying to bug#82298 in message-mode with automatic 82298@debbugs.gnu.org routing and full References chain](https://etaf.top/media/maillist/maillist-debbugs-reply.webp)

### Side-by-side split workflow (`C-x 3`)

Below `maillist-narrow-width` (for example in a `C-x 3` split beside code),
`*maillist*` automatically collapses into a single-column list/reader view with
a `← 列表` (`u`) back bar and full-width search box, and refits smoothly back
to two columns on `C-x 1`:

![Coding alongside maillist in a C-x 3 split with automatic single-column narrow reader layout](https://etaf.top/media/maillist/maillist-split-narrow.webp)

### Live Emacs theme adaptation

All surfaces, borders, quote bars, diff tints and selection states are derived
from the active Emacs theme — switching between dark and light themes (such as
`modus-operandi`) repaints the entire interface immediately:

![Live emacs-devel rendered in the modus-operandi light theme](https://etaf.top/media/maillist/maillist-light.webp)

### Searchable in-buffer keyboard help (`?`)

Press `?` anywhere inside `*maillist*` to open the centered, read-only
two-column keyboard reference (with `/` live filtering across commands and
notes) alongside `M-g` region jumps (`f` search, `t` list, `v` reader):

![Centered two-column keyboard help dialog opened with ?](https://etaf.top/media/maillist/maillist-help.webp)

## Capabilities

- **Thread list & local state**: date grouping (`今天` / `昨天` / `本周` /
  `更早`), simultaneous starred (`*`) and unread (`+`) indicators,
  all / unread / starred scopes (`1` / `2` / `3`) with dedicated empty states,
  bottom-right action notices, `M-u` mark-unread, `A` mark-scope-read, and
  automatic `新回复` detection when a read thread receives new mail.
- **Conversation reader**: fixed thread header over a scrollable conversation,
  incremental expansion (`e`) for long threads, per-message focus (`[` / `]`),
  collapse-all (`z`), long-quote folding (`Q`), nested quote bars, unified diff
  highlighting, signature dimming, raw RFC 5322 viewer (`v`), mbox URL copy
  (`m`), `<Message-ID>` copy (`w`) and extracted clickable links.
- **Structured search**: mail-client query syntax (`from:`, `to:`, `subject:`,
  `body:`, `message:`, negated `-field:`, `after:`, `before:`, `is:unread`,
  `is:read`, `is:starred`, `-is:...`). Local mark queries filter live with zero
  network calls; remote queries run on `RET` and fall back to structured local
  search over cached threads and bodies when offline.
- **Multiple archives & custom sources**: ships with `emacs-devel`,
  `emacs-user`, `emacs-bugs` and `emacs-tangents`, remembers the last opened
  list, and lets you add any public-inbox archive via `L` or
  `M-x maillist-add-source` with per-list SQLite isolation.
- **Scheduled quiet sync & native paging**: background refresh
  (`maillist-auto-refresh`, 300 s) surfaces new-thread and new-reply counts
  without disturbing active searches; `o` pages older mail via NNTP `XOVER` or
  native `?t=...` archive cursors.

## Requirements

- Emacs 29.1 or newer, built with SQLite support.
- Providers (installed automatically via `etaf-install`): `etaf` (>= 0.3.6),
  `etaf-ui` (>= 0.3.4), `etaf-db` (>= 0.1.0), `ebox`, `ecss`.

## Install

<!-- BEGIN:GENERATED:pkg-install-en:maillist -->
### From the ETAF package archive (recommended)

```elisp
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(etaf-install-ensure '(maillist))
```

Or run `M-x etaf-install` and select `maillist` interactively.

### From a source checkout

All core framework packages live in [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf):

```sh
git clone https://github.com/emacs-taf/etaf.git
git clone https://github.com/emacs-taf/maillist.git
```

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui" "etaf-db"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/maillist")
(require 'maillist)
```
<!-- END:GENERATED:pkg-install-en:maillist -->

Start the client with `M-x maillist-open` (or manage upgrades later with `M-x etaf-install-manage`).

## Keys

### List and marks

| Key | Action |
| --- | --- |
| `j` / `k` | next / previous thread |
| `RET` or click | open the selected thread |
| `n` / `p` | next / previous unread thread |
| `<` / `G` | jump to the first / last thread |
| `1` / `2` / `3` | switch scope: all / unread / starred |
| `s` | star or unstar the selected thread |
| `M-u` | mark the selected thread unread |
| `A` | mark all shown rows read |

### Conversation reader

| Key | Action |
| --- | --- |
| `]` / `[` | focus next / previous message in the open thread |
| `SPC` / `DEL` / `S-SPC` | page down / up inside the reader (or list) |
| `e` | expand older messages held back in a long thread |
| `z` | collapse or expand all messages in the open thread |
| `Q` | fold or unfold long quoted blocks (3+ lines) |
| `v` | view raw RFC 5322 email and full headers of the focused message |
| `m` / `w` | copy thread `t.mbox.gz` URL / copy focused `<Message-ID>` |
| `C` / `B` | copy / open the thread's archive web page |

### Search, paging and archives

| Key | Action |
| --- | --- |
| `/` | focus search box (`RET` runs remote search; empty restores list) |
| `M-p` / `M-n` | recall previous / next search query |
| `o` | load mail older than the current list |
| `g` | sync again (re-runs the active query when searching) |
| `L` or click list name | switch archive or add a custom public-inbox source |

### Replying, posting and layout

| Key | Action |
| --- | --- |
| `r` / `R` / `C-u r` | reply to list (or Debbugs bug) / reply-all / reply to author |
| `c` | compose a new post to the current list |
| `u` | return from reader to list (narrow layout) |
| `M-g` / `Tab` / `?` | jump region (`f` search, `t` list, `v` reader) / next control / help |
| drag divider | resize list pane (saved automatically; arrows move when focused) |

## Search syntax

| Form | Effect |
| --- | --- |
| `from:` `to:` `subject:` `body:` `message:` | match archive field (prefix `-` to exclude) |
| `after:2026-10-01` `before:2026-10-10` | date range |
| `is:unread` `is:read` `is:starred` | local mark filters (`-is:...` negates), instant with no request |
| `"two words"` | exact phrase |

Local-only mark queries filter the archive list in place; remote queries run on
`RET` and fall back to structured local search across cached subjects, authors
and bodies when offline. Clearing the search restores the full cached archive
list immediately.

## Sending

Sending defaults to `smtpmail`. Store the account's application password in
`auth-source` once:

```elisp
(setq maillist-mail-address "you@gmail.com")
;; then M-x maillist-mail-configure and paste the application password
```

Defaults target `smtp.gmail.com:465` over SSL; adjust `maillist-smtp-server`,
`maillist-smtp-service` and `maillist-smtp-stream-type` for another provider,
or set `maillist-send-mail-function` to `'inherit` to reuse Emacs's existing
`message-send-mail-function` (such as `msmtp`, `sendmail` or `gmi`). Replying
inside `emacs-bugs` automatically targets `<bug>@debbugs.gnu.org`.

## Data and network

- **SQLite storage**: threads, marks, cached bodies and settings live in
  `~/.emacs.d/maillist/store.sqlite3` (`maillist-store-file`) in WAL mode,
  keyed per archive (`(list_name, id)` and `(thread, id)`) so cross-posted
  discussions never collide.
- **Bounded retention**: `maillist-thread-limit` (2000) and
  `maillist-body-limit` (400) prune per list with non-blocking incremental
  vacuum while never dropping starred threads or read marks.
- **Transport & routing**: `maillist-transport` (`auto`, `nntp`, `http`) uses
  persistent NNTP on the four built-in `yhetil.org` archives with automatic
  HTTP fallback; `maillist-network-route` (`auto`, `proxy`, `direct`) caches
  the working route and falls back after `maillist-route-attempt-timeout`
  (10 s). `maillist-proxy` configures an HTTP(S) proxy (`HOST:PORT`), falling
  back to `url-proxy-services` or `HTTP(S)_PROXY`.
- **Background prefetch & sync**: `maillist-prefetch-bodies` (10) warms top
  uncached unread threads on idle; `maillist-auto-refresh` (300 s) syncs an
  open client quietly.

See [docs/manual.md](docs/manual.md) for full workflows, configuration
variables, storage schema details and troubleshooting.

## Development

```sh
make check     # structure, byte compilation, acceptance scenarios, public API
make test      # acceptance scenarios only
make gui       # drive the maintained GUI scenario on a running Emacs server
make clean
```

Acceptance scenarios run offline against `tests/fixtures/archive` over `file:`
URLs and loopback sockets. `make gui` accepts `SERVER=<name>` for a dedicated
Emacs instance and records frames and assertions to a fresh evidence directory.
