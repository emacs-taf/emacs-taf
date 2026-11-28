# Mount and Lifecycle

A constructed tree can be consumed in two ways. `ebox-render` lays it out and returns its lines as a string, with no buffer involved; `ebox-mount` binds it to a buffer and keeps the buffer in step with every later mutation. This chapter follows the second path through its whole life: how a mount is created, what owning a buffer means, how to inspect a live mount, and how it is released again. [Node Construction](ebox-node-construction.md) built the tree; the [Tree Queries](ebox-tree-queries.md) chapter reads it back from a mount; [Viewport](viewport.md) defines the size a mount lays out for, and [Incremental Updates and Publication](incremental-updates-and-publication.md) the flush that keeps the text current.

## The mount

<!-- index: mount; root binding; buffer ownership; flush count; canvas background -->

A mount is the binding between one root node and one buffer. The tree stays the model; the buffer is output that the mount keeps in sync. Mounting replaces the buffer's text, and from then on the text belongs to Ebox: an edit made from outside is overwritten the next time the owning line is written, as [Incremental Updates and Publication](incremental-updates-and-publication.md) describes. The mount also takes over a few buffer-wide display settings while it lives — the buffer lays rows out left to right, truncates long lines, and paints window space beyond the last row with the root's background color — and puts each setting back when the mount is released.

A mount is also the unit of update. Layout and paint run per mount, `ebox-mount-flush-count` counts how often that happened, and viewport handling, observers and input sessions all hang off it. Because a root records the mount it feeds, a root is mounted once: mounting the same root in a second buffer does not copy it, and later mutations reach only the newest mount. Showing the same contents in two buffers therefore means copying the tree with `ebox-node-copy` or building it twice.

The lifecycle has three states. A tree is detached after construction; it is live while a mount binds it to a buffer; releasing the mount leaves the tree detached again and the buffer holding the last rendered text. Killing the buffer also releases the mount and runs the same release hook; the buffer simply disappears afterwards.

## Rendering to a string

#### Function: ebox-render (input)

Render INPUT, a node or author form, and return its lines as a string.

**Arguments.** INPUT is a detached root node or an author form that `ebox-build` understands.

**Semantics.** The tree is laid out for the viewport given by `ebox-viewport-width` and `ebox-viewport-height` ([Viewport](viewport.md)), painted, and turned into one string with a newline between root lines. No buffer is created and no mount exists, so this is the cheap way to see a tree's output — a preview, a test assertion, or the snapshot of a copied subtree. The string carries the text properties of the painted lines, including their faces and their display specifications, and is otherwise an ordinary string that the caller owns.

**Returns.** The rendered lines as a string.

**Errors.** `error→ ebox-error` when INPUT is a node with a parent ("Cannot render a non-root node"), and the construction errors of [Node Construction](ebox-node-construction.md) when INPUT is a malformed author form.

**Example.**

```elisp
(let ((ebox-viewport-width 40))
  (ebox-render '(text "pin")))
     ⇒ "pin"
```

**See also.** `ebox-mount`, `ebox-render-to-buffer`, `ebox-node-copy`.

## Mounting a tree

#### Function: ebox-mount (buffer-or-name input &rest options)

Mount INPUT, a root node or author form, in BUFFER-OR-NAME and return the root.

**Arguments.** BUFFER-OR-NAME is a live buffer or a name; a missing buffer is created. INPUT is a detached root node or an author form. OPTIONS may contain `:width` and `:height`, which fix that dimension of the viewport instead of following the display window ([Viewport](viewport.md)), and `:observer`, a function of buffer and report or nil. The observer is installed before the first flush and uses the same reports as `ebox-buffer-set-observer`; nil disables observation.

