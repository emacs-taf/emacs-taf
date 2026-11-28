# Buttons and Choice Controls

The catalog's action and selection controls follow a controlled contract: the application owns the value and the component renders it and reports what the user did. Where a control declares `:bind`, a writable ref can replace its explicit value/change-callback pair; Range instead keeps separate change and commit callbacks and has no `:bind` prop. Buttons commit an action, checkbox and switch own a boolean, radio and segmented pick from a fixed list, and slider and range report a number that the caller stores. This chapter defines the seven controls, their keyboard behavior and their shared color tokens. [UI Overview](ui-overview.md) defines the controlled contract, [Events](events.md) how a press reaches a callback, [Focus](focus.md) and [Keyboard](keyboard.md) the Tab and arrow behavior the controls inherit, and [Component Styles and Themes](component-styles-and-themes.md) the token mechanism.

## The shared selection contract

<!-- index: controlled control; tonal pill; selection state; bind -->

Selection controls are *tonal pills* rather than boxed fields: a selected control paints the secondary button tint, an unselected one inherits its surface, and none carries an outline. Because the secondary tints are dialog tokens, a selected control stays crisp inside a modal above a dimmed shell. Geometry never changes with selection — state is paint, not layout — so switching a segment or checking a box never moves a neighbour.

Choice controls read input through the same contract. An explicit `:value` or `:checked` prop and an `:on-change` callback form the controlled pair; where supported, a writable ref passed as `:bind` replaces both, and its current value supplies the displayed state. A non-nil bind together with an explicit value or callback is rejected, and the conflict names the offending property. The ref belongs to the caller: a rejected publication keeps the previous binding target, and unmounting releases the control's handlers and subscriptions without touching the ref.

`DISABLED` removes the control's callback and its Tab stop while keeping its footprint, so toggling availability never shifts the layout. An additive `:on-press` observer may be supplied alongside the controlled interface; it observes activation without becoming the value path.

## The button

<!-- index: etaf-button; button variant; failed publication; ghost -->

#### Component: etaf-button (&key label on-press disabled id ref class color bgcolor border padding font-size font-weight tab-index aria-label aria-selected help-echo hover-content hover-group pointer use variant)

Render a standard pressable Button with a committed callback.

**Arguments.** LABEL names the button and is shown unless a default slot replaces it. ON-PRESS is the zero-argument callback. DISABLED removes the callback and the default Tab index. VARIANT is `primary` (accent fill, bold; the default), `secondary` (soft accent tint) or `ghost` (inherits its surface, narrower padding); by default every variant is a borderless single-row pill whose second class name carries the variant. The optional `:ui-button-padding`, `:ui-button-radius` and `:ui-button-border` Theme tokens change the shared geometry; explicit presentation props take precedence. The presentation props COLOR, BGCOLOR, BORDER, PADDING, FONT-SIZE and FONT-WEIGHT override the variant's defaults. ID reaches the rendered Host so anchor-based surfaces can reference the Button by identity; CLASS, REF, TAB-INDEX, ARIA-LABEL, ARIA-SELECTED, HELP-ECHO, HOVER-CONTENT, HOVER-GROUP, POINTER and USE are the ordinary Host capabilities.

**Semantics.** The Runtime publishes ON-PRESS together with the visible Button, so a render that fails to publish keeps the previous callback and the values it captured. A Button's label stays on one row even when padding makes the control taller: it never shrinks below its label or wraps the label's text, so a Flex line that runs out of room moves the whole Button instead of splitting its text.  An enabled, unselected Button paints its variant's hover fill while the pointer is over it, or a fill derived from its own `:bgcolor` when the caller supplied one; ARIA-SELECTED controls such as tabs and segments keep their selected presentation instead. A selected `ghost` uses the secondary Theme colors without changing its padding, font weight or size; selection should change ARIA-SELECTED, not switch between geometry-bearing variants.  Keyboard focus underlines the label and fills a Button that carries no surface of its own.  A default slot replaces the visible label with ordinary non-interactive content, such as a title and description; LABEL or ARIA-LABEL still names the single focus and activation target, and nested controls inside a button are inappropriate. The native root attributes `:pointer`, `:help-echo`, `:hover-style` and `:hover-content` request Ebox's text-property capabilities, and an explicit nil blocks an inherited capability.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when a name is neither a declared prop nor a supported Host attribute.

**Example.**

```elisp
(etaf-button :label "Save" :variant 'primary :on-press #'save-buffer)
```

**See also.** `etaf-checkbox`, `:ui-button-primary-bg`.

```elisp :figure The primary, secondary, ghost and disabled button variants
(etaf-view
 (column :item-gap '(lh 1)
   (row :item-gap '(ch 1)
     (etaf-button :label "主要" :on-press #'ignore)
     (etaf-button :label "次要" :variant 'secondary :on-press #'ignore)
     (etaf-button :label "幽灵" :variant 'ghost :on-press #'ignore)
     (etaf-button :label "禁用" :disabled t))))
```

