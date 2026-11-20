# Invariants

The mechanisms in this part — compilation, reactivity, retained layout, incremental buffer writes — are safe to use because they maintain a small set of invariants. An invariant names one fact that is always true while the framework runs, the layer that holds it true, and what goes wrong when it is not. This chapter collects the invariants of ETAF and Ebox into two tables. It defines no interfaces; every item is observable through the public interfaces named in the "Checked by" column.

## How an invariant is held

<!-- index: invariant; owner; dirty invalidation -->

Three habits keep the list short. First, every fact has exactly one owner: the Runtime owns the segment tree, a segment owns its node, a node owns its computed style and layout, a mount owns its buffer. An invariant therefore has a layer to blame and a layer to fix. Second, derived state is invalidated from the change, never re-derived from the buffer: public mutations set dirty bits and the flush recomputes what the bits cover, so a cache cannot disagree with the tree it belongs to. Third, the public boundary itself is checked mechanically — the workspace's structure and API gates read the provider sources and reject a consumer that calls an unlisted symbol, so the boundary is not a convention to remember.

The "Checked by" column names representative scenarios from each package's acceptance inventory rather than the complete set; the scenario names come from the provider repositories, and the failing scenario is the first place to look when an invariant is suspected.

## The ETAF invariants

<!-- index: retained tree; write boundary; binding ownership; keyed identity -->

| Invariant | Held by | If violated | Checked by |
| --- | --- | --- | --- |
| One retained tree: a mounted Runtime has exactly one segment tree and one Ebox node tree, and its Host and instance tables are indexes into it. | The mount and unmount lifecycle; the commit treats the retained tree as the only authority. | Two owners for one node, or a query answering from a tree the mount no longer has. | *etaf-view-keyed-list-retains-instances*, *etaf-view-unmount-and-kill-release-runtime* |
| One visible write boundary: a commit performs at most one Ebox flush, and a failed pre or render effect discards the whole transaction before any buffer write. | The commit journal and the Ebox batch; [Tracing One Update](update-trace.md) follows the path. | Half-updated UI, or a revision that disagrees with the buffer. | *etaf-view-batches-writes-into-one-commit*, *etaf-data-completion-publishes-atomically* |
| Binding ownership: each fine-grained binding owns exactly one Host property set, one text payload or one dynamic child region, and may patch only that target. | The Runtime compiles bindings per site; an effect that did not rerun leaves its target untouched. | Two bindings overwrite each other's output, or an update rebuilds subtrees that did not change. | *etaf-selector-notifies-only-the-changed-keys*, *etaf-component-tracked-props-update-without-setup* |
| Keyed identity: a stable kind and key preserve the segment, its Component instance, its Host reference and its node; a missing or changed key disposes the old owner. | Reconciliation compares kind and key before retaining anything. | State resets on reorder, or removed keyed items keep running. | *etaf-view-keyed-list-appends-and-clears*, *etaf-view-component-props-update-retained-instance* |
| Scope ownership: effects and cleanups belong to their Scope, and disposal stops reactive work before releasing external resources. | Scopes stop their children and effects in order; a stopped Scope accepts no new work. | A disposed owner keeps publishing, or cleanup runs while effects still run. | *etaf-scope-stop-releases-effects-and-owned-children*, *etaf-data-owner-scope-disposes-controller*, *etaf-async-mounted-owner-unmount-invalidates-late-work* |
| No rendering side effects: rendering and binding evaluation must not write application state. | Writes belong to events, Actions, watchers, effects, async completions and explicit batches; the Runtime rejects a ref write during rendering. | Re-render loops, or a value nobody can explain. | Runtime rejection with `etaf-render-side-effect-error`; otherwise review |
| Ebox authority: layout, focus, native input and buffer text are queried from Ebox, and ETAF keeps no parallel copy. | Host queries read committed Ebox facts; ETAF stores only indexes and semantic properties. | A query answers from stale ETAF state, or focus and layout disagree. | *etaf-events-host-queries*, *etaf-events-retained-host-updates* |
| Public boundary: applications and catalog components use ETAF public APIs only; Ebox-prefixed calls stay inside ETAF or Ebox-owned packages. | The workspace structure and API gates read the sources; the manual's own gate rejects private names in prose. | The gate fails; behavior may still work, but the interface contract is broken. | `make api-check`, the package `check` targets |

