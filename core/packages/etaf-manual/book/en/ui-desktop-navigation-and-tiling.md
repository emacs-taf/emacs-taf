# Desktop Navigation and Tiling

The desktop components are the shells a window manager is built from: a taskbar for open windows, a workspace bar for switching and managing virtual desktops, a modal launcher and switcher, and the splitter and pane resizer that lay panes out. They are presentational and deliberately keep every piece of selection, workspace, window and layout state in the caller; they expose ordinary callbacks and Behaviors, so a desktop policy can use the same controls in floating and tiled layouts without adding another input or focus system. [UI Overview](ui-overview.md) defines the controlled contract, [Panels and Windows](ui-panels-and-windows.md) the windows they manage, [Overlays](ui-overlays.md) the dialog the launcher opens, and [Component Styles and Themes](component-styles-and-themes.md) the shell tokens.

## Items, tone and the shell

<!-- index: desktop item; item state; item tone; shell tokens -->

Desktop items are item plists: a unique scalar `:key`, a nonempty `:label`, and optionally a `:description`, a `:state` of `active`, `minimized` or `error` (or a ref or computed of one), a `:disabled` flag, and a `:ref`. Captions never carry marker glyphs: state is communicated by the button's tone without changing padding or font weight, which keeps the text width stable as windows focus and minimize, and avoids a noisy taskbar.

The bars and their items paint from the shell token set — `:ui-shell-bg`, `:ui-shell-fg`, `:ui-shell-muted-fg`, `:ui-shell-item-fg` and `:ui-shell-item-minimized-fg` — while selection uses the accent tokens and picker rows the picker tokens. Because every key resolves through a deferred token, providing a Theme restyles the whole shell, its items, the pickers and the dividers together without re-rendering.

## The taskbar

<!-- index: etaf-taskbar; window buttons; launcher button -->

#### Component: etaf-taskbar (&key items active on-select on-launch launcher-label ref-prefix class)

Render a controlled taskbar for window items.

**Arguments.** ITEMS are item plists with scalar `:key` and nonempty string `:label`; an optional `:state` is `active`, `minimized`, `error` or nil (or a ref or computed of one), and `:disabled` suppresses activation. ACTIVE marks the focused item and may be a scalar key, nil, a ref or a computed. ON-SELECT receives a key; ON-LAUNCH, when supplied, opens the caller's launcher through a leading primary button labelled LAUNCHER-LABEL (default `"Applications"`).

**Semantics.** The bar is one row: a launcher button when there is a launch callback, then one button per item, each painted according to its tone — an active item with the accent-soft tint, a minimized one with the muted minimized token, an error one with the semantic error color. An empty taskbar shows a muted `"No windows"`. The caller owns all window state: selecting only reports a key.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` for duplicate keys, a bad state, a non-boolean `:disabled`, a bad active key, or a non-string launcher label or non-function callback.

**Example.**

```elisp
(etaf-taskbar :items '((:key editor :label "Editor" :state active)
                       (:key term :label "Terminal" :state minimized))
              :active 'editor :on-select #'focus-window :on-launch #'open-launcher)
```

**See also.** `etaf-workspace-bar`, `etaf-launcher`.

## The workspace bar

<!-- index: etaf-workspace-bar; workspace tabs; layout control; status -->

#### Component: etaf-workspace-bar (&key workspaces active on-select on-add on-close add-label brand status layout-label layout-action settings-label settings-action ref-prefix class)

Render controlled workspaces as an accessible workspace switcher bar.

**Arguments.** WORKSPACES holds scalar keys or item plists with `:key`, `:label`, optional `:description` and `:disabled`. ACTIVE is the selected key, a ref or a computed. STATUS is a string, nil, a ref or a computed. ON-SELECT receives a key; ON-ADD and ON-CLOSE are optional policy actions and ADD-LABEL (default `"New workspace"`) names the add control. BRAND is an optional leading caption. LAYOUT-LABEL and LAYOUT-ACTION render the trailing window-management control; LAYOUT-LABEL may be a string, ref or computed, and the control keeps a fixed width so a changed label publishes as a retained text update. SETTINGS-LABEL and SETTINGS-ACTION add one more trailing action.

**Semantics.** A single-row bar shows the brand, one tab per workspace with a close control, the add control, a status region that takes the remaining width and clips excess text, and the trailing layout and settings controls at the right edge. Status length changes therefore never move the trailing actions. The component creates, removes and persists nothing: the callbacks request those changes.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` for a malformed workspace list, a bad callback or label; a duplicate workspace key surfaces from the renderer as `etaf-renderer-error` naming the key.

