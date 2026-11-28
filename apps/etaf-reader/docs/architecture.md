# ETAF Reader architecture

## Responsibilities

`etaf-reader` is an application: it owns the library, the reading session and
the annotations, and it renders through ETAF and Ebox. Parsing is delegated to
the `ebook-parse` skill behind a two-function contract, and storage is
delegated to ETAF DB; neither is re-implemented here.

| Module | Owns |
| --- | --- |
| `etaf-reader-theme` | palettes and the ETAF UI token projection |
| `etaf-reader-store` | the SQLite schema, Data Controllers and row operations |
| `etaf-reader-library` | parser discovery/call, scan, import, cover and image cache |
| `etaf-reader-model` | session refs, wrapping, pagination, selection, annotations, search, progress |
| `etaf-reader-navigation` | library queries/pages, persisted preferences, navigation panes and bounded jump history |
| `etaf-reader-views` | pure renderers read from the session refs |
| `etaf-reader-app` | application lifecycle (`etaf-app-open`), root keys, window fit, commands |

The root entry re-exports the supported subset; everything unlisted is
internal.

## Data flow

1. `etaf-reader-refresh-library` asks the parser to scan the configured
   directories and upserts one `books` row per file, keeping annotations and
   reading state of unchanged files.
2. Opening a book imports it when its chapter rows are missing: the parser
   writes a manifest and one JSON file per chapter into a per-book cache
   directory (images included), and the store receives one `chapters` row
   (metadata) and one `contents` row (text + blocks JSON) per chapter,
   written as one batched transaction per table.
3. The model loads one chapter at a time, wraps its block text into lines for
   the current column count, and publishes refs: chapter, lines, annotations,
   selection, position. Views read those refs during render, so a command
   repaints without a remount.
4. Page turns update the plain position and publish each column's styled text
   through ETAF's retained content API. Selection and structural changes publish
   reactive Views. Position and reading time are saved on a trailing timer and
   on close; the timer retains the originating store path.

## Invariants

- **One projection.** `chapter.text` is `"\n".join(block.text)`; block and run
  offsets inside a chapter are code point offsets into that projection.
  Annotations store `(chapter, start, end)` in the same space, which is why
  they survive re-wrapping, font changes and resizes.
- **Borrowed lines are not a resize.** An active minibuffer or a wrapped
  echo-area message borrows window lines; `etaf-transient-space-borrowed-p'
  keeps the committed metrics instead of repaginating for the borrowed
  height.
- **One writer per fact.** Reading position lives in `states`, annotations in
  `annotations`, book metadata in `books`, and reading settings in
  `preferences`. The constructor restores settings before mounting; Views
  never query storage. A book switch saves the old book before replacing its
  identity and chapter together.
- **Rendering is a function of refs.** Views never call the store; the model
  refreshes cached annotation and state lists when a write happens.
- **Import is replace-on-success.** An extraction writes to `cache/<id>.new`
  and only replaces the previous directory after the manifest was read, so a
  failed import never leaves a half-updated book.

## Performance

The reading path does no I/O: the current chapter's text, lines, annotations
and states are in memory. Wrapping is cached per (chapter, column count) and
only re-run when the column count changes or a chapter is opened. The shelf
reads cached states from one hash table instead of one query per row. The
windowed render keeps the node count constant regardless of chapter size.

Each reading column owns one retained Text Host. Caller-owned string faces
carry headings, inline emphasis, highlights and underlines; source-coordinate
properties preserve selection across two physical columns. A turn replaces the
column strings and one position label in a single
`etaf-runtime-update-host-contents` publication. Empty rows contain a space,
keeping final-page columns addressable and removing the previous page's text.
There is no fixed limit on the number of styled segments in a line.

The reading surface owns one drag handler, not one keymap per line. When the
selection toolbar opens, the ordinary View temporarily exposes individual line
anchors for the shared Popover. Closing it restores the compact column tree.
Open dialogs and toolbars use ordinary publication; unexpected retained errors
are reported, not silently hidden by a full repaint. A rejected turn restores
the authoritative position.

The `:line` position is plain session state; `:revision` explicitly requests an
ordinary repaint. Views no longer write a speculative published-page marker.
Navigation lists are paged from cached data. The fixed-height canvas owns the
reading surface and dialog layers, so opening a dialog does not remove the
reader's viewport constraint. Catalog Buttons, Lists, Selects, Menus, Avatars,
Progress and Dialogs own their native interaction behavior.

The maintained `reader.page.styled` workload in
`benchmarks/performance-scenarios.el` drives actual page keys and checks visible
text. Run it through the workspace performance driver; batch results do not
certify graphical interaction latency.

## Dependencies

`etaf-reader` requires `etaf`, `etaf-ui`, `etaf-db`, `ebox` and `ecss` at
runtime, and the `ebook-parse` skill (with poppler for PDF) for imports.
Applications embed the reader through `etaf-reader-view-for-session`; the
Component provides its palette to the subtree, so shared ETAF UI controls
follow the reading theme.
