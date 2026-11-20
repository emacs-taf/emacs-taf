# Design Rationale

The rest of the manual describes what the framework does; this chapter collects why. Each section states a choice, the alternative it displaces, and the consequence that shows up in the public behavior — the parts an application author can rely on. The choices are implemented ones, not proposals: when an alternative is named, it is the design the implementation deliberately does not follow.

## Retained, not rebuilt

<!-- index: retained design; dependency edge; incremental damage -->

The View is compiled once into a retained segment tree, and a state write follows the dependency edge to the binding that owns the affected node. Ebox then updates only the damaged layout and rewrites only the changed buffer lines. The displaced alternative is the React-style model of producing a fresh candidate tree per render and diffing it against the previous one.

Retention is what makes the cost of an update proportional to the change instead of to the size of the interface: a keyed list moves nodes instead of recreating them, and a text change in a vertical stack recomposes the affected lines. It is also why identity is a first-class concept: a stable kind and key keep the segment, its Component instance and its Ebox node alive, so state survives reordering. The price is that reconciliation must own identity, which [Views](views.md) and [Components](components.md) describe in full.

## One reactive graph, three phases

<!-- index: reactive phase; commit boundary; rollback -->

Refs, computeds and effects form one graph. A write marks observers directly dirty and their transitive observers for checking, so an effect runs only when a value it actually read changed — not because some source anywhere changed. The displaced alternative is coarse invalidation that re-runs consumers of consumers, or a global event bus that re-renders everything subscribed.

The graph also fixes the timing of visible work. Effects run in three phases — pre watchers, render bindings, post watchers — and the Runtime commits between render and post, so the buffer is written exactly once per commit and post watchers read the published result. Batching defers delivery to the outermost boundary, which is why an event callback that writes several refs produces one commit. The commit is atomic: a failed render effect is rolled back and parked, while the application's writes stay, so a persistent failure keeps the last good UI instead of publishing half of the new one. [Tracing One Update](update-trace.md) walks that path.

## Ebox is the only layout and buffer engine

<!-- index: engine boundary; single authority -->

The physical node tree, computed styles, layout, focus, native input and buffer text belong to Ebox; ETAF keeps indexes and semantic properties, never a second copy. The displaced alternatives are letting ETAF keep a parallel geometry cache, or letting applications call the engine directly to get at a fact the framework has not exposed.

One authority means a query cannot disagree with what is on screen, and a fix to layout or input behavior is made in one place. The boundary rule that applications and catalog components use ETAF public interfaces only is what keeps that true; when something is genuinely missing, [Extending the Framework](extending-the-framework.md) describes how a new Ebox capability is exposed through ETAF instead of bypassed.

## Styles belong to ECSS

<!-- index: cascade library; specified active distinction -->

Selector matching, the cascade, origins, layers and computed values live in a general ECSS library, and Ebox registers its style vocabulary with it. The displaced alternative is a private styling pass inside the engine that would be usable only for boxes.

Keeping the cascade separate makes it reusable — a program can compute styles for a widget, a diagnostic or a document with its own schema — and it gives the engine a normalized input instead of a pile of special cases. The `specified` and `active` distinction matters for the same reason: a declaration that is specified but invalid is not the same as one that is active, and a consumer that reports or debugs a value needs to tell them apart. [Values](values.md) and [Computed Style](ecss-computed-style.md) define both halves.

## A flex and grid subset, not all of CSS

<!-- index: layout subset; predictable cost -->

The layout engine implements the flex and grid concepts that text interfaces use — main and cross axes, grow and shrink, gaps, tracks, spans, alignment — and leaves the rest of CSS out. The displaced alternative is chasing full CSS compatibility, with its many interacting sizing rules and legacy quirks.

A subset with a documented box model is predictable in cost and honest about what it cannot do: a `kp` break mode that Ebox cannot implement is documented as behaving like `word` rather than approximated silently, and a border wider than one pixel is refused rather than painted wrong. The cost of that honesty is that some documents cannot be reproduced exactly, which the reference chapters state where it applies.

