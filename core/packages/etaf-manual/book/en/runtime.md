# Runtime

A *Runtime* is one live ETAF application: a View mounted into an Emacs buffer, together with the retained tree that keeps its output current, the reactive graph bound to it, its committed revision, and the lifecycle of its Component instances. This chapter defines mounting and unmounting, how to find the Runtime that owns a buffer, how commits and revisions work, the retained boundary for high-frequency Host content and geometry, the introspection interfaces, the transient-space check, and the error condition of the Runtime layer.

The Runtime builds on [Views](views.md), [Components](components.md) and [Reactivity](reactivity.md): `etaf-mount` publishes a normalized View, the Runtime owns the render bindings that keep it current, and each commit is one step of the drain that Reactivity defines. Host kinds, properties and references belong to [Hosts](hosts.md).

<!-- index: Runtime; mount; unmount; commit; revision; retained update; introspection -->

## Model

### The Runtime and its buffer

A Runtime belongs to exactly one buffer. `etaf-mount` creates it, publishes the first View into the buffer, and registers it as that buffer's Runtime; mounting again into the same buffer disposes the previous Runtime first, so a buffer never has two. Killing the buffer unmounts the Runtime.

While mounted, the Runtime owns everything its View puts into the buffer: the retained tree and the Ebox node of each Host, the live Component instances with their Scopes, the registered Host references and references to their retained properties, and the buffer-local key handling that [Hosts](hosts.md) describes for `:keys`. Besides mounting a new View into the same buffer, the ways to dispose it are `etaf-unmount` and killing the buffer.

Mounted Runtimes are found one of three ways: from the dynamic context (`etaf-current-runtime`), from the buffer (`etaf-runtime-for-buffer`), or by keeping the object returned when it was mounted. An unmounted Runtime is no longer returned by the lookup functions, but the object itself still answers the accessor functions.

### Output, commits and revisions

