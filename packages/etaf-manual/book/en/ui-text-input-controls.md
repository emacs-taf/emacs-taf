# Text Input Controls

The catalog edits text in place: a field is ordinary rendered content until the user activates it, and activation opens a native Emacs editing session on the field's value, so typing, input methods, point, selection, undo and the kill ring behave exactly as in an ordinary buffer while the field keeps its frame, padding and wrapping. No frame, window or per-field surface is created. This chapter defines the text field, the search pill and the number stepper, and the session functions that open and close an edit. [Text Input](text-input.md) defines the native session mechanism these components drive, [UI Overview](ui-overview.md) the controlled contract, and [Component Styles and Themes](component-styles-and-themes.md) the tokens.

## In-place native editing

<!-- index: edit session; activation; controlled text; submission -->

Before activation a field is static text, placeholder and frame; the value is painted by the ordinary rendering path. Activation begins a session on that value: the session owns the caret, the selection and the undo history for its duration, and every change is reported to the application through `:on-change` with the complete text. The field itself stays in the layout — its padding, border and wrapping do not move — and no minibuffer, child frame or separate window is involved.

The value remains caller-owned. `:value` plus `:on-change` forms the controlled pair, or a writable ref passed as `:bind` replaces both; the application decides what a submitted text means. Leaving the session has three distinct meanings: submitting keeps the session text as the value and reports it to `:on-submit`; leaving (`blur`) keeps the text as the value without calling either submission callback; cancelling restores the value captured at activation through the change callback and reports the abandoned text to `:on-cancel`. Only one field edits at a time across the process; beginning another field first leaves the previous one keeping its text.

A few keys leave the field while editing, so the keyboard remains usable in a full application: TAB and backtab leave and move application focus, Escape leaves keeping the text and the Host focus, and the arrows move the caret and, at the text boundary, leave toward that direction. Return submits when the field is single-row and inserts a newline when it is multi-row, unless `:submit-on-return` says otherwise; Shift+Return and C-j always insert a newline, C-c C-c and Ctrl+Return submit, and C-c C-k cancels. The `:keymap` prop adds field-local bindings that run in the application buffer, and a keymap that tries to rebind the framework-reserved keys is rejected rather than silently ignored.

## The text input

<!-- index: etaf-text-input; outlined field; text area; placeholder -->

#### Component: etaf-text-input (&key value bind on-change label placeholder rows width variant disabled read-only submit-on-return on-submit on-cancel on-focus completion-functions keymap hide-label ref)

Edit text directly in the application's layout.

**Arguments.** VALUE is the controlled string, or BIND a writable ref replacing VALUE and ON-CHANGE. LABEL is the caption and accessible name and defaults to `"Text"`; HIDE-LABEL omits the caption for grid forms. PLACEHOLDER (default `""`) shows while the value is empty and never becomes its content. ROWS (default 1) sets the minimum visible lines, so one Component covers single-line inputs and text areas; the field grows with longer values. WIDTH is an Ebox length and defaults to `stretch`. VARIANT is `outlined` (default) or `plain`. DISABLED and READ-ONLY remove editing; READ-ONLY stays focusable. SUBMIT-ON-RETURN overrides the one-row default. ON-SUBMIT and ON-CANCEL receive the session text; ON-FOCUS runs once when a session begins. COMPLETION-FUNCTIONS configures CAPF for the session and KEYMAP adds field-local bindings. REF names the field Host.

**Semantics.** `outlined` draws a panel with a hairline border that turns to the accent color while editing, without moving any cell; `plain` draws only the text, for a composer inside an already styled surface. While the value is empty, the placeholder is painted after the caret, so typing replaces it. Activation begins a session through `etaf-text-input-begin`; a press or click on the field starts it, and a press outside leaves it keeping its text. Native editing acts on the value alone: no minibuffer is opened and other publications continue while editing. Return submits for a single-row field, and a multi-row field inserts a newline instead.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ROWS is not a positive integer, LABEL or PLACEHOLDER is not a string, VARIANT is neither `outlined` nor `plain`, WIDTH is not an Ebox length, a callback is neither a function nor nil, COMPLETION-FUNCTIONS is not a list of functions, the resolved value is neither a string nor nil, or KEYMAP is not a keymap or binds a framework-reserved key (the message names the key).

**Example.**

```elisp
(etaf-text-input :value "" :label "Name" :placeholder "Ada Lovelace"
                 :on-submit (lambda (text) (setq name text)))
```

**See also.** `etaf-text-input-begin`, `etaf-search-field`, [Text Input](text-input.md).

## Session functions

<!-- index: etaf-text-input-begin; etaf-text-input-end; submission semantics -->

#### Function: etaf-text-input-begin (runtime ref)

Begin native editing of the mounted text input REF in RUNTIME and return it, or nil when REF is unknown, disabled, read-only or already editing.

**Semantics.** Activation normally calls this from the field's own event callback; call it directly to focus a composer or open a grid cell for editing. Beginning another field first leaves the previous one, keeping its text. Other publications continue while editing.

**Returns.** The text input, or nil.

**Example.** `(etaf-text-input-begin runtime 'composer)`

**See also.** `etaf-text-input-end`, `etaf-text-input-active-p`.

#### Function: etaf-text-input-end (&optional how)

Finish the active text input and return its user text, or nil when none is active.

**Arguments.** HOW nil submits: the text stays the value and `:on-submit` receives it. HOW `blur` leaves the field keeping its text, without callbacks. Any other HOW cancels: the value captured at activation is restored through the change callback and `:on-cancel` receives the abandoned text.

**Semantics.** The session is released even when a callback signals; the signal then propagates. A dead buffer or failing callback still releases the session, so a field can never be left editing because its teardown failed.

