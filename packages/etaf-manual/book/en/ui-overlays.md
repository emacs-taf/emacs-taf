# Overlays

An overlay is a floating surface painted on the root layer above the application: a contextual panel, a modal dialog, a tooltip, a notification or a side drawer. The catalog's overlays are controlled — the caller owns the open flag and the reaction to a dismissal request — and they share one card anatomy, one focus policy and one dismissal rule. Ebox owns placement, occlusion and the anchor contract; the components own the panel's presentation and the keyboard scope. [Positioning, Layers and Overlays](positioning-layers-and-overlays.md) defines anchoring, root-layer coordinates and the canvas reservation an overlay needs, [Focus](focus.md) the modal scope, [UI Overview](ui-overview.md) the controlled contract, and [Component Styles and Themes](component-styles-and-themes.md) the panel tokens.

## The floating surface

<!-- index: floating surface; card anatomy; open flag; modal scope; backdrop -->

Every overlay renders nothing while its `:open` is nil, and one shared card while it is true: a one-row header carrying the title under a hairline, a body column padded by one row and two columns, and an optional footer row aligned to the right. A modal surface adds a small `x` in the header — pointer-only, so keyboard focus still lands on the first body control — and a footer confirmation button where the component defines one. Header and panel paint with the panel token triple, so a Theme restyles every surface at once.

The panel is one root-layer Host with the `dialog` role when modal and `group` otherwise, a negative Tab index, and the component's `:on-close` installed as its dismissal handler. Placement is delegated: a surface with an anchor follows the Ebox anchor/placement contract, a side drawer fills one edge at full height, and a centered dialog sizes itself within the visible window and bounds its height so a short window clips its own body rather than the application. A modal surface paints a full-screen backdrop that dims the application underneath instead of covering it: covered text and images stay visible while covered controls lose their pointer and focus targets. With the backdrop omitted the panel is still modal in the keyboard sense and the application's surface keeps its full paint.

Focus follows the same rules for every overlay. Opening focuses the first eligible control inside the panel (or the panel itself when it has none); while it is open the panel is a modal key scope, so Tab, arrows and Escape stay within the surface and dismissal returns focus to the control that opened it. Nesting works: each surface records the focus route it was opened from, and a closing inner surface hands focus back along that chain, skipping targets that no longer exist.

## The popover component

<!-- index: etaf-popover; anchored panel; controlled open -->

#### Component: etaf-popover (&key open anchor placement width title on-close)

Show controlled OPEN content on Ebox's root layer, anchored to a unique semantic ID.

**Arguments.** OPEN is a value, ref or computed. ANCHOR is a nonempty symbol or string naming the Host the panel attaches to. PLACEMENT defaults to `bottom-start` and follows the anchor contract of [Positioning, Layers and Overlays](positioning-layers-and-overlays.md). WIDTH defaults to `(ch 32)`. TITLE is an optional string. ON-CLOSE is required and receives no arguments. The default and `footer` slots hold the caller's content.

**Semantics.** The popover is the general anchored surface; menus, tooltips and toasts are built on it. While open, the panel is a modal key scope closed by Escape, and the panel's own dismissal requests ON-CLOSE without changing the caller's state. The application root must reserve a canvas height for floating content — without it the panel has nowhere to paint — and the caller owns the open flag, so two popovers can be open independently.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ON-CLOSE is not a function, ANCHOR is not a nonempty semantic ID, or TITLE is neither a string nor nil.

**Example.**

```elisp
(etaf-popover :open open :anchor 'status-chip :title "Details"
              :on-close (lambda () (setf open nil))
              (text "All checks passed."))
```

**See also.** `etaf-dialog`, `etaf-tooltip`.

## The dialog component

<!-- index: etaf-dialog; modal panel; backdrop; fixed height -->

#### Component: etaf-dialog (&key open title width height compact close-label on-close backdrop keys on-direction)

Show a controlled modal panel using the same floating surface as Popover.

**Arguments.** OPEN is a value, ref or computed. TITLE defaults to `"Dialog"`. WIDTH defaults to `(ch 48)`. HEIGHT is nil or `(lh N)` with positive N, bounding the panel to text rows within the visible window. COMPACT removes the body's vertical air so short forms stay dense. CLOSE-LABEL defaults to `"Close"`; nil omits the default footer button so the footer slot orders every action. BACKDROP defaults to t. ON-CLOSE is required. KEYS and ON-DIRECTION declare the panel Host's scoped `:keys` and `:on-direction`, never those of its backdrop.

