# Events

An interaction reaches an application as an event. Ebox decides which Host owns the position or the key and triggers the keymap entry ETAF lowered for it; the Runtime then runs one application callback inside a reactive event batch. This chapter defines the Host event properties, activation from the pointer and the keyboard, explicit dispatch, the order in which callbacks compose and how ancestor capture hooks work, the queries that describe the event in progress, the derived `active` state, hover feedback, and how disabled Hosts behave in hit testing. [Interaction Overview](interaction-overview.md) describes the path the chapters share; [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md) defines the drag and resize callbacks of the built-in Behaviors, which are not Host event properties.

## Event properties

<!-- index: event property; :on-press; capture; drag gesture; swipe; dismiss -->

A Host declares one callback per event kind as a property named `:on-KIND`, where KIND uses lowercase words joined by hyphens, for example `press` in `:on-press`. The value must be a function or nil; any other value is rejected when the Host commits with `error→ etaf-renderer-error`. A nil callback declares the property without handling the event, which still counts as a declaration for the merge rules below.

One kind has no Host property: drag gestures reach drag and resize Behaviors as the `:on-start`, `:on-move`, `:on-end`, `:on-cancel`, `:on-resize` and `:on-change` attributes described in [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md). `:on-direction` is a keyboard property and belongs to [Keyboard](keyboard.md); `:on-leave` is an input-session option of the [Text Input](text-input.md) chapter. The properties below are the ETAF Runtime's event callbacks.

#### Property: :on-press

The callback that activates a Host.

**Arguments.** A function of no arguments, or of one argument when the event is dispatched with a payload, or nil.

