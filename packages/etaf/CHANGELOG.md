# Changelog

## Unreleased

### Changed

- Reissued as 0.3.7 after package-loading and workspace updates since 0.3.6.

### Changed

- Reissued: the source had moved ahead of this version without a
  release, so the published file no longer matched it.  Changed since
  0.3.5 was cut: `CHANGELOG.md`, `etaf.el`, `etaf-animation-example.el`, `etaf-help.el` and 3 more.


## [Unreleased]

### Removed

- `etaf-document` and the commands that typed through a rendered page
  (`etaf-document-open` and the rest of its session) are gone.  A page stays a
  rendering: the document is edited in its own buffer, and the preview follows
  that edit block by block.  Cell positions and source characters do not
  correspond one to one -- folded markers, bullets, table rules, wide
  characters and wrapping -- so editing through the painting cannot keep the
  semantics of the buffer itself.

### Added

- `etaf-video-render-backend` selects how `etaf-video` puts a graphical
  frame on screen.  `image` (the default) keeps publishing one scaled JPEG
  per frame, `canvas` reads BGRA frames into one Emacs canvas image and
  refreshes it in place, and `auto` prefers canvas when the Emacs build has
  the `canvas` image type and the optional native reader is built.  A build
  without canvas, or a native module that cannot load, silently keeps the
  image path, so released Emacs versions behave as before.

- `etaf-surface-create`, `etaf-surface-provide`, `etaf-surface-host` and
  `etaf-surface-declare` let content that owns its palette and its light/dark
  switch declare them to the host that frames it.  `etaf-surface-theme`,
  `etaf-surface-mode` and `etaf-surface-modes` read the declaration back, so a
  floating panel can paint its own chrome from the content's Theme and offer
  the content's modes instead of keeping a second appearance state.

- A Host with `:drag-edge` non-nil receives `edge` gesture phases while a drag
  that has moved rests in a window edge band.  Each phase names the touched
  edges and reports intent only; the drag handler owns the viewport and the
  scroll, and `ebox-drag-edge-band` / `ebox-drag-edge-interval` tune the
  engine's cadence.

- `etaf-app-open`, `etaf-app-close`, `etaf-app-state` and `etaf-app-buffer`
  give every application one lifecycle: a canvas buffer, a default face that
  follows the application's theme, a fit callback that runs after each
  settled window or text-scale change, and a close function that runs once
  however the buffer goes away.  Applications no longer need their own
  resize hooks, debounce timers, face remapping or kill hooks.

- `etaf-process-run`, `etaf-process-cancel` and `etaf-process-live-p` run a
  command-line backend without blocking and report one result with the exit
  status, the complete stdout (optionally parsed as JSON) and stderr, a
  timeout or a start failure.  A cancelled job never calls back.

### Changed

- A pointer event bound in `:keys`, such as `<wheel-up>`, resolves from the
  Host under the pointer, so a pane can bind the wheel for itself.  RET
  activates a nearer enabled Host with a press handler before an enclosing
  Host's RET entry, so an application can bind RET on its root for the
  selection without a dispatcher of its own.

### Fixed

- The help panel and a keyboard drag step measure in the cells the canvas
  draws.  `ch' and `lh' resolve against the canvas's own face, while both
  numbers came from the frame's character width, which is the same number only
  while no text scale and no canvas font set them apart: a smaller canvas cell
  left the panel off the centre it had computed and made a drag step travel
  the wrong distance.

