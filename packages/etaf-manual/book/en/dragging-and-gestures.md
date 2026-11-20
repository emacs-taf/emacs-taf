# Dragging and Gestures

Direct manipulation — moving a panel, resizing a split, scrubbing a slider — is built from the same event machinery as a button press. A Host declares `:on-drag`; Ebox tracks the primary button and delivers the gesture phase by phase; ETAF runs each phase in its own reactive batch. On top of that, the framework adds two things applications should not rebuild: a keyboard equivalent for every pointer gesture, and Behaviors that turn gesture deltas into caller-owned geometry. This chapter describes the gesture contract as a whole, the drag lock, edge intent for application-owned scrolling, the keyboard path, the controlled geometry Behaviors and the shipped resize example. [Events](events.md#property-on-drag) defines the `:on-drag` property and its payload, [Hosts](hosts.md#property-drag-lock-modifier) the lock modifier, and [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md) the `etaf-draggable` and `etaf-resizable` Behaviors and their controlled variants.

## Gesture phases and the payload

<!-- index: gesture; drag phase; drag payload -->

A drag is a sequence of phases delivered to one handler. Ebox decides the owner when the primary button goes down — the nearest keymap owner under the pointer — and keeps that target for the whole gesture, so moving outside the Host does not hand the drag to whatever is under the pointer now. Each phase arrives as a plist carrying the phase symbol (`start`, `move`, `end`, `cancel` or `edge`), the raw event, the node, the window and buffer, the start and current positions in text-area pixels, the displacement from the start, the pointer's overshoot past the text area, a cancellation reason and the `:keyboard` flag for gestures synthesized from keys. An `edge` phase adds `:edges`, the window edges the pointer rests against or has passed, and `:elapsed`, the seconds since the previous `edge` phase. Each phase runs in its own reactive event batch and publishes before the next pointer event is read, so a handler that writes a reactive coordinate sees its own committed layout on the next phase instead of lagging one frame behind.

A gesture ends in one of two ways. A release lands `end`, wherever the pointer is; a gesture whose target becomes unavailable — removed, hidden or disabled — or that is aborted by Escape, another input or an error ends with `cancel` and a `:reason` of `target-unavailable`, `quit`, `input` or `error`. Escape is consumed as part of the cancellation; other input is left for Emacs. Handlers should treat `cancel` as "restore anything you changed optimistically", which is exactly what the shipped example does.

While the button is held the pointer may leave the text area, onto the mode line, another window or past the frame, and the gesture keeps tracking it. `:position` stays at the nearest point of the text area, so `:delta` never describes a place the window cannot show, and `:overshoot` gives the pointer's `(DX . DY)` distance past the text area in pixels: negative to the left and above, positive to the right and below, `(0 . 0)` inside. A release out there ends the gesture with `end` as usual.

The window system can lose a button release; on macOS this happens most often while a tooltip is being shown or hidden. Ebox therefore hides any shown or pending tooltip and suppresses help echo while it tracks a gesture, and it treats a new press of the primary button during an unlocked gesture as the missing release: the gesture ends with `end` at its last position, and the press is then handled as a fresh press. Read the pointer from `:position`, not from `:event`: a native drag or release event starts at the press, and the event of an `end` implied by a new press is that press.

## The drag lock

<!-- index: drag lock; click-then-drag -->

`:drag-lock-modifier` makes a gesture survive the button release. When the modifier is held as the drag starts, releasing the button does not end the gesture: it keeps tracking the pointer, now with no button held, until the next primary press finishes it or Escape cancels it. That turns a click-then-drag sequence into one gesture, which is how a resize handle stays attached to the pointer after a quick click. The modifier is declared on the Host alongside `:on-drag`, and a lock modifier without a drag handler is rejected when the Host commits. The shipped example uses `shift` so the behavior is visible and opt-in.

## Edge intent and scrolling

<!-- index: edge intent; auto-scroll; drag edge -->

Dragging past the visible edge of a sheet, list or canvas is how a person reaches content that is not on screen. The engine reports that intent; the application, which owns its viewport, decides what scrolls and how far.

A Host with `:drag-edge` non-nil receives an extra `edge` phase while a drag rests in or past an edge band of its window. The gesture must have moved from its press; a press that merely rests at the edge reports nothing. The first phase arrives after one `ebox-drag-edge-interval`, then repeats at that cadence while the pointer stays within `ebox-drag-edge-band` lines or columns of an inside edge or beyond that edge. `:edges` names the touched or passed edges in the fixed order `left`, `right`, `top`, `bottom`; a corner names both. Moving back into the interior or ending the gesture stops the phases. `:elapsed` is the wall time in seconds since the previous `edge` phase began, or since the pointer reached the band for the first one; it exceeds the interval when the handler and the publication after it take longer. Together with `:overshoot` it lets a handler scroll by distance and time: faster the further out the pointer is, at a speed that does not depend on how long a redraw takes.

The engine does not scroll. `:position` and `:delta` describe the pointer only, so a handler that scrolls an Ebox scroller with `ebox-node-set-scroll` or `etaf-scroll-by` keeps a content-anchored object under the pointer by adding the scrolled lines and columns to the delta it applies. A model-driven viewport, such as a grid that changes its first visible row, advances that state in the same handler.

```elisp
(box :drag-edge t
     :on-drag
     (lambda (gesture)
       (pcase (plist-get gesture :phase)
         ('edge
          (when (memq 'bottom (plist-get gesture :edges))
            ;; Scroll faster the further the pointer is past the edge, and by
            ;; elapsed time so the speed holds however long a redraw takes.
            ;; The move branch adds the scrolled rows to the delta so the
            ;; content stays under the pointer.
            (let* ((past (max 0 (cdr (plist-get gesture :overshoot))))
                   (rows-per-second (+ 8 (/ past 4.0)))
                   (rows (max 1 (round (* rows-per-second
                                          (plist-get gesture :elapsed))))))
              (etaf-scroll-by (etaf-current-runtime) 'list rows))))
         ((or 'move 'end) (move-content (plist-get gesture :delta))))))
```

#### Variable: ebox-drag-edge-band

Lines and columns from a window edge where a drag reports edge intent.

**Semantics.** The default is 1, so the last line and the last column of the display window report intent; each axis scales by the frame's character height and width. A larger value widens the band on both axes, and a pointer past the edge, outside the window, counts as in the band. The value is read when a gesture starts.

**See also.** `ebox-drag-edge-interval`, `:drag-edge`.

#### Variable: ebox-drag-edge-interval

Seconds between `edge` gestures while a drag rests in or past the edge band.

**Semantics.** The default is 0.12. The first `edge` phase arrives one interval after the pointer reaches the band, and later phases repeat at this cadence; `:elapsed` reports the spacing actually observed, which grows when a handler is slower than the interval. A handler maps the cadence to whatever scroll step its viewport uses. The value is read when a gesture starts.

**See also.** `ebox-drag-edge-band`, `:drag-edge`.

## Keyboard equivalents

<!-- index: keyboard drag; drag step -->

Every pointer gesture has a keyboard path, and the framework supplies it rather than asking each application to invent keys. The built-in Behaviors contribute their own arrow bindings, described in [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md): a draggable Host moves with `M-<arrow>` along its axis, and a resizable Host grows and shrinks with `M-S-<arrow>` according to its edges. A focused `separator` or `slider` with `:on-drag` steps with the plain arrow keys through `etaf-direction`, as [Keyboard](keyboard.md#direction) describes. For an application's own commands there is one entry point that speaks the same gesture language as the pointer.

#### Function: etaf-drag-step (runtime host-ref columns rows)

Drag HOST-REF in mounted RUNTIME by COLUMNS and ROWS from the keyboard and return HOST-REF.

**Arguments.** COLUMNS and ROWS are numbers; they may be fractional for sub-cell movement. RUNTIME must be mounted and HOST-REF must name a committed Host with a drag handler.

**Semantics.** The call dispatches exactly two gestures, a `start` at zero displacement and an immediate `end` at the displacement, so every handler that works with the pointer — including the draggable and resizable Behaviors and the controlled variants — works from the keyboard without special cases. The displacement is expressed in the pointer gesture's units: COLUMNS character widths and ROWS line heights in pixels, measured on the frame of the window showing the buffer. The gestures carry `:keyboard` t, which distinguishes them from pointer input; applications that care can also check `etaf-event-pointer-p` at the event level. Because only `start` and `end` are delivered, a handler sees one origin and one final position, and `on-start`/`on-end` callbacks that bracket a gesture run as usual.

**Returns.** HOST-REF.

**Errors.** `error→ etaf-event-error` with `"Drag step COLUMNS and ROWS must be numbers"` for a non-number argument, with `"No committed Host reference"` when HOST-REF is not mounted, and with the handler's own errors; `error→ etaf-render-side-effect-error` when called during rendering.

**Example.** `(etaf-drag-step runtime 'handle 1 0)`

**See also.** `:on-drag`, `etaf-draggable`, `etaf-resizable`, `etaf-direction`.

## Controlled geometry

<!-- index: controlled geometry; aggregate state; resize edges -->

The built-in Behaviors cover the common case where each coordinate is its own ref. Applications that keep geometry as one aggregate value — a plain alist in a manager's state, a record owned by a window controller — use the *controlled* variants instead. Their shape is the same: the Behavior consumes `:on-drag`, converts the pixel delta through an optional `:delta` function, and calls the application back with the next geometry; the application remains the only persistent authority, while the Behavior keeps at most a transient origin for the gesture's duration. On `cancel` nothing is written and the origin is dropped, so an aborted gesture cannot leave a half-updated record behind.

`etaf-draggable-controlled` reads a geometry plist, infers or takes an axis, and writes the moved coordinates back through `on-change`; `etaf-resizable-controlled` reads `:x`, `:y`, `:width` and `:height`, resizes along the declared `:edges`, clamps to the declared minimums and maximums, and shifts the origin when a left or top edge moves so the opposite edge stays fixed. [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md) defines their arguments, validation and error conditions, including the rule that move and resize handlers belong on separate Hosts because every `:on-drag` handler on a Host receives every gesture.

The keyboard bindings come with them: a controlled draggable contributes the move keys for its axis and a controlled resizable the grow and shrink keys for its edges, so the keyboard path is present whether the application stores four refs or one record.

## The retained resize example

<!-- index: retained resize; runnable example -->

The framework ships one application-shaped example so that the whole path — native gesture, controlled geometry, reactive publication and keyboard cancellation — can be exercised without building an application first. It is a plain mounted Runtime, not a special mode: the panel is an ordinary Host with an absolute position and a controlled resizable Behavior, and the peer beside it is an independent, focusable control.

#### Function: etaf-retained-resize-open (&optional buffer-or-name)

Mount a fixed-text resize example, returning BUFFER-OR-NAME (default `*ETAF Retained Resize*`).

**Arguments.** BUFFER-OR-NAME names the buffer to mount into; the default is `*ETAF Retained Resize*`.

**Semantics.** The buffer is mounted with a panel that reports its geometry through a controlled resizable Behavior: dragging resizes its right and bottom edges, Shift locks the gesture after the button release so a second press finishes it, and Escape cancels a locked gesture and restores the dimensions the panel had when the gesture started. The panel's body is fixed text clipped by its box, deliberately not a window frame or a paragraph reflow engine, and a peer control next to it stays independently focusable and activatable while the panel resizes. Reopening with the same buffer replaces the existing mount; the example refuses to take over a nonempty buffer it did not create. The example does not implement catalog window chrome or text reflow.

**Returns.** The buffer.

**Errors.** `error→ user-error` with the message `"Refusing to replace unrelated contents in %s"` when the buffer has contents the example did not mount; mounting errors propagate.

**Example.** `(etaf-retained-resize-open)`

**See also.** `etaf-resizable-controlled`, `etaf-drag-step`, [Focus](focus.md).

## Errors and recovery

<!-- index: gesture errors; cancellation -->

Gesture failures follow from the phase model. A handler that signals ends the gesture with a `cancel` whose reason is `error`, and the error propagates after that phase's batch drains; the remaining phases do not run. A target that disappears mid-gesture produces a terminal `cancel` with `target-unavailable`, which is the framework's way of telling the handler to release anything it acquired. Escape produces `cancel` with `quit`, for a locked or a plain gesture alike. The controlled Behaviors drop their origin on every `cancel`, so the safest handler pattern is the one the example uses: record the starting value on `start`, write the moved value on `move` and `end`, and restore the recording on `cancel`. `etaf-drag-step` validates its arguments up front and signals `etaf-event-error` rather than synthesizing a broken gesture.
