# Text Input

A rendered text Host is normally output, not an editing surface: the canvas has no text selection and unbound printing keys do nothing. When the user must type into a field without leaving the mounted layout, an *input session* turns exactly one laid-out text node into an editable value. The keys the user types are ordinary Emacs editing commands, running against a hidden buffer that holds the value; the node redraws each keystroke inside its own box, so wrapping, padding and borders stay in place while the value grows and shrinks. This chapter describes the session model, the ETAF and Ebox entry points, click and selection mapping, input-method preedit, how a session ends including the runtime finisher, and the error conditions. [Events](events.md) defines the Host event callbacks that begin sessions from presses, and [Keyboard](keyboard.md) defines the key layer, which steps aside while a session edits.

## The input session

<!-- index: input session; editing buffer; session value -->

A session connects three things: the mounted text node, a hidden editing buffer that holds the node's value, and the command loop of the mounted buffer. Creating a session copies the node's current text into the editing buffer and redirects the editing commands that arrive at the mounted buffer to that buffer — insertion, deletion, motion, the kill ring, undo, the region, and input methods all act on the value while the mounted buffer itself stays read-only. After each command the session reads the buffer back, calls the change callback when the value changed, and repaints the node, so the visible field always matches the value.

The node keeps its layout while it is edited. Wrapping, padding and borders belong to the box around it and stay untouched; the value is re-measured and the box may grow or shrink. Point in the mounted buffer follows the editing caret, and up and down move by painted rows rather than by value lines, so a wrapped value moves the way it looks. The painted characters carry their value offsets, which is what lets the session map a click to a caret position and back. A session is the only supported way to let the user edit mounted text; writing to the buffer directly would fight the retained tree.

At most one session exists per mounted buffer. Disposing the mount ends its session, and so does the explicit end call. When a session ends, its editing buffer is remembered for the node rather than discarded: if the node's text has not changed since the last session, the next session reuses that buffer and keeps the caret, the region and the undo history, so a field that closes and reopens resumes where the user left it.

## The ETAF interface

<!-- index: input API; :on-change; :keymap; :local-variables -->

The ETAF functions address a session by Host reference, matching the rest of the application API, and forward the session options to Ebox.

#### Function: etaf-input-begin (runtime host-ref &rest options)

Start native editing of a mounted text Host's value; return a session.

**Arguments.** RUNTIME is the mounted Runtime. HOST-REF names a committed text Host; a Host of another kind signals `ebox-input-error`. OPTIONS are the input session options: `:on-change` receives the new value after each command that changes it, `:on-leave` runs when a later click lands outside the Host's box, `:keymap` holds bindings consulted before the editing commands, `:local-variables` is an alist of buffer-local settings for the editing commands, and `:caret` is a value offset placing the caret. The remaining options are Ebox's, so this list grows with the Ebox contract rather than being redefined here.

**Semantics.** The Host's text becomes the session value with the caret at its end unless `:caret` says otherwise. Typed keys edit the value with ordinary Emacs commands, undo and input methods while the Host keeps its layout, padding and borders and shows each edit at once. Publication continues during the session: publishing the session value into the Host is a no-op, and publishing another value replaces the session text and clears its undo history. A session begins and ends without any explicit flush; the mounted buffer updates as the user types.

**Returns.** The session object, used by `etaf-input-text`, `etaf-input-end` and `ebox-input-session-node`.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted; `error→ etaf-event-error` with `"No committed Host reference"` for an unknown HOST-REF; `error→ ebox-input-error` when the Host is not a laid-out text node, the buffer already has a session, or a `:keymap` value is not a keymap.

**Example.** `(etaf-input-begin runtime 'search-field :on-change (lambda (value) (etaf-set-value query value)))`

**See also.** `etaf-input-text`, `etaf-input-end`, `ebox-input-begin`.

#### Function: etaf-input-text (session)

Return a session's current property-free value, or nil once it ended.

**Arguments.** SESSION is a session returned by `etaf-input-begin`.

**Semantics.** The value is the editing buffer's contents with text properties stripped, so callers never see caret overlays or preedit marks. Reading it does not end the session and does not publish anything. After the session ends the value is nil, because the final value belongs to the Host that keeps displaying it.

**Returns.** The current value string, or nil after the session ended.

**Errors.** `error→ ebox-input-error` when SESSION is not a session object.

**Example.** `(etaf-input-text session)`

