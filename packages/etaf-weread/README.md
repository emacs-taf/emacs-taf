# ETAF Weread

ETAF Weread is a WeChat Reading (微信读书) client for Emacs. It renders the
signed-in account's shelf, notebook and reading statistics as one ETAF view: a
section sidebar, a paginated book list, a side pane with the book card, table
of contents and highlights, and a local SQLite index of every highlight through
ETAF DB.

The reader at a wide frame:

![The reader at a wide frame](examples/etaf-weread-wide.png)

At a medium frame the sidebar becomes an icon rail and the side pane turns
into tabs:

![The reader at a medium frame](examples/etaf-weread-medium.png)

At a narrow frame the sections become a chip strip and the panes stack under
tabs:

![The reader at a narrow frame](examples/etaf-weread-narrow.png)

## Capabilities

- Shelf: every book with progress, reading time and finished state, filtered by
  all, reading and finished.
- Notebook: the books that have highlights or thoughts, with per-book counts.
- Book detail: cover initial, author, category, rating, word count, progress
  meter, reading time, note counts, introduction-free card and the full table
  of contents.
- Highlights: quotes grouped by chapter with the attached thought below each
  quote, orphan thoughts collected separately.
- Store search: find books in the WeChat Reading store and open their detail.
- Reading statistics: finished and reading counts, total reading time, notes
  and the most-read books.
- Local highlight index: reading a book's highlights stores them in a SQLite
  database, and the index section searches the whole notebook offline; `I`
  walks and indexes the notebook in the background.
- Export: the selected book's highlights and thoughts are written as Markdown
  by the bundled `weread` backend.
- Open in the browser: the selected book opens in the WeChat Reading web reader.
- Three palettes (dark, light and sepia) on one key, published as `:ui-*`
  theme tokens so shared ETAF UI controls follow the same colours; inside a
  floating panel the title bar offers the standard 亮/随/暗 switch, and `随`
  follows the panel's palette.
- Window layouts: three columns on a wide frame, a glyph-only section rail with
  one pane on a medium one, and a phone-like stacked layout on a narrow one.
- Headless sessions for scripts and tests: no buffer, no timer and a scripted
  client are all supported.

## Prerequisites

| Requirement | Why | Check |
| --- | --- | --- |
| Emacs 29.1 or newer | the ETAF runtime and the built-in SQLite support | `emacs --version` |
| Node.js 22 or newer | runs the backend client | `node --version` |
| `etaf`, `etaf-ui`, `etaf-db`, `ebox`, `ecss` | the framework; each root entry must be on `load-path` | every checkout is readable |
| Bundled `weread` backend | shelf, notes, login | ships inside the package; only Node.js is required |
| Chrome, Edge, Brave or Chromium | opens the QR login page and reads its cookies; every read-only command works without it | `WEREAD_BROWSER=/path/to/browser` overrides the binary |

The reader displays what the backend provides: the bundled `weread` backend owns
the account, the cookie and the highlight index, and the app keeps a local SQLite
mirror of every highlight it reads.

## Installation

### 1. System tools

```sh
brew install node                 # Node.js 22 or newer
```

Emacs 29.1 or newer is required; its built-in SQLite support stores the local
highlight index (no external database is needed).

### 2. The bundled backend and its one-time login

The account, cookie and highlight backend ships inside this package under
`backends/weread/`; nothing else has to be installed or cloned.  Sign in once,
from Emacs:

```elisp
(require 'etaf-weread)
M-x etaf-weread-login
```

The command reuses its own signed-in browser, otherwise reads your local Chrome
session, and otherwise opens a browser window at the WeChat Reading login page
and waits for the QR scan.  WeChat Reading only offers QR login, so this step
needs you once; `etaf-weread-login-timeout` (default 300 seconds) is how long it
waits.  The browser is a separate profile that ships with the package — any of
Chrome, Edge, Brave or Chromium works, and `WEREAD_BROWSER` points at another
binary — so no Pi skill or external tool is involved.  The cookie is stored in
the backend's data directory, and later reads go straight over HTTP.