## Checkbox and switch

<!-- index: etaf-checkbox; etaf-switch; checkbox mark; switch state -->

#### Component: etaf-checkbox (&key checked label on-change disabled bind)

Render a controlled Checkbox whose next value is sent to ON-CHANGE.

**Arguments.** CHECKED is the displayed boolean, a ref or a computed. ON-CHANGE receives the next boolean. LABEL is the visible caption and the accessible name. BIND is an existing writable ref that replaces CHECKED and ON-CHANGE.

**Semantics.** The control draws a bold `[x]` or `[ ]` mark followed by the label. No additional state is created: an external write to a bound ref updates the control, a disabled control cannot write, and an additive `:on-press` observer sees activation without affecting the value path. Failed publication retains the old binding target, and unmounting releases the control's handlers and subscriptions without owning the caller's ref.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when a non-nil BIND is combined with an explicit CHECKED or ON-CHANGE (including nil), naming the conflicting property, or when BIND is not a writable ref.

**Example.**

```elisp
(etaf-checkbox :label "Auto-save" :checked t)
```

**See also.** `etaf-switch`, `:ui-checkbox-enabled-fg`.

#### Component: etaf-switch (&key checked label on-change disabled bind)

Render a controlled binary switch with Checkbox's ownership contract.

**Arguments.** CHECKED must be a boolean, ref or computed; LABEL defaults to `"Switch"`; BIND follows `etaf-checkbox`.

**Semantics.** The switch is a single ghost button whose caption is `"[x] LABEL"` or `"[ ] LABEL"`, painted with the selection tint when on. Its accessible name is LABEL.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when CHECKED is not boolean-valued after resolution or LABEL is not a string.

**Example.** `(etaf-switch :checked nil :label "Aeroplane mode")`

## Radio and segmented

<!-- index: etaf-radio; etaf-segmented; option alist; tab list -->

#### Component: etaf-radio (&key value options label on-change disabled bind)

Render a controlled single-choice group from an options alist.

**Arguments.** OPTIONS is a nonempty alist of unique scalar values to unique nonempty string labels. VALUE is nil or one of the option values. LABEL names the group and defaults to `"Choice"`. ON-CHANGE receives the chosen value; BIND follows `etaf-checkbox`.

**Semantics.** The group is a labelled column whose options share one horizontal focus group, so the arrows move between choices. Each choice is a ghost button whose caption is prefixed `"(o) "` when selected and `"( ) "` when not, and the selected one paints the selection tint. The group's role is `radiogroup` and each choice carries its label as its accessible name.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` for an empty or malformed OPTIONS, for duplicate values or labels, for a VALUE outside OPTIONS, or for a non-string LABEL.

**Example.**

```elisp
(etaf-radio :value 'b :label "Mode"
            :options '((a . "Alpha") (b . "Beta")))
```

**See also.** `etaf-segmented`, `:ui-button-secondary-bg`.

#### Component: etaf-segmented (&key value options on-change disabled bind)

Render a compact mutually-exclusive selector from an options alist.

**Arguments.** OPTIONS, VALUE, ON-CHANGE and BIND follow `etaf-radio`; there is no caption label.

**Semantics.** The segments are ghost buttons in one horizontal focus group with a two-column gap and the `tablist` role. Selection changes only the secondary Theme paint through `:aria-selected`, never the variant, padding or font weight, so moving selection preserves every caption's position and width.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` for an empty or malformed OPTIONS, for duplicate values or labels, or for a VALUE outside OPTIONS.

**Example.**

```elisp
(etaf-segmented :value 'day
                :options '((day . "Day") (week . "Week") (month . "Month")))
```

## Slider

Use `etaf-number-input` for in-place integer entry with unit steppers and an optional empty value, `etaf-slider` for a required step-aligned integer with keyboard increments and a native number prompt, and `etaf-range` for pointer scrubbing with intermediate versus committed numeric values. They share caller-owned values but not the same editing or callback contract.

<!-- index: etaf-slider; integer slider; native prompt; step alignment -->

#### Component: etaf-slider (&key value min max step label on-change disabled bind)

Render a controlled numeric slider.

**Arguments.** VALUE must be an integer between MIN and MAX aligned to STEP. MIN and MAX are integers with `min <= max` (defaults 0 and 100); STEP is a positive integer (default 1). LABEL defaults to `"Value"`. ON-CHANGE receives the next integer; BIND follows `etaf-checkbox`.

