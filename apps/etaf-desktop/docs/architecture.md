# ETAF Desktop architecture

ETAF Desktop is the top application layer in the ETAF ecosystem.

- **Ebox** owns measured geometry, overlap, z-index rendering, hit testing and
  incremental buffer updates. It supplies the retained gesture phases.
- **ETAF** owns reactive application state, fine-grained Host bindings,
  Component lifecycle and event batching.
- **ETAF UI** owns the reusable controlled `etaf-window` and
  `etaf-resizable-panel` presentation components. They expose title-bar and
  resize gestures but retain no window policy.
- **ETAF Desktop** owns window records, workspaces, focus and z-order policy,
  restore rectangles, taskbar projection and the mounted application surface.

Window membership, workspace selection and lifecycle metadata are published
through a structural ETAF ref. Each retained window owns authoritative refs
for its position, size and z-index; active window identity has its own ref.
The window record stores those sources, and public queries derive detached
numeric snapshots from them. There is no second geometry cache to reconcile.
The saved normal rectangle is separate lifecycle state for maximization.

Structural operations validate detached candidates, retain the existing
windows' scalar sources and publish the resulting membership and scalar
changes through ETAF's public batch boundary. Ordinary floating moves and
resizes write the existing scalar sources directly after validating geometry
and bounds. They do not copy the complete desktop or rerun layout allocation.
Structural publications prepare reusable geometry and focus writers with
private invocation storage. Floating mutations reuse those writers and the
record's normal rectangle; public snapshots still return detached copies.
ETAF batches the coordinated fields so observers see the completed geometry
and focus change. A failed update leaves application writes queryable and
the buffer showing the last flushed windows and targets.

The desktop View depends on structural membership and workspace selection.
Window geometry sources pass directly through the public `etaf-window` props
to their Host property bindings. Ebox's z-index owns paint order, so moving or
raising a window does not require sorting and rebuilding the Component tree.
Workspace controls, taskbar and switcher project focus in separate Components;
each window's traffic lights consume a derived focus value. No Ebox node,
private ETAF Runtime table or private ETAF UI module is used by consumers.

The retained taskbar and workspace Components derive selection and status as
computed values and pass them directly to ETAF UI's Host property and Text
bindings. Membership, grouping and lifecycle changes construct the bar items
and callbacks; changing window focus keeps those items and callbacks retained.

A desktop window's public identity is its stable application ID. The rendered
Host refs are derived from that ID only for Ebox/ETAF target retention; they are
not a second state store. Playground packages may demonstrate this package but
do not own any of its policies.

The component records its enclosing Runtime for event dispatch, but ownership
follows the mount entry: `etaf-desktop-mount` owns the Runtime it creates;
`etaf-desktop-view` embedded in another application borrows that Runtime. The
caller unmounts the enclosing application. An existing target buffer remains
caller-owned in either case.

An application embeds a desktop View in one of its windows, so a buffer can
host several desktops: the enclosing one and every nested one. Window fitting
is a buffer-local set of those desktops rather than a single owner, so a
nested desktop neither takes the enclosing desktop's refit nor loses it on
unmount. Each desktop still decides its own geometry: an explicit canvas keeps
the dimensions it was created with, a desktop without one follows the Emacs
window, and `:fit 'region'` fills the viewport region of the window it is
rendered into. The region path is the same reactive read a normal application
view uses for its size, so maximizing or resizing the hosting window reflows a
nested desktop instead of leaving it at its creation size. The shell's size
properties read the fitted canvas cell before any explicit canvas override, so
every binding subscribes to it: a region-fitted desktop starts with the canvas
it was created with and only later learns its surface size, and a binding that
short-circuited on the creation size kept the workspace bar, canvas and
taskbar at that size until an unrelated re-render.

Window IDs of application instances are `<token>/<instance-id>/<window-id>`, and
the desktop's own controls are `<token>-<name>`. The per-desktop token exists
because ETAF resolves keys, retained updates and focus by Host reference within
one Runtime: two desktops mounted in one buffer would otherwise intern the same
names for their bars, launcher entries and dialogs, and a press on the outer
level's control would reach the inner one. Callers that open windows directly
keep their own IDs and are responsible for uniqueness within the buffer. The
token is part of the state snapshot so callers and logs can compute a
reference and tell which level it belongs to.

A desktop without explicit dimensions fills its Emacs window.
`etaf-desktop-fit-canvas` measures the display window, writes the retained
canvas-size cell and reflows workspaces, maximized windows and floating
windows in one batch; the default canvas takes the window body's full pixel
width rounded down to the character grid, so no window background shows beside
the last column.  `etaf-desktop-mount` schedules one fit once the display
settles and `etaf-desktop-close` cancels it.  Lines borrowed by a transient
minibuffer are not a resize: the committed canvas stays until the prompt
closes.

## Application host boundary