The View is a description; the Runtime keeps the output. Static parts of the View are built once, and every dynamic part becomes an effect bound to the piece of the tree it updates. A write to application state queues the effects that read it; the drain runs them in phase order, and between the render and post phases each Runtime whose output changed commits: the buffer is written once, the committed revision advances, and the lifecycle hooks of the commit run. The exact phases, queues and failure rules belong to [Reactivity](reactivity.md#draining).

A Runtime therefore has a *committed revision*, an integer that increases once per commit that changed its buffer. Application code uses it to observe that a publication has reached the buffer, for example after an explicit flush, rather than as a handle on the tree.

## Mounting and unmounting

#### Function: etaf-mount (buffer-or-name view &optional options)

Mount normalized VIEW into BUFFER-OR-NAME and return its buffer.

**Arguments.**

- BUFFER-OR-NAME is a buffer or a buffer name. The buffer is created if it does not exist; the Runtime does not display it.
- VIEW is a normalized View, as [Views](views.md) defines, or a zero-argument function returning one. A function is evaluated with tracking, so a View function that reads a reactive source is re-rendered when the source changes.
- OPTIONS is a plist. The supported keys are `:viewport-width` (in pixels) and `:viewport-height` (in lines), which the first publication uses directly instead of an immediate re-layout, `:observer`, a one-argument report sink installed before the first render, and `:text-selection`, a boolean (t or nil) enabling native Emacs mark and pointer text selection on the canvas for the duration of the mount. A nil dimension follows the displaying window. The viewport details belong to [Viewport](viewport.md); the report format belongs to [Incremental Updates and Publication](incremental-updates-and-publication.md).

**Semantics.** An existing Runtime mounted in BUFFER-OR-NAME is unmounted first, so the new View replaces the old application. The first publication is one observed operation: the View is lowered and rendered, the whole buffer is written, and the committed revision becomes 1. Registering the Runtime also installs its key handling and its `kill-buffer-hook`, so killing the buffer unmounts it. If the first publication fails, the new Runtime is disposed and the condition propagates; the buffer survives with no Runtime.

**Returns.** BUFFER-OR-NAME as a live buffer.

**Errors.** `error→ etaf-runtime-error` when OPTIONS is not a proper plist, when it contains a key outside the four above, when `:viewport-width` or `:viewport-height` is neither nil nor a positive number, when `:observer` is neither nil nor a function, or when `:text-selection` is not a boolean (`nil` or `t`); the data names the message and the offending value or key. A View problem propagates its own condition, such as `etaf-view-error`, `etaf-view-syntax-error`, `etaf-component-call-error` or `etaf-renderer-error`, and the buffer is left without a Runtime. During rendering the call signals `error→ etaf-render-side-effect-error` with data `(mount-runtime)`.

**Example.** A headless host that already knows the layout context avoids the first re-layout.

```elisp
(etaf-mount "*tasks*"
            view
            '(:viewport-width 1200 :viewport-height 48))
```

**See also.** `etaf-unmount`, [Finding a Runtime](#finding-a-runtime), and [Viewport](viewport.md).

### Native application windows

A native text application owns the window it opens in. `etaf-app-open` displays its buffer in the selected window regardless of the user's `display-buffer` rules, so they cannot split the frame into a side pane; the [Applications](applications.md) chapter covers that lifecycle. Reserve one clear line at the top of the root View: count it as chrome in page and row budgets, and on a short window render fewer content rows rather than clipping the first line. The top line is a convention of the application, not an option of `etaf-mount`.

#### Function: etaf-unmount (&optional runtime)

Unmount RUNTIME, defaulting to the active or `current-buffer` Runtime.

**Arguments.** RUNTIME is a Runtime, a value the call failed to use as one signals `wrong-type-argument`; omitted or nil, the Runtime making the call is used, then the Runtime of `(current-buffer)`. A mounted Runtime is required: when none is mounted the call signals `etaf-runtime-error`.

**Semantics.** Unmounting is the reverse of mounting: the retained tree and its Ebox nodes are released, Components are disposed and their unmounted hooks run, the buffer-local key handling and the Ebox mount are removed, and the Runtime is delimited from its buffer, so `etaf-runtime-for-buffer` stops returning it and `etaf-runtime-mounted-p` returns nil. The buffer itself survives and keeps the text of the last publication; the Runtime object also survives and still answers the accessor functions, but it can no longer be updated or flushed. Killing the buffer unmounts the Runtime without an explicit call.

**Returns.** RUNTIME.

**Errors.** `error→ etaf-runtime-error` with the message `"ETAF runtime is not mounted"` when RUNTIME, the active Runtime and the current buffer's Runtime are all unmounted or absent. During rendering the call signals `error→ etaf-render-side-effect-error` with data `(unmount-runtime)`.

**Example.** Dispose the application of the current buffer.

```elisp
(etaf-unmount (etaf-runtime-for-buffer "*tasks*"))
```

**See also.** `etaf-mount`, `etaf-runtime-for-buffer` and `etaf-runtime-mounted-p`.

## Finding a Runtime

These four functions locate the Runtime an operation should use: the dynamic context inside a callback, the buffer outside one, and the two accessors that answer whether a Runtime object is still mounted.

#### Function: etaf-current-runtime ()

Return the Runtime that owns the current setup, lifecycle, or event callback, or nil outside a Runtime operation.

**Semantics.** During Component setup, a lifecycle hook, an event callback and a render binding of a mounted View, the call returns the Runtime those bindings belong to. Outside such an operation, including inside `etaf-render`, it returns nil. Lifecycle code that needs the mounted buffer must use `(etaf-runtime-buffer (etaf-current-runtime))`: `current-buffer` is the caller's buffer and is not guaranteed to be the mounted target when `etaf-mount` received a name.

**Returns.** A mounted Runtime, or nil.

**Example.** A lifecycle hook opens a resource for the Runtime's own buffer.

```elisp
(etaf-on-mounted
 (lambda ()
   (let ((buffer (etaf-runtime-buffer (etaf-current-runtime))))
     (with-current-buffer buffer (open-resource)))))
```

**See also.** `etaf-runtime-buffer` and [Components](components.md#lifecycle-hooks).

#### Function: etaf-runtime-for-buffer (buffer-or-name)

Return the live Runtime mounted in BUFFER-OR-NAME, or nil.

**Arguments.** BUFFER-OR-NAME is a buffer or a buffer name, as for `get-buffer`.

**Semantics.** The lookup reaches only mounted Runtimes. A name that does not name a buffer, a killed buffer, and a buffer whose Runtime was unmounted all yield nil.

**Returns.** The mounted Runtime, or nil.

#### Function: etaf-runtime-buffer (x)

Access slot "buffer" of Runtime object X.

**Arguments.** X is a Runtime object. Any other value signals `wrong-type-argument` with data `(etaf-runtime X)`.

**Semantics.** The accessor returns the buffer the Runtime publishes into, whether or not the Runtime is still mounted, so it is safe to call on a Runtime being unmounted.

**Returns.** The buffer.

#### Function: etaf-runtime-mounted-p (x)

Access slot "mounted-p" of Runtime object X.

**Arguments.** X is a Runtime object. Any other value signals `wrong-type-argument` with data `(etaf-runtime X)`.

**Semantics.** The value is non-nil while the Runtime is mounted and nil after `etaf-unmount` or after its buffer was killed. Mounting a new View into the same buffer gives a new Runtime; the old object never becomes mounted again.

**Returns.** Non-nil while mounted, nil otherwise.

## Committing and revisions

#### Function: etaf-runtime-flush (&optional runtime)

Settle mounted RUNTIME's pending reactive work and return its revision.

**Arguments.** RUNTIME is a mounted Runtime; nil or omitted uses the active Runtime, falling back to the Runtime of the current buffer.

**Semantics.** Outside a batch, a drain and a render evaluation, the call runs the pending reactive work now, including the effects a previous failed update left parked, and returns the revision after the resulting commits. Inside `etaf-call-with-batch` or a running commit the pending work stays deferred to that boundary and the current revision is returned without draining. The flush is the explicit way for a synchronous caller to guarantee that its writes have reached the buffer.

**Returns.** The Runtime's committed revision, an integer.

**Errors.** `error→ etaf-runtime-error` with the message `"ETAF runtime is not mounted"` when no mounted Runtime can be resolved. The error of the drain that the flush runs is signaled after the drain, as [Reactivity](reactivity.md#recovery) describes; a persistent failure signals again on every flush.

**Example.** A benchmark writes state and waits for the publication before reading the buffer.

```elisp
(let ((runtime (etaf-runtime-for-buffer buffer)))
  (etaf-set-value tasks new-tasks)
  (etaf-runtime-flush runtime))
```

**See also.** `etaf-runtime-revision` and [Atomic commits](#atomic-commits).

#### Function: etaf-runtime-revision (runtime)

Return RUNTIME's committed revision, an integer that increases once for every commit that changed its buffer (ordinary reactive work, Host content or geometry updates, and `etaf-runtime-refit` or `etaf-refit` calls that changed the layout). Tests and benchmarks compare revisions to observe that a change was published.

**Arguments.** RUNTIME is a Runtime object. Any other value signals `wrong-type-argument` with data `(etaf-runtime RUNTIME)`.

**Semantics.** The revision is monotonic for the life of the Runtime and advances only for a commit that changed the buffer. A write whose observers all compare unchanged does not advance it; a failed update that was rolled back does not advance it; work queued inside an open batch does not advance it until the batch commits. The accessor does not drain and does not require the Runtime to be mounted: after unmount it keeps answering with the last committed value.

**Returns.** The committed revision as an integer.

**See also.** `etaf-runtime-flush` and [Reactivity](reactivity.md#mounted-runtimes).

### Atomic commits

A commit is all-or-nothing for the work of one drain. The drain runs inside a transaction that journals every change to state that existed when it began: the retained segments and Hosts, Component instances, the written values of reactive cells, and the Ebox nodes' properties and text. Objects the transaction created are not journaled; if the commit is abandoned they are released instead. Cleanup of resources that were replaced and are still committed waits until the transaction commits.

When a pre or render effect fails, the Runtime discards the whole uncommitted work: the buffer keeps the output of the last successful commit, the revision does not advance, and the application's own refs keep the values that were written to them. The effects that ran are kept and parked: the next drain that has work, or the next `etaf-runtime-flush`, runs them again. A failure in the post phase does not discard the commit — the buffer is already written and the revision has advanced — and the condition is signaled at the end of the drain together with the other errors. This is the Runtime side of the recovery contract that [Reactivity](reactivity.md#recovery) states.

Because the journal covers only what changed, the cost of a commit is proportional to the state the transaction touched, not to the size of the View.

## Retained Host updates

A mounted Runtime can update an addressed Host's published content or geometry directly, without going through the reactive graph. This is the display boundary for values a caller owns and republishes at a high rate, such as video frames, chart data or live measurements: the value bypasses the Component props and the ordinary publication path, and one Ebox publication updates one Host or several.

#### Function: etaf-runtime-update-host-content (runtime host-ref content)

Replace HOST-REF's published content with CONTENT in mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime. HOST-REF is a committed Host reference of a Text Host, such as the `:ref` of a `text` Host. CONTENT is a string, published as the Host's text, or an image object as returned by `create-image`, published as one image cell showing that image at its own size. Emacs builds without native image support accept strings only; a rejected value still signals `error→ etaf-runtime-error` before any content or revision changes.

**Semantics.** The update replaces only the addressed Host and publishes once through Ebox, so a caller whose controlled state changed one value skips an ordinary ETAF publication. Strings retain caller-owned display properties, including image slices; a caller that keeps a fixed-size Host live with per-frame images passes a new image object per update. The View remains the authority: the update changes the Host's published content, not the View or the Component that rendered it, so the retained value must agree with what the View renders, as [Reconciling retained content](#reconciling-retained-content) explains. Use a Text Host for changing media; a Box Host's content is its child structure, and this call refuses it.

**Returns.** t after a committed update.

**Errors.** `error→ etaf-runtime-error` before anything changes when RUNTIME is unmounted, when HOST-REF is not a committed Host (message `"Unknown committed Host"`), when CONTENT is neither a string nor an image object (`"Invalid Host content updates"`), or when the addressed Host's retained node cannot hold content, as a Box cannot (message `"Host cannot hold content"`).

**Example.** A video frame on its own Host, once per decoded frame.

```elisp
(etaf-runtime-update-host-content runtime 'video-frame frame-image)
```

**See also.** `etaf-runtime-update-host-contents`, `etaf-runtime-update-host-geometry`, and [Text](text.md) for display properties.

#### Function: etaf-runtime-update-host-contents (runtime updates)

Replace several HOST-REF contents in one retained Ebox publication.

**Arguments.** RUNTIME is a mounted Runtime. UPDATES is a proper alist whose keys are committed Host references and whose values are replacement strings or image objects, with the same content contract as `etaf-runtime-update-host-content`.

**Semantics.** Every target is validated before the first replacement, so a caller keeping several small contents live — text and frames together — publishes once per change instead of once per node. One call is one publication and advances the revision once.

**Returns.** t after a committed update.

**Errors.** `error→ etaf-runtime-error` before anything changes when RUNTIME is unmounted, when UPDATES is not a proper alist of the expected shape (`"Invalid Host content updates"`), when a key is not a committed Host (message `"Unknown committed Host"`), or when a value is neither a string nor an image (`"Invalid Host content updates"`). A target whose node cannot hold content signals `"Host cannot hold content"`; because all targets are resolved before the first replacement, no other Host in the batch has changed at that point.

**Example.** A status line and a preview that change together.

```elisp
(etaf-runtime-update-host-contents
 runtime
 '((status . "connected") (preview . thumbnail)))
```

**See also.** `etaf-runtime-update-host-content`.

#### Function: etaf-runtime-update-host-geometry (runtime host-ref &rest geometry)

Set HOST-REF's position, size or layer properties in mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime. HOST-REF is a committed Host reference. GEOMETRY is a plist of style properties such as `:left`, `:top`, `:width`, `:height` and `:z-index`.

**Semantics.** Only the Host's relayout boundary is laid out and its changed buffer region rewritten, and the update publishes once through Ebox. This is a display projection of a caller's already-updated controlled state: it does not change Component props and it implements no window policy. As with content, the View remains the authority and the retained value must agree with what the View will render.

**Returns.** t after a committed update.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is unmounted, when HOST-REF is not a committed Host (`"Unknown committed Host"`), or when Ebox rejects a property or value (message `"Host geometry update rejected"`, whose data holds the affected references and the underlying condition). A rejected value does not publish a new layout for that update, but it is retained on the Host; [Recovery](#recovery) describes what that means for later updates.

**Example.** Snap a dragged panel to its committed position.

```elisp
(etaf-runtime-update-host-geometry runtime 'panel :left '(px 40) :top '(px 0))
```

**See also.** `etaf-runtime-update-host-geometries` and [Style Properties](style-properties.md) for the accepted values.

#### Function: etaf-runtime-update-host-geometries (runtime updates)

Apply several HOST-REF/GEOMETRY pairs in one retained Ebox publication.

**Arguments.** RUNTIME is a mounted Runtime. UPDATES is a proper alist whose keys are committed Host references and whose values are geometry plists, with the same property contract as `etaf-runtime-update-host-geometry`.

**Semantics.** All referenced Hosts are resolved before the batch starts and the accepted updates publish as one buffer write, so a caller moving several related Hosts pays one publication. One call advances the revision once.

**Returns.** t after a committed update.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is unmounted, when UPDATES is not a proper alist of reference/plist pairs (`"Invalid Host geometry updates"`), when a key is not a committed Host (message `"Unknown committed Host"`, signaled before any host changes), or when Ebox rejects a property or value (message `"Host geometry update rejected"`, with the affected references and the underlying condition). A value rejected in the middle of the batch does not roll back the entries applied before it; [Recovery](#recovery) describes the retained value and the revision.

**Example.** Move a palette and its overlay together.

```elisp
(etaf-runtime-update-host-geometries
 runtime
 '((palette . (:top (px 2) :left (px 4)))
   (overlay . (:z-index 10))))
```

**See also.** `etaf-runtime-update-host-geometry`.

### Reconciling retained content

A retained update is a display value, not application state. The reactive graph, the Component props and the View are unchanged; only the addressed Host's published content or geometry differs from what the View would render. The caller's contract is to keep them consistent: whenever the View publishes that Host again, the View is the authority.

When the Host later re-renders different text or different geometry, the View's values replace the retained ones; a View expression that re-runs without changing its output leaves the retained content in place. A retained update therefore suits values the View does not itself derive — frames, measurements, positions owned by a controller — and a caller that also feeds the value into the View should expect the View's next change to win.

## Introspection

A mounted Runtime can report its committed contributions: which Hosts carry event handlers, what declared properties they committed, how they nest, and which Component instances are alive. All of these read committed state only; none of them publishes, relayouts or drains.

The Host queries see the Hosts that carry at least one non-nil semantic property, such as `:ref`, `:role` or `:keys` — the same Hosts that are registered by reference. A Host with styles only is not registered and does not appear.

#### Function: etaf-runtime-handler-entries (runtime)

Return committed handler contribution entries for RUNTIME.

**Arguments.** RUNTIME is a Runtime object.

**Semantics.** The result lists the Hosts that committed at least one event handler, in tree order, each entry pairing the Host reference with its handlers as `(KIND . FUNCTION)` pairs in property order. A Host whose `:on-*` values are nil commits no handler and is absent. The list describes the committed contribution, not a subscription: it changes on the next commit that changes handlers.

**Returns.** A list of `(REF (KIND . FUNCTION) ...)` entries.

**Example.** A diagnostic lists which Hosts commit a drag handler.

```elisp
(let ((entry (assq 'canvas (etaf-runtime-handler-entries runtime))))
  (alist-get 'drag (cdr entry)))
```

**See also.** [Events](events.md) and the Behavior chapter.

#### Function: etaf-runtime-host-props-entries (runtime)

Return committed Host contribution entries for RUNTIME.

**Arguments.** RUNTIME is a Runtime object.

**Semantics.** The result pairs each registered Host reference with its committed semantic properties, in tree order. The property plist is a copy with the Theme already resolved, exactly as `etaf-runtime-host-props-for` returns it, so a caller can take a snapshot of the whole application's Host contributions in one walk.

**Returns.** A list of `(REF . PROPS)` entries.

**Example.** Dump the committed Host tree for a bug report.

```elisp
(etaf-runtime-host-props-entries runtime)
     ⇒ ((shell :ref shell :role application)
        (title :ref title :role heading :font-weight bold))
```

**See also.** `etaf-runtime-host-props-for`.

#### Function: etaf-runtime-host-props-for (runtime host-ref)

Return committed semantic Host props for HOST-REF in RUNTIME.

**Arguments.** RUNTIME is a Runtime object. HOST-REF is a reference.

**Semantics.** The plist spine is fresh on every call, while contained values preserve identity and are read-only for the caller. The properties are the ones the Host committed, with Theme tokens already resolved to values; later geometry publication does not replace fields in this copy, because a retained geometry update writes to the Host's published node, not to this record. An unknown reference, a Host without semantic properties and an unmounted Runtime all yield nil.

**Returns.** A property plist, or nil.

**Example.** A command checks whether the pointed Host is disabled.

```elisp
(plist-get (etaf-runtime-host-props-for runtime host-ref) :disabled)
```

**See also.** `etaf-runtime-host-props-entries` and [Hosts](hosts.md#semantic-properties).

#### Function: etaf-runtime-host-ancestries (runtime host-refs)

Return committed semantic ancestries for HOST-REFS in RUNTIME.

**Arguments.** RUNTIME is a Runtime object. HOST-REFS is a list of references; unknown ones are skipped.

**Semantics.** The result is a hash table mapping each found reference to its lineage list, `(REF PARENT-REF ... ROOT-REF)`, nearest first and ending at the root of the registered Host chain. Callers use it for overlapping hit tests: the lookup walks the retained Host parents, so a reference in a slot or a Component projection reports the Host chain it actually committed under.

**Returns.** A hash table from reference to lineage list; missing references are absent.

**Example.** One hit test asks whether one Host encloses another.

```elisp
(let ((table (etaf-runtime-host-ancestries runtime (list outer inner))))
  (memq outer (gethash inner table)))
```

**See also.** [Hosts](hosts.md#host-references).

#### Function: etaf-host-ref-row-spans (runtime host-ref)

Return the committed Ebox `(ROW BEG END)` row spans of HOST-REF in RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime object. HOST-REF is a committed Host reference.

**Semantics.** Looks up HOST-REF's retained Ebox node and returns its committed row-span list, or nil when HOST-REF is absent or not yet laid out. Native overlay consumers such as `etaf-media` use this to measure visible rows and occlusion without reaching into internal Runtime slots.

**Returns.** A list of `(ROW BEG END)` entries, or nil.

#### Function: etaf-runtime-overlay-active-p (&optional runtime)

Return non-nil when RUNTIME has an active root surface or named root overlay.

**Arguments.** RUNTIME defaults to the current mounted Runtime.

**Semantics.** Returns `t` when RUNTIME currently hosts a modal surface or any named root overlay, and nil otherwise. Native overlays use this to hide or pause hardware surfaces while a modal or overlay covers the canvas.

**Returns.** `t` or nil.

#### Function: etaf-runtime-instances (x)

Access slot "instances" of Runtime object X.

**Arguments.** X is a Runtime object. Any other value signals `wrong-type-argument` with data `(etaf-runtime X)`.

**Semantics.** The table maps each live Component instance's identity to its instance record and belongs to the Runtime for introspection: a caller can count the live instances or look one up, and every instance is removed from it when the instance is disposed, so an unmounted Runtime's table is empty. The records are opaque to the caller; use them when comparing or counting, not as a source of Component internals.

**Returns.** A hash table of instance identity to instance record.

**Example.** A test asserts that a reconciliation reused both instances.

```elisp
(let ((runtime (etaf-runtime-for-buffer buffer)))
  (hash-table-count (etaf-runtime-instances runtime)))
     ⇒ 2
```

**See also.** [Components](components.md#the-instance-record).

## Transient space

#### Function: etaf-transient-space-borrowed-p (window committed-rows)

Return non-nil when transient UI borrows lines from WINDOW.

**Arguments.** WINDOW is a live window. COMMITTED-ROWS is the body height WINDOW's caller last laid out for, an integer.

**Semantics.** The minibuffer and the echo area keep one body line at rest; while one of them is taller — an active completion session, a wrapped prompt or a message — its extra lines are borrowed from the display windows, which shrink. The call returns non-nil exactly when WINDOW is live, COMMITTED-ROWS is an integer, WINDOW's body is shorter than COMMITTED-ROWS, and the frame's minibuffer window is taller than one line. A caller that laid out for COMMITTED-ROWS can then keep that layout instead of recomputing one for the borrowed height. Growth, a nil commitment, an absent minibuffer and a shorter window with no transient UI are real geometry, so they return nil and the caller follows the window.

**Returns.** Non-nil while transient UI borrows WINDOW's lines, nil otherwise.

**Example.** Fit application layout state to its window in a size-change handler, so a completion popup does not shrink the application.

```elisp
(add-hook 'window-size-change-functions
          (lambda (frame)
            (dolist (window (window-list frame))
              (unless (etaf-transient-space-borrowed-p window layout-rows)
                (fit-layout-to-window window)))))
```

**See also.** [Viewport](viewport.md) and [Scrolling](scrolling.md) chapters, whose canvas keeps its committed viewport for the same borrow.

## Semantic details

### The retained tree

A mounted View is one retained tree, and every part of the View that can change on its own is a segment with an effect. There are eight kinds of segment besides the root:

| Kind | Retains |
| --- | --- |
| Host | One Ebox node and its committed properties; the only segment with a node of its own |
| fragment | A group of sibling nodes published as a group |
| expression | A property or text value computed by an expression; re-evaluates when a source it read changes |
| branch | The taken arm of a conditional; switching arms patches children by identity |
| list | A keyed list; rows keep their nodes and move, and a retained key updates its row |
| row | One item of a keyed list, with the item bound for its subtree |
| component | One Component instance with its input cells, Scope and retained output |
| slot | Caller content projected into a Component's View, rendered with the caller's Context and styles |

The kinds and their reconciliation rules are defined with the View syntax in [Views](views.md); this table names them so the commit below can refer to the tree as a whole.

### One commit, step by step

A commit happens between the render and post phases for every Runtime whose buffer output changed:

1. The tree is synchronized from the retained segments: the top-level node — the single root node or a column wrapping several roots — is mounted into the Ebox mount when it changed.
2. The dirty Ebox subtrees are flushed in one batch: styles are recomputed, damaged regions are laid out and the buffer regions are rewritten once.
3. The committed revision advances by one, and any sticky Host mirror and line span are refreshed (retained Host updates and refits refresh them the same way, and unmount clears them).
4. The lifecycle hooks of the commit run outside rendering: mounted for the instances that appeared in this commit, updated for the instances that took part in it, and unmounted for the instances that were disposed. Each runs with `etaf-current-runtime` bound to the Runtime and with rendering off, so a hook may write state; hook errors are collected by the drain like other publication work.

The drain then continues with the post phase, and starts over if the post phase wrote state, as [Reactivity](reactivity.md#draining) describes. A commit that fails before step 2 is rolled back as a whole, as [Atomic commits](#atomic-commits) explains.

### Cost

- A commit that only moves nodes pays layout and painting for the damaged region; Ebox keeps the nodes and the buffer write is one batch.
- A retained content or geometry update pays one Ebox publication and one revision increment, independent of the size of the View.
- The introspection functions walk the retained Host tree or the instance table; they allocate fresh lists or plists and publish nothing. Use them for diagnostics and tests, not per frame.
- A rollback pays for the state the failed transaction touched, not for the whole View.

## Runtime extensions and presentations

Extensions such as page translators observe a Runtime's lifecycle, read its committed Host tree without touching internal segments or Ebox nodes, and attach keyed visual presentations that survive application updates and dispose cleanly with their Hosts.

#### Hook: etaf-runtime-mount-functions

Hook run with one argument, RUNTIME, after `etaf-mount` completes its first publication.

**Semantics.** Each function in the hook runs with `etaf-current-runtime` bound to RUNTIME and rendering disabled, after any mount `:observer` is installed. An error in one observer is isolated and does not abort the mount or prevent later observers from running.

**See also.** `etaf-runtime-after-commit-functions` and `etaf-runtime-unmount-functions`.

#### Hook: etaf-runtime-after-commit-functions

Hook run with one argument, RUNTIME, after a mounted Runtime commits an application change.

**Semantics.** The hook runs after Ebox flushes, the committed revision advances and Component lifecycle hooks finish. Neither the initial mount nor presentation-only flushes run this hook, so an extension that updates presentations never triggers an observation loop. Individual observer errors are isolated.

**See also.** `etaf-runtime-mount-functions` and `etaf-runtime-set-host-presentations`.

#### Hook: etaf-runtime-after-flush-functions

Hook run with one argument, RUNTIME, after a non-presentation Ebox flush on RUNTIME's buffer.

**Semantics.** Runs after Ebox finishes updating the buffer for an `:overflow scroll` offset change, a viewport refit or an application commit, so extensions such as viewport-first translators observe internal container scrolling without reading Ebox directly. Presentation-only flushes do not run this hook. Individual observer errors are isolated.

**See also.** `etaf-runtime-host-geometries` and `etaf-runtime-after-commit-functions`.

#### Hook: etaf-runtime-unmount-functions

Hook run with one argument, RUNTIME, when a mounted Runtime begins unmounting.

**Semantics.** Runs before the retained tree, Host tables and buffer bindings are released, allowing extensions to cancel asynchronous work and clean up per-Runtime sessions. Individual observer errors are isolated.

**See also.** `etaf-unmount` and `etaf-runtime-mount-functions`.

#### Function: etaf-runtime-host-tree (&optional runtime)

Return the committed application Host tree of mounted RUNTIME as read-only data.

**Arguments.** RUNTIME defaults to the active or current-buffer Runtime.

**Semantics.** Walks the application root only, excluding transient surfaces and attached presentation companions. Each node is a plist with `:id` (stable integer Host ID), `:ref`, `:tag`, `:text` (the application's authoritative text, never a presentation override), `:props` (data-only semantic and style properties plus `:has-on-press` when an enabled press handler exists), `:geometry` (`(:x :y :width :height)` or nil) and `:children`.

**Returns.** A list of top-level Host node plists in document order.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**See also.** `etaf-runtime-host-geometries`, `etaf-runtime-trigger-host-press` and `etaf-runtime-set-host-presentations`.

#### Function: etaf-runtime-host-geometries (runtime host-ids)

Return live geometry and clipping visibility for integer HOST-IDS in mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime; HOST-IDS is a proper list of integer Host IDs returned by `etaf-runtime-host-tree`. Unknown or unlaid-out IDs are omitted.

**Semantics.** Queries the current laid-out box of each Host without walking the full tree. Each entry is `(HOST-ID . PLIST)` with `:x` and `:width` in pixels, `:y` and `:height` in root lines reflecting every enclosing `:overflow scroll` offset, `:clip-top` and `:clip-bottom` naming the effective vertical clip band intersected with the displaying window (or nil when unbounded), and `:visible-p` indicating whether the Host intersects that band.

**Returns.** An alist of `(HOST-ID . PLIST)` entries in the order of HOST-IDS.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or HOST-IDS is not a proper list.

**See also.** `etaf-runtime-host-tree` and `etaf-runtime-after-flush-functions`.

#### Function: etaf-runtime-trigger-host-press (runtime host-id)

Dispatch an enabled `press' event on committed integer HOST-ID in RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime; HOST-ID is an integer `:id` from `etaf-runtime-host-tree`.

**Semantics.** Dispatches `press' through RUNTIME's ordinary event batch when HOST-ID is still live and carries an enabled `:on-press' handler, allowing translated or decorated controls to invoke the original Host action without exposing closures.

**Returns.** Non-nil when dispatched, or nil when HOST-ID is absent or has no enabled press handler.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or HOST-ID is not an integer. `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-set-host-presentation (runtime host-id key spec)

Attach or update keyed presentation SPEC owned by KEY on integer HOST-ID in RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime; HOST-ID is an integer from `etaf-runtime-host-tree`; KEY is a non-nil symbol naming the owner; SPEC is nil (clear KEY on HOST-ID) or a plist with `:mode` (`decorate`, `override`, `companion-inside`, `companion-after` or `companion-beside`), optional `:priority` (integer, default `50`, lower runs first), and mode-specific payload: `:spans` (list of `((START . END) . FACE)` or `((START . END) :face FACE)`) and/or `:face` for `decorate`, `:text` (string on a text Host) or `:view` (normalized View on a container Host) for `override`, or `:view` (normalized View inheriting the Host's Context and Theme) for companion modes.

**Semantics.** Delegates to `etaf-runtime-set-host-presentations` for one target. Multiple owners coexist in the same Host's presentation bucket: additive `decorate` layers compose over authoritative text without replacing it, coexisting companions stack in ascending `:priority` order, and `override` layers stack by `:priority` with automatic fallback when the top owner clears.

**Returns.** Non-nil when HOST-ID was live and updated, or nil when absent.

**Errors.** `error→ etaf-runtime-error` on unmounted RUNTIME or invalid KEY/SPEC; `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-set-host-presentations (runtime key updates)

Apply a list of `(HOST-ID . SPEC)` presentation UPDATES owned by KEY in mounted RUNTIME in one atomic flush.

**Arguments.** RUNTIME is a mounted Runtime; KEY is a non-nil symbol; UPDATES is a proper list of `(HOST-ID . SPEC)` pairs validated as in `etaf-runtime-set-host-presentation`.

**Semantics.** All changes apply in one Ebox batch and advance `etaf-runtime-revision` without firing `etaf-runtime-after-commit-functions`. Unknown or unmounted HOST-IDs are skipped. Updating an existing presentation of the same KEY and `:mode` patches its companion segment in place; `decorate` entries coexist with companion entries of the same or other keys and survive application text edits; container `override` parks the application's real children offscreen so reactive edits survive until cleared; companion modes keep their Host's layout slot across reconciliation and dispose automatically when the Host unmounts.

**Returns.** The number of Hosts updated.

**Errors.** `error→ etaf-runtime-error` on unmounted RUNTIME or invalid KEY/UPDATES/SPEC; `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-clear-presentations (runtime &optional key)

Remove attached presentations in mounted RUNTIME in one Ebox flush, restoring original Hosts.

**Arguments.** RUNTIME is a mounted Runtime; optional KEY restricts removal to presentations owned by that symbol, or nil removes all.

**Semantics.** Disposes attached presentation segments for KEY without disturbing other coexisting owners, restores original Ebox nodes and authoritative text once no active owner remains on a Host, and advances the revision without firing `etaf-runtime-after-commit-functions`.

**Returns.** The number of Hosts restored.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or KEY is not a symbol; `error→ etaf-render-side-effect-error` during rendering.

## Extensions, metadata, overlays and key layers

Extension engines and external overlays attach to any mounted Runtime through four composable primitives: declarative Runtime metadata, named root-layer overlays, semantic Host actions and text-offset hit testing, and priority-ordered extension key layers that sit strictly below application bindings.

#### Hook: etaf-runtime-meta-change-functions

Abnormal hook run with `(RUNTIME META)` when a mounted Runtime's resolved metadata snapshot changes.

**Semantics.** Fires after `etaf-runtime-set-meta` or when any reactive source (`etaf-ref`, `etaf-computed` or zero-argument function) inside `:meta` produces a changed snapshot. Each function runs in isolation; errors do not stop other listeners.

#### Hook: etaf-runtime-focus-change-functions

Abnormal hook run with `(RUNTIME PREV-HOST-ID NEXT-HOST-ID)` when logical Host focus moves in RUNTIME.

**Semantics.** Fires after focus changes between committed Hosts (or enters/leaves focus, passing nil for the absent endpoint). Each listener runs in isolation so a failing extension cannot break keyboard navigation.

#### Function: etaf-runtime-meta (&optional runtime)

Return a detached read-only copy of mounted RUNTIME's resolved metadata plist.

**Arguments.** RUNTIME defaults to the active or current-buffer Runtime.

**Semantics.** Returns the latest resolved snapshot of the `:meta` plist supplied to `etaf-mount`, `etaf-app-open` or `etaf-runtime-set-meta`, commonly carrying `:app`, `:kind`, `:uri` and `:title`. Returns nil when no metadata was set.

**Returns.** A detached plist, or nil.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

#### Function: etaf-runtime-set-meta (runtime meta)

Replace mounted RUNTIME's metadata declaration with META and return the resolved snapshot.

**Arguments.** RUNTIME is a mounted Runtime. META is nil or a proper keyword plist whose values may be static data, `etaf-ref`, `etaf-computed` or zero-argument functions.

**Semantics.** Disposes any previous metadata watcher scope, evaluates META inside a fresh Scope when reactive sources are present, and notifies `etaf-runtime-meta-change-functions` whenever the resolved snapshot changes.

**Returns.** The detached resolved metadata plist, or nil.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or META is not a valid plist; `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-focus-host (runtime host-id)

Move logical keyboard focus in mounted RUNTIME to integer HOST-ID.

**Arguments.** RUNTIME is a mounted Runtime; HOST-ID is an integer `:id` from `etaf-runtime-host-tree`.

**Semantics.** Locates the committed Host segment and moves Ebox focus to its backing node when the Host is live, focusable and not disabled. Fires `etaf-runtime-focus-change-functions` when focus changes.

**Returns.** Non-nil when focus moved to HOST-ID, or nil when HOST-ID is absent, disabled or not focusable.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or HOST-ID is not an integer; `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-scroll-host-into-view (runtime host-id &optional align)

Scroll enclosing `:overflow scroll`/`auto` containers and displaying windows in RUNTIME so integer HOST-ID is visible.

**Arguments.** RUNTIME is a mounted Runtime; HOST-ID is an integer `:id`; optional ALIGN is `nearest` (default), `top` or `center`.

**Semantics.** Walks ancestor scroll containers from innermost outward and adjusts their scroll offset (and any live window displaying RUNTIME's buffer) so HOST-ID enters view according to ALIGN.

**Returns.** Non-nil when HOST-ID is live and laid out, or nil when absent.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted, HOST-ID is not an integer or ALIGN is invalid; `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-host-text-offset-at (runtime &optional position)

Return text Host character offset and active region details at POSITION in mounted RUNTIME, or nil.

**Arguments.** RUNTIME is a mounted Runtime; POSITION defaults to point in RUNTIME's buffer.

**Semantics.** Resolves POSITION to the innermost committed text Host covering it and maps buffer offsets back to indices inside the Host's authoritative `:text`. When mark/region is active over the same text Host, also populates `:region-start` and `:region-end`.

**Returns.** A plist `(:host-id INT :offset INT :text STR :region-start INT-OR-NIL :region-end INT-OR-NIL)`, or nil when POSITION does not lie on a text Host.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

#### Function: etaf-runtime-set-overlay (runtime key view &optional origin)

Mount, update or clear named root-layer overlay KEY with VIEW in mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime; KEY is a non-nil symbol identifying the overlay owner; VIEW is a normalized View (commonly a `:layer 'root :position 'absolute` box or a fragment of such boxes) or nil to remove KEY; optional ORIGIN is a committed Host reference whose Context and Theme VIEW inherits (defaulting to the root).

**Semantics.** Multiple distinct KEYs coexist independently above the application layout. Updating an existing KEY patches its overlay segment in place. Mounting or patching overlays runs inside a presentation mutation guard and never fires `etaf-runtime-after-commit-functions` or `etaf-runtime-after-flush-functions`, and overlay nodes never appear in `etaf-runtime-host-tree` or `etaf-runtime-inspect-tree`.

**Returns.** Non-nil when changed, or nil when clearing an absent KEY.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or KEY is not a non-nil symbol; `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-clear-overlay (runtime &optional key)

Remove named root-layer overlay KEY (or all overlays when KEY is nil) from mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime; optional KEY is a symbol naming the overlay owner, or nil for all owners.

**Semantics.** Disposes the matching overlay segment(s) in one Ebox batch without firing application commit hooks.

**Returns.** The number of overlays removed.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or KEY is not a symbol; `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-set-key-layer (runtime key entries &optional label priority)

Register or replace an extension key layer owned by KEY on mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime; KEY is a non-nil symbol; ENTRIES is a list of `(KEY-SEQ COMMAND LABEL)` triples (or nil to remove KEY); optional LABEL names the source in key help; optional PRIORITY is an integer (default `50`, lower runs first).

**Semantics.** Extension key layers resolve strictly below Host `:keys` and framework defaults (`Tab`, `ESC`, `?`, `M-g` and direction keys). Any entry attempting to bind a framework-reserved key is rejected with `etaf-renderer-error`. Active unshadowed bindings surface automatically in `etaf-help-data` under `:kind 'extension`.

**Returns.** Non-nil when updated.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or KEY/PRIORITY is invalid; `error→ etaf-renderer-error` when an entry is malformed or binds a reserved key; `error→ etaf-render-side-effect-error` during rendering.

#### Function: etaf-runtime-clear-key-layer (runtime &optional key)

Remove extension key layer KEY (or all extension key layers when KEY is nil) from mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime; optional KEY is a symbol, or nil to clear every layer.

**Semantics.** Drops the matching layer(s) immediately so subsequent key dispatches and `etaf-help-data` reflect the removal.

**Returns.** The number of layers removed.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or KEY is not a symbol; `error→ etaf-render-side-effect-error` during rendering.

## Runtime introspection

Developer tools inspect live mounted Runtimes through read-only on-demand queries plus one controlled reactive-binding write entry, without mutating caches or touching Ebox directly.

#### Function: etaf-runtime-list ()

Return a list of all currently mounted live ETAF Runtimes ordered by mount identity.

**Semantics.** Iterates over mounted Runtimes whose backing buffers are still live and returns them in ascending mount order.

**Returns.** A fresh list of live Runtime objects.

**Errors.** None.

**See also.** `etaf-runtime-for-buffer`, `etaf-runtime-inspect-tree`.

#### Function: etaf-runtime-inspect-tree (&optional runtime)

Return mounted RUNTIME's unified Component and Host tree as read-only data.

**Arguments.** RUNTIME defaults to the active or current-buffer Runtime.

**Semantics.** Walks the committed segment tree, excluding transient surfaces and attached presentation companions. Component nodes carry `:kind` (`component`), `:id`, `:name`, `:key`, `:source-file`, `:render-count`, `:props-summary`, `:root-host-ids` and `:children`. Host nodes carry `:kind` (`host`), `:id`, `:tag`, `:ref`, `:dom-id`, `:classes`, `:text-preview`, `:presentations`, `:geometry`, `:focusable-p`, `:focused-p`, `:disabled-p`, `:has-press-p` and `:children`.

**Returns.** A list of top-level node plists in document order.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**See also.** `etaf-runtime-host-tree`, `etaf-runtime-inspect-host`, `etaf-runtime-inspect-component`.

#### Function: etaf-runtime-host-id-at (runtime &optional position)

Return `(INNERMOST-HOST-ID ... ROOT-HOST-ID)' at POSITION in mounted RUNTIME, or nil.

**Arguments.** RUNTIME is a mounted Runtime; POSITION defaults to point in RUNTIME's buffer.

**Semantics.** Resolves the painted Ebox node at POSITION back to its committed application Host lineage, stepping out of presentation companions to the owning Host.

**Returns.** A list of integer Host IDs from innermost to root, or nil when no Host covers POSITION.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**See also.** `etaf-host-ref-at`, `etaf-runtime-inspect-host`.

#### Function: etaf-runtime-inspect-host (runtime host-id)

Return detailed read-only inspection snapshot for integer HOST-ID in mounted RUNTIME, or nil.

**Arguments.** RUNTIME is a mounted Runtime; HOST-ID is an integer `:id` from `etaf-runtime-inspect-tree` or `etaf-runtime-host-id-at`.

**Semantics.** Gathers box-model metrics, on-demand ECSS cascade provenance attributed to owning Components, exact per-line painted row spans, clipping visibility, sanitized props, behaviors, presentations and focus flags without mutating buffers or caches.

**Returns.** A detached plist for HOST-ID, or nil when HOST-ID is absent.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or HOST-ID is not an integer.

**See also.** `etaf-runtime-inspect-tree`, `etaf-runtime-inspect-component`.

#### Function: etaf-runtime-inspect-component (runtime instance-id)

Return detailed read-only snapshot for integer Component INSTANCE-ID in mounted RUNTIME, or nil.

**Arguments.** RUNTIME is a mounted Runtime; INSTANCE-ID is an integer `:id` of a `:kind component` node from `etaf-runtime-inspect-tree`.

**Semantics.** Reports component name, key, source file, definition symbol, root Host IDs, render count, props, named bindings (classifying `ref`, `computed`, `resource`, `data-controller` and plain values with versions, subscriber/dependency summaries and editability), inherited Context entries and resolved local refs.

**Returns.** A detached plist for INSTANCE-ID, or nil when INSTANCE-ID is absent or disposed.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted or INSTANCE-ID is not an integer.

**See also.** `etaf-runtime-set-component-binding`, `etaf-runtime-inspect-tree`.

#### Function: etaf-runtime-set-component-binding (runtime instance-id binding-name new-value)

Write NEW-VALUE to writable `etaf-ref' BINDING-NAME of Component INSTANCE-ID in mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime; INSTANCE-ID is a live integer Component instance ID; BINDING-NAME is a declared `:bindings` symbol; NEW-VALUE is the replacement value.

**Semantics.** Locates the declared binding and writes NEW-VALUE through `etaf-set-value` when it holds a writable `etaf-ref`, participating in the ordinary reactive commit path. Non-ref bindings (such as `etaf-computed`) are rejected without mutating state.

**Returns.** t on success.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted, INSTANCE-ID or BINDING-NAME is unknown, or the binding is not a writable `etaf-ref`; `error→ etaf-render-side-effect-error` during rendering.

**See also.** `etaf-runtime-inspect-component`, `etaf-set-value`.

#### Function: etaf-runtime-inspect-focus (runtime)

Return detached focus, region and effective key-scope diagnostics for mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime.

**Semantics.** Collects the currently focused Host ID and reference, native input session state, active `etaf-direction-scheme`, ordered focus stops with tab-index and focus-group metadata, declared regions and the effective `etaf-help-data` snapshot.

**Returns.** A detached plist with `:focused-host-id`, `:focused-host-ref`, `:input-active-p`, `:direction-scheme`, `:stops`, `:regions` and `:help`.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**See also.** `etaf-focused-host-ref`, `etaf-help-data`.

#### Function: etaf-runtime-commit-summary (runtime)

Return a lightweight summary plist of mounted RUNTIME's latest commit.

**Arguments.** RUNTIME is a mounted Runtime.

**Semantics.** Reads the Runtime's revision, latest instance counts (`:new-instances`, `:updated-instances`, `:retired-instances`) and latest `etaf-runtime-update-report` in constant time without walking the tree.

**Returns.** A detached plist with `:rev`, `:new-instances`, `:updated-instances`, `:retired-instances` and `:update-report`.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**See also.** `etaf-runtime-update-report`, `etaf-runtime-after-commit-functions`.

## Errors and recovery

#### Error: etaf-runtime-error

ETAF runtime error.

**Semantics.** The condition is signaled when a Runtime operation cannot be completed: an unresolved Runtime, a malformed mount option, or a retained update that fails before or during publication. Catch this condition with `condition-case`; failed calls do not return a value. The data is a list; its first element is usually a message string, and some messages carry the offending value, reference or underlying condition as further elements.

| Message | Cause |
| --- | --- |
| `"ETAF runtime is not mounted"` | A flush, retained update or other operation required a mounted Runtime |
| `"Mount options must be a plist"` | OPTIONS is not a proper plist |
| `"Unknown mount option"` | An option key outside `:viewport-width`, `:viewport-height` and `:observer` |
| `"Invalid :viewport-width"`, `"Invalid :viewport-height"` | A dimension that is neither nil nor a positive number |
| `"Invalid :observer"` | An observer that is neither nil nor a function |
| `"Unknown committed Host"` | A retained update named a reference that is not a committed Host |
| `"Host cannot hold content"` | A content update addressed a Host whose node is not a text node, such as a Box |
| `"Invalid Host content updates"` | UPDATES is not a proper alist of reference-to-string/image entries |
| `"Invalid Host geometry updates"` | UPDATES is not a proper alist of reference-to-plist entries |
| `"Host geometry update rejected"` | Ebox rejected a geometry property or value; the data holds the affected references and the underlying condition |

**See also.** [Reactivity](reactivity.md#errors-and-recovery) for the reactive conditions, [Views](views.md#errors-and-recovery) for `etaf-renderer-error`, and [Atomic commits](#atomic-commits) for what a failed commit leaves in place.

### Recovery

| Failure | What remains |
| --- | --- |
| A mount whose first publication fails | The buffer exists with its previous content and no Runtime; the condition propagates |
| `etaf-unmount` on an unmounted Runtime | The call signals; the buffer and the disposed Runtime are unchanged |
| A flush with a failing effect | The buffer keeps the last commit and the revision does not advance; the failing work stays parked and the flush or the next drain reports the condition again |
| A pre or render effect fails in a commit | The whole uncommitted work is rolled back: the last committed output, the same revision, and refs that keep their written values; the work is retried at the next drain or flush |
| A post effect fails | The commit stays: the buffer shows the new output and the revision advanced; the condition is signaled at the end of the drain |
| A rejected content update | Nothing changes: the targets and values are validated before the first replacement, and the committed buffer keeps its content |
| A rejected geometry value | The update signals and publishes no new layout for the rejected properties, but the rejected value is retained on the Host, so later geometry updates for that Host keep failing until the View re-renders it |
| A retained update whose value the View does not render | The retained value stays until the View renders different text or geometry for that Host; keep the View and the retained value consistent |
| A retained update against an unmounted Runtime | The call signals; the disposed Runtime and the buffer content are unchanged |

The Runtime does not keep a copy of the View to restore from: the View is the authority, and the recovery route for a Host whose retained values have drifted is always to publish the View again — change the state the Host reads, or remount the application.

**See also.** `etaf-mount`, `etaf-runtime-flush` and `etaf-runtime-update-host-geometry`.