**Semantics.** Mounting replaces the buffer's text with the rendered tree, enables `ebox-buffer-mode` ([Keyboard](keyboard.md)) and writes the first version before returning, so the buffer is current the moment the call ends. The root's computed background becomes the buffer's default background, so window space beyond the laid-out rows matches the surface. When the buffer already has a mount, that mount is released first, exactly as `ebox-unmount-buffer` would release it. Nothing about the tree's identity changes: the same nodes remain the model, and mutations flow to the buffer through the flush pipeline. Mount a root once — a second mount of the same root does not copy the tree and takes over as the mount mutations reach.

**Returns.** The mounted root node.

**Errors.** `error→ ebox-error` when INPUT is a node with a parent ("Cannot mount a non-root node") and the construction errors of [Node Construction](ebox-node-construction.md) for a malformed form. An invalid non-function, non-nil `:observer` signals `error→ wrong-type-argument` before replacing the old mount. A mount that fails while building its input leaves an existing mount and the buffer text untouched.

**Example.**

```elisp
(let ((buffer (generate-new-buffer "*demo mount*")))
  (ebox-mount buffer '(text "hello"))
  (prog1 (with-current-buffer buffer
           (buffer-substring-no-properties (point-min) (point-max)))
    (kill-buffer buffer)))
     ⇒ "hello"
```

**See also.** `ebox-render-to-buffer`, `ebox-unmount-buffer`, `ebox-buffer-root`.

#### Function: ebox-render-to-buffer (buffer-or-name input &rest options)

Mount INPUT in BUFFER-OR-NAME with OPTIONS and return the buffer.

**Semantics.** The entry point for code that wants the buffer rather than the root — setting up a window, a mode line or a buffer-local setting usually starts from it. It behaves exactly like `ebox-mount` and takes the same OPTIONS; only the return value differs.

**Returns.** The buffer.

**Errors.** The same as `ebox-mount`.

**See also.** `ebox-mount`, `ebox-buffer-mount`.

## Inspecting a mount

#### Function: ebox-buffer-mount (&optional buffer-or-name)

Return the mount of BUFFER-OR-NAME (default current buffer), or nil.

**Semantics.** The mount object is the handle for everything mount-scoped: its viewport, its flush count, its observers and its input session. The result is nil for a buffer without a mount, for a killed buffer, and for a name that names no buffer. Use it to tell a live mount from a buffer that merely holds rendered text.

**Returns.** The mount object, or nil.

**Errors.** None.

**See also.** `ebox-buffer-root`, `ebox-mount-viewport`, `ebox-input-active-p`.

#### Function: ebox-buffer-root (&optional buffer-or-name)

Return the root node mounted in BUFFER-OR-NAME, or nil.

**Semantics.** The root is the node passed to `ebox-mount`; a child of it cannot be mounted, so this is also the node a program keeps to mutate what the buffer shows. The result is nil when the buffer has no mount.

**Returns.** The root node, or nil.

**Errors.** None.

**See also.** `ebox-buffer-mount`, `ebox-node-children`.

#### Function: ebox-mount-flush-count (&optional buffer-or-name)

Return the number of flushes that wrote BUFFER-OR-NAME's mount.

**Semantics.** The count starts at one after the mounting flush and grows by one for every flush that writes the mount, whether a single mutation, the end of a batch, or a viewport change caused it. A mutation that changes nothing does not flush and does not count. The count is a mount's, not a buffer's: releasing the mount loses it, and a remount starts again at one. Tests and diagnostics use it to assert that an update was applied in one flush rather than several.

**Returns.** The count, or 0 when the buffer has no mount.

**Errors.** None.

**See also.** `ebox-flush`, `ebox-with-batch`, `ebox-buffer-update-report`.

## Releasing a mount

#### Function: ebox-unmount-buffer (&optional buffer-or-name)

Release the mount of BUFFER-OR-NAME, keeping its text. Return non-nil if any.

**Arguments.** BUFFER-OR-NAME is a buffer or a name, defaulting to the current buffer.

