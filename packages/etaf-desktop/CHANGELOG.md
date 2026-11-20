# Changelog

All notable changes to ETAF Desktop are documented here.

## [0.1.7] - 2026-10-24

### Fixed

- A desktop embedded with `:fit 'region' now keeps its workspace bar, canvas
  and taskbar inside the window that hosts it after that window shrinks. The
  shell's size bindings started from the canvas the desktop was created with
  and never followed the region, so a nested desktop whose hosting window got
  smaller laid its taskbar out below the visible window and the bar vanished.

## [0.1.6] - 2026-10-24

### Fixed

- A desktop without explicit dimensions now takes the render surface's pixel
  width for its canvas. It used to take the display-safe window width, two
  characters narrower, while the shell stretched to the surface: the workspace
  bar reached the right edge and the canvas, together with every maximized
  window, stopped short of it.



### Fixed

- Every control a desktop owns carries the desktop's own Host reference
  namespace: the layout and settings controls, the launcher entries, the
  taskbar launcher and the close dialog. Two desktops mounted in one buffer — a
  desktop embedded in another desktop's window — no longer shadow each other,
  so a press or a focus on the outer desktop's control no longer acts on the
  inner level's.

- A desktop created with `:fit 'region' fills the surface it is rendered into
  edge to edge. Its canvas takes the region's pixel width and every row above
  its own taskbar, instead of leaving a band on the right and an empty row at
  the bottom.

`etaf-desktop-state` reports the desktop's `:token`, the namespace of its Host
references: its own controls are `<token>-<name>` and its application windows
are `<token>/<instance-id>/<window-id>`.

## [0.1.4] - 2026-10-24

### Added

- `etaf-desktop-create` accepts `:fit 'region'`. A desktop embedded with
  `etaf-desktop-view` in another application's window then follows that window
  body through `etaf-viewport`, so moving, resizing or maximizing the hosting
  window reflows the desktop and its windows like any application view that
  fills its window. The desktop keeps one cell clear on each side and one row
  at the bottom for the window's resize strips.

- Application instance window IDs are `<token>/<instance-id>/<window-id>`. The
  per-desktop token keeps ETAF Host references unique when desktops embed each
  other, and makes the owning desktop readable from a window ID.

## [0.1.3] - 2026-10-24

### Fixed

- A desktop nested in another desktop's window no longer takes over the host
  buffer's window fit. An application embeds `etaf-desktop-view` in one of its
  windows, so several desktops can share one buffer; resizing the Emacs window
  still refits the enclosing desktop, while a nested desktop keeps the explicit
  canvas it was created with.

## [0.1.2] - 2026-10-20


### Changed

- `?` shows searchable, read-only help inside the Desktop buffer, preserving
  its windows and focused content. Escape and backdrop dismissal close only
  the top help layer; use `M-x etaf-palette` to execute commands by name.

### Fixed

- `etaf-desktop-open` displays the desktop in the current Emacs window instead
  of letting display rules create a side pane. Existing windows stay intact.
- A pointer press on application content no longer leaves a cursor block
  behind, while keyboard navigation keeps the native cursor that marks the
  focused row. Every mounted ETAF view follows the input modality itself, so
  the desktop no longer keeps a cursor hook of its own.
- Desktop background uses an arrow pointer while retaining outside-click
  dismissal. Window body focus no longer implies a hand pointer.
- Floating windows expose all four resize edges and four corners. Side and
  bottom grips are transparent pointer targets on the outermost body cells, so
  they stay draggable while the application's own background and content reach
  the window edges.

### Added

- Full keyboard operation through ETAF's key layer: Tab reaches the workspace
  bar, window controls, tiling dividers and taskbar; `M-`arrows move and
  `M-S-`arrows resize the focused window; arrows move a focused divider; Esc
  closes the launcher, switcher, settings and close card; `?` lists commands.
  Tab entering a window activates it, and `n`/`p` move keyboard focus into the
  window they raise.

- `etaf-desktop-demo-open` (examples/etaf-desktop-demo.el) mounts a
  standalone demo desktop with six sample applications — Notes, Tasks,
  Clock, Calculator, Chat and Monitor — spread over two workspaces. Each
  application is one Component on a shared header/body/footer surface plus a
  manifest entry, so it doubles as the template for new applications.

- Selectable desktop themes. `etaf-desktop-define-theme` registers a named
  light or dark token set; `daylight`, `paper`, `midnight`, `forest` and
  `graphite` are built in and `etaf-desktop-themes` lists them. The `:theme`
  setting accepts `system`, `light`, `dark` or a theme name, and the
  Appearance tab offers every registered theme. `:accent-color` now defaults
  to nil, meaning the theme's own accent; a `#RRGGBB` value overrides it.
  Theme changes repaint the mounted shell in place, and an open launcher,
  switcher or settings dialog dims the desktop behind it while the dialog
  keeps its own theme colors. `etaf-desktop-theme-tokens` exposes the resolved
  colors for companion applications and tests.

