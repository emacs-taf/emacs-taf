# Floating Panels

A panel is a child frame that hosts one ETAF Runtime above the window you are working in: a clock, a player, a timer, a search result. Panels are independent — each owns its frame, Runtime and input, several can be open at once, and a panel never changes the selected buffer. A focusable panel can take the keyboard; a click anywhere on a panel raises it above the other panels. This chapter documents the panel surface itself; [Panel Applications](posframe-applications.md) documents the registry that opens a whole application as a panel, [Component Styles and Themes](component-styles-and-themes.md) the Theme plist a panel provides to its Views, [Focus](focus.md) and [Keyboard](keyboard.md) the input a focusable panel receives, and [Positioning, Layers and Overlays](positioning-layers-and-overlays.md) the absolute coordinates a panel is placed at.

## Panel options

<!-- index: panel option; etaf-posframe-show option; :at; :stack; :width; :height; :title; :theme; :border; :key -->

`etaf-posframe-show`, `etaf-posframe-toggle` and `etaf-posframe-register-app` accept the same panel vocabulary. This table is the complete list: an option not in it is rejected with `etaf-posframe-error` before any frame is created.

| Option | Value | Default | Meaning |
| --- | --- | --- | --- |
| `:at` | placement | `point` | Where the panel sits |
| `:stack` | `t`, `nil` | `nil` | Clear of the panels at the same anchor |
| `:width` | columns, fraction | 56 | Content columns |
| `:height` | rows, fraction | 30 | Content row budget |
| `:fill-height` | `t`, `nil` | `nil` | Keep the budget height |
| `:resizable` | `t`, `nil`, side list | `t` | Which edges accept a resize |
| `:title` | string | `nil` | Title-bar text |
| `:draggable` | `t`, `nil` | `nil` | Drag the title bar to move it |
| `:focusable` | `t`, `nil` | `nil` | Let the panel take the keyboard |
| `:focus-on-open` | `t`, `nil` | the value of `:focusable` | Select it on open |
| `:auto-hide` | `nil`, `t`, seconds | follows `:focusable` | Hide when the user moves on |
| `:theme` | mode, plist, ref | `auto` | Palette |
| `:border` | border plist | `nil` | Border width and state colours |
| `:key` | symbol | `nil` | Identity of the panel |

Every option is validated on entry, so a bad value signals before a frame exists rather than after a panel is half built. The rest of this section gives the accepted forms and the behaviour of each group; the entry for `etaf-posframe-show` below states the function contract, and the entries for `etaf-posframe-theme` and the variables give the palette.

### Placement and stacking

<!-- index: panel anchor; anchor names; character cell placement; pixel placement; stacked panels -->

`:at` takes five forms, and the form decides how the position resolves:

| Form | Example | Position |
| --- | --- | --- |
| Anchor symbol | `'frame-top-right` | A named place inside the parent frame or the parent window's text area. |
| Anchor plus offset | `'(point 0 -1)` | The anchor, shifted by character cells: rows first (negative goes up), columns second (negative goes left). |
| Character cell | `'(cells 0 0)` | The cell at zero-based ROW and COL of the parent window's text area, counted from its top left. |
| Frame pixels | `'(pixels 120 . 40)` | Absolute X and Y in the parent frame's pixels. |
| Function | any Posframe poshandler | Called with Posframe's placement info, returns `(X . Y)`. |

The anchors are twenty symbols: `point`, `point-top`, and every combination of `frame` or `window` with one of nine places.

| Place | Inside the parent frame | Inside the parent window's text area |
| --- | --- | --- |
| top left | `frame-top-left` | `window-top-left` |
| top centre | `frame-top-center` | `window-top-center` |
| top right | `frame-top-right` | `window-top-right` |
| middle left | `frame-center-left` | `window-center-left` |
| middle | `frame-center` | `window-center` |
| middle right | `frame-center-right` | `window-center-right` |
| bottom left | `frame-bottom-left` | `window-bottom-left` |
| bottom centre | `frame-bottom-center` | `window-bottom-center` |
| bottom right | `frame-bottom-right` | `window-bottom-right` |

