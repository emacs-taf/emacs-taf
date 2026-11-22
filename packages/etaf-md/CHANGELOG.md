# Changelog

## Unreleased

### Changed

- Reissued as 0.2.1 after package-loading and workspace updates since 0.2.0.

### Fixed

- Raw HTML `<img>` blocks with declared CSS pixel `width`/`height` attributes
  now render at those declared dimensions (preserving intrinsic aspect ratio
  when only one axis is specified, left-aligning compact icons and omitting
  blank caption rows for empty `alt=""`) instead of inflating to the image
  file's larger intrinsic pixel dimensions.

- Documents containing `:::` containers now retain every heading (before,
  inside and after containers) in document order with unique anchor IDs, and
  resolve footnote references across container boundaries instead of keeping
  only the first plain stretch's metadata.  Heading navigation (`etaf-md-locate`
  and `#anchor` links) also lands on headings rendered behind container or
  line-grid left borders.

- `:::table` containers preserve inline formatting and interactive runs (bold,
  italic, inline code, links and footnotes) in cells instead of flattening
  every cell to plain text.

- `:::columns` containers given an explicit track list such as `"2fr 1fr 1fr"`
  now count columns from the parsed tracks instead of falling back to 2.

- Container bodies painted via `etaf-md-render` now stretch to their enclosing
  column width, and `:::columns` and `:::card` propagate narrowed available
  widths to nested blocks so images fit inside multi-column cards and following
  paragraphs wrap within the card instead of being clipped.

- The package loads twice without complaint.  A shipped node type used to
  refuse its second registration, which `package.el' triggers when a file
  that `require' already loaded is loaded again.

### Added

- `etaf-md-create` accepts `:on-link` (`(url)`) and `:on-media` (`(kind path)`,
  where `kind` is `image` or `video`) callbacks so embedding applications can
  intercept link and media activation; returning non-nil marks the activation
  handled, and returning nil falls back to the built-in behavior.

- A page that holds many diagrams no longer pays for its generated mermaid
  configuration once per diagram.  The configuration is a property of the
  page — its colours and its type size — so publishing builds it once: a 47k
  character page with thirty-four diagrams opens in 274 ms instead of 4.8 s,
  and a repaint after an edit costs 12 ms instead of 5.4 s.

- `etaf-md-doctor` reports `qrencode` beside ffmpeg and mermaid-cli, so a
  `qrcode` block that kept its text has a stated reason.

- Following a link to another markdown document opens that document's
  preview, and a `#fragment` after it selects the heading; `mailto:` and
  `tel:` links reach the browser instead of being read as local file names.

- A fenced code block takes plume's options: `title=`, `:line-numbers[=N]`,
  `{1,4-7}` and the `[!code ...]` row markers, with a copy action in its
  header.  The options and the guard that keeps every row readable live in the
  `etaf-ui` renderer this page already uses.

- A `steps` container also accepts an ordered list: each item is one step and
  its text is the title, which is how Plume documents write steps.  A
  `timeline` event takes `status` (`success`, `warning`, `danger` or `info`),
  colouring its dot and painting a badge, and the container takes `start`.

- A table is a real grid: every cell draws its own rules, so the header row and
  each body row are separated the way a printed table is.  Its frame hugs the
  grid, and the caption and the copy line stay above it instead of sitting
  inside a page-wide box.

- Every container in the extension contract is implemented: `steps`,
  `timeline`, `stats`, `field`, `file-tree`, `chat`, `code-tabs`,
  `accordion`, `table` and `window`, beside the structure, callout and `tabs`
  parts.  A container translates its attributes to the `etaf-ui` component
  that owns the shape; the table reads a parsed table block and the field and
  file-tree read list items.

- `tabs` and `code-tabs` write one `@tab` per page.  A definition declares its
  child syntax, so `@tab` is a marker only inside the container that owns it:
  inside a note it is plain text and inside a fence it is code.  Prose before
  the first marker, a `:::tab` child and a mismatched marker are reported
  instead of silently dropping content.  The strip and the page share one
  panel, the selected tab is filled, and the strip is one Tab stop where Left
  and Right move focus and RET opens the page.

- The `table` container can highlight rows and columns, choose its surfaces
  and title, and set cell alignment and spacing.  `table-header` and
  `table-stripe` join the surface words a document may write.