The application registry is a separate policy layer above window geometry.
Each manifest identifies an application, declares its capabilities and
provides optional open, close, serialize and restore callbacks. A manifest is
not an application instance: one manifest may have multiple instances, each
with its own lifecycle state, caller-owned View values, options and window
IDs. Instance status transitions are observable as `launching`, `active`,
`inactive`, `suspended`, `closing`, `closed` or `error`.

`etaf-desktop-launch` creates instances and routes callback failures into an
error placeholder. Closing always releases the instance's windows even when a
close callback fails. Focus policy marks the previously active instance
inactive; suspend and restore operate on all windows belonging to one
instance. These rules isolate one application failure from the mounted
desktop and other applications.

Session state contains desktop geometry, workspaces, window state and instance
options. It also records each workspace's layout mode, detached tree, split
orientations/ratios and floating membership. Application-owned data enters the
session only through the manifest's serialize callback; View and Runtime objects
never enter the persisted value. Restore invokes the registered restore callback,
reapplies saved window state, then validates and reapplies each saved workspace
layout. An unavailable application becomes an error placeholder, while a
low-level window without an application manifest is recreated with a title
placeholder because its caller-owned View cannot be serialized. Older sessions
without layout records continue through the existing window-only restore path.

## Settings and shell composition

Desktop settings are stored in one controller-owned reactive plist and are
serialized with the desktop snapshot. The mounted shell projects that value
through ETAF UI Components: the workspace bar exposes a settings action and
`etaf-dialog` renders the form as a retained root-layer panel. Desktop chooses
the unpainted modal variant so the underlying application windows remain
visible; the reusable UI component retains its normal painted backdrop for
other modal callers. The form groups controls into Appearance, Layout,
Behavior and Shortcuts tabs within a compact panel. Unspecified title and
content sizes stay nil through the controlled shell and inherit through the
shared style cascade; the desktop does not copy the current frame size into
settings. Explicit sizes remain CSS reference pixels and apply independently
to title and content. When both are explicit, the positioned host uses their
maximum for the shared line-height basis; if either inherits, the host retains
its inherited basis so one override cannot impose a size on the other region.

The Settings panel retains its tab row and footer while a structural View
expression replaces the active field grid. Section-dependent dialog height,
tab variants and hint text have their own reactive property expressions;
changing a tab does not reconstruct the surrounding Desktop View or its
callbacks. Only the active section's fields are mounted. Closing releases the
dialog and field controls while the panel's selected section remains available
for the next opening; field values always come from the controller.

The settings form owns only policies already supported by the application:
theme/accent presentation, typography, tile spacing, resize and locked-drag
behavior, taskbar grouping, close confirmation, and keyboard actions. Session
restore remains the explicit public save/restore workflow. Keyboard actions are
the shell root's ETAF Host `:keys`, computed from the keybindings setting, so
only a binding change re-renders the shell; ETAF scopes them to the Desktop
buffer, lets focused application content override them and suspends them under
modal dialogs. Window cycling raises the target before moving keyboard focus
into it, because a covered window exposes no focus stops; the window's
focus-enter handler performs the same activation as a pointer press. Traversal and neighbor selection use
visible window membership in stable opening order, independently of mutable
paint order. Swapping tiled windows changes leaf identities in the authoritative
layout tree; changing their rectangles alone would be overwritten by allocation.
The close shortcut and chrome use the same confirmation request path.

The layout allocator converts the controller's cell-based spacing settings to
horizontal pixel widths and vertical text rows. It first insets the canvas by
the outer gap, reducing that inset where pane minimum sizes need the space.
Each split then allocates two pane rectangles and an inner gap, with a minimum
horizontal gap target sufficient for the three-pixel divider. An undersized
subtree reduces gaps and pane sizes while reserving space for its descendant
panes where the canvas permits. The same partition feeds window geometry and
the reusable ETAF UI splitter's `:overlay-rect`; three-pixel or one-row handles
are centered inside their allocated gaps, shrink with the gap and disappear
when it reaches zero. Nested dividers render as separate canvas overlays, each
limited to its subtree. Monocle computes its inset from the largest leaf
minimums on each axis because retained splits consume no space in that mode.
Spacing changes refresh the active workspace through the existing layout
publication path and persist in the settings snapshot. Window records remain
authoritative for their rectangles; the splitter owns only presentation and
gestures. A divider retains both the requested ratio for cancellation and the
allocated first-pane extent for pointer motion. This separates size-constrained
geometry from user intent without a second layout authority. Master-stack
refresh retains existing ratios; membership additions rebuild the stack while
preserving the master width ratio.

Divider rectangles, content and visibility are retained reactive sources;
orientation is a scalar ETAF UI Component prop. Adding a divider or changing
an existing path's orientation republishes the shell in the same batch as
its allocated geometry, so labels and pointer semantics describe the new axis.
Ordinary ratio changes keep the existing presentation and update its sources.

A layout mode transition updates policy and window geometry in one Desktop
state publication. It clears temporary maximization before allocating the new
rectangles; ordinary tiling refreshes preserve a maximized window's full canvas
view while continuing to maintain the other layout leaves.
