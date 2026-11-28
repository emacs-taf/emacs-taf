# Pickers and Menus

The catalog answers "choose one of these values" in two shapes: a *picker* that lives inside the layout and shows the current choice in place, and a *menu* that opens a temporary surface of actions. `etaf-select` is the picker: chips for short lists, an anchored dropdown for longer ones. `etaf-menu`, `etaf-dropdown-menu` and `etaf-context-menu` are the menus: one uses native completion, the other two open an in-buffer floating surface. All four are controlled — the caller owns the value, the items and the reaction — and all four report a chosen key through a callback. [UI Overview](ui-overview.md) defines the controlled contract, [Buttons and Choice Controls](ui-buttons-and-choice-controls.md) the buttons and selection tints they compose, [Overlays](ui-overlays.md) the floating surface they open, and [Text Input](text-input.md) the native input boundary that the completion menu crosses.

## The option contract

<!-- index: option alist; item plist; unique values; disabled item -->

The picker takes an *option alist*: each entry maps a value to its caption. Values must be unique scalars (symbols, numbers or strings), captions unique nonempty strings, and the current value is either nil or one of the values — a nil value absent from the list shows the placeholder, while any other absent value is an error, because the caller asked to display something the list cannot explain. The menus take an *item plist list* instead, because a menu item carries more than a caption: a unique non-nil `:key`, a unique nonempty `:label`, and an optional `:disabled` flag. The key is what a callback receives; the label is what the user reads.

A text menu trigger has a trailing disclosure arrow from the shared icon catalog. It indicates a menu, not a keyboard binding, and is not part of the accessible control name.

A disabled item stays visible and cannot be activated or reached by focus. A control whose menu has no enabled item left, or whose callback is missing, disables its own trigger instead of opening an empty surface: an empty list is a disabled control, not an error, because an application that has no actions right now still renders a coherent toolbar.

## The select component

<!-- index: etaf-select; chips; dropdown anchor; auto presentation -->

#### Component: etaf-select (&key value options label placeholder on-change disabled bind presentation hide-label width ref)

Choose a controlled value from OPTIONS without leaving the UI.

**Arguments.** VALUE is the current value, a ref or a computed. OPTIONS is the alist described above. LABEL defaults to `"Select"` and PLACEHOLDER to `"—"`. ON-CHANGE receives the accepted value; BIND is a writable ref replacing VALUE and ON-CHANGE, following `etaf-checkbox`. PRESENTATION is `chips`, `dropdown` or `auto` (default). HIDE-LABEL omits the caption for grid forms. WIDTH is the dropdown's popover width and defaults to `(ch 28)`. REF names the dropdown anchor, or the whole field when chips are shown.

**Semantics.** With chips, every option is an inline pill, the current one filled with the selection tint; with `dropdown`, one anchor pill shows the current caption followed by a disclosure arrow and opens a popover of ghost option buttons; `auto` shows chips for up to four options and a dropdown beyond that. Chips and dropdown options keep their padding and typeface when selected; selection changes Theme paint only and suppresses hover fill. Choosing a dropdown option closes the surface and calls ON-CHANGE once; Escape closes it without a choice. The dropdown's open state and its anchor belong to the retained instance, so the caller stores no open flag. Selection never opens the minibuffer.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when PRESENTATION is not one of the three, OPTIONS is not a proper list of unique scalar values with unique nonempty string labels, VALUE is neither nil nor a listed value, LABEL or PLACEHOLDER is not a string, or a callback is neither a function nor nil.

**Example.**

```elisp
(etaf-select :value 'medium :label "Size"
             :options '((small . "Small") (medium . "Medium") (large . "Large"))
             :on-change #'set-size)
```

**See also.** `etaf-menu`, `etaf-dropdown-menu`.

## The menu component

<!-- index: etaf-menu; native completion; action menu -->

#### Component: etaf-menu (&key label items on-select disabled)

Render a Button opening native completion for an action.

**Arguments.** LABEL defaults to `"Actions"` and names the trigger. ITEMS is the item plist list described above. ON-SELECT receives the chosen key.