An anchored panel keeps a margin to the edge it is anchored to, so it never sits on a scroll bar or a window border: one character cell inside the parent frame, half a cell inside the window's text area. A right or bottom anchor also keeps the panel's own width or height inside the parent, so a wide panel cannot run off the screen. `point` places the panel at point growing upward, which keeps the text before point visible; `point-top` places it at point growing downward.

`:stack t` reads the live panels and places the new panel against them, so a stack stays closed however tall each panel turned out. From a top or centre anchor the panel sits directly below the lowest panel it meets, from a bottom anchor directly above the highest, and two stacked frames stay 6 pixels apart on a graphical frame and one cell apart on a terminal. A column to the left takes the panel only when the frame has no room in the one it starts in, and a panel never leaves the parent frame. `:stack` needs an anchored `:at` — an anchor symbol or an anchor with an offset — because a character cell, a pixel pair or a poshandler carries no stacking direction. `:stack` with any other `:at` signals.

### Panel size

<!-- index: panel width; panel height; panel fraction; panel fitting -->

`:width` is a count of content columns and `:height` a budget of content rows; the border, the padding and the title bar are added around them. Both accept a positive integer or `(fraction F)` with F above 0 and at most 1, where the fraction is of the parent frame's width or height and the result is clamped to the parent frame.

The frame fits the rendered content up to the `:height` budget, so a short View gets a short panel and a long one clips at the budget instead of growing past the screen. `:fill-height t` keeps the frame at the full budget whatever the content height, which is what a game board on a fixed grid needs: the surface paints the remaining rows instead of the frame shrinking and clipping the board. A frame the user resizes from outside becomes the panel's new width or height and the View re-lays out at it; the fit then stops fighting the user's size.

Sizing is measured in the parent frame's character metrics. A panel whose content is wider than the parent frame is clamped, and a fraction is resolved once per show, so resizing the parent afterwards reflows the panel rather than rescaling the fraction.

| Value | Meaning |
| --- | --- |
| `30` | Thirty content columns or rows. |
| `(fraction 0.5)` | Half the parent frame's width or height, clamped to the frame. |
| `(fraction 1)` | The whole parent frame. |

### Resizing

<!-- index: panel resize; resizable panel; panel width change; panel height change -->

A panel's frame can be changed from outside: the user drags an edge, a caller calls `set-frame-size`, a tiling step rewrites it. A change the panel accepts becomes its new width and row budget, and the View re-lays out at it. `:resizable` decides which changes to accept.

| Value | Accepted |
| --- | --- |
| `t` (default) | Any edge. |
| `nil` | None; the frame returns to the size the panel had. |
| list | The axes whose edges it names: `left` or `right` for a width change, `top` or `bottom` for a height change. |

The list names edges but acts per axis, because a child frame reports only its new size, not which edge the pointer held: `'(left right)` accepts any width change and no height change, and `'(bottom)` accepts a height change and refuses the width. A refused axis is put back immediately, so the frame never keeps a size the panel does not allow. A top or left edge drag moves the frame origin while it resizes, so a refused axis returns the origin too and the panel keeps its place.

While a drag is in progress the frame shows the canvas it already has, clipped at the new edge: each row stays on its own line instead of wrapping into the narrower frame, and the View re-lays out at the new size once the panel fits again.  The panel's own fit to its content is not an outside resize, so it keeps working: a `nil` panel still shrinks to short content, and `:fill-height` still holds the row budget. A height change is only kept when it becomes the new budget — taller than the budget, or shorter than the content needs — because a panel otherwise fits its content.

```elisp
(etaf-posframe-show (etaf-view (text "panel"))
                    :width 24 :height 8 :fill-height t
                    :resizable '(left right bottom))
```

### Title bar and dragging

<!-- index: panel title; panel dragging -->

`:title` is a string and becomes the title bar above the content, painted full width in the panel surface with a hairline below it. A panel without `:title` has no header line at all, so it has no title-bar theme toggle either and cannot be dragged. `:draggable t` binds Posframe's own drag to that title bar; it needs `:title`, and a `:draggable` without a title is silently ineffective rather than an error.

### Input and lifetime