**See also.** `etaf-input-end`, `ebox-input-text`.

#### Function: etaf-input-end (session)

End a session and return its value; the Host keeps displaying it.

**Arguments.** SESSION is a session.

**Semantics.** The session is detached from the buffer, the Host's text is set to the final value without preedit, and the session's editing buffer is cached for reuse. Ending a session that already ended — for example because its buffer was unmounted — returns nil and does nothing. Ending is idempotent and never signals for an already-ended session.

**Returns.** The final value string, or nil when the session had already ended.

**Errors.** `error→ ebox-input-error` when SESSION is not a session object.

**Example.** `(etaf-input-end session)`

**See also.** `etaf-input-text`, `etaf-call-with-input`, `etaf-runtime-set-input-finisher`.

#### Function: etaf-input-active-p (&optional runtime)

Return a mounted Runtime's active input session, or nil.

**Arguments.** RUNTIME defaults to the active Runtime or the current buffer's Runtime.

**Semantics.** This is the Runtime-level query for "is the user editing, and what are they editing". A Runtime with no session returns nil instead of signalling, which makes the check safe inside key handlers and event callbacks.

**Returns.** The session object, or nil.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**Example.** `(etaf-input-active-p runtime)`

**See also.** `etaf-input-begin`, `ebox-input-active-p`.

#### Function: etaf-input-edit-command-add (command)

Add COMMAND to the commands that edit a native input session's text.

**Semantics.** A command in this list that is bound in a session keymap edits the session value; other session bindings run in the mounted buffer. The list starts with the standard insertion, motion and yank commands, and a catalog component registers its own editing commands here.

**Returns.** The updated command list.

**Errors.** `error→ wrong-type-argument` naming `commandp` when COMMAND is not a command symbol.

**See also.** `etaf-input-edit-command-remove`, `ebox-input-begin`.

#### Function: etaf-input-edit-command-remove (command)

Remove COMMAND from the native input session's text-editing commands.

**Semantics.** Use it when a component unloads or when a command should stop editing the session value; the other session bindings then run in the mounted buffer again.

**Returns.** The updated command list.

**Errors.** `error→ wrong-type-argument` naming `commandp` when COMMAND is not a command symbol.

**See also.** `etaf-input-edit-command-add`.

```elisp :run
(etaf-define-component demo-input-mirror ()
  :bindings ((value (etaf-ref "")))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (etaf-text-input :bind value
                           :label "姓名"
                           :placeholder "在这里输入…"
                           :rows 2)
          (text :color (etaf-theme-token :ui-muted-fg "#526174")
                (expr (format "受控值：%S" (etaf-value value))))))
(etaf-view (demo-input-mirror))
```

## The Ebox interface

<!-- index: Ebox input; session node -->

The Ebox entry points are the same sessions without the Runtime layer: they address the mounted node directly, which is what a library that owns an Ebox tree without ETAF uses. Everything an ETAF application can do with a session is available here, including the pieces ETAF does not surface, such as the edited node and the command classification.

#### Function: ebox-input-begin (buffer-or-name node &rest options)

Begin native editing of laid-out text NODE in BUFFER-OR-NAME and return a session.

**Arguments.** NODE is a live, laid-out text node. OPTIONS is a plist: `:on-change` receives the new value after each command that changes it; `:keymap` holds bindings consulted first; `:on-leave` runs when a later click lands outside the node's box; `:local-variables` is an alist of buffer-local settings such as `completion-at-point-functions`; `:caret` is a value offset placing the caret.

**Semantics.** The node's text becomes the session value with the caret at its end, unless `:caret` places it. While the session is active, keys typed in BUFFER-OR-NAME are classified: a binding from `:keymap` runs in the buffer, except the commands in `ebox-input-edit-commands`, which edit the value; keys with no session binding run the editing command of the hidden buffer, so insertion, deletion, motion, kill and yank, undo, the region and input methods all act on the value while the buffer stays read-only. The node keeps its layout and repaints each edit, point follows the caret, up and down move by painted rows, and a click inside the node's box moves the caret or selects. The gesture that opened the session does not count as leaving it. Setting the node's text to the session value is a no-op; another string replaces the value and clears its undo history. A session whose node text is unchanged since the last one reuses the previous editing buffer, keeping the caret, region and undo history.

**Returns.** The session.

**Errors.** `error→ ebox-input-error` when BUFFER-OR-NAME has no mount, when NODE is not a live laid-out text node, when the buffer already has a session, or when `:keymap` is not a keymap.

