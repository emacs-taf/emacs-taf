# ETAF Desktop manual

ETAF Desktop is a controlled application layer. A desktop controller owns
reactive window and workspace state. Public queries return detached snapshots;
floating moves and resizes publish their geometry and focus changes together
to ETAF observers. The mounted View supplies that state to ETAF UI's
`etaf-window`, which forwards geometry and gestures to Ebox.

`M-x etaf-desktop-open` opens the desktop buffer in the current Emacs window.
It does not create a side pane or close other Emacs windows; ordinary
`display-buffer` routing rules do not move it elsewhere.

Create a controller with `etaf-desktop-create`, add windows with
`etaf-desktop-open-window`, and mount it with `etaf-desktop-mount`. A window's
`:view` is caller-owned content. The controller owns its identifier, rectangle,
size limits, workspace, visibility, minimized/maximized mode and z-index.

```elisp
(let ((desktop (etaf-desktop-create :workspaces '(main dev))))
  (etaf-desktop-open-window
   desktop 'editor :title "Editor" :x 2 :y 1 :width 70 :height 20
   ;; A window is seamless; the application keeps the frame margin clear.
   :view (etaf-view (box :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                         (text "Application content"))))
(etaf-desktop-mount desktop))
```

With no explicit `:canvas-width` or `:canvas-height`, the mounted surface
measures the Emacs window that displays it before the first render, so the
workspace bar, canvas and taskbar fill the visible window body.  The desktop
keeps following that window: when Emacs resizes it, the shell frame, tiled
and monocle workspaces, maximized windows and floating windows on every
workspace (including inactive ones) refit in one batch through retained
bindings, without re-rendering the desktop tree.
`etaf-desktop-fit-canvas` runs the same refit on demand, for example after
`split-window` in batch Emacs where no redisplay hook fires.  Pass explicit
dimensions when a desktop embeds a fixed-size surface or when tests need
deterministic geometry.

