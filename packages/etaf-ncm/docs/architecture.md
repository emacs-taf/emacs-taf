# ETAF NCM architecture

ETAF NCM is one ETAF application built on the Ebox layout engine and the shared
ETAF UI controls. It is an interface over the `netease-music` backend, not a
player: mpv owns playback, the backend owns queue and login state, the package
owns presentation and interaction.

## Modules

| File | Responsibility |
| --- | --- |
| `etaf-ncm-theme.el` | Palettes, `etaf-ncm-color`, `etaf-ncm-theme-defaults` and the mode selection. No ETAF dependency beyond the token plist it produces. |
| `etaf-ncm-layout.el` | The responsive decision table: breakpoints derived from the header/row/chip parts they must fit, the vertical budget, the row variants and the two-size type scale. |
| `etaf-ncm-service.el` | The backend client: request translation to backend commands, child processes, timeouts, cookie injection, reply decoding, queue state reading, LRC parsing. |
| `etaf-ncm-cache.el` | The SQLite media cache built on ETAF DB: lyric text and cover file index keyed by song id, opened beside the library snapshot and failing open. |
| `etaf-ncm-model.el` | One session: reactive sources, library loading, search, every playback and queue action, selection and paging, status polling, dispose. |
| `etaf-ncm-views.el` | Pure presentational Components: sidebar, header, list, lyrics, queue, aside, player bar. They receive values and callbacks only. |
| `etaf-ncm-app.el` | The `etaf-ncm-app` Component (session lifecycle, theme provision, the only place that reads reactive sources), its keymap, its commands and the buffer entry points. |
| `etaf-ncm.el` | The package entry: public API Commentary, `load-path` bootstrap for `lisp/`, requires and `provide`. |

Dependency direction is one way: `theme` ← `layout` ← `model` ← `views` ←
`app`, with `model` also using `cache` (which depends only on ETAF DB). A
lower layer never calls into a higher one, and only `app` knows about buffers,
windows and keymaps.

## Data flow

```
key or mouse ─▶ app command ─▶ model action ─▶ client request ─▶ backend process
                                                     │
      view tree ◀─ app Component ◀─ reactive sources ◀┘ reply callback
```

1. A command reads the buffer's session (`etaf-ncm--model`), calls a public
   model action and returns. Nothing blocks.
2. The action writes the intent (selection, message, loading) into reactive
   sources and sends a request through the client.
3. The reply callback compares normalized data before publishing. Per-key
   request tokens share pending loads; a late reply warms its own cache but
   cannot overwrite a different visible library. Disposed tokens are ignored.
4. `etaf-ncm-app` subscribes to the sources it displays. A write repaints only
   the subscribed subtree, so a status tick never re-renders the sidebar.

The model never touches a buffer, and the views never touch a source. That is
what makes a headless session (`etaf-ncm-create` + actions + `etaf-ncm-state`)
behave exactly like the mounted player, and what the acceptance scenarios rely
on.

## State ownership

- Session (model): current library, loaded rows, backend total, selection, page,
  queue window and panel row budgets, message, error, the local download
  registry (the backend reports it) and the per-row download marker,
  pending request tokens, poll timer, `:theme`, `:aside`, `:layout` and `:pane`.
- Backend state directory: login cookie, queue file, saved queues and the
  download registry. The player reads the queue tracks from that file and takes
  the current index from the backend command, so a stale file cannot invent a
  playing position; the registry is read through the `downloads` command, not
  from disk, and a registered song is played from its local path by the
  backend's queue builder.
- mpv: playback itself. The player never assumes a command succeeded; after a
  playback command it re-reads status and queue.

## Window layouts

Ebox has no media or container queries, so the responsive behaviour lives in the
model and is expressed by the view:

- The decision table lives in `etaf-ncm-layout.el`. Its breakpoints are
  derived, not chosen: the header and a full row declare the columns their
  labels and actions need, the list pane's minimum is the larger of those, and
  `etaf-ncm-wide-columns` is that minimum plus the sidebar and side panel.
  `etaf-ncm-medium-columns` is the rail plus a comfortable regular row. Change
  a label or an action and the breakpoints follow; a narrower frame switches to
  the rail, then to the chip strip.
- The vertical budget is shared the same way. Every tier spends a fixed number
  of rows on the header, the chip strip, the pane switch and the player bar;
  `etaf-ncm-layout-page-rows` returns what is left for the library, so reserved
  and painted rows cannot disagree. The queue and lyric budgets come from the
  same table.
- The row plan picks a variant by fit: `full` on a wide frame, `regular` with
  the artist column, `compact` folding the artist into the name cell, `tiny`
  dropping the badge. The name column never leaves, and its minimum plus a
  variant's fixed columns decide whether that variant is used.
