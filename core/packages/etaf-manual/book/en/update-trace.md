# Tracing One Update

An update starts with a state write and ends with different text in a buffer. Earlier chapters describe the pieces of that path — the reactive graph, the Runtime, Ebox's flush pipeline — and this chapter joins them into one walk: what runs in which order, what is visible at each point, and where a failure stops it. It defines no interfaces of its own; every step is named by a public interface defined elsewhere.

## The write

<!-- index: reactive write; shallow equality -->

The path begins with `etaf-set-value`, which replaces a ref's value and returns it, or `etaf-update-value`, which applies a function to the current value once. Both make the new value readable through `etaf-value` immediately — inside a batch too, before any buffer changes. `etaf-update-value` rejects rendering and read-only sources before the function runs, and a function that errors leaves the ref unchanged.

A ref compares by its shallow rule: lists, vectors, hash tables, records, functions and editor handles by identity, every other value with `equal`. Setting an equal value does not notify dependents, and there is no deep copy, so a caller that replaces an object should treat the old one as detached. The write itself changes no buffer. It only makes the new value current and marks the observers that read the old one.

## The batch boundary

<!-- index: batch; deferred delivery; outermost scope -->

Outside a batch, the write drains the queued work synchronously before it returns, so a single `etaf-set-value` is already visible when it returns. Inside `etaf-batch` or `etaf-call-with-batch`, delivery is deferred to the outermost batch; nested batches join it, and several writes publish together. Ref reads are not deferred — only observers and Runtime updates are.

Events and Actions run their callbacks inside the same boundary, so an explicit batch composed around an event callback does not create a second publication. The boundary is synchronous: a later asynchronous callback must establish its own batch. If the batch body errors or quits, pending work still drains before the original condition is re-signaled; written refs stay written, and the batch provides neither rollback nor atomic publication across several Runtimes.

## From marking to retained edits

<!-- index: dependency edge; render binding; binding ownership -->

A write colors its direct observers dirty and their transitive observers for checking, so the drain runs an effect only if the values it actually read have changed. Two kinds of effects matter here. Watchers registered with the default `pre` flush of `etaf-watch` or `etaf-watch-effect` run before any mounted Runtime writes its buffer: they see the new values and the old buffer. Render bindings run in the same phase and turn the new values into retained edits: a property binding patches its own Host's property set, a text binding its own text payload, a structural region its own child list. Each binding owns exactly one target; it may read many reactive sources but may patch only that target.

That ownership is what keeps the update small: the retained tree is the single authority, there is no candidate tree or whole-tree diff, and a binding that did not rerun leaves its nodes untouched. Rendering and binding evaluation must not write application state; writes belong to events, Actions, watchers, effects, async completions and explicit batches.

## The commit and the buffer write

<!-- index: commit; flush; revision; update report -->

After the pre and render effects settle, the Runtime commits. If any retained node changed, the commit performs exactly one Ebox flush; [Incremental Updates and Publication](incremental-updates-and-publication.md) describes the pipeline that restyles, relayouts, repaints and computes the damaged line ranges. The flush writes only those ranges, so untouched lines are left alone, and `ebox-mount-flush-count` advances only when a flush actually wrote. `etaf-runtime-revision` advances once for the commit, and only when the buffer changed; a commit that finds nothing to write leaves both the counter and the revision alone.

The commit is the one visible write boundary of the update. Everything before it prepared retained state, and everything that reads the buffer afterwards sees the new text. Applications observe the flush through public interfaces: `ebox-buffer-update-report` returns the latest flush's report plist, `ebox-buffer-set-observer` receives one report after every flush, and `ebox-after-flush-functions` runs after each writing flush. A report names the strategy, the number and location of the line replacements, the flush counter, and — when an observer timed that flush — the elapsed milliseconds. Read the report together with `etaf-runtime-revision` when a change looks invisible: an unchanged revision with an unchanged report means nothing reached the buffer, while a new revision with an empty edit list cannot happen.

