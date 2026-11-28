# Applications

An *application* is one named buffer showing one mounted View, with the lifecycle a user expects from a program: it opens in the selected window, fits its content to that window as the window changes, follows its theme in every cell, answers its own keys, and saves its state once when it goes away. This chapter defines the application lifecycle that `etaf-app-open` and `etaf-app-close` provide, how fitting, theming and keys work for an application, and the recovery rules when opening or closing fails. Running command-line backends belongs to [Asynchronous Model](async.md#subprocesses).

An application builds on the [Runtime](runtime.md): `etaf-app-open` prepares and displays a buffer, then calls `etaf-mount`. A Runtime alone is enough for a View embedded in another buffer or a test; an application adds what a top-level program needs around it.

<!-- index: application; application buffer; application lifecycle -->

## Model

An application has a name, which is also its buffer name, a View, and three optional pieces of behavior supplied as functions: a fit function that adapts the application's state to the display window, a close function that saves or releases what the application holds, and the theme colors of its canvas. The application also carries one opaque state value, usually the record or session object its commands work on.

Opening is one transaction: the buffer is prepared as a canvas, displayed, fitted and mounted, and a failure at any step closes the application again. Closing has three triggers, killing the buffer, `etaf-app-close` and reopening the same name, and each runs the close function exactly once while the View is still mounted.

## Opening and closing

#### Function: etaf-app-open (name view &key state on-fit on-close background foreground (cursor 'inherit) mode-line (display t) mount-options meta)

Open VIEW as the application buffer NAME and return the buffer.

**Arguments.**

- NAME is the buffer name. An existing buffer of that name that is not an open application is reused.
- VIEW is passed to `etaf-mount`: a normalized View or a zero-argument function returning one.
- STATE is any value; `etaf-app-state` returns it.
- ON-FIT is nil or a function of one argument, the display window. It runs with the application buffer current.
- ON-CLOSE is nil or a function of no arguments. It runs with the application buffer current.
- BACKGROUND and FOREGROUND are nil or a color: a color string, a ref, a computed or a zero-argument function returning a color string or nil.
- CURSOR is a `cursor-type` value, or `inherit` (the default) to keep the buffer's cursor.
- MODE-LINE is nil (the default) to hide the mode line, t to keep it, or a `mode-line-format` value.
- DISPLAY is t (the default) to show the buffer in the selected window, a function that receives the buffer and displays it, or nil to leave it undisplayed.
- MOUNT-OPTIONS is the OPTIONS plist of `etaf-mount`, or a function of the display window (nil when the buffer is not displayed) that returns it. A function runs in the buffer after ON-FIT, so options such as a fixed `:viewport-height` can come from the fitted state.
- META is an optional Runtime metadata plist (`:app`, `:kind`, `:uri`, `:title`, whose values may be static data, refs, computeds or zero-argument functions) merged into MOUNT-OPTIONS as `:meta` when MOUNT-OPTIONS does not already supply one.

**Semantics.** The steps run in this order.

1. An open application named NAME is closed first, with its close function.
2. The buffer is prepared as a canvas: lines are truncated, horizontal scrolling and scroll margins are off, line numbers are off and a truncated line shows no continuation glyph, so content wider than the window is clipped cleanly. CURSOR and MODE-LINE apply as described above.
3. BACKGROUND and FOREGROUND remap the buffer's default face, so the cells the View does not paint, such as the area below the last line, match the application's surface. A reactive color repaints when it changes, until the application closes.
4. DISPLAY shows the buffer. With t, the user's `display-buffer` rules cannot redirect it to another window or split the frame.
5. When the buffer has a window, ON-FIT runs once with that window, so the first render already uses fitted sizes.
6. VIEW mounts with MOUNT-OPTIONS, calling it first when it is a function.

After the mount, ON-FIT runs again after each settled change of the display window, as [Fitting to the window](#fitting-to-the-window) describes.

**Returns.** The application buffer.

**Errors.** Any error from a step, including `etaf-runtime-error` for invalid MOUNT-OPTIONS, View errors and a `quit` while opening, closes the application: the close function runs, the buffer is killed and the condition propagates.

**Example.** A notes application keeps a session object as its state, sizes its list in the fit function and saves on close.

```elisp
(defun notes-open ()
  (interactive)
  (let ((session (notes-session-create)))
    (etaf-app-open "*notes*" (lambda () (notes-view session))
                   :state session
                   :on-fit (lambda (window)
                             (notes-set-page-size
                              session (- (window-body-height window) 2)))
                   :on-close (lambda () (notes-save session))
                   :background (notes-theme-color session :bg))))
```

**See also.** `etaf-app-close`, `etaf-mount` and [Native application windows](runtime.md#native-application-windows).

#### Function: etaf-app-close (&optional buffer-or-name)

Close the application in BUFFER-OR-NAME, by default the current buffer, and return t.

**Semantics.** The close function runs while the View is still mounted, then the View unmounts and the buffer is killed. Interactively the command closes the application in the current buffer, so an application can bind it to `q` in its root `:keys`.

**Returns.** t.

**Errors.** `error→ user-error` when the buffer holds no open application. An error of the close function propagates after the buffer is gone; when the buffer is killed directly the same error is reported as a message instead, so `kill-buffer` itself never fails.

#### Property: :on-close

The teardown callback keyword of `etaf-app-open` and `etaf-pip-open`.

**Arguments.** Nil or a zero-argument function.

**Semantics.** Runs once with the application or PiP buffer current before the View unmounts and the buffer is killed, whether triggered by `etaf-app-close`, `etaf-pip-close`, killing the buffer or reopening the same name.

**See also.** `etaf-app-open`, `etaf-app-close`, `etaf-pip-open`.

## Finding an application

#### Function: etaf-app-state (&optional buffer-or-name)

Return the STATE of the open application in BUFFER-OR-NAME, by default the current buffer, or nil.

**Semantics.** A key command runs in the application buffer, so it finds its session with `(etaf-app-state)` instead of a buffer-local variable of its own. The close function still sees the state, so it can save the session it belongs to; once the close function returns, the call returns nil.

#### Function: etaf-app-buffer (name)

Return the buffer of the open application NAME, or nil.

**Semantics.** An entry command that should return to an open application rather than reopen it checks this first and selects the buffer it returns.

## Application declarations and registry

<!-- index: application registry; etaf-app-define; etaf-app-register; etaf-app-launch -->

Applications built on ETAF often run inside multiple hosts without knowing about any specific host: a standalone Emacs buffer (`etaf-app-open`), a desktop window manager, a floating child-frame panel or an interactive launcher. The application registry is a thin metadata and session-lifecycle contract that decouples applications from hosts: each application declares its identity, supported hosts, optional embeddable `:session` callbacks (`:create`, `:view`, `:close`) and layout hints, while hosts read the registry without hardcoding application names. Function fields accept unloaded symbols so packages can register manifests via `;;;###autoload` with `with-eval-after-load` at zero startup cost and load their `:feature` only when launched.

#### Function: etaf-app-register (id &rest spec)

Register or update ETAF application manifest ID from keyword plist SPEC.

**Arguments.**

- ID is a non-nil, non-keyword symbol identifying the application.
- SPEC is a keyword plist carrying required nonempty string `:title`, optional `:feature` symbol (defaults to ID), `:icon` string, `:category` (`media`, `reading`, `productivity`, `communication`, `game`, `system`, `utility` or `other`, default `other`), `:description` string, `:hosts` nonempty subset of `(buffer desktop panel pip)` (defaults to `(buffer desktop panel)` when `:session` is present, else `(buffer)`), `:open` callable symbol or function, `:session` keyword plist (`:create` and `:view` required callable refs, optional `:close`, `:keep-alive` and `:multiple-instances`), `:window` desktop geometry hint plist, `:panel` floating-panel hint plist, `:file-extensions` list of strings, `:capabilities` list of symbols and `:doctor` callable ref.

**Semantics.** Validates all keys and types eagerly, stores the normalized manifest in the global registry (replacing any previous registration for ID in place) and runs `etaf-app-change-functions` with `(register ID ENTRY)`. Declaring `desktop` or `panel` in `:hosts` requires a valid `:session` plist.

**Returns.** A detached copy of the normalized manifest plist.

**Errors.** `error→ etaf-runtime-error` on invalid ID, unknown keys, missing `:title`, unsupported `:hosts` or `:category`, missing `:session` for embedded hosts, or non-callable callbacks.

#### Macro: etaf-app-define (id &rest spec)

Declaratively register ETAF application ID with keyword manifest SPEC.

**Semantics.** Expands to `(etaf-app-register 'ID SPEC...)` so packages can declare manifests concisely inside `with-eval-after-load 'etaf`.

**Returns.** The detached manifest plist returned by `etaf-app-register`.

#### Function: etaf-app-unregister (id)

Remove registered ETAF application ID from the registry.

**Semantics.** Removes ID when present and notifies `etaf-app-change-functions` with `(unregister ID nil)`.

**Returns.** t when ID was registered, nil otherwise.

**Errors.** `error→ etaf-runtime-error` when ID is not a valid application symbol.

#### Function: etaf-app-get (id)

Return a detached manifest plist for registered application ID, or nil.

**Returns.** A detached manifest plist or nil.

#### Function: etaf-app-list (&optional host category)

Return detached manifests of registered ETAF applications sorted by ID.

**Arguments.** Optional HOST filters by `:hosts` (`buffer`, `desktop`, `panel` or `pip`); optional CATEGORY filters by `:category`.

**Returns.** A list of detached manifest plists sorted alphabetically by ID.

**Errors.** `error→ etaf-runtime-error` when HOST or CATEGORY is non-nil and unrecognized.

#### Function: etaf-app-launch (id)

Launch registered ETAF application ID in a standalone buffer.

**Semantics.** Interactively prompts among registered applications. Loads `:feature` lazily via `require` if not yet loaded, then calls `:open` when declared; otherwise creates a session via `:session`'s `:create`, mounts `:view` with `etaf-app-open` (`:mode-line t`), and wires `:close` into `:on-close`.

**Returns.** The return value of `:open` or the opened application buffer.

**Errors.** `error→ user-error` interactively when no applications are registered; `error→ etaf-runtime-error` when ID is unknown or declares neither `:open` nor `:session`.

#### Hook: etaf-app-change-functions

Abnormal hook run with `(EVENT ID ENTRY)` when the application registry changes.

**Semantics.** EVENT is `register` or `unregister`, ID is the application symbol and ENTRY is a detached manifest plist (or nil on removal). Individual observer errors are isolated.

## Fitting to the window

<!-- index: fit; resize; display window; fixed viewport -->

An application fits its content in ON-FIT: page sizes, row budgets, column widths, or a fixed viewport for an application whose canvas has a natural size. The function receives the display window and reads its body size; it writes refs, and the View renders from them.

After the mount, ON-FIT runs once per settled change: Emacs reports window size changes many times during a drag, and the engine waits until they stop before refitting the Runtime. ON-FIT then runs inside one reactive batch, after the Runtime's own viewport has been updated, so the refit and the application's changes publish together. It runs when the display window's body width or height changes, when the buffer moves to another window, and when the text scale changes. It does not run when the minibuffer or an echo-area message temporarily takes lines from the window, because the space returns as soon as they close; refitting would make the content jump twice.

An application that mounts with a fixed `:viewport-width` or `:viewport-height` still receives ON-FIT, so it can call `etaf-refit` with new dimensions there.

## Theme and canvas

<!-- index: canvas; default face; application background -->

The View paints only the cells it draws. The rest of the window, such as the lines below a short View or the right edge of a narrow one, shows the buffer's default face. BACKGROUND and FOREGROUND make those cells match the application: pass the same theme colors the root Host uses, as refs or functions when the theme can change while the application is open. The remapping belongs to the application buffer only and ends when the application closes.

## Keys

<!-- index: application keys; root :keys -->

An application declares its commands in the `:keys` of its root Host, as [Keyboard](keyboard.md#host-keys) describes; it does not install a keymap of its own. Root keys appear in help, yield to nearer Hosts and modal scopes, and leave the framework keys intact. Two resolution rules make root keys sufficient for an application.

- RET on the root acts on the application's selection, yet a focused button nearer than the root still receives RET.
- A pointer event, such as `<wheel-down>`, resolves from the Host under the pointer, so a pane can scroll itself with its own wheel binding.

## Cross-application activities and notifications

<!-- index: activity; live activity; notification; cross-application protocol -->

Applications often need to report ongoing background work or transient events to shell surfaces such as a floating Dynamic Island, a desktop top bar or a screensaver without depending on any shell package. ETAF provides two reactive registries for this purpose: live *activities* for ongoing state (`media`, `timer`, `task`, `inbox`, `schedule` or `status`) and *notifications* for transient alerts. Producers publish plain data and action callbacks; shells subscribe through shared reactive refs without polling.

#### Function: etaf-activity-publish (id plist)

Publish or update live cross-application activity ID from PLIST.

**Arguments.**

- ID is a non-nil symbol, nonempty string or cons cell compared with `equal`.
- PLIST is a proper plist carrying `:title` (required nonempty string) and optional `:app`, `:kind` (`media`, `timer`, `task`, `inbox`, `schedule` or `status`, default `status`), `:state` (`active`, `paused` or `idle`, default `active`), `:priority` (number, default 50), `:subtitle`, `:compact`, `:icon`, `:tone` (`info`, `success`, `warning`, `danger` or `neutral`), `:progress` (plist), `:meter` (level-sampling function), `:actions` (list of plists each carrying `:id` symbol, `:label` string and `:fn` function), `:open` (zero-argument function) and `:owner-runtime` (mounted Runtime whose unmount removes ID automatically).

**Semantics.** When the payload matches the existing record for ID ignoring `:updated-at`, the update is a no-op so unchanged background polls avoid redundant repaints. Otherwise the registry updates `etaf-activity-ref` and runs `etaf-activity-change-functions` with `(publish ID ENTRY)`.

**Returns.** A detached copy of the stored activity plist.

**Errors.** `error→ etaf-runtime-error` on invalid ID, non-plist input, missing `:title`, unsupported `:kind`, `:state`, `:tone` or malformed `:actions`.

#### Function: etaf-activity-remove (id)

Remove live cross-application activity ID and return non-nil if it existed.

**Semantics.** Removing a present entry updates `etaf-activity-ref` and notifies `etaf-activity-change-functions` with `(remove ID nil)`.

**Returns.** t when ID was present, nil otherwise.

#### Function: etaf-activity-get (id)

Return a detached copy of live cross-application activity ID, or nil.

**Returns.** A detached activity plist or nil.

#### Function: etaf-activity-list (&optional kind)

Return ordered detached snapshots of live activities, optionally for KIND.

**Semantics.** Active entries precede paused entries, which precede idle entries; ties break by descending `:priority` and newest `:updated-at`.

**Returns.** A list of detached activity plists.

**Errors.** `error→ etaf-runtime-error` when KIND is non-nil and not a recognized activity kind.

#### Function: etaf-activity-ref ()

Return the shared reactive ref holding ordered live activity snapshots.

**Returns.** A read-only reactive ref updated whenever activities are published or removed.

#### Function: etaf-activity-invoke (id action-id)

Invoke ACTION-ID (or `open`) declared on live activity ID.

**Semantics.** Looks up `:open` when ACTION-ID is `open`, or the matching `:id` entry in `:actions`, and calls its function with no arguments.

**Returns.** The action function's return value.

**Errors.** `error→ etaf-runtime-error` when ID is unknown or declares no matching action.

#### Hook: etaf-activity-change-functions

Hook run with `(EVENT ID ENTRY)` when live activities change.

**Semantics.** EVENT is `publish` or `remove`, ID is the activity key, and ENTRY is a detached activity plist (or nil on removal). Individual observer errors are isolated.

#### Function: etaf-notify (title &key id app detail (variant 'info) (ttl 5.0) group actions)

Publish notification TITLE to ETAF shell consumers and return a detached entry.

**Arguments.**

- TITLE is a nonempty string.
- ID optionally supplies a stable identifier; omitted values receive a monotonic integer.
- APP is an optional source symbol.
- DETAIL is optional supporting text.
- VARIANT is `info`, `success`, `warning` or `danger` (default `info`).
- TTL is nonnegative seconds before auto-collapse (default 5.0; 0 disables auto-collapse).
- GROUP is an optional key compared with `equal`; a matching existing entry is replaced in place with an incremented `:count`.
- ACTIONS is an optional list of action plists (`:id`, `:label`, `:fn`).

**Semantics.** Prepends the entry to the bounded notification store, updates `etaf-notify-ref` and runs `etaf-notify-functions`. When `etaf-notify-functions` is empty in an interactive session, falls back to `message` so alerts are not lost.

**Returns.** A detached copy of the notification plist.

**Errors.** `error→ etaf-runtime-error` on empty TITLE, invalid VARIANT, negative TTL or malformed ACTIONS.

#### Function: etaf-notify-dismiss (&optional id)

Dismiss notification ID (or the newest entry when nil) and return remaining list.

**Returns.** Detached list of remaining notifications, newest first.

#### Function: etaf-notify-clear ()

Clear all stored ETAF notifications and return nil.

**Returns.** nil.

#### Function: etaf-notify-list ()

Return detached list of stored ETAF notifications, newest first.

**Returns.** A list of detached notification plists.

#### Function: etaf-notify-ref ()

Return the shared reactive ref holding stored ETAF notifications.

**Returns.** A reactive ref holding the detached notification list.

#### Hook: etaf-notify-functions

Hook run with `(ENTRY)` when `etaf-notify` records a notification.

**Semantics.** Individual observer errors are isolated. Installing at least one observer suppresses the echo-area `message` fallback.

## Floating Picture-in-Picture

<!-- index: etaf-pip-open; etaf-pip-close; etaf-pip-bounds; picture-in-picture; child frame -->

Video and monitoring applications often detach a compact always-on-top player while the user returns to another buffer. `etaf-pip-open` hosts any View inside a recycled floating child frame with a native-draggable adaptive header bar, a 4-pixel drag-resize border, focus-reactive border color, four-corner docking, S/M/L presets, and unpinned viewport synchronization so manual dragging adapts both layout and embedded GPU video layers smoothly.

#### Function: etaf-pip-open (id view &key title parent (size 'medium) (corner 'bottom-right) theme on-return on-close on-resize on-size-change on-corner-change)

Open a floating adaptive Picture-in-Picture window for symbol ID showing VIEW.

**Arguments.** ID is a non-nil symbol identifying the PiP host; VIEW is the mounted View. TITLE is a string, ref, computed or zero-argument function for the header bar. PARENT names the enclosing top-level frame (default selected frame). SIZE is `small`, `medium` (default) or `large`; CORNER is `bottom-right` (default), `bottom-left`, `top-left` or `top-right`. THEME is a color plist or zero-argument function supplying `:bg`, `:panel`, `:chip`, `:hover`, `:ink`, `:muted`, `:accent`, `:accent-soft` and `:border-inactive`. ON-RETURN, ON-CLOSE, ON-RESIZE, ON-SIZE-CHANGE and ON-CORNER-CHANGE are optional callbacks.

**Semantics.** Opening an ID that is already active closes the previous host first. On graphical frames the View mounts inside a recycled undecorated child frame without pinning viewport dimensions so Ebox and `etaf-pip-bounds` follow every edge/corner drag and synchronize native GPU video surfaces. In non-graphical sessions the View still mounts into its buffer with live bounds so tests exercise the full lifecycle.

**Returns.** The mounted PiP buffer.

**Errors.** `wrong-type-argument` when ID is not a non-nil symbol.

#### Function: etaf-pip-close (id &optional restore-focus)

Close floating Picture-in-Picture window ID and return non-nil if it was open.

**Semantics.** Runs ON-CLOSE once, unmounts and kills the PiP buffer, parks graphical child frames for safe reuse, and restores input focus to the parent frame when RESTORE-FOCUS is non-nil or the PiP frame held focus.

**Returns.** `t` when ID was active, nil otherwise.

#### Function: etaf-pip-active-p (id)

Return non-nil when floating Picture-in-Picture window ID is currently live.

**Returns.** `t` when active, nil otherwise.

#### Function: etaf-pip-bounds (id)

Return reactive live inner bounds plist of Picture-in-Picture window ID.

**Semantics.** Returns `(:width-px W :height-px H :cols C :rows R :cell-w CW :cell-h LH :size SIZE :corner CORNER)` or nil when ID is closed. Calling this inside a Component `:render` subscribes it to every manual drag-resize and preset change.

**Returns.** The bounds plist or nil.

#### Function: etaf-pip-frame (id)

Return the floating child frame of Picture-in-Picture window ID, or nil.

**Returns.** A live frame or nil.

#### Function: etaf-pip-buffer (id)

Return the mounted buffer of Picture-in-Picture window ID, or nil.

**Returns.** A live buffer or nil.

#### Function: etaf-pip-cycle-size (id)

Cycle Picture-in-Picture window ID among `small`, `medium` and `large`.

**Semantics.** Resizes the frame to the next preset, re-docks it into the active corner, updates `etaf-pip-bounds` and calls ON-SIZE-CHANGE.

**Returns.** The new size symbol or nil when ID is not active.

#### Function: etaf-pip-cycle-corner (id)

Dock Picture-in-Picture window ID clockwise across parent frame corners.

**Semantics.** Moves the floating frame to the next corner in `(bottom-right bottom-left top-left top-right)` while preserving any manually dragged dimensions, and calls ON-CORNER-CHANGE.

**Returns.** The new corner symbol or nil when ID is not active.

#### Function: etaf-pip-refresh-chrome (id)

Repaint Picture-in-Picture window ID's surface, border and header bar.

**Semantics.** Re-evaluates THEME and TITLE to update frame colors, border paint and the adaptive header line.

**Returns.** `t` when ID is active, nil otherwise.

## Two-Tier Fullscreen

<!-- index: etaf-fullscreen-mode; etaf-fullscreen-enter; etaf-fullscreen-exit; etaf-fullscreen-toggle; fullscreen -->

Media players, readers and presentation views need distraction-free fullscreen without losing the user's window splits or mode-line permanently. ETAF separates fullscreen into two tiers: `window` fullscreen hides the buffer's mode-line in place without disturbing Emacs splits or OS spaces, while `frame` fullscreen saves the current window configuration and frame `fullscreen` parameter, expands to a single window, enters graphical OS fullscreen when not already fullscreen, and restores everything cleanly on exit or buffer kill.

#### Function: etaf-fullscreen-mode (&optional buffer)

Return BUFFER's reactive fullscreen mode: nil, `window` or `frame`.

**Arguments.** BUFFER defaults to the current buffer.

**Semantics.** Reading this inside a Component `:render` subscribes the View to fullscreen transitions so layouts expand without remounting stateful media nodes.

**Returns.** `window`, `frame`, or nil.

#### Function: etaf-fullscreen-active-p (&optional buffer)

Return non-nil when BUFFER is currently in `window` or `frame` fullscreen.

**Arguments.** BUFFER defaults to the current buffer.

**Returns.** `t` when fullscreen is active, nil otherwise.

#### Function: etaf-fullscreen-enter (&optional mode buffer &key (hide-mode-line t) on-change)

Enter fullscreen MODE (`window` or `frame`) for BUFFER.

**Arguments.** MODE defaults to `window`; BUFFER defaults to the current buffer. When HIDE-MODE-LINE is non-nil (default `t`), BUFFER's `mode-line-format` is saved and temporarily set to nil. Optional ON-CHANGE runs with the new mode symbol on transitions.

**Semantics.** Entering `frame` saves non-trivial window splits and the frame's previous `fullscreen` parameter before collapsing splits and switching graphical frames to `fullboth`. Switching directly from `frame` to `window` restores splits and OS fullscreen while keeping the mode-line hidden. Every transition triggers multi-phase viewport refits and native GPU video synchronization, and installs a buffer-kill guard so abrupt closure always restores frame state.

**Returns.** The entered mode symbol (`window` or `frame`).

**Errors.** `wrong-type-argument` when MODE is neither `window` nor `frame` (nor nil) or BUFFER is not a buffer or buffer name.

#### Function: etaf-fullscreen-exit (&optional buffer)

Exit fullscreen for BUFFER, restoring its mode-line, window splits and OS frame state.

**Arguments.** BUFFER defaults to the current buffer.

**Semantics.** Idempotent when BUFFER is not in fullscreen. Restores the exact original `mode-line-format` (killing the buffer-local binding when it was previously inherited), reverts OS frame `fullscreen` if changed, restores saved window splits and refits the canvas.

**Returns.** nil.

#### Function: etaf-fullscreen-toggle (&optional mode buffer &key (hide-mode-line t) on-change)

Toggle fullscreen MODE (`window` or `frame`) for BUFFER.

**Arguments.** MODE defaults to `window`; BUFFER, HIDE-MODE-LINE and ON-CHANGE match `etaf-fullscreen-enter`.

**Semantics.** Exits fullscreen when BUFFER is already in MODE; otherwise transitions directly into MODE from normal view or from the other fullscreen tier.

**Returns.** The new fullscreen mode (`window`, `frame` or nil).

## Errors and recovery

Opening never leaves a half-open application: when a step fails, the close function runs, the buffer is killed and the condition propagates, so the caller can fix the cause and open again. A close function should not signal; when it does, `etaf-app-close` reports the error after the buffer is gone and killing the buffer reports it as a message. Either way the application is closed and its name can be opened again.

The close function does not run when Emacs exits. An application whose state must survive the session saves it from `kill-emacs-hook` as well.