- The chip strip keeps every library: it drops the inter-chip gap and then
  narrows each chip to the icon's inset before a library could fall off.
- A frame too small for that chrome uses the card family. The rule is derived
  too: a stacked layout needs 46 columns for the compact player bar's
  transport and tool groups, and a page worth browsing (ten rows) on top of
  its header, chip strip, switch and bar. Below either, `card` keeps the cover
  band, one content pane, the pane switch and the transport, and `tile` drops
  the cover and the progress line as well. A wide frame is exempt: its columns
  are the content, so it stays in the desktop layout when it is short.
- The card's content area is one row budget shared by three panes: the library
  page, the lyric pool and the queue. They stay mounted behind one
  `:visibility`, so a switch keeps their retained hosts. `etaf-ncm--sync-viewport`
  writes that budget as both `:page-size` and `:lyric-rows`, and entering the
  family from a larger layout brings the lyric pane to the front.
- `etaf-ncm--sync-viewport` reads `etaf-viewport' — the `(PIXELS . ROWS)`
  region the player is mounted into — and writes `:layout`, `:columns`,
  `:window-rows`, the page count (`:page-size`), `:queue-rows` and
  `:lyric-rows`; on a wide region it forces `:pane` back to `list`.  The
  component learns its region in a setup watcher, so one path covers the
  standalone buffer window and a host window, pane or tab, and every region
  change re-resolves the budgets.
- The region is reactive: Ebox publishes a settled resize to the Runtime
  viewport, and a host republishes its region after each flush, so the player
  reflows without reading Emacs windows itself.  Lines borrowed by an active
  minibuffer or completion popup are not a resize: Ebox keeps the mounted
  viewport until the prompt closes.
- The view reads `:layout`, `:columns` and `:window-rows` while it renders, so
  one ref write repaints header, sidebar, panes and player consistently, and a
  resize re-decides the row variant and the chip size. Layout decisions that
  must appear with a reply are left to Host-level bindings; a `visibility`
  written by a component-level read stayed stale until an unrelated repaint,
  so the footer labels and the account row read their sources inside the text
  expression itself. Every pane switch goes through `etaf-ncm-show-pane`.
- The type scale has two sizes: the frame default for anything a reader acts
  on, and `etaf-ncm-font-meta` (15 reference pixels, about 11 pt on a 14 pt
  frame) for subtitles, counters, hints and credits. Emphasis is weight, never
  a larger size, so wording cannot change a fixed row height; a short frame
  drops whole lines (the subtitle, the hint) instead.
- A session without a mount (headless) keeps the `wide` defaults, which keeps
  scripted and test sessions independent of any window.

## Lifecycle

Mounting the app (`etaf-ncm-open`, `etaf-ncm-view` + `etaf-mount`) provides the
palette to the subtree, subscribes the Component, starts polling and loads the
library. Unmounting disposes the session: the timer is cancelled and every
in-flight request of the client is dropped, so late replies never reach a
disposed session. A disposed session is revived by the next mount, which is what
makes close-and-reopen keep the library, selection and queue.

Reading a session (`etaf-ncm-state`) always returns copies. Callers can therefore
hold snapshots without keeping the player alive or accidentally mutating it.

## Interaction feedback

- Row actions are inline icon buttons, without popovers or a root dismissal
  handler. Press dispatch targets the icon, not the ancestor row, so downloading
  or adding to the queue cannot also select or play it. The retained download
  toggle shares the catalog icon path with its check mark.
- Sidebar and library rows have fixed, independently addressable drawing areas.
  Title, text and active colours update retained Hosts rather than rebuilding
  the sidebar. Structural flags (footer and play-all visibility) store booleans,
  not row lists: replacing rows must not invalidate unchanged topology. The
  library keeps a viewport-sized row pool; unused rows, footers and play-all
  controls retain their Hosts but hide their pixels and input maps. Row numbers
  travel with slot values, so scrolling does not rebuild the row components.
  The playing glyph is line-safe icon text in the number Host, not a hidden
  positioned overlay. Headers, chips, lists and footers use separate planes.
- A press on a row selects it; a press on the row that is already selected
  plays it.  The gesture does not consult a timing window, so a slow repaint
  cannot turn a double click into two selections.
- A song row belonging to a playable origin (`:daily`, `:liked`, `:fm`) sends
  `:play` with the loaded ids and captured 1-based start. The service reuses
  `play-ids --start`, which loads paused, positions the queue and then resumes.
  No freshly fetched FM list or second jump can change the selected song.
  Search, recent and list-of-lists rows retain their individual targets. The
  header offers play-all only for kinds in the service's play-command table.
- The queue projection uses `:queue-rows` and a zero-based `:queue-start`.
  A nil stored start centres the loaded window on the playing entry. A wheel
  gesture stores an explicit clamped start; unchanged queue replies preserve
  it, and a new position or changed songs restores following playback. Counts
  come from the backend, while the displayed range comes from loaded entries.
  The wheel's event window and pixel position select the target. A pure
  text-cell rectangle test uses the same body budget and the view's aside/rail
  widths, and excludes a hidden pane and the player bar. The wheel events are
  root `:keys` of the player View, so they take precedence over the renderer's
  minor-mode bindings like every other player key.
  Outside the queue the wheel scrolls the visible library window a row at a
  time and leaves the selection alone; arrow keys and presses still choose rows.
  Queue entries retain their press callback, focusable button role and normal
  TAB/RET bindings.
- Transport commands publish their local effect before the backend answers: the
  play/pause state, the volume, the shuffle and repeat flags and the message
  line change immediately, and the reply reconciles them with measured facts.
  Only a command that can move the queue reloads it.
- Every library list is cached under its section (or search keyword) through
  ETAF's `etaf-list-cache`, which owns the freshness interval, the candidate
  order and the one-at-a-time rule. Sidebar cache hits only publish existing
  memory; they do not start processes or access files. The service restores a
  bounded, credential-scoped sidebar snapshot before mount, preserving each
  entry's observation time through the public `:at` cache API. Reply-driven
  snapshot saves are coalesced outside navigation. Other search/detail entries
  remain session-local. Cache entries keep normalized rows and backend totals;
  equality skips row publication entirely, while a changed total is observable.
  Per-key request tokens deduplicate work and reject disposed replies. A reply
  may publish only into the current key; other replies only warm their cache.
  Selection and scroll anchors follow resource identity through insertions.
  A mounted player warms missing lists one at a time and refreshes
  `etaf-ncm-library-refresh-interval`-second-old entries
  while it is idle.  The refresh pauses while the player's buffer is not on
  screen, backs off after a failure and stops when the backend needs a human
  (an expired login), resuming after the next successful load.  The background
  reply never moves the reader's selection.
- Lyrics and cover art persist in a SQLite database (`media-cache.sqlite`) beside
  the sidebar snapshot, through `etaf-ncm-cache`.  A lyric is one row keyed by
  song id with its translation in the validating column; a downloaded cover is
  one row keyed by song id holding the local file path plus the URL it came
  from, so a changed URL or a deleted file is a miss.  Lookups are synchronous,
  fail open, and let `etaf-ncm--request-lyric`/`etaf-ncm--request-cover` publish
  a hit without starting a backend request. Status replies select the cover
  from already loaded queue metadata immediately; a queue position is only a
  fallback before status identifies the playing song. Either reply order
  therefore converges on the playing song's artwork.

Browse requests take the maximum of `etaf-ncm-list-limit` (1000), the existing
`etaf-ncm-fetch-limit` and three pages. The public snapshot preserves
`:rows-total` as the loaded count and exposes `:list-total` as the reported
total, falling back to the loaded count when absent. Selection and page bounds
use only loaded rows; the footer uses one-based visible indices and explicitly
labels a partial load on a second line, so the loaded count stays readable in
compact panes. The list uses a flex spacer to keep this footer inside its own
height; the player bar and pane tabs do not shrink when space is tight.
List repeat (`列表循环`) uses the existing `:repeat` request, which controls
mpv's `loop-playlist`.

## Player bar composition

The wide bar is a three-column grid. The left column reuses the cover Component
and groups the status VIP flag, title/artist, small actions, queue count and
command message. The centre stacks a single transport cluster over the seek
line. The right column groups a status-derived quality badge, lyric visibility,
queue access and volume. Compact layouts compose the same parts into three
rows, omitting the cover and quality badge. A symbol font is resolved once per
transport instance for the filled play/pause circle, with a Unicode fallback.
Bottom padding reserves room for the symbol fonts' taller metrics; the panel
and list budgets use the same reservation.

All action and gesture callbacks belong to the app's `:bindings`. Child Views
receive those stable functions and never allocate a render-time callback.
The cover and lyric action reveal the lyric pane; queue access reveals the
queue pane without changing either library selection or the stored queue window.
Status normalization preserves supplied VIP and quality hints; it never infers
the playing song's quality from the currently selected row.

Seek and volume are `etaf-range' Components: the pointer-to-ratio conversion
uses the host's painted pixels through ETAF's public measurement and Host-bound
APIs, and never leaves the app. A click and a released drag commit the pointed
value; motion reports a live value and cancellation commits nothing. Volume
routes through a retained numeric source and the existing optimistic command
and reply reconciliation path, retaining the 0–100 range. Its fill, percentage
and mute glyph update without rebuilding the player. Slider drag/value reads
belong to the Fill Host getter, not the component render; callback identities
remain stable across motion and backend replies.

