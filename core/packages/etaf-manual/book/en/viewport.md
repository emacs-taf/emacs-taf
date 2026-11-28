# Viewport

A mounted tree does not own the screen; it owns a viewport, the rectangle its layout resolves against. The buffer's window decides that rectangle, the user's resizing decides when it changes, and Ebox is the layer that turns those editor events into one settled relayout. This chapter describes how a mount gets its viewport, how window measurement and settling work, the refit interface at both the Ebox and ETAF layers, the viewport units, and the nested viewport regions an application uses to lay out for a pane rather than a whole buffer. [Rendering Model](rendering-model.md) defines the pixels and lines involved, [Runtime](runtime.md) the mount lifecycle, and [Style Properties](style-properties.md) the `vw` and `vh` units that read the viewport.

## The mount viewport

<!-- index: viewport; mounted viewport; fixed viewport; window measurement -->

A viewport is a pair of a width in pixels and a height in lines. `ebox-mount` fixes it when the caller passes `:width` and `:height`; otherwise the mount measures the window that displays its buffer, so a tree fills the editor area it was opened into. A batch session has no window height, so the measured height may be indefinite: block sizes expressed in viewport-height units then size to content instead of the screen. The measured width falls back to the fallback viewport variables and finally to an eighty-column default.

#### Function: ebox-mount-viewport (&optional buffer-or-name)

Return (WIDTH . HEIGHT) of BUFFER-OR-NAME's mounted viewport, or nil.

**Arguments.** BUFFER-OR-NAME names a mounted Ebox buffer; the current buffer is the default.

**Semantics.** WIDTH is in pixels and HEIGHT in lines. Without a fixed viewport the size follows the window displaying the buffer, in batch sessions too. HEIGHT is nil when indefinite, so height-dependent units size to content; a fixed mount reports exactly the values it was mounted with.

**Returns.** The cons, or nil when the buffer has no mount.

**Errors.** None. Reading an unmounted buffer is a nil result, not an error.

**See also.** `ebox-mount-set-viewport`, `ebox-viewport-measure`.

#### Function: ebox-mount-set-viewport (buffer-or-name width height)

Lay out BUFFER-OR-NAME's mount for a WIDTH by HEIGHT viewport.

**Arguments.** WIDTH is pixels and HEIGHT lines; either may be nil to follow the displaying window for that dimension.

**Semantics.** The fixed values are stored on the mount and a refit runs immediately. Passing nil twice releases a fixed viewport and lets both dimensions follow the display again. A refit that actually changes the size runs `ebox-viewport-change-functions` after the layout settles.

**Returns.** The result of the refit, non-nil when the layout changed; nil when the buffer has no mount.

**See also.** `ebox-mount-viewport`, `ebox-refit`.

## Window measurement and settling

<!-- index: window width; measurement precedence; settle delay; transient space -->

Two details decide whether a measured viewport is correct. The first is the difference between a window's body and the pixels it actually offers: fringes, scroll bars, margins and the truncation column all take space that layout must not use. The second is timing: a frame drag produces size events faster than a reflow completes, so Ebox schedules one trailing relayout instead of one per event, and it distinguishes a real resize from lines borrowed by transient UI.

#### Function: ebox-viewport-window-width (window)

Return the pixel width WINDOW offers to a mounted tree.

**Arguments.** WINDOW is a live window; anything else yields nil.

**Semantics.** The width is the window's outer pixel width minus its fringes, scroll bar and margins. When the body width disagrees with that computation by more than a small char-width tolerance, the body width wins. A window without a right fringe loses one more column, because Emacs reserves the last text column for its truncation glyph; on a graphical frame one additional pixel is removed so a full line is not truncated.

**Returns.** The usable width in pixels.

**Errors.** None.

**See also.** `ebox-viewport-measure`, `ebox-mount-viewport`.

#### Function: ebox-viewport-measure (buffer-or-name &optional width height)

Return the (WIDTH . HEIGHT) viewport a mount of BUFFER-OR-NAME would use now, whether or not it is mounted yet.

**Arguments.** WIDTH and HEIGHT are explicit overrides; either may be nil.

**Semantics.** The precedence is the explicit argument, then the `ebox-viewport-width` and `ebox-viewport-height` variables, then the window displaying the buffer, then the fallback defaults. The buffer need not be mounted: a layer that computes content before mounting uses this to size that content to the viewport the mount will have. Passing an unknown buffer falls back to the current buffer's window.

