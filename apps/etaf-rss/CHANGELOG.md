# Changelog

All notable user-visible changes to ETAF RSS are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- The reader no longer starts with an empty row above the header, and the
  status bar sits on the window's last row: the shell dropped its top and
  bottom inset rows.

- The article list uses the width it has: the row's columns follow the width
  the flex row gives the list, a source name appears only when the title still
  has room beside it (`>= 52` columns of list), and the relative time shows
  `4 分钟前` instead of `4 分钟`.  At 120 columns a title gets 26 cells
  instead of 8.

- Wrapped article text fits the reading pane: the width budget takes the share
  the frame actually gives the pane (the list and the reader split what the
  sidebar leaves) and subtracts the pane's horizontal padding, so a long
  paragraph no longer loses its last words at the pane edge.

- The wheel now acts on the pane under the pointer: a turn over the article
  scrolls the article, a turn over the list moves the selection, and a turn
  over the subscription list scrolls it.  It used to be resolved from the
  pointer by recomputed column geometry, which both missed the reading pane's
  left columns and always scrolled the article in the compact layouts.

- Scrolling can no longer move the whole page.  The canvas is the window (the
  shell follows the display window's body instead of the renderer's viewport,
  which still counted the mode line the reader hides), the subscription list
  scrolls inside its own region, and Ebox no longer scrolls the window of a
  mounted tree that already fits, so a stray wheel turn over chrome cannot
  slide the sidebar and the list along with the article.

- The subscription list scrolls when it has more sources than the window
  holds; the overflow was clipped and every subscription below the fold was
  unreachable.

### Added

- A Miniflux backend: `etaf-rss-backend` = `miniflux` reads a self-hosted
  server through its REST API with the same sidebar, scopes, folders, reading
  pane and keys. `etaf-rss-miniflux-client` creates such a client, configured
  by `etaf-rss-miniflux-url`, `etaf-rss-miniflux-token` and
  `etaf-rss-miniflux-config-file`, with `MINIFLUX_URL` / `MINIFLUX_TOKEN` as
  environment fallbacks. Reads, stars, marking a scope read, subscribing,
  unsubscribing, filing a feed, and OPML import and export all reach the
  server. This replaces the separate `etaf-miniflux` application.

- A client may also be a function of (REQUEST CALLBACK) or a plist
  `(:call FUNCTION [:cancel FUNCTION])`, so another backend drives the reader
  without the local store.

### Changed

- The reader opens as an ETAF application: its keys are root keys of the
  View, so RET reaches a focused control before it opens the selected
  article, the canvas follows the palette, and the layout follows each
  settled resize without a reader-owned resize hook. It requires ETAF 0.3.0
  and ETAF UI 0.2.0.

- `?` and `C-c h` now open the same searchable, themed modal inside the
  reader. Its concise labels come from the effective bindings, not a static
  message. Escape exits one layer at a time; clicking outside closes help
  and restores the reader focus without splitting the window.

### Removed

- `etaf-rss-mode-map` is removed. The reader's keys are declared on its root
  View; `C-c h` lists them. Keys the reader does not declare fall through to
  your own bindings, so bind an extra command globally instead.

### Fixed

- Opening the minibuffer (`M-x`, a completion popup or the reader's own
  prompts) no longer shrinks the article page or the reading budget to the
  lines the prompt borrows. The reader keeps the layout it committed for the
  window and returns to the full view unchanged once the prompt closes.

## [0.1.0] - 2026-10-03

### Added

- A complete RSS client as one ETAF text application: RSS 2.0, Atom and JSON
  Feed subscriptions (including feed autodiscovery from a site page), one
  local JSON store, all/unread/starred scopes and per-feed or per-folder
  lists.
- A reading pane that renders article HTML as wrapped blocks (headings,
  paragraphs, quotes, lists, code, table rows and collected links) and opens
  the original in the browser.
- Read and starred state with optimistic toggles, mark-all-read and
  mark-above-read, and starred articles that survive unsubscribing.
- Case-insensitive search over titles, summaries and bodies with snippets.
- OPML import and export, with folders.
- Conditional background refresh (ETag / Last-Modified), one request at a
  time, per-feed error reporting, an idle auto-refresh timer and a manual
  every-subscription refresh.
- Three responsive layouts, dark and light palettes published as ETAF UI
  theme tokens, and full keyboard, mouse and wheel navigation.
- Headless sessions with an injectable client, a public API inventory in the
  entry Commentary, and acceptance scenarios that exercise the real service
  layer over `file://` fixtures without a network.
