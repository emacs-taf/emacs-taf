# Changelog

All notable changes to Ebox are documented here.

## Unreleased

### Changed

- Reissued as 3.1.4 after package-loading and workspace updates since 3.1.3.

### Fixed

- Sizes render the same in batch as in a window.  The default face height
  was read in points without its tenths outside a window system, so a ratio
  written for a heading came out ten times smaller than the same ratio drawn
  on screen.

### Changed

- `:font-size` is a ratio of the body size, not a pixel size.  A style says
  `1.42` for a heading and `0.85` for a caption, and Ebox turns that into the
  face height the frame's own default font gives it.  The old pixel size
  assumed 96 dots per inch and had to be converted at every use, which is what
  made one document look different on two platforms and left a second
  conversion in every application.

### Fixed

- A face that raises the size keeps its Chinese as tall as its Latin.  A
  face's line box probed only the Latin `"0"`, so a heading read its CJK font
  as an overflowing fallback glyph and fitted the text down to the body size.
  The line box now probes the same body scripts as the default face, per face.

- A fitted glyph shrinks from its own size.  The `height` display factor counts
  from the default face, so a heading that needed a slight fit fell to the body
  size; the factor now carries the face's own height.

- A picture is drawn in the pixels the page places it in, so a display with two
device pixels per point no longer shows its labels twice.  The prepared image
asked for one image pixel per device pixel as well as for a width and height in
page pixels.  On such a frame it was drawn at twice its size while its rows were
still cut for the page size, so each row of it held half a row of the drawing:
every label appeared again, a few pixels lower, and a diagram looked doubled
while its boxes looked almost right.  Page pixels now decide the size, and the
frame's own scale decides only how finely it is drawn.

- Pointer hover follows the pointer inside its own frame.  The guard measured
the display-absolute pointer against the window's reported absolute edges, but
a child frame can be placed relative to its parent while those edges omit that
origin; a mounted panel therefore highlighted the rows below the pointer
(three rows in a typical panel) and flickered between them and the pointed row
while the pointer moved.

- Chinese and other CJK text keeps its own font size.  A row's line height was
taken from the Latin font alone, so a CJK font with a taller line box was
treated as a fallback glyph and scaled down to 0.8 of its size, which also
made its line breaks too tight.  The line now covers the body fonts of the
face, Latin and CJK, and every published row is one line high, so a taller
CJK font raises the rows instead of shrinking its glyphs.

- A row's height carrier starts the line instead of ending it.  A row of
  shorter glyphs still takes the line height, and a row that reaches the
  window's right edge keeps it instead of losing the carrier at the
  truncation boundary.  The buffer text carries the carrier at each line's
  start, so copied text includes it.

- Pointer hover no longer sets `track-mouse' in a mounted buffer.  A painted
  `help-echo' probe paints entry and a short guard follows the pointer until
  no feedback remains, so motion over another window never runs a command
  here; a global click-ripple hook could draw on every move.  Each run's
  original help value is preserved through the probe.

- A canvas no taller than its window stays at its first line after a rewrite:
  the window start is no longer restored to a line the rewritten content no
  longer reaches, so a panel that shrank does not leave its window blank.
- A wheel turn that no scroll region consumes no longer scrolls the window
  of a mounted tree that already fits: the fallback measures the painted tree
  instead of asking whether `point-max` is visible, so a canvas stays pinned
  instead of sliding every region at once.

- A partial update that moves several rows and changes the page height leaves
  no vacated row behind.  Each changed node was recorded at the line it now
  occupies while the edit list still applied to the old page, so closing a
  tall row and opening another kept the old header of a moved row under the
  following block.  Such an update rewrites the page; a single changed node
  keeps its line edits.

### Added

- `ebox-keymap-create` accepts `:drag-edge`: a drag that has moved and rests
  in or past a window edge band then receives repeating `edge` phases whose
  `:edges` name the touched edges and whose `:elapsed` gives the seconds since
  the previous one.  The tracker reports intent only; the callback owns
  the scroll.  `ebox-drag-edge-band` and `ebox-drag-edge-interval` set the
  band and cadence, and the gesture protocol is documented in the entry
  Commentary.