**Returns.** The cons of pixels and lines; the height may be nil when indefinite.

**Errors.** None.

**See also.** `ebox-mount-viewport`, `ebox-viewport-width`, `ebox-viewport-height`.

#### Variable: ebox-viewport-settle-delay

Seconds of quiet after the last size change before Ebox reflows.

**Semantics.** Window size events and buffer changes are recorded as intents, deduplicated per frame, and one task waits for this delay; each new event restarts the wait. When the delay passes with no further events, the mounts displayed in that frame are refitted. The default 0.12 seconds keeps a frame drag responsive: intermediate sizes are never laid out.

**Example.** On a graphical frame, resizing the frame from 80 to 70 columns and 34 to 18 rows leaves the viewport at its old value immediately after the resize; half a second later the viewport is 490 by 16 pixels and lines, seven pixels per column, and the viewport-change hook has run once.

**See also.** `ebox-viewport-change-functions`, `ebox-refit`.

Transient UI does not count as a resize. While an active minibuffer, a completion popup or an echo-area message borrows lines from a displayed window, the frame itself is unchanged; a mount keeps its committed viewport until that UI releases the lines, and the minibuffer exit schedules a recheck. A frame change or a taller window is real geometry and refits as usual.

### Buffer text scale

<!-- index: text scale; zoom; metric refresh -->

Changing a buffer's text scale changes the metrics every measured glyph was computed with, but it produces no window-size notification, so the size bridge never hears about it. Ebox treats a scaled mounted buffer as a viewport intent of its own: `text-scale-mode-hook` records the buffer, the same settle delay waits for the zoom to go quiet, the shared glyph caches are cleared once for the batch, and the whole mount is laid out again. Measured widths, line heights and intrinsic sizes then follow the buffer's new faces, so wheel zooming a mounted application paints aligned rows instead of cutting rows to the metrics of the previous scale. A burst of zoom steps settles into one relayout, and returning to the default size is another.

Rendering outside a mount reads the same measuring context: `ebox-render` measures under the current buffer's faces. Pixel images prepared by an application do not grow with the font: their producer reads the effective metrics and repartitions the pixels into rows. This keeps intrinsic graphics intact instead of stretching them or leaving gaps between strips.

#### Function: ebox-display-metrics (&optional buffer-or-name)

Return a fresh plist describing BUFFER-OR-NAME's effective default-face metrics.

**Arguments.** BUFFER-OR-NAME defaults to the current buffer. Its displaying frame supplies the base font; a hidden buffer uses the selected frame.

**Semantics.** `:char-width` and `:line-height` are positive pixel dimensions and `:ascent` is the image ascent percentage that aligns the baseline. Buffer-local text scaling is included. Text displays return unit cells and 100 percent ascent. The caller owns the result and may modify it without changing later reads.

**Errors.** An unknown buffer signals error→ `error`.

**Example.** `(plist-get (ebox-display-metrics) :line-height)` supplies the logical height of one strip for a native image producer.

#### Hook: ebox-display-change-functions

Report a mounted buffer after its display metrics settle.

**Semantics.** Each function receives the mounted buffer after its retained tree has been remeasured. A burst of text-scale changes shares the viewport settle delay. The callback reads `ebox-display-metrics` to rebuild externally prepared rows; the mount and application state are not recreated. Released mounts receive no notification. This hook also runs for fixed-size viewports, unlike the viewport-size hook which reports only changed dimensions.

#### Function: etaf-display-metrics (&optional runtime)

Read a mounted Runtime's effective default-face metrics reactively.

**Arguments.** RUNTIME defaults to the active Component's Runtime or the current buffer's Runtime.

**Semantics.** The fresh plist has the same `:char-width`, `:line-height` and `:ascent` keys as `ebox-display-metrics`. A render, computed or effect that reads it reruns after settled buffer text scaling, even with a fixed viewport. ETAF publishes metrics and viewport changes in one reactive batch; native image producers can adapt their rows without remounting components or resetting state.

**Errors.** A missing or unmounted Runtime signals error→ `etaf-runtime-error`.

**Example.** `(etaf-computed (lambda () (plist-get (etaf-display-metrics) :line-height)))` tracks the row height for an image-producing application.

## Refit across both layers

<!-- index: refit; relayout; fixed viewport; adaptive viewport -->