- The `window` container draws the catalog's Mac-style title bar, so the
  traffic lights are the same control the desktop applications use instead of
  three look-alike glyphs.

- A diagram is drawn from its vector copy rather than a bitmap.  The renderer
  writes the drawing's own SVG beside the raster, and the page places that: the
  text stays sharp at whatever size the reading measure gives it, a wide
  diagram narrows without resampling its labels, and no two-times bitmap of the
  drawing is held in memory.  The raster stays as the fallback, and a diagram
  whose labels mermaid writes as HTML - a journey's - keeps using it, because
  no renderer outside a browser can draw one, and that raster is cut to the
  drawing so a journey no longer carries rows of empty picture under it.

### Changed

- Document titles and body headings scale above body text again, as the reader
  asked: the front-matter title is the largest run on the page and every
  heading level steps down from it, so a page reads with a real hierarchy
  instead of one uniform text size.  This is an explicit reader request and the
  one place the package sets a size.

- The `r`, `[`, `]` and `C-c j` keys run commands that are now part of the
  supported API: `etaf-md-reload`, `etaf-md-wider`, `etaf-md-narrower` and
  `etaf-md-goto-heading`, so a consumer can bind them without reaching for an
  internal symbol.

- The page header starts on the body's column: the header and the body read
  one width now, and prose fills the measured column instead of capping itself
  again inside it.  The page title reads above an H1 again rather than at body
  size, at 2.2 times the body size given as a ratio: Ebox reads `:font-size`
  that way now, so the title follows the reader's default font on any platform
  instead of a height measured from the frame.

- `examples/all-syntax.markdown` is the union of the former galleries in one
  classified page: the full basic-syntax section, every container section, the
  whole site-component set and all twenty diagram kinds, followed by a
  per-value pass over the containers and components.  Nothing the separate
  example files showed is gone; only their duplicated diagram gallery is.