- Scoped key commands are named symbols instead of anonymous closures.  Emacs
  stores the resolved command in `this-command', so a post-command hook or any
  other code that stringifies a command no longer walks the mounted Runtime's
  object graph; one keypress in a two-box View used to build a 4 MB string.

- A Theme computed that follows the frame re-derives after an Emacs theme
  switch.  `etaf-theme-current-mode` reports the frame's mode, and a computed
  that read it kept the mode the frame had when it first ran, so a surface
  that followed the Emacs theme stayed on its old palette after a switch.
  A switch now reaches each consumer once, after the enable and disable steps
  of one switch settle.

- Checking a long list of explicitly keyed siblings for duplicate keys is
  linear instead of quadratic.  A View that re-renders about 1,900 keyed grid
  cells spent about 100 ms of every update in this check alone.

- A mounted View follows the input modality with the native cursor: a pointer
  press hides the block it would leave behind, and the next keyboard command
  restores it, so arrows and Tab still show the position while clicking no
  longer paints a stray block. A text input keeps its caret while editing,
  and the caller's cursor state returns on unmount.

- `etaf-runtime-window-viewport` reports a text frame's cell viewport instead
  of nil, so a surface can center and clamp itself against the window on a
  terminal as it does on a graphical frame.

- Reopening a mounted application after packages were installed, natively
  compiled or reloaded in the same Emacs no longer signals
  `excessive-lisp-nesting`.  The reactive layer can be evaluated after the
  Runtime installed its environment hook, and watchers, effects and computed
  getters keep their Component environment.

- Text-only Emacs builds compile optional graphics calls without undeclared
  function warnings. Invalid retained Host content reports `etaf-runtime-error`
  instead of a missing image-predicate error, without partially updating a batch.

- Standard package.el installation can reload unchanged Component declarations
  from source to bytecode without duplicate-registration errors. Library reloads
  preserve live state and original captures; changed definitions and ordinary
  evaluated duplicates still require explicit redefinition.

- A local `etaf-video` source resolves `~` and names relative to
  `default-directory` with `expand-file-name` before ffprobe or ffmpeg runs,
  so a file chosen from a prompt that shows `~/Videos/` plays instead of
  falling back to default metadata.

- RET/return activation follows live keyboard focus after reflow or inspection
  moves point, rather than activating another control at the displaced position.

- Keyboard help stays within the visible canvas even when its application
  uses native window scrolling. Escape and pointer callbacks restore focus
  and the original scroll position after the modal disappears.

### Added

- Host `:on-focus-leave` clears focus-dependent presentation when focus moves
  outside a subtree. Leave callbacks precede enter callbacks in one reactive
  batch, skip shared ancestors and observe the engine's accepted focus.

- Host `:key-scope 'local` isolates a nested application's commands,
  navigation, dismissal, regions and help without creating a modal dialog.
  Unbound letters cannot invoke enclosing Host or buffer actions. Explicit
  focus changes remain available, and region entry memory restores the
  previous control when returning.

- Host `:on-help-open` prepares the nearest enabled application scope before
  any shared help entry opens. Applications can pause ongoing activity without
  overriding `?`; dismissing help does not reverse that policy.

- `etaf-help-data` exposes a defensive snapshot of effective scoped keys,
  application-local keymaps, regions and readable controls. Host `:help`
  supplies non-binding notes. `etaf-help-close` and
  `etaf-help-view-function` let a catalog provide a modal View without
  creating another buffer or application Runtime.

- `etaf-video` sources accept a separate `:audio-url` plus `:headers` and
  `:proxy` for authenticated HTTP(S) playback.  The video decoder and the
  audio sidecar receive the same network options, `etaf-video-source-info`
  reports the normalized `:audio-url`, `:audio-target`, `:headers` and
  `:proxy` keys, and a present audio URL implies `:audio`.
- `etaf-display-metrics` reactively reports a mounted buffer's effective
  character width, line height and image ascent, including text scaling.
  Native image producers can repartition rows without resetting the app.
- `etaf-keymap-reserved-events` reports the framework-reserved events bound in
  a keymap, so components reject a caller-supplied `:keymap` that would override
  Escape, Tab, `?`, the arrows, `M-g` or `C-g`.
- `etaf-animation-paused` freezes the shared clock and resumes every run in
  place, and `etaf-animation-speed` scales transitions and frame sequences
  live; `etaf-animation-frame-rate` now re-rates the running clock. One-shot
  scheduling yields after each publication without suppressing animation during
  keyboard input or replaying missed frames. Runs created during a pause or speed
  change use the same time base as existing runs.
- The animation example fills the buffer with twenty panels, live clock and
  theme controls, and a native editing pad supporting empty drafts and undo.
  GUI windows avoid the extra truncation-column gap with a narrow right fringe.