A refit is one operation with one result: measure the viewport, and when it differs from the committed one, update it and relayout exactly what depends on it. In Ebox that means the root when the width changed or its block size follows the container height, and every node that declared `vw` or `vh` units on the changed axis. In ETAF, refit is a Runtime operation, so a mount observer and the performance recorder see it as kind `refit`, and the revision advances when the layout changed.

#### Function: ebox-refit (&optional buffer-or-name)

Relayout BUFFER-OR-NAME's mount when its viewport size changed.

**Arguments.** BUFFER-OR-NAME names a mounted Ebox buffer; the current buffer is the default.

**Semantics.** The viewport is measured again; an unchanged size returns nil without touching layout. A changed size updates the mount's viewport, marks the nodes that read the changed axis, flushes the relayout, and runs `ebox-viewport-change-functions`. A window that shows the whole buffer is returned to its top, so a tree that scrolled while transient UI borrowed window lines comes back into place.

**Returns.** Non-nil when the layout changed.

**Errors.** None.

**See also.** `ebox-mount-set-viewport`, `ebox-viewport-change-functions`.

#### Function: etaf-runtime-refit (runtime viewport-width &optional viewport-height)

Refit mounted RUNTIME to VIEWPORT-WIDTH pixels and VIEWPORT-HEIGHT lines.

**Arguments.** RUNTIME is a mounted Runtime. VIEWPORT-WIDTH is pixels and VIEWPORT-HEIGHT lines; either may be nil to follow the displaying window for that dimension, so an application can fix its line count while keeping an adaptive width.

**Semantics.** The fixed dimensions are stored on the Runtime and Ebox relayouts the mount. Viewport units and viewport-dependent layout are resolved again and only the changed region is rewritten. The refit is one observed Runtime operation, reported to a mount observer and the performance recorder as `refit` with its Ebox flush report.

**Returns.** Non-nil when the layout changed.

**Errors.** A non-mounted Runtime signals `etaf-runtime-error`; non-positive sizes signal `wrong-type-argument`; a call during a render signals `etaf-render-side-effect-error`.

**See also.** `etaf-refit`, `etaf-runtime-viewport`, `ebox-mount-set-viewport`.

#### Function: etaf-refit (&optional runtime window)

Refit a mounted Runtime to the display window's current viewport size.

**Arguments.** RUNTIME defaults to the current buffer's Runtime and WINDOW to a window showing that buffer.

**Semantics.** The Runtime's fixed viewport is released and the window's current size becomes the viewport. Mounted Runtimes already follow window resizes through the Ebox viewport bridge, so this call is for windows that bridge does not cover, such as a buffer mounted before the window manager displayed it.

**Returns.** The new viewport as (WIDTH . HEIGHT), or nil when there is no mounted Runtime or no live window, which makes a call from a window-change hook a safe no-op.

**Errors.** None.

**See also.** `etaf-runtime-refit`, `etaf-runtime-viewport`.

## Viewport units

<!-- index: vw; vh; fallback viewport -->

The `vw` and `vh` units read the viewport: one `vw` is one percent of the viewport width, one `vh` one percent of its height. Inside a mount the values come from the measured window; outside one — a tree rendered with `ebox-render` rather than mounted — they come from two variables.

#### Variable: ebox-viewport-width

Viewport width in pixels for rendering outside a mount, or nil.

**Semantics.** When set, the value is the viewport width for rendering outside a mount and the fallback before a display is available. When nil, a graphical session measures the current window and a batch session uses eighty columns. Setting it does not resize any mount; it only supplies the number the units and measurements resolve against.

**See also.** `ebox-viewport-height`, `ebox-viewport-measure`.

#### Variable: ebox-viewport-height

Viewport height in lines for rendering outside a mount, or nil.

**Semantics.** When nil, height is indefinite: `vh` units cannot resolve and block sizes fall back to their content, and a mount in a batch session has no viewport height either. Fixing the variable supplies a definite height for off-screen rendering, and fixing a mount with `ebox-mount-set-viewport` supplies one for a mounted tree.

**See also.** `ebox-viewport-width`, `ebox-mount-set-viewport`.

