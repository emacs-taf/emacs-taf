# The Core Records

Every mechanism in this part operates on a small set of records that live as long as the thing they describe: a mounted View is a tree of retained segments, a retained segment owns an Ebox node, a node owns a computed style and a layout, and a mount binds one root to one buffer. This chapter collects those records in one place, record by record, and lists what each one holds and how a program can read it. It defines no interfaces; the readers it names are defined where their chapters define them.

## Records and readers

<!-- index: record; reader; opaque handle -->

The records differ in how much of themselves they expose. Some are opaque handles: a program receives the object, keeps it, passes it back to other functions and compares it by identity, but never reads its fields directly. The mount of a buffer and a Component instance record are like that. Others publish readers for the facts a consumer legitimately needs. The tables below therefore have three columns: the field in the record, what it means, and the public interface that reads it — or a dash when this version exports no reader and the field is visible only through behavior.

A record is created when its owner is created and disposed with it. Segments and their Ebox nodes are created at mount or insertion and retained while their identity lasts; a node's computed style and layout are replaced in place as the node changes; a paragraph record is cached and evicted by policy; a mount lives from `ebox-mount` to `ebox-unmount-buffer` or the death of its buffer. Nothing in this chapter adds a second source of truth: every field is owned by exactly one record, and the readers hand out snapshots or read-only views.

## The retained segment record

<!-- index: retained segment; keyed identity -->

A mounting Runtime turns the View into one retained segment tree. A segment records the View node it was instantiated from, its kind (a Host, a Component, a fragment, an expression, a branch, a list, a slot or the root) and, among siblings, its key. It holds the links to its parent and children, the single reactive effect that maintains its dynamic content, and its lifecycle state — new, mounted, updated or removed.

