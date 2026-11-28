# Images

An image reaches the screen only after it has been prepared. Preparation reads the source, runs a converter or builds and decodes an Emacs image descriptor, and returns an immutable character grid. Layout and buffer writes reuse that grid without source I/O or subprocesses; painting may derive cached native background or brightness composites from the bytes already in memory. This chapter describes the preparation step, the converter protocol applications can extend, the difference between a graphical frame and a character-cell fallback, the cache that makes repeated preparation cheap, and the one-line-one-glyph invariant the graphical adapter is built around. [Text](text.md) describes the character content an image node sits beside; the image Host in [Hosts](hosts.md) wraps this model for applications, and `ebox-node-set-image` replaces a prepared image in place.

## Preparation

<!-- index: image preparation; prepared image; source; adapter; inset -->

`ebox-image-prepare` is the only I/O boundary of the image model. Its SOURCE is a local file name — expanded, with its truename, size, modification times and inode forming the cache identity — or an Emacs image descriptor that carries `:file` or `:data`. Remote files are rejected before reading. COLUMNS and ROWS are the character area the image must fill, and the adapter choice decides which path is tried: `auto` tries a graphical descriptor first, then Kitty terminal graphics on compliant 24-bit text frames, then the converter list, then a monochrome placeholder; `kitty` tries only Kitty terminal graphics before falling back to the placeholder; `text` skips both graphics paths; `placeholder` skips all of them.

#### Function: ebox-image-prepare (source columns rows &key (adapter 'auto) (frame (selected-frame)) inset (converters ebox-image-converters))

Prepare SOURCE for an integer COLUMNS by ROWS character area.

**Arguments.** SOURCE is a local file or an Emacs image descriptor containing `:file` or `:data`. COLUMNS and ROWS are positive integers. ADAPTER is `auto`, `kitty`, `text` or `placeholder`. FRAME supplies the font metrics a graphical desktop uses or the terminal tested for Kitty graphics. CONVERTERS obeys `ebox-image-converters`. INSET is nil or `(TOP . BOTTOM)`, pixels below one line height that a graphics image leaves empty above and below it inside its rows.

**Semantics.** The call reads and decodes everything it needs and returns a detached value; nothing about layout or buffer writing touches the source again. Under `auto`, a graphical frame with usable font metrics and a usable image type produces a slice-based descriptor; on a compliant 24-bit text terminal Kitty Unicode placeholder graphics are tried next; otherwise the converters are tried in order; if all of them decline, a monochrome placeholder grid is produced. A missing or corrupt image ends in the placeholder rather than an error. Identical preparations are answered from the cache.

**Returns.** An opaque reusable value for an image node or for `ebox-image-info` and `ebox-image-content`.

**Errors.** A non-positive COLUMNS or ROWS, an unknown ADAPTER, a malformed INSET, a converter list that is not an alist of symbol-and-function pairs, or a SOURCE that is neither a local file nor a valid descriptor raises an error before anything is read.

**Example.** `(ebox-image-prepare "cover.png" 24 12 :adapter 'placeholder)` returns a 24-by-12 grid of dots for use in a layout that must not depend on the display.

**See also.** `ebox-image-info`, `ebox-image-content`, `ebox-image-cache-clear`.

## The converter protocol

<!-- index: image converter; half block; truecolor; converter protocol -->

A converter turns one source into a truecolor half-block character grid. It is called only during preparation, and it must not mutate the source. The built-in list tries `chafa` first — asking for truecolor `▀` symbols at the requested size — and then `ffmpeg`, which scales the source to twice the row count and packs each pair of RGB pixels into one cell's foreground and background. Neither program is a package dependency; when neither is installed, or both decline, preparation falls back to the placeholder. Applications extend the list with their own converters, and a converter that throws or returns a malformed grid declines to the next one, so an experimental converter cannot break rendering.

#### Variable: ebox-image-converters

Ordered (NAME . FUNCTION) image converters, called only by preparation.