- A default desktop now follows its Emacs window. Resizing the window refits
  the shell frame, tiled and monocle workspaces, maximized windows and
  floating windows in one batch through retained bindings, and
  `etaf-desktop-fit-canvas` runs the same refit on demand (for example after
  `split-window` in batch Emacs).

### Changed

- Opening settings, the launcher, the switcher or the close confirmation no
  longer restyles shell tokens to simulate dimming: the shared modal backdrop
  dims the painted desktop, application content and images included, and the
  shell paint returns when the modal closes.

- Desktop shortcuts are ETAF Host keys on the shell instead of a buffer-local
  overriding keymap. Keys bound by focused application content now take
  precedence, and shortcuts are suspended while a dialog is open.
  `:keybindings` now rejects sequences starting with a printing key (such as
  `"g n"`) and bindings that prefix another; rebind them to a single key or a
  sequence such as `"C-c n"`.

- The desktop runs on ETAF's retained runtime: moving, resizing and focusing
  a window update only the affected buffer lines, and opening or closing a
  shell surface no longer re-renders the desktop. The public desktop API is
  unchanged.
- Settings tab changes retain the dialog controls and callbacks while replacing
  the active field grid; selection, height and guidance update independently.
- New desktops inherit the Emacs font size for window titles and application
  content instead of forcing 14 CSS pixels (10.5 points). Appearance font
  fields show "Emacs default" or offer to restore it for an existing override,
  instead of offering arbitrary larger sizes on Emacs's shared text rows.
  Explicit and saved numeric overrides remain CSS pixels.

- Closing, focusing or restacking one window re-renders only the windows
  whose shell facts changed; other window surfaces stay retained. The batch
  close workload drops from about 158 to 145 ms.
- Opening or closing the launcher re-renders only the launcher surface
  instead of the whole desktop shell, cutting the batch launcher toggle on
  the four-window benchmark from about 335 ms to about 125 ms.

- Structural window changes under a tiling or monocle layout publish once:
  the layout reflow and its divider republication now run inside the same
  reactive batch as the structural change instead of as a second publication.

- Performance workloads (`benchmarks/performance-scenarios.el`, version 4)
  measure a default desktop that fills the benchmark window in GUI mode, as a
  user's desktop does; batch Emacs uses a fixed full-frame canvas. The four
  windows are placed on a grid derived from that canvas, and the recorded
  environment includes the canvas actually measured. Baselines recorded with
  the earlier fixed 900×30 canvas are incomparable and must be re-established.

### Fixed

- The minibuffer and echo area borrow window lines without shrinking or
  reflowing the canvas: the desktop keeps the canvas it committed until the
  prompt closes.
- Changing an existing split between columns and rows now updates its divider
  label and mouse pointer together with the new geometry.
- Demo applications scroll their body content when resized, keeping the app
  header and footer actions visible instead of clipping longer content.
- Clicking a maximized window's title without dragging keeps it maximized;
  unchanged gesture proposals focus the window without changing its geometry.
- Tiled `x` swaps now exchange layout leaves and preserve split ratios; `s` and
  `x` skip hidden and minimized windows. Repeated `n`/`p` visits every visible
  window without focus raises changing the traversal order.
- The close shortcut honors the configured in-desktop close confirmation.
- Left/right and top/bottom divider drags begin at their actual visible edge
  after minimum or maximum size constraints. Master-stack ratios survive focus
  changes and workspace refreshes.

- Resizing the Emacs window now refits windows on every workspace. Floating
  windows parked on an inactive workspace previously kept their old canvas
  geometry and reappeared off-canvas when that workspace was switched to.
- Tiling two workspaces at once no longer fails with a duplicate
  `desktop-splitter-nil` key: every workspace's dividers share the canvas,
  so their keys now carry the workspace.

- The Layout tab's "Window layout" select shows the active workspace's
  current mode. It read the `:layout-mode` preference, which the bar
  control, the `l` shortcut and workspace switches never write, so it kept
  showing "Floating" for a tiled workspace. The bar label also names
  `master-stack` ("Master") and `monocle` modes instead of "Floating".
- Pressing anywhere outside the launcher, switcher or settings dialog closes
  it: window content, window controls, bar controls and shell background all
  dismiss the open modal, and a taskbar control that opens another modal
  swaps them in one press. Pressing the shell background no longer sets the
  mark through `mouse-drag-region`. The modals' own close requests close
  unambiguously instead of toggling, so a second dismissal in the same press
  cannot reopen them.
- Floating windows can be dragged past the left, right and bottom canvas
  edges again. `etaf-desktop-move-window` and the shell's move and resize
  gestures accept any integer position and keep at least 48 pixels of the
  window and its title row inside the canvas instead of signalling an error
  at the first negative coordinate, which aborted the drag and left the window
  wherever the pointer had last been tracked.
- Dragging a tiling divider follows the pointer one row or pixel at a time.
  The split allocation rounded half values to even, so on an odd span every
  other step produced the same pane size and the divider stuck for one step
  and then jumped two.

