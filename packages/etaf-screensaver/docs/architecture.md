# Screensaver architecture

## Ownership and dependency direction

The application depends on ETAF's public Runtime and retained Host APIs.
ETAF owns rendering and its own mount resources; the application owns idle
policy, input dismissal and playback. No catalog UI is needed. Scene authors
supply data specs or pure callbacks, not editor buffers, processes or timers.

## Source map

Runtime modules stay flat under `lisp/` because they share one scene registry
and one loader; their names state their responsibility.

| Area | Files | Responsibility |
| --- | --- | --- |
| Public entry | `etaf-screensaver.el` | Supported API inventory, declarations, package loading |
| Lifecycle | `etaf-screensaver-app.el`, `etaf-screensaver-views.el` | Idle watcher, window takeover, input dismissal, teardown, ETAF mount |
| Playback | `etaf-screensaver-playlist.el`, `etaf-screensaver-engine.el`, `etaf-screensaver-model.el` | Program/pack compilation, scene registry, page clock, seeds, transition and publication |
| Presentation | `etaf-screensaver-presentation.el` | Full, card, band and mosaic layouts, captions and page composition |
| Data scenes | `etaf-screensaver-dsl.el`, `etaf-screensaver-layers.el`, `lisp/scenes/*.esc` | Safe expression interpreter and the rain, sand, particles, field and text layers |
| Callback scenes | `etaf-screensaver-scene-donut.el`, `etaf-screensaver-scene-equalizer.el` | Native works that need arithmetic beyond the DSL |
| Recordings | `etaf-screensaver-reel.el`, `etaf-screensaver-tte.el`, `etaf-screensaver-ansi.el`, `etaf-screensaver-frames.el`, `etaf-screensaver-glyphs.el`, `lisp/reels/*` | Provider cache, TTE/ANSI decoding, image frames, enlarged text and loop timing |
| Loading and import | `etaf-screensaver-loader.el`, `etaf-screensaver-import.el` | Scan specs, reject bad files without stopping others, copy and report imported recordings |
| Development tools | `scripts/bake-canvas-frames.mjs`, `scripts/bake-gallery.mjs`, `scripts/bake-poems.py`, `scripts/trim-recording.py`, `scripts/loop-recording.py` | Offline asset baking and loop repair; never called during playback |
| Acceptance | `tests/`, `benchmarks/`, `scripts/etaf-screensaver-gui-scenarios.el` | Public ERT scenarios, timing baselines and real-GUI review |

The scene registry validates descriptions. The playlist compiler validates
all branches before takeover and snapshots effective scene descriptions,
parameters, durations, backgrounds and frame-rate caps. Finite groups choose
children in order, from shuffled bags or with replacement; nesting composes
whole sequences. Bounds on depth, group size and round expansion prevent an
accidental unbounded program from occupying the input thread.

The engine owns a page's composed frame and the independent scene states,
random streams and content rectangles within it. The playlist expands finite
selections first, then groups consecutive mosaic works into pages of at most
four without crossing pack boundaries. Partial pages do not fabricate works.
The presentation layout is the single source of content rectangles for both
callback sizing and composition; a wall is not a sliced single-scene frame.
Only the parent owns a mounted Runtime. Color-only changes are meaningful:
publication compares text properties as well as characters. Full-canvas works
inherit the Host background directly. Gallery cards extend the work's paper
across the viewport, inset a thin frame by an even mat of about three line
heights, and reserve two ordinary lower-left caption rows for its title and
summary. The side mat is derived from the frame's cell metrics so the four
pixel distances match; compact windows shrink the mat before the work drops
below four content rows. The echo row below the presentation window is
painted with the mat and counted in the bottom inset, so the visual margins
stay equal. Framed works use a read-only paper/mat, border
and caption template, rebuilt only for a new page, viewport or clock minute;
its rows are split into static fragments and work-row slots. Each animation
fills those slots with borrowed logical rows and background metadata, without
joining a full-width row or copying a source merely to add its presentation's
face. Background-only framing is applied to the owned compact string after
glyph projection; it cannot change font metrics or recolor a recording's
cached strings. Only a viewport narrower than the layout joins logical
fragments for the shared clipping operation. Short rows append blank cells;
fitting a row that already fits does not slice or rebuild its text and image
runs. At final publication, ordinary text and blank runs are emitted
unchanged; only image slices collapse to one replacing glyph. Natural spaces
already carry the run's face width, and scanning every changing row for blank
compression cost more allocation than the layout it saved. This projection
never changes the logical rows used for composition or reveals. Rows and
their fragments stay separate through composition and reveal; projection
concatenates each row's runs once, without copying the full grid and its text
properties into another string. Each row has a stable retained Text Host in a
one-line box. Publication compares immutable row strings and replaces only
changed rows in one batched Host update, so static margins and borders need no
repeated paragraph layout. A scene can reuse and mutate its own row without
aliasing the last published snapshot. Resize commits any added row Hosts
before addressing them. A page boundary copies outgoing rows before the old
scene state is released or a new scene is created. Publication depends on the
Runtime mount, not painted bounds: a shrink can clip all old glyphs, and the
newly fitted rows must still replace them.