**Semantics.** FUNCTION receives SOURCE, COLUMNS and ROWS and returns nil to decline, or a string of exactly ROWS lines of COLUMNS `▀` characters, each with a `face` plist containing 24-bit `:foreground` and `:background` strings of the form `#RRGGBB` and no trailing newline. Any other result, including a raised error, declines. Only the two colors are copied out of a result; a converter cannot inject display specifications, keymaps or node ownership into the prepared value. Change a converter's NAME or clear the image cache when its behavior changes, because the cache key holds the list as it was.

**Example.** A converter returning a well-formed three-by-two grid is accepted as `(:adapter text :converter ok :columns 3 :rows 2)`; the same list with a wrong character, a non-`#RRGGBB` color, a raised error and a nil result in front still ends at the working one.

**See also.** `ebox-image-prepare`.

## Graphics, text and placeholder adapters

<!-- index: graphics adapter; text adapter; placeholder; transparency -->

On a graphical frame the `graphics` adapter creates one Emacs image descriptor scaled to COLUMNS times the frame's character width and ROWS times the line height, decodes it during preparation — warming Emacs' own image cache before the block is published — and represents each row as a single space glyph carrying a horizontal slice of that descriptor. A 4-by-2 image on a frame with 7-by-14 cells becomes two glyphs: the first shows the descriptor's pixels from y 0 to y 14, the second from y 14 to y 28. INSET shrinks the slice height by the requested pixels and raises the slice inside the row, so the image keeps the line height and shows the box background in the gap above and below it; a one-pixel inset on the same image makes the slices 13 pixels tall.

In a terminal, or under `:adapter text`, the same prepare call produces a character grid: every cell is a `▀` half block whose face carries the averaged colors of the two source rows it stands for. The grid is plain text from the layout's point of view — the paragraph or image node treats it as columns of characters — so a terminal gets a readable, if coarse, rendering. The placeholder adapter produces the same shape of grid with `.` characters and no faces, which is what a layout or a test sees when neither graphics nor converters are available.

A graphical image's transparent pixels show the background of the box that holds it, composed during paint. This is why the same source can sit on a tinted row without showing frame-colored corners. Filtered overlays use the shared [`:backdrop-filter`](style-properties.md#style-backdrop-filter) image path; they never re-prepare the source, replace the picture with a flat cover or change its slice geometry.

**Example.** On a frame whose cells are 7 by 14 pixels with a 79% ascent, preparing a 4-by-2 PNG yields `(:adapter graphics :converter nil :columns 4 :rows 2)`, two rows of one glyph each, the first with display `(slice 0 0 28 14)` and the second `(slice 0 14 28 14)` — 28 pixels being four cells wide. The fallback grid for the same call without a graphical frame is four characters per row.

## Cache and inspection

<!-- index: image cache; prepared value; cache eviction -->

Preparation results are cached by source identity, size, adapter, frame metrics, inset and the converter list. The cache is bounded and drops its least recently used entries when it grows past 256, so a screen with many images does not evict every unrelated preparation at once. A live prepared value keeps working after eviction — it is detached and immutable — but the next prepare for the same source rebuilds the grid.

Brightness composites have a separate weak identity cache, with at most eight recent variants per live image or display. The key includes the amount, native foreground, filtered background and frame. The first variant builds an in-memory SVG descriptor and native redisplay decodes it; subsequent paints share that descriptor across all row slices. A new source, palette or amount gets its own variant, while an identity filter uses the original descriptor. The cache never owns input callbacks or mounted trees.

#### Function: ebox-image-content (prepared)

Return an owned character string for PREPARED, without any I/O.

**Arguments.** PREPARED is a value returned by `ebox-image-prepare`.

**Semantics.** The returned string is a shallow copy: its characters and faces are fresh, while a graphical row's nested display descriptor and slice values are shared. Lines are separated by newlines, so an image node gets one line per row. Do not mutate the nested display values.

**Returns.** The raster as a string.

**Errors.** A value that is not a preparation raises an error.

**See also.** `ebox-image-prepare`, `ebox-image-info`.