- The Applications launcher lists every registered application by title
  (with its icon when declared) and shows whether it is running and how many
  windows it owns. The launcher and window switcher open centered over the
  retained desktop instead of covering it with an opaque backdrop.
- Dragging a tiling divider now follows the pointer one-to-one. Each motion
  applies the displacement from the press to the ratio the drag started from,
  so the divider no longer runs ahead of the mouse, and a cancelled drag
  restores that start ratio.

### Changed

- Desktop Settings is one card with a tab row and a labelled two-column
  form. Theme, layout, drag-lock modifier and taskbar grouping are chip or
  dropdown selects, numbers are `[−] value [+]` steppers and booleans are
  On/Off switches, so choosing a theme no longer opens the minibuffer.
- "Confirm before closing" asks through an in-desktop "Close window?" card
  with Cancel and Close window actions instead of a `yes-or-no-p` prompt.
- Themes follow the ETAF UI tonal control palette: `:ui-button-secondary-*`
  tints controls with the theme accent, and the `:ui-button-*-border`,
  `:ui-selection-*`, `:ui-checkbox-*-bg`/`-border` and
  `:ui-button-ghost-bg` tokens are no longer part of a theme. Custom themes
  that set them are still accepted; the values are ignored.
- Switching workspaces, including through `etaf-desktop-focus-window` on a
  window of another workspace, publishes through retained cells. Every
  workspace's windows and tiling dividers stay mounted; the active workspace
  is a reactive source that shows or hides them, updates the workspace bar
  and layout label and focuses the highest visible window. The desktop tree
  is no longer rebuilt on a switch. The taskbar now lists the windows of
  every workspace, not only the active one.
- Tiling layouts publish window rectangles and divider positions, labels and
  visibility through retained geometry cells. Ratio drags, focus changes,
  maximize and minimize under tiling update the affected windows in place;
  the desktop tree is rebuilt when a divider appears or changes direction.
  Performance scenarios `etaf-desktop.policy.tiled-{focus,maximize,minimize,close}`
  cover these paths.

- Toggling between floating and tiling layouts publishes through retained
  bindings. The workspace bar label reads a reactive source, tiling divider
  overlays stay mounted and hide through their visibility cells, and
  `etaf-desktop-set-layout-mode` batches the label and geometry writes, so a
  toggle keeps the committed generation once its dividers exist. Requires
  ETAF's prepared bindings under a reactive Theme.

- Window shells and taskbar items receive each window's mode, visibility and
  taskbar state as retained reactive sources, so maximizing, minimizing or
  restoring a window publishes through prepared Host bindings instead of
  rebuilding the desktop tree. `etaf-desktop-layout-mode` is now a pure
  query that no longer resynchronizes layout membership; mutation entry
  points still call `etaf-desktop-layout-refresh`.

- The configured drag-lock modifier now applies to all resize handles as well
  as the title. Locked resizing confirms at the next press. Explicit user
  cancellation restores the starting rectangle through the controlled
  geometry writer; target invalidation and unrelated input retain the last
  accepted geometry without restoring a replacement window.

- Tiled workspaces now default to one cell of outer and inner spacing.
  Configure `:tile-outer-gap` (0–4 cells) and `:tile-inner-gap` (1–4 cells)
  through Desktop Settings or `etaf-desktop-set-setting`; changes reflow the
  active workspace immediately and persist in saved sessions. Set the outer
  gap to zero for tiles flush with the canvas. Divider handles stay centered
  within inner gaps, and outer gaps shrink to preserve pane minimum sizes.

- Desktop Settings now groups appearance, layout, behavior and shortcuts into
  tabs in a compact panel, with Done and Reset settings actions.

- Session snapshots now persist each workspace's layout mode, split tree and
  floating membership, so restore keeps tiling topology and ratios.

- An implicit launch of an application without the `multiple-instances`
  capability focuses its running instance instead of creating a second one.
  Session restore still passes explicit instance ids and recreates every
  recorded instance.

### Fixed

- Session restore preserves floating rectangles, fixed-size windows and tiles
  compressed below their preferred minimum dimensions on small canvases.

- Closing an embedded Desktop View no longer unmounts its host application or
  kills the caller's buffer. Direct mounts and Playground cleanup now share the
  same Runtime ownership rule.

- Minimizing or closing the active window selects a visible replacement and
  keeps application status aligned with the focused window. A maximized tiled
  window keeps its full rectangle while other tiles change. Switching layout
  modes exits temporary maximization so the new tiles remain visible.

- An inactive desktop window renders gray traffic lights and only the active
  window keeps the colored macOS lights.

- Tiling layouts reserve their divider row or column, so the splitter is
  visible between tiles and never covers the second window's title bar.  The
  reserved cells are asserted by the layout acceptance cases.

- Tiling dividers use the same allocated gap as their adjacent windows.
  Nested dividers now render at each subtree's position and size, so their
  overlays remain visible without covering another window's title bar.

- A desktop without explicit `:canvas-width`/`:canvas-height` measures the
  Emacs window that displays it, so the mounted surface fills the visible
  window body instead of whichever window happened to be selected first.