Several desktops can share one buffer, because an application embeds a desktop
View in one of its windows.  A desktop created with `:fit 'region' follows the
window body it is rendered into through `etaf-viewport`: moving, resizing or
maximizing the hosting window reflows that desktop and its windows, and the
canvas fills the surface edge to edge — the desktop's own workspace bar and
taskbar are the only rows it does not use for windows.  A desktop with explicit
dimensions keeps the canvas it was created with, and every desktop mounted in
the buffer still follows the Emacs window that displays it, taking the render
surface's pixel width so its bar, canvas and maximized windows share one right
edge, and resizing refits the outer desktop as well.

The mounted desktop hides that buffer's header and mode lines so its workspace
bar, canvas and taskbar occupy the complete visible body.  Application status
and actions belong in the desktop shell or in the active application's own
surface.  The native cursor is hidden only when it covers a rendered image,
where it would outline an entire image row.  Text, launchers and menus retain
their normal navigation cursor; ETAF UI text fields retain their editing caret.
Moving off the image, switching buffers or unmounting restores the window's
previous cursor visibility.  Cursor shape and global blink preferences are
unchanged.

`etaf-desktop-move-window` and `etaf-desktop-resize-window` are the single
state update paths used by ETAF's controlled geometry Behaviors. Resize is
clamped to each window's minimum and optional maximum, and Ebox pixel deltas
are converted to desktop text-row units before application state is changed.
The built-in shell exposes all four edges and four corners. Side grips are
six pixels wide and the bottom grips occupy one text row; content is laid out
inside them so resizing cannot cover application controls. The top grip is
at the right end of the title row, beside the top-right corner; dragging the
rest of the title bar moves the window. Left/right grips show a horizontal
resize pointer and top/bottom grips show a vertical one. Desktop background
and ordinary window body space use the arrow pointer; child controls choose
their own pointer. `M-S-<arrow>` from anywhere inside a focused window resizes
through the right/bottom handles. The configured drag-lock modifier applies to both
the title and every resize handle: the first release keeps tracking, and the
next primary-button press confirms at that press's position. The default is
Shift; Desktop Settings → Behavior → Drag lock modifier can select Super.
An explicit Escape cancellation during locked resize, or C-g during resize,
restores the starting rectangle. Unrelated input or target invalidation keeps
the last accepted geometry; a replaced window is never restored by an old
gesture. Generic ETAF Behaviors retain their caller-owned cancel semantics.
The desktop package uses Ebox's event loop and the existing controlled geometry
writer; it does not introduce a second input or geometry authority.
A title press/release without displacement focuses the window and preserves its
rectangle and maximized state. Unchanged gesture geometry proposals do not act
as explicit move or resize requests.

`etaf-desktop-maximize-window` saves the normal rectangle and fills the desktop
canvas. `etaf-desktop-restore-window` returns that rectangle. Minimized windows
become invisible and are listed by the taskbar; restoring them makes them
visible and active. `etaf-desktop-focus-window` raises a window and switches to
its workspace. Workspaces are application state: removing one moves its windows
to a remaining workspace and the final workspace cannot be removed. Every
workspace's windows and dividers stay mounted; `etaf-desktop-switch-workspace`
shows the target workspace, hides the others, focuses its highest visible
window and updates the workspace bar through retained cells, so the mounted
tree is not rebuilt. The taskbar lists the windows of every workspace, and
activating another workspace's entry switches to it.

## Desktop Settings

The workspace bar's Settings action opens an in-buffer ETAF UI dialog as a
root-layer projection, so the existing desktop remains visible underneath.
On a graphical Emacs viewport the panel is centered, limited to the visible
canvas and scrollable. A row of Appearance, Layout, Behavior and Shortcuts
tabs sits above a two-column form: each setting's name is in the left
column and its control in the right. Choices with a few options (theme,
layout, drag-lock modifier, taskbar grouping) render as selectable chips
and longer lists as a dropdown; numbers use `[−] value [+]` steppers whose
value pill also accepts a typed number; booleans are On/Off switches.
Font size fields display "Emacs default". If a restored session or an API
caller has set an explicit size, the field shows its CSS pixel value and a
"Use Emacs default" action. This restores each size independently; Reset
settings restores all defaults. The form does not offer arbitrary larger
sizes that could expand Emacs's shared physical text rows.
Appearance controls theme, accent and fonts; Layout controls layout mode and
tile spacing; Behavior controls drag locking, resize availability, close
confirmation and taskbar grouping. Shortcuts configures focus traversal,
launcher, switcher, layout, split, swap, maximize, minimize and close
bindings. Done closes the panel; Reset settings restores defaults. Session
restore remains an explicit
`etaf-desktop-save-session`/`etaf-desktop-restore-session` workflow.

When "Confirm before closing" is on, a window's Close control and the close
shortcut open a "Close window?" card inside the desktop instead of a
minibuffer prompt. Cancel, Escape or a press outside the card keeps the
window; "Close window" removes it. The pending request is desktop state:
switching workspaces or closing the desktop discards it.

`etaf-desktop-settings` returns a detached plist. Use
`etaf-desktop-set-setting` for validated changes or
`etaf-desktop-reset-settings` to restore defaults. Settings are included in
`etaf-desktop-session-state`; invalid persisted values are rejected through the
same public validator during restore.

By default, window titles and application content use the current Emacs font
size. Title and content overrides are independent and use CSS reference pixels,
not points: 16 pixels is 12 points. For example:

```elisp
(etaf-desktop-set-setting desktop :content-font-size 16) ; 12 points
(etaf-desktop-set-setting desktop :content-font-size nil) ; inherit again
```

Controls inside applications inherit the content font unless an application
explicitly styles them. Desktop Settings and the other desktop panels inherit
the Emacs font independently of application title/content overrides. Saved
numeric preferences remain explicit overrides when restoring a session; use
"Use Emacs default" or reset settings to restore inheritance. Explicit sizes
still obey Ebox's shared text-row constraint for positioned windows.

### Themes

A desktop theme is a named set of ETAF Theme tokens that paints the shell
(bars, canvas, window chrome, dividers) and the dialogs above it. Built-in
themes are `daylight` and `paper` (light) and `midnight`, `forest` and
`graphite` (dark); `etaf-desktop-themes` lists them in order. The `:theme`
setting selects one by name, or `system` (the first built-in theme matching
the Emacs frame's light or dark mode), `light` or `dark`. `:accent-color`
is nil by default, which keeps the theme's accent; a `#RRGGBB` string replaces
the accent and its derived tints. The Appearance tab exposes both controls.