<!-- index: panel focus; panel keyboard; panel auto hide -->

`:focusable t` lets the panel take the keyboard, so its View's `:keys`, text inputs and buttons receive input. The default is nil, which means a panel is a read-only surface until the caller asks otherwise; clicking any part of a panel raises it above the other panels in both cases. `:focus-on-open` decides whether the panel is selected the moment it opens and defaults to the value of `:focusable`, so a focusable panel starts ready to type in and nil leaves it unfocused until it is clicked.

`:auto-hide` controls the lifetime of a panel the user has left:

| Value | Behaviour | Default for |
| --- | --- | --- |
| `nil` | Keep the panel until it is closed, a timer hides it or the parent buffer dies. | a `:focusable` panel |
| `t` | Hide the panel before the next command that runs outside it, so a preview disappears as soon as the user moves on. | a panel that is not focusable |
| positive number | Hide the panel that many seconds after it opens. | none |

The default therefore follows the input contract: a passive panel vanishes when the user works elsewhere, while a panel that holds the keyboard stays until it is closed, because hiding it under the user's hands would lose typed input. `etaf-posframe-hide-inactive` is a separate behaviour: it hides every panel while Emacs is not the active application, whatever `:auto-hide` says.

### Theme and border

<!-- index: panel theme option; panel border option; panel palette choice -->

`:theme` accepts five kinds of value:

| Value | Palette |
| --- | --- |
| `auto` (default) | Derived from the parent frame's default face, following the Emacs theme. |
| `light` | Pinned to the light mode. A pin that agrees with the frame keeps the frame's own surface; a pin that disagrees uses the package's neutral light base. |
| `dark` | Pinned to the dark mode, with the same rule: agree with the frame and keep its surface, otherwise use the neutral dark base. |
| Theme plist | Used as given, no derivation. |
| Theme ref or computed | Read on each render, so a host that owns a palette can switch it under a live panel. |