- `:::accordion {expand=true}' opens every fold even when the group only
  allows one open section, which it used to reject as an invalid open list.

- The package is `etaf-md` and the library is `etaf-md.el`.  It renders
  Markdown documents and the container syntax that extends them, so the old
  name promised a preview and said nothing about the document vocabulary.  The
  command keeps its action word: `M-x etaf-md-preview` still opens a preview
  beside the source, and `etaf-md-open` still mounts one and returns its
  buffer.  Migration: `(require 'etaf-md)`, and every `etaf-md-preview-`
  symbol lost that segment, so `etaf-md-preview-open` is now `etaf-md-open`,
  `etaf-md-preview-create` is now `etaf-md-create`, the option
  `etaf-md-preview-theme` is now `etaf-md-theme`, and the error
  `etaf-md-preview-error` is now `etaf-md-error`.  No aliases are kept.

- The drawing script runs on Windows.  It found `mmdc` with `command -v`
  through `sh`, walked from that launcher to the package with a POSIX symlink
  layout, and started a headless shell build of Chromium that a machine with
  Chrome never downloaded.  It now asks `where` on Windows, finds the package
  by walking up to `node_modules`, and draws with an installed Chrome or the
  browser named by `ETAF_MD_CHROME`, keeping the shell build as the fallback.
  A KaTeX stylesheet also loaded from a `file:` URL that Windows could not read,
  and an element screenshot hung forever once a second page was open, so the
  formula is clipped from the page and the browser runs without its GPU
  compositor.

- A page with many diagrams opens and rescales quickly.  A vector used to be
  rasterised just to learn its size, and again whenever a text scale changed the
  grid it sits in: on a page of twenty-three diagrams that meant five seconds to
  open and two seconds per zoom.  A vector's size is now read from its own
  header, and while the raster beside it still has the pixels a new grid needs,
  the raster is shown - loading it is a decode, not a drawing.  The same page
  opens in a third of a second and rescales in a fifth, holding less than half
  the memory.

- A `tabs` or `code-tabs` container no longer accepts `:::tab` children; the
  spelling is `@tab Title` or `@tab {attrs}`.  Migration: replace each
  `:::tab {title="X"}` block and its closing `:::` with one `@tab X` (or
  `@tab {title="X"}`) line.  A document that uses the old spelling now reports
  the child instead of opening a second page.

- Every diagram family the renderer supports is drawn in the page's own
  colours.  Mermaid gives each family its own palette, and the ones added later
  (charts, radar, kanban, treemap, block, packet, architecture, C4) were still
  arriving in mermaid's light defaults: a chart's plot and a radar's disc came
  out black on a light page, and a packet diagram stayed a strip of white paper
  on a dark one.  A chart's bar and its line now take different hues instead of
  two steps of the same grey.

- Diagrams and formulas are no longer doubled on a display with two device
pixels per point.  The picture was drawn at twice the size its rows were cut
for, so each row held half a row of the drawing and every label appeared a few
pixels below itself.  A picture now takes the size of the page it sits on.

- A diagram's first drawing after the renderer starts is laid out with the
  reader's face.  Chromium resolves a font stack on the first layout that uses
  it, so the first diagram on a fresh page was measured against the fallback
  face: a label came out wider than the chip cut for it, and two runs of the
  same diagram differed.  The renderer now lays the stack out once and waits
  for the page's fonts before it draws.  `make mermaid-check` asks for every
  fixture twice and refuses a second drawing that disagrees with the first.

- A preview no longer accepts typing on the painted page.  The markdown is
  edited in its own buffer with the reader's own commands, and the page shows
  the result; the commands that typed through the page
  (`etaf-md-edit-document`, `etaf-md-insert`,
  `etaf-md-delete-char`, `etaf-md-editing-p`) are gone with
  them.

### Removed

- Editing a block inside the rendered page is gone, and so is the projection
  that carried a painted position back to a source offset:
  `etaf-md-projection` no longer exists, the page no longer takes an `e` key,
  and `etaf-md-after-repaint-functions` went with the edit session that used
  it.  Migration: edit the markdown in its own buffer — the preview follows
  that buffer and repaints the block under the caret on the next frame.

### Fixed

- A diagram's pictures arrive in about a second instead of several.  Every
  fence and formula started its own Chromium through `mmdc`, so a page with a
  dozen diagrams paid a dozen launches and several ran at once; one renderer now
  serves the session, keeps a few pages drawing in parallel and stops itself
  when the page has been read for a while.
- A diagram that cannot be parsed keeps its source and says why, instead of
  drawing mermaid's error picture and leaving the reader to guess.  The block
  stays its fence and the renderer's own message names the line to look at, and
  the message is not repeated on every repaint.
- A diagram that separates its items by hue stays readable on any page.  A pie,
  a timeline, a git graph, a journey and a mind map take their colours from
  mermaid's own scales, which it derives by darkening the page's box colour: on
  a dark page every slice, branch, period and mind-map node came out black, a
  pie's slices were indistinguishable, and a journey's periods and title were
  the page colour.  The scales now come from the page's callout colours, mixed
  into the page far enough that the ink still reads on the fill and the fill
  still stands off the page - which also keeps a mind map's branches, painted in
  that same fill, visible on a light page.
- A gantt's finished, running and late tasks, its section bands, its grid and
  its today line are the page's own colours instead of a light page's grey,
  white and red.  A white bar with white text on a dark page read as a blank
  block.  An entity's attribute rows, a cluster, an edge label and a journey's
  faces take the same treatment, and a git commit's label is laid flat instead
  of at forty-five degrees, where a Chinese id could not be read.
- A picture keeps the diagram's own canvas.  Several kinds declare a height
  that does not match their drawing, which left a band of empty picture under a
  journey; the picture is taken from the viewBox the drawing was sized to.
- A picture wider than the reading measure is narrowed in whole cells.  The
  rows were rounded up to a cell and the columns taken from them, which made
  the grid a few percent wider than the measure, and the window cut off the
  right edge of a wide diagram.
- A derived colour is read from the colour itself instead of asking the frame.
  A batch session has no frame, so `color-values' answered from the terminal's
  palette and turned `#b3541e' into pure red; a heading colour, a mixed surface
  or a diagram fill now comes out the same in a headless run as in a window.
- The renderer's configuration reaches it as the JSON text the preview
  generated.  A round trip through an Emacs plist turned every `false` into the
  string "false", which mermaid reads as true, so a setting that asked for
  something to be off was silently on.

- A flow chart's nodes hug their labels: the padding is mermaid's own eight
  pixels rather than twelve, which had added four pixels an axis to every box,
  and the node and rank spacing drop to forty, so a wide flow chart is scaled
  down less before it fits the reading column.  In a batch run, with no frame to
  ask, a diagram was sized at one pixel; the body size now has a floor.
- A theme switch republishes every preview that follows the Emacs theme.  A
  picture's ink is part of the PNG, so a page whose ink changed kept showing the
  previous theme's drawing: a formula rendered in light ink stayed a blank block
  on a light page until the document happened to be reloaded.
- A formula or a diagram is drawn for the same surface the page paints.  The
  picture's palette was chosen from the frame's appearance whenever the preview
  followed the Emacs theme, while the page itself followed the theme's faces: a
  frame reporting itself dark on a light page produced diagrams with dark boxes
  and a formula in light ink, invisible until its picture was replaced.  The
  same test called the palette's slate `#191a1c` light, because it sat 1.6:1
  from black and the test asked for 1.5, so a dark page could be drawn with the
  light palette; the surface is now dark when it stands farther from white than
  from black.
- Every diagram kind is drawn at the page's size.  Mermaid sizes each kind on
  its own: sequence messages came out at 12px beside 14px actors, and gantt,
  er, requirement and state diagrams default to 11, 12, 14 and 24, so one page
  carried several sizes and a diagram's text did not match its neighbours.
- A diagram's Chinese labels are drawn in the reader's WenKai face instead of
  whatever CJK face the system picks.  The font stack named `LXGWWenKai', which
  is the font's file name rather than its family: the renderer found no such
  family and silently fell back to PingFang SC, so the diagram kept a face the
  page does not use no matter how the stack was configured.
- A diagram that separates its items by hue stays readable on a dark page.  A
  pie, a timeline, a git graph and a mind map take their colours from mermaid's
  own scales, which it derives by darkening the page's box colour: on a dark
  page every slice, branch, time period and mind-map node came out black, and a
  pie's slices were indistinguishable.  Those scales now come from the page's
  own callout colours, each mixed into the page background far enough that the
  label on it still reads, so the same document keeps a readable diagram on a
  light, sepia or dark page.  A pie's slices are separated by the page colour
  and outlined in its border colour instead of a black ring.
- A state node, an ER entity and a requirement box keep a size their label can
  fill.  Their diagrams carry minimum boxes of their own - 120 pixels wide for
  a state, 100 by 75 for an entity, 200 for a requirement - which left a
  two-character label inside a frame with room to spare.
- A git commit's label is set in the page's size instead of mermaid's ten
  pixels, so a commit id reads like the rest of the page.
- A colour derived from the theme is read from the colour itself instead of
  asking the frame.  A batch session has no frame, so `color-values' answered
  from the terminal's palette and turned `#b3541e' into pure red; a derived
  heading colour, a mixed surface or a diagram fill now comes out the same in a
  headless run as in a window.

- A diagram follows text scaling.  A picture is placed in cells, and the cells
  were measured from the frame's default font, which does not follow a buffer's
  text scale: after `C-x C-+` the page's lines grew and the slices drawn for the
  old line height stayed behind, so every diagram broke into horizontal strips
  with the glyphs cut between them.  The grid, the formula's row height and the
  size a diagram is typeset at now come from the page's own metrics, which the
  framework republishes when the scale settles, so the picture is placed and
  drawn again at the new size.

- A label mermaid wraps in HTML is text again.  Every diagram kind drew its
  labels inside the SVG's `foreignObject`, which only a browser can paint, so
  the picture showed its boxes and lost every word in any other renderer.  The
  configuration asks for text labels instead, and the drawings are unchanged.
- A fill and the label on it are chosen together.  A category fill now has to
  stand 1.5:1 away from the page, so a mind map's branch - painted in that same
  fill - is visible on a light page and on a dark one, and the label takes
  whichever of the page's two inks reads on it at 3:1.
- A contrast ratio is measured on decoded channels.  The luminance was computed
  from the encoded values, which understated what a dark colour gives; two dark
  surfaces were called far more different than they look, so the generator
  believed a fill stood off the page when it did not.

- `etaf-md-follow-scroll` makes the page move with the source window:
  the block at the top of the markdown buffer becomes the first row of the
  preview as the source scrolls.  Only the source's scrolling follows, so the
  reader still scrolls the page freely, and typing follows as far as the
  source window scrolls.  Run it from either buffer; it takes no key.
- The preview follows the markdown file while it is edited: a change in the
  source buffer repaints the page on the next frame, block by block, so typing
  in the source costs the block under the caret instead of the whole document
  (measured: one new, one updated and one retired instance per keystroke on a
  703-line file).  A save, or a change made by another program, repaints the
  same way.
- The preview's own keys are `n`, `p`, `C-c j`, `r`, `t`, `[`, `]`, `C-c h` and
  `q`: outline navigation, reload, theme, reading width, help and close.  The
  page is a rendering, so native scrolling, isearch and link activation stay
  available as they are.
- A `mermaid' fence and a `$$' display formula are drawn by mermaid-cli when
  it is installed: the diagram through `mmdc', the formula through KaTeX in the
  Chromium that package brings.  A render runs in the background and is cached
  by its source and the page's colours, so a page paints the source at once and
  swaps in the picture when it arrives, and a block edited again draws again.
  Without the program the fence stays a code block and the formula keeps its
  plain-text rendering; an inline formula always keeps the text, because a
  picture inside a line would change the line height.
- A markdown file may name its own dialect with a `flavor:' line in its front
  matter, and the preview parses that file with it: one document can stay
  CommonMark while the rest read with everything the renderer supports.  A
  session's `:flavor' argument still wins, and the default now follows
  `etaf-ui-markdown-flavor' (the widest preset) instead of `gfm'.
- Definition lists, sub- and superscript, abbreviations and `$' math render in
  a preview, because the shared renderer enables them: `H~2~O' paints `H₂O',
  `Term' with a `:' line under it paints a term with its definitions, and a
  formula paints as text rather than an image.

- A formula is typeset at the page's body size and no larger: KaTeX's own
  1.21em base and the margins of its display block were both in the picture, so
  the same formula took twice the height it should and looked blurry after the
  page scaled it down.
- A diagram takes the page's colours: mermaid is configured with the page's
  own surfaces, ink and body size instead of its fixed `default` and `dark`
  palettes, so a light page carries light boxes.  The margins that keep a
  drawing off the card's edge and a font the renderer can measure with are set
  too, which is what stopped a CJK edge label from coming out cut off.
- A block whose picture changed is a different block.  The published entry's
  key holds the picture path, so a palette change publishes the pictures drawn
  for it instead of keeping the ones the previous page had drawn.
- A picture's box and its grid agree on one size.  The rows came from the
  height at the capped width while the columns came from the picture's own
  width, so a wide diagram ran past the reading measure and was cut off at the
  window, and a formula a pixel taller than its rows took a whole extra row,
  which showed as a gap under it.  A formula now sits in 2 to 3 rows with one
  blank row between two of them, and a diagram stays inside the measure.
- A diagram is drawn flat: mermaid's `neo` look gives every node a thick
  outline and a drop shadow, which reads as a heavy card inside a card.  The
  renderer asks for the classic look, and the card frame around a diagram is
  gone, so a drawing sits on the page with only its caption under it.
- A display formula takes half a line of air above and below: without it the
  formulas stacked on the paragraph's last line and read as one cramped lump.
- Every diagram on a page is drawn at its own size: only a picture wider than
  the reading measure is scaled down to fit it.  A height cap used to shrink a
  diagram that already fitted, so one page showed diagrams with different text
  sizes.
- A formula is drawn at the size of the text around it and never scaled: its
  picture is produced in whole body rows with the transparent margin above and
  below, which is the size it is placed at.  One number, the scale, decides both
  sides of a picture's grid, so a drawing is never stretched to fit its box.
- A formula no longer carries block padding.  A fractional line of padding takes
  a whole line in the layout, so `(lh 0.5)` added two rows and turned a single
  blank line between two formulas into an 80-pixel gap; the raster's own
  transparent rows and the source's blank lines are the separation now.
- A diagram is drawn and measured in the reader's own font: the renderer
  takes the frame's default family first and puts the CJK face behind it, so a
  label is set in the page's type instead of a fixed family, and a font with no
  CJK glyph no longer clips a label.
- A picture's cache key carries every setting it was drawn with: a diagram
  keys on the renderer's whole configuration, so changing its font, margins or
  colours draws a new picture instead of handing back the one drawn before.

- A soft line break folds into a space, as CommonMark reads it: the paragraph
  flows and wraps at the page's own width.  A two-space or backslash break is
  the author asking for a line end and still paints its own row, and a blank
  line inside a fence stays a row inside the block.
- A republish publishes the file when the buffer visiting it is gone.  A
  picture that landed after that buffer closed asked the session for its text,
  got nothing, and published an empty page.
- A typeset picture is placed at the size it is meant to occupy: the file is
  drawn at two device pixels per point for sharpness, and the grid it is put in
  now comes from half that file size.  Formulas are set at the reader's body
  size instead of a fixed 30 pixels, which had made one equation claim half the
  page, and mermaid diagrams stop appearing at twice their intended size.
- The blank lines after a leading definition line are painted again: a
  document that opens with a link reference or an abbreviation definition used
  to lose the gap after it, because the whole leading stretch was skipped as
  front matter.  The front matter alone is skipped now, and the blank lines
  around it keep their rows.
- The page title takes the size of a level-one heading, which is the rank a
  front matter title has.  It used to be a notch smaller than that rank, so a
  document whose sections start at level 2 read as if the title and the
  headings came from two different scales.
- The scroll follow reaches the top of the page: a source position above the
  first block sits in the front matter, which no block owns, so the page used
  to scroll past its header.  It now opens on the title, tags and metadata
  line the page starts with.
- An edit repaints a document that holds a definition list: the parse keeps a
  range for the paragraph above the list as well as for the list, and an edit
  whose document has a block without one falls back to a whole parse instead
  of stopping the follow timer with an error.
- A blank line next to a line the parser consumes without painting one, such
  as a link reference definition or an abbreviation definition, is painted
  again: the preview kept the file's own spacing instead of pulling the next
  block up against the previous one.

- A card's surface, a muted label and a bar track take their colours from the
  page's theme palette again: the lookup read a plist while a theme palette is
  an alist, so those fills were silently painted as nothing.

- A fenced sample no longer opens or closes a container: a `:::` inside a code
  block stays the sample's text, and a fence in a container body cannot end
  the container early.  The scanner that finds containers now remembers the
  open fence and reads its body as opaque.

- Closing one accordion section and opening another no longer leaves the
  closed section's header row under the following block.  A toggle that moves
  several rows repaints the page instead of patching the lines the previous
  layout wrote.

- A code tab names its language once: the selected page's fence no longer
  repeats it in a header strip under the tab strip.

- A table caption stands on its own line: one blank row separates it from the
  header, so a caption no longer reads as part of the first row.

- A table marks single cells with `highlight-cells="2:3"`, aligns its whole
  body with `align`, and offers a copy line with `copy` that puts the table on
  the kill ring as tab separated text.  Its frame hugs the grid, with the
  caption and the copy line above it.

- `:::` field` describes one parameter: `name`, `type`, `type-link`, `default`,
  `required`, `deprecated`, `experimental`, `enum`, `unit`, `format`,
  `constraint` and `since` become a card with its state chips, a metadata row
  and a notes row.  A field without `name` keeps the list form.

- The callout family reads `info` and `danger` as well, and `:::details`
  folds one block at a time.  A `collapse` child takes an `index` for its
  order, and the group takes `expand` and `accordion` so it can open every
  fold or allow several at once.
- `:::left`, `:::center`, `:::right` and `:::justify` align a body the way
  their names say; `card` takes an `icon`; and `window` takes `gap` and
  `no-padding` for its content area.

- The site component catalog joins the prose containers: `home-box`,
  `image-card`, `link-card`, `npm-badge`, `qrcode`, `swiper`,
  `code-tree` and `npm-to`.  `swiper` and `code-tree` use the same `@name`
  child markers as tabs; `npm-to` rewrites one npm command for pnpm, yarn,
  bun and deno; `qrcode` draws with the optional `qrencode` program and
  keeps the text when it is missing.
- The `etaf` dialect now paints `==highlighted==` runs, `::name::` icons,
  `:kbd[KEY+KEY]` key groups and `:badge[TEXT]` badges inline, through the
  shared renderer.

### Fixed

- The package loads twice without complaint.  A shipped node type used to
  refuse its second registration, which `package.el' triggers when a file
  that `require' already loaded is loaded again on activation.
