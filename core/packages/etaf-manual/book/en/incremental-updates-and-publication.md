# Incremental Updates and Publication

A mounted tree and its buffer are two representations of the same content: the tree is the source of truth, the buffer is output. Between a mutation and the buffer lies one flush — a single pipeline that restyles what changed, relayouts it inside its boundaries, turns the result into line replacements and writes only those lines. This chapter describes that pipeline: the node mutation API, batching and flush, the dirty bits behind them, the eight steps of a flush, relayout boundaries, painting and its caches, how the buffer is written, the reports observers receive, what happens when the buffer is edited from outside, and the invariants the whole mechanism keeps. [Runtime](runtime.md) describes how ETAF batches and publishes on top of this machinery; [Rendering Model](rendering-model.md) the retained tree it starts from.

## Node mutations

<!-- index: node mutation; author properties; text content; structural change -->

Every mutation marks the changed nodes and queues their mount; outside a batch, each call flushes once before returning, so a single edit is visible immediately.

#### Function: ebox-node-put (node key value)

Set NODE's author property KEY to VALUE.

**Arguments.** KEY is an author property keyword; VALUE is any value the property accepts.

**Semantics.** The property list is copied, the key is replaced or appended, and the result goes through `ebox-node-set-props`. Use it for one property; `ebox-node-set-props` replaces the whole list and is what a re-render normally calls.

**Returns.** NODE.

**Errors.** A value the property rejects arrives through the same validation as `ebox-node-set-props`.

**See also.** `ebox-node-set-props`, `ebox-node-restyle`.

#### Function: ebox-node-set-props (node props)

Replace NODE's author properties with PROPS.

**Arguments.** PROPS is a plist of author properties, or nil to clear them.

**Semantics.** An equal list is a no-op. Otherwise the properties are reinstalled; the node's scroll offset is preserved, and the change is classified: a change confined to style properties repaints the node, while a change to a structural or interaction property relayouts it. The classification matters because most visual updates are of the first kind.

**Returns.** NODE.

**Errors.** Malformed properties or values signal `ebox-error` with the property named.

**See also.** `ebox-node-put`, `ebox-node-restyle`.

#### Function: ebox-node-set-text (node string)

Set text NODE's content to STRING.

**Arguments.** NODE is a text node; STRING is its new content, which may be empty.

**Semantics.** Equal text — comparing properties too — is a no-op, so setting a value the node already shows costs nothing. Otherwise the payload is replaced and the node is marked for layout, because a different string can break into different lines. While a native input session edits this node, the session owns the value; setting it from outside replaces what the session shows.

**Returns.** NODE.

**Errors.** A non-string or a node that is not a text node signals an error.

**See also.** `ebox-node-put`, `ebox-node-set-image`.

#### Function: ebox-node-set-image (node image)

Set image NODE's prepared IMAGE.

**Arguments.** IMAGE is a value returned by `ebox-image-prepare`.

**Semantics.** The prepared raster is replaced and the node is marked for layout, because a different image has a different line count and width. Preparation stays outside this call: the value was already decoded and converted when it was prepared, so replacing an image costs no I/O.

**Returns.** NODE.

**Errors.** None; a malformed value surfaces when the node is laid out.

**See also.** `ebox-image-prepare`, `ebox-node-set-text`.

#### Function: ebox-node-set-states (node states)

Set NODE's author selector STATES, a list of symbols or strings.

**Semantics.** States feed state selectors such as a rule written for `&:on`. Values are normalized to names, so symbols and strings are interchangeable; an unchanged set is a no-op and a changed one marks the node for restyling only, never for layout.

**Returns.** NODE.

**Errors.** None.

**See also.** `ebox-node-restyle`, `ebox-node-set-props`.

#### Function: ebox-node-restyle (node)

Recompute NODE's style after derived selector state changed.

**Semantics.** Some state a selector can match is derived rather than declared — hover and focus are the built-in examples — and a caller that changes the source of a derived state asks for the recomputation instead of marking a property. The node is marked for restyling; the next flush recomputes its style and repaints it if nothing geometric changed.

**Returns.** NODE.

**Errors.** None.

**See also.** `ebox-node-set-states`.

#### Function: ebox-node-insert (parent child &optional index)

Insert detached CHILD into PARENT at INDEX (default last) and return CHILD.

**Arguments.** CHILD is a node or a string, which becomes a text node. INDEX is the child position; nil appends.

**Semantics.** The child must be detached. When the parent is already laid out and can absorb the insertion, the change is recorded as a structural operation at a position, so the flush shifts the following lines instead of relaying out the whole parent.

**Returns.** CHILD.

**Errors.** A child with a parent, a text parent, or an unknown tag signals `ebox-error`.

**See also.** `ebox-node-remove`, `ebox-node-move`.

#### Function: ebox-node-remove (node)

