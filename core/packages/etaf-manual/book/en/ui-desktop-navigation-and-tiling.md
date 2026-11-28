# Desktop Navigation and Tiling

`etaf-ui` provides `etaf-pane-resizer` for resizing adjacent fixed-width panes alongside shared shell, picker and divider theme tokens. Application-specific desktop shells (taskbar, workspace bar, launcher, switcher and tiling splitter) live in the etaf-desktop application package rather than the general catalog. [UI Overview](ui-overview.md) defines the controlled contract, [Panels and Windows](ui-panels-and-windows.md) defines window chrome, and [Component Styles and Themes](component-styles-and-themes.md) defines how deferred tokens resolve through a Theme.

## Pane resizer

<!-- index: etaf-pane-resizer; pane width; divider -->

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

**See also.** [Dragging and Gestures](dragging-and-gestures.md), [Panels and Windows](ui-panels-and-windows.md).

## Shell and divider tokens

<!-- index: ui-shell-bg; ui-shell-item-fg; ui-picker-item-bg; ui-divider-bg -->

#### Token: :ui-shell-bg

The background of desktop shell bars.

#### Token: :ui-shell-fg

The foreground of desktop shell bars.

#### Token: :ui-shell-muted-fg

Muted text on shell bars, such as an empty bar message or status region.

#### Token: :ui-shell-item-fg

The caption color of an ordinary shell item.

#### Token: :ui-shell-item-minimized-fg

The caption color of a minimized shell item.

**Semantics.** The five shell keys paint shell bars and their items; selection and emphasis use the accent tokens, so a Theme can restyle an application shell through this set without touching individual controls.

#### Token: :ui-picker-item-bg

The background of a picker row.

#### Token: :ui-picker-item-fg

The caption color of a picker row.

#### Token: :ui-picker-item-muted-fg

The description color of a picker row.

**Semantics.** The picker triple dresses picker rows; a selected row uses the secondary button pair instead, which stays crisp above a dimmed surface.

#### Token: :ui-divider-bg

The divider color of a pane resizer or split boundary.

**Semantics.** A pane resizer's hairline paints with it, so every draggable boundary reads as the same material.

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected prop through `etaf-check-prop`, naming the component, property, received value and expectation: an unknown side, a bad pixel bound and non-function callbacks.
- Drag gestures are requests: a resizer callback that ignores a gesture leaves the caller's width untouched.
- `etaf-pane-resizer` owns no state at all, so a rejected input leaves every mounted pane exactly as it was.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Panels and Windows](ui-panels-and-windows.md).

```elisp :run
(etaf-view
 (row :width '(ch 48) :height '(lh 6)
   (box :width '(px 180) (text "Sidebar"))
   (etaf-pane-resizer :size 180 :side 'right :min 120 :max 320 :on-change #'ignore)
   (box :width '(ch 20) (text "Content"))))
```