## After the commit

<!-- index: lifecycle hook; post watcher; next tick -->

Three kinds of follow-up work run after the visible commit, in a fixed order. First, Component lifecycle hooks: `etaf-on-updated` runs after a Component participates in an update, and `etaf-on-mounted` after its first publication; at that point the buffer already shows the new text. Second, post watchers — `etaf-watch` and `etaf-watch-effect` with `:flush 'post` — run after the buffer was written, so they can read the published result. Third, functions queued with `etaf-next-tick` run once pending work is published, which places them after the post watchers; outside a batch they run immediately, and queued functions run in order even when the drain failed.

The order is observable and stable: for one `etaf-set-value` outside a batch, a pre watcher sees the old buffer, the commit writes the new text, `etaf-on-updated` sees the new buffer, and a post watcher then sees it too. A watcher created during Component setup re-enters that Component's environment on every run; a watcher created outside a Component is not scoped to a Runtime, so it reads the buffer through the Runtime and Host references it captured rather than through the current environment.

## Other entry points

<!-- index: retained boundary; refit -->

An ordinary reactive binding is the common way into this path, but not the only one. `etaf-runtime-update-host-content` and `etaf-runtime-update-host-contents` replace Host content directly — the retained boundary for high-frequency surfaces such as a video frame — validating every target before the first replacement and publishing once per call, with one revision increment. `etaf-runtime-update-host-geometry` and `etaf-runtime-update-host-geometries` do the same for position, size and layer facts; the caller stays responsible for keeping its own state consistent with the display. `etaf-runtime-refit` and `etaf-refit` republish a changed viewport through the same revision.

Events and Actions enter through the batch boundary, so their callbacks publish exactly like a state write. Animation frames are ordinary refs whose values move over time, so one tick is one commit. Resource and Data completions write one reactive state cell and then follow the same path. In every case the update ends at the same single commit: one flush, one set of line replacements, one revision.

## Failure and recovery

<!-- index: rollback; parked effect; retry -->

A pre or render effect can fail after earlier effects in the same drain already edited retained nodes. The commit then discards the whole transaction: the recorded changes are replayed backwards, effects, Scopes and installations created during it are released, and the effects that ran are parked. The buffer, the revision and the post watchers remain exactly as before the update, while application refs keep the values the write gave them. Nothing half-written is published.

The parked effects run again with the next drain that has work, or with an explicit `etaf-runtime-flush`, retried together with the new work. A persistent failure therefore keeps the last committed UI on screen until its cause is fixed; `etaf-runtime-flush` re-signals the failure instead of publishing. Once the cause is gone, the next write publishes both the new work and the parked effects in one commit, so the buffer catches up in a single step rather than through a series of partial updates. Lifecycle hook failures are different: they are reported after the commit and never rewind visible state.

## The whole trace

<!-- index: update trace -->

For a mounted Runtime, one write outside a batch runs through these steps:

1. `etaf-set-value` (or `etaf-update-value`) replaces the ref value and marks its observers; the new value is readable at once.
2. The outermost batch boundary drains the queued effects — synchronously here, or at the exit of an enclosing `etaf-batch` or `etaf-call-with-batch`.
3. `pre` watchers run and see the new value with the old buffer.
4. Render bindings patch the retained Ebox nodes they own: properties, text payloads, child regions.
5. The Runtime commits and performs one Ebox flush; only the damaged line ranges are written.
6. `etaf-runtime-revision` advances by one and `ebox-mount-flush-count` records the write; the report is available to readers and observers.
7. `etaf-on-updated` and other Component lifecycle hooks run, then `post` watchers.
8. Functions queued with `etaf-next-tick` run.

A failure in step 3 or 4 undoes steps 3 and 4 and stops before step 5; the next write or `etaf-runtime-flush` retries from the parked effects.
