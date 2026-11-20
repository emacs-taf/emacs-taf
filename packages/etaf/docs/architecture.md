# ETAF Architecture

This document is the maintainer contract for ETAF's implemented runtime.  It
explains ownership, dependency direction, data flow and invariants.  User
recipes belong in the [ETAF Reference Manual](https://etaf.top/introduction/); the authoritative public API list is
in the Commentary of [`../etaf.el`](../etaf.el).

## 1. Responsibility stack

ETAF is the public application framework for text UIs.  It keeps the authoring
model small: applications declare Views and Components, store state in reactive
sources, and receive events through Host callbacks.  Lower layers own lower
level facts.

```text
ecss → ebox → etaf → etaf-ui → applications
```

- **ECSS** owns selector matching, cascade and normalized style values.
- **Ebox** owns retained nodes, computed styles, layout, focus, native input
  sessions, line composition and direct Emacs buffer updates.
- **ETAF** owns View and Component syntax, reactive bindings, Runtime lifetime,
  Context, Theme, Behavior, Actions, Data, Resource and public Host queries.
- **etaf-ui** owns reusable ETAF Components.  It depends only on ETAF public
  APIs.
- **Applications** compose Components and own business state.  They do not call
  Ebox directly; missing lower-level capability is exposed through ETAF first.

Ebox is therefore an internal engine behind ETAF.  ETAF may keep Host-to-node
maps for events and queries, but the physical node tree, layout cache and buffer
edits remain Ebox responsibilities.

Ebox's settled display notifications publish `etaf-display-metrics` and the
Runtime viewport in one reactive batch.  Applications preparing native image
rows read these metrics to update their own producers.  ETAF does not rebuild
the Component tree or take ownership of the producer's pixel content.

## 2. Maintainer model

| Concept | Owner | Maintained facts |
| --- | --- | --- |
| View | `etaf-view` / compiler | Host and Component structure, literal values, executable holes |
| Segment | Runtime | Retained identity, parent/child relation, one binding owner |
| Host segment | Runtime + Ebox | One retained Ebox node, semantic props, Host reference |
| Component instance | Runtime | Scope, props, bindings, setup result, slots, lifecycle hooks |
| Reactive source | `etaf-reactive` | Value, dependency edges, phase queues, Scope ownership |
| Ebox node | Ebox | Computed style, geometry, focus/input facts, composed lines |
| Data Controller | `etaf-data` | Query, page, items, status, errors, reconciliation state |

Host segments own authored Ebox nodes. Fragment, expression, branch, list, slot,
Component and root segments group children or own effects that maintain them.
A Runtime canvas wrapper is needed only for multiple roots or a transient
surface; ordinary Component structure does not add invisible Ebox wrappers.

Keyboard help is a transient segment owned by the existing Runtime, with the
same build, patch, disposal and Component lifecycle as application content.
It inherits the opening Host's Context and shares one viewport-sized canvas
with the original nodes, including short or text-only application roots.
Opening and closing never recreate application Components or their state;
node scroll offsets survive the canvas mount change. Root replacement keeps
surface nodes in the same child-list update, retaining their native input
projection. Unmount releases the application and transient segment together.
The effective key snapshot and return location belong to core; an optional
catalog renderer returns a View rather than another buffer or Runtime.
Before capture, the nearest enabled `:on-help-open` Host in the effective
key scope can prepare application state, such as pausing ongoing activity.
The modal boundary contains this lookup. Closing does not reverse that
application policy.

## 3. View compilation and retained segments

`etaf-view` expands structural forms into a View value.  The compiler separates
static structure from executable holes when it can do so:

- literal properties and literal text are stored as static node facts;
- executable property values become property programs;
- `(expr FORM)` in a text Host becomes a text program;
- structural `expr`, `:if`, `:else-if`, `:else` and `:for` forms become dynamic
  regions;
- Component calls are normalized with their props and slot inputs.

Mounting instantiates one retained segment tree from that View.  A segment keeps
its identity while its key and kind continue to match.  `:key` selects identity
among siblings: on a Component it retains the Component instance, and on a Host
it is forwarded to the Ebox node.  Keyed lists compare keys, patch matching
segments and move their retained Ebox nodes into the new order.

Static subtrees are built once.  Dynamic sites are represented by reactive
effects tied to the segment they update.  A property binding calls
`ebox-node-set-props`; a text binding calls `ebox-node-set-text`; structural
regions patch only their own child list.  Bindings do not rebuild unrelated
segments.

## 4. Components

`etaf-define-component` registers one Component definition. Registration records
its declaration fingerprint and the canonical library path, treating `.el` and
`.elc` as the same library. Reloading an unchanged declaration reuses the original
definition without invalidating compiled Views or resetting retained instances;
this supports package.el's source-to-bytecode reload after installation. It also
preserves the original captured values. Ordinary evaluation has no library identity,
and changed declarations or another library still require explicit redefinition
through `etaf-component-redefine-run` after disposing affected Runtimes.

A mounted Component instance runs its initialization once:

1. allocate the Component Scope;
2. create named `:bindings` in declaration order;
3. run optional `:setup` in the instance environment;
4. compile and bind `:view`, or execute `:render` inside the instance;
5. record lifecycle hooks and slot access.

Declared props are per-instance reactive signals.  The View and callbacks read
current prop values through the instance environment, while setup can use
`etaf-prop` for tracked input reads.  Prop updates patch the instance inputs;
only the bindings or regions that read changed values re-run.  `:render`
Components retain their documented whole-output behavior, but their output still
patches inside the same retained segment tree.

Lifecycle hooks run after the visible Runtime commit that made their owner
mounted, updated or unmounted.  Hook failures are reported after the commit;
they do not rewind visible Ebox state.  Error boundaries remain explicit
function boundaries around user code.

## 5. Reactive core and commits

`etaf-reactive` provides refs, lazy push-pull computeds, effects, untracked
reads and Scopes.  A write updates the source immediately and marks observers.
Queued effects run in three phases:

1. **pre** watchers;
2. **render** Runtime bindings;
3. **post** watchers.

`etaf-call-with-batch` and `etaf-batch` defer effect delivery until the
outermost batch exits.  Outside a batch, a write drains synchronously.  The
drain calls the Runtime commit function after pre and render effects settle;
post watchers run after the visible commit.

A Runtime commit performs exactly one Ebox batch flush when any of its retained
nodes changed.  Ebox then writes only damaged buffer regions.  The Runtime's
`etaf-runtime-revision` increments once for each commit that changed the
mounted buffer.  `etaf-runtime-flush` drains pending work for a mounted Runtime
when possible and returns that revision.

Each commit is atomic.  While pre and render effects run, every change they
make to retained state is recorded in an undo journal proportional to the work
touched: segment, Host and instance slot writes, Host and instance index
entries, internal prop and row cells, and Ebox node edits.  Objects created in
the same transaction are not journaled; their creation is undone by stopping
them.  Cleanup of replaced committed resources (Behavior installations,
Component Scopes, stopped effects) is deferred until the commit succeeds.  If
a pre or render effect fails, the journal is replayed backwards, new effects,
Scopes and installations are released, and the effects that ran are parked.
The buffer, revision and post watchers then remain as before the update.
Application refs keep their written values.  The next drain with queued work,
or an explicit `etaf-runtime-flush`, re-runs parked effects together with the
new work, so a persistent failure keeps the last committed UI until it is fixed.

Scopes own effects, computeds, watchers and cleanup.  Disposing a Component
Scope stops child Scopes and effects before cleanup runs.  A stopped Scope
cannot accept new work.

A viewport is the region a mounted subtree lays out into.  The mount publishes
the Runtime viewport (`etaf-runtime-viewport`); an `etaf-viewport-region`
wraps its content in one Host whose committed border box becomes the viewport
of every Component placed below it in the render tree.  Regions are indexed
per Runtime by Host reference and republished from the Ebox after-flush hook
with `etaf-host-ref-size`, so readers depend on committed geometry instead of
guessing it.  Resolution follows Component segment ancestors, not Context:
content passed through a slot keeps its caller Context, so a Context value
provided inside a wrapper would not reach it.  Reactive callbacks created in
setup -- watchers, effects and computed getters -- capture their instance's
evaluation context and re-enter it on later runs, so a reader keeps its
Component environment after reactive reruns.

Animation is time in the same graph.  `etaf-transition` and
`etaf-animation-frames` publish values through ordinary refs, so a tick is
one reactive batch, one Runtime commit and one Ebox flush with no second
paint path.  A shared clock exists only while something runs, and a
Scope-owned animation stops with its Scope.  A transition watches its target
and restarts from the displayed value, which makes interruption continuous.

## 6. Ebox retained engine

ETAF creates each Host's Ebox node once at mount or insertion time.  Ebox keeps
that node's style, layout and buffer location until the Host segment is removed.
Host property and text changes are local node mutations.

Ebox provides:

- ECSS-computed styles and Host defaults;
- relayout boundaries, where fixed-size boxes stop layout propagation;
- line composition for row, column, flex, grid and text content;
- direct local writes for changed buffer lines;
- native focus, pointer, keymap, drag and input-session integration.

A text Host contains one text payload.  ETAF validates the payload and stores the
semantic Host props; Ebox owns the display string, image display property,
geometry and interaction facts.  Grid and flex Hosts map to Ebox layout nodes;
ETAF does not duplicate layout algorithms.

Some applications paint a document that lives elsewhere, and editing it in place
needs the way back from painted cells to that source.  `etaf-projection` answers
that as a query: given a Runtime and one `(REF . (SOURCE-START . SOURCE-END))`
entry per Host, it returns runs of `(DISPLAY-BEG DISPLAY-END SOURCE-BEG
SOURCE-END)` computed from the current paint.  It is not a rendering mode, so a
rendering without source ranges pays nothing, and no answer can describe an
older frame.

A run maps one painted cell to one source character.  A range that still holds a
block's trailing line break, or a heading's folded marker, spreads itself over
cells that stand for no character, and every caret after it lands one character
off.  The entries therefore measure a Host's text leaves, not its outer box,
whose bounds also cover padding, borders and the trailing break.  Runs are
half-open: a source offset at a run's end is that run's end position on the
line, and a painted position in the gap between two runs names the start of the
next one, so an edit on a blank line never reaches back into the block above.

## 7. Events, focus and input

Events enter through committed Host references.  The Runtime resolves a Host ref
to its retained Ebox node and handler table, then dispatches the callback inside
an ETAF batch.  Press capture callbacks run through committed ancestor refs.

Ebox owns native targeting, point preservation, focus order, drag tracking and
input sessions.  ETAF translates public operations such as `etaf-activate`,
`etaf-focus`, `etaf-focus-next`, `etaf-call-with-input` and `etaf-input-begin`
into Ebox operations after validating the Runtime and Host reference.
Keyboard activation restores point to the live focus before resolving its
native keymap. The activation relay also covers text-property keymaps, which
can precede emulation maps; a displaced point never selects another control.
Pointer activation keeps its clicked target, and absent focus retains the
ordinary point-based lookup.

`ebox-input-begin` edits a text Host's value in Ebox's hidden editing buffer, so
Emacs owns its keys, point, selection and undo while the Host keeps its layout.
Publications continue during the session: a component mirrors each value into a
ref from `:on-change`, and publishing that same value into the Host is a no-op.

Keyboard input is a scoped key layer in `etaf-keys`.  Each Runtime buffer owns
one emulation keymap holding every event any committed Host lists in `:keys`;
each binding is a menu-item filter that resolves at key time.  Resolution
starts at Ebox focus (or point), or at the Host under the pointer for a
pointer event such as a wheel turn, moves to the innermost visible
`:focus-scope modal` node when the start lies outside it, then walks committed
Host ancestors nearest first and stops after the first modal or
`:key-scope local` Host.  The first
enabled entry wins, except that RET activates a nearer enabled Host with a
press handler before an enclosing Host's RET entry; otherwise framework defaults apply (Escape to the
nearest `:on-dismiss`, `?` to read-only help, arrows to a focused separator or
slider's `:on-drag`), and anything else falls through.  This walk is the only
outward key propagation; ordinary callbacks still do not bubble.  Direction
keys do not fall through to Ebox: `etaf-direction` runs the nearest Host
`:on-direction' handler, then a separator or slider step, then Ebox's spatial
movement limited to the surrounding region, entering the adjacent region's
entry at the boundary; Tab dispatches to `etaf-focus-next'/`etaf-focus-previous'.
`etaf-set-direction-scheme' switches the arrow and Vim mappings after
checking Host declarations and region hints for conflicts.  Ebox owns the
focus those commands move.  Ebox owns
focus groups, modal confinement and spatial arrow navigation, so the key layer
never moves focus itself.  Keyboard drags reuse the pointer `:on-drag` path
through `etaf-drag-step`, so Behaviors keep one gesture implementation.

A local keyboard boundary is derived from the same focus/point ancestry as
key dispatch, not a parallel application-mode state. It bounds dismissal,
direction handlers, region adjacency, help and palette controls as well as
commands. Tab, direction aliases and edge keys delegate to Ebox navigation
with that subtree root; no second ordering or focus algorithm is maintained.
Unbound printing keys and unhandled Escape stop at the boundary. Native
editing keeps its bindings, and pointer or explicit focus/region jumps can
leave a local boundary. A visible modal still bounds entry from outside it.

Region navigation adds one layer above the scoped keys.  `etaf-regions` reads
the committed `:region` declarations (stable id, label, hint key, default
entry and declared neighbors), derives their Host ancestry, remembers the
last accepted focus position of each region and resolves arrow adjacency
from committed geometry when no declared neighbor applies.  `etaf-region-select`
(`M-g` in a Runtime buffer) reads the selection, and `etaf-region-focus`
performs the same jump for application keys; Ebox still owns the focus it
moves.

## 8. Data, Resource and reconciliation

Data is a core ETAF capability.  A Data Source supplies `:load`, optional
`:mutate` and optional `:dispose`.  Data and Resource share async start,
completion, cancellation, timeout and late-result protection.

A Data Controller owns query, pagination, item collection, selection, status,
error and mutation outcome.  Reconciliation states are:

- `reconciliation-pending` while a committed external write awaits reload;
- `reconciled` after the accepted reload succeeds;
- `reconciliation-error` when that reload fails;
- `rolled-back` when the source reports that no external write occurred;
- `external-unknown` when ETAF cannot prove the external result.

External uncertainty never implies local rollback.  Retrying reconciliation
refreshes through the Data Source without repeating a write unless the source
explicitly chooses to do so.

## 9. Application buffers and subprocesses

`etaf-app` is the lifecycle layer above one Runtime: an application is one
named buffer showing one mounted View.  `etaf-app-open` prepares the canvas
(truncated lines, no hscroll, zero margins, a blank truncation glyph, an
optional mode line and cursor), remaps the default face from the
application's theme sources through a detached watch effect, displays the
buffer, runs the application's fit and mounts.  Its record lives in a
buffer-local variable; a `kill-buffer-hook` at negative depth runs the close
function before the Runtime's own unmount hook, so the View is still mounted
while the application persists its state.  `etaf-app-close` releases the
same record before it unmounts and kills, which makes teardown single
whether the user kills the buffer, reopens the name or closes it.

Fitting rides Ebox's viewport task instead of a resize hook per application.
Ebox runs `ebox-display-window-change-functions` after each settled refit
when the display window's identity or body size differs from the last one
delivered, and skips heights lowered by a transient minibuffer or echo
message.  `etaf-app` registers one global function there and on
`ebox-display-change-functions` (text scaling), looks up the buffer's record
and calls its fit in one reactive batch.  A fixed-viewport application
refits from the same callback.

The Runtime and the application are deliberately separate: a Runtime is per
buffer and shared by everything the buffer shows, so the desktop and tests
can mount Views without application lifecycle.  Keys stay on Hosts; an
application's root `:keys` replaces buffer keymaps and emulation maps.

`etaf-process` runs one subprocess per request for applications whose
backends are command-line programs.  Each job owns separate stdout and stderr
buffers, an ignoring sentinel on the stderr pipe and an optional timer.
Settlement drains both pipes with a zero timeout after the exit event,
because the stderr pipe can deliver after the exit; it then rechecks whether
a timeout or cancellation finished the job while draining.  Delivery is
idempotent and cancellation marks the job settled before deleting the
process, so the callback runs at most once and never after a cancel.
Protocols stay in each application's service layer.

## 10. Retained Host update boundaries

`etaf-runtime-update-host-content` and `etaf-runtime-update-host-contents` are
public escape hatches for high-frequency display surfaces such as video.  They
validate all Host refs first, then set the retained text nodes in one Ebox batch
and increment the Runtime revision.

`etaf-runtime-update-host-geometry` and `etaf-runtime-update-host-geometries`
perform the same retained boundary for Ebox geometry facts such as position,
size and layer.  They patch the Host node directly and leave authoritative
application state with the caller.  The caller should update its own refs first
so the next ordinary View binding agrees with the display.

`etaf-runtime-refit` updates the mounted viewport through
`ebox-mount-set-viewport`.  Viewport changes are Ebox layout work; ETAF does not
recreate the View tree to resize the buffer.

## 11. Invariants

1. **Single retained ownership.** A mounted Runtime owns the application
   segments and at most one transient help segment over one retained Ebox node
   tree. Host/node maps index those segments, not a second authority.
2. **One visible write boundary.**  A Runtime commit performs at most one Ebox
   flush, and that flush writes changed buffer regions once.  A failed pre or
   render effect discards the whole transaction before any buffer write.
3. **Binding ownership.**  Each fine-grained binding owns exactly one Host node
   property set, one text payload or one dynamic child region.  It may read many
   reactive sources but may patch only its own target.
4. **Keyed identity.**  A stable key preserves the segment, Component Scope,
   Host ref and Ebox node.  A missing or changed key disposes the old owner.
5. **Scope ownership.**  Effects and cleanups belong to their Scope.  Disposal
   stops reactive work before releasing external resources.
6. **No rendering side effects.**  Rendering and binding evaluation must not
   write application state.  Writes belong in events, Actions, watches, Effects,
   Data/Resource completions or explicit batches.
7. **Ebox authority.**  Layout, focus, native input and buffer text are queried
   from Ebox.  ETAF exposes public adapters but does not maintain parallel
   copies of those facts.
8. **Public boundary.**  Applications and catalog Components use ETAF public
   APIs only.  Ebox-prefixed calls stay inside ETAF or Ebox-owned packages.

## 12. Rationale

The retained design records dependencies when structure is created.  A state
write follows the dependency edge to the binding that owns the affected node,
then Ebox updates only the damaged layout and buffer lines.  This removes
whole-tree recomputation from ordinary text, style and geometry changes while
preserving the declarative View syntax.

Keeping Ebox as the only layout and buffer engine prevents duplicate geometry,
focus and input state.  Keeping Components as the only reusable ETAF UI unit
prevents parallel widget/control models.  Keeping Data and Resource above the
same reactive batch boundary lets async completions, event callbacks and local
state writes publish through one visible commit path.

When a new capability is needed, extend the smallest owner that already owns the
relevant facts: Ebox for layout and native input, ETAF Runtime for public Host
lifetime, reactive Scopes for dependencies, Data/Resource for requests, or
Components for reusable composition.