Detach NODE from its parent and return it.

**Semantics.** The node's subtree forgets its mounted layout and computed-style context, so the same node can be inserted again later, and a laid-out flow node records a structural removal with its position and height, letting the flush close the gap incrementally. Overlays inside the subtree that were hosted outside it vacate their lines. Reattachment rebuilds style context and overlay hosting throughout the subtree, even when the inherited values have not changed; node identity, author properties and scroll offsets survive.

**Returns.** NODE.

**Errors.** A node without a parent is returned unchanged; a non-node signals `wrong-type-argument`.

**See also.** `ebox-node-insert`, `ebox-node-replace-children`.

#### Function: ebox-node-move (node index)

Move NODE to INDEX among its siblings.

**Semantics.** A no-op when the node is already at that index. A laid-out flow node records a removal and an insertion, so the container updates by shifting lines rather than rebuilding. A root node cannot be moved.

**Returns.** NODE.

**Errors.** Moving a root or a non-node signals an error.

**See also.** `ebox-node-insert`, `ebox-node-remove`.

#### Function: ebox-node-replace-children (parent children)

Replace PARENT's children with CHILDREN, reusing nodes already present.

**Arguments.** CHILDREN is a list of nodes and strings; strings become text nodes.

**Semantics.** Nodes already among the parent's children keep their identity and layout state, new ones are marked fresh, and removed ones forget their mounted layout and style context. This is the primitive behind list reconciliation: identity is what lets a row keep its state across a re-render. The parent is relayouted as a whole.

**Returns.** PARENT.

**Errors.** A duplicated child, a child owned by another parent, or a text parent signals `ebox-error`.

**See also.** `ebox-node-insert`, `ebox-node-remove`.

## Batching and flush

<!-- index: batch; flush; queue -->

#### Macro: ebox-with-batch (&rest body)

Run BODY as one update batch; flush queued mounts when it ends.

**Semantics.** Mutations inside the batch only mark and queue; the outermost batch flushes once when it finishes, including when it exits nonlocally, so an error still publishes everything that was marked. Batches nest: only the outermost one flushes.

**Returns.** The value of BODY.

**See also.** `ebox-call-with-batch`, `ebox-flush`.

#### Function: ebox-call-with-batch (function)

Call FUNCTION as one update batch and return its value.

**Semantics.** The function form of `ebox-with-batch`, for a callback whose body cannot be wrapped in a macro.

**Returns.** FUNCTION's value.

**See also.** `ebox-with-batch`.

#### Function: ebox-flush ()

Bring every queued mount's buffer up to date.

**Semantics.** Each queued mount is flushed once; a mount with no damage and no dirty root is skipped without writing, which is why the flush count only counts flushes that published something. Flushing is not reentrant: a flush triggered from inside a flush is ignored, and mutations made during one are queued for the next. Outside batches and hooks, callers do not need this function; Ebox settles automatically.

**Returns.** Nil.

**Errors.** None.

**See also.** `ebox-after-flush-functions`, `ebox-mount-flush-count`.

## Dirty bits and the queue

<!-- index: dirty bit; dirty path; structural operation -->

Marking a node sets bits that say what kind of work it needs. Style bits mean the computed style must be recomputed; layout bits mean geometry may change; paint bits mean only the pixels change. A mark also walks the path to the root, clearing each ancestor's cached intrinsic size and listing the child below it among the dirty children, so the style pass and the layout pass can descend only into the paths that lead to changes. An ancestor already known dirty stops the walk. Structural operations — an insertion, a removal with its position and height — are recorded on the parent instead of as a flag, because layout needs the position to shift lines rather than recompose them.

The mount is queued once no matter how many nodes were marked, and the queue is drained by the outermost batch or by the next settle point.

## The flush pipeline

<!-- index: flush pipeline; damage; line replacement -->

A flush runs one pipeline over the queued mount. First it takes the mount's viewport and the damage recorded since the last flush and decides whether there is work at all. The style pass recomputes the computed style of the dirty path; a node whose inheritance key and environment are unchanged descends only into its dirty children, and a change that leaves the layout-relevant values identical marks the node for repaint instead of layout. Layout then relayouts the dirty subtree inside its structural boundaries, using the recorded operations to shift lines where it can. Anchored overlays are placed again, because their targets may have moved.

The damage collected during layout is then pruned — a whole-node change absorbs the smaller ranges inside it — and the composed lines of every damage owner are dropped from the cache. What remains is converted to ordered line replacements, `(START OLD NEW)`, where START counts lines after the preceding replacements have been applied. If the changes cannot be expressed as ordered replacements — two ranges that overlap in incompatible ways — the flush falls back to rewriting the whole buffer. Otherwise it writes exactly the replaced lines, increments the flush count, stores the report, calls the observer, syncs the buffer background to the root's color, and runs the after-flush hook.