- `ebox-display-window-change-functions` runs with a mounted buffer and its
  display window once a window change settles, after the refit, whenever that
  window's body size changed or it became the display window.  It also runs
  under a fixed viewport, so state that follows the window (page sizes, row
  budgets, a self-fixed canvas height) refits in the same settle instead of in
  a second resize handler of its own.

### Fixed

- `ebox-node-scroll-offset` reports the offset a scroller shows.  When
  content shrank below a scrolled offset, the scroller showed its last lines
  but kept reporting, and scrolling from, the old offset: the next scroll
  command moved nothing visible and passed the remainder to the window.
  Scrolling now starts from the shown offset.

- A drag no longer keeps moving after the window system loses its button
  release.  A new press of the primary button ends an unlocked drag with
  `end` at its last position and then starts its own gesture; it used to
  cancel the drag with reason `input`.  While a drag is tracked, a shown or
  pending tooltip is hidden and help echo is suppressed, because tooltip work
  makes the macOS port lose releases more often.

- Automatic grid placement no longer rescans the occupied cells from the
  grid's origin for every item.  Each search resumes after the cells already
  taken, so placing N items is linear instead of quadratic; items still take
  the earliest free area in flow order.  Re-laying out an auto-placed sheet of
  56 rows by 35 columns after a one-row scroll fell from about 356 ms to 71 ms.

- Escape during a drag cancels it with `quit` and is consumed.  It was pushed
  back to the command loop, where the still-held button's release completed it
  as an undefined `ESC <drag-mouse-1>` sequence and rang the bell.

- Text-terminal frames draw borders with box-drawing characters: side borders
  are one-cell rules instead of filled colour bands, and a blank top or bottom
  border row becomes a same-width `┌──┐` / `└──┘` frame.  A row that carries
  content keeps its overline and underline decorations.

- A terminal has one face size, so a node that raises its font size takes bold
  weight and its children inherit it; a root-level size change is the
  application's global choice and stays unemphasized.

- Text measurement works on Emacs 29 and 30, where `string-pixel-width`
  accepts no buffer.  Ebox measures in a work buffer that copies the
  measuring buffer's face remapping and default text properties, so text
  scaling selects the same widths as on Emacs 31.

- Optional native image and font calls no longer produce undeclared-function
  warnings on text-only Emacs builds. Wheel events outside a mounted Ebox
  buffer load the standard mouse-wheel library for their fallback handler.

- A local paint or same-height text update inside a stationary overlay now
  publishes its changed rows instead of repainting the entire panel. Movement,
  resizing, stacking changes and structural updates keep full coverage and
  never insert or delete the surrounding canvas's rows.
- Mounting a previously laid-out tree replaces the whole destination buffer,
  even if foreign edits changed its row count. Old line coordinates and
  newline input properties no longer leak into the new mount.
- Restyling a retained line keeps its unchanged characters and native markers
  in place. Local text edits preserve their common prefix and suffix, while
  native displays and input properties retain the composed objects' identity.
  Whole-buffer publication inserts composed parts without allocating temporary
  concatenated lines.
- Backdrop updates filter only the background spans they actually show and
  apply input ownership on the same owned copy, reducing transient allocation
  during modal search and editing without changing colors or hit isolation.
- Blank identity-filtered hit surfaces preserve text glyphs crossed by their
  edges instead of replacing partial glyphs with spaces. Native text input
  uses whole-glyph ownership; image and space slices stay pixel-exact.

- Filtered backdrops now dim PNG, JPEG and SVG pixels on graphical frames
  with SVG support, including native `currentColor` icons. Cached in-memory
  composites preserve alpha, image slices, row insets and the application
  palette without reopening sources or running external converters.
  Other native formats stay visible without pixel filtering.