**Semantics.** A primary-button click on the Host, RET or SPC with the Host's keymap at point or focus, and `etaf-dispatch-event` all run it. A Host that only declares `:on-press` receives the `hand` pointer by default and its Ebox keymap claims the primary-button sequence, so a press that moves is tracked and a press that does not move still activates on release. Ordinary press callbacks do not bubble: an ancestor observes a descendant's press only through [`:on-press-capture`](#property-on-press-capture). A disabled Host does not run its callback, and the press stops at the disabled Host instead of reaching an ancestor. A root Host's press covers presses on its own non-interactive surface, because the root is the nearest keymap owner there.

**Returns.** The Runtime preserves the callback's return value from `etaf-dispatch-event`; a native activation discards it.

**Errors.** A callback error propagates from the dispatch after the event's batch drains; callbacks composed after the failing one do not run, and the error stops the ancestor capture pass.

**Example.** `(text :role 'button :tab-index 0 :on-press #'retry "Retry")`

**See also.** `etaf-activate`, `etaf-dispatch-event`, `:on-press-capture`.

#### Property: :on-press-capture

An ancestor hook for observing a press that landed inside the Host.

**Arguments.** A function of no arguments, or of one argument when the event carries a payload, or nil.

**Semantics.** After the pressed Host's own callback returns successfully, ETAF runs the capture callbacks of its committed ancestors from the nearest outward. The pressed Host itself is not an ancestor, so a Host's own capture does not run for its own press. Inside a capture callback `etaf-event-target-within-p` compares against the pressed Host rather than the callback's Host, so a shell can tell a press inside an open panel from one on the surface around it; `etaf-event-pointer-p` still describes the input that started the event. A capture pass runs once per press dispatch: a press dispatched from inside a capture callback does not start a second pass. When the target callback signals, the capture pass does not run at all.

**Returns.** The capture callback's return value is discarded; the pressed Host's return value is what `etaf-dispatch-event` returns.

**Errors.** An error in a capture callback propagates after the batch drains and stops the remaining capture callbacks.

**Example.** `(column :on-press-capture (lambda () (when (etaf-event-target-within-p 'popover) (close-popover))) ...)`

**See also.** `:on-press`, `etaf-event-target-within-p`.

#### Property: :on-drag

The callback that receives a pointer drag gesture phase by phase.

**Arguments.** A function of one argument, the gesture plist, or nil.

**Semantics.** Ebox tracks the primary button on the Host and calls the handler once per phase with a plist containing `:phase` (`start`, `move`, `end`, `cancel` or `edge`), `:event` (the raw mouse event), `:window`, `:buffer`, `:start` and `:position` as text-area pixel conses, `:delta` as the displacement from `:start`, `:overshoot` as the pointer's distance past the text area while `:position` stays clamped inside it, `:reason` on cancellation, and `:keyboard` when the gesture came from `etaf-drag-step` instead of the pointer. An `edge` phase additionally carries `:edges`, the window edges the pointer rests against or has passed, and `:elapsed`, the seconds since the previous `edge` phase. Each phase runs in its own reactive event batch and publishes before the next pointer event is read, so a drag handler sees each committed position. Ebox owns target retention and the tracking loop: a retained Host that becomes disabled receives one terminal `cancel` gesture, and a removed or unmounted Host receives nothing more. When a Host declares both `:on-press` and `:on-drag`, press handles keyboard activation and drag owns the primary mouse sequence. `:reason` is one of `input`, `quit`, `error` and `target-unavailable`; leaving the window does not cancel a gesture, and a release anywhere ends it; Escape cancels with `quit` and is consumed. `:drag-lock-modifier` can keep the gesture alive across the button release, and `:drag-edge` adds edge phases that report intent for an application-owned scroll; see their [Host entries](hosts.md#property-drag-lock-modifier) and [Dragging and Gestures](dragging-and-gestures.md#edge-intent-and-scrolling).

**Returns.** The return value is ignored.

**Errors.** A handler error propagates after the phase's batch drains and ends the gesture with a `cancel` whose `:reason` is `error`.

**Example.** `(box :on-drag (lambda (gesture) (pcase (plist-get gesture :phase) ('start ...) ((or 'move 'end) ...)))) "Drag me")`

**See also.** `etaf-drag-step`, [Dragging and Gestures](dragging-and-gestures.md), `etaf-draggable`, `etaf-resizable`.

#### Property: :on-scroll

The callback that observes a scrollable Host's offset changing.

**Arguments.** A function of one argument, the new offset in lines, or nil.

**Semantics.** Ebox calls it after the wheel, a scroll key, `ebox-node-set-scroll` or an `etaf-scroll-*` call changes the Host's offset, with the value read back from `ebox-node-scroll-offset`. The callback is how a history list loads older rows when its viewport reaches the top, or more recent rows at the bottom. Content growth is not a scroll: a node pinned to its end by `:scroll-anchor end` follows new rows without calling the handler. Setting the offset a node already has is also not a change and calls nothing.

**Returns.** The return value is ignored.

**Errors.** A handler error propagates from the caller that changed the offset.

**Example.** `(box :ref 'messages :overflow 'scroll :on-scroll (lambda (offset) (when (zerop offset) (load-older))) ...)`

**See also.** [Scrolling](scrolling.md), `ebox-node-scroll-offset`, `etaf-scroll-to`.

#### Property: :on-swipe

The callback that receives a horizontal two-finger gesture.

**Arguments.** A function of one argument, the finger direction `left` or `right`, or nil.

**Semantics.** Trackpad gestures are recognized by the buffer's swipe handling: the innermost enabled Host under the pointer whose `:on-swipe` is a function receives the direction exactly once per gesture, and later events of the same gesture, including momentum, are absorbed. A longer pause or a direction reversal starts the next gesture. The callback does not make the Host activatable and does not change its pointer; it is for navigation such as going back to a list. `ebox-swipe-distance` and `ebox-swipe-quiet` tune the recognition.

**Returns.** The return value is ignored.

**Errors.** A handler error propagates from the wheel event that delivered the gesture.

**Example.** `(box :on-swipe (lambda (direction) (when (eq direction 'right) (go-back))) (text "Chat"))`

**See also.** [Scrolling](scrolling.md) for the gesture model, `ebox-wheel-swipe`.

#### Property: :on-dismiss

The callback that closes or cancels a Host with Escape.

**Arguments.** A function of no arguments, or nil.

**Semantics.** Escape runs the callback of the nearest enabled Host in the current key chain that declares one, stopping at the modal boundary. This is how a dialog, popover or viewer closes without binding the key itself, and it works without keyboard focus because the key chain follows focus, then point. A disabled Host is skipped, so an inner control being disabled does not make the dialog behind it undismissable.

**Returns.** The return value is ignored.

**Errors.** A handler error propagates from the key that ran it.

**Example.** `(column :focus-scope 'modal :on-dismiss close-dialog ...)`

**See also.** [Hosts](hosts.md#property-focus-scope) for the modal scope, [Keyboard](keyboard.md) for the key layer.

#### Property: :on-help-open

Prepare the current application scope before a new keyboard-help opening.

**Arguments.** A function of no arguments, or nil.

**Semantics.** After finishing native editing, `etaf-help` dispatches the nearest enabled Host's callback in the current key scope, stopping at the modal boundary. The callback can pause ongoing application activity without rebinding the framework's help key. Its changes publish before the help snapshot is captured. Repeated opening calls reuse the existing help without dispatching again; closing help does not dispatch or undo application changes. Keep the Runtime mounted and do not recursively open help from this callback.

**Returns.** The return value is ignored.

**Errors.** A callback error or quit aborts opening and propagates to the caller; accepted application state changes remain in place. A later opening can retry.

**Example.** `(column :on-help-open (lambda () (etaf-set-value running nil)) ...)`

**See also.** `etaf-help`, `etaf-help-close`, `:focus-scope`.

#### Property: :on-focus-enter

The callback that runs when keyboard focus enters the Host from outside it.

**Arguments.** A function of no arguments, or nil.

**Semantics.** Every Host that focus moves into from outside runs it, nearest first, once per move; Tab, arrow keys, a press and `etaf-focus` all count. Moving focus between two descendants of the Host does not enter it again, because the previous focus was already inside. Disabled Hosts are skipped. Use it to activate a region when the keyboard reaches it, for example raising a window or switching a sidebar's context, so keyboard and pointer users see the same active state.

**Returns.** The return value is ignored.

**Errors.** A handler error propagates from the focus operation that ran it.

**Example.** `(column :on-focus-enter (lambda () (raise-window 'notes)) ...)`

**See also.** `etaf-focus`, `ebox-focus-change-functions`, [Focus](focus.md).

#### Property: :on-focus-leave

The callback that runs when accepted keyboard focus leaves the Host's subtree.

**Arguments.** A function of no arguments, or nil.

**Semantics.** Enabled Hosts left by a focus move receive this callback nearest-first, before newly entered Hosts receive `:on-focus-enter`. Shared ancestors receive neither notification. Both phases share one reactive batch and observe the already accepted focus; Tab, directions, presses and `etaf-focus` use the same path. Redirecting focus stops notifications for the superseded destination. These are movement notifications, not teardown hooks; removed or unmounted Hosts use Component cleanup instead.

**Returns.** The return value is ignored.

**Errors.** A handler error propagates from the focus operation.

**Example.** `(column :on-focus-leave (lambda () (etaf-set-value active nil)) ...)`

**See also.** `:on-focus-enter`, `etaf-focus`, [Component lifecycle](components.md).

### How several sources compose

One Host can receive the same event callback from up to three places: the Host's own declaration, fallthrough attributes passed to a Component call, and Behaviors attached with `:use`. They compose into one callback that runs the inner declaration first and the outer ones after it, preserving the first callback's return value: the Host's own callback, then caller attributes from innermost to outermost, then Behaviors in declaration order. An error in any callback stops the callbacks after it. A caller can therefore wrap a control's business callback with its own observation without replacing it, and a library Behavior can add behavior beside it. [Hosts](hosts.md#values-and-conflicts) defines the merge table this rule belongs to.

## Activation

<!-- index: activation; RET; pointer activation; interaction movement -->

Activation is what turns a primary click or a key into the Host's `press`. Ebox binds the Host's activation to RET, return, SPC and — when the Host has no drag gesture — the primary mouse button; `etaf-activate` performs the same activation for the focused Host or the interaction boundary at point.

#### Function: etaf-activate (&optional runtime)

Dispatch `press` for the focused Host, or the interaction boundary at point.

**Arguments.** RUNTIME is the mounted Runtime to activate, or nil for the active Runtime or the current buffer's Runtime.

**Semantics.** The target is the focused Host while point lies inside it; otherwise the nearest Host whose keymap covers point, which may be an enclosing pressable row. Activation runs the same handler as a click or the RET key, through `etaf-dispatch-event`, so capture hooks and the reactive event batch behave identically. Keyboard and explicit activation do not create the `active` pointer state, so a click-only policy can distinguish them with `etaf-event-pointer-p`.

**Returns.** The dispatch result of the press callback.

**Errors.** `error→ user-error` when no interactive Host is at point or the target has no press handler; `error→ etaf-event-error` when the Runtime is not mounted, and `error→ etaf-render-side-effect-error` with data `(dispatch-event)` when called during rendering.

**Example.** `(etaf-activate (etaf-runtime-for-buffer buffer))`

**See also.** `etaf-dispatch-event`, `ebox-activate`.

#### Function: ebox-activate (&optional position noerror)

Invoke the RET binding of the node at POSITION, defaulting to point.

**Arguments.** POSITION is a buffer position or nil for point. NOERROR, when non-nil, returns nil instead of signaling when no command exists.

**Semantics.** With nil POSITION the focused node wins while point rests on its first painted character, because that is the node the user sees as focused; otherwise the keymap painted at POSITION answers. The command invoked is the node's activation entry, which for an ETAF Host dispatches the Host's press; a keymap created by `ebox-keymap-create` without an ETAF Host runs its own `:activate` callback.

**Returns.** The command result, or nil when NOERROR suppresses the failure.

**Errors.** `error→ user-error` with the message `"No Ebox RET command at position"` when nothing activates there and NOERROR is nil.

**Example.** `(ebox-activate (ebox-node-position button) t)`

**See also.** `ebox-next-interaction`, `etaf-activate`, `ebox-keymap-create`.

#### Function: ebox-next-interaction (&optional count)

Move point to the next keymap owner COUNT times; return the position.

**Arguments.** COUNT defaults to 1. A negative count moves backward; zero leaves point alone.

**Semantics.** The scan runs over the buffer in order and considers each node that owns a keymap, skipping the owner at point. Unlike focus movement it does not consult `:tab-index`, so it visits exactly the interaction boundaries the pointer can activate, in document order.

**Returns.** The new point, or the current point when COUNT is zero.

**Errors.** `error→ user-error` with the message `"No next Ebox interaction"` when no further keymap owner exists.

**Example.** `(ebox-next-interaction)`

**See also.** `ebox-previous-interaction`, `ebox-activate`.

#### Function: ebox-previous-interaction (&optional count)

Move point to the previous keymap owner COUNT times; return the position.

**Arguments.** COUNT defaults to 1; it is negated before the scan, so a positive COUNT moves backward.

**Semantics.** The backward twin of `ebox-next-interaction`, with the same owner selection and the same exclusion of the owner at point.

**Returns.** The new point, or the current point when COUNT is zero.

**Errors.** `error→ user-error` with the message `"No previous Ebox interaction"` when no earlier keymap owner exists.

**Example.** `(ebox-previous-interaction 2)`

**See also.** `ebox-next-interaction`, `ebox-activate`.

```elisp :run
(etaf-define-component demo-event-log ()
  :bindings ((last (etaf-ref "（还没有事件）"))
             (focus (etaf-ref "（无焦点）")))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (row :item-gap '(ch 1)
               (box :role 'button :tab-index 0 :padding '((lh 1) (ch 2))
                    :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") :pointer 'hand
                    :on-focus-enter (lambda () (etaf-set-value focus "按钮 A"))
                    :on-press (lambda () (etaf-set-value last "press：按钮 A"))
                    (text "按钮 A"))
               (box :role 'button :tab-index 0 :padding '((lh 1) (ch 2))
                    :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff") :pointer 'hand
                    :on-focus-enter (lambda () (etaf-set-value focus "按钮 B"))
                    :on-press (lambda () (etaf-set-value last "press：按钮 B"))
                    (text :color (etaf-theme-token :ui-accent "#0969da") "按钮 B")))
          (text :color (etaf-theme-token :ui-muted-fg "#526174") (expr (format "最近事件：%s" (etaf-value last))))
          (text :color (etaf-theme-token :ui-muted-fg "#526174") (expr (format "当前焦点：%s" (etaf-value focus))))))
(etaf-view (demo-event-log))
```

## Programmatic dispatch

<!-- index: event dispatch; payload; event kind -->

#### Function: etaf-dispatch-event (runtime host-ref kind &optional payload (payload-p nil))

Dispatch KIND for HOST-REF through mounted RUNTIME.

**Arguments.** RUNTIME is a mounted Runtime. HOST-REF addresses a committed Host. KIND is a symbol, keyword or string; an `on-` prefix and surrounding punctuation are normalized away, so `press`, `:press` and `"on-press"` name the same event. PAYLOAD is passed to the callback as its only argument when PAYLOAD-P is non-nil; otherwise the callback is called with no arguments regardless of PAYLOAD.

**Semantics.** The Runtime looks the handler up among the Host's committed properties and runs it inside an event context and a reactive event batch: `etaf-current-runtime` is the Runtime, the current event records its kind, Host and target, and the writes the callback makes publish together at the batch boundary. A press runs the ancestor capture pass after the target callback succeeds, exactly as a pointer press does. A press also finishes an active native input session first unless the pressed Host is the session's own Host, contains the session, or is the innermost Host enclosing it, so clicking away from a field commits the edit before the click's callback runs. Tests and integrations use explicit dispatch in place of a pointer; native pointer and keyboard activation reach the same callbacks.

**Returns.** Whatever the callback returns. The payload flag does not change it.

**Errors.** `error→ etaf-runtime-error` with `"ETAF runtime is not mounted"` when RUNTIME is not mounted. `error→ etaf-event-error` for an invalid KIND, for a Host reference the Runtime does not know or that has no handler for KIND (`"No KIND handler for Host reference REF"`), and for a disabled Host (`"Cannot dispatch to disabled Host reference: REF"`); the one exception is the terminal cancellation Ebox delivers to a drag handler whose target became disabled. `error→ etaf-render-side-effect-error` with data `(dispatch-event)` when called during rendering.

**Example.**

```elisp
(let ((runtime (etaf-runtime-for-buffer "*etaf-status*")))
  (etaf-dispatch-event runtime 'save 'press))
```

**See also.** `etaf-activate`, `etaf-dispatch`, `etaf-current-runtime`.

## Callback order

<!-- index: callback composition; capture order; short-circuit -->

Several callbacks can run for one event, and their order is fixed. On one Host, the declarations compose as described in [How several sources compose](#how-several-sources-compose): the Host's own callback first, caller wrappers next from inner to outer, Behaviors last in declaration order, with the first return value preserved and any error ending the chain.

After a press callback returns successfully, the ancestor capture pass runs from the nearest committed ancestor outward. A Host that is not an ancestor of the target never runs. The pass happens once, not once per ancestor dispatch, and it runs no second pass for a press dispatched from inside a capture callback. If the target callback signals, no capture callback runs.

Nothing else bubbles. A press on a nested control does not run an ancestor's `:on-press`, and a key handled by a Host does not also run the same key's buffer command. The capture hook exists precisely so a shell can express ancestor policy without implicit propagation, and `etaf-event-target-within-p` is how that policy identifies the target.

## Event context

<!-- index: event context; pointer origin; event target -->

While a callback runs, ETAF keeps the event in progress so the callback can ask about it. Both queries signal when called outside an event callback, because outside one there is no event to describe.

#### Function: etaf-event-pointer-p ()

Return non-nil when the current event came from a pointer button.

**Arguments.** None.

**Semantics.** A press activated by a mouse or trackpad click returns non-nil; keyboard activation with RET or SPC, and an explicit dispatch of a non-mouse input, return nil. Click-only policies such as dismissing a modal when its backdrop is clicked use it so the same callback triggered by a key never applies the policy. The value reads the input event that started the delivery, so a drag gesture delivered from the keyboard is recognized by its own `:keyboard` flag rather than by this query.

**Returns.** Non-nil for a pointer button, nil otherwise.

**Errors.** `error→ etaf-event-error` with the message `"Event source lookup requires a Host event callback"` outside a callback.

**Example.** `(when (etaf-event-pointer-p) (close-on-backdrop-click))`

**See also.** `etaf-event-target-within-p`, `:on-press`.

#### Function: etaf-event-target-within-p (host-ref)

Return non-nil when the current event's target is HOST-REF or inside it.

**Arguments.** HOST-REF is compared with `equal`.

**Semantics.** In an ancestor `:on-press-capture` callback the target is the Host whose press callback ran; in any other callback it is the callback's own Host. The comparison walks the target's committed Host ancestors, so a root shell can tell a press inside an open panel from one on the surface around it and close the panel only in the first case. A Host reference that is not committed is simply not found.

**Returns.** Non-nil when the target equals HOST-REF or lies inside it, nil otherwise.

**Errors.** `error→ etaf-event-error` with the message `"Event target lookup requires a Host event callback"` outside a callback.

**Example.** `(when (etaf-event-target-within-p 'panel) (raise 'panel))`

**See also.** `:on-press-capture`, `:on-press`, `etaf-host-ref-at`.

## The active state

<!-- index: active state; pointer press; state selector -->

Ebox derives an `active` selector state for the Host currently under a primary-button press. It is not authored data: it exists while the tracking loop for that press is alive, disappears when the loop ends, and ETAF never stores it. Component styles and stylesheets match it as `&:active`, so a button can paint its held state without the application writing anything.

The state appears when tracking begins and clears before the press callback runs. A Host that declares a drag gesture starts tracking on the press itself, so it is active from the button-down. A Host with only a press starts tracking with the press-claim sequence as well, but the state itself is applied at the first pointer motion: a click that presses and releases without moving never shows `:active`, while a slight movement does. On release, Ebox clears the state, then activates the Host, so the callback observes the base style; a drag handler's `end` phase still sees the active state, which clears when the tracking loop exits.

Keyboard activation with RET or SPC and an explicit `etaf-dispatch-event` create no pointer state, so a Host's `:active` appearance means a real pointer press is being tracked. Because the state lives on the mount, it survives a republish during the gesture: a drag handler may update the Host's properties or position and the held appearance stays until release.

## Hover feedback

<!-- index: hover; mouse face; help echo; hover content -->

Hover feedback is native: Ebox paints `:hover-style` as the node's `mouse-face` and `:help-echo` as the node's help text, so Emacs itself shows them while the pointer rests on the Host. The paint covers the whole drawn area of the element, including its padding and every row it spans, and a hidden element paints no feedback at all. Both properties inherit from ancestors and an explicit nil blocks the inherited value, as [Interaction Overview](interaction-overview.md#inheriting-interaction-attributes) describes.

`:hover-content` changes what the element shows rather than how it is painted: while the pointer is over the Host — or keyboard focus reaches it — ETAF replaces the text of the Host's first text descendant with the value and restores the original text when the pointer or focus leaves. `:hover-group` makes several Hosts switch together, so a toolbar can reveal every button's full label as one batch. A zero-argument function can compute the replacement value.

#### Function: ebox-help-create (function)

Adapt zero-argument FUNCTION to a native `help-echo` callback.

**Arguments.** FUNCTION takes no arguments and must return a string or nil.

**Semantics.** Ebox help functions are native three-argument `help-echo` callbacks, and this adapter bridges the simpler form: when Emacs calls the returned function, it resolves the buffer for the help object (the buffer, overlay buffer or the live window's buffer), makes it current, calls FUNCTION and returns its string. The Host already accepts a plain string as `:help-echo`, so this is for help text that has to be computed at display time, for example from the row under the pointer.

**Returns.** A function suitable for the native `help-echo` text property.

**Errors.** `error→ error` when FUNCTION is not a function or does not accept zero arguments, at creation; a return value that is neither a string nor nil signals when Emacs displays the help.

**Example.** `(text :help-echo (ebox-help-create (lambda () (format "Saved %s" (current-time-string)))) "Status")`

**See also.** [Hosts](hosts.md#property-help-echo), `:hover-style`, `:hover-content`.

## Disabled Hosts and hit testing

<!-- index: disabled host; empty keymap; hit testing -->

A disabled Host stays visible and keeps its layout place, but it is inert: it runs no event callback and no `:keys`, its Behaviors are not installed, and it cannot receive focus. Ebox gives it an empty keymap, so it still owns its hit area and blocks rather than falls through: a click on a disabled button never activates the row around it, even when their painted bounds coincide. This is what lets an application disable one control without accidentally making its container the target.

The rest of the boundary rules belong to [Interaction Overview](interaction-overview.md#hit-testing): activation follows the nearest keymap, so a label inside a pressable row activates the row and a nested control with its own callback handles the press itself, while an ordinary Host that declares no pressure boundary leaves the parent's keymap in charge. `etaf-host-ref-at` answers which Host was hit from an application's perspective.

## Errors and recovery

<!-- index: event errors; dispatch errors -->

#### Error: etaf-event-error

Invalid ETAF Event. It is signaled when an event operation cannot be carried out because the event context or target is invalid. Catch this condition with `condition-case`; failed calls do not return a value. Its parent condition is `error`, and its data is a list of values describing the violation.

| Data | Cause |
| --- | --- |
| `("Invalid event kind: %S")` | A dispatch KIND that is not a symbol, keyword or string |
| `("No KIND handler for Host reference REF")` | A target, or a reference the Runtime does not know, without a committed handler for that kind |
| `("Cannot dispatch to disabled Host reference: REF")` | A dispatch to a disabled Host; the terminal drag cancellation is exempt |
| `("Event source lookup requires a Host event callback")` | `etaf-event-pointer-p` outside a callback |
| `("Event target lookup requires a Host event callback")` | `etaf-event-target-within-p` outside a callback |
| `("Drag step COLUMNS and ROWS must be numbers")`, `("No committed Host reference" REF)` | Invalid arguments or a missing Host in `etaf-drag-step` |
| `("Native input requires a Host event callback")` | `etaf-call-with-input` outside a callback |

The error reports a broken dispatch, not a broken Host: a missing or disabled target leaves the committed tree, focus and input session unchanged, so the application can fix the reference or the disabled state and dispatch again. An empty position is not this error: `ebox-activate` and `etaf-activate` signal `user-error` there, because nothing is wrong with the event.