- `etaf-transition` returns a ref that follows a reactive target over time and
  restarts from the displayed value when the target changes mid-run;
  `etaf-animation-frames` cycles a frame sequence for spinners, marquees and
  typewriter effects.  Both share one display clock
  (`etaf-animation-frame-rate`), publish through the normal ref, Runtime commit
  and Ebox flush path, stop with their Component Scope, and honour
  `etaf-animation-enabled`.  `etaf-animation-stop`, `etaf-animation-finish` and
  `etaf-animation-active-p` control and inspect a run;
  `etaf-animation-interpolate`, `etaf-animation-interpolators` and
  `etaf-animation-easings` cover value conversion and curves.
- `etaf-viewport` reads the region a Component subtree lays out into, and
  `etaf-viewport-region` wraps content in a nested viewport that publishes its
  committed box to descendants, so one application lays out for a buffer, a
  window or a pane through the same reactive read.
- Watchers and effects created during Component setup run their callback in
  that Component's environment on every later reactive run, so `etaf-inject`,
  `etaf-current-runtime` and `etaf-viewport` keep working after the first run.
- Hosts accept `:keys`, scoped `(KEY COMMAND [LABEL])` bindings of keys or
  key sequences such as `C-c C-u` that work while focus is inside them (or
  point, once a command moves point out of the focused Host) and
  run their commands exactly like keymap bindings, `:focus-group` to make a list, toolbar or grid
  one Tab stop navigated with arrows, `:focus-scope 'modal` to confine keys
  and focus to an open dialog, `:on-dismiss` for Escape, and
  `:on-focus-enter`, which runs when focus moves into a Host.
- `?` opens read-only help inside the application instead of splitting an
  Emacs window or displaying a separate help buffer. Escape or a backdrop
  click closes it and restores the caller; repeated openings do not stack.
  The optional etaf-ui package supplies search and responsive key cards.
  `M-x etaf-palette` remains the separate command execution entry.
- `etaf-draggable` and `etaf-resizable` (and their controlled variants) move
  with `M-<arrow>` and resize with `M-S-<arrow>`; focused separators and
  sliders step with arrows; `etaf-drag-step` drives any `:on-drag` from keys.
- `image` Hosts accept `:inset (TOP . BOTTOM)`, pixels under one line height
  left blank inside the first and last rows, for a small gap between an
  image and adjacent text.
- Box Hosts accept Ebox's `:border-radius` and fractional block padding such
  as `:padding-block '(lh 0.5)` for rounded pills and bubbles.
- `etaf-scroll-offset`, `etaf-scroll-to`, `etaf-scroll-by` and
  `etaf-scroll-into-view` scroll an `:overflow 'scroll` Host by `:ref`.  With
  `:scroll-anchor 'end` a chat or log Host opens at its newest row and follows
  new rows until the user scrolls away.
- Hosts accept `:on-swipe`: a horizontal two-finger trackpad gesture calls the
  nearest enabled handler once with `left` or `right`.
- Scrolling Hosts accept `:on-scroll`, called with the new line offset after
  the user or an `etaf-scroll-*` call scrolls them, for infinite histories.
- `etaf-next-tick` runs a function after pending reactive work is written to
  the buffers, for example to scroll to a row a callback just added.
- `etaf-scroll-into-view` takes an optional `start` or `end` alignment.
- `etaf-event-pointer-p` tells, from an event callback, whether a press came
  from a mouse or trackpad click rather than RET or SPC, so backdrop clicks
  can dismiss a modal without the keyboard doing the same.
- `etaf-runtime-viewport` is a reactive read: a render or computed that sizes
  content to the window reruns after a resize or refit.
- `etaf-input-begin` accepts `:on-change`, `:on-leave`, `:keymap` and
  `:local-variables`.  Typed keys edit the Host's value natively while the
  Host keeps its layout, and publications continue during the session.
- Hosts accept `:sticky 'top`: the Host's row stays pinned in the window's
  header line once the window scrolls past it, and header clicks run its
  press bindings, so app bars and back buttons remain reachable.
- `image :src` also accepts an Emacs image descriptor with `:type` and
  `:data` or `:file`, so in-memory thumbnails and generated SVG render
  without temporary files.
