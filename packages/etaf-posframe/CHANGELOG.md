# Changelog

## Unreleased

### Added

- Panels can be placed and resized from the keyboard, which is how a text
  terminal reaches them: the app prefix map moves a panel with the arrow keys,
  widens it with `=' or `+', narrows it with `-', and heightens or shortens it
  with `>' or `<'; `k' forwards the next key to the panel.
  `etaf-posframe-move', `etaf-posframe-resize' and `etaf-posframe-send-key'
  are the same three operations as commands.  The arrow keys stay live after
  the first press, so one prefix reaches a run of moves and a held key repeats
  it; any other key ends the run.  A moved panel keeps its place and a resized
  one keeps its width and row budget through later refreshes, and a panel stops
  at its parent frame's edge instead of leaving the screen.
- `etaf-posframe-move-step` (3) and `etaf-posframe-resize-step` (1) set the
  default step of those two commands.  A move counts character cells, so a
  graphical frame moves by its character width and a terminal by its single
  cell, and no longer by one pixel per press.

## 0.3.0

### Added

- ETAF panels work on a text terminal that provides Emacs' `tty-child-frames`
  feature (Emacs 31 and later), so `etaf-posframe-show` no longer refuses a
  non-graphical display when its terminal has child frames.  Terminal panels
  keep the same placement, stacking, clipping, filling and focus behaviour as
  graphical ones, and a terminal resize re-places and re-fits every open panel
  at new columns and rows.  A terminal draws the frame border in one cell that
  sits outside the frame size, so anchors, stacking and the row clamp count it;
  that border takes one cell and the terminal's colours, while `:border` width
  and colours remain a graphical-frame feature.  `etaf-posframe-hide-inactive`
  stays a graphical-frame feature because a terminal frame is not listed as a
  window.  A panel with a title now keeps its frame at header plus content on a
  terminal instead of one empty row below it.

- `:resizable` decides which outside size changes a panel accepts: `t`
  (default) keeps today's behaviour and follows any edge, `nil` returns the
  frame to the size the panel had, and a list such as `'(left right bottom)`
  accepts only the axes whose edges it names.  A top or left edge drag moves
  the frame origin with the size, so a refused axis returns the origin too and
  a fixed panel stays where it was.  The panel's own fit to its content is not
  an outside resize, so a `nil` panel still shrinks to short content and
  `:fill-height` still holds the row budget.

- A panel whose content declares its surface with `etaf-surface-declare`
  paints its frame, title bar and border from that content's Theme, and its
  title bar offers the content's modes with the content's current mode
  selected.  The content's own switch and the title-bar switch write the same
  mode cell, so an application inside a panel has one appearance state instead
  of one per surface; when the content holds a mode the switch does not offer,
  such as the reader's sepia paper, the switch still renders its choices with
  none selected; the content's mode may be any palette, such as the
  reader's sepia.  Panels whose content declares nothing keep the `:theme`
  behaviour.

- A panel title bar carries a theme toggle when its `:theme` is `auto`, `light`
  or `dark`: `亮`, `随` and `暗` in one row of equal-width boxes, the current
  mode filled with the theme accent.  A click repaints that panel for the rest
  of its life and never writes the caller's configuration.

### Fixed

- A panel keeps its rows on one line each while a drag narrows its frame: the
  frame shows the previous canvas clipped at the new edge instead of wrapping
  it, so a board no longer scrambles for the moment before the View re-lays
  out.  Posframe writes `truncate-lines` from its own keyword, so the panel now
  passes `:lines-truncate`.

- A panel pinned with `:theme light` or `dark` now starts a content that owns
  its palette in that mode.  The pin used to reach only the panel's own frame
  and title bar, so an application such as the NetEase player kept painting its
  own default palette inside a light panel; the panel now writes its pinned
  mode into the content's mode cell once, and the content's own switch decides
  after that.

- A stacked panel now takes the row below the panel above it instead of
  stepping down by its own height, so panels of different heights close up
  instead of leaving a hole as tall as the difference between them.

- Switching between `auto` and the frame's own mode no longer shifts the panel
  and title-bar colours: a pin that agrees with the frame keeps the frame's
  surface.  The mode now comes from the frame's actual background, so a theme
  that leaves `background-mode` stale is read correctly, and a filled accent
  takes black or white ink by its luminance instead of by the palette's mode.

### Changed