**Semantics.** Activating the trigger runs Emacs' own completion over the enabled items' labels; the choice is validated against the list and its key is passed to ON-SELECT once, with focus restored by the native input boundary. Empty input or C-c C-k cancels without a callback. The control owns no application value and no extra open state: current props supply each published menu. The trigger is disabled when DISABLED is non-nil, when no item is enabled, or when ON-SELECT is missing. An additive `:on-press` observer may accompany the control, as for any input.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` for a malformed item (not a plist with `:key`, `:label` and optional `:disabled`), duplicate keys or labels, an empty label, a non-string LABEL, or a non-function ON-SELECT.

**Example.**

```elisp
(etaf-menu :label "Actions"
           :items '((:key save :label "Save") (:key quit :label "Quit"))
           :on-select #'run-action)
```

**See also.** `etaf-dropdown-menu`, `etaf-select`.

## The dropdown menu

<!-- index: etaf-dropdown-menu; icon trigger; anchored menu; menu item icon -->

#### Component: etaf-dropdown-menu (&key label items on-select disabled width icon placement)

Render a Button and an anchored Popover of menu items.

**Arguments.** LABEL defaults to `"Actions"`. WIDTH defaults to `(ch 28)`. ITEMS follows `etaf-menu` and may carry an `:icon` shown before the label. ICON non-nil makes the trigger that icon, with LABEL as its help text and accessible name. PLACEMENT defaults to `bottom-start` and follows [Overlays](ui-overlays.md).

**Semantics.** Pressing the trigger opens the popover; choosing an enabled item closes it and invokes ON-SELECT once with its key. An item with an icon is a full-width row whose pointer and keyboard behavior come from the same Host properties as a button, with a hover tint; an item without an icon is a ghost button. Open state and the unique anchor belong to the retained Component, so several dropdowns coexist without sharing a flag, and application data remains caller-owned. Keyboard navigation, focus return and dismissal follow the Popover contract.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` for the same item and callback contract as `etaf-menu`, or for a non-string LABEL.

**Example.**

```elisp
(etaf-dropdown-menu :label "Actions" :icon 'more-vertical
                    :items '((:key share :label "Share" :icon 'send)
                             (:key delete :label "Delete" :icon 'close))
                    :on-select #'run-action)
```

**See also.** `etaf-popover`, `etaf-context-menu`.

## The context menu

<!-- index: etaf-context-menu; compact trigger -->

#### Component: etaf-context-menu (&key label items on-select disabled width)

Compose a keyboard and mouse accessible context action trigger from the DropdownMenu contract.

**Arguments.** LABEL defaults to `"More"`; WIDTH defaults to `(ch 30)`; ITEMS, ON-SELECT and DISABLED are those of `etaf-dropdown-menu`.

**Semantics.** The component is a thin specialization: the trigger is an ordinary Ebox Button with the same keyboard, mouse and focus behavior as a dropdown trigger, and the menu is the same anchored popover. Applications place it beside whatever target the actions belong to — a row, a card or a pane — and the caller still owns the actions.

**Returns.** A View.

**Errors.** Those of `etaf-dropdown-menu`.

**Example.**

```elisp
(etaf-context-menu :items '((:key rename :label "Rename")
                            (:key delete :label "Delete"))
                   :on-select #'run-action)
```

**See also.** `etaf-dropdown-menu`.

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected prop through `etaf-check-prop`, naming the component, property, received value and expectation: a malformed option list or item list, duplicate values or keys, a value outside the options, and non-string labels or placeholders.
- Choosing always closes before reporting: a dropdown that has been chosen from is closed when ON-SELECT runs, so a callback that re-renders the surrounding view does not reopen it accidentally.
- Cancelling is not an error: closing a menu without a choice, an empty completion entry or C-c C-k simply reports nothing, and a disabled trigger cannot be activated at all.
- The picker and the menus own only presentation state; a rejected or cancelled interaction leaves the caller's value untouched.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Overlays](ui-overlays.md).

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-select :value 'medium :label "Size"
                :options '((small . "Small") (medium . "Medium") (large . "Large"))
                :on-change #'ignore)
   (etaf-dropdown-menu :label "Actions"
                       :items '((:key save :label "Save") (:key quit :label "Quit"))
                       :on-select #'ignore)))
```