## Components are the only reusable UI unit

<!-- index: component model; slot ownership; context inheritance -->

A reusable control is a Component; there is no separate widget or control model with its own lifecycle. The displaced alternative is a class hierarchy of controls beside the component model, which would need parallel rules for props, state, styles and events.

One model means one set of prop, slot and Theme rules for everything, and the catalog can compose components because they share those rules. Two ownership choices inside it are deliberate: a slot's content keeps its caller Context, while Context provided by a wrapper component reaches the wrapper's rendered descendants but not content passed through its slot — so a wrapper cannot hijack the environment of content it did not create. [Context](context.md) and [Component Styles and Themes](component-styles-and-themes.md) define the mechanism.

## Interaction flows through committed Host references

<!-- index: committed reference; input ownership -->

Events, focus and key dispatch all operate on committed Host references. Ebox owns native targeting, focus order, drag tracking and input sessions; ETAF validates the Runtime and Host reference and runs the callback inside a batch. The displaced alternative is a global event bus with its own target model.

Routing through committed references means a callback runs against the Host the user actually sees, and a reference that no longer resolves fails loudly instead of acting on a stale node. The scoped key layer is built on the same rule: a key is owned by the innermost committed Host that declares it, and the framework's defaults fill in only where nothing claims the key. [Events](events.md) and [Keyboard](keyboard.md) define the details.

## Data, Resource and async share one boundary

<!-- index: source controller split; certainty -->

A Data Source is a plist of capabilities and a Controller owns the reactive state over it; both Data and Resource use one asynchronous lifecycle. The displaced alternative is a store with built-in loads and mutations, or a promise library separate from the reactive graph.

The split lets a backend be reused by different controllers and lets a controller's query, page, selection and status stay in ETAF where the rest of the reactive state lives. It also forces certainty to be explicit: a committed external write is never replayed by a refresh, and an unknown outcome stays unknown rather than being reported as rolled back. [Data Controllers](data-controllers.md) and [Reconciliation](reconciliation.md) define the rules.

## Animation and video are ordinary subsystems

<!-- index: transition ref; retained frames -->

A transition and an animation are refs whose values move over time, and a video frame is retained Host content. The displaced alternative is a second rendering path with its own clock and its own paint loop.

Building on the reactive graph means an animation tick is one batch, one commit and one Ebox flush, with no ordering rules beyond the ones already defined, and a Scope-owned animation stops with its Scope. Publishing frames as content reuses the same damage, clipping and overlay behavior as any other image. [Animation](animation.md) and [Native Video](native-video.md) define those interfaces.

## Explicit, optional observation

<!-- index: observation port; recorder as consumer -->

Timing and diagnostics travel through a small observation port that emits flat reports during an operation; the performance recorder is a consumer of those reports, not an advice registry and not a timing path of its own. The displaced alternative is advising the framework's functions globally, which measures whatever happens to run and cannot say which operation it belonged to.

The report contract makes recorded work attributable: an operation has a kind, a label and an identity, and each stage names its provider and category. Recording is opt-in per Runtime, so an application pays for instrumentation only when it turns it on, and turning it off restores the unobserved path with no residue. [Performance Engineering](performance-engineering.md) defines the recorder.

## Tests and documentation are contracts

<!-- index: acceptance contract; living manual -->

A package's maintained scenarios are listed with their observable purpose, only public interfaces are tested, and the manual's own gate checks signatures, coverage and both languages. The displaced alternative is tests bound to implementation details and documentation that drifts from the code.

Tests written against public behavior survive a refactor that preserves the behavior and fail when the contract changes, which is exactly when a maintainer wants a failure. The same applies to the book: a public interface without an entry, a signature that no longer matches the Commentary, or a translation that lags fails the build, so the manual cannot silently fall behind. The [Extending the Framework](extending-the-framework.md#how-a-change-is-verified) chapter describes how correctness is established and how a change is delivered.
