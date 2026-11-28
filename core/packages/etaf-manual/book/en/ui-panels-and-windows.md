# Panels and Windows

A window shell is a controlled surface with a title bar, traffic lights and resize handles. The catalog's panels and windows are deliberately presentational: they project the caller's geometry to Ebox and report gestures to the caller's callbacks, and they keep no window state, assign no z-order and implement no workspace or window manager. The caller owns position, size, visibility and mode, usually as refs; changing one repaints the retained shell without rebuilding it. [UI Overview](ui-overview.md) defines the controlled contract, [Positioning, Layers and Overlays](positioning-layers-and-overlays.md) the absolute positioning and z-order they use, [Dragging and Gestures](dragging-and-gestures.md) the gesture and lock protocol, and [Component Styles and Themes](component-styles-and-themes.md) the window tokens.

## Controlled geometry and mode

<!-- index: window geometry; reactive geometry; window mode; gesture callbacks -->

Every geometry prop — position, size, z-index and visibility — is an ordinary Host property, so it may be a value, a ref or a computed source, and the shell publishes it as a retained binding. A caller that stores the rectangle in refs can move a window by writing those refs: the frame, slots and gesture routes do not change, and each pointer move only updates the geometry cells. Constraints (`:min-width`, `:max-width`, `:min-height`, `:max-height`) travel with the same props and are resolved by Ebox.

Mode is a small closed vocabulary — `normal`, `minimized`, `maximized` — that the components read reactively. A reactive MODE keeps the shell's mode classes, the Zoom action's target and the collapsed content as retained bindings, so minimizing or maximizing never rebuilds the window. `minimized` is presentation, not geometry: a minimized window that stays visible collapses to its title bar, and clicking Zoom calls ON-RESTORE while maximized and ON-MAXIMIZE otherwise. A window never changes global focus or z-order policy; raising, stacking and persistence belong to the caller or a desktop shell.

Gestures are reported, never applied. The title bar forwards Ebox's gesture plist to ON-MOVE, a resize handle forwards the edge and the gesture to ON-RESIZE, and `:drag-lock-modifier` makes a move or resize release-independent for that modifier. A caller that wants keyboard traversal of the same operations gets them for free: with focus anywhere in the window, `M-arrows` move it through the title bar's handlers and `M-S-arrows` drag the right, bottom or bottom-right handle. Handles are hit targets, not Tab stops, so Tab keeps moving between real controls.

## The resizable panel

<!-- index: etaf-resizable-panel; resize handles; header slot; full bleed -->

#### Component: etaf-resizable-panel (&key x y width height position z-index visible min-width max-width min-height max-height resizable resize-edges resize-refs resize-use on-resize on-move header-style drag-lock-modifier full-bleed font-size font-family ref id class role use overflow)

Render a controlled positioned panel with optional edge and corner resize handles.

**Arguments.** X, Y, WIDTH, HEIGHT, Z-INDEX, VISIBLE, MIN-WIDTH, MAX-WIDTH, MIN-HEIGHT, MAX-HEIGHT and CLASS accept values, refs or computed sources. POSITION is `absolute` (default) or `relative`. RESIZABLE defaults t and RESIZE-EDGES lists the active edges from `top`, `right`, `bottom`, `left` and the four corners. RESIZE-REFS maps an edge to a caller-owned reference or a per-edge reference function, and RESIZE-USE maps an edge to a Behavior. ON-MOVE receives a gesture plist from the panel root and ON-RESIZE receives EDGE and that gesture. HEADER-STYLE presents the header row's corner cells like the header; FULL-BLEED lets the default slot own the full body while handles overlay its edge cells. FONT-SIZE and FONT-FAMILY inherit when nil.

**Semantics.** A panel with a `header` slot or interactive handles is framed: the header owns the first row between the corner cells, and `header-style` keeps its background and rule continuous across the window's outer columns. Widgets move and resize through the caller's refs — an ETAF Behavior or the `M-arrows`/`M-S-arrows` bindings a shell installs. The component stores no geometry, constraints, z-order or interaction state; Ebox owns gesture confirmation and cancellation, and the caller must fit positioned content within the canvas's shared line height.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when POSITION is neither `absolute` nor `relative`, RESIZABLE or FULL-BLEED is not a boolean, RESIZE-EDGES contains an unsupported edge, RESIZE-REFS or RESIZE-USE is not an edge-keyed alist of the right shape, a callback is neither a function nor nil, DRAG-LOCK-MODIFIER is neither nil nor a supported modifier, or FONT-SIZE is not a positive CSS pixel size (or FONT-FAMILY not a string).

**Example.**

```elisp
(etaf-resizable-panel :x px :y py :width pw :height ph
                      :min-width '(px 160) :min-height '(lh 4)
                      :on-move #'move-window :on-resize #'resize-window
                      (slot :name 'header (text "Inspector"))
                      (text "Body"))
```

**See also.** `etaf-window`, [Dragging and Gestures](dragging-and-gestures.md).

## Window controls and chrome

<!-- index: etaf-window-controls; traffic lights; etaf-window-chrome; title bar -->