**Example.**

```elisp
(etaf-workspace-bar :workspaces '((:key 1 :label "One") (:key 2 :label "Two"))
                    :active 1 :on-select #'switch-workspace :on-add #'add-workspace
                    :status "3 windows" :layout-label "Tiled" :layout-action #'toggle-layout)
```

## Launcher and switcher

<!-- index: etaf-launcher; etaf-switcher; application picker -->

#### Component: etaf-launcher (&key open title items on-select on-close close-label backdrop)

Render a controlled modal application launcher from item plists.

**Arguments.** OPEN is a value, ref or computed; the launcher renders nothing while it is nil. TITLE defaults to `"Applications"`. ITEMS use `:key`/`:label` with optional `:description`, `:state` and `:disabled`. ON-SELECT receives the selected key and ON-CLOSE is required; CLOSE-LABEL (default `"Close"`) names the dialog's footer button. BACKDROP defaults to t.

**Semantics.** The launcher is a modal dialog of `(ch 56)` whose body is the picker list; items show their caption with an optional muted description below it. The launcher owns no registry and no open state: the caller normally closes OPEN after handling a selection, and a BACKDROP nil paints no backdrop at all, leaving the desktop fully visible instead of dimmed.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ON-SELECT or ON-CLOSE is not a function, a label is not a string, or the item list is malformed.

**Example.**

```elisp
(etaf-launcher :open launcher :on-select #'launch-app
               :on-close (lambda () (setf launcher nil))
               :items '((:key editor :label "Editor" :description "Text editor")))
```

#### Component: etaf-switcher (&key open title items selected on-select on-close close-label backdrop)

Render a controlled modal application or window switcher.

**Arguments.** The props match `etaf-launcher`; TITLE defaults to `"Switch application"` and SELECTED marks the currently focused item.

**Semantics.** The presentation, sizing and backdrop follow the launcher, and SELECTED paints the focused row with the selection tint so a keyboard-driven switcher shows its current target. The caller owns the item list, the selection and the open state.

**Returns.** A View.

**Errors.** Those of `etaf-launcher`.

**Example.**

```elisp
(etaf-switcher :open switch :selected current :on-select #'switch-to
               :on-close (lambda () (setf switch nil))
               :items '((:key editor :label "Editor") (:key term :label "Terminal")))
```

## Splitter and pane resizer

<!-- index: etaf-splitter; divider overlay; etaf-pane-resizer; pane width -->

#### Component: etaf-splitter (&key orientation ratio min-ratio max-ratio on-change use class overlay z-index divider-content overlay-rect visible)

Render a controlled split layout with a keyboard-focusable divider.

**Arguments.** ORIENTATION is `horizontal` (left/right) or `vertical` (top/bottom). RATIO is the first pane's fraction and is caller-owned, bounded by MIN-RATIO (default 0.1) and MAX-RATIO (default 0.9). ON-CHANGE receives the raw divider gesture and USE may install an ETAF Behavior that turns that gesture into a new ratio. The `first` and `second` slots hold the panes. OVERLAY renders only the divider for a caller-owned positioned host; DIVIDER-CONTENT supplies that divider's rendered extent — a row of characters for a vertical divider, one character per row for a horizontal one — because a positioned box paints only the content it has. OVERLAY-RECT optionally supplies the exact `:left`/`:top`/`:width`/`:height` allocation; without it the divider follows RATIO relative to its positioned parent. OVERLAY-RECT entries, DIVIDER-CONTENT, Z-INDEX and VISIBLE may be refs or computed values, read only inside Host bindings, so a layout policy can move, hide or show a divider without re-rendering it.

**Semantics.** The splitter never stores a ratio or a window/layout policy: it renders the panes and reports divider gestures, and the focused divider steps like a one-cell drag with the arrows across it. A ratio-based policy captures the initial ratio and the allocated pixel extent on `start`, adds cumulative pixel delta divided by that extent on `move`/`end`, clamps to the chosen bounds and restores the initial ratio on `cancel`. Measure the current allocation, for example through `etaf-host-ref-size` on a referenced horizontal split with no extra insets, instead of assuming a fixed viewport width. MIN-RATIO and MAX-RATIO validate supplied ratios; they do not perform the callback's conversion. A caller that owns the allocation can run the divider in overlay mode and update its rectangle through refs as tiles move.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ORIENTATION is unknown, RATIO is outside the configured bounds, a callback is neither a function nor nil, or a visible flag is not a boolean.

