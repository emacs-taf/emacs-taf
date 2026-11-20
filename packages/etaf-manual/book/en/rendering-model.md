# The Rendering Model

Ebox renders a retained node tree into an Emacs buffer. A View published through ETAF, or a tree built with the Ebox API directly, becomes nodes; layout resolves a border box for every node; paint composes each root line from those boxes; and the buffer holds the composed lines. This chapter describes the model that the remaining layout and rendering chapters build on: the retained tree as the single source of truth, the coordinate system of lines and pixels, the display primitives that keep layout exact, how font fallback is kept from breaking the line height, and what differs between graphical frames and terminals. [Hosts](hosts.md) defines the box kinds this model lays out and [Runtime](runtime.md) defines how a published View becomes a mounted tree; the three function entries below are Ebox library interfaces, documented through their concepts.

## The retained tree is the source of truth

<!-- index: retained tree; output cache; incremental update; dirty node -->

A mount owns one retained node tree, and the tree is the model: its nodes, properties, computed styles, geometry and content decide what the buffer shows. The buffer is only the rendered output of that model. The first flush of a mount erases the buffer and writes the whole tree; every later update restyles, relayouts and repaints only the affected boxes and writes only the lines whose content changed. An update outside `ebox-with-batch` flushes at once, so the buffer is up to date as soon as the authoring call returns.

Because the tree is the model, the buffer text is not data. A foreign edit to the buffer is unknown to the tree; the next update driven by the tree rewrites the affected lines from their nodes and the edit disappears. Anything that must survive an update therefore belongs in the tree, or in the state that produces it — a reactive value, a Component's state, an application record — and never in the buffer text alone. The same rule applies to positions: a buffer position is an output of one layout and a later update can move it, so code that must follow a node stores the node, not the position, and asks for the node's current geometry or position when it needs them.

Rendering does not require a mount. `ebox-render` lays a tree out and returns its lines as a string, which is how previews and tests show a tree without a buffer; `ebox-mount` binds a root to a buffer and starts writing updates there. Both paths run the same layout and paint, so a tree renders the same way whether or not it is mounted.

```elisp :figure From View to Ebox tree to buffer lines
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 0)
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
        (text :color (etaf-theme-token :ui-accent "#0969da") "View：描述"))
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
        (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "→ Ebox：保留节点树、几何与计算样式"))
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
        (text :color (etaf-theme-token :ui-disabled-fg "#687386") "→ buffer：行、文本属性与 display 对象"))))
```

## Coordinates: lines and pixels

<!-- index: coordinate system; border box; line height; pixel width; length unit -->

Vertical geometry is line based and horizontal geometry is pixel based. A node's border box is reported as `:x`, `:y`, `:width` and `:height`: `:x` and `:width` are pixels and `:y` and `:height` are lines. A box styled `:width (px 20)` and `:height (lh 3)` reports a width of 20 and a height of 3, and renders as three lines; the same box inside a container that stretches it takes the container's pixel width while its height still counts lines.

One line is one graphical text row. Ebox sizes the line from the fonts that carry body text, Latin and CJK: the tallest ascent plus the largest descent among them, probed once per frame, so a CJK font with a taller line box raises the line instead of shrinking Chinese text into the Latin one. Every row is exactly that tall, and a row holding only shorter glyphs carries a zero-width space one line high as its `line-prefix`. Content that would need a taller row is fitted instead, as the next sections describe. Horizontal sizes resolve in pixels — the inline space available to a box is its containing block's inner width in pixels — while block sizes resolve in lines. [Style Properties](style-properties.md) defines the `px`, `ch`, `lh` and `vh` units that produce those values and the constraints a box's size may have.

The rendered form keeps this split visible: a line of output is one buffer line. Consecutive buffer lines normally belong to consecutive root lines, but the mapping is an output detail that a later update may change, and a box's interior may span several rows; code that cares about a box asks for its geometry rather than counting buffer lines.

## Display primitives

<!-- index: display space; pixel measurement; measurement cache; measurement context -->

Text in a buffer is a sequence of characters, but layout places content at exact pixel offsets. Two primitives bridge the difference. A *pixel space* is a character whose display specification gives it an arbitrary width, so a layout can put any number of pixels between two pieces of content. A *pixel width measurement* converts the characters, faces, display specifications and clusters of a string into the pixels they occupy.

Both primitives share one measurement cache, keyed by the face that decides glyph advances: faces that differ only in paint — foreground, underline, stipple — share one width table, so a repaint without a metric change never invalidates measurement. Measurements are remembered per face and per multi-character cluster, and `ebox-clear-cache` empties the memory of both primitives together when the metrics behind it change.

#### Function: ebox-pixel-space (pixel-width)

Return a display space PIXEL-WIDTH pixels wide.

**Arguments.** PIXEL-WIDTH is a width in pixels. A nil value counts as 0.

**Semantics.** The result is a one-character string whose `display` property is a space specification of that width. A width that is not positive yields the empty string, so a computed gap of zero adds nothing. Equal widths share one object while the measurement cache holds them, which lets composed lines compare them by identity; clearing the cache leaves every width intact but rebuilds fresh, `equal` objects. This is how layout writes spacing that no character can express: gaps, alignment, and the spaces that keep text columns aligned at pixel boundaries.

**Returns.** The display space as a string, or the empty string for a non-positive width.

**Example.**

```elisp
(ebox-string-pixel-width (ebox-pixel-space 8))
     ⇒ 8
```

**See also.** `ebox-string-pixel-width`, `ebox-clear-cache`.

#### Function: ebox-string-pixel-width (string)

Return the display pixel width of STRING's first line.