Theme and accent changes repaint the mounted desktop through Theme paint
slots without re-rendering windows, and while the launcher, switcher or
settings dialog is open the shell is dimmed behind the dialog. A floating
panel that frames the desktop offers `亮` / `随` / `暗` in its title bar; its
switch writes the same `:theme` setting, so it repaints the desktop and its
windows instead of only the panel chrome. Applications in desktop windows
also receive the desktop's resolved light or dark polarity through
`etaf-appearance`, so a client that follows its host paints with the desktop
theme rather than the Emacs frame's. Register a custom theme before mounting
or at any later time:

```elisp
(etaf-desktop-define-theme
 'harbor :label "Harbor" :mode 'dark
 :tokens '(:ui-shell-bg "#10202B" :ui-canvas-bg "#152A36"
           :ui-window-bg "#1B3442" :ui-accent "#5DD3C8"))
(etaf-desktop-set-setting desktop :theme 'harbor)
```

Omitted tokens fall back to the first built-in theme of the same mode.
`etaf-desktop-theme-tokens` returns the resolved plist so companion
applications can match the desktop's colors.

The default Desktop buffer map uses single letters because it is local to the
Desktop surface: `n`/`p` focus next/previous, `a` opens Applications, `w`
opens the switcher, `o` opens Settings, `l` toggles layout, `s` splits, `x`
swaps, `m` maximizes, `r` restores, `i` minimizes, and `q` closes the active
window. A modal or native input surface temporarily takes precedence.

Traversal uses stable window opening order, skipping minimized, hidden and
other-workspace windows. `s` pairs the active window with the next visible
workspace window in an equal left/right split. `x` exchanges it with the next
visible window in the same layout group: tiled windows swap places in the
layout tree while floating windows swap rectangles. Split topology and ratios
stay intact, and the active window keeps focus. With no other eligible window,
split and swap do nothing.

The launcher, switcher and settings dialog are unpainted modals: the shell
stays visible and dimmed behind them, and they close on Escape, on their
close control, or on any press outside their panel, including window
content, bar controls and shell background. A taskbar control that opens a
different modal closes the current one in the same press.

Read-only queries return detached plists: `etaf-desktop-state`,
`etaf-desktop-windows`, `etaf-desktop-window-state`,
`etaf-desktop-active-window` and `etaf-desktop-active-workspace`. Callers must
use the mutation functions rather than changing returned plists.

`etaf-desktop-close` unmounts the Runtime created by `etaf-desktop-mount` and
kills a buffer created by that call. An existing target buffer remains with its
caller. When embedding `etaf-desktop-view` in another ETAF application, the
caller owns the enclosing Runtime and buffer and unmounts them; closing the
Desktop controller leaves that shared surface mounted. Closing is idempotent.
A controller can be mounted only once at a time.

## Keyboard operation

Every desktop interaction is available from the keyboard through ETAF's
shared key layer; the desktop adds no global Emacs bindings.

| Keys | Action |
| --- | --- |
| `n` / `p` | Raise the next or previous visible window and focus it |
| `a`, `w`, `o` | Toggle the launcher, window switcher or settings |
| `l`, `s`, `x` | Toggle layout mode, split, swap with the next window |
| `m`, `r`, `i`, `q` | Maximize, restore, minimize, close the active window |
| Tab / S-Tab | Move between the workspace bar, windows, dividers and taskbar |
| Arrows, `C-n`/`C-p`/`C-b`/`C-f` | Move within a group or to the nearest control |
| `M-`arrows / `M-S-`arrows | Move / resize the window holding focus |
| Arrows on a divider | Move a tiling split |
| Esc | Close the innermost open surface |
| `?` | Show searchable, read-only key help in this Desktop buffer |