`M-x etaf-weread-logout` deletes that stored login and clears the account data
from the open reader; the WeChat Reading account itself is unchanged.  The
backend script remains available for a manual cookie without Emacs:

```sh
BACKEND="$(dirname "$(locate-library etaf-weread)")/backends/weread"
node "$BACKEND/weread.mjs" status                                 # reports a missing login
node "$BACKEND/weread.mjs" login --from-chrome                    # macOS: reads the Chrome session
# or paste the two cookie values from a signed-in browser:
node "$BACKEND/weread.mjs" login --cookie "wr_vid=…; wr_skey=…"
node "$BACKEND/weread.mjs" logout                                 # forget the stored login
```

`M-x etaf-weread-open` reports a missing or expired login in its status line and
names `M-x etaf-weread-login`; `g` retries once you have signed in.

### 3. The Emacs package

```elisp
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ui")
(add-to-list 'load-path "/path/to/etaf-db")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/etaf-weread")
(require 'etaf-weread)

(global-set-key (kbd "C-c r") #'etaf-weread-open)
```

`M-x etaf-weread-open` mounts the reader in the selected window; `M-x
etaf-weread-close` closes it.  `etaf-weread-index-file` selects the local
SQLite file and `etaf-weread-theme-mode` the palette.

### Quick start for an agent

A non-interactive path to a working reader (the QR scan needs the user once):

```sh
command -v node || brew install node
BACKEND="$(dirname "$(locate-library etaf-weread)")/backends/weread"
test -f "$BACKEND/weread.mjs" || {
  echo "weread backend not found: reinstall etaf-weread" >&2; exit 1; }
node "$BACKEND/weread.mjs" status || node "$BACKEND/weread.mjs" login --from-chrome
```

```elisp
;; After adding the repositories to `load-path':
(require 'etaf-weread)
(etaf-weread-open)               ; real backend; returns the reader buffer
```

A missing client or an expired cookie leaves the reader mounted with the
backend error in its message line; sign in again through the bundled backend
(see "The bundled backend and its one-time login") and press `g` to retry.

## Minimal example

```elisp
(require 'etaf-weread)

(let* ((reader (etaf-weread-create))        ; headless session
       (client (etaf-weread-make-client)))
  (plist-put reader :client client)
  (etaf-weread-refresh reader)              ; shelf, account and stats
  (while (plist-get (etaf-weread-state reader) :loading)
    (sit-for 0.05))
  (etaf-weread-move-selection reader 3)
  (etaf-weread-activate-selection reader)   ; the fourth book's detail
  (plist-get (etaf-weread-state reader) :detail))
```

## Runnable demo

`M-x etaf-weread-demo-open` mounts the complete reader on a scripted account,
so it needs no network, login or external backend.
`M-x etaf-weread-demo-live` opens the same reader against the installed
backend. From a checkout with sibling providers:

```sh
cd etaf-weread
emacs -Q -L ../ecss -L ../ebox -L ../etaf -L ../etaf-ui \
  -L ../etaf-db -L . -l examples/etaf-weread-demo.el -f etaf-weread-demo-open
```

## Documentation

- [The manual](docs/manual.md): keys, sections, the local index, theming,
  scripting, custom backends and troubleshooting.
- [Architecture](docs/architecture.md): module responsibilities, data flow and
  invariants.
- [The root entry Commentary](etaf-weread.el): the authoritative list of
  supported functions, variables, the app Component and the error type.

## Checks

`make check` runs the structure checker, byte compilation with warnings as
errors, the acceptance suite and the API boundary checker. The acceptance
scenarios drive a scripted backend and a temporary SQLite database, so they
need no network, login or frame:

```sh
make compile   # byte compilation, warnings are errors
make test      # the public acceptance scenarios
make check     # structure + compile + acceptance + API boundary
```