**Semantics.** The dialog centers itself in the window that displays its buffer when that window is graphical, and it never moves the application's geometry or global focus policy. The header shows TITLE and a pointer-only `x` that requests ON-CLOSE, and Escape does the same, so a modal always has a keyboard exit. With BACKDROP (the default) the backdrop dims the root canvas while keeping the covered application, text and images included, visible; covered controls and their focus targets stay blocked. A pointer press on the backdrop requests ON-CLOSE without clicking through to the background; a press inside the panel does not dismiss it. Nested modal backdrops dismiss their own topmost surface, not the covered parent. With BACKDROP nil no backdrop is painted at all and the caller owns any outside-click policy. A fixed HEIGHT needs the body rows plus five for the header, body air and footer; a too-short window clips the dialog body instead of overflowing the frame. Dialogs own no form data.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ON-CLOSE is not a function, TITLE is not a string, HEIGHT is neither nil nor `(lh POSITIVE-INTEGER)`, COMPACT is not a boolean, or CLOSE-LABEL is neither a string nor nil.

**Example.**

```elisp
(etaf-dialog :open ask :title "Confirm" :width '(ch 40)
             :on-close (lambda () (setf ask nil))
             (text "Proceed?")
             (slot :name 'footer
               (etaf-button :label "Delete" :variant 'primary :on-press #'delete)))
```

**See also.** `etaf-popover`, `etaf-confirm-dialog`.

## Keyboard help

<!-- index: etaf-key-help; read-only help; help search -->

#### Component: etaf-key-help (&key data on-close)

Present an effective keyboard snapshot in a searchable, read-only modal.

**Arguments.** DATA is a snapshot from `etaf-help-data`. ON-CLOSE is a zero-argument callback.

**Semantics.** Group descriptions by their source, with application and region keys beside common navigation in wide windows and a scrolling single column in compact ones. The panel follows its inherited Theme and dims the background. `/` starts native search; matching is literal and case-insensitive over keys, labels, sources and notes. Arrow keys scroll and C-v/M-v or Page Down/Page Up page the list when not editing. Entries never execute business commands. Escape exits a search edit before closing help; clicking the backdrop closes it without activating covered controls. Dismissal restores the surviving opener. The minimum usable viewport is 48 character widths by 18 rows; smaller viewports deliberately clip rather than shrink the font.

**Semantics.** Loading etaf-ui installs this renderer for `etaf-help` unless `etaf-help-view-function` is already non-nil. Ordinary applications call `etaf-help` and own no separate open state, buffer or Runtime. Direct composition is for callers that already own a controlled dialog lifecycle; they capture DATA before opening and reserve the root canvas like other overlays.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when DATA is not a list with a string `:title` or ON-CLOSE is not a function.

**Example.** `(etaf-key-help :data snapshot :on-close close)`

**See also.** `etaf-help`, `etaf-help-data`, `etaf-dialog`, `etaf-kbd`.

## Tooltips and toasts

<!-- index: etaf-tooltip; etaf-toast; transient notice -->

#### Component: etaf-tooltip (&key open anchor text placement on-close)

Show controlled short text near an anchor using Popover placement. The caller controls visibility; no second hover event system is introduced.

**Arguments.** OPEN is a value, ref or computed. ANCHOR is the semantic ID. TEXT is a string or reactive string. PLACEMENT defaults to `top-start`. ON-CLOSE is required.

**Semantics.** The tooltip is a small anchored popover carrying one label, so its dismissal, focus scope and layer behavior are exactly those of `etaf-popover`. Because visibility is controlled, an application decides when a hint is appropriate — a button's event callback, not an implicit hover timer, is the usual trigger.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when TEXT does not resolve to a string or ON-CLOSE is not a function.

**Example.** `(etaf-tooltip :open hint :anchor 'copy-button :text "Copy" :on-close #'hide-hint)`

#### Component: etaf-toast (&key open anchor message title variant on-close)

Show a controlled dismissible anchored notification. The caller owns its lifecycle and message state.

**Arguments.** MESSAGE is a string or reactive string. TITLE defaults to `"Notification"`. VARIANT selects the semantic status color and defaults to `info`. ANCHOR and ON-CLOSE follow `etaf-popover`; the width is `(ch 42)` and the placement `top-end`.

**Semantics.** The body shows a status badge carrying the capitalized variant name above the message, so a success, warning, danger or info notice reads with the same status colors as the rest of the catalog. The toast never expires by itself: the application decides when to clear OPEN and remove it.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when MESSAGE does not resolve to a string, TITLE is not a string, or ON-CLOSE is not a function.

**Example.**

```elisp
(etaf-toast :open notice :anchor 'status-chip :message "Saved" :variant 'success
            :on-close (lambda () (setf notice nil)))
```

## The drawer component

<!-- index: etaf-drawer; side panel; modal side surface -->

#### Component: etaf-drawer (&key open title placement width modal on-close)

Show a controlled left or right side surface with default and footer slots.

