# ETAF Weread architecture

## Modules

| File | Responsibility |
| --- | --- |
| `etaf-weread.el` | Package entry: the public API inventory and the feature closure. |
| `lisp/etaf-weread-theme.el` | Palettes, `etaf-weread-color` and the ETAF UI theme tokens. |
| `lisp/etaf-weread-service.el` | Backend client: turns requests into command lines for the bundled Node backend and decodes JSON replies. |
| `lisp/etaf-weread-model.el` | Session state, list/detail/highlight loading, selection, panes, layout fitting and the public actions. |
| `lisp/etaf-weread-index.el` | Local SQLite index: schema, Data Controller and storage primitives through ETAF DB. |
| `lisp/etaf-weread-views.el` | Internal Components that take plain values and callbacks. |
| `lisp/etaf-weread-app.el` | The `etaf-weread-app` Component, the buffer, the keymap and the reader commands. |

Only the framework is used: the application never calls the renderer directly.
A window change adapts the layout through the model, and ETAF refits the canvas
of every mounted runtime once a resize settles; the reader holds no direct Ebox
or ECSS reference.  Lines borrowed by an active minibuffer or completion popup
are not a window change (`etaf-transient-space-borrowed-p'): the reader keeps
the layout it committed until the prompt closes, like the canvas, which Ebox
leaves at its committed viewport.

The layout breakpoints are derived, not chosen: the wide threshold is the
sidebar plus the pane plus the columns a full book row needs, so a frame can
never show three columns the list cannot render in (below it the medium layout
keeps a glyph rail and one pane at a time).  `etaf-weread--list-min-columns`
records how many columns a full row spends outside its title.

No row may be taller than the row height the page budget counted.  A row may be
*shorter* than the budget — a blank or Latin-only row does not reach the height
a CJK row does — so the invariant is "taller than the budget", not equality.
Fallback fonts are common offenders: a symbol can use Sarasa at 18px or Arial
Unicode at 19px, and a bold symbol can make the row taller still.  The reader
uses the shared `etaf-ui-icon' SVG set for its navigation, which is measured
against the line and never grows a row.

An active or selected state is carried by color, surface and weight, never by
a prefix glyph.  A `* `-style marker changes the label's width, so every
switch shifts the whole row or tab strip; the sidebar paints a tinted surface
with an accent edge, and the shared Tabs button uses its selected variant.
Validate with `etaf-weread-gui-check` in `scripts/weread-gui-probe.el`: the
canvas must fit the window, no row may exceed the budgeted row height, and
every line must fit the body width.

## Data flow

```text
backends/weread (JSON over stdout)
  → service: child process, decoded plist, (:ok ...) or (:error ...)
  → model: generation-guarded list/detail/notes loads write reactive refs
  → views: take plain values and callbacks
  → app: reads the refs once per render, calls the View components
  → ETAF runtime → renderer → buffer
```

- A session is the unit of state and has no buffer until mounted. Every mutable
  value is an `etaf-ref`, so a backend reply repaints the mounted reader
  without a refresh call.
- Replies carry a generation: a reply from a superseded list load, book or
  notes request is dropped (or cached without being painted), so switching
  sections while a request is in flight cannot paint stale data.
- Failures never signal through the actions. The service maps backend errors to
  `(:error MESSAGE :hint HINT)`, and the model records them in `:error` and
  `:message`, which the status bar shows while the reader stays usable.
- The detail pane follows the selection after a quiet period
  (`etaf-weread-detail-follow-delay`); each book's detail and highlights are
  cached per id, so revisiting is instant.

## List cache and background refresh

Library lists are cached per session under a key that names the section (a
search keys on its keyword, so another keyword is another list).  Switching a
section paints the cache synchronously and then compares it with a fresh reply
in the background; the reply replaces the cache and repaints only when the rows
or the total differ, so an unchanged sidebar costs one request and no repaint.
The detail and highlight panes use the same idea per book id.

The policy itself lives in ETAF (`etaf-list-cache`), so the reader only maps
its sections to keys and requests: a cached entry carries its timestamp,
`etaf-weread-library-refresh-interval` is passed as the freshness, and the
timer armed on start (`etaf-weread-prefetch-interval`) asks for one candidate
at a time — the stalest list, or a list that was never loaded.  A background
load never sets the loading state, never bumps the list generation a visible
load owns, and is skipped while the reader is loading or has just opened;
`etaf-weread--dispose` disarms the cache.  Failed loads report their backend
error code, so an expired login pauses the warmer until a foreground load
succeeds and other failures back off; a reader that no window shows pauses the
warmer as well.  The cache is a display shortcut only: the backend reply is
still the source of truth, and the backend stays a thin data layer (no caching
there).

## Local index

`etaf-weread-index.el` owns one SQLite table (`highlights`) described by
`etaf-weread-index-database` and served by an `etaf-data-controller` over
`etaf-sqlite-source`. Storing a book's highlights issues one `upsert` per row,
which inserts new rows and updates changed thoughts in place; the notebook walk
never duplicates a row. The model owns the orchestration (which book to fetch
next, how the rows appear in the list) and the index module owns the storage,
so the storage is testable without the network and the backend conversation
stays in one place.

The index is a local copy for offline search. The server remains the authority
for the account, and the bundled backend remains the authority for the login.

## Invariants

- The public API is exactly the root entry Commentary; everything below `lisp/`
  is internal.
- Views take plain values; only the `etaf-weread-app` Component reads reactive
  state, so a repaint has one owner.
- A session's timers, follow timer, SQLite controller and in-flight child
  processes are released on dispose; a reply after dispose is dropped.
- Layout, page size and pane budgets are derived from the window that shows the
  reader; a headless session keeps the `wide` layout.