#### Function: ebox-image-info (prepared)

Return PREPARED's adapter, converter, columns and rows as a fresh plist.

**Arguments.** PREPARED is a value returned by `ebox-image-prepare`.

**Semantics.** The plist has the keys `:adapter` (`graphics`, `kitty`, `text` or `placeholder`), `:converter` (the name of the converter that produced a text grid, or nil), `:columns` and `:rows`. The value is fresh, so callers may keep or modify it.

**Returns.** The plist.

**Errors.** A value that is not a preparation raises an error.

**See also.** `ebox-image-prepare`, `ebox-image-content`.

#### Function: ebox-image-cache-clear ()

Release cached preparations and paint composites without changing live images.

**Semantics.** Clearing the cache does not touch any prepared value or painted descriptor already held by a node, but the next `ebox-image-prepare` for the same arguments prepares again and later filtering rebuilds its composites. Call it after installing or reconfiguring converters, or when a font or display capability change makes the cached metrics stale.

**Returns.** The reset access counter, 0; the clearing itself is the effect callers rely on.

**See also.** `ebox-image-converters`.

## The one-glyph line

<!-- index: image invariant; one glyph per line; image node -->

The graphical adapter's defining invariant is that one image row is one glyph. Each row of the prepared grid is a single character whose display specification carries a full-width slice, so redisplay paints the row in one step; a design that put one slice per cell would multiply the cost of every repaint and scroll by the column count. The invariant is why a graphical image always has exactly ROWS lines, why its horizontal size is COLUMNS times the cell width, and why `:inset` is implemented as a shorter slice plus a raise instead of extra pixels or lines.

An image node lays those rows out as they are: `ebox-node-create 'image` with the prepared value under the `:image` property produces an item whose height is the row count and whose width is the widest prepared line. A stretched image box fills the extra horizontal space with its background, and the grid never reflows — resizing the container does not re-prepare the image. To change an image in place, prepare the new value and call `ebox-node-set-image`; the node keeps its slot and the flush repaints it.

## Kitty terminal graphics

<!-- index: kitty graphics protocol; unicode placeholder; terminal image; kitty stream -->

On a 24-bit text terminal that implements the Kitty Graphics Protocol with Unicode placeholders (`U=1`, such as Kitty 0.28+, Ghostty, Ghostel and iTerm2 3.6+), Ebox transmits the image once under a process-scoped 24-bit image ID and paints a COLUMNS by ROWS grid of composed `U+10EEEE` placeholder cells whose `:foreground` face carries that ID. Because each cell is one text column carrying its own row, column and MSB combining diacritics, Ebox's normal text layout, line diffing, scrolling, horizontal clipping and modal overlays work without cursor-tracking hooks, transparent PNG or rasterized SVG pixels composite over the enclosing box's `:background`, and hover or backdrop dimming preserve the image ID foreground color. Local PNG files transfer directly with `t=f`; SVG and other raster formats convert to PNG when `rsvg-convert`, `ffmpeg`, ImageMagick or macOS `sips` is available, falling back to `ebox-image-converters` and placeholders when unavailable.

#### Variable: ebox-image-kitty-protocol

Control Kitty terminal graphics protocol use on text frames.

**Semantics.** The value defaults to `auto`, which probes each text terminal once with a single round-trip query and enables Unicode placeholder graphics on compliant 24-bit terminals (Kitty 0.28+, Ghostty, Ghostel and iTerm2 3.6+). Setting it to `t` enables transmission on any 24-bit text terminal that acknowledges the Kitty graphics query without checking the terminal name. Setting it to nil disables the protocol so text frames always fall back to `ebox-image-converters` or placeholders.

**See also.** `ebox-image-kitty-available-p`, `ebox-image-prepare`.

#### Function: ebox-image-kitty-available-p (&optional frame)

Return a capability plist when FRAME supports Kitty terminal graphics, or nil.

**Arguments.** FRAME defaults to the selected frame.

