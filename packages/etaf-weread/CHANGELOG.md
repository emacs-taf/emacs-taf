# Changelog

All notable user-visible changes to ETAF Weread.

## Unreleased

- The reader and a panel framing it share one appearance state: `T` and the
  panel's title-bar switch write the same mode cell, and the panel paints the
  reader's palette.  `etaf-weread-theme-mode` now seeds the live mode instead
  of replacing it at runtime.

- The panel's title bar offers the standard `亮`/`随`/`暗` switch like every
  other panel.  `随` follows the panel's palette, which tracks the Emacs
  theme; the reader's own `sepia` paper stays on `T` and shows in that switch
  with no segment selected.

- The reader's keys belong to its root Host, so a floating panel or a desktop
  host that mounts `etaf-weread-view` keeps them; both host kinds also record
  the session they mount, and the new `etaf-weread-session` returns it, so a
  command like `T` acts on the mounted reader instead of signalling that the
  buffer is not one.  A mounted reader also knows its buffer again, which
  pauses its background prefetch while no window shows it.

- Local books are removed.  The `本地书` section, the in-frame reading pane and
  every action that existed only for a local file are gone: opening TXT,
  Markdown or EPUB files, reading width and columns (`[`, `]`, `m`), reading
  fonts (`F`), zen (`f`), auto-scroll (`a`), bookmarks (`b`, `B`), percentage
  jumps (`%`), in-book search, dictionary lookup (`y`), the matched-account
  highlight overlay (`N`, `M`), reading time records, stored positions and the
  progress write-back (`w`).  `etaf-weread-library-directory`,
  `etaf-weread-library-depth`, `etaf-weread-library-chapter-length` and the
  other local-library options are removed, as are the backend's `bind` and
  `sync-progress` commands and its `bindings.json` ledger.  The shelf,
  notebook, book detail, highlights, store search, statistics, export, the
  local highlight index and every key that drives them stay.  Remove the old
  options from your configuration; an existing settings file is still read and
  its extra keys are ignored.

- `M-x etaf-weread-login` signs in (or refreshes) the account through the
  bundled backend — its own browser window at the QR page, the local Chrome
  session or `--cookie` — and reloads the account, lists and statistics.  The
  browser login is self-contained now: the backend ships a CDP login client and
  uses Chrome, Edge, Brave or Chromium (`WEREAD_BROWSER` overrides the binary)
  with its own profile, so it no longer needs a Pi skill, `cdp-channel.mjs` or
  `WEREAD_CDP_CHANNEL`.  `M-x
  etaf-weread-logout` deletes the stored login and clears the account data from
  the reader without touching the WeChat Reading account.  A missing or expired
  login now reports `M-x etaf-weread-login` in the status line instead of the
  backend's command line, and the bundled backend gains a `logout` command.

- The reader opens as an ETAF application: its keys are root keys of the
  View, so RET reaches a focused control before it opens the selection, the
  canvas follows the palette, and the layout follows each settled resize
  without a reader-owned resize hook. It requires ETAF 0.3.0 and ETAF UI 0.2.0.

- `etaf-weread-mode-map` is removed. The reader's keys are declared on its root
  View; `C-c h` lists them. Keys the reader does not declare fall through to
  your own bindings, so bind an extra command globally instead.

- Installing from the package archive now compiles every module: the entry
  resolves its `lisp/` directory from the file being compiled, so an
  installation started from a script cannot point the compiler at the script's
  own directory.

- The WeChat Reading account backend now ships inside this package under
  `backends/weread/` and no longer needs a Pi skill, `pi-skill`, or a separate
  clone. Install `node` and sign in once through the bundled script. The
  login, config and export defaults moved to
  `~/.local/share/etaf-weread/` (or `$XDG_DATA_HOME/etaf-weread/`, or
  `$ETAF_WEREAD_HOME`); move an existing `~/.pi/agent/local/skills/weread/`
  there once to keep the login. `etaf-weread-skill-directory`
  became `etaf-weread-backend-directory`, and `etaf-weread-doctor` reports
  Node.js and the bundled script.

- `?` and `C-c h` now open the same searchable, read-only help dialog inside
  the reader. Effective bindings supply its labels; Escape or an outside
  click closes it and restores focus without splitting the window.

- Opening the minibuffer (`M-x`, a completion popup or the reader's own
  prompts) no longer shrinks the book list or the pane budgets to the lines
  the prompt borrows. The reader keeps the layout it committed for the window
  and returns to the full view unchanged once the prompt closes.

- Sidebar lists are shown from the session cache at once and compared with a
  fresh reply in the background: an unchanged list never repaints or resets
  the reader's place, and a mounted reader warms and refreshes one list at a
  time while idle (`etaf-weread-library-refresh-interval`, default 120
  seconds; `etaf-weread-prefetch-lists` and `etaf-weread-prefetch-interval`
  control the timer).

- First complete reader: shelf with all/reading/finished filters, notebook,
  book detail with table of contents, highlights grouped by chapter, store
  search, reading statistics, Markdown export and opening a book in the web
  reader.
- Local SQLite index of highlights through ETAF DB: reading a book stores its
  highlights, `笔记检索` searches the whole notebook offline, and `I` walks the
  notebook in the background (prefix argument re-fetches indexed books).
- Two palettes with one key and `:ui-*` tokens for the shared ETAF UI controls.
- Wide, medium and narrow layouts; the detail pane follows the selection after
  a short quiet period so fast browsing does not query every passed book.
- A reader session is headless: no buffer, no timer, a scripted client is a
  complete backend.

## 0.1.0

- Initial package skeleton: entry, theme, backend client, reader model, views
  and application shell.