- Removing and reattaching the same overlay at unchanged coordinates now
  repaints it instead of retaining the uncovered background.

- Reattaching a retained subtree restores its absolute descendants and their
  style context. Closing an in-buffer overlay no longer loses positioned
  application content or leaves later responsive child updates unstyled.

- Filtered backdrops now keep their own native keymaps, hit ownership,
  pointer and help feedback over the visible background pixels. Outside
  clicks can dismiss the covering modal without activating covered controls.

- A tab stop scrolled out of a scroller can receive focus again.  The cover
  check that rejects controls hidden under an overlay used the stop's layout
  line, so a line that happened to lie under a fixed region (a footer, a
  toolbar) blocked focus even though the stop was merely scrolled away.
  Focus now reveals scrolled-out stops while a stop genuinely covered by an
  overlay still refuses focus.

### Added

- `ebox-focus-edge` accepts an optional subtree root, keeping Home/End-style
  focus movement and participating focus groups inside a caller's boundary.

- `ebox-mount` accepts an `:observer` installed before its first flush, so
  root replacement can keep complete paint timing and update reports.

- Complete, same-color 1 px solid borders now follow `:border-radius` on
  graphical frames with SVG support. Corners use only blank padding; text
  and images are never covered to make room for a curve. Other borders and
  terminals keep square outlines, with no change to layout or input.

- The `:backdrop-filter` style property dims the cells an overlay covers while
  keeping their text and images visible.  Its `(brightness AMOUNT)` value
  multiplies the covered foreground and background colors, so a modal backdrop
  keeps the application painted instead of covering it.

- Keyboard focus models composite widgets: `:focus-group` (`vertical`,
  `horizontal` or `grid`) makes a container one Tab stop entered at its
  selected or last focused member and roved with arrows; `:focus-scope modal`
  confines navigation to an open dialog; `ebox-focus-direction` moves to the
  nearest stop in a direction; `ebox-focus-scope` and `ebox-focus-stops`
  expose the scope; `ebox-focus-change-functions` reports each focus move.

- Box backgrounds take `:border-radius` on graphical frames, and block
  padding accepts fractions of a line such as `(lh 0.5)`, painting the
  background over that part of the line while rows keep one line height.
- `ebox-image-prepare` accepts `:inset (TOP . BOTTOM)` to leave a few pixels
  blank above and below a graphics image without changing its rows.
- On macOS, colour emoji are shown as full-height line images rendered by a
  helper compiled with `swiftc` and cached under `ebox-emoji/` in
  `user-emacs-directory`.
- Soft wraps keep closing punctuation off line starts and opening
  punctuation off line ends.
- `ebox-input-begin` accepts `:on-change`, `:on-leave`, `:keymap` and
  `:local-variables`; `ebox-input-edit-commands` lists the keymap commands
  that edit the value.
- The `:scroll-anchor end` style keeps a scroller pinned to its last line
  as content changes until the user scrolls away, for logs and chat views.
- `ebox-node-scroll-into-view` scrolls enclosing scrollers so a node shows.
- The `:swipe` interaction property receives one `left` or `right` call per
  horizontal two-finger trackpad gesture over a node, with momentum absorbed.
- The `:scroll` interaction property receives a scroller's new line offset
  whenever scrolling changes it, so lists can load more rows at an edge.
- `ebox-node-scroll-into-view` takes an optional `start` or `end` alignment.
- `ebox-viewport-measure` returns the viewport a buffer's mount would take,
  before the buffer is mounted.
- `ebox-viewport-change-functions` runs with a mounted buffer after its
  viewport size changed and the new layout settled.
- `make native` byte-compiles Ebox and stores native code in the user's
  `eln-cache`, which Emacs loads in place of the bytecode.

### Changed

- Text without `display` properties is measured per face run instead of
  per grapheme cluster: a run's characters share one face lookup and the
  cluster table is built only when a line has to wrap.  Rows of many styled
  cells measure about twice as fast; a horizontal step through a 31-column
  styled text grid fell from 13.8 ms to 6.3 ms.