## Relayout boundaries

<!-- index: relayout boundary; partial relayout; intrinsic size -->

Layout tries to change only what the change can reach. A vertical stack absorbs a child's height change by shifting the later items and damages only the child's lines and a bounded tail; horizontal containers, flex and grid containers, overlay hosts and anything whose children's participation changed relay out their children completely, because one item's size can move every other. A node that gains or loses absolute positioning moves between hosts. Untouched subtrees reuse their layout records, intrinsic sizes, wrapped paragraphs and composed lines, so a change at the bottom of a long list does not touch the top.

A stationary overlay can also keep its inner line replacements when its position, size and stacking order are unchanged and the host's flow has not shifted. This applies only to equal-height replacements within the overlay and root bounds. Internal insertions or deletions, escaping ranges, movement and reordering retain the bounded whole-coverage path: changing overlay content must not insert or delete rows in the surrounding buffer. Full host layout still repaints its overlays.

The boundary is what makes increments incremental: the pipeline visits dirty paths, and each container decides whether it can absorb the change or must lay its children out again.

## Painting, caches and display twins

<!-- index: painting cache; composed parts; display twin -->

Composition turns a node's line into a flat list of strings — margins, borders, padding, content and overlays spliced in — and caches that list on the node, up to a bounded number of lines; a paragraph caches its wrapped lines instead. The strings are shared and immutable, so a line that did not change is reused by identity, and their pixel widths are memoized. Dropping a cache only happens along the chain from a damage owner up through the nodes that actually composed it.

One graphical subtlety is that Emacs draws two consecutive characters once when they carry the same `eq` display value. That would collapse runs of one emoji or one image slice, so composition alternates between two equal but distinct display objects for repeated values; the buffer keeps exactly the object the composed line used. Attribute comparison uses a value-aware comparison that treats faces by value and display values by identity, so unchanged rows compare equal without descending into the tree.

## Writing the buffer

<!-- index: line anchor; part comparison; position preservation -->

Every new mount first replaces the whole destination buffer, even if its tree already has layout from rendering or a previous mount; line coordinates belong to that mount's own publications, not to the tree's layout alone. Whole-buffer publication inserts composed parts directly without building temporary concatenated lines. When the whole root fits the existing per-mount bound, it records the parts there for the next update. Larger roots leave those slots for subsequently changed rows instead of occupying them with the first static rows; there is no additional cache. Writing is incremental at three levels. Lines are located through sparse markers every 128 lines, so finding the first line of an edit costs a binary search plus at most a short walk, and markers after an edit are shifted rather than rebuilt. Corresponding old and new lines are updated in place. Within a remembered line, identical shared string parts at either end are skipped without copying or comparing their contents. Only the remaining span is diffed: its common character prefix and suffix stay in place, and only differing property runs are set. A property-only repaint therefore keeps the characters and native markers within them, while a local text edit preserves markers in its unchanged prefix and suffix. A single changed part, or several parts with aligned character boundaries, use the remembered strings directly without concatenating them or copying buffer text; identical interior parts also skip writing. An unremembered line uses the same character and property comparison over the whole line. Faces compare by value, but display and input objects retain their composed identities, so equal display twins do not collapse and replacement keymaps are not confused with retired ones.

Positions are preserved per line and column: point, the window point and the window start are tracked when they fall inside the replaced lines and moved with their text, while positions in untouched lines move with their text naturally. Newlines receive the `:extend` face of the cell before them, so a box's background continues to the window's right edge, and the same newline bridges hover feedback across the rows of a multirow element. Writes run with read-only checks, undo recording and modification hooks suppressed, and restore the buffer's modified flag afterwards.

## Reports, observers and hooks

<!-- index: update report; observer; after flush -->

#### Hook: ebox-after-flush-functions

Abnormal hook run with each mount's buffer after a flush wrote it.

**Semantics.** It runs once per flush that actually published, after the observer and after the background sync, with the buffer as its only argument. It is the place for work that must see the new committed buffer but must not itself be part of the flush; a scroll or measurement done here sees settled geometry.

**Returns.** The hook value is ignored.

**Errors.** An error in one function does not prevent the others from running.

**See also.** `ebox-flush`, `ebox-viewport-change-functions`.

#### Function: ebox-buffer-set-observer (buffer-or-name observer)

Call OBSERVER with the buffer and a report plist after each flush.

**Arguments.** OBSERVER is a function of two arguments, or nil to remove observation.