Help uses the current application's effective bindings and the Desktop keys
that remain reachable. It opens inside the same buffer without splitting an
Emacs window or changing desktop-window geometry. Escape first leaves search
editing, then closes help and restores the opening focus; clicking its backdrop
also closes only that topmost modal. Settings underneath remain open. Native
`C-g` stays an Emacs interrupt, not a dismissal command. Use `M-x etaf-palette`
when you want to execute a command by name rather than read its description.

The single-key shortcuts are configured in the Shortcuts tab or through the
`:keybindings` setting; a binding is a key or a sequence such as `C-c n` that
does not start with a printing key. They yield
to keys bound by the focused application's content, are suspended while text is
being edited and while a dialog is open. Tab entering a window activates it, as
a pointer press does. A window covered by another has no reachable controls
until it is raised, so use `n`/`p`, the switcher or the taskbar to reach it.

## Applications and instances

`etaf-desktop` is an application host. Register an application once with a
manifest, then launch one or more independent instances. The manifest's
`:open` callback receives a context plist and returns one window spec or a
`:windows` list. A spec uses the same public geometry options as
`etaf-desktop-open-window`; its `:view` remains application-owned.  A window
body reaches the window border, and the frame's resize strips cover its
outermost body row and columns, so an application view keeps that margin cell
clear of controls.

```elisp
(etaf-desktop-register-app
 'notes :title "Notes"
 :open (lambda (context)
         (list :state '(:document "welcome")
               :windows (list
                         (list :id 'main :title "Notes"
                               :view (etaf-view
                                      (box :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                                           (text "Welcome"))))))))
 :close (lambda (_context reason) (message "Notes closed: %s" reason))
 :serialize (lambda (context) (plist-get context :state)))

(let ((instance (etaf-desktop-launch desktop 'notes)))
  (etaf-desktop-focus-instance desktop (plist-get instance :id)))
```

A manifest without the `multiple-instances` capability is single-instance:
an implicit `etaf-desktop-launch` focuses its running instance instead of
creating a second one, while session restore keeps passing explicit instance
ids.  The host owns instance identity, lifecycle (`launching`, `active`,
`inactive`, `suspended`, `closing`, `closed` or `error`) and all window cleanup.
Applications may update their serializable state with
`etaf-desktop-set-instance-state`; they do not mutate desktop internals. A
callback error is isolated to that instance and produces a visible error
placeholder so the remaining desktop can continue operating.
`etaf-desktop-instances` and `etaf-desktop-instance`
return detached state snapshots.

An instance's windows carry its desktop's token, instance ID and the spec's
own ID: `<token>/<instance-id>/<window-id>`, for example `d3/etaf-manual-1/main`.
The desktop's own controls use the same namespace as `<token>-<name>`, for
example `d3-etaf-workspace-layout`. The token keeps ETAF Host references unique
when desktops are embedded in each other — otherwise two levels intern the same
names and a press or focus reaches the wrong one — and makes the owning desktop
readable from a window ID in logs and state queries.
`etaf-desktop-state` reports it as `:token`.

[examples/etaf-desktop-demo.el](../examples/etaf-desktop-demo.el) is the
runnable form of this contract: `M-x etaf-desktop-demo-open` registers six
sample applications, each one Component on a shared surface plus a manifest
entry with its launcher metadata and default window geometry. The shared application
surface fills the window body and reserves its header and footer toolbar; only
the bounded middle region scrolls when content exceeds the available height.
Resizing changes that viewport while title input and footer actions stay visible.
This scrolling policy belongs to the demo applications, not every Desktop window.
Launcher marks use ordinary ASCII from the inherited text font, avoiding
symbol-font fallback that could stretch a shared physical row.

