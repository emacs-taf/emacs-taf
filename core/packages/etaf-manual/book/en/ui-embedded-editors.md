# Embedded Native Editors

`etaf-ui` also offers one editing behavior for application-owned buffers outside the rendered surface: an integration such as a native-pane chat client reuses the same mode and callbacks that the catalog's text field uses, while the application owns the buffer, its window placement, its drafts and its transport. This chapter defines that shared behavior — the minor mode, its configuration, the value query and the tick-guarded replacement — because it is part of the public interface even though it mounts no View. [Text Input](text-input.md) defines the in-layout editing session, [Text Input Controls](ui-text-input-controls.md) the components that drive it, and [Views](views.md) why an application-owned buffer can sit beside rendered content.

## What the behavior owns

<!-- index: embedded editor; native pane; empty hint; observer -->

The behavior is deliberately small. It owns an empty-text hint and one edit observer; it never owns windows, layout, the application's draft, transport acknowledgements or any rendered Ebox surface, and it schedules no rendering for each typed character. Enabling the mode preserves the buffer's text, major mode, key bindings, undo history, point, mark, completion setup and modified state — it adds behavior beside them, it does not replace the editing stack.

The empty hint is an overlay at the beginning of the buffer whose after-string paints the placeholder only while the text is empty; it is not part of the text, the selection or the undo history, so reading the value or copying the buffer never includes it. The observer receives the buffer after accepted text changes, and it receives no eager text copy: an application reads the value only when it needs it. An observer error propagates to the native command after the edit, and the accepted text stays available; the observer must not edit the same buffer it is observing.

Replacement is written for asynchronous results. The application captures both the text it expects to supersede and the buffer's character modification tick; after an async operation completes it calls the replacement with that tick, and a buffer whose text changed in the meantime — including a change that was undone back to the same string — makes the call return nil instead of overwriting the user's newer edit. An equal value is accepted without touching selection, undo or modification state, and a changed value is one undoable replacement.

## The editor mode

<!-- index: etaf-ui-editor-mode; minor mode; cleanup -->

#### Function: etaf-ui-editor-mode (&optional arg)

Enable or disable native editing behavior in a caller-owned UI buffer.

**Arguments.** ARG is the ordinary minor-mode argument: nil toggles, a positive number enables and a non-positive number disables.

**Semantics.** Enabling preserves text, the major-mode keymap, undo, selection and CAPF. It owns an empty hint and edit observation, not window layout or transport: no minibuffer is opened and no per-character rendering is scheduled. Disabling removes its overlay and hooks, never text. Changing the major mode or killing the buffer also cleans the behavior up, so a released buffer keeps no observer. The mode's lighter is nil.

**Returns.** The mode's new state, as any minor mode returns.

**Example.**

```elisp
(with-current-buffer (get-buffer-create "*Embedded editor*")
  (text-mode)
  (etaf-ui-editor-mode 1)
  (etaf-ui-editor-configure :placeholder "Write here"))
```

**See also.** `etaf-ui-editor-configure`, `etaf-ui-editor-value`.

## Configuring the behavior

<!-- index: etaf-ui-editor-configure; placeholder; change observer -->

#### Function: etaf-ui-editor-configure (&key (placeholder nil placeholder-p) (placeholder-face nil face-p) (on-change nil callback-p))

Configure the current editor's hint string, face and edit observer.

**Arguments.** PLACEHOLDER is a string copied without text properties; PLACEHOLDER-FACE is a face name or plist (default `shadow`); ON-CHANGE is nil or a function receiving the edited buffer. A supplied keyword replaces the corresponding setting, while an omitted one keeps its current value; an explicit nil ON-CHANGE detaches the observer. PLACEHOLDER does not accept an explicit nil, because the hint is always a string.

**Semantics.** Enable `etaf-ui-editor-mode` first. Configuration never changes the text and never calls ON-CHANGE. The observer receives the buffer rather than a copied value, and it must not edit that buffer: read text with `etaf-ui-editor-value`. An observer error propagates after the edit and does not erase the draft.

**Returns.** Unspecified.

**Errors.** `error→ user-error` with `"Expected a live buffer with etaf-ui-editor-mode enabled"` when the current buffer is dead or the mode is off, and `"Invalid editor placeholder, face or change observer"` when the placeholder is not a string, the face is neither nil, a face nor a proper list, or the observer is neither nil nor a function.