**Semantics.** The slider is a labelled column: a strong caption and a muted current value, then a secondary button reading `"◀  N  ▶"`. With the button focused, Left and Right report VALUE moved by one STEP through the direction channel, clamped to MIN and the largest STEP-aligned value not greater than MAX; MAX need not itself align. For MIN 0, MAX 5 and STEP 2 the reachable values are 0, 2 and 4, so Right at 4 reports 4 rather than 5. Home and End are not bound; the native number prompt is reachable by activating the button, which opens `read-number` outside the layout, restores focus afterwards, and writes the result only after it passes the same integer, range and STEP-alignment checks. Cancelling the prompt leaves the value unchanged.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when MIN or MAX is not an integer, MAX is below MIN, STEP is not a positive integer, LABEL is not a string, or VALUE is not an aligned integer within the bounds. The native prompt reports a misaligned or out-of-range entry as a `user-error` and does not write it.

**Example.**

```elisp
(etaf-slider :value 4 :min 0 :max 5 :step 2 :label "Level")
```

## Range

<!-- index: etaf-range; retained fill; drag preview; commit callback; reactive bounds -->

#### Component: etaf-range (&key value min max step key-step on-change on-commit disabled color track-color bar-height label ref fill-ref)

Render a controlled interactive Range (progress, seek, volume) within MIN..MAX.

**Arguments.** VALUE is a number or reactive source within MIN..MAX, snapped to STEP when STEP is non-nil. MIN and MAX accept numbers or reactive sources. KEY-STEP is the arrow step and defaults to STEP, else a twentieth of the span. ON-CHANGE reports intermediate values and ON-COMMIT the released one. BAR-HEIGHT is the painted thickness as a percentage of one standard row (integer 1..100, default 40). On SVG-capable graphical frames it is centered and rounded to pixels with a one-pixel minimum; text-only frames keep a thin rule. Neither the row height nor the full-row hit target changes. COLOR and TRACK-COLOR override the fill and track tokens. LABEL is the accessible name. REF names the track Host and FILL-REF the fill Host.

**Semantics.** The bar is a track in normal flow carrying a one-row rule, with the accent fill painted above it as an absolutely positioned Host whose width is a percentage. Both parts clip the same centered graphic (or text fallback), so their thickness agrees as the fill moves. A pointer click reports the pointed value through ON-CHANGE and ON-COMMIT; dragging reports intermediate values through ON-CHANGE and the released value through ON-COMMIT. A press or drag re-proportions the two parts through retained Host geometry before the caller's value arrives, so the gesture follows the pointer while a backend reply is pending. With the range focused, Left and Right report the value moved by KEY-STEP and Home and End report MIN and MAX. A caller may move the fill in place with `etaf-runtime-update-host-geometries` and a `:width` percentage without republishing the View, which is how a playing position advances. Bounds that change through a reactive source are read at the retained fill, and a pending nil bound paints an empty span instead of failing.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when MIN or MAX is neither a number nor a reactive source, a static MAX is below MIN, STEP or KEY-STEP is not a positive number, BAR-HEIGHT is not an integer percentage from 1 through 100, ON-CHANGE or ON-COMMIT is neither a function nor nil, or DISABLED is not a boolean. A resolved reactive MAX below MIN signals when the retained fill reads it.

**Example.**

```elisp
(etaf-range :value 30 :min 0 :max 100 :on-change #'preview-volume
            :on-commit #'set-volume :label "Volume")
```

**See also.** `:ui-range-fill`, `:ui-range-track`, [Dragging and Gestures](dragging-and-gestures.md).

## Choice tokens

<!-- index: ui-button-primary-fg; ui-button-secondary-fg; ui-checkbox-enabled-fg; ui-range-fill -->

#### Token: :ui-button-padding

The default padding of a Button, using the `:padding` value syntax.

**Semantics.** Without this token, each variant keeps its existing padding. An explicit PADDING prop overrides it. For example, `((lh 1) (ch 2))` reserves one standard row above and below the label without changing font metrics.

#### Token: :ui-button-radius

The default Button corner radius, using the `:border-radius` value syntax and falling back to `(px 0)`.