**Semantics.** Returns nil in batch sessions, on graphical frames, when `ebox-image-kitty-protocol` is nil, or when FRAME's terminal lacks 24-bit color or Kitty Unicode placeholder support. Otherwise probes the terminal once (caching the result per terminal) and returns a fresh plist with `:cell-width`, `:cell-height` (pixel dimensions of one terminal cell) and `:local` (whether local file transfers are available).

**Returns.** A capability plist or nil.

**See also.** `ebox-image-kitty-protocol`, `ebox-image-kitty-stream-create`.

#### Function: ebox-image-kitty-stream-create (columns rows &optional frame)

Create a Kitty virtual placement stream for COLUMNS by ROWS cells on FRAME.

**Arguments.** COLUMNS and ROWS are positive integers within the Kitty diacritic limit (297). FRAME defaults to the selected frame.

**Semantics.** Allocates a process-scoped image ID and prebuilds its static Unicode placeholder grid so live producers such as `etaf-video` can publish the grid once and push frame bytes in place without rewriting the buffer.

**Returns.** An opaque stream handle, or nil when FRAME does not support Kitty terminal graphics.

**Errors.** Non-positive dimensions or dimensions exceeding the diacritic limit signal `error`.

**See also.** `ebox-image-kitty-stream-grid`, `ebox-image-kitty-stream-present`, `ebox-image-kitty-stream-destroy`.

#### Function: ebox-image-kitty-stream-grid (stream)

Return an owned Unicode placeholder grid string for Kitty STREAM.

**Arguments.** STREAM is a handle returned by `ebox-image-kitty-stream-create`.

**Returns.** A fresh copy of the COLUMNS by ROWS placeholder grid string.

**Errors.** A value that is not a Kitty stream signals `error`.

**See also.** `ebox-image-kitty-stream-create`, `ebox-image-kitty-stream-present`.

#### Function: ebox-image-kitty-stream-present (stream bytes width height &optional format)

Present one unibyte frame of BYTES (WIDTH by HEIGHT) into Kitty STREAM in place.

**Arguments.** STREAM is a Kitty stream handle. BYTES is a unibyte string. WIDTH and HEIGHT are positive integers. FORMAT is `rgb24` (default), `rgba32` or `png`.

**Semantics.** Transmits the frame under STREAM's image ID and virtual placement (`U=1`, `q=2`), using an auto-deleted temp file (`t=t`) on local terminals and 4096-byte chunked base64 (`t=d`) over remote connections. Already-displayed placeholder cells update in place without modifying Emacs buffers.

**Returns.** `t` when transmitted, or nil after STREAM was destroyed or its terminal closed.

**Errors.** Invalid stream, multibyte payload, non-positive dimensions, unsupported format or mismatched raw byte count signal `error`.

**See also.** `ebox-image-kitty-stream-create`, `ebox-image-kitty-stream-destroy`.

#### Function: ebox-image-kitty-stream-destroy (stream)

Destroy Kitty STREAM and release its image data on its terminal.

**Arguments.** STREAM is a Kitty stream handle.

**Semantics.** Sends a quiet delete command (`a=d,d=I`) for STREAM's image ID when its terminal is still live and marks STREAM destroyed. Calling it more than once is a safe no-op.

**Returns.** Nil.

**Errors.** A value that is not a Kitty stream signals `error`.

**See also.** `ebox-image-kitty-stream-create`.

## Errors and recovery

<!-- index: image errors; missing image; converter failure -->

Argument errors — non-positive columns or rows, an unknown adapter, a malformed inset, a bad converter list, a remote or non-file source — surface at preparation, before any I/O, with the messages listed under `ebox-image-prepare`. They are programming errors rather than data conditions.

A source that cannot be read, decoded or converted is not an error by design. The graphical path declines, the converters decline, and a placeholder grid takes their place, so a layout never fails because a picture is missing; `ebox-image-info` tells the application which adapter actually produced content, so it can show a different message for a placeholder. Installing a new converter takes effect for new preparations once the cache is cleared, and a converter whose behavior changes should get a new name for the same reason.