- `etaf-selector` returns a keyed membership reader over a reactive source,
  so moving a selection across a long list re-renders only the previous and
  the new row instead of every row.
- `etaf-host-ref-at` maps a buffer position to the explicit `:ref` of its
  innermost enclosing Host, optionally filtered by a predicate, so point-driven
  selection and row commands do not need private buffer properties.
- `etaf-runtime-refit` accepts a nil width, which keeps that dimension
  following the window while the height stays fixed.
- `make native` byte-compiles ETAF and stores native code in the user's
  `eln-cache`, which Emacs loads in place of the bytecode.
- `etaf-runtime-revision` reports the mounted Runtime's committed revision
  without forcing a flush.

- `etaf-video` places a live video source in a layout: ffmpeg decodes the
  source, the Component maps each frame for the `image`, `ascii` or `color`
  render mode, and every frame updates only the canvas Text Host, so a playing
  canvas does not re-render the application.  Handle
  control functions (`etaf-video-play', `etaf-video-pause',
  `etaf-video-seek', `etaf-video-set-speed', `etaf-video-set-volume',
  `etaf-video-set-audio' and `etaf-video-state') drive playback from ordinary
  Elisp, and `etaf-video-source-info' reports a source's metadata without
  mounting anything.  `image' frames decode at the display's device pixel
  ratio so Retina screens stay sharp, `ascii' and `color' cover terminal and
  graphical frames, and an optional ffplay sidecar plays a source's audio.
  The Component stays a canvas: it renders frames and exposes state and handle
  controls, while buttons, progress bars and hover chrome are composed by
  callers from ordinary Hosts.  Image frames are capped to the displayed
  canvas size and the previous frame is flushed as the next one commits, so a
  long video neither overflows Ebox's accepted content nor grows the Emacs
  image cache without bound.

- `etaf-list-cache-put` accepts an observation time with `:at`, so restored
  snapshots retain their age and background revalidation can prioritize them.

- `etaf-data-mutate-many` applies a non-empty list of `(OPERATION PAYLOAD)`
  pairs and reconciles the Controller once, so bulk writes no longer pay one
  reload per row.  A source may expose the optional `:mutate-batch' capability
  to receive the whole list in one call; a transactional backend applies it
  atomically.  A signaled operation stops the batch and keeps the completed
  prefix observable under the `external-unknown' outcome.

- `etaf-list-cache` provides the stale-while-revalidate policy for slowly
  changing lists: each list is cached under a key with its arrival time, an
  application shows it at once and compares a fresh reply in the background,
  and `etaf-list-cache-next` picks the stalest or never-loaded list, one at a
  time, for a timer armed while the session is mounted.  Failed refreshes back
  off and a failure that needs a human pauses them until a load succeeds, and
  an optional version token lets a conditional backend refresh an entry
  without a repaint.

- Interactive Hosts advertise themselves: a Host with an `:on-press` or
  `:on-drag` callback publishes the hand pointer by default. Applications no
  longer declare `:pointer 'hand` per element; an explicit `:pointer`,
  including an explicit nil, still keeps its own shape, and a disabled
  boundary stays with the plain arrow.
- `etaf-retained-resize-open` mounts a runnable fixed-text resize example:
  a controlled `etaf-resizable-controlled` Behavior drives a clipped panel
  whose `:width`/`:height` bindings relayout only the panel, with Shift-locked
  drags and Escape restoring the starting size.
  `benchmarks/performance-scenarios.el` registers matching
  `retained.resize.*` workloads for reactive and Host-geometry routes.
- `etaf-event-target-within-p` reports, from an event callback, whether the
  pressed Host is a given Host or one of its descendants. Combined with a root
  `:on-press` and `:on-press-capture` it lets a shell dismiss an open panel
  when a press lands outside it.
- `etaf-batch` and `etaf-call-with-batch` group related reactive writes in
  ordinary application code. Nested batches defer observers and Runtime
  updates until the outer scope completes while preserving written refs on
  failure.
- `etaf-draggable` and `etaf-resizable` Behaviors translate Ebox drag gestures
  into caller-owned reactive geometry refs, with axis/edge selection, bounds,
  lifecycle callbacks and optional logical-unit delta conversion.
- Controlled variants accept aggregate geometry through `read`/`on-change`
  callbacks without creating a second persistent geometry store.
- `etaf-gui-verifier-line-height-assertions`, `etaf-gui-verifier-canvas-filled-p`
  and `etaf-gui-verifier-canvas-assertion` expose the row-height budget and the
  full-window canvas as reusable scenario checks, so an application scenario
  fails when a glyph falls back to a taller font or a resize leaves the canvas
  taller than the window.

### Changed

- Runtime publication uses the fine-grained retained architecture: `etaf-view`
  compiles to retained segments, Host property and text reads become
  per-binding effects, Ebox nodes stay mounted, and commits patch local buffer
  regions instead of rebuilding the application tree.  This improves ordinary
  text, style and geometry update latency and keeps Ebox as ETAF's internal
  retained node engine.
- `etaf-runtime-refit` and `etaf-refit` advance the revision when the layout
  changes and run as an observed Runtime operation of kind `refit`, so mount
  observers and `etaf-performance-mode` see resize work and its Ebox flush.
- Data reconciliation success is now `reconciled` instead of `projected`;
  update consumers that compare `etaf-data-reconciliation-state` symbols.
- Migration: use `etaf-runtime-revision` or the value returned by
  `etaf-runtime-flush` instead of generation APIs.  Compare revisions to
  observe that a publication reached the buffer.
- A failing binding discards its whole update: the buffer, revision and mount
  callbacks stay as last committed while written refs keep their values.  The
  next write or `etaf-runtime-flush` retries the discarded work, so later
  updates wait until the failure is fixed.

- Video image frames share row-sized slices of one Retina-resolution image,
  keeping adjacent text at normal line height. Each frame updates the retained
  canvas Text Host rather than replacing the canvas subtree.
- `etaf-host-ref-size` returns a mounted Host's committed painted size as
  `(PIXELS . ROWS)`, so an application can fit a resource such as a video
  canvas to a measured region instead of estimating it from window chrome.
- `etaf-video` accepts reactive sources for speed, volume and audio. Controls
  can share one source with the canvas without rerendering their surrounding
  View, and their latest values survive a canvas resize. `display-fps` sets
  the Component's presentation cap independently of decoding.

- Box and Text class lowering now consistently normalizes whitespace strings,
  symbols and nested lists for selectors while preserving public raw Host props.
- Equal computed inputs retain mounted output without committing a new
  revision. Custom `:test` comparisons apply before rendering; unused
  computations stay lazy and failed computation remains retryable.

### Removed

- The package manual `docs/manual.md` is replaced by the [ETAF Reference Manual](https://etaf.top/introduction/), which the README, the development instructions and the architecture notes link; `docs/architecture.md` remains the maintainer contract.

- Removed the deleted Runtime and integration APIs: `etaf-runtime-generation`,
  `etaf-runtime-current-generation`, `etaf-runtime-snapshot`,
  `etaf-runtime-root-node`, `etaf-generation-p`,
  `etaf-generation-root-semantic-id`, `etaf-generation-conflict`,
  `etaf-generation-error`, `etaf-host-authority-error`,
  `etaf-render-write-error`, `etaf-retirement-error`, `etaf-scheduler-error`,
  `etaf-spi-bootstrap-error`, `etaf-spi-incompatible-error`,
  `etaf-data-projection-conflict`, `etaf-data-projection-error`,
  the `:scheduler-context` option of `etaf-effect-scope`,
  the `:watch-scheduler` option of `etaf-scope-run`, and
  `benchmarks/benchmark-ebox-resize.el`.

### Fixed

- A computed runs its getter in the Component environment that created it, on
  every later reactive run, like watchers and effects already did.  A
  `etaf-viewport`, injected Context or current Runtime read inside a computed
  no longer falls back to an empty environment when the computation refreshes
  outside rendering; an application embedded in a desktop window keeps
  laying out for its own region.
- A `:region`'s `:neighbors` declaration now reaches the named region: the
  lookup asked the symbol direction in a keyword plist, so declarations never
  matched and arrow adjacency always followed geometry.
- The animation pad and its text now share one activation owner. Complete
  mouse press/release gestures keep empty drafts editable after deletion and
  resize, rather than starting and immediately ending the session.
- Native scoped commands retained by Emacs key history no longer keep disposed
  Runtimes and callback resources alive. Live commands still work across GC;
  commands from ended mounts fail clearly instead of targeting another app.
- The animation theatre opens with its editing pad already active, so
  typing works without a first click; TAB or ESC leaves the editor, and
  pressing the pad starts it again. The rail leaves one cell of slack, so
  the row never draws a truncation marker at the right edge.
- The animation theatre's editing pad stays focusable and editable in
  narrow or short windows, and a leaked session from a dead mount can no
  longer block starting a new one. The pad text keeps its committed Host
  geometry instead of being wrapped in a plain box.
- The animation theatre uses a responsive one-to-four-column Grid, wrapping
  controls and vertical scrolling on narrow windows. Its top rail spans the
  viewport instead of ending after a fixed number of characters.
- The animation theatre keeps its editing toolbar visible when a multiline
  draft exceeds the pad's height. Multiline input, clear and undo are covered
  alongside animated neighbours by public regressions and a GUI workload.
- A Theme token nested in a `:hover-style' plist resolves from the
  provided Theme like any other Host style value, so catalog rows tint on
  hover instead of leaking the deferred token into the native mouse face.
- A paused `etaf-video` presents the frame at a `etaf-video-seek` target
  instead of keeping the old picture, a source change starts the new source
  at its beginning, and resizing an ended video redraws its last frame at the
  new canvas size.

- A settled window size change no longer refits a mounted Runtime when an
  active minibuffer, a completion popup, or a message in the echo area borrowed
  the display window's height.  A frame resize still refits, and
  `minibuffer-exit-hook` reconciles the canvas once the borrowed space is
  released.

- Visible canvases preserve layout typography instead of shrinking tall glyphs
  after publication. Emoji no longer shift later table columns, and large
  headings keep their declared size. Fixed-row controls must use suitably sized
  fonts or catalog icons rather than relying on post-layout shrinking.

- Semantic palettes use application-owned token plists and
  `etaf-theme-resolve-palette`. The palette adapter and replacement registry
  are removed; replace named palette bindings with direct light/dark token pairs.

- Narrow Host content updates no longer deep-copy their immutable property
  signature before lowering; renderer and source-builder ownership boundaries
  retain the required snapshots without duplicating interaction metadata.
- Local updates invalidate enclosing Range snapshots without eagerly rebuilding
  their complete output. Snapshots are composed from current semantic facts when
  needed; subsequent parent updates and keyed reorders retain current child state.

- Retained Components and keyed rows receive replacement input objects even
  when their contents compare equal. Business props and list items now share
  refs' shallow equality, keeping state and focus while updating callbacks.
  Function-valued refs also preserve this identity rule across Emacs function
  representations.

- Components can change between empty, single-root and fragment output without
  changing the enclosing layout or rejecting a valid update. Component bindings
  survive output changes; retained keyed children keep state and focus. Nested
  updates publish from the same final output, including Host property changes.

- Fragment Components projecting slots no longer introduce an implicit Column
  when mounted. Their children participate directly in the enclosing layout,
  matching pure rendering while preserving state, focus and cleanup.

- Host property updates use Ebox's general property operation for layout, style
  and interaction changes. They compose with retained Component state and child
  updates without rebuilding the Host subtree. Framework checkouts require the
  Ebox version providing `ebox-candidate-update-host-properties`.

- Retire reused Component records with their removed branch, including records
  whose unchanged subtree was not staged. Filtering an edited selection out
  and restoring it no longer leaves loading stuck on a missing render node.

- Retire staged descendants and pending Host updates when their enclosing
  branch is removed. Deleting an edited Data selection leaves subsequent loads
  and filtering usable; slot updates preserve their physical parent.

- Resolve conditional ancestors before descendant input/render work, so hidden components release their callbacks and repeated show/hide updates never address a retired Host.

- Pure `etaf-render` rejects reactive writes in expressions before they can
  change application state, matching mounted rendering's read-only boundary.

- Repairing a rejected root input now publishes pending descendant state changes,
  including when the repaired props equal the previously committed props.

- Composed slots can update a controlled child and conditional content together
  without duplicating retained children. Both declarative and programmatic slot
  containers preserve the child's interactive identity across repeated updates.

- Buttons without explicit references keep working after theme or reactive style
  updates. Retained layout identity and native activation now address the same
  committed Host, including after disabling and re-enabling a control.

### Removed

- `etaf-input-mode` and its independent keyboard map. Mounted applications use
  `ebox-buffer-mode` automatically; remove calls and hook setup for the old mode.
  Update Ebox together with ETAF and use its shared buffer map for custom keys.

### Changed

- Deferred Resources now start `idle`; successful Data reloads report
  `refreshing` while retaining items. Consumers matching status symbols must
  handle `idle`, `refreshing` and `cancelled` as well as loading/success/error.

### Added

- `etaf-performance-report-data` exposes a detached structured report for
  automated consumers, including operation identity and public provider stages.

- `etaf-focus-within` delegates panel-local navigation to Ebox's shared focus
  implementation. Menus and dialogs can cycle within a committed subtree
  without keeping their own target index. Requires Ebox's `ebox-focus-within`.

- Components can declare optional `:validate` checks using ordinary Elisp after
  defaults resolve, before initialization or updated inputs publish. The shared
  `etaf-check-prop` helper reports the component, property, received value and
  expectation. Pure and mounted rendering use the same input contract.

- Component rules can use Ebox-derived `:active` during native press and drag
  gestures. Reactive updates retain the state; pointer activation observes it
  cleared. No application pressed-state binding is required.

- Hosts and Component root attributes accept Ebox native help, pointer and
  hover paint, preserving inheritance and explicit nil boundaries on updates.

- Host `:on-drag` callbacks use Ebox's shared native gesture lifecycle. Each
  motion publishes through its own reactive event batch; target retention,
  coordinates and native input remain owned by Ebox. Update Ebox together.

- Expose Data source capabilities for adapters that preserve storage and disposal while wrapping load or mutation operations.

- Add `etaf-call-with-input` for native editing and selection inside event callbacks, using Ebox target lifetime and focus restoration.

- Resource and Data accept native asynchronous loaders through `etaf-async`,
  with cancellation, timeout, late-result protection and Scope-owned disposal.
  Resource supports `:keep-value`; Data exposes write certainty and read-only
  recovery with `etaf-data-mutation-outcome`, `etaf-data-reconciliation-state`
  and `etaf-data-retry-reconciliation`.
- The Resource example demonstrates native timers, retained refresh and cancel.
  Its open/close commands are available directly after requiring `etaf`.


- `etaf-update-value` applies an ordinary function to a ref's current value
  and publishes its replacement through the existing reactive write path.
  Updaters need no manual read/write pair or deep reactive proxy.

- Components accept `:bindings ((name initializer) ...)` for stable instance
  values shared directly by setup, views and callbacks. Initializers run once
  in order, using the existing Scope lifecycle. Examples and manuals use this
  form instead of packing and unpacking `etaf-state`; the latter remains an
  advanced accessor for an explicit setup result in components without bindings.

- ECSS-tagged Box layout and outer values now use Ebox's canonical projection,
  including important, CSS-wide and variable values during reactive updates.

- Preserve Host role, ARIA attributes and disabled state in Ebox selector
  subjects, including successful reactive updates and failed-candidate rollback.

- `etaf-local-ref` allocates stable instance-local Host handles during setup.
  Reusable components can address same-named internal controls independently,
  retaining targets across keyed reorder and failed publication.

- `etaf-prop` supplies stable read-only Component inputs for setup computed values
  and watches. Updates notify after publication; rejected candidates preserve
  committed inputs and dependency tracking. Sources expire with their instance.

- `etaf-behavior-context-info` exposes installation Runtime, Host reference and
  semantic properties through a public snapshot query usable during cleanup.

- Standalone effect scopes have public `etaf-scope-stop` and
  `etaf-on-scope-dispose` lifecycle operations. Cleanup registration rejects
  stopped scopes, and teardown returns cleanup failures while continuing.

- Component props accept `(name default)` declarations. Missing inputs lazily
  initialize instance-owned defaults; explicit nil remains a supplied value.
  Published defaults survive overrides and are discarded on unmount.

### Fixed

- Deferred Theme tokens remain valid in Component rules. Their actual values
  pass Ebox validation after contextual resolution.

- Component callbacks can directly capture declared props in both `:view` and
  `:render`. Successful updates replace their snapshots; rejected renders keep
  the committed callbacks. Setup closures retain initial inputs, and props
  containing refs preserve live reads and reference identity.

### Changed

- Component `:focus` rules now follow shared Ebox focus, including reactive
  layout, hiding and rollback. Update Ebox with ETAF; pure rendering and other
  mounted buffers remain independent of the selected buffer's focus.

- Disabled component styles use Ebox's shared interaction-derived selector
  state. Update Ebox together with ETAF so pure and mounted disabled rules keep
  their behavior during reactive updates.

- Mounted keyboard navigation and activation now use Ebox's buffer mode and
  target selection. `etaf-activate` and native commands share focus precedence;
  mouse clicks continue to use their clicked target. Configure
  `ebox-buffer-mode-map` after requiring Ebox to customize input.

- Focus APIs now operate Ebox's single mounted focus and published tab order.
  Direct Ebox focus changes are visible through ETAF. Reorder follows stable
  source identity; hidden, disabled or removed targets clear focus. Manual point
  movement preserves a clamped numeric position and rejected publication restores
  focus. Negative or absent tab index skips navigation but no longer clears an
  explicitly focused surviving Host; call `(ebox-focus nil buffer)` to clear it.
  Update Ebox together with ETAF; it also supplies shared keyboard bindings.

- Mounted press handlers now use Ebox native keymaps and activation lookup;
  Ebox navigation can discover ETAF controls. Disabled and callbackless children
  block ancestor activation. Native clicks preserve point/window selection,
  and keyboard activation preserves explicit focus at shared positions.

- Component styles now use Ebox/ECSS matching and cascade. Later equal-specificity
  rules win, author-important rules can override normal inline values, and
  structural selectors operate on the canonical tree. Change root class/type
  rules to `&.class` or `:scope`; plain selectors address descendants.
  Fragment roots, reactive Theme rules and code slot recomposition retain ownership.

- Theme defaults now use ECSS UA origin through Ebox scopes. Normal defaults
  remain below author properties; UA-important defaults take precedence over
  author-important declarations. Remove importance from Theme defaults that
  callers should override. Reactive updates retain layout and deferred values.

- Component `:styles` and `etaf-component-set-styles` now accept a plain
  ordered rule list. Remove the `styles` wrapper; normal Elisp arguments still
  quote literal lists. Rules validate through the shared Ebox/ECSS contract.

- Expose the package entry at the repository root, document supported APIs in
  its Commentary and retain implementations under `lisp/`. Source consumers add
  the repository root to `load-path` and require the package entry; internal
  feature imports are unsupported. Archives retain this same directory layout.

## ETAF 0.2 migration

ETAF 0.2.1 requires Ebox 3.0.0 and TP 2.0.0. Install TP, then Ebox, then ETAF.
The renderer bootstrap now requires Ebox framework SPI v2 and fails closed when
the provider is absent, malformed, or incompatible.

Remove any configuration of `etaf-render-port-selection-policy`. The v1 render
port and its manual initial-publication cleanup path have been retired. Runtime
mounts and updates always use the immutable SPI v2 port, including its paired
framework stage and rollback, same-object report, observation replay, revision,
and Host final-marker contracts.

During an ordered source upgrade, ETAF accepts Ebox providers that report either
`tp-transaction-protocol-v1+v2` or `tp-transaction-protocol-v2`. The former is a
temporary capability declaration that still contains the required v2 protocol;
ETAF never invokes a v1 transaction operation.