Each scene renders its own frame text.
Canvas cells are character vectors, so writes do not depend on UTF-8 byte
width. Each DSL scene owns one scratch canvas for its current dimensions;
render clears its character and color vectors, including wide-character
continuations, before drawing any layers. Resize replaces that storage.
Composed row strings remain independent of the scratch vectors, so clearing
the next frame cannot change published or outgoing-page snapshots.
Composition preserves wide-character continuation cells and merges
adjacent colors. Row projection builds one string, omits continuation cells
and paints color spans directly instead of joining per-cell or per-color
strings. The expression interpreter evaluates only its whitelist;
common unary/binary arithmetic does not allocate an argument list per
expression. Dense fields also call three- and four-operand arithmetic directly,
retaining the original operand order and arity rather than reassociating float
operations. A dense field builds closures over that same whitelist and reuses
exact subexpression values along invariant spatial/time axes. Its caches and
coordinate bindings belong to the field and are recreated on resize. Changing
globals refresh per render; random calls are never cached, and conditional
branches remain lazy. Scene data is never evaluated as Lisp, and the environment
cannot escape through the expression whitelist. The engine
owns no timer or input handler.

## Recorded animations

Reels adapt external animation recordings without reimplementing their
algorithms. A provider turns one native format into frame strings and
metadata; it is registered by id with match and read functions, extension
hints and a license. The built-in `tte` provider validates Terminal Text
Effects recordings, a zlib stream of tagged records, and converts SGR runs
into the same face properties the canvas uses. The SGR parser reads numeric
fields directly from the source ranges, without splitting parameter strings.
Each sequence derives a fresh face value; later changes and resets cannot
mutate preceding runs. No provider runs a process: playback reads bytes and
leaves the recording in its native format.

The reel layer owns provider-independent behavior: per-frame timing from the
recording, looping, lazy per-frame SGR conversion, wide-character aware
center fitting and a bounded cache of recent unchanged reads. Up to 32 recent
recordings share a 48 MiB frame-text and image-path payload budget, rather than
a per-recording allowance; cache hits refresh recency. Image entries retain
validated file names, not encoded or decoded images, so a gallery round can
reuse its metadata without retaining its frames. Changed manifest size or
modification time triggers a fresh provider read. Registration
validates metadata and the referenced file but not frames, so an unused reel
costs only its spec. A private source descriptor travels with the registered
scene in the compiled program; read-ahead never resolves a newer registration
by id or inspects a creation closure. Custom providers keep their synchronous
read contract. Importing
copies a recording beside a `.esr` spec and reports compatibility,
dimensions, color depths and license per file instead of claiming universal
support. The loader scans `.esr` specs beside `.esc` scenes and skips a
broken spec without disturbing the others.

Text recordings retain native canvas rows for the surrounding animation.
Their last visible frame supplies nonblank subject bounds, not a per-effect
lookup; a blank closing frame from a baked loop does not hide the subject.
Graphical SVG builds can project that subject as cached vector glyphs at a
bounded, viewport-dependent scale. Automatic sizing applies to single-work
pages; concurrent works retain their native overview unless a fixed scale is
explicitly selected. Each glyph occupies complete base-height
slices and retains its original character once in the public buffer, including
wide text; no large font can raise the line height or resize a caption.
The native subject cells are blanked before the enlarged subject is composed,
without changing cached recording rows. Only the subject's source rows are
scanned; there is no expanded per-frame character-grid cache. A work keeps at
most 64 glyph shapes and 512 styled glyphs for its current scale/font geometry.
Their display slices and styled slice strings are read-only reusable values;
publication cannot recolor an earlier frame. The subject keeps one ink chosen
for contrast with the work background, and weight/slant still come from the
original character's face, so a colour fade does not rebuild or release a
still-visible shape. Publication and teardown use the same image ownership
as image reels. Terminals, missing SVG support,
scale 1 and a recording with no visible frame retain native text.