- The user documentation moved into the ETAF Reference Manual: the Floating
  Panels and Panel Applications chapters replace `docs/manual.md`, which this
  repository no longer keeps.  The README and the entry Commentary point there.

### Removed

- The Pomodoro example panel moved to its own application package,
  [etaf-pomodoro](https://github.com/emacs-taf/etaf-pomodoro).  Its surface no
  longer sits inside an `etaf-card`, so the panel frame is the only border and a
  panel edge stays one pixel wide on every side.

- A theme switch repaints every live panel in one pass.  The palette was
  derived with an explicit nil `INHERIT`, which answers for the selected frame:
  a panel that held the keyboard took its own colours as the theme, so after a
  switch it painted a wrong mixed surface instead of the new palette.  The
  palette now comes from the panel's parent frame, whatever holds the keyboard.
- Disabling the old theme and enabling the new one arrive as separate steps,
  and disabling every theme resets a child frame to white.  The panels now keep
  the palette they already paint until one coalesced pass repaints the frame
  colours, the title bar and every View together, so a switch no longer flashes
  an intermediate surface behind a 0.1 s timer.

- A panel no longer enables buffer-level `track-mouse`.  Enabling it made Emacs
  select the frame under the pointer whenever the pointer moved, so moving the
  pointer off a focused panel moved the keyboard to the frame behind it.  The
  hover border still follows the pointer through its 0.2 s reading, and a click
  remains the only pointer action that moves the keyboard.

### Changed

- The panel vocabulary now has one option per concept.  Renames and merges:
  `:header` becomes `:title`; `:focusable` and `:auto-focus` become
  `:focusable` and `:focus-on-open`; `:dismiss` and `:timeout` become
  `:auto-hide` (`nil`, `t` or seconds); `:theme` takes `auto`, `light`, `dark`
  or a palette; `:at` takes `(ANCHOR ROWS COLS)`, `(cells ROW COL)` or
  `(pixels X . Y)`, so `:cell` and `:offset` are gone; the four border options
  become one `:border` plist; `:fill` becomes `:fill-height`; `:pinned` is
  `:auto-hide nil`; the registration `:key` is `:shortcut`.
- `:width` and `:height` accept `(fraction F)`, a share of the parent frame.
- `:keep-alive` keeps an application running while its panel is hidden and
  `:on-stop` releases it; `etaf-posframe-app-quit` stops it explicitly.

- Panels hide while Emacs is inactive, so a window manager that lists child
  frames (macOS Mission Control) cannot offer them in place of the application
  behind them; `etaf-posframe-hide-inactive` turns it off.
- The panel border follows the mouse pointer: the panel under the pointer
  paints its hover accent without taking the keyboard, so hovering it and then
  clicking it changes nothing.  The position comes from the window system,
  which reports a child frame; a 0.2 s reading while panels exist clears the
  hint when the pointer leaves, because a pointer leaving a buffer runs no
  command.
- A click anywhere in a panel raises it above the other panels.  Emacs selects
the clicked child frame but leaves the stacking order alone, so a panel behind
another stayed covered even while it held the keyboard; only an explicit raise
puts it in front.
- The state border follows the theme's accent without the saturated outline: a
focused panel tints 60% toward the accent and a hovered one 30%, so hovering
hints and clicking commits instead of painting a bright one-pixel box in
either palette.  `etaf-posframe-border-focus-strength' and
`etaf-posframe-border-hover-strength' set those two strengths.
- `:theme-mode` pins a panel (or a registered application) to `light` or `dark`:
the panel keeps that palette when the Emacs theme changes.  The default `auto`
follows the Emacs theme as before.  The palette carries `:ui-mode`, so a View
with its own light and dark palettes can follow the panel's mode.
- The title bar keeps the panel surface: a 3% tint and one hairline below it
read as chrome, and the bar clears the theme's `header-line` box, so a light
theme no longer draws a dark strip inside a dark outline above the panel.
- `etaf-posframe-focus-follows-mouse` focuses the panel under the pointer.  It
  defaults to nil, so a resting pointer does not move the keyboard away from
  another window.

- `:offset` shifts a panel by `(ROWS . COLUMNS)` character cells from whatever
  `:at`, `:cell` or `:stack` chose, so a caller writes "centred, one row up"
  instead of counting a position; a function may compute the pair.
- The focus border follows the real selection, so clicking a panel or the frame
  behind it moves the accent, not only the cycling command.

- The title bar keeps the panel's own surface colors and fills every column in
  a theme whose `header-line` face is inverted, instead of showing an inverted,
  partly filled bar.
- A panel whose frame is resized from outside becomes that wide: the View is
  laid out again, the content reflows, the title bar repaints to the new column
  count and the height follows the new content.  The width is remembered across
  `etaf-posframe-refresh' instead of snapping back to the opening columns.
- Closing a focused panel hands the window system's input focus back to the
  frame it was opened from.  `select-frame' alone left macOS without a key
  window, so the next command froze until the user clicked the parent frame.
- `:fill t` keeps a panel at its row budget instead of shrinking to its content,
  for applications whose board has a fixed size; the surface paints the rest of
  the stage.
- A row budget taller than the parent frame is clamped so the panel stays on
  screen.
- The panel holding the input focus paints its border in the Theme accent, so
  the active application is visible among several open panels;
  `:focus-border-color` overrides it and nil turns it off.
- `etaf-posframe-cycle' walks the input focus through the open panels and back
  to the frame behind them, so one key switches between the applications and the
  buffer they float over.
- Applications register once with `etaf-posframe-register-app' and open with one
  `etaf-posframe-app' call; `etaf-posframe-app-prefix' dispatches the registered
  shortcuts, so a caller writes one line per application instead of its own
  command, session bookkeeping and repeat guard.
- A dark panel paints the flat near-black surface family that dark
  applications use (the NetEase player's `#191a1c`), so a panel and such an
  application read as one design; the frame paint matches the canvas, so no
  second colour shows at the edges.  `etaf-posframe-dark-shade',
  `etaf-posframe-dark-surface' and `etaf-posframe-surface-lift' tune it.
- Panels draw a one pixel border in the Theme's panel border colour, so they
  read as surfaces above the buffer.  `:border-width` and `:border-color` change
  it; the border is painted outside the text area, so the content keeps its
  width.
- `:stack t` with an anchor `:at` places a new panel clear of the panels already
  at that anchor, one gap below (or above, for a `bottom-*` anchor).
- A resize re-fits at the next timer tick instead of after 50 ms, so dragging a
  panel edge no longer shows a stretched old layout for long.
- A returned panel prints as one readable line.  Its Runtime and Theme ref
  used to live in the struct, so printing the value of an
  `etaf-posframe-show` call (`C-x C-e`, a log line) followed a cycle.
- A panel that would fit itself more than 20 times in a second backs off for
  two seconds and reports it, so a condition that keeps resizing it cannot
  spin the CPU.
- `:height` is the row budget the View lays out for, and it caps the frame: a
  View that fills its viewport, such as a whole application, no longer
  stretches the frame to the measuring height (a 110x30 panel stayed 770x6416).
- A frame resized from outside also adopts a new height as the row budget, so a
  taller panel of a viewport-filling View shows more rows.  A card with
  intrinsic height stays as tall as its content.
- A style switch in the Pomodoro example keeps the width the user gave the
  panel, so a resized panel does not snap back to the example's columns.
- Document hosting a complete app in a panel; `etaf-ncm` opens this way with
  `etaf-posframe-show` over `etaf-ncm-view`.
- Cover the panel surface with tests that pin the frame to the canvas: exact
  content width, no empty rows below a short panel, an outside resize adopting
  its width and its rows, and the title bar painting every column.

## 0.1.0

- First release: `etaf-posframe-show`, `etaf-posframe-hide`,
  `etaf-posframe-toggle`, `etaf-posframe-panels`, `etaf-posframe-live-p` and
  `etaf-posframe-theme`.
- Panels mount an ETAF View in a child frame, size the frame from the rendered
  content, hide before the next outside command, and support focus, pinning,
  header-line dragging, a timeout and an `on-close` callback.
- `:auto-focus` selects a focusable panel on open and hiding restores the
  previous frame; `q`, `ESC` and `C-g` close it from inside the panel.
- One panel per buffer: showing another replaces the first, and killing the
  parent buffer hides its panel.
- Panels follow the Emacs theme: loading a theme re-derives the palette and
  restyles live panels, including the title bar.
- Frame height follows the rendered pixels, so rows taller than the canonical
  line are not clipped; trailing blank rows are trimmed.
- Add `frame-top-right` and `frame-bottom-right` anchors and a pointer-free
  panel surface (no cursor).
- Ship the symbol card and the three-style Pomodoro examples under `examples/`.