**Example.**

```elisp
(etaf-splitter :orientation 'horizontal :ratio ratio :on-change #'split-gesture
               (slot :name 'first (text "Left"))
               (slot :name 'second (text "Right")))
```

**See also.** `etaf-pane-resizer`, [Dragging and Gestures](dragging-and-gestures.md).

#### Component: etaf-pane-resizer (&key size side min max on-change on-end line background ref)

Render a vertical divider that resizes an adjacent fixed-width pane.

**Arguments.** SIZE is the pane's current width in pixels — a number, ref or computed. SIDE `right` (default) places the divider on the pane's right so dragging right widens it; `left` serves a pane on the divider's right. Each drag move passes the candidate width, clamped to MIN and MAX pixels when given, to ON-CHANGE; ON-END receives the final width. LINE (default t) draws a hairline in the divider color beside the pane over BACKGROUND. REF reaches the rendered divider so callers can focus or address it.

**Semantics.** The divider is wide enough to grab, carries the `separator` role with a vertical orientation, and never moves other cells while dragging. With a callback it is a Tab stop whose Left and Right presses step the width one column. The width stays caller-owned: the component reports candidates and the application stores the pane width it accepts.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when SIDE is neither `left` nor `right`, a callback is neither a function nor nil, or MIN or MAX is neither a number nor nil.

**Example.**

```elisp
(etaf-pane-resizer :size width :side 'right :min 120 :max 400
                   :on-change #'preview-pane :on-end #'commit-pane)
```

## Desktop tokens

<!-- index: ui-shell-bg; ui-shell-item-fg; ui-picker-item-bg; ui-divider-bg -->

#### Token: :ui-shell-bg

The background of the desktop bars.

#### Token: :ui-shell-fg

The foreground of the desktop bars.

#### Token: :ui-shell-muted-fg

Muted text on the desktop bars, such as an empty taskbar's message and the status region.

#### Token: :ui-shell-item-fg

The caption color of an ordinary window or workspace item.

#### Token: :ui-shell-item-minimized-fg

The caption color of a minimized window item.

**Semantics.** The five shell keys paint the bars and their items; selection and emphasis use the accent tokens, so a desktop Theme can restyle the whole shell through this set without touching individual components.

#### Token: :ui-picker-item-bg

The background of a launcher or switcher row.

#### Token: :ui-picker-item-fg

The caption color of a picker row.

#### Token: :ui-picker-item-muted-fg

The description color of a picker row.

**Semantics.** The picker triple dresses launcher and switcher rows; a selected row uses the secondary button pair instead, which stays crisp above a dimmed shell.

#### Token: :ui-divider-bg

The divider color of a splitter or pane resizer.

**Semantics.** A splitter divider and a pane resizer's hairline paint with it, so every draggable boundary in a desktop reads as the same material.

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected prop through `etaf-check-prop`, naming the component, property, received value and expectation: duplicate keys, a bad state, a ratio outside its bounds, an unknown side or orientation, a bad pixel bound and non-function callbacks.
- A duplicate key can also surface from the renderer as `etaf-renderer-error "View has duplicate sibling key: …"` when the offending key reaches the keyed list, which names the exact key rather than the list.
- Gestures and selections are requests: a splitter or resizer callback that ignores a gesture leaves the caller's ratio or width untouched, and a launcher that ignores a selection keeps its open flag.
- The desktop components own no state at all, so a rejected input leaves every mounted bar, pane and dialog exactly as it was.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Panels and Windows](ui-panels-and-windows.md).

```elisp :run
(etaf-view
 (column :width '(ch 70) :height '(lh 22) :item-gap '(lh 1)
   (etaf-workspace-bar :workspaces '((:key 1 :label "One") (:key 2 :label "Two"))
                       :active 1 :on-select #'ignore :status "3 windows")
   (etaf-taskbar :items '((:key editor :label "Editor" :state active)
                          (:key term :label "Terminal" :state minimized))
                 :active 'editor :on-select #'ignore)))
```