| Field | Meaning | Read by |
| --- | --- | --- |
| Source View node | The structural form this segment was created from | — |
| Kind | Host, Component, fragment, expression, branch, list, slot or root | — |
| Key | Identity among siblings | Keyed identity governs retention; see [Views](views.md#identity) |
| Parent and children | The retained tree shape | Host content and queries through ETAF; Component counts through `etaf-runtime-instances` |
| Binding effect | The one effect that patches this segment's own Host node property, text payload or child region | — |
| Lifecycle state | Whether the segment is mounted, updated or being removed | `etaf-on-mounted`, `etaf-on-updated`, `etaf-on-unmounted` |

The identity rule is the important part of this record. While a segment's kind and key continue to match, it keeps its identity, its Component instance and its Ebox node, so an update patches the existing node instead of replacing it. A changed or missing key disposes the old segment and everything it owns, and the next update builds a new one.

## The instance record

<!-- index: component instance; prop cell; setup scope -->

Each live Component has one instance record, created when the Component is first published and disposed when the Component is removed. Its fields are the identity (definition and key), one reactive cell per declared prop, the current call with its resolved slots, the Scope created for setup, the state or named binding values, the retained rendered View, the effect that re-runs the frontend on prop changes, the registered lifecycle hooks, and the bookkeeping flags the Runtime uses to publish and retire it.

| Field | Meaning | Read by |
| --- | --- | --- |
| Identity | Definition plus the call's `:key` | The Runtime's instance table: `etaf-runtime-instances` |
| Prop cells | One reactive cell per declared prop | Prop bindings and `etaf-prop`; `etaf-current-prop` inside the frontend |
| Call and slots | The current call and its resolved slot contents | Slot access inside the Component |
| Setup Scope | The Scope owning the instance's effects and cleanups | Disposal behavior; `etaf-on-scope-dispose` |
| State or bindings | Setup state, or the named binding values | `etaf-state` for setup state; the binding names directly |
| Rendered View | The retained output of the frontend | — |
| Input effect | Re-runs the frontend when a prop cell changes | — |
| Lifecycle hooks | Mounted, updated and unmounted callbacks | `etaf-on-mounted`, `etaf-on-updated`, `etaf-on-unmounted` |
| Bookkeeping | Publish and retire flags | — |

[Components](components.md#the-instance-record) describes how an instance initializes and updates, and [Runtime](runtime.md) the table that holds every live instance for introspection. The record itself is opaque: comparing identity, counting instances and checking that an update reused one is what the table is for.

## The node record

<!-- index: ebox node; author identity; retained content -->

Every Host segment owns exactly one Ebox node, created when the Host is inserted and released when it is removed. The node record is the largest of the set: it holds the author and selector facts (tag, id, classes, attributes, states, key, user data), the compiled declarations, default rules and ECSS scopes that style it, the interaction properties, its content, its parent and children, its computed style and layout, its caches and its dirty state.

| Field | Meaning | Read by |
| --- | --- | --- |
| Author and selector facts | Tag, id, classes, attributes, states, key, user data | Author properties; ETAF Host semantics through `etaf-runtime-host-props-for` and `etaf-runtime-host-props-entries` |
| Style inputs | Compiled declarations, default rules, local and shared ECSS scopes, active environment | `ebox-node-set-props`, `ebox-node-restyle`; [Styles Implementation](style-implementation.md) describes the pass |
| Interaction facts | Help, pointer, hover, keymap, tab index, focus group, focus scope, disabled state | Host properties; focus and pointer queries |
| Content | One text payload, or a prepared image | `ebox-node-text-p`, `ebox-node-set-text`, `ebox-node-set-image` |
| Parent and children | Tree links, stored as chunked child sequences | `ebox-node-parent`, `ebox-node-children`, `ebox-node-child`, `ebox-node-child-count`, `ebox-node-index` |
| Computed style | The computed style record, shared when local inputs are equal | The readers of the next section |
| Measurement and layout caches | Measured text, intrinsic sizes, the last layout | Through geometry and bounds; the caches themselves have no readers |
| Dirty state | Dirty bits, dirty children, structural operations, overlay registration | Observable through flush behavior; [Incremental Updates and Publication](incremental-updates-and-publication.md) |
| Scroll and mount pointer | The node's scroll offset; on a root, the owning mount | `ebox-node-scroll-offset`, `ebox-node-set-scroll`, `ebox-node-scroll-into-view`, `ebox-node-buffer` |

The tree readers also give the shape-independent queries: `ebox-node-root`, `ebox-node-ancestor-p`, `ebox-node-walk` and `ebox-node-buffer`. A node can be compared and traversed without reading any internal field, and every mutation goes through the public mutation functions listed in [Incremental Updates and Publication](incremental-updates-and-publication.md).

## The computed style record

<!-- index: computed style record; hash consing; provenance -->

The computed style record is the normalized result of the cascade for one node: the full set of resolved values plus the facts the layout needs. It is built from the ECSS computed values, the parent style and the node's tag, and equal local inputs share one object, so geometry comparisons can rely on identity. [Computed Style](ecss-computed-style.md) defines the readers; the record's field surface is exactly what they expose.

| Field | Meaning | Read by |
| --- | --- | --- |
| Values | The resolved value of every covered property, in schema order | `ecss-computed-style-values`, `ecss-computed-style-value` |
| Custom properties | Declared custom properties and their resolved values | `ecss-computed-style-custom-properties` |
| Active and specified sets | Which properties have a value, and which were specified by a declaration | `ecss-computed-style-active-properties`, `ecss-computed-style-present-p`, `ecss-computed-style-specified-properties`, `ecss-computed-style-specified-p` |
| Declaration facts | Per-property declaration, validity and fallback details | `ecss-computed-style-property-fact`, `ecss-computed-style-precedence-winner` |
| Source provenance | Where each value came from: declaration, initial, inheritance or custom-property resolution | `ecss-computed-style-provenance` |
| Diagnostics | Invalid or deferred computations recorded while computing | `ecss-computed-style-diagnostics` |
| Hot layout fields | Faces, inherited paint, dimensions, edges, borders, overflow, positioning, flex and grid facts, z order, viewport-unit dependencies and a layout key | — |

The hot fields are the reason the record exists beside the ECSS value map: the style pass fills them once so layout, painting and comparison do not re-derive them from values on every flush. A program that needs them asks the node through its behavior — a geometry query, a restyle — rather than reading the record.

## The geometry record

<!-- index: geometry record; border box; painted span -->

A laid-out node stores its resolved geometry: the margin, border and padding edges, the border-box and content-box sizes, the visible height, the scroll offset, the content height and the layout items of a stacking or positioned container.

| Field | Meaning | Read by |
| --- | --- | --- |
| Border box | `:x`, `:y`, `:width`, `:height` in layout coordinates | `ebox-node-geometry` |
| Root line | The vertical position alone | `ebox-node-root-line` |
| Painted span | The buffer positions the node painted | `ebox-node-bounds`, `ebox-node-position`, `ebox-node-at` |
| Resolved edges and boxes | Margin, border, padding, content box and content size | — |
| Visible height, content height, scroll offset | How much of the content is visible and where it is scrolled to | `ebox-node-scroll-offset` for the offset |
| Layout items | The placed children of a stacking or positioned container | — |

Two rules about the record are worth stating precisely, because a text node sits in both cases. A text node that is laid out as its own layout item — a direct child of a `row` or `column`, for example — has a border box and reports geometry. A text node whose line layout is owned by an anonymous paragraph held by its `box` has no border box of its own: `ebox-node-geometry` and `ebox-node-root-line` answer nil for it, and its painted run is what `ebox-node-bounds` reports. And like every layout fact, the record is a snapshot: it is available once the node has been laid out, and a later mutation changes it at the next flush.

## The paragraph record

<!-- index: paragraph record; cache key -->

EKP does not store its work in the Ebox tree. A justification call produces paragraph records owned by the layout: one record per paragraph per layout context, holding the box vector with its widths, types and glue values, the hyphenation positions, the prefix arrays and per-class counters that make line measurement constant time, a snapshot of the effective spacing parameters, and the result caches for the break search and the semantic plan.

The record is keyed by everything that can change how a paragraph is shaped — the characters, their text-property intervals, the detected fonts, the width context, the hyphenation language, the alignment and the layout policy — and the key is compared structurally, so equal inputs share one record and hash collisions cannot alias two paragraphs. It is a cache, not a public object: this version exports no reader for its fields, and the public way to release the caches is `ekp-clear-caches`. `ekp-layout-plan` returns the semantic plan built from the record, and the plan's readers are documented in [Programming Interface](ekp-programming-interface.md). [Implementation](ekp-implementation.md) describes the pipeline that fills and consumes the record.

## The mount record

<!-- index: mount record; line anchors; input session -->

A mount binds one root node to one buffer. It is created by `ebox-mount` (or `ebox-render-to-buffer`) and released by `ebox-unmount-buffer` or by killing the buffer. Everything that is scoped to one mounted buffer lives here: the root, the viewport, the line anchors and the remembered written line parts that make incremental writes possible, the flush counter and the latest update report, the observer, the saved and restored display settings, the focus state and its memory, the hover and active state, and the active input session.

| Field | Meaning | Read by |
| --- | --- | --- |
| Root | The mounted root node | `ebox-buffer-root` |
| Buffer | The buffer showing the mount | The handle is passed to every mount-scoped function |
| Viewport | Fixed or window-derived width and height | `ebox-mount-viewport`, `ebox-mount-set-viewport` |
| Flush counter and report | How many flushes wrote, and what the latest one wrote | `ebox-mount-flush-count`, `ebox-buffer-update-report`, `ebox-buffer-set-observer` |
| Line anchors and written parts | The retained bookkeeping behind incremental line replacement | — |
| Saved display settings | Buffer-local settings installed at mount and restored at unmount | — |
| Focus state and memory | The focused node, its anchor and the per-group memory | `ebox-focused-node`, `ebox-focus-within` |
| Hover and active state | Pointer state used by interaction properties | Host hover properties and pointer queries |
| Input session | The native editing session, if any | `ebox-input-session-node`, `ebox-input-active-p` |
| Queue flag | Whether the mount is waiting for a flush | — |
| The mount object itself | An opaque handle for everything mount-scoped | `ebox-buffer-mount` |

The mount object returned by `ebox-buffer-mount` is the opaque case of this chapter: callers keep it, compare it against nil to test liveness, and pass it nowhere — the mount-scoped functions take the buffer. The record's readers are the functions above; its internal fields drive the flush pipeline that [Incremental Updates and Publication](incremental-updates-and-publication.md) describes.

## How the records own each other

<!-- index: record ownership -->

The set forms a strict ownership chain: a Runtime owns the segment tree, a Segment owns at most one Component instance and at most one Ebox node, a Node owns one computed style and one geometry record, a Mount owns one root node and one buffer, and EKP owns its paragraph records beside the Ebox tree rather than inside it. Each fact has exactly one owner, which is why the readers can be small and why an update can stay local: changing a value touches the record that owns it and the segment that owns that record, not a second copy somewhere else.