**Arguments.** STRING is the string to measure. A nil value counts as "".

**Semantics.** Only the first line is measured, meaning the part before the first newline. The measurement follows the string's own properties, so a run carrying a `face` property measures under that face, a pixel space measures as its width, and a multi-character cluster measures as its own unit. STRING is not inserted into a buffer and the current buffer is not modified, so the function can be called while composing layout; repeated measurements are answered from the per-face cache.

**Returns.** The width in pixels as an integer. The empty string measures 0, and so does a string that starts with a newline.

**Example.**

```elisp
(= (ebox-string-pixel-width "Save\nDraft")
   (ebox-string-pixel-width "Save"))
     ⇒ t
```

**See also.** `ebox-pixel-space`, `ebox-clear-cache`.

#### Function: ebox-clear-cache ()

Clear pixel width caches after font or named face metrics change.

**Arguments.** None.

**Semantics.** The remembered glyph widths, cluster widths, pixel spaces, image widths and default font metrics are dropped, so every later measurement is computed again with the current metrics. Already composed lines are not laid out again; they keep their text until the next tree-driven update rewrites them. This is a host call, made when a configuration changes the default font, a named face's font, or text scaling through face remapping; Ebox does not call it on its own, and calling it again is harmless.

**Returns.** The new measurement epoch, an integer that increases on every call.

**Example.**

```elisp
(ebox-clear-cache)
     ⇒ 1   ; the first clear; the next call returns 2
```

**See also.** `ebox-string-pixel-width`, `ebox-pixel-space`.

The two primitives round-trip: a pixel space measured by `ebox-string-pixel-width` reports exactly its width, so a layout can reserve pixels with a space and measure the result without a special case, and text that mixes words and spaces measures as the sum of its parts.

## Font fallback and the line height

<!-- index: font fallback; fitted glyph; emoji; line height -->

When the face of a character has no glyph for it, Emacs draws the character with a fallback font. A fallback font can have a larger ascent or descent than the body fonts that size the line, and an unfitted fallback glyph would make its row taller than the rows around it and shift the vertical grid.

Ebox keeps the line height by fitting such glyphs on graphical frames. The body fonts already size the line, so fitting covers the glyphs outside body text: colour emoji, symbols, mathematical letters and rarer scripts. A character whose fallback font may exceed the default font's line is measured beside an ordinary character — the comparison belongs in a row, not in isolation, because the row height combines the largest ascent with the largest descent. When the candidate would make the row taller, Ebox paints it scaled down, trying a fixed sequence of `height` scales from 0.9 down to 0.3 and keeping the largest one that still fits the line. On macOS graphical frames a colour emoji that would exceed the line is instead shown as an image at full line height; [Images](images.md) covers that path and its caches. The character is never replaced by a different one, only shown in a fitted form, so copying text out of the buffer still yields the original characters.

Terminals and batch sessions have no fonts to measure, so nothing is fitted there and every row is one text line. A cluster that no scale fits is drawn at the smallest scale, and the row still holds one line, because a taller row would move every line below it.

## Graphical frames and terminals

<!-- index: graphical frame; terminal; batch session; capability -->

The same tree renders on a graphical frame and on a terminal; the model above does not change, but the capabilities it rests on do. Rounded outlines reuse cached corner images keyed by geometry, palette and display metrics, not by nodes or callbacks. Only the first and last lines need those slices; ordinary middle lines retain native text and border faces. Original display units are checked before cutting so a partial glyph cannot be mistaken for blank padding. See [Style Properties](style-properties.md#style-border-radius) for radius limits and square fallback.

| Aspect | Graphical frame | Terminal |
| --- | --- | --- |
| Measurement | real font metrics; character widths are font pixels | one text line per row; widths follow the terminal's character grid |
| Fitting | fallback glyphs are fitted and colour emoji can be image-based | nothing is fitted; a row is a text line |
| Backgrounds | rounded corners and fractional block padding are painted as shapes | a background fills the whole border box |
| Outlines | complete same-color 1 px solid frames use corner slices when blank padding permits; text stays native | one-cell box rules (`┌─┐`, `│`, `└─┘`) when the character width table agrees; otherwise square border faces |
| Typography | `:font-size` scales the glyphs | one face size; a node that raises its size takes bold weight, and children inherit it |
| Images | drawn at the frame's cell metrics | approximated with characters |

A batch session has no window and no display: a mount still renders, with a viewport that falls back to the displaying window when there is one and to the fixed dimensions otherwise, and measurements use the default font's nominal metrics. Tests, previews and command-line tools rely on this, but it also means a pixel width measured in batch need not equal the width on a graphical frame, and layout that must be exact should be checked graphically.

## Errors and recovery

<!-- index: measurement tolerance; stale cache; foreign edit -->

The measurement primitives accept degenerate input without signaling: nil and the empty string measure 0, and a non-positive pixel width produces no space. Fitting is skipped where there is no font to fit, not reported as an error, so the same tree renders on every display kind with the same public calls.

Measurement results can go stale only when the metrics they were computed from change. The recovery is `ebox-clear-cache`, after which the next measurement is recomputed from the new metrics; until then, already composed lines keep the old text, and the tree-driven update that follows the clear is what makes the new metrics visible in the buffer. Ebox never clears the cache by itself, so a host that changes a font without clearing reports widths from the old font until it does.

The buffer is output, so a foreign edit to it has no recovery path of its own: the next update driven by the tree rewrites the affected lines and the edit is gone. A document that must accept editing has to model the edit on the tree side, which is what the text-input and incremental-update interfaces provide; the [Text Input](text-input.md) and [Incremental Updates and Publication](incremental-updates-and-publication.md) chapters describe them.