#### Component: etaf-window-controls (&key mode show-minimize show-maximize show-close active on-minimize on-maximize on-restore on-close group class)

Render reusable macOS-style traffic-light controls.

**Arguments.** MODE is `normal`, `minimized`, `maximized`, a ref or a computed. SHOW-MINIMIZE, SHOW-MAXIMIZE and SHOW-CLOSE default t. ACTIVE toggles the macOS presentation: an inactive window shows one gray for all three lights, the active window keeps red, yellow and green. GROUP is a shared hover group key forwarded to Ebox so all lights update in one incremental batch. The callbacks request caller-owned transitions.

**Semantics.** The lights are ordered close, minimize, zoom. The green Zoom control has one stable target: it calls ON-RESTORE while MODE is `maximized` and ON-MAXIMIZE otherwise, reading a reactive MODE when pressed so a mode change never rebuilds the controls. Without SVG the lights fall back to one-cell ASCII marks that keep the same action targets and hover labels. The group is a one-row toolbar focus group.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when MODE is not one of the three values or a reactive source, ACTIVE does not resolve to a boolean, GROUP is not a scalar key, or a callback is neither a function nor nil.

**Example.** `(etaf-window-controls :mode mode :active active :on-close #'close-window)`

#### Component: etaf-window-chrome (&key title mode show-minimize show-maximize show-close active on-minimize on-maximize on-restore on-close on-move drag-lock-modifier title-font-size font-family group ref class use)

Render a controlled title bar with minimize, zoom and close action buttons.

**Arguments.** TITLE is the centered title. MODE, SHOW-*, the action callbacks, ACTIVE, DRAG-LOCK-MODIFIER (default `shift`) and GROUP match `etaf-window-controls`. ON-MOVE receives the title bar's gestures. TITLE-FONT-SIZE and FONT-FAMILY default to nil to inherit; an explicit size is a multiple of the body size, from 0.3 through 4. The `actions` and default slots append custom controls after the built-in lights on the right.

**Semantics.** The bar is one retained row: a leading spacer, the traffic lights, an equal-fixed-column title surface that stays centered without a positioned child, and a fixed-width actions column. A reactive MODE changes the chrome's mode class and the Zoom target without re-rendering the bar, and the title's tone follows ACTIVE as a retained paint update. The whole bar hands its drag gestures to ON-MOVE, so pressing and dragging it moves the window through the caller's handler.

**Returns.** A View.

**Errors.** Those of `etaf-window-controls`, plus a bad `:drag-lock-modifier`, a non-positive `:title-font-size` or a non-string `:font-family`.

**Example.**

```elisp
(etaf-window-chrome :title "Editor" :mode mode :active active
                    :on-move #'move-window :on-close #'close-window)
```

## The window

<!-- index: etaf-window; window shell; viewport region; keyboard move -->

#### Component: etaf-window (&key title mode x y width height z-index visible min-width max-width min-height max-height resizable resize-edges resize-refs resize-use move-use full-bleed on-move on-resize on-focus drag-lock-modifier title-font-size content-font-size font-family controls-group controls-active on-minimize on-maximize on-restore on-close show-minimize show-maximize show-close ref id chrome-ref class use overflow)

Compose a controlled window shell from `etaf-resizable-panel` and `etaf-window-chrome`.

**Arguments.** TITLE, MODE and every geometry or constraint prop are as for `etaf-resizable-panel` and the chrome. ON-MOVE and ON-RESIZE receive the gestures described above, and MOVE-USE, RESIZE-USE and USE install Behaviors. ON-FOCUS runs for body activation, for a nested control press through the ancestor capture hook, and when keyboard focus enters the window. TITLE-FONT-SIZE and CONTENT-FONT-SIZE override their own region independently, and FONT-FAMILY selects one family for both. CONTROLS-GROUP and CONTROLS-ACTIVE configure the traffic lights. Slots are `header`, `actions`, `default` and `footer`.

**Semantics.** The shell composes the panel and the chrome: the title bar occupies the first row, the body is the default slot wrapped in one viewport region so a component inside reads `(PIXELS . ROWS)` from `etaf-viewport`, and the actions and footer slots compose around it. With focus anywhere in the window, `M-arrows` move it through the title bar's handlers and `M-S-arrows` resize it through the right, bottom or bottom-right handle; the handles are hit strips, not Tab stops. `minimized` collapses the visible window to its title bar, and maximizing never changes geometry or global focus policy. All positioned content must fit the containing canvas's shared line height; Ebox rejects a larger resolved font before publishing.

**Returns.** A View.

**Errors.** The panel's and chrome's validation applies; a bad MODE, geometry constraint or callback fails the call with `error→ etaf-component-call-error` naming the property.

**Example.**

```elisp
(etaf-window :title "Editor" :mode mode :x wx :y wy :width ww :height wh
             :on-move #'move-window :on-resize #'resize-window
             :on-close #'close-window
             (text "Document"))
```

**See also.** `etaf-resizable-panel`, `etaf-window-chrome`.

## Window tokens

<!-- index: ui-window-fg; ui-window-bg; ui-window-title-bg; ui-window-title-active-fg -->