`etaf-desktop-session-state` excludes View and Runtime objects. It records
desktop geometry, settings (including tile spacing), workspaces, instance
options, application-owned data from `:serialize`, and every workspace's layout
mode/tree/split ratios and floating membership. `etaf-desktop-save-session`
writes this plist. `etaf-desktop-restore-session` invokes the registered
`:restore` callback, reapplies saved window state, then restores the saved
layout policy. If an application is no longer registered, its instance is
restored as an error placeholder instead of aborting the session. Sessions
written before layout records were introduced remain readable.

## Workspace layout policy

Each workspace can use `floating`, `tiling`, `master-stack` or `monocle` mode.
Floating windows keep their own rectangles and may be dragged past the left,
right and bottom canvas edges; the canvas clips the overflow while at least
48 pixels of the window and its title row stay inside it, so a window can
always be grabbed again. Tiling uses a detached layout tree
whose leaves are window IDs and whose split nodes have an orientation and ratio:

```elisp
(etaf-desktop-set-layout-mode desktop 'tiling)
(etaf-desktop-layout-split desktop 'editor 'terminal 'horizontal 0.65)
(etaf-desktop-layout-resize-split desktop nil 0.55)
```

`horizontal` splits divide width from left to right; `vertical` splits divide
height from top to bottom. The allocator observes each window's minimum and
maximum dimensions where the canvas permits. `master-stack` gives the first
visible window a wide master region and stacks the remaining leaves vertically.
Adjusted master-stack ratios survive focus, workspace switches and ordinary
refreshes. Adding a window retains the master width ratio and redistributes the
stack; removing the master promotes a remaining window.
`monocle` keeps the tree but gives every leaf the inset canvas rectangle and
raises the focused window, allowing a quick return to tiling.

Tile spacing defaults to one cell around the canvas and between panes. A cell
is one frame character width horizontally and one text row vertically; a
horizontal inner gap normally reserves at least three pixels for its divider.
Outer gaps shrink when the canvas needs that space for pane minimum sizes.
If those minimums still cannot fit, the allocator reduces pane sizes and inner
gaps as needed to keep panes inside the canvas where possible. Divider handles
stay centered and confined to their gaps, including in nested trees; a gap
reduced to zero has no handle. Splitter gestures change the ratio within that
split's own span, starting from its visible edge even when minimum or maximum
sizes constrained the requested ratio. Cancelling restores the requested ratio
from the start of the gesture. Both left/right and top/bottom dividers use this
policy. Monocle uses the same outer spacing without reserving inner
gaps for its retained split tree.

Use Desktop Settings or the public settings API to adjust spacing. For example,
this removes the outer margin and leaves two cells between tiled panes:

```elisp
(etaf-desktop-set-setting desktop :tile-outer-gap 0)
(etaf-desktop-set-setting desktop :tile-inner-gap 2)
```

Each change immediately reflows the active tiled workspace, preserving its
split tree and ratios. Other workspaces apply the current gaps when selected.
Floating windows retain their rectangles, and maximized windows retain the
full canvas until restored. Gap preferences are saved and restored with the
session settings. The [public API inventory](../etaf-desktop.el) specifies the
accepted integer ranges and error behavior; invalid values are rejected without
changing the setting or geometry.

`etaf-desktop-layout-tile-window` and `etaf-desktop-layout-untile-window`
control individual leaves. An explicitly untiled window remains a floating
overlay while other leaves reflow. Closing a window removes its leaf and
collapses empty split branches. The runtime invokes
`etaf-desktop-layout-refresh` after state publication, so a newly opened window
is inserted into an active tiling or master-stack workspace without a second
event loop. Applications that publish through a custom mutation path should
call the same refresh hook.

Maximizing a window temporarily fills the canvas without discarding its tiling
tree. Restoring that window returns it to the current layout. Changing a
workspace's layout mode exits the temporary maximized view and publishes the
new mode and window rectangles together, so all tiles become visible.

The title bar uses a macOS-style traffic-light control group on the left:
close is red, minimize is yellow and maximize/restore is green. The taskbar,
workspace bar, launcher, switcher and splitter are reusable ETAF UI components;
their callbacks call these desktop APIs while the application layer retains
window, focus and lifecycle policy.
