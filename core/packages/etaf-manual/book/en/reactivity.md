# Reactivity

The reactive system holds application state and keeps everything derived from it current: computed values, watchers, effects and the output of mounted Runtimes. It belongs to the ETAF layer and is loaded by `(require 'etaf)`. The core does not depend on Views or Runtimes, so the same graph serves application code, Components and every mounted Runtime.

Read this chapter before the chapters on [Components](components.md) and [Runtime](runtime.md), which build on the ownership and timing rules defined here.

<!-- index: reactive graph; state; dependency tracking -->

## Model

### Sources and observers

A *source* holds a value. There are two kinds:

- a *ref*, a writable cell created by `etaf-ref`;
- a *computed*, a read-only value derived by a function and created by `etaf-computed`.

An *observer* depends on sources. Computeds are observers as well as sources. The other observers are *effects*: functions that the system runs again after a source they read has changed. Watchers created by `etaf-watch`, effects created by `etaf-watch-effect`, the watcher inside every `etaf-selector`, and the render bindings of mounted Runtimes are all effects.

A *Scope* owns computeds, effects, child Scopes and cleanup functions, and disposes them together. Refs are plain values: no Scope owns them, and garbage collection reclaims them when they become unreachable.

### Dependency tracking

<!-- index: tracking; dependencies -->

While an observer runs, each `etaf-value` call records an edge from the source it reads to that observer. These edges are the observer's *dependencies*.

- Each run replaces the previous set. A source the latest run did not read is no longer a dependency, so a conditional read subscribes only to the branch that was taken.
- Reading the same source several times in one run records one edge.
- When a run signals an error, the observer keeps its previous dependencies in addition to the sources it read before the error, so a later change to either set runs it again.
- Reads outside a running observer are not tracked. Watcher callbacks, cleanup functions and the old-value read of `etaf-update-value` run untracked even when they happen inside an observer.

### Push and pull

<!-- index: push-pull; dirty state; check state -->

Every observer is in one of three states:

| State | Meaning |
| --- | --- |
| clean | Up to date with all dependencies. |
| check | A computed it depends on, directly or transitively, may have changed. |
| dirty | A dependency is known to have changed. |

A write *pushes*: the ref's direct observers become dirty, and observers that reach the ref only through computeds become check. An effect that leaves the clean state is queued for its phase. Nothing is evaluated during the push.

A queued effect *pulls* before it runs. A check effect first brings each computed dependency up to date, in dependency order. When none of them changed value, the effect returns to clean without running. A dirty effect runs.

Computeds are lazy. A computed is evaluated only when something reads it. A computed that nothing reads stays dirty at no cost, however often its inputs change.

Two guarantees follow. A computed whose new result compares equal to its previous one stops the propagation: its observers do not run. And no effect sees a half-updated graph, because all writes made before a drain are applied before any effect runs, and computeds are refreshed before an effect reads them.

### Phases

<!-- index: phases; pre phase; render phase; post phase -->

Queued effects run in three phases:

| Phase | Effects | Relative to buffer output |
| --- | --- | --- |
| pre | Watchers and effects created with `:flush 'pre`, the default | Before mounted Runtimes write their buffers |
| render | Runtime render bindings: dynamic View properties, `expr` children, keyed lists and Component inputs | Produce the next output |
| post | Watchers and effects created with `:flush 'post` | After mounted Runtimes have written their buffers |

Within a phase, effects run in creation order.

### Draining

<!-- index: drain; delivery -->

*Draining* runs the queued effects until the graph is settled. A write outside any batch drains before the writing function returns. Inside a batch, effects wait until the outermost batch ends. Event callbacks and Action handlers run inside a batch, so writes they make are delivered together when the callback returns.

A drain repeats these steps while any of them finds work:

1. Run the pre queue.
2. Run the render queue.
3. Commit: each mounted Runtime with changed output writes its buffer once.
4. Run the post queue.

After each step the drain starts again from step 1, so a post watcher that writes a ref causes a further pre, render and commit pass. When the graph is settled, the functions queued by `etaf-next-tick` run.

```elisp :figure A ref feeds a computed, which feeds an effect
(etaf-view
 (row :item-gap '(ch 2)
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "ref"))
   (text :color (etaf-theme-token :ui-muted-fg "#526174") "→")
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
        (text :color (etaf-theme-token :ui-accent "#0969da") "computed"))
   (text :color (etaf-theme-token :ui-muted-fg "#526174") "→")
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "effect"))))
```