**Example.** `(ebox-input-begin buffer field :on-change (lambda (value) (message "%s" value)))`

**See also.** `ebox-input-end`, `ebox-input-edit-commands`, `ebox-call-with-input`.

#### Function: ebox-input-text (session)

Return SESSION's current value, or nil once it ended.

**Arguments.** SESSION is an input session.

**Semantics.** The value is property-free, so caret overlays and preedit marks are never part of it. It is the same value `:on-change` receives, read on demand; after the session ends the function returns nil.

**Returns.** The current value string, or nil.

**Errors.** `error→ ebox-input-error` when SESSION is not a session object.

**Example.** `(ebox-input-text session)`

**See also.** `ebox-input-end`, `etaf-input-text`.

#### Function: ebox-input-end (session)

End SESSION and return its value; NODE keeps displaying it. Ending a session that already ended returns nil.

**Arguments.** SESSION is an input session.

**Semantics.** The session detaches, the node's text becomes the final value without preedit, and the editing buffer is cached for the node so a later session can reuse its caret and undo history. Ending is safe to call twice and safe after the buffer was unmounted.

**Returns.** The final value string, or nil when the session had already ended.

**Errors.** `error→ ebox-input-error` when SESSION is not a session object.

**Example.** `(ebox-input-end session)`

**See also.** `ebox-input-begin`, `ebox-input-session-node`.

#### Function: ebox-input-active-p (&optional buffer-or-name)

Return the active input session of BUFFER-OR-NAME, or nil.

**Arguments.** BUFFER-OR-NAME defaults to the current buffer.

**Semantics.** The session is stored on the mount, so this is a direct lookup without consulting the Runtime layer. An unmounted or sessionless buffer returns nil.

**Returns.** The session, or nil.

**Errors.** None.

**Example.** `(ebox-input-active-p buffer)`

**See also.** `ebox-input-begin`, `etaf-input-active-p`.

#### Function: ebox-input-session-node (session)

Return the node SESSION edits.

**Arguments.** SESSION is an input session.

**Semantics.** The node is the laid-out text node originally passed to `ebox-input-begin`, still live for as long as the session lasts. Applications use it to compare the edited target against a hit test, or to hand it to Ebox's own update and geometry functions. Node updates through the session are the supported path; the node identity does not change while editing.

**Returns.** The Ebox text node.

**Errors.** `error→ ebox-input-error` when SESSION is not a session object.

**Example.** `(ebox-node-bounds (ebox-input-session-node session))`

**See also.** `ebox-input-begin`, `ebox-node-set-text`.

#### Variable: etaf-cursor-follows-input-modality

Whether a mounted canvas hides its cursor after a pointer press.

**Semantics.** A painted page follows the input modality: a press leaves the cursor as a stray block, so it hides until the next keyboard command. An application that edits text in place sets this to nil, because a press there really does place a caret the user needs to see.

**Returns.** Not applicable; the variable is a boolean.

**See also.** [Text input](text-input.md), [Focus](focus.md).

#### Variable: ebox-allow-text-selection

Whether a mounted canvas allows native Emacs mark and pointer text selection.

**Semantics.** Nil by default so canvas applications keep pointer presses and `set-mark-command` from painting a region over layout cells. Setting it buffer-locally to non-nil (or passing `:text-selection t` to `etaf-mount`) lets reading and browser buffers use native Emacs mark, Shift-movement, pointer drag selection and `kill-ring-save` while interactive controls keep their own press and drag gestures.

**Returns.** Not applicable; the variable is a boolean.

**See also.** `etaf-mount`, `etaf-cursor-follows-input-modality`.

#### Variable: ebox-input-edit-commands

Commands that edit the session value when a session `:keymap` binds them.

**Semantics.** When a `:keymap` entry binds one of these command symbols — `newline`, `open-line`, `newline-and-indent`, `electric-newline-and-maybe-indent`, `completion-at-point`, `indent-for-tab-command`, `yank` — the key edits the value instead of running the command in the mounted buffer. Any other binding of a session keymap runs in the mounted buffer, which is how a field binds RET to submit while Shift-RET or C-j inserts a newline. The list exists because these commands act on text, not on the widget: running `newline` in the mounted buffer would try to insert into a read-only canvas, while the session wants the newline in its value.

**Returns.** Not applicable; the variable holds the command list.