**Arguments.** OPEN is a value, ref or computed. PLACEMENT is `left` or `right` (default `right`). WIDTH defaults to `(ch 42)` and is constrained to the root canvas. MODAL defaults to t. TITLE defaults to `"Drawer"`. ON-CLOSE is required.

**Semantics.** The drawer fills one edge of the canvas at full height, taking its width from the prop and leaving the rest of the application visible. Its focus, dismissal, return and disposal follow the Dialog contract: modal mode adds the backdrop and traps the keyboard scope, non-modal mode leaves the surrounding surface interactive while Escape still requests ON-CLOSE. Form data and the drawer's content remain caller-owned.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when PLACEMENT is neither `left` nor `right`, MODAL is not a boolean, TITLE is neither a string nor nil, or ON-CLOSE is not a function.

**Example.**

```elisp
(etaf-drawer :open filters :title "Filters" :placement 'right
             :on-close (lambda () (setf filters nil))
             (etaf-checkbox :label "Only stale"))
```

## Confirmations and outside clicks

<!-- index: etaf-confirm-dialog; etaf-ui-dismiss-outside-press; outside policy -->

#### Function: etaf-confirm-dialog (prompt)

Ask a nonempty string PROMPT with the native yes/no minibuffer from a Host callback. Return non-nil on confirmation and nil on no; change application state only after confirmation.

**Semantics.** Emacs owns the yes/no prompt and Ebox restores focus to the valid entry afterwards; C-g aborts the callback, as does an entry that is no longer valid. No surface content is edited. Compose it in a Menu's ON-SELECT or a Button's ON-PRESS.

**Returns.** Non-nil when confirmed, nil otherwise.

**Errors.** `error→ etaf-event-error` outside a Host event callback; `error→ etaf-view-error` when PROMPT is not a nonempty string.

**Example.** `(etaf-confirm-dialog "Delete this file?")`

**See also.** `etaf-dialog`.

#### Function: etaf-ui-dismiss-outside-press ()

Dismiss every mounted floating surface in the current event's Runtime whose panel does not contain the pressed Host, requesting each one's ON-CLOSE, and return the number dismissed.

**Semantics.** Call it from the `:on-press` or `:on-press-capture` callback of a Host enclosing the application, such as a shell root, to give unpainted (`:backdrop` nil) modals and popovers click-outside dismissal. Each dialog, launcher, switcher, popover, menu or drawer mounted in the Runtime whose panel does not contain the pressed Host receives a dismissal request; a surface opened by the press being handled is not mounted yet and stays open. The function requests closes through the normal event path, so a surface whose owner ignores the request simply stays open.

**Returns.** The number of surfaces dismissed.

**Errors.** `error→ etaf-event-error` outside a Host event callback.

**Example.**

```elisp
(box :ref 'shell :on-press-capture #'etaf-ui-dismiss-outside-press
  (etaf-popover :open open :anchor 'status-chip
                :on-close (lambda () (setf open nil))
                (text "Details")))
```

**See also.** `etaf-popover`, `etaf-drawer`.

#### Component: etaf-drop-zone (&key side label ratio cols rows accent width ref)

Render LINES as a pane whose drop preview sits on SIDE.

**Parameters.** SIDE is nil, `top`, `bottom`, `left`, `right` or `center`, and nil paints the lines plainly; LABEL names the preview on its dashed rule; RATIO defaults to 0.5 and is the share of the pane the preview takes; COLS and ROWS are the pane's size in cells; ACCENT overrides the preview ink; WIDTH and REF are the usual layout and addressing parameters.

**Returns.** An ETAF Component.

**Semantics.** The preview takes RATIO of the pane and keeps the pane's own text inside it, so a reader sees both where the pane will land and what it will cover. The tint is ACCENT mixed into the pane surface, which is how a text frame shows translucency.

**See also.** `etaf-drawer`, [Dragging and gestures](dragging-and-gestures.md).

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected prop through `etaf-check-prop`, naming the component, property, received value and expectation: a missing or non-function ON-CLOSE, a bad anchor, a malformed fixed height, a non-boolean flag or a non-string title.
- Dismissal is a request, never a state change: Escape, the header `x` and an outside press all run ON-CLOSE, and the application decides whether the surface closes. A callback that ignores the request leaves the surface open.
- A closing dialog or drawer restores focus to the control that opened it, or to the nearest still-valid target along the nesting chain; an unmounted return target is skipped rather than signaling.
- A rejected or cancelled confirmation changes nothing: `etaf-confirm-dialog` returns nil on no and aborts the callback on C-g, so the caller's state stays as it was.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Focus](focus.md).

```elisp :run
(etaf-view
 (column :width '(ch 60) :height '(lh 18)
   (box :id 'status-chip (text "Status: ready"))
   (etaf-popover :open t :anchor 'status-chip :title "Details" :on-close #'ignore
                 (column (text "All checks passed.")))))
```