**Example.**

```elisp
(etaf-ui-editor-configure :placeholder "Write here"
                          :on-change (lambda (editor)
                                       (message "%d characters"
                                                (length (etaf-ui-editor-value editor)))))
```

**See also.** `etaf-ui-editor-value`, `etaf-ui-editor-replace`.

## Reading and replacing the value

<!-- index: etaf-ui-editor-value; etaf-ui-editor-replace; modification tick -->

#### Function: etaf-ui-editor-value (&optional buffer)

Return a detached, property-free, widened text value without changing edit state.

**Arguments.** BUFFER defaults to the current buffer and must have the editor behavior enabled.

**Semantics.** The returned string is the whole buffer text with text properties removed, regardless of narrowing. The query changes nothing: point, mark, narrowing, modified state and undo history stay as they were, and the caller owns the returned string.

**Returns.** The editor's text as a new string.

**Errors.** `error→ user-error` with `"Expected a live buffer with etaf-ui-editor-mode enabled"` when BUFFER is dead or does not have the mode.

**Example.** `(etaf-ui-editor-value editor)`

**See also.** `etaf-ui-editor-replace`.

#### Function: etaf-ui-editor-replace (buffer text &optional expected-tick)

Replace native editor text, preserving markers where possible and making one undoable replacement.

**Arguments.** BUFFER must have the editor behavior enabled. TEXT is the replacement string; EXPECTED-TICK, when non-nil, is compared against the buffer's `buffer-chars-modified-tick`.

**Semantics.** Return t when the replacement is accepted, including identical text. When EXPECTED-TICK is non-nil and differs from the current tick, return nil without changing anything; an edit followed by an undo also makes an earlier tick stale, so a late asynchronous result never overwrites a newer edit. An equal value changes nothing and emits no notification. A changed value is one undoable replacement, retaining native markers where possible; other native change hooks still run, and this behavior notifies ON-CHANGE once after the replacement. It never decides whether an asynchronous result permits replacement, and it never owns the draft: the application decides.

**Returns.** t when accepted, nil when the tick is stale.

**Errors.** `error→ user-error` with `"Expected string text and an optional integer modification tick"` when TEXT is not a string or EXPECTED-TICK is not an integer, with `"Expected a live buffer with etaf-ui-editor-mode enabled"` for a dead BUFFER or a buffer without the mode, and with `"Cannot replace editor text from its change observer"` when called reentrantly from ON-CHANGE. Invalid inputs and stale buffers signal before any change.

**Example.**

```elisp
(let ((tick (buffer-chars-modified-tick)))
  (send-message (etaf-ui-editor-value buffer))
  (etaf-ui-editor-replace buffer "" tick))
```

**See also.** `etaf-ui-editor-value`, `etaf-ui-editor-configure`.

## Semantics in detail

<!-- index: replacement internals; read-only buffer; reentrancy guard -->

A replacement is one edit, not a sequence of visible operations: the mode bounds it with undo boundaries and applies it atomically, so a changed value is one undo step and a failure inside the group cannot leave half of the new text. The replacement explicitly allows a read-only buffer — an integration that mirrors a sent message may paint into a locked buffer — while ordinary native typing still respects `buffer-read-only`.

The mode's own notification is guarded in both directions: while the replacement applies the new text it suppresses its change notification, and it runs the observer only once when the edit settles. Because the observer may not replace the same editor, a callback that mirrors edits back into the buffer must do so outside the notification, typically from the application's own command loop. The empty hint is refreshed on every accepted change, so it reappears when the user clears the text and vanishes on the first character.

## Errors and recovery

- `error→ user-error` covers the behavior's usage errors, as each entry above lists; the messages name the violated expectation, and stale ticks return nil instead of signaling, because a stale asynchronous result is an ordinary race rather than a programming error.
- An observer error propagates to the native command but never erases the accepted text: the draft the user typed is already in the buffer, and the application can decide how to recover.
- Reconfiguring or disabling the behavior never edits text; disabling, changing the major mode or killing the buffer removes the overlay, the hooks and the observer, so a released buffer cannot call back into the application.
- A rejected replacement leaves everything untouched — text, selection, undo history, modification state — so a caller can retry with a fresh tick without repairing state.

**See also.** [Text Input](text-input.md), [UI Overview](ui-overview.md#errors-and-recovery).