## The Ebox invariants

<!-- index: retained authority; damage; buffer state -->

| Invariant | Held by | If violated | Checked by |
| --- | --- | --- | --- |
| The retained node tree is the source of truth; buffer text is an output cache. | Every flush rewrites exactly the lines the damage covers; [Incremental Updates and Publication](incremental-updates-and-publication.md) explains the one deliberate exception, a foreign edit not yet reached by an update. | The buffer and the tree disagree on a line nobody edited. | *ebox-node-set-text-updates-buffer-like-fresh-render* |
| A node has at most one parent; detached roots may be rendered or mounted, and mounted descendants stay in their root tree. | Insertion rejects a child that already has a parent. | One node in two trees, making damage and geometry ambiguous. | *ebox-node-insert-remove-move-and-replace-children-update-order* |
| Public mutations alone change retained nodes; internal caches are invalidated from dirty bits, never by reading buffer text. | Every mutation marks what it changed and what may have to be recomputed. | A cache keeps a value a mutation should have cleared. | *ebox-node-mutation-errors-leave-buffer-at-last-successful-render* |
| A computed style belongs to the parent style, declarations, selector facts and scope environment used to build it. | The style pass recomputes a node when its style bit is set, when it has no computed style, or when an ancestor's style changed. | Two nodes with different inputs share one style, or inheritance lags a change. | *ebox-parent-restyle-updates-inheriting-descendants*, *ebox-inline-ecss-cascades-to-descendants* |
| Vertical geometry is line based and horizontal geometry is pixel based. | Layout resolves heights as whole lines and widths as pixels, using display spaces for exact pixel fill. | Lines drift apart or pixel columns fail to align. | *ebox-render-wraps-aligns-and-measures-cjk* |
| A clean node under the same width constraint keeps its layout and composed line caches; a dirty node records precise damage or damages the smallest boundary whose shape changed. | Dirty bits classify style, layout, paint and descendant changes before the flush. | Unnecessary relayout and repaint, or an untouched line appearing in the update report. | *ebox-with-batch-flushes-mutated-mount-once*; the update report's ranges |
| Buffer writes preserve unrelated buffer state: the read-only flag, the undo list, the modified flag, point and window starts. | Ebox suppresses undo and modification hooks while it writes and restores saved display settings at unmount. | A repaint moves point or pollutes the undo history. | *ebox-first-content-keeps-point-and-window-start-at-top*, *ebox-mounted-rows-own-wrapping-and-restore-buffer-settings* |
| Image decoding and external converter execution happen only in preparation, never in layout or buffer writing, and preparations are cached by source identity, size and frame in a bounded cache. | Preparation runs before layout and stores results; layout and paint reuse them. | A flush stalls on decoding, or the same image is decoded once per paint. | *ebox-image-identical-preparation-reuses-a-screenful-of-images*, *ebox-image-cache-stays-bounded-and-usable-under-churn* |
| A graphical image row is one glyph displaying a full-width slice; cutting it at a box or overlay edge narrows the slice instead of replacing it with a space. | Image rows are emitted as whole slices, and edges trim the slice. | The visible part of an image disappears at a box edge. | *ebox-image-slice-cut-at-a-box-edge-keeps-its-visible-part* |
| Private modules may change; consumers require only `ebox` and use only the symbols documented in `ebox.el`. | The workspace structure and API gates. | The gate fails while the runtime may still appear to work. | `make api-check`, the package `check` targets |

## When an invariant looks broken

<!-- index: false alarm; foreign edit; failed commit -->

Two everyday situations imitate an invariant violation and are worth ruling out before looking for a defect. The first is a buffer that differs from the tree because it was edited from outside: Ebox repairs such a line only when the next flush reaches it, so an untouched line can disagree until then. The second is a write that never reached the buffer at all: an equal ref value, a commit with no damage, or a failed effect that was rolled back and parked. The update report and the revision distinguish all three — no report and no revision change means nothing was published, while a fresh report names the exact lines that were.

A real violation is diagnosed from the owning layer, not from the symptom. A stale Host query points at the Runtime's indexes or a disposed owner; a node that ends up in two trees points at insertion or reconciliation; a style that lags points at the style pass's dirty bits; a rewritten buffer state points at the write path. When the owner is found, fix it there: a reader that works around a broken owner adds a second source of truth and turns one violation into two.