**Returns.** The session text, or nil.

**Example.** `(etaf-text-input-end 'blur)`

#### Function: etaf-text-input-active-p (&optional runtime)

Return the text input currently editing in RUNTIME, or nil. RUNTIME defaults to the active field's Runtime, so the query works from any buffer.

**Returns.** The active text input, or nil.

**See also.** `etaf-text-input-begin`.

## The search field

<!-- index: etaf-search-field; search pill; clear button; live query -->

#### Component: etaf-search-field (&key value bind on-change placeholder width icon on-focus on-submit on-cancel on-clear keymap ref)

Render a rounded pill search field editing a controlled query through `etaf-text-input`, so ON-CHANGE sees every keystroke.

**Arguments.** VALUE/ON-CHANGE or a writable BIND supplies the query. PLACEHOLDER defaults to `"Search"`. WIDTH defaults to `stretch`. ICON non-nil adds a magnifier before the text. ON-CLEAR is called when the clear control is used. ON-FOCUS, ON-SUBMIT, ON-CANCEL and KEYMAP follow `etaf-text-input`. REF names the input for `etaf-text-input-begin`.

**Semantics.** The pill is three rows tall and its painted surface leaves half a row above and below the text. A clear control follows a nonempty query: it leaves the session, empties the query, calls ON-CLEAR and resumes editing. A press anywhere on the pill begins editing. The pill paints with the `:ui-search-bg` and `:ui-search-fg` tokens and the magnifier is muted.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when PLACEHOLDER is not a string or ON-CLEAR is neither a function nor nil; the inner text input's own contract applies to the rest.

**Example.**

```elisp
(etaf-search-field :value "" :icon t :on-clear #'reset-search)
```

**See also.** `etaf-text-input`, `:ui-search-bg`.

## The number input

<!-- index: etaf-number-input; stepper; draft value; bounded integer -->

#### Component: etaf-number-input (&key value label on-change disabled min max bind hide-label ref)

Render a controlled stepper NumberInput: a muted LABEL, a − stepper, the value pill and a + stepper.

**Arguments.** VALUE is an integer or nil. LABEL is a string or nil and defaults to `"Value"`. MIN and MAX are numbers or nil with `min <= max`. BIND replaces VALUE and ON-CHANGE. HIDE-LABEL omits the caption. REF names the text field.

**Semantics.** The steppers change the value by one and disable at the bounds; the value itself is edited in place by the text field, so typing accepts only a complete in-range integer, and an empty field means no value. Intermediate text stays a draft: clearing the text does not clear the value, an out-of-range entry is not written, and submitting an invalid entry reports a readable error without changing the value. Submitting the empty field reports nil.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when LABEL is neither a string nor nil, MIN or MAX is neither a number nor nil, MIN exceeds MAX, a non-nil BIND is combined with an explicit VALUE or ON-CHANGE, or the resolved value is neither an integer nor nil. Submitting a text that is not an in-range integer signals `user-error` naming the label and the bounds.

**Example.**

```elisp
(etaf-number-input :value 3 :min 0 :max 10 :label "Count")
```

**See also.** `etaf-text-input`, `etaf-slider`.

## Outlined field tokens

These tokens apply only to the outlined variant of `etaf-text-input`. A reactive Theme updates the retained field without ending native editing; focus changes the reserved frame's color, not its size. The plain variant keeps zero padding and no background or border of its own.

#### Token: :ui-input-padding

The outlined field's padding, using the `:padding` value syntax and falling back to `((lh 0) (ch 1))`.

**Semantics.** For example, `((lh 1) (ch 2))` surrounds the value with standard-row padding while preserving the text's font metrics.

#### Token: :ui-input-radius

The outlined field's corner radius, using the `:border-radius` value syntax and falling back to `(px 0)`.

**Semantics.** Rounded frame support and padding requirements follow [Style Properties](style-properties.md#style-border-radius).

#### Token: :ui-input-bg

The outlined field's background color.

**Semantics.** If omitted, the field reads the current Theme's `:ui-panel-bg`, including its built-in fallback; supplying only a dark panel palette therefore keeps fields dark.

#### Token: :ui-input-border

The outlined field's idle one-pixel border color.

**Semantics.** Use a hexadecimal color string. If omitted, the field reads `:ui-panel-border` from the current Theme. While editing it reads `:ui-accent` instead, keeping the one-pixel frame reserved in both states.

## Search tokens

<!-- index: ui-search-bg; ui-search-fg; search pill paint -->

#### Token: :ui-search-bg

The fill of a search field's pill.

**Semantics.** A search field that reads the token supplies a built-in fallback, so the pill paints without a provided Theme; `etaf-text-input` never reads it, because a field inside a caller's surface keeps that surface.

#### Token: :ui-search-fg

The text foreground inside a search field.

**Semantics.** Painted by the pill's flex frame, so both the placeholder and the edited text inherit it; the magnifier and clear control use `:ui-muted-fg` instead.

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected prop through `etaf-check-prop`, naming the component, property, received value and expectation, including a keymap that binds a framework-reserved key.
- The number input distinguishes a draft from an error: text that is not yet a complete integer is simply not written, while submitting an invalid value signals `user-error` and leaves the value untouched.
- A failing submission or cancel callback still releases the session, so the field cannot be stuck editing; the callback's error then propagates to the caller.
- Unmounting a field with an open session leaves it (`blur`), keeping the user's text as the draft rather than submitting it.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Text Input](text-input.md).

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-text-input :value "" :label "Name" :placeholder "Ada Lovelace")
   (etaf-search-field :value "query" :icon t)
   (etaf-number-input :value 3 :min 0 :max 10 :label "Count")))
```