**Semantics.** The report describes what the flush wrote: `:provider` (always `ebox`), `:strategy` (`lines` or `full`), `:edits` (the number of ranges), `:lines` (how many lines those ranges wrote in total), `:ranges` (the `(START OLD NEW)` replacements in application order), `:flush` (the mount's flush counter) and `:duration-ms`. The observer receives a copy and must not mutate the tree; it exists for metrics and instrumentation.

**Returns.** Nil.

**Errors.** A buffer without a mount signals `user-error`.

**See also.** `ebox-buffer-update-report`, `ebox-mount-flush-count`.

#### Function: ebox-buffer-update-report (&optional buffer-or-name)

Return a copy of the report of BUFFER-OR-NAME's latest flush, or nil.

**Semantics.** The mount keeps its latest report, so an application can ask after the fact instead of observing every flush. The report describes the same flush an observer would have received; `:duration-ms` is present when that flush was timed through an observer, while a flush run without one stores only its raw line ranges and the reader materializes the report without timing. The value is a fresh copy each call.

**Returns.** The report plist, or nil before the first flush.

**Errors.** A buffer without a mount signals `user-error`.

**See also.** `ebox-buffer-set-observer`.

#### Function: etaf-runtime-update-report (&optional runtime)

Return the last buffer update report of mounted RUNTIME, or nil.

**Semantics.** The plist is the engine's flush report for the last commit, the same report `ebox-buffer-update-report` returns for the Runtime's buffer: its strategy, edited range count, line count, ranges and flush counter. Applications read it to observe that a retained update rewrote changed rows instead of the whole buffer.

**Returns.** The report plist, or nil before the first flush.

**Errors.** A non-mounted Runtime signals `etaf-runtime-error`.

**See also.** `ebox-buffer-update-report`, `etaf-runtime-revision`.

#### Error: etaf-observer-error

Invalid ETAF observer operation. It is signaled when observer context state is constructed or used with an invalid value, such as a sink that is not a function or an identity that is not an integer. Catch this condition with `condition-case`; failed calls do not return a value. Its parent condition is `error`, and its data is a list of symbols describing the violation.

| Data | Cause |
| --- | --- |
| `(Observer sink must be a function)` | A report sink that is not callable |
| `(Operation identity must be an integer)` | A non-integer operation identity |
| `(Runtime identity must be an integer)` | A non-integer Runtime identity |
| `(Buffer name must be a string or nil)` | A buffer name that is neither |
| `(Diagnostic sink must be a function)` | A diagnostic sink that is not callable |
| `(Invalid observer context)` | Operating on something that is not observer context |
| `(Observed operation must be a function)` | Running a non-function as an observed operation |

An observer installed through a mount's `:observer` option receives an observed-operation snapshot rather than the bare Ebox report: a format version, the operation and Runtime identities, a per-operation sequence number, the buffer name, the provider reports — the Ebox flush report above among them — and a status. Observer errors and quits are contained: they are reported to the diagnostic sink and never reach the code being observed, so instrumentation cannot break rendering.

## Recovery from foreign edits

<!-- index: foreign edit; buffer divergence; tick -->

A mounted buffer is not read-only; Ebox only suppresses undo and modification hooks while it writes. An edit from outside — a program inserting text, a user typing in a buffer whose mode was turned off — makes the buffer disagree with the tree. Ebox does not detect and repair that on the spot, because there is no tree-side record of the edit to apply.

What happens is deterministic: the next flush that writes the edited line replaces it with the composed content, so the foreign edit disappears exactly where the tree drives a change; lines the flush does not touch keep whatever they contain. The remembered per-line strings are dropped when the buffer's modification tick says someone else wrote it, so the next writes compare against the real buffer instead of stale parts. Rewriting the whole buffer — the first flush or a full damage — restores every line. Applications that must accept editing should model it in the tree, as the native input sessions do.

## Invariants

<!-- index: invariant; source of truth; incremental guarantee -->

The mechanism is defined by a small set of invariants. The retained tree is the single source of truth and the buffer is output. After a flush, every line the damage covered equals the tree's line, and the buffer's line count equals the root's height. Changes reach the buffer only through damage, so the damage must cover everything that changed and nothing else. Untouched lines are not rewritten, untouched subtrees are not relaid out. A batch flushes once, no matter how many mutations it contains. Flushing is not reentrant. Observers observe; they never change what is published.

Those invariants are what allow the pipeline to skip work: any line not reported as damaged is assumed to still match the tree, which is also why foreign edits survive until an update reaches their line.

## Errors and recovery

<!-- index: update errors; malformed mutation; stale buffer -->

Mutation errors are reported when the call is made: a malformed property, a node of the wrong kind, a child that already has a parent, a root that cannot move. They leave the tree unchanged, so a failed mutation never publishes half an update; batching plus Ebox's own containment means a mutation that throws inside a batch still flushes everything marked before it.

Two situations look like bugs but are not. A flush that reports no edits wrote nothing because nothing relevant changed; the flush counter does not advance. A line that differs from the tree was edited from outside and has not been reached by an update yet; the next update that covers it puts the tree's content back. When neither explanation fits — the buffer and the tree disagree on a line no one edited — the update report, with its exact ranges, is the place to look.