- A drag keeps tracking the pointer after it leaves the window's text area,
  onto the mode line, another window or past the frame, instead of
  cancelling with reason `window-left`, which no longer exists.  `:position`
  stays clamped to the text area, the new `:overshoot` gives the pointer's
  `(DX . DY)` distance past it, and a release anywhere ends the gesture with
  `end`.  Handlers that relied on `window-left` to
  revert a drag now receive `end` at the clamped position.

- Tab visits focus stops in ascending `:tab-index` and then tree order
  instead of screen rows, so a sidebar's controls all come before the pane
  beside it.

- **BREAKING:** Ebox now exposes a mutable retained-node engine.  Build roots
  with `ebox-build`, `ebox-node-create` or `ebox-text-create`; mount them with
  `ebox-mount`; then update the existing tree with node mutation functions.
  Flushes restyle, relayout and repaint dirty paths, and rewrite only changed
  buffer lines/parts.
- `ebox-file-load-companion` loads a compiled `.ebox` companion when its
  bytecode is newer than the `.el` source; edited sources still load directly.
- An input session no longer makes the painted text writable or defers the
  mount's flushes.  It edits the node's value in a hidden buffer with native
  commands, undo and input methods while the node keeps its padding,
  borders and wrapping and grows as the value does.  Clicks, drags,
  double and triple clicks inside the node edit the value, and input method
  preedit text wraps inside the node instead of overflowing it.
- A `:layer root` absolute box without an anchor is placed and sized from the
  root's border box instead of its content box, so a full-size scrim or
  viewer covers the root's padding.

### Removed

