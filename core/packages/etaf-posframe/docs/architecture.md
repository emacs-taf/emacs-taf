# ETAF Posframe Architecture

This document is the maintainer contract for the implemented panel host.  It explains ownership, dependency direction, lifecycle and invariants.  User workflows live in the [ETAF Reference Manual](https://etaf.top/posframe-panels/); the authoritative public API list is the Commentary of [`../etaf-posframe.el`](../etaf-posframe.el).

## 1. Responsibility and boundary

`etaf-posframe` shows any ETAF View in a floating child frame.  A panel does not take a window, does not replace the selected buffer and does not change the user's window layout.  The package owns:

- the child frame and its geometry;
- one ETAF Runtime and one buffer per panel;
- the panel lifecycle: show, hide, close, raise, fit and cleanup;
- palette derivation from the frame the panel belongs to;
- the application registry that turns a session plus a View into a panel.

It does not implement layout, focus or input semantics of its own.  Content is placed by Ebox through ETAF, focusable panels use ETAF's key layer, and the frame itself is created through the external `posframe` package.  A panel that needs different content rules composes ETAF and ETAF UI; it does not add a second host.

```text
ecss → ebox → etaf → etaf-ui → etaf-posframe → applications
                                      │
                                      └── posframe (child frame creation)
```

## 2. Panel model

A panel is one `etaf-posframe--panel` record plus one buffer.

| Fact | Owner | Stored where |
| --- | --- | --- |
| Frame, anchor, options, timers | the panel record | panel slots |
| ETAF Runtime | the mounted buffer | `etaf-runtime-for-buffer` |
| Theme, surface, appearance refs | the mounted buffer | buffer-local variables |
| Application session | the application | the registry callbacks |

The panel record holds only printable values.  Refs, keymaps and closures are cyclic, so `prin1` on a panel must not walk them; the Runtime and Theme ref are looked up from the panel buffer instead.  This is why the struct never stores a Runtime directly.

Panels are independent.  Each has its own frame, Runtime and behavior, and several may be open at once.  `:key` names the panel identity: showing another View with the same key hides the previous panel, while a different key keeps its frame and position.  A panel without a key shares the nil identity, so showing one replaces the previous unkeyed panel.

## 3. Lifecycle

`etaf-posframe-show` performs the whole opening sequence:

1. Validate options and resolve defaults, including the anchor frame.
2. Clamp width and height to the parent frame; a panel never exceeds it.
3. Resolve the View, create a buffer, and mount one Runtime into it.
4. Create the child frame, place it, and publish the first fit.
5. Return the panel record.

Hiding releases the panel's Runtime, buffer, timers and hooks and runs `:close-callback` once.  On graphical displays the underlying child frame is hidden, detached onto a live parking buffer and returned to an internal reuse pool rather than deleted, avoiding repeated native window creation and macOS NS `NSTextInputContext` teardown crashes inside `ns_free_frame_resources`.  On text terminals hiding deletes the child frame directly.  A panel whose parent frame dies is closed through the same path, and `etaf-posframe-app-quit` drops a keep-alive session and releases everything it owns.

The application registry is a thin layer over this lifecycle.  `:create` runs once per open and returns a session; `:view` receives it.  `:require` defers loading an application until its first open.  `:keep-alive` hides instead of closing, so a player or game keeps its session; `:on-stop` runs when the session is really dropped.

## 4. Geometry, stacking and fitting

Placement is resolved in character cells of the parent frame, from an anchor, an `(ANCHOR ROWS COLS)` offset, a window cell, frame pixels or a posframe poshandler.  `:stack` looks at the live panels at the same anchor and places the new panel below the lowest one, or above the highest from a bottom anchor, and moves to a side column only when the frame has no room.  Stacking reads the panels that are actually open; it keeps no parallel list of positions.

The frame is sized from the rendered content and then fitted again when the content settles.  An outside resize becomes the new width or height budget and the View re-lays out at it.  Fitting is rate-limited: more than twenty fits in one second backs the panel off for two seconds, so a content loop cannot pin the event loop.

A text terminal draws one border cell outside the frame size.  Anchors, fit counts and stacking account for that cell, and the border takes the terminal's own colors.  On a graphical frame the border is part of the child frame.

## 5. Theme and surface

A panel derives its palette from the frame it belongs to: the default face, `ui-mode`, border and status faces are read from that frame, not from whatever frame happens to be selected.  `:theme light` or `:theme dark` pins the mode; `:theme auto` follows the frame.  A Theme ref or computed value is accepted, so an application can pass its own reactive palette.

Color steps are mixed and checked for contrast, and text is made legible on the surface it is painted on.  A panel therefore works in both palettes without a second fixed set of colors.  Content that declares its own surface receives it through the mounted View; the panel keeps one readable surface declaration on each side of the mount.

## 6. Input and focus

A panel shows its View without stealing focus.  `:focusable` lets it take the keyboard, so the View's `:keys` and text properties work; the panel key map adds Escape and the close keys.  A click anywhere in a panel raises it above the other panels.  On a text terminal child frames take neither keyboard nor mouse, so panels are reached through the application prefix map; the same registry serves both displays.

Loading `etaf-posframe` also registers its modal child-frame host into `etaf-ui-modal-host-function` (when unset) so users who opt into `etaf-ui-modal-use-child-frame` get centered `etaf-dialog` modals and `?` keyboard help rendered in centered native child frames above their dimmed parent canvas (including when the owning application itself runs inside an `etaf-posframe` panel).  Modal child frames disable the panel-level `q`/`ESC`/`C-g` emulation map so ETAF's modal scope owns Escape layering, search input and native `C-g`, and teardown restores OS input focus and selection directly to the owning frame and window.

## 7. Invariants

- A panel never changes the selected buffer unless it is focusable and the user asks for focus.
- Every panel owns exactly one Runtime, one buffer and one frame.
- Content state lives in the application session, not in the panel record.
- A panel frame never exceeds its parent frame, and its width and height are recomputed when the parent or the content changes.
- Hiding or closing releases the Runtime, the frame, the buffer and every timer and hook the panel added.
- The external `posframe` package creates the frame; panel behavior, palette and lifetime stay in this package.
