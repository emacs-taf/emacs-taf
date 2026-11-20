# ETAF Weread manual

`M-x etaf-weread-open` replaces the selected window with the reader.  It does
not split the frame or defer to `display-buffer` rules; use `etaf-weread-view`
to embed the reader in another layout.

## Signing in

`M-x etaf-weread-login` signs in through the bundled backend: it reuses its own
signed-in browser, otherwise reads the local Chrome session, and otherwise
opens a browser window at the WeChat Reading login page and waits up to
`etaf-weread-login-timeout` seconds for the QR scan.  The browser uses a
separate profile owned by the backend (Chrome, Edge, Brave or Chromium; set
`WEREAD_BROWSER` for another binary), so the step needs no Pi skill or other
external tool.  The reader shows the
progress and the reply in its status line and reloads the account, the lists
and the statistics when the login succeeds; with no reader open the reply is
reported in the echo area.

`M-x etaf-weread-logout` deletes the login saved by the backend and clears the
account, the loaded lists and the open book from the reader; the WeChat Reading
account itself is unchanged, and the status line then names
`etaf-weread-login` again.

While the account is not signed in, the status line reports the backend's
sentence and names `M-x etaf-weread-login`; `g` retries the current section once
the login is done.

## Keys

| Key | Command |
| --- | --- |
| `↑` / `↓`, `C-n` / `C-p` | move the book selection |
| wheel | select a book, or scroll the detail/highlight pane over it |
| `<home>` / `<end>`, `G` | first / last book of the list |
| `<next>` / `<prior>` | one page down / up the book list |
| `RET`, double click | open the selected book (detail, or highlights in the notebook) |
| `v` | switch the side pane between detail and highlights |
| `C-v` / `M-v`, `SPC` / `S-SPC` | scroll the detail or highlight pane one page |
| `d` / `P` | show the detail pane / the highlights of the selected book |
| `o` | open the selected book in the WeChat Reading web reader |
| `E` | export the selected book's highlights and thoughts as Markdown |
| `s` `n` `i` `t` | shelf, notebook, local notes index, statistics |
| `1`–`7` | the sidebar sections in order |
| `/` or `S` | search the WeChat Reading store |
| `I` | index the notebook's highlights into the local database |
| `g` | reload the current list, account and statistics |
| `T` | switch to the next palette (dark, light, sepia) |
| `?` or `C-c h` | searchable, read-only keyboard help in the reader |
| `q` | close the reader |

Help stays in the current buffer without splitting the Emacs window. It lists
actual effective bindings with short labels, including local keymap overrides.
Use `/` to search; Escape leaves search editing first, then closes help and
restores the reader's focus. Clicking the backdrop also closes it. Wide windows
use two columns; compact windows use one scrolling column.

In the local index section the search field filters the indexed highlights
instead of the store, and `RET` opens the book of the selected highlight.

The chosen palette is stored in `etaf-weread-settings-file` (default
`<user-emacs-directory>/etaf-weread/settings.eld`), so the next session starts
with it; a corrupt or unreadable file falls back to the defaults.

## Sections

- **书架 / 全部书架** every book on the shelf with its progress and reading time.
- **在读 / 读完** the same list filtered by state.
- **笔记本** the books that have highlights or thoughts.
- **笔记检索** the local highlight index (see below).
- **搜索书城** store search results; the field accepts a book or author name.
- **阅读统计** finished/reading counts, total reading time, note count and the
  most-read books.

The detail pane follows the selection after `etaf-weread-detail-follow-delay`
seconds of quiet, so moving through the list quickly never asks the backend
about a book that was only passed over. Pressing `RET` loads it immediately.

## List cache and background refresh

Every sidebar list is cached under its own key (a search keys on its keyword).
Opening a section shows the cached rows at once and compares them with a fresh
reply in the background, so a section switch never waits for the network; a
reply that differs repaints the list, and one that did not change leaves the
reader exactly where it is (no loading flash, no reset selection).