## Polling policy

- Playing: one tick per `etaf-ncm-status-interval` (1 s). The tick advances the
  local clock for a smooth progress bar, asks the backend for playback truth and
  never overlaps the previous request (`:status-in-flight`).  While a request is
  on its way the tick leaves the clock alone: the reply is the truth and a local
  guess would repaint the view for the same second.
- The moving position is the session's retained `:position-ref` source;
  `etaf-ncm--set-clock' stores the numeric slot and publishes that source
  together.  A playing second therefore updates the elapsed label, the progress
  fill and the lyric window through their existing Host getters instead of
  writing a new `:status' and repainting the view.  `etaf-ncm-state' merges the
  position back into the reported `:status', which keeps the public snapshot
  shape unchanged.
- The progress bar is an `etaf-range': a flow track paints the rail and gives
  the row its measurable width, and an absolutely positioned fill overlay above
  it carries the played fraction. A playing second changes only the Range's
  value source, so its Fill getter republishes the elapsed fraction without a
  View publication or a per-tick layout pass.
- Idle: one check per `etaf-ncm-idle-poll-interval` (15 s).
- A lyric is fetched only when the playing song id changes, and then only on a
  media-cache miss; the reply is stored for later sessions.
- The queue list is read from the backend's queue file, not re-downloaded.