**Semantics.** An explicit `:border-radius` Host attribute overrides it. Rounded outline support and padding requirements follow [Style Properties](style-properties.md#style-border-radius).

#### Token: :ui-button-border

The default Button border, using the `:border` value syntax and falling back to no border.

**Semantics.** An explicit non-nil BORDER prop overrides it. A complete outline can use `((px 1) solid "#8798ae")`; include its horizontal width in the control's layout budget.

#### Token: :ui-button-primary-fg

The foreground of a primary button.

**Semantics.** Painted on `:ui-button-primary-bg` for the filled accent button, which uses bold text.

#### Token: :ui-button-primary-bg

The fill of a primary button.

#### Token: :ui-button-primary-hover-bg

The hover fill of a primary button.

**Semantics.** While the pointer is over an enabled primary button, its fill changes to this color, so the button reacts to the pointer without moving or resizing.

#### Token: :ui-button-secondary-fg

The foreground of a secondary button and of a selected choice.

**Semantics.** Checkbox marks, radio and segmented selections, switch-on labels and picker rows paint this color on `:ui-button-secondary-bg`; because they are dialog tokens, a selected control stays crisp above a dimmed shell.

#### Token: :ui-button-secondary-bg

The tint of a secondary button and of a selected choice.

#### Token: :ui-button-secondary-hover-bg

The hover tint of a secondary button.

**Semantics.** While the pointer is over an enabled secondary button, its tint changes to this color; selected choices keep their selected color.

#### Token: :ui-button-ghost-fg

The foreground of a ghost button.

**Semantics.** A ghost button inherits its surface and paints only its text, which is why an unselected segment or a plain tag close control reads as content rather than as a box.

#### Token: :ui-button-ghost-hover-bg

The hover surface of a ghost button.

**Semantics.** While the pointer is over an enabled ghost button, it paints this surface; the button itself stays transparent so the surrounding panel shows through when the pointer leaves.

#### Token: :ui-checkbox-enabled-fg

The label color of an enabled checkbox.

#### Token: :ui-checkbox-disabled-fg

The label color of a disabled checkbox.

#### Token: :ui-range-fill

The accent fill of a range bar.

**Semantics.** Painted above the track for the filled part of the value; a caller may override it per instance with the range's `:color` prop.

#### Token: :ui-range-track

The unfilled track of a range bar.

**Semantics.** Drawn as the rule string the pointer hits, so its measured width is what maps a pointer position to a value; a caller may override it with `:track-color`.

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected input through `etaf-check-prop`, naming the component, the property, the received value and the expectation: a bind combined with an explicit value or callback, a malformed or duplicate option list, a value outside the options, a non-integer slider bound or a misaligned slider value, and the range's bound, step, thickness and callback contracts.
- A failed publication keeps the last committed state: a button keeps its previous callback and captured values, and a bound control keeps its previous binding target. The caller's business ref is never rolled back by the component.
- A disabled control is not inert markup: it removes its callback and Tab stop, so activation cannot reach it while its layout footprint stays.
- The slider's native prompt is the one place the control leaves the layout: a cancelled prompt changes nothing, and a misaligned entry is reported as a `user-error` without a write.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery).

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (row :item-gap '(ch 1)
     (etaf-button :label "Save" :on-press #'ignore)
     (etaf-button :label "Cancel" :variant 'ghost :on-press #'ignore))
   (etaf-segmented :value 'week
                   :options '((day . "Day") (week . "Week")))
   (etaf-checkbox :label "Auto-save" :checked t)))
```

## Toggle rows

A header line and a mode line hold text, not Components.  `etaf-toggle-strip` is the same choice control as text, so a title bar or a status row can offer a small mutually exclusive switch without a second layout.

#### Function: etaf-toggle-strip (&key options value on-change theme label surface)

Return a two-way or three-way choice as one row of boxes for a text row.

**Arguments.** OPTIONS is a nonempty alist of at least two unique scalar values with nonempty labels. VALUE is the selected key or nil. ON-CHANGE, when non-nil, receives the key of a clicked segment. THEME is the token plist that supplies `:ui-panel-fg`, `:ui-panel-border`, `:ui-accent` and `:ui-accent-fg`. LABEL, when non-nil, is painted before the row in `:ui-muted-fg`. SURFACE is the row's own background behind an unselected segment; nil uses the Theme's panel surface.

**Semantics.** A header line and a mode line cannot mount a Component, so this returns the same control as a propertized string. The segments form one run, every segment is the same number of columns wide, and each carries its own one-pixel box, so the shared edges separate the segments and the chosen one paints the accent behind its label. A click calls ON-CHANGE. The selected segment takes no pointer-hover face, so the two states never stack and its label stays readable. The result is plain text: it is not a focus target and not a Tab stop, and the caller installs it in `header-line-format` or `mode-line-format` itself.

**Returns.** A propertized string of `(length OPTIONS) × cells` columns.

**Errors.** `error→ etaf-component-call-error` for an empty or malformed OPTIONS, for duplicate values or labels, for a VALUE outside OPTIONS, for a THEME without `:ui-panel-border`, or for an ON-CHANGE that is not a function.

**Example.**

```elisp
(let ((theme (etaf-ui-theme-tokens '(:bg "#FAFAFA" :fg "#383A42"))))
  (setq-local header-line-format
              (etaf-toggle-strip :options '((light . "亮") (auto . "随") (dark . "暗"))
                                 :value 'auto :theme theme
                                 :on-change #'my-choose-mode)))
```