#### Token: :ui-window-fg

The foreground of window content.

#### Token: :ui-window-bg

The background of a window or panel surface.

#### Token: :ui-window-border

The frame around a window or panel.

**Semantics.** With `:ui-window-fg` and `:ui-window-bg` it forms the window surface triple; the same keys paint a plain resizable panel, so a panel and a full window read as one material.

#### Token: :ui-window-title-bg

The background of a window's title bar.

#### Token: :ui-window-title-fg

The title color of an inactive window.

#### Token: :ui-window-title-active-fg

The title color of the active window.

**Semantics.** The title surface reads the active or inactive key from a retained Host property, so a focus change repaints the title's tone without re-rendering the bar.

#### Component: etaf-edge-panel (&key title status variant focus width ref)

Render a panel whose TITLE sits on the panel's top rule.

**Parameters.** STATUS, when given, is painted at the right end of the same rule; VARIANT defaults to `default`, and `flat` drops the surface and keeps the rule; FOCUS paints the rule and the title in the accent ink; WIDTH and REF are the usual parameters.

**Returns.** An ETAF Component.

**Semantics.** The title occupies the cell the rule would take, so the panel names itself without spending a row; the status shares that same row's right end, which is denser than a panel with its own title bar.

**See also.** `etaf-edge-tabs`, `etaf-underline-field`, `etaf-window`.

#### Component: etaf-edge-tabs (&key items active on-change width ref)

Render ITEMS as tabs set into the panel's top rule.

**Parameters.** ITEMS are plists with a unique `:key` and a nonempty `:label`; ACTIVE is the selected key and may be a ref; ON-CHANGE receives the key of a pressed tab; WIDTH and REF are the usual parameters.

**Returns.** An ETAF Component.

**Semantics.** The rule runs across the whole tab row, so the labels sit on the pane's edge instead of on a strip above it. The chosen tab takes the accent ink and a bold weight while the others stay muted; the rule never breaks for a tab, so the whole still reads as one frame.

**See also.** `etaf-edge-panel`, `etaf-tabs`.

#### Component: etaf-underline-field (&key label value placeholder focus width ref)

Render a read-only field drawn as a line under its value.

**Parameters.** LABEL names the field above it in muted ink; VALUE is what the rule carries; PLACEHOLDER shows in the muted ink while VALUE is empty; FOCUS paints the rule in the accent colour; WIDTH and REF are the usual parameters.

**Returns.** An ETAF Component.

**Semantics.** It draws a form as rows of labelled text rather than as boxes, and the rule costs no row of its own. The field is read-only: editing it means opening an input session, which [Text input](text-input.md) defines.

**See also.** `etaf-edge-panel`, [Text input](text-input.md).

#### Component: etaf-log (&key rows level-width time-width width ref)

Render ROWS as a log, one entry per row.

**Parameters.** Each row is a plist with `:time`, `:level` and `:message`; LEVEL-WIDTH defaults to 5 and TIME-WIDTH to 8; WIDTH and REF are the usual parameters.

**Returns.** An ETAF Component.

**Semantics.** The time and the level are muted and coloured, the level column has LEVEL-WIDTH cells and the time column TIME-WIDTH, and the message fills the rest. It draws no frame, because a pane already draws one; putting it inside `etaf-edge-panel` or a drawer is what completes the surface.

**See also.** `etaf-status-bar`, `etaf-edge-panel`.

#### Component: etaf-status-bar (&key mode keys note width ref)

Render a one-row status bar with MODE, KEYS and NOTE.

**Parameters.** MODE is a filled chip naming the current mode; KEYS is a list of (KEY . LABEL) pairs painted as a key and its meaning; NOTE sits at the right end; WIDTH and REF are the usual parameters.

**Returns.** An ETAF Component.

**Semantics.** The bar owns no frame: it reads as the bottom edge of the window. KEYS keeps the order it is given, so the caller decides which keys earn a place on that row.

**See also.** `etaf-log`, `etaf-window`.

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected prop through `etaf-check-prop`, naming the component, property, received value and expectation: an unsupported mode, position, edge list, reference or Behavior alist, a non-boolean flag, a bad lock modifier, and a font size that is not a positive number.
- Gestures are requests: a move or resize handler that ignores a gesture leaves the geometry unchanged, and the component never writes the caller's refs. Releasing with the lock modifier active ends the gesture through the same callbacks.
- Ebox still owns gesture confirmation and cancellation: an invalid geometry value is rejected at publication, and the previous committed rectangle stays visible.
- Content that exceeds the canvas's shared line height is refused before publication; the previous pixels and input remain available, so a rejected font cannot corrupt the window.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Dragging and Gestures](dragging-and-gestures.md).

```elisp :run
(etaf-view
 (column :width '(ch 70) :height '(lh 22)
   (etaf-window :title "Editor" :x '(px 0) :y '(lh 0)
                :width '(ch 40) :height '(lh 10)
                :on-move #'ignore :on-resize (lambda (edge gesture) (ignore edge gesture))
                (text "Document"))))
```