- The package manual `docs/manual.md` is replaced by the [ETAF Reference Manual](https://etaf.top/ebox-node-construction/), which the README and the package Commentary link; `docs/architecture.md` remains the maintainer contract.

- **BREAKING:** Removed the previous engine's canonical inputs, source builders,
  surfaces, publications, transactions, prepared update/geometry APIs,
  generation/candidate model, layer module, native Rust layout module, framework
  SPI and render-burst interfaces.  Migrate high-level callers by keeping Ebox
  node references instead of external handles: old full input replacement maps to
  building or copying a retained root and mounting it; old source-builder child
  updates map to `ebox-node-insert`, `ebox-node-remove`, `ebox-node-move` or
  `ebox-node-replace-children`; old content/property/selector updates map to
  `ebox-node-set-text`, `ebox-node-set-image`, `ebox-node-set-props`,
  `ebox-node-put`, `ebox-node-set-states` or `ebox-node-restyle`; old explicit
  update grouping maps to `ebox-with-batch`.

### Fixed

- Pointer hover repaints the hovered node through its own computed paint
  instead of a rectangular text band, so a hovered control keeps its
  `:border-radius` and covers every padding row; leaving restores the
  resting paint on the same rows.

- Clip oversized stacked children to their parent's content width before
  composing overlays. Moving or resizing overlapping windows no longer adds
  the hidden content's width to the canvas, shifts neighboring windows or
  misaligns image rows. Intrinsic child sizes remain unchanged.
- Partial occlusion now crops complete native image glyphs as well as image
  slices, preserving baseline modifiers. A window covering part of a native
  image row no longer blanks the exposed remainder of that row.

- Pointer hover now highlights every painted row of side-by-side multirow
  elements, without filling intervening gaps or adjacent elements.

- Buffer text scaling keeps a mounted tree aligned: a scale change clears the
  shared glyph caches once the zoom settles and lays the whole mount out
  again, so wheel zooming a mounted application no longer paints rows cut to
  the metrics of the previous scale.
- Killing a mounted buffer now runs `ebox-unmount-functions` and releases the
  canvas and mount state, like an explicit `ebox-unmount-buffer`; the hook no
  longer stays silent on the kill path.
- Opening a mount in a frame created by the same command no longer crashes
  Emacs: Ebox redisplays such a frame once before measuring text on it.
- Starting native input from a button no longer immediately ends it when the
  opening gesture is released outside the text field. Nested field controls
  retain editing unless their callback finishes it; later outside clicks
  still invoke the ordinary leave callback.

- The prepared-image cache keeps the most recently used preparations instead
  of discarding every entry at a fixed count.  A screen holding more images
  than the old threshold, such as a tiled arena, reuses unchanged
  preparations instead of re-preparing and republishing them every frame.
- Replacing an image with a different preparation of the same size now
  repaints it.  Distinct preparations no longer compare `equal`, so property
  updates are no longer skipped when the new image was laid out before, as
  cached images are; a moving tile in an animated arena froze until a cache
  miss.
- A graphics image shown over a box background is decoded once.  Preparation
  already decodes for the background images were last painted over, so
  layout no longer decodes every new image a second time for a background
  variant; an image placed over a different background still gets one.
- Hidden nodes no longer retain callback resources removed from their authored
  properties through obsolete interaction decorations.
- Mounted buffers disable native line continuation so already-laid-out rows
  reach the right edge without an extra continuation-column background strip.
  Unmounting restores the buffer's original wrapping setting.
- Growing or shrinking text inside a fixed-height flex container no longer
  inserts or deletes rows outside it. Multiline native editing, clearing and
  undo preserve following content, including independently animated footers.

- A two-finger swipe that reverses direction starts and fires the next
gesture at once, so consecutive left and right swipes each register
instead of waiting out the momentum's quiet interval.
- An interactive overlay clipped by its host keeps its keymap, pointer and
  help on blank rows and on padding cut at the clip edge, so clicks there
  reach it.
- Transparent pixels of a graphics image show the background of the box
  holding it instead of the frame background, so round avatars blend into
  a highlighted row.
- On graphical frames, glyphs whose fallback font is taller than the line,
  such as colour emoji, symbols, mathematical letters and other fallback
  scripts, are scaled to fit their row.  Rows
  keep one line height, so image slices beside them, such as avatars, stay
  joined.
- Printing keys in a mounted canvas outside an input session no longer
  insert text into the application buffer.
- A node's bounds include the cells under its own absolutely positioned
  children, such as a range control's fill.
- `ebox-node-at` on a padding or gap cell returns the innermost box that
  owns the cell instead of the root.
- `ebox-node-at` on a blank or padding cell inside a scroller returns the
  innermost box under that cell, not the scroller.
- Graphical images paint one slice glyph per row instead of one per cell,
  so scrolling and repainting views with many images no longer stalls;
  an image row cut at a box or overlay edge keeps its visible part.
- Scrolling past a scroller's end no longer scrolls a window that already
  shows the whole buffer, so pinned headers and footers stay in place.
- `ebox-buffer-mode` turns off `show-paren-mode` in the mounted buffer and
  restores it when the mode is disabled, so painted text never shows paren
  match or mismatch highlights.
- An image narrower than its stretched box paints the box background beside
  it, so a photo inside a wider bubble leaves no unpainted gap.
- A mounted viewport in a window without a right fringe ends before the
  truncation column, so full-width rows no longer display Emacs's `$` glyph.
- A mounted buffer shown in a window of another size, without any window
  resizing, refits to that window.
- Content wider than its box is cut at the box edge, so later siblings on a
  line keep their columns instead of shifting right.
- Content that fills a mounted buffer which was empty keeps point and the
  window start at the top, so an application no longer opens scrolled to the
  end of its buffer.
- A mounted buffer's default background follows the root's background color,
  so the partial line below the last row and other space beyond the laid-out
  text match the application surface; unmounting removes the remapping.
- Hover feedback covers every row of a multirow element: the rows join into
  one native `mouse-face` run instead of highlighting only the row under the
  pointer.
- A `:visibility hidden` box keeps its layout slot but paints no interaction
  feedback, so an empty slot no longer shows hover, pointer or help output.