**See also.** `ebox-input-begin`, [Keymaps](hosts.md#property-keys).

## Clicks, selection and offset mapping

<!-- index: caret placement; pointer selection; value offsets -->

A session makes the field's painted cells a pointer target for the caret. A primary press inside the node's box — its padding included, and bounded by the nearest keymap owner when one frames it — places the caret at the value offset of the pressed character, before it. Pressing and dragging extends a selection, and the selection lives in both buffers: dragging over the value highlights the same characters in the field, and editing commands that operate on the region see it. A double press selects the word under the pointer and a triple press the whole value, matching ordinary Emacs behavior. A press on the padding still counts as inside the field, and a press that a control nested inside the field's frame owns keeps the session open, because that control's callback may act without ending editing; any other press outside the box leaves the field.

The mapping is the reason the value can wrap: every painted character carries its offset in the value, so the session converts a buffer position to a value offset and back. Up and down use the same map to move by painted rows while preserving the column, and a caret placed by a click or by editing commands stays consistent with point in the mounted buffer. Writes that come from outside — `ebox-node-set-text`, an application updating the mounted content — are followed: an equal string is ignored, a different string replaces the value and clears its undo history, and the session keeps editing from there.

## Input method preedit

<!-- index: preedit; input method; working text -->

Input methods need somewhere to show text that is not committed yet. While a session is active, the working text of the input method is shown at the caret, wrapped inside the field's box like any other content, while the session value stays unchanged; when the input method commits, the resulting characters are inserted into the value and the preedit disappears. The special events Emacs uses for this on macOS are routed to the active session while any session exists and restored to their native bindings afterwards, so an input method works in the field exactly as it does in a normal buffer. Both the value read by `ebox-input-text` and the value reported to `:on-change` exclude the preedit.

## Ending, leaving and the finisher

<!-- index: ending a session; on-leave; finisher; native read -->

A session ends through an explicit end call, through its buffer being unmounted, or through a press that lands elsewhere. The last case is policy the application can steer: a press delivered to a Host that is neither the session's Host, nor one containing it, nor the nearest Host framing it ends the editing session first, so clicking away from a field commits it before the click's callback runs. How the session ends is the application's decision, which is what the finisher is for.

#### Property: :on-leave

The callback an input session runs when a click lands outside the edited box.

**Arguments.** A function of no arguments, or nil. It is passed as an input-session option, not declared on a Host: `:on-leave` is not a Host event property and is never dispatched by the event layer.

**Semantics.** When the session is active, a later click whose position is outside the edited node's box calls the callback once. The gesture that opened the session does not count: a click on the field opens the session and must not immediately report leaving it. The callback is the hook for policy such as committing the value, closing a popover, or moving the editing session to the clicked field. It runs in the mounted buffer with the session still active, so it can read the value or end the session itself.

**Returns.** The return value is ignored.

**Errors.** A callback error propagates from the command that delivered the click.

**Example.** `(ebox-input-begin buffer field :on-leave (lambda () (message "left the field")))`

**See also.** `ebox-input-begin`, `etaf-input-begin`, `etaf-runtime-set-input-finisher`.

#### Function: etaf-call-with-input (reader)

Run zero-argument native input READER from the current Host event callback.

**Arguments.** READER takes no arguments and returns the value the caller wants back.

**Semantics.** This is the event-callback form of a short native read: the current event supplies the Host, so no Runtime or reference is passed. Ebox restores logical focus to that Host and checks that it is still visible and enabled; if the target becomes unavailable the call signals a subtype of `quit`. The reader owns the native editing — it may use the minibuffer or another buffer — and the function returns its result without applying any application state, so a caller decides what to do with the value. Native editing must not edit the rendered surface itself.

**Returns.** READER's result, provided the target is still valid.

**Errors.** `error→ etaf-event-error` with `"Native input requires a Host event callback"` outside an event callback; `error→ etaf-render-side-effect-error` with data `(read-input)` when called during rendering; READER errors and user quit propagate unchanged; target invalidation signals `ebox-input-cancelled`, a subtype of `quit`.

**Example.** `(etaf-call-with-input (lambda () (read-string "Name: ")))`

**See also.** `ebox-call-with-input`, `etaf-input-begin`, `etaf-dispatch-event`.

#### Function: ebox-call-with-input (node reader &optional buffer-or-name)

Call zero-argument READER for visible, enabled NODE in BUFFER-OR-NAME.

**Arguments.** NODE is the Ebox node to read for; BUFFER-OR-NAME defaults to the current buffer.

**Semantics.** The call is synchronous and scoped: the reader runs while Ebox owns target validation, and afterwards logical focus belongs to NODE. If NODE has disappeared or become unavailable by then, the earlier focus returns when it is still focusable, and the call still signals, so a caller never mistakes a vanished target for a successful read.

**Returns.** READER's result.

**Errors.** `error→ user-error` with `"Ebox input target is not available"` when NODE is not focusable at the start; `error→ ebox-input-cancelled` with the node when NODE is no longer available after the read.

**Example.** `(ebox-call-with-input field (lambda () (read-string "Name: ")) buffer)`

**See also.** `etaf-call-with-input`, `ebox-input-begin`.

#### Function: etaf-runtime-set-input-finisher (runtime finisher)

Set mounted RUNTIME's native input session finisher to FINISHER or nil.

**Arguments.** FINISHER is a function of one argument, the Runtime, or nil to remove it.

**Semantics.** A finisher is the application's policy for leaving a session on a press elsewhere. When a `press` is dispatched to a Host that is neither the session's own Host, nor a Host containing it, nor the nearest Host framing it, the Runtime calls the finisher before the target callback runs, and the finisher should end the session according to the application's keep-or-edit decision. The catalog's in-place text input registers one while its session is open. Because the finisher runs inside the press batch, the publication that ends the session settles before the press callback observes the tree. A Runtime without a finisher simply leaves the session open.

**Returns.** FINISHER.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted; `error→ wrong-type-argument` with data `(functionp FINISHER)` for a non-function, non-nil value.

**Example.** `(etaf-runtime-set-input-finisher runtime (lambda (rt) (etaf-input-end (etaf-input-active-p rt))))`

**See also.** `etaf-runtime-input-finisher`, `:on-leave`, `etaf-input-end`.

#### Function: etaf-runtime-input-finisher (x)

Return RUNTIME's registered input session finisher, or nil.

**Arguments.** X is the Runtime whose slot is read.

**Semantics.** This is the structure accessor behind `etaf-runtime-set-input-finisher`, exposed for code that reads Runtime state rather than setting it. It returns exactly the function that was registered, or nil when none is installed; it does not call the finisher.

**Returns.** The finisher function, or nil.

**Errors.** `error→ wrong-type-argument` when X is not a Runtime.

**Example.** `(when (etaf-runtime-input-finisher runtime) (message "input policy installed"))`

**See also.** `etaf-runtime-set-input-finisher`, `etaf-input-active-p`.

## Errors and recovery

<!-- index: input errors; cancellation -->

Input session failures are explicit because the session owns a shared resource: a buffer has at most one. Creating a session on an unmounted buffer, on a node that is not laid-out text, on a buffer that already has one, or with a `:keymap` that is not a keymap is an `ebox-input-error`; the same condition covers calling the session accessors with something that is not a session. Unknown Host references and unmounted Runtimes are reported by the ETAF layer as `etaf-event-error` and `etaf-runtime-error`, matching the rest of the application API. A read that loses its target signals `ebox-input-cancelled`, a subtype of `quit`, so callers that catch `quit` for user cancellation also catch an invalidated target, and callers that do not treat it as a normal cancellation. Ending a session is always safe: the second end returns nil, and unmounting the buffer silently drops any session it owned.

#### Error: ebox-input-error

Invalid Ebox input session

**Semantics.** Signals that an input session operation cannot be carried out because its target or session is invalid. It is a child of `ebox-error`. Catch it with `condition-case`; failed calls do not return a value.

**Causes.** An unmounted buffer, a node that is not a live laid-out text node, a buffer that already has a session, a `:keymap` that is not a keymap, and accessor calls with a value that is not a session.

**See also.** `ebox-input-begin`, `etaf-input-begin`.

#### Error: ebox-input-cancelled

Ebox input target is no longer available

**Semantics.** Signals that a synchronous read's target disappeared or became unavailable before the reader returned. The condition is a child of `quit`, so `condition-case` handlers for `quit` catch it and user cancellation and target invalidation travel together. The error data carries the stale node.

**Recovery.** The call did not apply anything; the earlier focus returns when it is still focusable. The application can re-read with a fresh target or treat the read as cancelled.

**See also.** `ebox-call-with-input`, `etaf-call-with-input`.