While the reader is idle, one list at a time is warmed or refreshed in the
background, so opening a section the account has not visited yet is usually
instant.  The warmer pauses while the reader's buffer is not on screen, backs
off after a failure and stops altogether when the account needs a human (an
expired login), resuming after the next successful load. `etaf-weread-library-refresh-interval` (default 120 seconds) is how
old a cache may be before the timer refreshes it — lower it for a more current
sidebar, raise it for fewer requests; set `etaf-weread-prefetch-lists` to nil
to keep the cache to the sections you actually open, or change
`etaf-weread-prefetch-interval` (default 15 seconds) to control how often the
timer looks for work. `g` refreshes the current section in the foreground.

## Local highlight index

WeChat Reading serves one book's highlights per request. The reader keeps its
own copy of everything it has seen in a SQLite database
(`etaf-weread-index-file`, default `~/.emacs.d/etaf-weread/notes.sqlite3`)
through ETAF DB:

- Reading a book's highlights stores them (`etaf-weread-index-on-read`, default
  on); a changed thought updates its stored row instead of adding another.
- `笔记检索` (or `etaf-weread-index-search`) filters the whole index by keyword
  across the quote, the thought, the chapter and the book title.
- `I` (`etaf-weread-index-notebook`) lists the notebook once and fetches the
  books that are not indexed yet, one at a time, reporting progress in the
  status line. `C-u I` re-fetches every notebook book, which is the way to
  refresh an index that was built from older data.

The index is a local copy, not the source of truth: the server still owns the
account and the bundled backend owns the login.

## Theming

`etaf-weread-theme-mode` seeds the mode a new Emacs session starts with; the
live mode is one reactive cell that selects the `dark`, `light` or `sepia`
palette, and `auto` follows the appearance its host provides.  `T` writes that
cell, and so does the title-bar switch of a panel framing the reader: the
reader declares the cell, its palette and the standard `亮`, `随` and `暗`
labels to its host with `etaf-surface-declare`, so a panel paints the reader's
palette, offers the same three-mode switch as every other panel, and switching
on either side repaints both.  `auto` follows the panel's palette, which
tracks the Emacs theme; `T` cycles `dark`, `light` and the reader's own
`sepia` paper, which has no segment in the three-mode switch and shows there
with none selected.  Views use `etaf-weread-color` and the
ETAF UI controls in the subtree follow `etaf-weread-theme-defaults`, so every
palette shares one layout and the reader renders the same surface in every
Emacs theme.  `etaf-weread-cycle-theme` performs the switch for a scripted or
headless session.

## Scripting and custom backends

A session is headless:

```elisp
(let ((reader (etaf-weread-create :client #'my-client)))
  (etaf-weread-refresh reader)
  ...)
```

A client is a function of `(REQUEST CALLBACK)`; it answers through
`etaf-weread-client-call`'s protocol (`(:ok DATA)` or
`(:error MESSAGE :hint HINT)`) and may answer synchronously. Requests use
`:op` `:status`, `:login`, `:logout`, `:shelf`, `:notebook`, `:book`, `:notes`,
`:search`, `:stats` or `:export`; `docs/architecture.md` describes the data shapes. Bind
`etaf-weread-client-factory` to change the backend of every new session, or
pass `:client` to `etaf-weread-create`. `examples/etaf-weread-demo.el` is a
complete scripted account in one function.

`etaf-weread-state` returns a detached snapshot for assertions or for rendering
outside ETAF.

## Troubleshooting

- **登录态失效**: the status line names `M-x etaf-weread-login`, which signs
  in again through the bundled backend (its own browser window at the QR page,
  the local Chrome session, or a session started with `--cookie`) and then
  reloads the account and the lists.  Press
  `g` to retry the current section instead.  `M-x etaf-weread-logout` deletes
  the stored login and clears the account data from the reader.
- **Empty shelf or notebook**: run the backend `status` (same section); a
  failing backend reply is reported in the status line, and the reader stays
  usable.
- **The local index is not written**: Emacs must be built with SQLite support
  (`sqlite-available-p`); otherwise the index section reports the storage
  failure while the online reader keeps working.
- **A book's detail does not appear**: the detail pane waits for quiet before
  following the selection; press `RET` or `d` to load it immediately.