```elisp :figure Viewport units follow the mount: boxes at 25 vw and 50 vw
(etaf-view
 (column :width '(ch 40) :item-gap '(lh 0)
   (box :width '(vw 25) :padding '((lh 0) (ch 1))
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
     (text :color (etaf-theme-token :ui-accent "#0969da") "25 vw"))
   (box :width '(vw 50) :padding '((lh 0) (ch 1))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
     (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "50 vw"))))
```

## Viewport regions

<!-- index: viewport region; nested viewport; pane -->

An application often lays out for a pane inside a larger mount: a sidebar, an editor area, a panel in a dashboard. A viewport region publishes its own committed box as the viewport of every Component below it, so the same application code reads one reactive viewport whether it fills a buffer or a pane.

#### Function: etaf-viewport ()

Return the viewport of the current Component subtree as (PIXELS . ROWS).

**Semantics.** Inside an `etaf-viewport-region` the value is that region's committed size; elsewhere it is the mounted Runtime's viewport, which is the value `etaf-runtime-viewport` reads. A region reads as nil until its first flush commits geometry, so a Component that renders at that moment must tolerate nil. The value is reactive: a render, effect or computed that reads it runs again after the region or Runtime viewport changes.

**Returns.** The viewport as (PIXELS . ROWS), or nil before a region's first commit.

**See also.** `etaf-viewport-region`, `etaf-runtime-viewport`.

#### Component: etaf-viewport-region ()

Wrap its content in a nested viewport region.

**Semantics.** The region fills the space its parent gives it and publishes that committed box as the viewport of every Component below it. Host attributes passed at the call site (`:class`, `:width`, `:height` and the other Host attributes) override the region's own defaults. The region resolves through the Component ancestor chain rather than the inherited Context, because content passed through a slot is compiled at its call site. Do not give a region padding or a border: its border box is exactly the published viewport, so inset the content inside the region instead.

**Returns.** A View node, like any Component.

**Errors.** A region outside a mounted Component setup raises an error.

**Example.** A 40-by-3 region inside a 60-by-12 column reports `(40 . 3)` to the Components inside it and the mount's viewport to Components outside, until a refit changes the mount.

**See also.** `etaf-viewport`, `etaf-runtime-viewport`.

#### Function: etaf-runtime-viewport (&optional runtime)

Return mounted RUNTIME's viewport as (WIDTH . HEIGHT) in pixels and lines.

**Semantics.** The value is the mount's measured viewport, the same numbers the renderer lays out against. The read is reactive: a render, computed or effect that reads it reruns after the viewport changes, so a Component can size itself from the mount. Before the tree is mounted the first render still gets the viewport the mount is about to take, which is how an initial render sizes correctly.

**Returns.** The viewport cons.

**Errors.** A non-mounted Runtime signals `etaf-runtime-error`.

**See also.** `etaf-viewport`, `etaf-runtime-refit`.

#### Function: etaf-runtime-window-viewport (&optional runtime)

Return RUNTIME's display-window viewport as (WIDTH . HEIGHT).

**Semantics.** WIDTH is the width the window offers to a mounted tree: pixels on a graphical frame and character cells on a text terminal. HEIGHT is its body height in lines. RUNTIME defaults to the Runtime in the current buffer. The read is a plain snapshot, not a reactive one; a Component that must reflow on a window change reads `etaf-runtime-viewport`, which the settled viewport change updates. Use this entry point when a surface has to match the window's geometry rather than the laid-out text viewport; floating panels center and clamp themselves from it on either display.

**Returns.** The window viewport cons, or nil when no window displays RUNTIME's buffer.

**Errors.** A non-mounted Runtime signals `etaf-runtime-error`.

**See also.** `etaf-runtime-viewport`, `etaf-runtime-refit`.

## Viewport change hooks

<!-- index: viewport change hook; settled size -->

#### Hook: ebox-viewport-prepare-functions

Abnormal hook run with a mounted buffer after its viewport size updated and before the relayout flushes.

**Semantics.** `ebox-refit` stores the new viewport dimensions and marks viewport-dependent nodes dirty, then runs this hook before flushing. Reading `ebox-mount-viewport` returns the new size while the tree has not been laid out for it yet, so reactive layers such as ETAF can update viewport-driven nodes and let both the viewport relayout and those updates flush together in one pass.

**Returns.** The hook's value is ignored.

**Errors.** An error in one function does not stop the others.

**See also.** `ebox-viewport-change-functions`, `ebox-mount-viewport`.

#### Hook: ebox-viewport-change-functions

