# Actions, Behaviors and Error Boundaries

Three facilities carry application behavior without adding View nodes: an *Action* is a named business mutation dispatched through a Runtime, a *Behavior* is a reusable bundle of non-visual Host attributes with optional installation, and an *error boundary* is an explicit place where a signaled error becomes a value. This chapter defines the definition macros and constructors, how Actions are dispatched and redefined, how Behaviors install, keep or replace themselves, the built-in Behaviors for focus, toggling, dragging and resizing, and the two conditions they signal.

None of the three is a View node and none of them renders: an Action mutates application state and lets the reactive system publish it, a Behavior contributes Host properties through `:use` and installs code beside the Host it is attached to, and an error boundary only decides which condition is handled. Host properties, including `:use`, belong to [Hosts](hosts.md#property-use); the tree that an Action's writes publish belongs to [Reactivity](reactivity.md); the Component side of fallthrough and redefinition belongs to [Components](components.md).

<!-- index: Action; Behavior; error boundary; :use; installer; cleanup -->

## Model

### Actions

An Action is one named, testable entry for a business mutation. It is registered under an ordinary symbol in a process-global table, and it is invoked through a Runtime rather than called directly: `etaf-dispatch` resolves the Runtime, calls the Action's function with that Runtime as its first argument inside one reactive batch, and returns what the function returns. Because the call is a batch, every write the Action makes is published together when it returns. An Action is neither a node nor a key binding; a Host's `:on-press` callback or a key command calls `etaf-dispatch` when it wants one.

### Behaviors

A Behavior is a specification, not a node: a name, a bundle of semantic attributes, and an optional *installer*. It reaches a Host through the `:use` property, which accepts a constructor symbol, a spec, or a proper list of them. When the Host resolves its properties, each source is resolved to a spec and the spec's attributes are merged into the Host's properties with the rules [Hosts](hosts.md#values-and-conflicts) defines: event callbacks and `:disabled` compose, the Host's own keys come first, and other attributes fill only where the Host is silent. The optional installer then runs once for the Host: it may open resources and must return a cleanup function, which runs when the Behavior is removed, replaced, disabled with its Host, or unmounted. Local `:on-*` callbacks on the Host remain the simpler choice for one-off interaction; a Behavior exists when the same bundle is reused, when it brings an installer, or when it is shipped by a library.

### Error boundaries

An error boundary answers one question: what should happen to an error signaled by this call. `etaf-error-boundary-run` calls a function and, when it signals, hands the raw condition to a handler whose return value becomes the boundary's result. It is containment at an explicitly chosen point, not an error policy: nothing outside the wrapped call and nothing the handler itself signals is caught.

## Actions

#### Macro: etaf-action-define (name arguments &rest body)

Define and register named Action NAME with ARGUMENTS and BODY.

**Arguments.** NAME is an ordinary symbol: a non-nil, non-keyword symbol that is not already registered. ARGUMENTS is an ordinary function lambda list; when the Action is dispatched, its first argument is the Runtime. BODY is the Action's body, optionally beginning with a docstring.

**Semantics.** The macro defines a function for the Action, registers it under NAME in the process-global Action table, and expands to the quoted NAME. Registration refuses a name that is already registered, unless the definition runs inside `etaf-action-redefine-run`. The Action's function is called only through `etaf-dispatch`, which supplies the Runtime as the first argument and runs the call in one batch. Defining an Action inside rendering is rejected: registering is a side effect.

**Returns.** NAME, as a quoted symbol, so a definition form evaluates to NAME.

**Errors.** `error→ etaf-action-error` with `"Duplicate ETAF Action: %S"` when NAME is already registered, and with `"Invalid Action registration: %S"` when NAME is a keyword or otherwise not an ordinary symbol. `error→ etaf-render-side-effect-error` with data `(register-action)` when the definition runs during rendering.

**Example.** An Action that adds an item to a caller-owned list ref.

```elisp
(etaf-action-define demo-add (runtime tasks title)
  (ignore runtime)
  (etaf-set-value tasks (cons title (etaf-value tasks))))
```

**See also.** `etaf-dispatch`, `etaf-action-redefine-run` and [Components](components.md) for batching inside callbacks.

#### Function: etaf-dispatch (action &rest arguments)

Dispatch named ACTION through the active Runtime with ARGUMENTS.

**Arguments.** ACTION is the registered Action name, or a Runtime when the Runtime is passed explicitly as the first argument: `(etaf-dispatch RUNTIME ACTION ...)`. ARGUMENTS are passed to the Action's function after the Runtime, which is always the first argument.

**Semantics.** The call resolves the Runtime — the explicit one or the dynamically active one, which is available inside event callbacks and lifecycle code — and runs the Action's function with `(RUNTIME ARGUMENTS...)` inside one `etaf-call-with-batch`. Writes the Action makes are published together when the call returns; the return value is the function's return value. After a redefinition, future dispatches use the new function, because the table is consulted at dispatch time. When the Runtime has an observer, the dispatch is reported as an observed operation, as [Incremental Updates and Publication](incremental-updates-and-publication.md) describes.

**Returns.** The Action function's return value.

**Errors.** `error→ etaf-action-error` with `"Unknown ETAF Action: %S"` when ACTION names no registered Action, and with `"Action name must be a symbol"` when ACTION is not a symbol. `error→ etaf-runtime-error` with the message `"ETAF runtime is not mounted"` when neither an explicit nor an active Runtime is mounted. `error→ etaf-render-side-effect-error` with data `(dispatch-action)` during rendering. An error the Action's body signals propagates after the batch has drained; writes the Action made before the error stay.

**Example.** A button callback that dispatches by name, and direct dispatch with an explicit Runtime.

```elisp
(etaf-dispatch 'demo-add tasks "Write tests")
(etaf-dispatch runtime 'demo-add tasks "Review diff")
```

**See also.** `etaf-action-define`, `etaf-action-redefine-run` and [Reactivity](reactivity.md#batches-and-ticks).

#### Function: etaf-action-redefine-run (function)

Run FUNCTION while allowing intentional Action redefinition.

**Arguments.** FUNCTION is a function of no arguments. Any other value signals `wrong-type-argument` with data `(functionp FUNCTION)`.

**Semantics.** Inside the call, `etaf-action-define` may replace an already registered Action instead of signaling. The replacement changes only the process-global name binding used by future `etaf-dispatch` calls: it does not flush, rerender or restart mounted Runtimes, and a call already in progress keeps the function it resolved. Use it in authoring and test tools that redefine an Action deliberately.

**Returns.** FUNCTION's return value.

**Errors.** `error→ wrong-type-argument` when FUNCTION is not a function. Errors inside FUNCTION propagate and leave the table as it was at the point of failure.

**Example.** A test tool redefines an Action to observe one call.

```elisp
(etaf-action-redefine-run
 (lambda () (etaf-action-define demo-add (runtime tasks title)
              (ignore runtime tasks title)
              'observed)))
```

**See also.** `etaf-action-define` and [Components](components.md) for `etaf-component-redefine-run`.

## Behaviors

### Defining a Behavior

#### Macro: etaf-define-behavior (name arguments &rest body)

Define ordinary Behavior constructor NAME with ARGUMENTS and BODY.

**Arguments.** NAME is a non-nil, non-keyword symbol. ARGUMENTS is an ordinary function lambda list, as `defun` accepts it: use `&optional` and `&rest`; a keyword lambda list such as `(&key ...)` is not supported. BODY is the constructor body, optionally beginning with a docstring.

**Semantics.** The macro is a function definition convenience: it defines a plain function whose body must return data created by `etaf-behavior-create`; usually the body ends with that call. The function is resolved by name wherever `:use` accepts a constructor symbol, so it can be used before or after it is defined, and it is called when the Host resolves its `:use` property. This is not a second runtime or node model: constructors only build specs and are ordinary functions for every other purpose.

**Returns.** Whatever the defined constructor returns when it is called.

**Example.** A constructor whose spec carries a role and an installer.

```elisp
(etaf-define-behavior demo-status (&rest attributes)
  (apply #'etaf-behavior-create 'demo-status
         (append attributes (list :role 'status))))
```

**See also.** `etaf-behavior-create` and `etaf-define-component`.

#### Function: etaf-behavior-create (name &rest attributes)

Create a Behavior spec named NAME from keyword ATTRIBUTES.

**Arguments.** NAME is an ordinary symbol. ATTRIBUTES are keyword/value pairs; each key is a keyword and no key may be repeated. The reserved `:install` attribute is an optional zero-argument installer; every other attribute is a semantic or style attribute destined for the Host.

**Semantics.** The call validates its inputs and returns a spec carrying the name, the semantic attributes and the installer. `:install` is not merged into Host properties; it is the Behavior's own code. Duplicate Behavior names on one Host are rejected when the Host resolves its `:use`, not here.

**Returns.** A Behavior spec.

**Errors.** `error→ etaf-behavior-error` with one message string: `"Behavior name must be a symbol: %S"` for a keyword or non-symbol NAME; `"Behavior attributes must be keyword/value pairs"` when ATTRIBUTES is not a proper even-length list; `"Behavior attribute must be a keyword: %S"` for a non-keyword key; `"Duplicate Behavior attribute: %S"` for a repeated key; and `":install must be a function or nil"` for a non-function installer.

**Example.** A spec that a Host can attach with `:use`.

```elisp
(etaf-behavior-create 'demo-badge :role 'status :aria-label "build")
```

**See also.** `etaf-define-behavior` and [Hosts](hosts.md#property-use).

### Installing a Behavior

A Behavior with an `:install` attribute runs that function once each time it is installed for a Host. The installer receives nothing and may return nil or a cleanup function; anything else is an error. It runs outside rendering, with the following two functions available.

#### Function: etaf-current-behavior-context ()

Return the Behavior context active during an installer, or nil.

**Semantics.** The call returns a context object while one Behavior installer runs and nil everywhere else, including inside another behavior's cleanup. Pass the result to `etaf-behavior-context-info` to read the installation facts.

**Returns.** A Behavior context, or nil.

#### Function: etaf-behavior-context-info (context)

Return CONTEXT's installation facts as a fresh plist.

**Arguments.** CONTEXT is a value from `etaf-current-behavior-context` during an installer. Any other value signals `etaf-behavior-error`.

**Semantics.** The result has three keys: `:runtime`, the owning Runtime; `:host-ref`, the Host's effective reference, whether it came from the Host's `:ref` or was generated; and `:properties`, the installation-time semantic Host properties with that reference added. The plist and the property container are fresh on every call, while contained values keep their identity and are read-only for the caller. The facts stay readable after cleanup, but they do not certify that the Host is still mounted or that its properties are still current: use the Runtime's committed queries, such as `etaf-runtime-host-props-for`, when current state matters.

**Returns.** A plist with `:runtime`, `:host-ref` and `:properties`.

**Errors.** `error→ etaf-behavior-error` with the message `"Expected a Behavior installation context"` when CONTEXT is not a Behavior context.

**Example.** An installer opens a subscription for the Host reference and returns its cleanup.

```elisp
(etaf-behavior-create 'demo-watch
  :install (lambda ()
             (let* ((context (etaf-current-behavior-context))
                    (ref (plist-get (etaf-behavior-context-info context) :host-ref)))
               (subscribe ref))
             (lambda () (unsubscribe))))
```

**See also.** `etaf-current-behavior-context`, `etaf-runtime-host-props-for` and [Runtime](runtime.md#introspection).

### Built-in Behaviors

#### Function: etaf-focusable (&rest attributes)

Return a focusable Behavior from ATTRIBUTES.

**Arguments.** ATTRIBUTES are passed to `etaf-behavior-create` unchanged, except for the tab stop.

**Semantics.** When ATTRIBUTES does not contain `:tab-index`, the Behavior supplies the standard first tab stop, `0`, so the Host takes part in tab navigation; an explicit `:tab-index nil` excludes it. The rest of the attributes belong to the Host as usual. The Keyboard and [Focus](focus.md) chapters define navigation over the resulting stops.

**Returns.** A Behavior spec named `focusable`.

**Errors.** The errors of `etaf-behavior-create`, plus those of whatever attributes the caller adds.

**Example.** `(text :use (list (etaf-focusable)) "Open")`

**See also.** [Focus](focus.md) and [Hosts](hosts.md#accessibility-and-focus).

#### Function: etaf-toggleable (&rest attributes)

Return a Behavior converting ATTRIBUTES into a toggleable press action.

**Arguments.** `:value` is the current value, as a ref, a computed value or a plain value; `:on-change` is the function called with the next value, and it is required. All other ATTRIBUTES remain part of the returned Behavior.

**Semantics.** `:value` and `:on-change` configure the action and are not kept as attributes; the Behavior attaches a press handler that calls ON-CHANGE with the negation of the current value. A ref or computed `:value` is read with `etaf-value` at press time, so the toggle follows the source; a plain value is used as it was at construction. The call itself does not change the value: ON-CHANGE decides what to write.

**Returns.** A Behavior spec named `toggleable` whose attributes are the remaining ATTRIBUTES plus the press handler.

**Errors.** `error→ etaf-behavior-error` with the message `"toggleable requires a function-valued :on-change"` when `:on-change` is missing or not a function, and the errors of `etaf-behavior-create` for the remaining attributes.

**Example.** A settings row whose switch owns its state.

```elisp :run
(etaf-define-component demo-setting-row (&key label)
  :bindings ((enabled (etaf-ref nil))
             (behavior (etaf-toggleable
                        :value enabled
                        :on-change (lambda (next) (etaf-set-value enabled next)))))
  :view (row :item-gap '(ch 2)
             (text :font-weight 'bold (expr label))
             (box :ref 'switch :use (list behavior)
                  (text (expr (if (etaf-value enabled) "[on]" "[off]"))))))

(etaf-view (demo-setting-row :label "Notifications"))
```

**See also.** [Hosts](hosts.md#property-use), [Events](events.md) and [Components](components.md#setup-bindings-and-state).

#### Function: etaf-draggable (&key x y axis delta on-start on-move on-end on-cancel)

Return a Behavior that moves caller-owned numeric coordinate refs from Ebox drag deltas.

**Arguments.** X and Y are writable `etaf-ref` values holding numeric logical coordinates; at least one is required for the selected AXIS. AXIS is `x`, `y` or `both`; nil infers `both` when both refs are given, otherwise the one that is. DELTA is an optional function receiving the gesture and returning a `(DX . DY)` cons, for callers whose units are not Ebox pixels. ON-START, ON-MOVE, ON-END and ON-CANCEL are optional functions of one argument, the gesture plist.

**Semantics.** The Behavior consumes the Host's `:on-drag` gestures. On `start` it records the refs' current values; on `move` and `end` it writes each selected ref as its recorded origin plus the delta, so the drag follows the gesture; the callbacks run after those writes, and `cancel` changes no coordinate. The gesture owns no window or pointer state here: Ebox keeps the gesture target and ETAF's ordinary reactive publication updates the Host from the refs, which the caller maps to geometry. The Behavior also contributes keys that move the Host one cell per press along the selected axis: `M-<left>` and `M-<right>` for `x`, `M-<up>` and `M-<down>` for `y`, all four for `both`. Put a move Behavior and a resize Behavior on separate Hosts, because one Host's drag handlers all receive every gesture.

**Returns.** A Behavior spec named `draggable`.

**Errors.** `error→ etaf-behavior-error` with one message string: `"etaf-draggable requires :x or :y"` when no coordinate ref is given; `"Invalid draggable axis: %S"` for an axis other than x, y or both; `"etaf-draggable :x and :y must be distinct refs"` for the same ref in both; `"%s must be a writable `etaf-ref': %S"` for a coordinate that is not a ref; and `"%s must be a function or nil: %S"` for a callback or DELTA that is neither. An invalid delta in a gesture signals during dispatch.

**Example.** A draggable handle that owns an x coordinate.

```elisp
(etaf-draggable :x position :axis 'x :on-end (lambda (_gesture) (commit position)))
```

**See also.** `etaf-draggable-controlled`, [Dragging and Gestures](dragging-and-gestures.md), and [Keyboard](keyboard.md) for the contributed keys.

#### Function: etaf-resizable (&key x y width height edges min-width max-width min-height max-height delta on-start on-resize on-end on-cancel)

Return a Behavior that resizes caller-owned numeric geometry refs from Ebox drag deltas.

**Arguments.** WIDTH and HEIGHT are writable `etaf-ref` values with numeric sizes; X and Y are optional writable coordinates required by the left and top edges. EDGES is one symbol or a list from `left`, `right`, `top` and `bottom`; it defaults to `right` and `bottom`. MIN-WIDTH, MAX-WIDTH, MIN-HEIGHT and MAX-HEIGHT are optional numeric bounds. DELTA, ON-START, ON-RESIZE, ON-END and ON-CANCEL follow `etaf-draggable`, with `:on-resize` replacing `:on-move`.

**Semantics.** The Behavior consumes the Host's `:on-drag` gestures. On `start` it records the current geometry; on `move` and `end` it computes the next size from the dragged edges — `left` and `top` also move X and Y so the opposite edge stays fixed — clamps it to the given bounds and writes the refs; the callbacks run after the writes, and `cancel` leaves the last accepted geometry. A missing bound means no bound, so a size may become negative if the caller does not set a minimum. The Behavior contributes `M-S-<left>` and `M-S-<right>` (Narrower, Wider) when a horizontal edge is selected and `M-S-<up>` and `M-S-<down>` (Shorter, Taller) when a vertical one is. It has no desktop-window policy and calls no Ebox private API. Put it on a Host of its own, separate from any move Behavior.

**Returns.** A Behavior spec named `resizable`.

**Errors.** `error→ etaf-behavior-error` with one message string: `"Invalid resizable edges: %S"` for an edge set that is empty, repeated or outside `left`/`right`/`top`/`bottom`; `"%s must be a writable `etaf-ref': %S"` for a size or coordinate that is missing when its edge is selected or is not a ref; `"%s must be numeric or nil: %S"` for a non-numeric bound; `"etaf-resizable :min-width exceeds :max-width"` and `"etaf-resizable :min-height exceeds :max-height"` for inverted bounds; and the callback and delta errors of `etaf-draggable`.

**Example.** A resizable panel anchored at its top-left corner.

```elisp
(etaf-resizable :width width :height height
                :edges '(right bottom)
                :min-width 20
                :on-end (lambda (_gesture) (store-size width height)))
```

**See also.** `etaf-resizable-controlled` and [Dragging and Gestures](dragging-and-gestures.md).

#### Function: etaf-draggable-controlled (read on-change &key axis delta on-start on-move on-end on-cancel)

Return a controlled drag Behavior for aggregate geometry state.

**Arguments.** READ is a function returning the current geometry as a plist with `:x` and `:y` facts; ON-CHANGE is a function receiving the next detached geometry plist. AXIS is `x`, `y`, `both` or nil to infer from what READ returns. DELTA and the callbacks follow `etaf-draggable`.

**Semantics.** The Behavior keeps no persistent geometry: on `start` it calls READ once and keeps the result as a transient gesture origin; on `move` and `end` it builds the next plist from that origin plus the delta and passes it to ON-CHANGE, then runs the callbacks. The caller's aggregate state is the only authority, so the Behavior fits managers whose geometry is not naturally four independent refs. Build the Behavior once in a retained owner such as a `:bindings` value, not inside `:render`: a Behavior constructed during rendering is a new handler identity and cannot carry an active gesture across a parent projection.

**Returns.** A Behavior spec named `draggable-controlled`.

**Errors.** `error→ etaf-behavior-error` with `"Controlled draggable ON-CHANGE must be a function"` at construction when the callback is not a function, with `"Controlled geometry READ must be a function"` and `"Controlled draggable READ must expose :x or :y"` when a gesture starts and READ is unusable, with `"Controlled geometry READ must return a plist"` for a malformed READ result, and with the delta and callback errors of `etaf-draggable`.

**Example.** A controlled window position.

```elisp
(etaf-draggable-controlled
 (lambda () (list :x (plist-get state :x) :y (plist-get state :y)))
 (lambda (next) (setq state next)))
```

**See also.** `etaf-draggable` and [Components](components.md#setup-bindings-and-state).

#### Function: etaf-resizable-controlled (read on-change &key edges min-width max-width min-height max-height delta on-start on-resize on-end on-cancel)

Return a controlled resize Behavior for aggregate `:x`/`:y`/`:width`/`:height` state.

**Arguments.** READ is a function returning the current geometry as a plist with numeric `:x`, `:y`, `:width` and `:height`. ON-CHANGE is a function receiving the next detached geometry plist. EDGES, the bounds and DELTA follow `etaf-resizable`.

**Semantics.** On `start` the Behavior records READ's result as the gesture origin; on `move` and `end` it computes the next geometry from the dragged edges, applies the bounds and DELTA conversion, and passes the detached plist to ON-CHANGE before running the callbacks. The Behavior retains no persistent application geometry; the same construction rule as `etaf-draggable-controlled` applies.

**Returns.** A Behavior spec named `resizable-controlled`.

**Errors.** `error→ etaf-behavior-error` with `"Controlled resizable ON-CHANGE must be a function"` at construction, `"Invalid controlled resize edges: %S"` for a bad edge set, the bound errors of `etaf-resizable`, and `"%s must contain a number, got %S"` when a gesture starts and READ does not expose the numeric geometry the selected edges need.

**Example.** A controlled window size.

```elisp
(etaf-resizable-controlled
 (lambda () state)
 (lambda (next) (setq state next))
 :min-width 40 :min-height 12)
```

**See also.** `etaf-resizable` and [Components](components.md#setup-bindings-and-state).

### Gesture callbacks

The drag and resize Behaviors accept callbacks that receive the original Ebox gesture: a plist whose `:phase` is `start`, `move`, `end` or `cancel` and whose `:delta` is a `(DX . DY)` cons of pixels. Move, end and resize callbacks run after the Behavior has written its refs or called its controlled ON-CHANGE, so a callback reads the accepted value. Cancel runs instead of a move when the gesture is abandoned and leaves the last accepted geometry in place.

#### Property: :on-change

The next-value callback of `etaf-toggleable`.

**Arguments.** A function of one argument, the next value; required.

**Semantics.** The Behavior's press handler calls it with the negation of the current `:value`. The callback decides what to write, so a toggle whose value is a ref typically writes it with `etaf-set-value` or `etaf-update-value`.

**Errors.** `error→ etaf-behavior-error` with `"toggleable requires a function-valued :on-change"` when it is missing or not a function.

**See also.** `etaf-toggleable`.

#### Property: :on-start

The gesture-start callback of the drag and resize Behaviors.

**Arguments.** A function of one argument, the gesture plist; optional.

**Semantics.** Runs when the gesture starts, after the Behavior has recorded its origin. It is the right place to prepare or announce a gesture; it must not assume any coordinate has changed yet.

**Errors.** `error→ etaf-behavior-error` with `"%s must be a function or nil: %S"` at construction for a non-function value.

**See also.** `etaf-draggable` and `etaf-resizable`.

#### Property: :on-move

The movement callback of `etaf-draggable` and `etaf-draggable-controlled`.

**Arguments.** A function of one argument, the gesture plist; optional.

**Semantics.** Runs after the accepted movement has been written to the refs, or passed to the controlled ON-CHANGE. A callback may read the new value but should not start another gesture.

**Errors.** `error→ etaf-behavior-error` with `"%s must be a function or nil: %S"` at construction for a non-function value.

**See also.** `etaf-draggable` and `etaf-draggable-controlled`.

#### Property: :on-end

The gesture-end callback of the drag and resize Behaviors.

**Arguments.** A function of one argument, the gesture plist; optional.

**Semantics.** Runs after the final movement or resize has been applied. It is the place to commit the outcome, for example to persist the released geometry or start a follow-up publication.

**Errors.** `error→ etaf-behavior-error` with `"%s must be a function or nil: %S"` at construction for a non-function value.

**See also.** `etaf-draggable`, `etaf-resizable` and their controlled versions.

#### Property: :on-cancel

The gesture-cancel callback of the drag and resize Behaviors.

**Arguments.** A function of one argument, the gesture plist; optional.

**Semantics.** Runs when the gesture is cancelled. No ref or controlled state changed for the cancelled movement, so the last accepted geometry is still in place.

**Errors.** `error→ etaf-behavior-error` with `"%s must be a function or nil: %S"` at construction for a non-function value.

**See also.** `etaf-draggable` and `etaf-resizable`.

#### Property: :on-resize

The movement callback of `etaf-resizable` and `etaf-resizable-controlled`.

**Arguments.** A function of one argument, the gesture plist; optional.

**Semantics.** Runs after the accepted size has been written to the refs, or passed to the controlled ON-CHANGE. `:on-end` still runs at the end of the gesture.

**Errors.** `error→ etaf-behavior-error` with `"%s must be a function or nil: %S"` at construction for a non-function value.

**See also.** `etaf-resizable` and `etaf-resizable-controlled`.

## Error boundaries

#### Function: etaf-error-boundary-run (function handler &key name)

Run FUNCTION and handle its signaled error with HANDLER.

**Arguments.** FUNCTION is a function of no arguments whose result becomes the boundary result when it returns. HANDLER is a function of one argument, the raw condition object, whose result becomes the boundary result when FUNCTION signals. NAME is accepted for caller diagnostics and does not change control flow. A non-function FUNCTION or HANDLER signals `wrong-type-argument` with data `(functionp VALUE)`.

**Semantics.** The boundary catches `error` conditions signaled by FUNCTION, but nothing else: `quit` propagates, errors signaled outside the call are not caught, and an error signaled by HANDLER itself propagates with its own backtrace. The handler receives the condition object as `condition-case` produces it, so its car is the condition symbol and its cdr the data. The boundary is a lexical place to convert an error into a value, for example to turn a failed render computation into an error payload or to keep a diagnostic list.

**Returns.** FUNCTION's value when it returns, otherwise HANDLER's value.

**Errors.** `error→ wrong-type-argument` with data `(functionp FUNCTION)` or `(functionp HANDLER)` for a non-function argument. Errors from FUNCTION are not re-signaled; errors from HANDLER and everything outside the call propagate unchanged.

**Example.** Turn a failing computation into a report.

```elisp
(etaf-error-boundary-run
 (lambda () (compute-report))
 (lambda (condition) (list :failed condition))
 :name 'report)
```

**See also.** [Reactivity](reactivity.md#errors-and-recovery) for how the Runtime collects and re-signals errors from a drain.

## Semantic details

### Behavior identity and replacement

A Behavior stays installed while the Host keeps resolving the *same* spec: the same name, the same installer function identity, attributes that compare equal by the same shallow rule as reactive values (conses recursively, refs and functions by identity), and the same effective Host reference. When all of that holds, a property change elsewhere on the Host does not touch the installed Behavior: the installer does not run again and its cleanup does not run.

A Behavior is replaced — cleanup of the old, installation of the new — when any of those facts changes: a different name, a different installer function, attributes that differ, or a different Host reference. Because the installer's identity matters, constructing the same spec twice with a fresh `:install` closure is a replacement, while constructing it twice with `nil` or a shared function is the same Behavior. This is why a Behavior that owns handler identity — the controlled drag and resize Behaviors — should be constructed once in a retained owner instead of during each render.

A Behavior is removed when the Host stops listing it, when the Host is disabled, and when the Host is unmounted. Removal runs the cleanup function the installer returned, in the same commit; the Runtime collects a cleanup error instead of losing the rest of the teardown. A disabled Host installs no Behaviors, so disabling and re-enabling a Host removes and reinstalls them.

### Attribute composition

The Host's own properties and each Behavior's attributes are combined with the same rules Components use for fallthrough, defined in [Hosts](hosts.md#values-and-conflicts): non-nil host style values win over a Behavior's, event callbacks compose with the Behavior's callback first, `:disabled` combines with `or`, the Host's own keys come before each Behavior's, and an owned semantic property declared by both the Host and a Behavior is a conflict rather than an override. Duplicate Behavior names on one Host, an unknown constructor symbol, a constructor that returns something other than a spec, and a `:use` value outside the source grammar are errors at Host property resolution.

### Cost

A Behavior costs one spec comparison per Host property resolution while it is unchanged: a name check, an installer identity check and a shallow attribute comparison. Installing costs whatever the installer opens plus one cleanup function stored per Host; removing costs the cleanup call. The built-in drag and resize Behaviors cost a gesture callback per Ebox drag phase and the ordinary reactive publication of the refs they write, so their publication cost is proportional to the change, not to the drag distance.

## Errors and recovery

#### Error: etaf-action-error

Invalid ETAF Action. It is signaled when an Action cannot be defined, registered or dispatched. Catch this condition with `condition-case`; failed calls do not return a value. Its parent condition is `error`, and its data is a list holding one formatted message string.

| Message | Cause |
| --- | --- |
| `"Duplicate ETAF Action: %S"` | `etaf-action-define` for a name already registered outside `etaf-action-redefine-run` |
| `"Invalid Action registration: %S"` | An Action name that is a keyword or otherwise not an ordinary symbol |
| `"Action name must be a symbol"` | `etaf-dispatch` with a non-symbol ACTION |
| `"Unknown ETAF Action: %S"` | `etaf-dispatch` with a name that is not registered |

**See also.** `etaf-action-define`, `etaf-dispatch` and [Reactivity](reactivity.md#errors-and-recovery) for the batch failure contract.

#### Error: etaf-behavior-error

Invalid ETAF Behavior. It is signaled when a Behavior spec, source, installer or controlled geometry input is invalid. Catch this condition with `condition-case`; failed calls do not return a value. Its parent condition is `error`, and its data is a list holding one formatted message string.

| Message | Cause |
| --- | --- |
| `"Behavior name must be a symbol: %S"` | `etaf-behavior-create` or `etaf-define-behavior` with a keyword or non-symbol name |
| `"Behavior attributes must be keyword/value pairs"` | ATTRIBUTES that are not a proper even-length list |
| `"Behavior attribute must be a keyword: %S"` | A non-keyword attribute key |
| `"Duplicate Behavior attribute: %S"` | The same attribute key twice in one spec |
| `":install must be a function or nil"` | A non-function installer |
| `"Behavior %S installer must return cleanup"` | An installer returning something that is neither nil nor a function |
| `"Invalid Ebox gesture delta: %S"` | A gesture whose `:delta` is not a numeric `(DX . DY)` cons |
| `"Unknown Behavior constructor: %S"` | A `:use` symbol that names no function |
| `"Behavior constructor %S returned %S"` | A constructor returning something other than a Behavior spec |
| `"Duplicate Behavior on one Host: %S"` | Two Behaviors with the same name attached to one Host |
| `"Expected a Behavior installation context"` | `etaf-behavior-context-info` with a value that is not a context |
| `"toggleable requires a function-valued :on-change"` | `etaf-toggleable` without a function callback |
| `"%s must be a writable `etaf-ref': %S"`, `"%s must be a function or nil: %S"`, `"%s must be numeric or nil: %S"` | Geometry or callback arguments of `etaf-draggable` and `etaf-resizable` |
| `"Invalid draggable axis: %S"`, `"etaf-draggable requires :x or :y"`, `"etaf-draggable :x and :y must be distinct refs"` | Invalid drag coordinates |
| `"Invalid resizable edges: %S"`, `"etaf-resizable :min-width exceeds :max-width"`, `"etaf-resizable :min-height exceeds :max-height"` | Invalid resize edges or inverted bounds |
| `"Controlled geometry READ must be a function"`, `"Controlled geometry READ must return a plist"`, `"Controlled draggable READ must expose :x or :y"`, `"%s must contain a number, got %S"` | Controlled READ input that cannot supply the geometry a gesture needs |
| `"Controlled draggable ON-CHANGE must be a function"`, `"Controlled resizable ON-CHANGE must be a function"`, `"Invalid controlled resize edges: %S"` | Invalid controlled Behavior arguments |

**See also.** [Hosts](hosts.md#property-use) for `:use` resolution, `etaf-component-call-error` in [Components](components.md#errors-and-recovery) for an owned-property conflict between a Host and a Behavior, and [Events](events.md) for gesture dispatch.

### Recovery

| Failure | What remains |
| --- | --- |
| A duplicate Action definition | The registered Action stays; use `etaf-action-redefine-run` to replace it deliberately |
| A dispatched Action whose body signals | Writes made before the error stay and are published; the error propagates after the batch drains |
| An invalid Behavior spec or source | The Host's property resolution fails for that commit; no Behavior was installed for the failing source |
| A failing installer | The commit is rolled back like any other failing commit, and installs made in it are cleaned up; the Host keeps its previously committed Behaviors |
| A failing cleanup | The error is collected by the Runtime; the remaining teardown still runs |
| A disabled Host | Its Behaviors are cleaned up; enabling the Host installs them again |
| An error inside an error boundary's function | HANDLER receives the raw condition; the boundary returns its value |
| An error outside a boundary or in its handler | Propagates unchanged, with its own backtrace |

An Action name, a Behavior constructor and a `:use` source are programming contracts: a failure is fixed in the definition. A gesture that a Behavior handles is data: a rejected delta or a controlled READ that cannot supply geometry signals from the event callback, and the event callback failure follows the Runtime's ordinary error collection.

**See also.** `etaf-dispatch`, `etaf-behavior-create` and `etaf-error-boundary-run`.
