# Keyboard

Every interaction has a keyboard path, and the framework's rule is that applications declare structure rather than key handlers. A Host lists its keys with the `:keys` property; direction behavior is declared with `:on-direction`; focus navigation and dismissal are framework keys that only need an entry point on the Host. This chapter describes the scoped key layer: how `:keys` resolves against focus and point, the framework-reserved keys, the two direction schemes and their handler chain, Escape dismissal, the help and palette surfaces, the Ebox buffer mode and its map, the native keymap primitive, and how the layer is built. [Hosts](hosts.md#property-keys) defines the `:keys` property and [Events](events.md#property-on-dismiss) defines `:on-dismiss`; [Focus](focus.md) defines the navigation the frame keys perform.

## Host keys

<!-- index: :keys; key binding; labelled key -->

A Host declares keyboard commands with `:keys`, a list of `(KEY COMMAND [LABEL])` entries. KEY is a `kbd` string or a key vector, COMMAND is a function called with no arguments (interactively when it is a command), and the optional LABEL names the command in the help buffer and the palette. The entries of a Host and its ancestors form its key scope: a key works while the scope's entry point — focus, or point when nothing is focused or point moved out of the focused Host — lies inside the Host.

Commands run exactly like keymap bindings, outside any batch: each write publishes on its own, so a command may move point to, focus or begin editing a Host it just revealed. Wrap several writes in `etaf-batch` when they should publish together. This is what lets a key command both reveal and act on new content in one press.