Abnormal hook run with a mounted buffer after its viewport size changed, whether a window resize or `ebox-mount-set-viewport` caused it.

**Semantics.** It runs once the relayout for the new size has settled, so reading `ebox-mount-viewport` inside the hook gives the new size and the buffer already shows the new layout. Applications can use it for their own adaptive work that reads settled geometry outside the render.

**Returns.** The hook's value is ignored.

**Errors.** An error in one function does not stop the others.

**See also.** `ebox-mount-viewport`, `ebox-viewport-settle-delay`.

#### Hook: ebox-display-window-change-functions

Abnormal hook run with a mounted buffer and its display window once a window change settles.

**Semantics.** The viewport task runs it after it refit the buffer's mount, when the window became the buffer's display window or its body pixel size changed since the hook last ran for that buffer. It runs even when a fixed viewport kept the layout unchanged, which is what distinguishes it from `ebox-viewport-change-functions`: state that follows the window rather than the mounted canvas — page sizes, row budgets, a canvas height the caller fixes itself — refits here. While the minibuffer, a completion popup or the echo area borrows lines, a shorter window is not a change and the hook does not run; growth and a frame resize are real geometry and do.

**Returns.** The hook's value is ignored.

**Errors.** An error stops the remaining work of that frame's batch and is reported by the viewport task once the batch ends.

**See also.** `ebox-viewport-change-functions`, `ebox-viewport-settle-delay`.

#### Function: etaf-canvas-cell (&optional runtime)

Return the cell the canvas draws as (CHAR-WIDTH . LINE-HEIGHT) pixels.

**Parameters.** RUNTIME defaults to the canvas in the current buffer.

**Returns.** A cons whose two values are at least 1.

**Semantics.** A mounted canvas answers with the cell it actually draws with; an unmounted one can only answer from the frame's default face, the only measurement left before a mount. A render that turns cells into a layout therefore never measures two different type sizes before and after mounting.

**See also.** `etaf-canvas-columns`, `etaf-display-metrics`.

#### Function: etaf-canvas-columns (&optional runtime)

Return how many whole cells wide RUNTIME's canvas viewport is.

**Parameters.** RUNTIME defaults to the canvas in the current buffer.

**Returns.** A column count of at least 1.

**Semantics.** This is a reactive read: a render that fits its layout this way reruns when the viewport or the cell changes. While the viewport has no pixel width yet it answers one cell, so the first frame never divides by zero.

**See also.** `etaf-canvas-cell`, `etaf-fit-columns`, `etaf-runtime-viewport`.

#### Function: etaf-fit-columns (available preferred minimum &optional gap)

Return a plist fitting AVAILABLE canvas cells into columns.

**Parameters.** Each item wants PREFERRED cells and keeps at least MINIMUM; GAP defaults to 3 cells between items.

**Returns.** `(:across ACROSS :item ITEM :offset OFFSET)`, where ACROSS is how many items a row holds, ITEM their width and OFFSET the cells to leave on one side so the remainder is symmetric.

**Semantics.** Columns are added only while every item keeps MINIMUM, so a wide canvas gains a column instead of leaving one side blank, and a canvas narrower than one preferred item keeps that item whole instead of shrinking it for nothing.

**See also.** `etaf-canvas-columns`, `etaf-canvas-cell`.

## Errors and recovery

<!-- index: viewport errors; indefinite height; first flush -->

Setting a viewport on an unmounted buffer is a no-op rather than an error, and reading one returns nil; a hook that fires for buffers that are no longer mounted should keep that in mind. ETAF's refit APIs are stricter: a non-mounted Runtime signals `etaf-runtime-error`, non-positive dimensions signal `wrong-type-argument`, and calling a refit while rendering signals `etaf-render-side-effect-error`; `etaf-refit` returns nil instead when there is no window to measure, which makes it safe in window hooks.

An indefinite height is the one viewport value that looks like a failure but is not: a batch session has no window, so `vh` units and block sizes that follow the viewport fall back to content. When that matters — a test asserting a full-screen layout, or an off-screen render — fix the height with `ebox-mount-set-viewport` or `ebox-viewport-height` and the units resolve again.

A region reads nil until its first flush commits geometry. A Component whose render reads `etaf-viewport` may therefore see nil on its first pass inside a region; guard the nil case or render a placeholder, and the reactive update supplies the real size as soon as the region has been laid out.