## Refs

A ref is a writable, *shallow* reactive cell. Reading it with `etaf-value` tracks the read; writing it with `etaf-set-value`, `setf` or `etaf-update-value` notifies its observers when the new value differs from the old one.

Two Component functions with similar names are not reactive sources. `etaf-local-ref` returns a Host reference to pass to `:ref` and to Host query, focus and event functions, and `etaf-state` returns the result of a Component's setup. Calling either one records no dependency.

#### Function: etaf-ref (initial-value &key test name)

Create a writable reactive cell holding INITIAL-VALUE and return it.

**Arguments.** INITIAL-VALUE is any Lisp value. It is stored as is, without copying. TEST, when non-nil, is a function called as `(TEST OLD NEW)` that returns non-nil when a write does not change the value; it replaces the default equality described in [Equality](#equality). NAME labels the ref in error data and diagnostics.

**Semantics.** Creating a ref is not tracked and registers it with no Scope.

**Returns.** A ref record, for which `etaf-ref-p` is non-nil.

**Errors.** `error→ etaf-render-side-effect-error` with data `(create-ref)` during rendering. `error→ wrong-type-argument` with data `(functionp TEST)` when TEST is non-nil and not a function.

**Example.**

```elisp
(let ((count (etaf-ref 0 :name 'count)))
  (etaf-ref-p count))
;; ⇒ t
```

#### Function: etaf-ref-p (x)

Return non-nil when X is a ref created by `etaf-ref`. A computed is not a ref: `(etaf-ref-p (etaf-computed #'ignore))` is nil.

#### Function: etaf-value (source)

Return the current value of reactive SOURCE and track the read.

**Arguments.** SOURCE is a ref or a computed.

**Semantics.** For a ref, return its stored value. For a computed, first bring it up to date (see [Computed values](#computed-values)), then return the result. When an observer is running, the read becomes one of its dependencies.

`etaf-value` is a generalized variable: `(setf (etaf-value SOURCE) VALUE)` expands to `(etaf-set-value SOURCE VALUE)`, so `cl-incf`, `cl-decf` and `push` work on refs. `push` builds a new cons, so it always notifies.

**Errors.** `error→ wrong-type-argument` with data `(etaf-reactive-source-p SOURCE)` when SOURCE is neither a ref nor a computed. Errors from a computed's getter propagate to the caller.

#### Function: etaf-set-value (source new-value)

Store NEW-VALUE in the ref SOURCE and return NEW-VALUE.

**Semantics.**

1. When the ref's test, or the default equality, reports that the old value and NEW-VALUE are the same, nothing happens. The ref keeps its old object, even if NEW-VALUE is a different object, and no observer is notified.
2. Otherwise the ref stores NEW-VALUE and pushes a change to its observers. Outside a batch, the drain runs before `etaf-set-value` returns. Inside a batch, the new value is readable at once and the observers wait for the outermost batch.

**Returns.** NEW-VALUE, in both cases.

**Errors.** `error→ etaf-render-side-effect-error` with data `(write NAME)` during rendering, where NAME is the ref's name. `error→ etaf-reactive-error` with data `("Reactive value is read-only" NAME)` when SOURCE is a computed, where NAME is the computed's name; when SOURCE is not reactive at all, the second element is its `type-of`. Errors from the drain propagate after the write: the ref keeps NEW-VALUE.

#### Function: etaf-update-value (source function &rest arguments)

Replace the value of the ref SOURCE with `(apply FUNCTION OLD ARGUMENTS)`, where OLD is its current value, and return the replacement.

**Semantics.** The write checks run first: during rendering, or when SOURCE is not a ref, the call signals before FUNCTION runs. FUNCTION then runs exactly once. OLD is read untracked. FUNCTION must return a new value without mutating OLD and without external effects; there is no implicit copy. The result is written with `etaf-set-value`, so the same equality, notification and batching rules apply.

**Returns.** The replacement value.

**Errors.** The errors of `etaf-set-value`, raised before FUNCTION runs. `error→ wrong-type-argument` with data `(functionp FUNCTION)` when FUNCTION is not a function. When FUNCTION signals, the ref is unchanged and the error propagates. When the write succeeds and a later drain fails, the ref keeps the replacement.

**Example.**

```elisp
(let ((task (etaf-ref '(:title "Draft" :done nil))))
  (etaf-update-value
   task (lambda (old done) (plist-put (copy-sequence old) :done done)) t)
  (etaf-value task))
;; ⇒ (:title "Draft" :done t)
```

### Equality

<!-- index: equality; shallow equality; identity -->

Refs, computeds and watchers decide whether a value changed with a TEST function when one is given, and otherwise with the default equality:

| Value | Compared by |
| --- | --- |
| Conses (lists), vectors, records, hash tables, functions | Identity (`eq`) |
| Buffers, markers, windows, frames, overlays, processes | Identity (`eq`) |
| Everything else: numbers, strings, symbols and so on | `equal` |

Consequences:

- Mutating an object in place, with `setcar`, `aset`, `puthash` or a destructive `plist-put`, does not notify anything. Store a new object.
- Storing a fresh list notifies, even when its elements equal the old ones.
- Storing an `equal` string or number is a no-op.
- `:test #'equal` makes a ref or computed treat structurally equal lists as unchanged.

```elisp
(let* ((items (etaf-ref (list 1 2)))
       (runs 0)
       (stop (etaf-watch-effect
              (lambda () (etaf-value items) (setq runs (1+ runs))))))
  (setcar (etaf-value items) 9)          ; in place: not seen
  (etaf-set-value items (list 9 2))      ; new object: runs again
  (funcall stop)
  runs)
;; ⇒ 2
```

## Computed values

<!-- index: computed; derived state; laziness -->

A computed derives a value from other sources with a getter function. It is read-only, lazy and cached.

#### Function: etaf-computed (getter &key test name)

Create a computed value derived by the zero-argument function GETTER and return it. The getter does not run yet.

**Arguments.** GETTER computes the value; every source it reads with `etaf-value` becomes a dependency. TEST, when non-nil, is called as `(TEST OLD NEW)` and returns non-nil when a new result counts as unchanged. NAME labels the computed in error data and diagnostics.

**Semantics.**

- The first `etaf-value` call evaluates GETTER and caches the result.
- Later reads return the cached value until a dependency changes. The computed then becomes dirty and is evaluated again at the next read.
- When the new result is the same as the old one under TEST or the default equality, observers of the computed are not run again.
- When a Scope is active, it owns the computed; a computed created while the active Scope has stopped has no owner. After its Scope stops, the computed releases its dependencies; each later read evaluates GETTER again untracked and caches nothing.
- Treat GETTER as rendering code: read sources and return a value. Do not write refs or create reactive objects in it. When it is evaluated during rendering, those operations signal `etaf-render-side-effect-error`.
- Mounted consumers keep their published output when all their reactive inputs compare unchanged. A computed created during Component setup, or during another Runtime operation, runs its getter in that operation's environment on every later run, so `etaf-inject`, `etaf-current-runtime` and `etaf-viewport` keep working after the first run; see [Creation environment](#creation-environment).

**Returns.** A computed record, for which `etaf-computed-p` is non-nil.

**Errors.** `error→ etaf-render-side-effect-error` with data `(create-computed)` during rendering. `error→ wrong-type-argument` with data `(functionp GETTER)` or `(functionp TEST)` for a non-function argument. When GETTER signals during a read, the error propagates to the reader; the computed keeps its previous value, stays dirty, and evaluates again at the next read. `error→ etaf-reactive-error` with data `("Recursive computed evaluation" NAME)` when GETTER reads its own computed, directly or through other computeds.

**Example.**

```elisp
(let* ((count (etaf-ref 2))
       (double (etaf-computed (lambda () (* 2 (etaf-value count))))))
  (list (etaf-value double)
        (progn (etaf-set-value count 5) (etaf-value double))))
;; ⇒ (4 10)
```

#### Function: etaf-computed-p (x)

Return non-nil when X is a computed created by `etaf-computed`.

## Watchers and effects

An effect runs a function now and again after the sources it read change. ETAF offers two forms. `etaf-watch` observes one value and calls a callback with its new and old values; the callback itself is untracked. `etaf-watch-effect` runs a function whose every read is tracked.

#### Function: etaf-watch (source callback &key immediate (flush 'pre) test name)

Watch SOURCE and call CALLBACK as `(CALLBACK NEW OLD)` when its value changes. Return a zero-argument function that stops the watcher.

**Arguments.**

- SOURCE is a ref, a computed or a zero-argument function. A function is evaluated with tracking, so it can combine several sources: `(lambda () (list (etaf-value x) (etaf-value y)))`.
- CALLBACK receives the new and the previous value.
- IMMEDIATE, when non-nil, also calls CALLBACK for the initial value, with OLD nil.
- FLUSH selects the phase: `pre`, the default, or `post`.
- TEST, when non-nil, is called as `(TEST OLD NEW)`. The default is SOURCE's own test when SOURCE is a ref or computed with one, and otherwise the default equality.
- NAME labels the watcher in diagnostics.

**Semantics.**

1. `etaf-watch` evaluates SOURCE at once to record its dependencies and its initial value. Without IMMEDIATE, CALLBACK is not called yet.
2. When a dependency changes, the watcher evaluates SOURCE again in its phase. If the value is the same as the recorded one, nothing else happens.
3. Otherwise the watcher records the new value, runs the cleanup returned by the previous callback, if any, and calls CALLBACK untracked.
4. When CALLBACK returns a function, that function is the cleanup for this call. It runs before the next callback and when the watcher stops.

The watcher records the new value before it calls CALLBACK. When CALLBACK signals, the same value is not delivered again.

When a Scope is active, it owns the watcher. A watcher created during Component setup, or during another Runtime operation, calls CALLBACK in that Component's environment on every later run; see [Creation environment](#creation-environment).

**Returns.** A stop function. Calling it releases the dependencies, removes the watcher from its Scope and runs the pending cleanup. Calling it again does nothing.

**Errors.** `error→ etaf-render-side-effect-error` with data `(watch)` during rendering. `error→ wrong-type-argument` with data `(functionp CALLBACK)`. `error→ etaf-reactive-error` with data `("Watch source must be reactive or callable" SOURCE)` or `("Invalid watcher flush" FLUSH)`. `error→ etaf-reactive-error` with data `("Inactive Scope" SCOPE)` when the active Scope has stopped.

**Example.**

```elisp
(let* ((count (etaf-ref 0))
       seen
       (stop (etaf-watch count (lambda (new old) (push (cons old new) seen)))))
  (etaf-set-value count 1)
  (etaf-set-value count 1)               ; same value: no call
  (etaf-set-value count 2)
  (funcall stop)
  (nreverse seen))
;; ⇒ ((0 . 1) (1 . 2))
```

#### Function: etaf-watch-effect (function &key (flush 'pre) name)

Run the zero-argument FUNCTION now, and again after any source it read changes. Return a zero-argument function that stops the effect.

**Arguments.** FUNCTION is tracked on every run. FLUSH is `pre`, the default, or `post`, as for `etaf-watch`. NAME labels the effect in diagnostics.

**Semantics.** Before each run after the first, the cleanup returned by the previous run, if any, is called untracked. When FUNCTION returns a function, that function becomes the cleanup for the run; the effect also calls it when it stops. The Scope and creation-environment rules of `etaf-watch` apply.

When a source the effect already depends on changes while the effect is running, for example because FUNCTION writes it, the effect runs again in the same drain. Dependencies are recorded when a run ends, so a write during the first run does not cause a rerun. An effect that writes a different value to a source it reads on every run never settles.

**Returns.** A stop function, as for `etaf-watch`.

**Errors.** `error→ etaf-render-side-effect-error` with data `(watch-effect)` during rendering. `error→ wrong-type-argument` with data `(functionp FUNCTION)`. `error→ etaf-reactive-error` for an invalid FLUSH or an inactive Scope, as for `etaf-watch`. An error from the first run propagates from `etaf-watch-effect`; the effect stays registered with the dependencies it read before the error.

### Cleanup functions

<!-- index: cleanup function -->

A cleanup returned by a watcher callback or an effect function releases what that call acquired: a timer, a process, a buffer-local hook. Each cleanup runs at most once: before the next call, or when the watcher or effect stops, whichever comes first. Stopping the owning Scope stops the effect, so its last cleanup runs then.

### Creation environment

<!-- index: creation environment; Component environment -->

A watcher or effect created during Component setup, or during another Runtime operation, captures that operation's environment: the Component instance, its Context and its Runtime. A computed created in the same way captures it for its getter. Every later run re-enters the environment as a lifecycle operation, so `etaf-inject`, `etaf-current-runtime` and `etaf-viewport` keep working after the first run, and the callback is not treated as rendering. A reactive callback created outside any Runtime operation runs in the dynamic environment of the drain.

```elisp :run
(etaf-define-component demo-reactivity-lab ()
  :bindings ((n (etaf-ref 2))
             (factor (etaf-ref 3))
             (runs (etaf-ref 0))
             (log (etaf-ref nil)))
  :setup
  (let ((total (etaf-computed (lambda () (* (etaf-value n) (etaf-value factor)))
                              :name 'demo-total)))
    (etaf-watch-effect
     (lambda ()
       (let ((line (format "n=%d × %d = %d" (etaf-value n)
                           (etaf-value factor) (etaf-value total))))
         (etaf-set-value runs (1+ (etaf-value runs)))
         (etaf-set-value log (append (etaf-value log) (list line)))))))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (row :item-gap '(ch 2)
               (etaf-number-input :label "n" :value 2 :min 0 :max 9
                                  :on-change (lambda (v) (etaf-set-value n v)))
               (etaf-number-input :label "倍数" :value 3 :min 1 :max 4
                                  :on-change (lambda (v) (etaf-set-value factor v))))
          (text (expr (format "结算次数：%d" (etaf-value runs))))
          (text :color (etaf-theme-token :ui-muted-fg "#526174") (expr (format "最近一次：%s"
                                               (or (car (last (etaf-value log))) "—"))))))
(etaf-view (demo-reactivity-lab))
```

## Selectors

<!-- index: selector; selection -->

A selector answers "is this key the selected one?" for many keys while notifying only the keys whose answer changed.

#### Function: etaf-selector (source &key (test 'equal) name)

Return a function of one argument KEY that is non-nil while the value of the reactive SOURCE equals KEY under TEST.

**Arguments.** SOURCE is a ref or a computed. TEST is a hash table test: `eq`, `eql` or `equal`. NAME labels the selector's watcher and cells in diagnostics.

**Semantics.** Each KEY has its own reactive cell. A reader that calls the selector depends only on the cell of the KEY it asked about. When SOURCE changes from A to B, the selector updates the cells of A and B in one batch, so only the readers of those two keys run again. A long list that highlights its selected row therefore re-renders two rows when the selection moves, not every row.

Create the selector during Component setup or `:bindings`; the Component's Scope then owns its watcher. Call the selector inside the View property or render that should update, for example `:background-color (if (funcall selected id) 'highlight 'default)`.

Cells are created on first use. When the number of cells exceeds a threshold, 256 at first, the selector discards the cells that no observer uses and sets the threshold to the larger of 256 and twice the number of remaining cells.

**Returns.** A function of one argument.

**Errors.** `error→ etaf-render-side-effect-error` with data `(selector)` during rendering. `error→ wrong-type-argument` with data `((member eq eql equal) TEST)` for any other TEST, and with data `(etaf-reactive-source-p SOURCE)` when SOURCE is not reactive.

**Example.** The bold row follows the selected key; pressing a row moves it.

```elisp :run
(etaf-define-component demo-selection ()
  :bindings ((current (etaf-ref 'beta))
             (current-p (etaf-selector current)))
  :view
  (column
   (text :for (id '(alpha beta gamma)) :key id
         :role 'button :tab-index 0
         :font-weight (if (funcall current-p id) 'bold 'normal)
         :on-press (lambda () (etaf-set-value current id))
         (expr (symbol-name id)))))
(etaf-view (demo-selection))
```

## Batches and ticks

<!-- index: batch; next tick -->

A batch groups several writes so that observers see them together. `etaf-next-tick` defers work until the output of pending writes is published.

#### Macro: etaf-batch (&rest body)

Evaluate BODY as one reactive batch and return the value of its last form, or nil for an empty BODY. This is `(etaf-call-with-batch (lambda () BODY...))`; its semantics and errors are those of `etaf-call-with-batch`.

#### Function: etaf-call-with-batch (function)

Call the zero-argument FUNCTION as one reactive batch and return its result after pending reactive work has finished.

**Semantics.**

- Ref writes inside FUNCTION take effect immediately and are readable at once. Effects of existing observers, and Runtime updates, wait until the outermost batch ends.
- A nested batch joins the outermost one. Event callbacks and Action handlers already run inside a batch, so an explicit batch inside them adds nothing.
- When the outermost batch ends, the drain runs and `etaf-call-with-batch` returns after it, including the `etaf-next-tick` functions.
- A batch provides no rollback. Writes stay when FUNCTION fails, and there is no atomic publication across Runtimes; each Runtime's commit follows its own failure contract.
- The batch is synchronous. Use it on the main Emacs event loop. A timer, process filter or other asynchronous callback that runs later is not part of the batch; it needs its own batch.

**Returns.** FUNCTION's result.

**Errors.** `error→ etaf-render-side-effect-error` with data `(batch)` during rendering. `error→ wrong-type-argument` with data `(functionp FUNCTION)`. When FUNCTION signals an error or quits, the pending work still drains, any error from that drain is discarded, and the original condition is signaled again. When FUNCTION returns normally and the drain fails, the drain's first error is signaled.

**Example.**

```elisp
(let* ((x (etaf-ref 0))
       (y (etaf-ref 0))
       observed
       (stop (etaf-watch (lambda () (list (etaf-value x) (etaf-value y)))
                         (lambda (new _old) (push new observed)))))
  (etaf-batch
    (etaf-set-value x 3)
    (etaf-set-value y 4))
  (funcall stop)
  observed)
;; ⇒ ((3 4))     ; one delivery, never (3 0)
```

#### Function: etaf-next-tick (function)

Call the zero-argument FUNCTION once pending reactive work has been published, and return nil.

**Semantics.** Inside a batch, an event callback or an effect, FUNCTION is queued. It runs after the outermost batch has drained and every mounted Runtime has written its buffer, so Hosts created by earlier writes have positions and scroll ranges. Use it to scroll to, or focus, a row that a callback has just added. Outside a batch nothing is pending, and FUNCTION runs immediately.

Queued functions run in the order they were queued. Functions queued while they run join the same pass. They run even when the drain before them failed.

**Returns.** nil.

**Errors.** `error→ etaf-render-side-effect-error` with data `(next-tick)` during rendering. `error→ wrong-type-argument` with data `(functionp FUNCTION)`. When queued functions signal, the remaining ones still run, and then the first of their errors is signaled. When the drain and a queued function both fail, the queued function's error is the one signaled.

## Scopes

<!-- index: Scope; ownership; disposal -->

A Scope is the unit of reactive ownership. The *active Scope* owns what is created while it is active:

| Created with | Owned by the active Scope |
| --- | --- |
| `etaf-computed` | The computed |
| `etaf-watch`, `etaf-watch-effect`, `etaf-selector` | The effect, or the selector's watcher |
| `etaf-effect-scope` without `:detached` | The child Scope |
| `etaf-on-scope-dispose` | The cleanup function |
| `etaf-ref` | Nothing: refs are not owned |

Each Component instance has a Scope. Its `:bindings` and setup run with that Scope active, and unmounting the instance stops it. Code outside Components creates a Scope with `etaf-effect-scope`, enters it with `etaf-scope-run` and stops it with `etaf-scope-stop`.

#### Function: etaf-effect-scope (&key detached name)

Create a Scope and return it.

**Arguments.** DETACHED, when non-nil, creates the Scope without a parent. NAME labels the Scope in diagnostics.

**Semantics.** Without DETACHED, the active Scope, if any, becomes the parent. A parent stops its child Scopes when it stops. A Scope without a parent, either because it is detached or because no Scope was active, must be stopped by its creator with `etaf-scope-stop`; stop it in `unwind-protect` when it lives for the extent of a form.

**Returns.** A new, active Scope.

**Errors.** `error→ etaf-render-side-effect-error` with data `(create-scope)` during rendering. `error→ etaf-reactive-error` with data `("Inactive parent Scope" PARENT)` when the active Scope has stopped.

#### Function: etaf-scope-run (scope function)

Call the zero-argument FUNCTION with SCOPE as the active Scope and return its value. Everything FUNCTION creates that a Scope can own belongs to SCOPE.

**Errors.** `error→ etaf-reactive-error` with data `("Cannot enter an inactive Scope")` when SCOPE is not a Scope or has stopped. Errors from FUNCTION propagate; SCOPE stays active and keeps what FUNCTION created before the error.

#### Function: etaf-scope-stop (scope)

Dispose SCOPE and return the conditions collected during the teardown.

**Semantics.** Stopping proceeds in this order:

1. Mark SCOPE inactive. From now on it cannot be entered and does not accept new effects, computeds, child Scopes or cleanups.
2. Stop the child Scopes, recursively.
3. Stop the owned effects, running their pending cleanups, and stop the owned computeds.
4. Run the cleanup functions in reverse registration order.
5. Remove SCOPE from its parent.

An error or quit in steps 2 to 4 does not abort the teardown: it is recorded, and the remaining work runs.

**Returns.** A list with one condition, `(SYMBOL . DATA)`, per failure, or nil when everything stopped cleanly. Do not rely on the order of the list. Stopping a Scope that has already stopped, or a value that is not a Scope, returns nil.

**Errors.** `error→ etaf-render-side-effect-error` with data `(stop-scope)` during rendering. Teardown failures are returned, not signaled.

#### Function: etaf-on-scope-dispose (function)

Register the zero-argument FUNCTION to run when the active Scope stops, and return FUNCTION.

**Semantics.** Cleanups run once, after the Scope's child Scopes and effects have stopped, in reverse registration order. An error from a cleanup is collected by `etaf-scope-stop` and does not prevent the others from running.

**Errors.** `error→ etaf-render-side-effect-error` with data `(register-scope-cleanup)` during rendering. `error→ wrong-type-argument` with data `(functionp FUNCTION)`. `error→ etaf-reactive-error` with data `("Cleanup registration requires an active Scope")` when no Scope is active or the active Scope has stopped.

**Example.**

```elisp
(let ((scope (etaf-effect-scope :detached t))
      (count (etaf-ref 0))
      log)
  (unwind-protect
      (etaf-scope-run
       scope
       (lambda ()
         (etaf-watch-effect (lambda () (push (etaf-value count) log)))
         (etaf-on-scope-dispose (lambda () (push 'released log)))
         (etaf-set-value count 1)))
    (etaf-scope-stop scope))
  (etaf-set-value count 2)               ; the effect has stopped
  (nreverse log))
;; ⇒ (0 1 released)
```

## Semantic details

### The path of a write

When application code writes a ref outside a batch:

1. The ref stores the value. When it compares equal to the old one, the path ends here.
2. Its direct observers become dirty; observers that depend on it through computeds become check. Effects that left the clean state are queued.
3. The drain starts. Pre effects run in creation order; each check effect first refreshes its computed inputs and is skipped when none of them changed.
4. Render effects run in the same way and produce Runtime output.
5. Each mounted Runtime with changed output commits and writes its buffer once.
6. Post effects run.
7. Steps 3 to 6 repeat while any of them finds work.
8. The `etaf-next-tick` functions run.
9. The first error collected in steps 3 to 6 is signaled again; otherwise the write returns.

Inside a batch, steps 1 and 2 happen at each write, and steps 3 to 9 happen once, when the outermost batch ends.

### Rendering is free of side effects

<!-- index: rendering; side effects -->

*Rendering* is the evaluation of View content: dynamic Host properties, `expr` children, `:render` bodies and the computeds they read. Rendering may read sources but must not change the graph. These operations signal `etaf-render-side-effect-error` during rendering:

| Operation | Condition data |
| --- | --- |
| `etaf-ref` | `(create-ref)` |
| `etaf-computed` | `(create-computed)` |
| `etaf-watch` | `(watch)` |
| `etaf-watch-effect` | `(watch-effect)` |
| `etaf-selector` | `(selector)` |
| `etaf-effect-scope` | `(create-scope)` |
| `etaf-on-scope-dispose` | `(register-scope-cleanup)` |
| `etaf-scope-stop` | `(stop-scope)` |
| `etaf-call-with-batch`, `etaf-batch` | `(batch)` |
| `etaf-next-tick` | `(next-tick)` |
| `etaf-set-value`, `setf`, `etaf-update-value` | `(write NAME)` |

Event callbacks, lifecycle callbacks and the reruns of effects created during setup are not rendering; they may write. Create reactive objects in `:bindings` or setup, and write them from callbacks.

### Mounted Runtimes

<!-- index: Runtime commit; publication -->

A mounted Runtime takes part in every drain:

- Its render bindings are render-phase effects. A binding whose computed inputs all compare unchanged is skipped, so its output is not published again.
- Between the render and post phases, each Runtime with changed output commits once. The whole drain runs inside one Ebox batch, so the buffer is written once per commit.
- Post watchers see the written buffer.
- When a pre or render effect fails, the Runtime rolls back the commit in progress and keeps its last committed output. The effects that ran are kept and run again at the next drain that has work, or at an explicit `etaf-runtime-flush`. Application refs keep their written values. A persistent failure therefore leaves the last committed output on screen until its cause is fixed.

### Sources the framework publishes

<!-- index: framework sources; viewport; animation -->

Several framework functions return reactive sources, so a render, computed or effect that reads them reruns like any other observer. Each is described with its subsystem.

| Function | Source |
| --- | --- |
| `etaf-prop` | A Component input as a read-only source; read it with `etaf-value` in computed getters and watchers |
| `etaf-runtime-viewport` | The canvas viewport of a mounted Runtime as `(WIDTH . HEIGHT)`; a reader reruns after the viewport changes, including the automatic refit after a window size change |
| `etaf-viewport-region` | A Component that publishes its committed box as the viewport of every Component below it |
| `etaf-transition`, `etaf-animation-frames` | Refs written by the [animation clock](animation.md); each tick is one batch, so it causes at most one commit per Runtime |
| `etaf-data-status`, `etaf-data-mutation-outcome` | The status ref and the mutation outcome of a Data Controller |

Two related functions are not reactive. `etaf-runtime-revision` returns an integer that increases once for every commit that changed the buffer; compare two revisions to observe that a change was published. `etaf-host-ref-size` queries committed geometry; it does not publish and is not meant for per-frame polling.

The functions `etaf-runtime-update-host-content`, `etaf-runtime-update-host-contents`, `etaf-runtime-update-host-geometry` and `etaf-runtime-update-host-geometries` change one or more Hosts and write the buffer once without going through the graph. The View remains the authority: the next ordinary publication must render the same content, or the Host is reconciled to what the View renders.

### Asynchronous code

A batch covers only the synchronous extent of its function. A timer, process filter or sentinel runs later, outside any batch: its writes drain immediately unless it opens its own batch. Several related writes from such a callback belong in one `etaf-batch`.

### Cost

- A read costs constant time, plus the refresh of a stale computed value.
- A write costs time proportional to the observers it reaches. A computed value passes a change on only when it first becomes stale, so a computed value that is already stale absorbs further writes.
- A run that reads the same sources in the same order as before does not change any subscriptions.
- Sorting the queue of a phase costs O(n log n) in the number of queued effects; a queue of one effect is not sorted.

## Errors and recovery

#### Error: etaf-reactive-error

The reactive graph rejected an operation. Catch it with `condition-case`; a call that signals it returns no value. The first element of the data is a message string:

| Message | Raised by |
| --- | --- |
| `"Reactive value is read-only"` | A write to a computed or a non-reactive value |
| `"Recursive computed evaluation"` | A computed that reads itself |
| `"Watch source must be reactive or callable"` | `etaf-watch` with an invalid SOURCE |
| `"Invalid watcher flush"` | An unrecognized FLUSH |
| `"Inactive Scope"` | Creating an effect while the active Scope has stopped |
| `"Inactive parent Scope"` | `etaf-effect-scope` under a stopped Scope |
| `"Cannot enter an inactive Scope"` | `etaf-scope-run` on a stopped Scope |
| `"Cleanup registration requires an active Scope"` | `etaf-on-scope-dispose` without an active Scope |

#### Error: etaf-render-side-effect-error

An operation that changes the reactive graph was attempted during rendering. The data is the operation, listed in [Rendering is free of side effects](#rendering-is-free-of-side-effects). Its parent condition is `etaf-reactive-error`, so a handler for `etaf-reactive-error` also catches it.

### Recovery

| Failure | What remains |
| --- | --- |
| A computed's getter signals | The previous cached value; the computed stays dirty and retries at the next read |
| A watcher callback signals | The watcher stays active and has recorded the new value; the error is signaled after the drain |
| An effect function signals | The effect stays active with its old and newly read dependencies |
| A pre or render effect fails during a drain | Mounted Runtimes keep their last commit: the buffer and `etaf-runtime-revision` do not change. Refs keep the values written to them, and watchers, post watchers included, still receive those values, so a post watcher cannot assume the buffer shows them. The failed work is retried at the next drain or `etaf-runtime-flush`, which signals again while the failure persists |
| The body of a batch signals | All writes stay; pending work drains; the body's condition is signaled |
| A cleanup signals during `etaf-scope-stop` | Teardown continues; the condition is in the returned list |
| A queued `etaf-next-tick` function signals | The other queued functions run; the first error is signaled |

Effects keep running after a failed drain: one failing effect does not stop the others in its phase. All the errors of a drain are collected, and the first one is signaled when the drain ends.