Several Hosts may declare the same key at different depths. The nearest one wins, and a disabled Host contributes none of its own entries while the search continues outward, so disabling an inner control falls back to the container's binding rather than losing the key. Component root `:keys` place the caller's entries first, per [Hosts](hosts.md#property-keys).

## Key resolution order

<!-- index: key resolution; key chain; fall-through; native input -->

When a key is pressed in a Runtime buffer, the layer resolves it in a fixed order.

1. The scope chain starts at the focused Host while point lies inside the focused Host or its subtree; otherwise it starts at the Host at point. A pointer event, such as a wheel turn or a click bound in `:keys`, starts at the Host under the pointer instead. When the innermost visible modal scope does not contain that Host, the chain starts at the modal Host instead.
2. The Host and its ancestors are searched from nearest to farthest for a matching `:keys` entry, stopping after the first `:focus-scope modal` Host, so keys outside an open dialog are unreachable. Disabled Hosts contribute nothing. The first matching entry wins, with one exception: RET activates the nearest enabled Host with a press handler when that Host is nearer than the Host whose RET entry was found, so a root RET entry acts on the application's own selection without stealing RET from a focused button.
3. Without a Host entry the framework keys apply: `M-g` enters [region selection](region-navigation.md#selecting-a-region), Escape dismisses the nearest `:on-dismiss` Host, the direction keys run `etaf-direction`, Tab and S-Tab move one focus stop, `?` opens `etaf-help`, and Home/End reach group or scope edges.
4. Anything still unbound falls through to the buffer's other keymaps. While a native input session is editing, every key falls through so the session's own editing commands win.

A Host key therefore shadows the buffer's binding of the same key, and an open modal scope also swallows unbound printing keys instead of letting them reach the application behind it. Sequence prefixes are shared: a Host may bind `C-c C-u` while the buffer's mode map keeps `C-c C-k`, and one key cannot both run a command and start a sequence anywhere in the same Runtime.

## Framework keys

<!-- index: reserved keys; keymap validation -->

The framework owns Escape, `M-g`, `C-g`, `?`, Tab and the direction keys. An application cannot bind them through `:keys`; direction behavior is expressed with `:on-direction` instead, and `C-g` keeps Emacs's native keyboard quit semantics. The reserved set is fixed by the key layer, not by a mutable variable, so a component can check a caller-supplied keymap before using it.

#### Function: etaf-keymap-reserved-events (keymap)

Return the framework-reserved events bound at the top level of KEYMAP.

**Arguments.** KEYMAP is a keymap, or nil.

**Semantics.** Each top-level binding of KEYMAP is compared against the reserved set, and the conflicting event vectors are returned in binding order. Component authors call it while validating a caller-supplied `:keymap` so that a component cannot shadow Escape, the region selector entry (`M-g`), native quit (`C-g`), the help key (`?`), Tab or the direction keys. A keymap that binds other keys, however many, is free of conflicts.

**Returns.** A list of event vectors, or nil when KEYMAP is nil, is not a keymap, or conflicts with nothing.

**Errors.** None; a non-keymap argument is a nil result.

**Example.** `(etaf-keymap-reserved-events (ebox-keymap-create :bindings '(("TAB" #'ignore))))` ⇒ `([tab])`

**See also.** `:keys`, `:on-direction`, [Events](events.md#property-on-dismiss).

## Direction

<!-- index: direction; :on-direction; direction scheme; separator step -->

Direction keys belong to the framework, but the meaning of "down" at a given Host is application policy. A Host declares that policy with `:on-direction`; the layer runs the nearest declaration, then gives a focused separator or slider its step, then moves focus, and finally scrolls the viewport when nothing else could move.

#### Property: :on-direction

The handler that decides what a direction means for a Host.

**Arguments.** A function of one argument, the direction symbol `up`, `down`, `left` or `right`, or nil.

**Semantics.** The nearest Host in the scope chain with a handler answers for a direction key. The handler returns one of three symbols: `handled` and `hold` stop there and keep focus where it is, while `release` passes the direction on to the separator step, region movement and spatial movement below. A handler is the declaration a grid, slider, carousel or editor uses to consume arrow keys without binding them. It runs before any focus movement, and the chain is the same focus-aware scope the key layer uses, so leaking directions into a nested editing Host only takes a handler there.

**Returns.** The return value must be `handled`, `hold` or `release`; it is ignored otherwise except for the error below.

**Errors.** `error→ etaf-renderer-error` at commit when the value is not a function or nil; `error→ etaf-event-error` when the handler returns something else, with the message naming the returned value and the expected symbols.

**Example.** `(box :on-direction (lambda (direction) (when (eq direction 'down) (next-line) 'handled)) ...)`

**See also.** `etaf-direction`, `etaf-direction-scheme`.

#### Function: etaf-direction (direction &optional runtime)

Move DIRECTION in mounted RUNTIME and return the focused Host reference.

**Arguments.** DIRECTION is `up`, `down`, `left` or `right`. RUNTIME defaults to the active Runtime.

**Semantics.** The order is fixed. First the nearest `:on-direction` handler in scope runs; `handled` and `hold` return the current focus unchanged, and `release` continues. Then a focused Host with role `separator` or `slider` and an `:on-drag` steps one cell along its `:aria-orientation`, reported as a keyboard drag gesture: a `vertical` element, a vertical rule, steps sideways and a `horizontal` element steps up and down. Then focus moves inside the surrounding region, entering the adjacent region at its edge when there is one, as [Region Navigation](region-navigation.md#adjacency) describes. Without a surrounding region the Ebox spatial movement applies, and when that finds no stop the viewport scrolls one step for down and up. Without focus the Host at point answers, so a reader keeps the key semantics of its rows. This is the function the arrow keys and, under the `vim` scheme, `h`/`j`/`k`/`l` run.

**Returns.** The focused Host reference; nil when nothing moved.

**Errors.** `error→ etaf-event-error` with `"Unknown direction %S"` for another direction, and for an invalid `:on-direction` return value; `error→ etaf-render-side-effect-error` when called during rendering; `error→ etaf-runtime-error` when the Runtime is not mounted.

**Example.** `(etaf-direction 'down runtime)`

**See also.** `:on-direction`, `etaf-set-direction-scheme`, `etaf-drag-step`.

#### Variable: etaf-direction-scheme

Direction scheme of the key layer: `arrows` (default) or `vim`.

**Semantics.** Under `arrows` the physical arrow keys run `etaf-direction` and `h`, `j`, `k` and `l` remain ordinary application keys. Under `vim` those four letters additionally dispatch as direction keys in navigation state, which suits readers who navigate without leaving the home row. The scheme is process-wide, and it is read when a key is pressed rather than when a binding is created. Set it through `etaf-set-direction-scheme` so that a conflicting Runtime is reported instead of silently shadowed.

**Returns.** Not applicable; the variable holds the current scheme symbol.

**See also.** `etaf-set-direction-scheme`, `etaf-direction`.

#### Function: etaf-set-direction-scheme (scheme &optional runtime)

Select the direction SCHEME, `arrows` or `vim`, after conflict checks.

**Arguments.** SCHEME is `arrows` or `vim`. RUNTIME limits the conflict check to one mounted Runtime; nil checks every mounted Runtime.

**Semantics.** Switching to `vim` verifies that no Host `:keys` entry and no region hint character uses `h`, `j`, `k` or `l` in the checked Runtimes, because those bindings would become unreachable or ambiguous. Conflicts are reported together and the previous scheme stays in effect, so a half-applied switch cannot happen. `arrows` never conflicts; switching back restores the letters to the application immediately.

**Returns.** SCHEME.

**Errors.** `error→ user-error` listing the conflicting bindings and hints when `vim` conflicts exist; `error→ etaf-event-error` with `"Unknown direction scheme %S"` for another scheme; `error→ etaf-runtime-error` when an explicit RUNTIME is not mounted.

**Example.** `(etaf-set-direction-scheme 'vim runtime)`

**See also.** `etaf-direction-scheme`, `:on-direction`.

## Dismissing with Escape

<!-- index: Escape; dismissal -->

Escape is the framework key for closing the nearest thing that can be closed. The layer searches the scope chain from the focus outward for the nearest enabled Host with `:on-dismiss` and dispatches that callback; the key works without any binding on the Host, and a disabled inner control does not make the dialog behind it undismissable. `C-g` is deliberately not bound to this: it keeps Emacs's keyboard quit semantics. [Events](events.md#property-on-dismiss) defines the callback and the modal scope that contains the search.

## Help and the command palette

<!-- index: help; command palette; etaf-help; etaf-palette -->

Two surfaces expose the keyboard state. Help is for reading: it lists what the current scope can reach and never runs anything. The palette is for running: it offers the labelled commands and the focusable controls by name. Both are ordinary Lisp entry points, so applications can open them from their own menus as well as from the framework keys.

#### Function: etaf-help (&optional runtime)

Open read-only keyboard help as a modal inside mounted RUNTIME's existing buffer.

**Arguments.** RUNTIME defaults to the active or current-buffer Runtime.

**Semantics.** Calls inside an event or reactive batch wait for its pending work to publish. Capture the effective scope before the modal takes focus: labelled Host keys, effective application-local keymaps, framework navigation, region entries, scoped `:help` notes and readable control names. The existing buffer, Emacs window and application Runtime are reused; no help buffer or split is created. Repeated calls reuse the opening snapshot. Native editing ends with accepted input preserved, then the nearest enabled `:on-help-open` callback prepares the application before the snapshot is captured; a callback error or quit aborts opening. The core presentation scrolls; loading etaf-ui supplies the searchable `etaf-key-help` presentation. Descriptions never execute their commands. Escape leaves an active search edit first, then closes help; a pointer click on the backdrop also closes it without activating the background. While help is open, native window scrolling starts at the canvas top so the root-layer modal stays visible. Closing restores a surviving opener and the original window position; a rejected renderer also restores that position. Background application updates remain live without changing the captured scope.

**Returns.** The application buffer.

**Errors.** `error→ etaf-runtime-error` when the Runtime is not mounted.

**Example.** `(etaf-help runtime)`

**See also.** `etaf-help-close`, `etaf-help-data`, `etaf-help-view-function`, `etaf-palette`, `:keys`.

#### Function: etaf-help-close (&optional runtime)

Close in-buffer help and restore its surviving focus and window start.

**Arguments.** RUNTIME defaults to the active or current-buffer Runtime.

**Semantics.** Dispose only the help surface and its editing session. The retained application, its state and node scroll offsets survive. Inside an event or reactive batch, restore focus and the native window start after modal removal is published; this restoration never overrides a newer help opening or a Runtime unmounted in the same batch. A removed opener is not focused. C-g remains Emacs's native interrupt, not a close command. Unmounting also disposes help and its snapshot.

**Returns.** Non-nil when help was open; nil otherwise.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

#### Function: etaf-help-data (&optional runtime)

Return a defensive, callback-free snapshot of the effective keyboard scope.

**Arguments.** RUNTIME defaults to the active or current-buffer Runtime.

**Semantics.** The plist contains string `:title` and `:scope`, plus `:groups`, `:notes` and `:controls`. A group has `:title`, `:source`, `:kind` (`application`, `framework` or `regions`) and `:entries`; each entry has `:key`, `:label`, `:source` and an optional key vector `:events`. Notes come from scoped Host `:help` strings; controls are readable names, never callbacks. Nearer Host keys shadow outer bindings even when unlabelled. Effective local maps supplement them, using a native menu-item label when available or the command's first documentation line otherwise; unrelated global minor modes are not application help. While help is open, return its opening snapshot. Mutable strings, vectors and lists are detached, so modifying the result cannot change the application or future snapshots.

**Returns.** The snapshot plist.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

#### Variable: etaf-help-view-function

Select the help renderer without making core depend on the component catalog.

**Semantics.** Nil (the default) uses the core scrollable modal. Otherwise the value is a function of DATA and CLOSE returning a root-layer modal View. DATA follows `etaf-help-data`; CLOSE is a zero-argument dismissal callback. The View inherits the opening Host's Context and mounted lifetime. It must not create buffers or windows or execute listed business commands. Loading etaf-ui installs its renderer only when this value is nil, preserving an existing custom renderer. A renderer failure leaves the application usable and permits retrying.

**See also.** `etaf-help`, `etaf-key-help`.

#### Function: etaf-palette (&optional runtime)

Choose and run a command or control of mounted RUNTIME by name.

**Arguments.** RUNTIME defaults to the active Runtime.

**Semantics.** The candidates are the labelled `:keys` the current focus reaches, a `Close` entry when an `:on-dismiss` Host is in scope, and every focusable control of the modal scope named by its `:aria-label` or painted text. Choosing a key runs its command exactly as the key would; choosing a control focuses it and dispatches its press. Duplicate labels receive a numeric suffix so every candidate stays selectable. The palette is reached through `M-x` by design, which keeps the execution surface explicit while `?` remains read-only.

**Returns.** The result of the chosen command, or nil.

**Errors.** `error→ user-error` with the message `"No ETAF command is reachable here"` when the scope offers no candidate; `error→ etaf-runtime-error` when the Runtime is not mounted.

**Example.** `(etaf-palette runtime)`

**See also.** `etaf-help`, `:keys`, `:on-dismiss`.

## The Ebox buffer mode

<!-- index: ebox-buffer-mode; keymap; canvas input -->

A mounted buffer is application output, not editable text. `ebox-mount` therefore enables `ebox-buffer-mode`, a minor mode whose keymap turns the usual reading keys into navigation and keeps unbound printing keys from inserting themselves into the canvas.

#### Function: ebox-buffer-mode (&optional arg)

Minor mode for mounted Ebox buffers.

**Arguments.** ARG toggles the mode as for any minor mode; nil toggles, a positive argument enables, a negative argument disables.

**Semantics.** `ebox-mount` enables the mode and `ebox-unmount-buffer` disables it, so an application does not manage it directly. While it is on, the mode's map is laid over the buffer, overline margins are zeroed so a top border does not add to a row's ascent, and paren highlighting is turned off because painted text is not code. A native input session takes the keys it needs for editing. The mode is also what makes the canvas selection-free: an activated mark over the canvas is refused.

**Returns.** The mode variable after the toggle.

**Errors.** None.

**Example.** `(ebox-buffer-mode 1)`

**See also.** `ebox-buffer-mode-map`, `ebox-mount`.

#### Variable: ebox-buffer-mode-map

Keymap of mounted Ebox buffers: scrolling, focus navigation and activation.

**Semantics.** The map covers the whole reading and navigation surface: mouse wheel, fringe and margin scroll events and horizontal wheel swipes; `n`/`p`, `C-v`/`M-v`, SPC/S-SPC, `<next>`/`<prior>` and the `scroll-up-command`/`scroll-down-command` remaps; `q` to quit the window; Tab and S-Tab focus movement; RET and return activation; the arrow keys and `C-n`/`C-p`/`C-b`/`C-f` for `ebox-focus-direction`, which scroll when no focus stop lies that way; Home/End and `M-<`/`M->` for the group's or scope's first and last stop; and `mouse-movement` for hover content. Unbound printing keys are suppressed rather than left to self-insert, so a mounted canvas never becomes editable accidentally. Applications customize the map after Ebox is loaded to change shared bindings, and ETAF layers its Host keys and framework keys above it.

**Returns.** Not applicable; the variable holds the keymap.

**See also.** `ebox-buffer-mode`, `etaf-keymap-reserved-events`.

## Ebox keymaps

<!-- index: native keymap; activation binding; gesture binding -->

Ebox lets library authors create native keymaps with the same interaction shape ETAF lowers its Host callbacks into. A map can activate on the standard keys, bind additional sequences to zero-argument callbacks, or receive primary-button drag gestures with an optional lock modifier.

#### Function: ebox-keymap-create (&rest options)

Create a native keymap from OPTIONS.

**Arguments.** OPTIONS is a plist with these keys: `:activate`, a zero-argument callback bound to RET, return, SPC and — unless a drag gesture is also declared — the primary mouse button; `:bindings`, an alist of key descriptions or vectors paired with zero-argument callbacks; `:drag`, a one-argument callback receiving each gesture phase; `:drag-lock-modifier`, one of `shift`, `control`, `meta`, `super` or `hyper`, which keeps a drag alive across the button release; and `:drag-edge`, any non-nil value to report `edge` phases while a drag rests in or past a window edge band. The lock modifier requires `:drag`; a malformed option or callback fails when the map is created.

**Semantics.** The returned keymap is a normal Emacs keymap, suitable for the `:keymap` text property Ebox paints on a node. An activation binding claims the primary-button sequence so a press neither starts region selection nor reaches global commands and activates only when the release lands on the same owner; a drag binding claims the whole primary-button sequence and relays movement through the gesture callback, whose plist carries the phase, the event, the node, the window, the buffer, the start and current pixel positions, the delta, the pointer's overshoot past the text area and a cancellation reason. With `:drag-edge` the callback also receives `edge` phases carrying `:edges` and `:elapsed`; the engine reports intent and the application owns any scrolling, as [Dragging and Gestures](dragging-and-gestures.md#edge-intent-and-scrolling) describes. A map with both press-only and sequence bindings rejects a sequence that is a prefix of another, exactly as the application key layer rejects a key that both runs and starts a sequence. ETAF builds its Host keymaps with this primitive, which is why a `:on-press` Host behaves like an `:activate` binding and a `:on-drag` Host like a `:drag` binding.

**Returns.** The new keymap.

**Errors.** `error→ error` with the offending value for an unknown or repeated option, a lock modifier outside the supported set, a lock modifier without `:drag`, a non-function `:drag`, a `:bindings` value that is not an alist, a binding whose value is not a function, a key that is neither a string nor a vector, an empty key, a callback that does not accept zero arguments, or a binding overlapping an existing key.

**Example.** `(ebox-keymap-create :activate (lambda () (save)) :bindings '(("C-r" #'reload)))`

**See also.** [Events](events.md#property-on-drag), `:keys`, `ebox-mount`.

## The scoped key layer

<!-- index: emulation keymap; lazy resolution; scope chain -->

The layer is built so that declarations, not bindings, scale. Every Runtime buffer owns one keymap that holds a binder for each key any reachable Host has declared; the map is installed among Emacs's emulation keymaps, which puts it ahead of the buffer's own maps without rewriting them. An application therefore declares its keys on its root Host instead of installing a keymap of its own; the keys then appear in help, respect modal scopes and disabled Hosts, and leave the framework keys intact. Each binder is a lazy filter rather than a fixed command: when the key is pressed, the filter walks the current scope chain — focus, then the Host at point, then ancestors up to the modal boundary — and returns the nearest matching command, one of the framework commands, or nothing, in which case the key continues through the remaining maps. Because resolution happens at press time, a Host that gains or loses a binding changes the effective keymap without any reinstall, and because the chain stops at the modal boundary, an open dialog is isolated by construction.

Sequence conflicts are structural rather than runtime: registering a sequence that extends another binding, or that another binding extends, is a render error, so the map never contains an ambiguous prefix. The scheme check for the Vim letters is the same idea applied to direction keys: a conflict is reported before the scheme changes.

## Errors and recovery

<!-- index: keyboard errors; key validation -->

Keyboard problems split by when they are detected. A malformed or conflicting `:keys` value, a binding of a reserved key, and a printing-key sequence all fail when the Host commits, with `error→ etaf-renderer-error` and a message naming the entry. A non-function `:on-direction` fails at commit; an invalid return value fails when the direction runs, with `error→ etaf-event-error`. `etaf-direction` rejects an unknown direction and `etaf-set-direction-scheme` an unknown scheme with `etaf-event-error`; a Vim conflict is a `user-error` that lists every conflict and leaves the previous scheme in effect, so the keyboard keeps working while the application resolves the names. `etaf-palette` with no reachable candidate is a `user-error`, and a key that resolves to nothing is not an error at all: it falls through to the buffer's maps, which is what lets a mounted canvas coexist with the user's editing commands.