A panel whose `:theme` is `auto`, `light` or `dark` carries the title-bar theme toggle, because those three are the modes it can switch between. When the content declared its own surface with `etaf-surface-declare` (see [Surface declaration](component-styles-and-themes.md#surface-declaration)), the content owns the palette and its modes are what the toggle offers. A pinned `:theme` still reaches that content: the panel starts it in the pinned mode once when it opens, so an application that owns its colours opens in the mode the caller asked for instead of its own default. From then on the content's mode cell is authoritative — the title-bar switch and the content's own switch write the same cell, and both repaints follow one state.

`:border` describes the frame border in one plist:

| Field | Accepted values | When absent |
| --- | --- | --- |
| `:width` | integer 0 to 19 pixels | 1 pixel |
| `:color` | colour string, `nil` | the Theme's panel border |
| `:focus` | colour string, `nil` | the accent tinted into the surface by the focus strength |
| `:hover` | colour string, `nil` | the same by the hover strength |

A `nil` colour means "derive this one from the Theme": the width comes from `etaf-posframe-border-width` (1), `:focus` and `:hover` from `etaf-posframe-border-focus-strength` (0.6) and `etaf-posframe-border-hover-strength` (0.3), so a caller can override only the focused border and keep the other two derived. An unknown field, a width outside 0 to 19 or a non-string colour signals `etaf-posframe-error`. A text terminal draws the border in one cell that sits outside the frame size, takes one cell regardless of `:width`, and uses the terminal's own colours; the width and the three colours apply to graphical frames.

### Panel identity

<!-- index: panel key; replacing a panel -->

`:key` is a symbol naming the panel within the current buffer. Showing a View with a key that is already live replaces that panel — its frame is reused and the View is mounted fresh — while panels with different keys keep their own frame, Runtime and position. Without `:key` the panel is anonymous and every show adds one.

## Opening, refreshing and closing

<!-- index: etaf-posframe-show; etaf-posframe-hide; etaf-posframe-toggle; etaf-posframe-refresh -->

#### Function: etaf-posframe-show (view &rest options)

Show VIEW in a floating panel and return the panel.

**Arguments.** VIEW is a View or a zero-argument function returning one. OPTIONS is the plist documented in [Panel options](#panel-options); this entry states the contract rather than repeating the table.

**Semantics.** A panel is a frame plus a mounted Runtime, so the View inside it behaves exactly as it does in a buffer: refs, Components, keys and retained updates all work, and the panel adds only the frame, the title bar and the pointer handling around them. The View is mounted fresh for this panel and receives the panel's Theme and appearance, so an application painted inside a panel follows the user's palette without knowing that it is in one. Showing a View with a live `:key` replaces that panel; different keys keep their own frame, Runtime and position.

**Returns.** A panel value, opaque to callers; pass it to the functions below or to `etaf-posframe-hide`.

**Errors.** `etaf-posframe-error` for an unknown option, a value the table above does not accept, `:stack` without an anchored `:at`, or a display without child frames. A failed show unmounts the View and deletes the frame before the error is re-signaled, so a caller that retries with valid options starts from a clean state.

**Example.**

```elisp
(etaf-posframe-show (etaf-view (text "25:00"))
                    :key 'timer :title "Timer" :width 24 :height 2
                    :at 'frame-top-right :stack t :draggable t)
```

#### Function: etaf-posframe-hide (&optional panel)

Hide PANEL and release its Runtime, timer and frame.

**Semantics.** PANEL defaults to the newest panel of the current buffer, which is what the panel's own keys call; every other panel stays open. Hiding releases everything the panel owned — the Runtime, the auto-hide timer and the frame — so a hidden panel costs nothing until it is shown again, and the View is mounted fresh on the next show rather than resumed. It is safe to call repeatedly and on a panel that is already hidden.

**Returns.** Non-nil when a live panel was hidden, nil otherwise.

**See also.** `etaf-posframe-show`, `etaf-posframe-toggle`, `etaf-posframe-app`.

#### Function: etaf-posframe-toggle (view &rest options)

Hide the panel of the same `:key`, or show VIEW with OPTIONS.

**Semantics.** Without `:key` this addresses the newest panel of the current buffer. It accepts every option of `etaf-posframe-show` and is the entry for a key binding that opens and closes one panel without touching the others. Because the panel is replaced rather than reused, the View is mounted fresh on each open and reads the state of the application at that moment.

**Returns.** The new panel, or nil when it hid one.

**See also.** `etaf-posframe-show`, `etaf-posframe-hide`.

#### Function: etaf-posframe-refresh (&optional panel)

Schedule PANEL to re-lay out at its frame width and fit the frame to the rendered content.

**Semantics.** PANEL defaults to the current buffer's panel. A frame resized from outside becomes the panel width, so the View reflows and the title bar repaints to the new column count; the fit is deferred past the current event and render, so it is safe to call from a Button, a timer or a theme callback. A panel also re-fits automatically when its host frame changes size, so the call is only needed after content changed height without a Runtime update. The fit backs off when it keeps resizing, so a condition that fights it cannot run away with the CPU: it gives up after twenty fits in one second and waits two seconds before trying again.

**Returns.** Non-nil when PANEL is live.

## Reading the open panels

<!-- index: etaf-posframe-panels; etaf-posframe-panel-frame; etaf-posframe-live-p -->

#### Function: etaf-posframe-panels ()

Return the live panels, most recent first.

**Semantics.** The list is a copy, so a caller may hide panels while walking it. Order is recency, which is what `etaf-posframe-hide` uses for its default, what `etaf-posframe-cycle` walks and what `:stack` consults when it looks for panels to avoid.

**Returns.** A list of panel values.

#### Function: etaf-posframe-panel-frame (panel)

Return PANEL's child frame, or nil when PANEL is not live.

**Semantics.** Read or compare the frame with this instead of reaching into package internals, for example to place another panel relative to it, to record a window id for a screenshot or to check which frame has focus.

**Returns.** A frame or nil.

**See also.** `etaf-posframe-live-p`.

#### Function: etaf-posframe-live-p (panel)

Return non-nil while PANEL's frame exists and its Runtime is mounted.

**Semantics.** A panel value outlives the panel: holding it after the panel is hidden is safe, and this predicate says whether there is still something to talk to. `etaf-posframe-hide` returns why a caller would ask.

**Returns.** A boolean.

## The title bar and the pointer

<!-- index: panel title bar; panel theme toggle; panel hover border -->

A panel with a `:title` has a full-width title bar: one row high, painted in the panel surface lifted slightly toward the foreground, with a hairline below it and, when the panel's `:theme` is a mode, the theme toggle at its right. The title bar clears the theme's own `header-line` face, so a light theme gets no dark outline around it and the bar keeps the panel's colors even when the theme inverts its header line.

The panel's own toggle is one row of three boxes and every segment is a mode:

| Segment | Mode | Effect |
| --- | --- | --- |
| `亮` | `light` | Pin the panel to the light palette. |
| `随` | `auto` | Follow the Emacs theme again. |
| `暗` | `dark` | Pin the panel to the dark palette. |

The segment of the current mode fills with the theme accent and its label takes black or white by the accent's luminance; the other two keep the title-bar surface and darken on hover. A click repaints that panel on the chosen mode for the rest of its life. `:theme` stays the value the caller passed, so the choice is a session setting that is never written to configuration, and reopening the panel starts from the configured mode again. The control is `etaf-toggle-strip` from etaf-ui, documented in [Buttons and Choice Controls](ui-buttons-and-choice-controls.md).

When the content declared its own surface, the toggle renders that content's mode table instead: the number of segments and their labels come from the content, which is why the reader offers `深`, `浅` and `纸`. The selected segment is the content's current mode, and a click writes the one mode cell the content and its host share. The content's own key writes the same cell, so a switch on either side repaints the content, the title bar, the frame and the border together: one application has one appearance state.

The pointer never takes the keyboard. A panel leaves buffer-level `track-mouse` off, because Emacs then selects the frame under the pointer whenever it moves, and leaving a panel would take the keyboard with the pointer. The hover border reads the pointer from a short timer instead: the panel under the pointer paints its border in the accent, and only a click moves the keyboard. A panel that is already focused keeps its focused border and takes no hover paint, so the two states never stack, and a focused segment of the theme toggle takes no hover fill for the same reason.

Dragging the title bar moves the panel when `:draggable` is set; Posframe owns the drag, so an application writes no code for it and the panel position is not reported back.

## The keyboard

<!-- index: panel keys; panel focus; panel cycling -->

A panel is focusable only when it was opened with `:focusable`, and only then do its View's keys, text inputs and buttons receive input; clicking any part of a panel raises it above the other panels either way. Once focused, the panel's own keys come from the View, and `etaf-posframe-panel-keys` adds exactly three bindings that outrank them, so closing a panel never depends on the application remembering to bind it.

#### Variable: etaf-posframe-panel-keys

Keymap that is always active while a focusable panel has focus.

**Semantics.** It closes the panel on `q`, `ESC` and `C-g` and outranks the View's own keys only for those three bindings, so an application may use every other key freely. A View key cannot win over these three, which is what keeps the panel closeable from any state, including a View whose own key handling is stuck. The map is read when the panel takes focus, so a caller may add a binding of its own and lose it to these three only on those keys.

**See also.** `etaf-posframe-cycle`, `etaf-posframe-hide`.

#### Variable: etaf-posframe-hide-inactive

Hide the panels while Emacs is not the active application, `t` by default.

**Semantics.** A child frame is a window of its own, so a window manager that lists windows — macOS Mission Control, for instance — would offer the panel as a target, and clicking it would activate Emacs instead of the application behind it. Hiding the panels while another application is active keeps that list clean; the panels come back when Emacs is active again. Nil keeps them visible, which suits a panel that should stay on screen beside another application. The variable is independent of `:auto-hide`, which is about the user working elsewhere inside Emacs. It has no effect on a text terminal, whose frame is not listed as a window: terminal panels stay visible.

#### Variable: etaf-posframe-focus-follows-mouse

Move the input focus to a panel the mouse pointer rests on, `nil` by default.

**Semantics.** Only panels that accept the keyboard are focused. The default keeps the keyboard where the user put it, which is why the hover border needs no option: the panel under the pointer paints its border accent, keeps the keyboard, and a click is what moves it. Setting this to `t` makes hovering itself change the keyboard target, which some pointer-driven workflows prefer and typing workflows do not.

**See also.** `etaf-posframe-show`, `etaf-posframe-panel-keys`.

### Reaching a panel from a text terminal

A text terminal draws a child frame but gives it neither the keyboard nor the mouse: every key and click stays with the frame behind the panel. A terminal therefore reaches a panel through the app prefix map, which acts on the panel of the selected frame and otherwise on the most recent panel, while the keyboard sits in an ordinary buffer.

After the prefix, the arrow keys move the panel `etaf-posframe-move-step` cells, `=` or `+` widens it, `-` narrows it, `>` heightens it and `<` shortens it, and `k` reads one more key and runs it in the panel. A move counts character cells: a graphical frame moves by its character width and height, a terminal by its single cell. Control plus an arrow is deliberately not used, because on macOS the window manager switches desktop spaces before Emacs sees the key. The keys stay live after the first press, so the prefix is needed once per run and a held key repeats the move; any other key ends the run. A panel stops at its parent frame's edge rather than leaving the screen. A moved panel keeps its place and a resized one keeps its width and row budget through later refreshes, because the new place becomes an absolute anchor and the new height becomes the `:fill-height` budget.

#### Function: etaf-posframe-move (direction &optional steps panel)

Move PANEL `steps` cells in `direction`.

**Semantics.** `direction` is `left`, `right`, `up` or `down`, `steps` defaults to `etaf-posframe-move-step` (3), and `panel` defaults as in the prefix map. One step is one character cell. The place is clamped to the parent frame's top left corner, and the panel's anchor becomes the absolute position it now occupies, so a refresh does not put it back. Interactively the command prompts for the direction instead of reading an arrow key.

**Errors.** Signals `etaf-posframe-error` when no live panel is available.

#### Function: etaf-posframe-resize (axis &optional steps panel)

Change PANEL's size by `steps` cells along `axis`.

**Semantics.** `axis` is `wider`, `narrower`, `taller` or `shorter`; `steps` defaults to `etaf-posframe-resize-step` (1). The panel never becomes narrower than four columns or shorter than two rows. The new width and row budget are recorded before the frame changes, so the refresh that a frame resize triggers keeps them and the content re-lays out to the new width. Interactively the command prompts for the axis.

**Errors.** Signals `etaf-posframe-error` when no live panel is available.

#### Function: etaf-posframe-send-key (&optional panel)

Read one key sequence and run it in PANEL's View.

**Semantics.** The key runs with the panel's buffer current, so a key the View declares on its Host runs there. A control that needs the keyboard focus on one row, such as a button reached through Tab, still needs a graphical frame; a terminal panel therefore suits a View that declares its keys. Return the key sequence that ran.

**Errors.** Signals `etaf-posframe-error` when no live panel is available.

#### Variable: etaf-posframe-move-step

Character cells `etaf-posframe-move` moves when it gets no step count, `3`.

**Semantics.** One step is one character, so a graphical frame moves by its character width and height and a terminal by its single cell. The default moves far enough that one arrow press is visible, and a held key still stops where the user means; the prefix map's arrow keys use it too.

#### Variable: etaf-posframe-resize-step

Columns or rows `etaf-posframe-resize` changes when it gets no step count, `1`.

**Semantics.** The default changes one cell, which keeps a narrow panel from overshooting its frame. Raise it to reach a wanted width in fewer presses; the prefix map's sizing keys use it too.

**See also.** `etaf-posframe-app-prefix`, `etaf-posframe-panel-keys`.

## Appearance and borders

<!-- index: panel theme; panel token; panel border; border strength -->

A panel provides a Theme to its Views, derived from the parent frame's default face, so an application painted inside it follows the user's palette instead of shipping colors. The panel frame paints the panel surface, and the title bar, the borders and the Views all read the same palette, which is why a light panel inside a dark frame stays light and readable. When the content declared its own surface with `etaf-surface-declare`, the panel paints that Theme instead: the frame, title bar and border all take that palette, and the panel derives no second one from the parent frame. Ink on a filled accent follows the accent's luminance, so a dark theme with a pale accent and a light theme with a deep one both get readable labels.

#### Function: etaf-posframe-theme (&optional frame mode)

Return an ETAF UI Theme plist derived from FRAME's default face.

**Arguments.** FRAME defaults to the selected frame. MODE is `light` or `dark` to pin the palette to that mode, or nil to follow the frame. A pin that agrees with the frame's own surface keeps that surface, so switching between following the theme and pinning to the frame's own mode does not move the panel colors; a pin that disagrees derives a palette of the pinned polarity. The mode is read from the frame's actual background, so a theme that leaves `background-mode` stale is still read correctly.

**Semantics.** The result carries the token vocabulary this package paints with. `:ui-panel-bg` is the panel surface: the frame background sunk toward `etaf-posframe-dark-surface` by `etaf-posframe-dark-shade` in a dark palette, or toward black by `etaf-posframe-surface-lift` in a light one. `:ui-accent` is the frame's `link` foreground, falling back to a fixed blue when the theme leaves it unspecified. Every other token derives from those three, so a caller that changes the frame colors gets a coherent palette rather than a mix.

| Token | Derivation |
| --- | --- |
| `:ui-mode` | `dark` or `light`: the resolved polarity. |
| `:ui-bg` | The frame background, or the neutral base of a pinned mode that disagrees with the frame. |
| `:ui-fg` | The frame foreground, or the matching base foreground. |
| `:ui-border` | The panel surface mixed 16% toward the foreground. |
| `:ui-panel-bg` | The frame background sunk as described above. |
| `:ui-panel-fg` | The foreground. |
| `:ui-panel-border` | Same as `:ui-border`. |
| `:ui-muted-fg` | The foreground mixed 42% toward the surface. |
| `:ui-accent` | The `link` foreground, else `#2F6FE4` in a light palette or `#6CB6FF` in a dark one. |
| `:ui-accent-fg` | Black or white ink for text on the accent, by the accent's luminance. |
| `:ui-accent-soft-bg` | The surface mixed 12% toward the accent. |
| `:ui-disabled-fg` | The foreground mixed 60% toward the surface. |
| `:ui-disabled-bg` | The surface mixed 12% toward the border. |
| `:ui-disabled-border` | The border. |
| `:ui-button-primary-fg` | The ink on the accent. |
| `:ui-button-primary-bg` | The accent. |
| `:ui-button-secondary-fg` | The foreground mixed 35% toward the accent. |
| `:ui-button-secondary-bg` | The surface mixed 18% toward the accent. |
| `:ui-button-ghost-fg` | The foreground. |
| `:ui-info-bg`, `:ui-info-fg`, `:ui-info-border` | The surface, the foreground and the border mixed toward `#6CB6FF` at 20%, 55% and 40%. |
| `:ui-success-bg`, `:ui-success-fg`, `:ui-success-border` | The same three mixes toward `#4FB477` at 20%, 50% and 40%. |
| `:ui-warning-bg`, `:ui-warning-fg`, `:ui-warning-border` | The same three mixes toward `#E8B45C` at 20%, 55% and 40%. |
| `:ui-danger-bg`, `:ui-danger-fg`, `:ui-danger-border` | The same three mixes toward `#FF7A7A` at 20%, 55% and 40%. |

**Returns.** A Theme plist with every token above; a caller may pass it to `etaf-theme-provide` in a Component `:setup` when it builds its own boundary, such as a second child frame or a region of a panel.

**Example.**

```elisp
(let ((theme (etaf-posframe-theme nil 'dark)))
  (plist-get theme :ui-panel-bg))
```

#### Variable: etaf-posframe-dark-surface

Neutral near-black a dark panel surface sinks toward, `#101214` by default.

**Semantics.** Dark applications paint a flat near-black surface, so sinking the panel by `etaf-posframe-dark-shade` keeps a panel in that family instead of lifting the theme color into a grey card. Set it to the background of the application a panel should sit beside.

#### Variable: etaf-posframe-dark-shade

How far a dark panel surface sinks toward `etaf-posframe-dark-surface`, 0 to 1, default 0.5.

**Semantics.** 0 keeps the frame's own dark background and 1 takes the neutral near-black outright. Half keeps a dark theme's hue while still reading as the same surface family as the application behind the panel.

#### Variable: etaf-posframe-surface-lift

How far a light panel surface sinks toward black, 0 to 0.5, default 0.03.

**Semantics.** A light panel keeps a faint grey so it still reads as a surface rather than merging into a white page. Raising it darkens every light panel; 0 makes a panel indistinguishable from a white buffer behind it.

#### Variable: etaf-posframe-border-width

Frame border width in pixels, 0 to 19, used when `:border` has no `:width`.

**Semantics.** A one-pixel border in the theme's border color is what separates a panel from the buffer behind it and makes it read as a floating surface. The panel's `:border` option overrides it per panel, and 0 removes the frame border while keeping the title bar's hairline.

#### Variable: etaf-posframe-border-focus-strength

How much of the Theme accent a focused border shows, 0 to 1, default 0.6.

**Semantics.** The border is the panel surface tinted toward the theme's `link` color: 0 keeps the surface and 1 paints the accent itself. A per-panel `:border` `:focus` color replaces the tint entirely. Tinting instead of painting the accent keeps a one-pixel outline from reading as a saturated frame in either palette.

#### Variable: etaf-posframe-border-hover-strength

How much of the Theme accent a hovered border shows, 0 to 1, default 0.3.

**Semantics.** A hovered panel does not hold the keyboard, so it hints at the accent more weakly than a focused one. Keep it below `etaf-posframe-border-focus-strength` so hovering hints and clicking commits stay distinct; a per-panel `:border` `:hover` color replaces the tint.

## Sizes and fitting

<!-- index: etaf-posframe-default-width; etaf-posframe-default-max-height -->

#### Variable: etaf-posframe-default-width

Columns of a new panel when `:width` is absent, 56 by default.

**Semantics.** The value is a column count of content, not of the frame: the border, the padding and the title bar are added around it. A panel whose content is drawn on a fixed grid passes `:width` instead, and a panel that should fill a fraction of the frame passes `(fraction F)`.

**See also.** `etaf-posframe-show`, `etaf-posframe-default-max-height`.

#### Variable: etaf-posframe-default-max-height

Maximum content lines of a new panel when `:height` is absent, 30 by default.

**Semantics.** The panel fits its frame to the rendered content up to this budget, so a short View gets a short panel. A panel that must keep a fixed height, such as a game board on a fixed grid, passes `:fill-height` with `:height` and the surface paints the rest.

**See also.** `etaf-posframe-show`, `etaf-posframe-default-width`.

## Errors and recovery

<!-- index: etaf-posframe-error; panel failure -->

#### Error: etaf-posframe-error

Signals invalid panel input and unavailable capabilities.

**Semantics.** Every option is checked before a frame exists, and a rejected show cleans up before it signals: the View is unmounted and the frame deleted. The condition data is a list whose first element is a message, so a caller can display it as it is.

| Failure | Signaled when |
| --- | --- |
| Unknown option | The plist carries a key outside [Panel options](#panel-options). |
| Bad value | A flag is not `t` or `nil`, a size is not a positive integer or `(fraction F)` in range, `:auto-hide` is not `t`, `nil` or positive seconds, `:title` is not a string, `:key` is not a symbol, or `:theme` is not a mode, a plist, a ref or a computed. |
| Bad `:at` | The value is not an anchor, an anchored offset, `(cells ROW COL)`, `(pixels X . Y)` or a function. |
| `:stack` without an anchor | `:stack` is non-nil and `:at` is a cell, a pixel pair or a poshandler. |
| Bad `:border` | A field outside `:width`, `:color`, `:focus` and `:hover`, a width outside 0 to 19, or a non-string colour. |
| Incomplete application registration | `etaf-posframe-register-app` has no `:create` or no `:view`; a panel option of a registration is checked when its panel opens, not at registration. |
| No child frame display | Emacs runs in a terminal that does not provide the `tty-child-frames` feature. |

**See also.** `etaf-posframe-show`, `etaf-posframe-register-app`, [Standard Errors](standard-errors.md).