Image recordings take a second path.
The `frames` provider returns image file names and a pixel size; the reel
layer retains each frame's native pixel dimensions or scales it down uniformly
when the canvas is smaller. It centers the image on character rows and crops it
per row with a `display` slice, the same retained Host boundary ETAF video uses.
The final partial slice is raised to the same top alignment as full slices,
rather than rescaling the whole image to a multiple of the line height. Each playing reel keeps
only its current geometry's logical row template, including blank rows and both
margins. Native image size, viewport and character/line/ascent metrics determine
that geometry. Frames replace each row's display value with a fresh image
descriptor and a read-only slice; they never mutate values shared with earlier
publication or outgoing-page snapshots. A geometry change replaces the template,
not an accumulating cache of frames. Composition reserves
each image run's full cell footprint for character-grid clipping. Publication
projects that replacing run as one glyph with the same image slice; its known
pixel width avoids measuring a long replaced string on every frame. A fixed
pixel-width spacer supplies rounding slack, so neighboring tile borders stay
aligned without stretching the image or remeasuring a font-relative spacer. The engine flushes the previous frame from Emacs's image cache
after the next one is committed and flushes remaining images on teardown.
Steady playback retains only the current page's decoded frames; a reveal may
also retain one outgoing page until its last visible slice is replaced.
Baking is a development step (`scripts/bake-canvas-frames.mjs`): it renders
a browser canvas offline and writes still frames. Renderer adapters use
upstream Butterchurn and Vanta, a virtual clock and a seeded RNG; external
URL canvases instead use real time. The baker owns one CDP tab and a staging
directory, bounds requests and output, validates canvas dimensions/MIME and
commits by rename. Loop crossfades happen there, not on the Emacs input path.
`scripts/bake-gallery.mjs` applies the data recipe, delegates each work to the
baker and generates public `.esr` specs and independent pack configuration.
The image provider rejects paths leaving the bundle and bounds manifest,
canvas, frame count and encoded size before import. A canonical bundle root
and basename-only entries make ordinary asset checks local; symlinks receive
an additional containment check. Header detection reuses one bounded buffer
rather than invoking editor buffer-lifecycle hooks for every asset. It reads
64 bytes first and extends unrecognized prefixes to at most 8192 bytes, so
binary signatures avoid unnecessary reads while long textual headers remain
supported. A shared begin/step/result reader performs this entire validation
for both synchronous import/playback and incremental next-page preparation;
there is no reduced validation path. File suffixes never substitute for content recognition. Format
recognition does not depend on the host build's image decoders. Validated
formats travel with the file names so playback need not reread each header;
other providers can omit formats and let the reel detect them lazily. A
headless projection retains ordinary image descriptors without decoding;
graphical playback rejects a format when its decoder is unavailable. Import
always rereads the provider instead of trusting the playback cache: a frame
or symlink can change without changing the manifest. It is not a decoder
sandbox. The application never runs a browser, shader or external decoder at
playback.

### Offline baking protocol (version 1)

The CLI uses a local Chrome CDP HTTP endpoint: `PUT /json/new?about:blank`
allocates its one owned target; the returned WebSocket carries numbered
`Runtime.enable`, `Page.enable`, `Emulation.setDeviceMetricsOverride`,
`Page.navigate` and `Runtime.evaluate` requests. Replies resolve by id;
protocol errors, exception events, console errors, socket loss and deadlines
fail the operation. Cleanup uses `/json/close/<owned-id>` and never closes
another target. The bounded fixture peer in `tests/tools` speaks these same
HTTP/WebSocket envelopes, including failure paths, without a browser or
network service. Actual upstream renderers require a separate real bake.

A renderer adapter exposes names, start and per-frame advance inside the
owned page. Capture validates its canvas and MIME; advance/capture share one
browser task so WebGL cannot clear the drawing buffer between them. The
output contract is a version-1 frame manifest plus basename-only stills.
Upstream attribution is metadata, never executable scene configuration.
A collection recipe contains defaults, works and pack data; its runner only
composes the baker and public reel/pack formats. It cannot change the playback
program, start Emacs, or run a renderer during presentation.

## Presentation lifecycle

Start validates and prepares the initial scene before replacing windows.
Only one presentation may own the editor at a time; a repeated start returns
its existing buffer without replacing the saved window configuration.
The presentation saves the frame's window configuration, caller buffer,
mouse tracking and any toolbar/tab-bar setting it changes. It mounts a
canvas-only view in an ephemeral buffer, with no mode line, header, cursor or
interactive scene controls. It does not create or activate a frame.