Costs are therefore bounded by the poll the session selected, and zero when no
player is mounted.

## Measuring repaint cost

Cached data and passing functional tests are not performance acceptance.
Measure native GUI events through flush and redisplay, including first use,
warmed repeats, backend reconciliation and changing lyric/queue windows.
The historical microbenchmarks below do not represent all real interactions;
particularly, equal-size toy lists can conceal cold admission and topology
costs. Outstanding slow paths must remain reported as failures, not averaged
away into a fast median.

An update is only as cheap as the nodes it invalidates.  ETAF binds each
source read to the Host that made it, so a write repaints those Hosts in
place; Ebox re-lays out only up to the nearest relayout boundary and writes
the changed rows directly into the buffer.

- Run `emacs -Q --batch -L . -L lisp -L tests -L ../etaf -L ../etaf-ui
  -L ../ebox -L ../ecss -L ../etaf-db -l benchmarks/update-cost.el`
  with the framework byte-compiled.  A selection write and a clock tick each
  take about 1 ms at every viewport size of the twelve-row fixture, because
  neither rebuilds or re-lays out the view.
- Sample the process CPU while the demo plays.  Paused playback is the baseline
  (0 %) and every playing second is one bound update, so a change that
  widens what a tick invalidates shows up directly.
- `benchmarks/performance-scenarios.el` registers library switching and
  opening with the workspace `scripts/performance.py` driver for GUI latency.

## Backend contract

`etaf-ncm-client-call` accepts a request plist and a callback; a client is either
a subprocess client from `etaf-ncm-make-client` or a plain function of two
arguments, which is what tests and the demo inject. Replies are `(:ok DATA)` or
`(:error MESSAGE :hint HINT)`, delivered at most once.

Two failure classes are kept apart on purpose:

- Backend failures (network, login, mpv, a missing script, a signal raised while
  translating a request) land in the session's `:error` and `:message`. The
  player stays mounted and `g` retries.
- Invalid player operations (unknown library, blank search keyword, unplayable
  row, out-of-range volume) signal `etaf-ncm-error` immediately, because they are
  programming or input errors rather than backend state.

The default client runs the bundled backend's scripts as child processes with the stored
cookie in the child environment (`process-environment` is bound around
`make-process`; that function has no `:environment` keyword). Each request has a
timeout, and unmounting deletes the processes.

## Rendering notes

- Cover art uses ETAF's `image` Host keyed by the downloaded source file.
  The source identity changes with the track even when the image dimensions
  match; the Host owns raster slicing and publication. Both cover locations
  share this path and preserve the source aspect ratio within their cell budgets.
- The layout is a column flex root: header, body (list + aside) and a full-width
  player bar; the compact layouts drop the sidebar for a library rail or a chip
  strip, tab the panes and stack the player bar into three lines. The clear
  line at the top belongs to the panels' own top padding and the one under the
  bar to the bar's closing padding row, so no hosting window needs an inset and
  the app's background stays unbroken at every size. The library page fills
  every row the window budget leaves, and the wheel scrolls its window through
  all loaded rows.
- `row`/`column` are flow containers; participation properties
  (`:flex-grow`, `:flex-basis`) require a flex or grid parent, and `:flex-basis`
  units follow the parent's main axis (lh/vh/% in a column, px/ch in a row).
- Song rows use a grid so columns align; the list is paginated to the window
  instead of scrolled, because Ebox has no programmatic scroll API and every row
  must stay reachable by keyboard.
- Progress and volume keep the played fraction as a percentage width on the
  fill overlay, so the bar never rounds the ratio to a count of blocks and a
  retained update can replace it without a layout pass.