**Semantics.** The release runs the abnormal hook `ebox-unmount-functions`, restores the display settings Ebox took over, removes the background remapping, ends an input session if one is active, and detaches the root, in that order. The text is not touched, so the buffer keeps showing what the tree last rendered; it is now just text, and later mutations of the tree do not reach it. The mount object stops answering, the root is detached again, and the buffer can be mounted with a new tree. Killing a mounted buffer releases the mount too, and it runs the same hook before the buffer goes away.

**Returns.** Non-nil when a mount was released, nil when the buffer had none or is dead.

**Errors.** None of its own; an error from the hook propagates and aborts the release, leaving the mount live.

**See also.** `ebox-mount`, `ebox-buffer-mount`, `ebox-unmount-functions`.

#### Hook: ebox-unmount-functions

Abnormal hook run with a buffer whose mount is being released.

**Semantics.** Each function is called with the buffer as its only argument, before the mount is detached and before the display settings are restored, so inside the hook `ebox-buffer-mount` still answers and the buffer still looks mounted. Functions run in order. An error signals out of `ebox-unmount-buffer` and aborts the rest of the release, which is why a hook should do its own work and return — the buffer is half-owned while the hook runs.

**See also.** `ebox-unmount-buffer`, `ebox-buffer-mount`.

## How the entries work together

`ebox-render` and `ebox-mount` share one input contract — a detached root node or an author form — and one layout; the first returns the string, the second keeps writing it into a buffer. `ebox-render-to-buffer` is the mount variant that returns the buffer. A program that mounts usually keeps the root it passed: the mount adds nothing to the tree's API, so every mutation entry point from [Incremental Updates and Publication](incremental-updates-and-publication.md) keeps working unchanged.

The query entries answer the three questions a caller asks about a live mount: is this buffer mounted (`ebox-buffer-mount`), what tree does it show (`ebox-buffer-root`), and how much work has it done (`ebox-mount-flush-count`). The release entries end the binding: `ebox-unmount-buffer` for an explicit release, buffer kill for a buffer that is going away; both run the hook. After either, the buffer and the tree are independent again, and the tree can be mounted elsewhere.

## Semantic details

<!-- index: display settings; background remapping; buffer kill -->

Mounting is a small transaction. The buffer's text is replaced, the mode is enabled, the background remapping is installed and the first flush runs before `ebox-mount` returns; if the input cannot be built, nothing is touched and the old mount stays as it was. Re-mounting is the same operation with an implicit release of the previous mount first, so the unmount hook runs and the display settings are restored and taken again.

Three pieces of buffer state belong to the mount. The display settings make rows behave as layout composed them: no native continuation wrapping, no bidi reordering, and no long-line scanning. The background remapping makes the window area below the last row show the root's background instead of the frame's. Both are removed on release; settings the buffer had locally are restored to their previous values. An input session, if one is running, is ended by the release.

Killing a buffer releases its mount through the buffer's kill hook and runs `ebox-unmount-functions`, restores the display settings and background remapping, ends an input session and detaches the root, exactly like an explicit unmount; only the mode teardown is moot for a dying buffer. A callback that releases outside resources therefore runs on either path.

## Errors and recovery

| Situation | Signal |
| --- | --- |
| INPUT has a parent, for render or mount | `error→ ebox-error`, "Cannot render a non-root node" or "Cannot mount a non-root node" |
| INPUT is a malformed author form | the construction errors of [Node Construction](ebox-node-construction.md) |
| A mount fails while building | the previous mount and text stay in place |
| The unmount hook signals | the error propagates and the release stops; the mount stays live |
| A buffer is killed | the mount is released, the hook runs and the buffer disappears |

Recovery follows the state. A rejected input leaves the tree detached and the buffer as it was, so the form can be fixed and the mount retried. A hook error leaves the mount live, so it can be released again after the hook is fixed. Once a mount is released — by `ebox-unmount-buffer` or by killing the buffer — the tree is detached and can be mounted again or rendered as a string.