A page change freezes at most one outgoing composed frame, including any
inherited background. The incoming page's clock begins normally. A smoothstep
reveal replaces complete rows from top to bottom, sharing existing native
image slices rather than decoding an SVG composition on every tick. Its
configured duration is snapshotted at start and capped at half the incoming
dwell. Repeated identical pages skip the reveal; resize completes it. A late
page change finishes any prior reveal before taking another snapshot, so
snapshots never accumulate. Publication retains only images still referenced
by visible rows, and ordinary wake/teardown releases the transition too.

One single-shot animation timer advances every work's elapsed time, selects
the next page when its duration expires and publishes the composed frame.
Scheduling uses an absolute frame grid anchored to the current page's clock,
with the natural page deadline as its final slot. Rendering time and timer
jitter do not accumulate into a shifting cadence. Missed grid slots are
skipped rather than replayed as a burst of old ticks.
During the last six seconds of a page, the same callback may prepare metadata
for the next already-queued page. It processes at most one reader and 64
assets per callback, using at most six milliseconds of remaining time in
that frame's first quarter-period. A frame already past that allowance does
no read-ahead. The reader checks this absolute deadline before each atomic
stat/header read; manifest parsing has its own 1 MiB/7200-entry bound.
OS file operations cannot be preempted. Each chunk owns one temporary header
buffer, with no buffer, timer, process or decoded image retained between
chunks. It neither expands a new shuffle round nor advances the playlist or
RNG. At selection, the manifest cache key is checked again; changed manifests
use a fresh read and incomplete reads finish synchronously. Only complete
successful results enter the existing shared cache. A failed preparation is
retained solely by its presentation and re-signaled on selection, so a broken
next page cannot stop the current page early. Stop drops all preparations,
including failures and partial reads, without adding them to resume state.
A mosaic page lasts for its longest work; recorded children follow their own
timing and loop independently. It schedules a successor only
if it still owns the active presentation. Scene boundaries and resize update
reactive view inputs; ordinary animation publishes just retained canvas text.
If the window disappears, the buffer dies, the frame is deleted or focus is
lost, the presentation is released rather than running invisibly. Focus loss
means an observed true-to-false transition on the owning frame, not a global
notification while a manual background preview is already unfocused.

A transient map plus a pre-command hook consumes wake input. Mouse tracking
is enabled only while presenting. Button-down is consumed before dismissal
on release, avoiding a trailing click on the restored application. Other
keys, mouse movement and wheel input dismiss immediately. No wake input is
requeued into the editor.

Stop clears active ownership first, making callbacks from unmount, keymap
release and buffer death safe to reenter. It cancels the animation timer,
removes wake hooks and focus observation, restores mouse tracking and the
frame/window snapshot, unmounts the Runtime and kills the temporary buffer.
Cleanup runs on failed startup and rendering failure too; an animation failure
also disables automatic mode and reports its cause instead of retrying in an
idle error loop.

Configured playback retains its current page, remaining queue, scene seed and
program random state across dismissal, restarting that page from its beginning
on wake. It compares a newly compiled effective program and configured seed to
the saved snapshot before reuse. Changed packs/options/registrations invalidate
it. Explicit previews do not consume or overwrite that configured position.

## Automatic idle mode

Automatic mode separately owns one single-shot idle timer and a post-command
rearming hook. Presentation suspends that watcher. On wake, a fresh interval
is armed; if mouse-only input did not reset Emacs's native idle clock, the
threshold includes its current idle duration. Subsequent ordinary commands
rearm relative to their fresh idle period. Hidden/unfocused frames and active
minibuffers defer activation. Disabling the mode removes both watcher and
rearming hook and dismisses any presentation.

There are no external processes, recurring hidden-frame probes or permanent
mouse-tracking changes. The idle watcher is intentional only while the user
has enabled automatic mode.

## Verification boundaries

Public acceptance drives real timers, the presentation API and native command
loop events. It checks seeded programs, Unicode output, configuration errors,
window restoration and Emacs timer/process inventories. The graphical scenario
checks every bundled scene, several window shapes and input dismissal, with
separate screenshot review. Real automatic activation and OS mouse delivery
require a focused idle/input pass; background evidence cannot establish them.
Performance scenarios measure autonomous frame cadence including timer wait,
not a private engine step or the removed workspace controls. Full-size gallery
workloads include manifest fingerprints in their environment and reject missing
or reduced fixtures. GUI boundary workloads preserve natural dwell times;
short repeated boundaries belong only to headless batch tests. Boundary
preparation interpolates time between public elapsed-time snapshots: a jittered
last frame need not land inside a single-frame sampling window. Preparation
never preloads the incoming page, and losing the current page before timing is
an explicit sampling failure. The dedicated
transition GUI scenario captures one normal day-to-night change, including
both image sources in the public buffer, and exits after wake.
