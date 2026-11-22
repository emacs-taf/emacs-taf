# Changelog

## Unreleased

### Changed

- Reissued as 0.3.5 after package-loading and workspace updates since 0.3.4.

### Fixed

- A window title, a desktop taskbar label and a statistic's value show the
  text a reactive source holds.  These three surfaces passed the source
  object itself to the text host and failed to render.

### Added

- Raw HTML `<img>` and `<video>` blocks in `etaf-ui-markdown-view-blocks` now
  parse positive pixel `width` and `height` attributes (quoted, unquoted or
  `px`-suffixed) and forward them as `:width` and `:height` on the media
  descriptor passed to `:render-media`.

- `etaf-edge-panel`, `etaf-edge-tabs` and `etaf-underline-field` put their
  labels on rules the layout already draws: a panel title and status sit on its
  top rule, tabs share the pane's edge instead of owning a strip above it, and a
  field hangs its value under a single line.  None of them spends a row on
  chrome.

- `etaf-log` paints a log entry per row with a coloured level column and no
  frame, and `etaf-status-bar` is one row of mode, key hints and a note.

- `etaf-braille-chart` plots a series on a 2x4 dot grid per cell, so the line
  stays thin and copies as text.

- `etaf-drop-zone` answers where a drag will land before the release: the half
  the release would take is tinted with the accent colour, framed with a dashed
  rule and named after the dragged thing, so the layout does not move again when
  the pointer lets go.

- A fenced code block reads plume's fence options: `title=` names it,
  `:line-numbers[=N]` numbers its rows, `{1,4-7}` and a trailing
  `[!code highlight|focus|++|--|warning|error]` paint rows, and the header
  carries a copy action.  Every ink is made readable against the fill of the
  row it sits on, so diffs and warnings stay legible in both palettes.

- A timeline item's `:status` may be a plist of `:text` and `:variant`, so a
  caller writes the badge in its own words and still takes the state colour.
  A bare symbol keeps its old meaning: the badge shows the symbol's name.

- The collection and navigation parts now draw the shape their names promise.
  `etaf-tabs` is one segmented bar with a filled selection and a single Tab
  stop: Left and Right move focus inside it and RET selects, and either end
  consumes the key instead of ringing.  Steps carry a numbered rail and body
  content, a timeline shows its time and composes whole blocks, a tree can
  draw guides, a metric is a panel, and a card takes a width, alignment and
  press handler.  The old props keep their meaning.

- A code block keeps its syntax colours readable on the page it is painted
  on: the colours come from the frame's own faces, which a light page can
  swallow, so each one is passed through `etaf-ui-color-legible' against the
  code surface.  `etaf-ui-color-contrast' reports the WCAG ratio between two
  colours, and `etaf-ui-color-legible' mixes a colour toward black or white
  until it reaches 4.5, keeping its hue.
- A heading takes the size a markdown page gives it: level 1 is twice the
  body, level 2 one and a half, level 3 one and a quarter, level 4 a little
  above the body, and levels 5 and 6 keep the body size with the muted colour
  telling them apart.  The steps are relative to the reader's own default
  font, so the document keeps their type size.
- A parsed top-level block carries `:begin` and `:end`, its character range in
  the parsed text, and the parser exposes the line-offset helper behind it.
  A caller that must map an edit back to the block holding it no longer
  searches the document: the range slices out the block's own source.
- `etaf-ui-color-mix` is public: applications derive hover, selection and
  surface steps from their own palette instead of carrying a second one. A
  colour written in any spelling other than `#RRGGBB` comes back unchanged.
- `etaf' is a markdown preset, and the default one: GitHub's extensions plus
  definition lists, sub- and superscript, abbreviations and `$' math.  All of
  it is pure parsing, so a plain checkout renders it.  A preset is only a set
  of switches over one parser, so a document written for a narrower preset
  still parses here, with the syntax it did not enable left as literal text.
- `etaf-ui-markdown-math-text` renders a TeX formula as plain text: command
  names get their symbols, `\frac{a}{b}' becomes `a/b', `\sqrt{x}' becomes
  `√(x)', and `^{}' and `_{}' become the Unicode letters of that position.
  A formula therefore paints without an image, a program or a font.
- The parser dispatches added syntax through two tables,
  `etaf-ui-markdown-block-extensions' and
  `etaf-ui-markdown-inline-extensions', and a preset enables a syntax by name.
  A disabled extension never runs, so its markers stay literal text.
- A fenced block with a language paints its code in that language's colours.
  `etaf-ui-markdown-highlight-code' runs the language's own major mode over
  the text and turns the faces `font-lock' produced into coloured runs, cached
  by language and text, so a repaint costs one lookup and a language without a
  mode keeps one plain colour.  `etaf-ui-markdown-code-renderers' is where a
  language that needs a program (a diagram, a typesetter) plugs in a View, and
  the block shows its source until one is registered.
- A display formula can be drawn by a caller instead of as text: the
  rendering environment's `:render-math (block env)' returns a View for the
  block, and nil keeps the text rendering, the same way `:render-code-block'
  lets a diagram language be drawn by a program.
- Emoji shortcodes such as `:tada:' and `:rocket:' paint their character; a
  name outside `etaf-ui-markdown-emoji' keeps its colons.  A Han character on
  either side of a shortcode does not block it, so Chinese prose can write
  `表情：:tada:很棒'; a time like `12:30:45' is still a time.
- A footnote label defined twice shows its first definition, as CommonMark
  and GitHub read it; a reference to a label that was never defined adds no
  note.

- A code block's colours come from the runs, not from the block: the fenced
  body no longer paints one colour over every token, so highlighting shows
  what the language's mode decided.  A block without highlight keeps the page
  ink, and each run that has no colour of its own gets it.

- The `etaf' markdown dialect reads four more inline forms: `==text==' with an
  optional `{.class}' fill, `::name::' for an icon from the icon sets,
  `:kbd[KEY+KEY]' for a key cap group and `:badge[TEXT]{.variant}' for a status
  badge.  `:' now opens several recognizers in turn, so a shortcode, an icon,
  a key group and a badge can share the trigger without eating each other's
  text.

- A code block whose plist has `:header` nil draws without its language strip:
  the fence keeps its frame and syntax colours, and the caller that already
  names the language, such as a code tab, no longer repeats it.  A block
  without the key keeps the header.

- `etaf-card` takes an optional `:icon`: the icon set's glyph is drawn before
  the title on the title's own row.  A card without the key keeps its title
  exactly as before.

### Changed

- `etaf-list` rows carry a `[ ]`/`[x]` checkbox column, a right-aligned
  `:meta` value and a selected row, so a caller that needs a done mark, a
  trailing value or a current entry no longer rebuilds the list out of rows.
  The item plist takes `:checked` and `:meta`, the component takes `:checkbox`
  and `:selected`, and a checked row greys its title and strikes it through.

- A soft line break inside a paragraph paints a space, the way CommonMark reads
  a source line end: the paragraph flows and wraps at the page's width instead
  of keeping one row per source line.  A hard break, written with two trailing
  spaces or a backslash, still paints a line end.

- `etaf-ui-markdown-flavor` now defaults to `etaf` instead of `gfm`, so opening
  a document shows every syntax the renderer knows.  `gfm` and `commonmark`
  remain as the narrower presets to name when a document has to parse exactly
  as those specifications say, and a feature plist still toggles one flag or
  one extension.
- A task list marks a done item with `■` and an open one with `□`.  The ballot
  boxes it drew at first come from a symbol fallback font on macOS: thin, small,
  and a different box size for each state, so the marks did not line up.  Both
  squares now come from the text's own font, which gives the two states one box
  geometry; the fill shows the state.

- A keycap draws the documented hairline box with no fill by default, and the
  new optional `:variant` picks `filled` for a soft chip. Both levels keep the
  frame's own type size, and the region level fills with the accent while its
  region holds the keyboard.

- Markdown headings read as a hierarchy in any theme. A level-1 and level-2
  heading now draws a rule from the new optional `:heading-rule` palette color
  (falling back to `:border`), and the heading ladder comes down a step
  (1.42/1.26/1.10 of the body size instead of 1.55/1.32/1.14), so a heading
  still fits a narrow window.
- A fenced block with a language opens with a header strip that holds the
  language and closes with a rule, instead of a tag floating over the first
  line of code.
- A markdown table draws its whole grid: an outer border, a rule between
  every pair of columns and a rule between rows. Its header row is closed by a
  rule mixed toward the ink color, and the zebra stripe is dropped when the
  palette gives the stripe and the header row the same surface.
- A blockquote paints its own text in `:muted`, so it reads as secondary
  content; a link keeps the accent and a code span keeps its panel.

- A code block's tokens take their colours from the page's own palette: the
  highlighter reads the tokens with the language's mode, so what a word is comes
  from font-lock, and the colour comes from `etaf-ui-markdown-highlight-palettes`
  — a saturated set for a light page and a light one for a dark page.  A token
  whose face names no role keeps its own colour, adjusted to the page.

- A table draws one hairline on every cell edge and around the table, a fifth of
  the way from the page's surface to its ink: the weight a documentation site
  gives its grid, seen on every edge and still quiet beside the text.  The header
  is set apart by its tint and its weight instead of by a heavier rule.  A tint
  that sits within a tenth of the page's own lightness is rebuilt from the page
  and its ink, so a dark palette's band stays visible behind the header.  Cells
  are padded two characters on each side, and a column's floor counts that
  padding, so the widest word in a column still fits.
### Fixed

- Components that convert between pixels and cells measure the canvas they are
  drawn in instead of the frame's default face: the media grid and stage, an
  icon's slice, an avatar's SVG, a selection rule, a traffic light and a
  floating surface's width.  A text scale or a canvas font is a different
  cell, and a picture or panel measured with the frame's one drew short of the
  region the canvas covers.

- An alert's note mark is the plain `i`: the information sign is missing from
  common monospace fonts and rendered as a box or a stray bar.
- An alert paints its text on the row under its label: the marker line's break
  stayed at the head of the paragraph after the marker was removed, so every
  callout opened with an empty row.
- A table cell keeps a pipe written `\|`: splitting on every pipe cut the cell
  the escape protects, and a pipe cannot appear in a cell any other way.
- A numbered list that changes its delimiter starts a new list: `3.` and `1)`
  were read as one list, so the second one showed 6 and 7 instead of the
  numbers the source wrote.
- A list mark sits one cell before its text instead of a fixed three-cell
  column, which left a gap as wide as a CJK character after a single bullet.
  The column fits the widest mark of its own list, so an ordered list that
  reaches two digits keeps one text column and a bullet list does not reserve
  space it never uses.
- A quote separates its own blocks by one blank row: a `>' line with nothing
  after it ends a paragraph, and running the next block up against it read the
  quote as one cramped lump instead of the paragraphs, list and nested quote
  the source wrote.  The quote still ends on the last line of its last block.
- A blank line inside a list item separates the paragraphs it wrote: the item
  keeps that line, so the two paragraphs stay two instead of running together
  as one paragraph split by a soft break.
- The paragraph above a definition list carries its own `:begin` and `:end`:
  one clause reads both blocks, and only the list was given a range.  A caller
  that splices an edited document on those ranges used to fail on the
  rangeless paragraph, which stopped the preview from following an edit.
- A definition list ends on its last definition line: it no longer claims the
  blank line that separates it from the next block, so a renderer that paints
  a document's blank lines keeps the page's own spacing.

- A blockquote ends on its last line of text: the rendered quote box no longer
  keeps an empty padded row before its bottom edge, so a source without a blank
  line inside the quote reads the same after rendering.

- The terminal icon set draws the transport controls with `⏮`, `❚❚` and `⏭`
  instead of `«`, `||` and `»`.  A text terminal showed the previous and next
  buttons as quotation marks beside the play pill, and the pause glyph as two
  thin bars, so a player's transport read as text rather than controls.

- A timeline entry's marker is a round dot, not an asterisk: the asterisk read
  as a footnote mark.  The dot keeps the row's line height and takes the
  colour its status names.

### Added

- `etaf-workspace-bar` and `etaf-taskbar` accept `:ref-prefix`. A host that
  embeds a whole application can mount several bars in one ETAF Runtime; without
  a prefix their tabs, the layout control, the settings control and the
  launcher spell the same Host reference and shadow each other, so a press on
  one bar reached the other bar's control.

- `etaf-toggle-strip` returns a two-way or three-way choice as one row of
  equal-width boxes for a header line or a mode line, where a Component cannot
  mount.  The selected segment paints the accent, the others the row surface,
  a click calls `:on-change`, and the selected segment takes no pointer-hover
  face, so the two states never stack.

- `etaf-cell-line` paints one grid line of caller-owned cells with the same
  one-pixel side stripes and closing underline an Ebox box uses, so a row of
  cells is one text Host instead of two Hosts per cell.  Selected cells keep
  their fill up to the stroke, no half-cell gap appears between cells, and the
  row rule runs unbroken across every separator; `etaf-cell-line-width`
  reports the line's character width.

- `etaf-sheet` shows a caller-owned grid of cells as a scrolling sheet with
  spreadsheet borders, a cursor cell, a rectangular selection and an in-place
  editor.  It builds one text Host per visible row, so mounting, scrolling and
  repainting follow the viewport rather than the sheet: with 5000 rows of
  grid-table data a line scroll costs 2.3 ms of command time and a cursor move
  1.4 ms, while the same data through grid-table's own renderer costs 24 ms and
  12.5 ms.  Arrow keys move the cursor, Shift extends the selection, F2 and RET
  edit the cell through `etaf-text-input`, dragged column headings and row
  numbers resize them, and `etaf-sheet-reveal`, `etaf-sheet-scroll` and
  `etaf-sheet-begin-edit` drive it from application code.  Colours come from the
  catalog palette, with dark-frame colours and a `:colors` override.

- `etaf-text-grid` accepts `:height`, `:ref` and `:on-scroll`.  With a
  height the grid shows that many lines in a scrolling viewport and builds
  only the rows near it, so mounting and scrolling cost the same for a
  thousand or a million rows: in batch a million-row, 31-cell grid mounts in
  9 ms, steps one line in 1.2 ms and jumps anywhere in 10 ms.  The wheel,
  scroll keys and `etaf-scroll-*` calls on `:ref` move it, and `:on-scroll`
  receives the first visible row.  Scroll columns by keeping the first
  column in a ref the row callback reads.

- `etaf-ui-qr-paint` paints scanned-code modules as half-block text and
  `etaf-ui-qr-login` presents that code in a modal sign-in panel.  The
  caller owns the request cycle and the account state, and the painted
  glyphs keep pure black on white in both palettes.
- `etaf-ui-theme-tokens` turns an application palette (surface, text,
  panel, border, muted, accent and status roles) into every color token the
  catalog reads.  Applications provide one palette instead of listing each
  `:ui-*` token; omitted roles are derived, and a token placed before the
  result still overrides it.
- Terminal frames use a registered `tty` icon set: one-cell Unicode marks for
  the catalog's icon names, so playback, navigation and library controls keep
  their shape without an icon font.  A request for the SVG set selects the
  terminal set on a text display; names it does not cover still fall back to
  the requested set.

- Gallery usage panels show every component's public signature, parameter
  types, required/default values, units, callback arguments and constraints
  alongside the existing live and copyable example. Reference text comes
  directly from the installed package Commentary, without a manual dependency
  or a second API inventory.
- `etaf-key-help` presents effective shortcuts in a searchable, read-only
  dialog inside the application: wide windows use two columns, compact
  windows one scrolling column. It follows the opening Theme and restores
  focus on close. Loading etaf-ui supplies this renderer for `etaf-help`
  without requiring application-owned help state.
- `etaf-dialog` accepts `:keys` and `:on-direction` for scoped panel input.

- Themes can set shared Button padding, radius and border, and outlined
  TextInput padding, radius, background and idle border color. Missing tokens
  preserve existing defaults and panel palette fallbacks; plain inputs remain
  unframed. Theme changes preserve active native editing.

### Removed

- The package manual `docs/manual.md` is replaced by the [UI chapters](https://etaf.top/ui-overview/) of the ETAF Reference Manual, which the README and the package Commentary link.

### Fixed

- A markdown table resolves its columns once for the whole table instead of
  once per row, so every row's borders land in the same columns and a cell
  that wraps no longer pushes its row out of line.  Each column keeps a floor
  taken from its widest unbreakable token: a word, identifier or code span
  stays whole, and a run of wide characters counts at a fixed cap because a
  line may break between them; a container narrower than the floors lets the
  table overflow rather than squeezing a column below its words.

- The gallery reference scenario reads wrapped reference text across the
  panel's vertical borders, so phrases that cross a box glyph still match.

- Floating surfaces center and clamp themselves in terminal frames too: the
  window viewport is read for any displaying window and measured in character
  cells, so dialogs, help and popovers no longer open at the left edge at the
  full canvas width.

- Full-bleed window resize strips no longer paint the window background over
  the body's outermost column and row. Each strip stays a pointer target but
  keeps an identity backdrop, so an embedded application's own background and
  content reach the window edges again while the edges still resize.

- The gallery, surfaces and window-resize commands are autoloaded by absolute
  path from this package's own `examples/` directory. Installed archives no
  longer depend on the package root being on `load-path`, which failed on
  Windows with `Cannot open load file: examples/etaf-ui-gallery`.

- Optional native icon and media calls no longer produce undeclared-function
  warnings when package.el compiles the catalog on text-only Emacs builds.
  Graphical capability checks and printable fallbacks stay unchanged. Gallery
  example generation also compiles with Emacs 29's older pretty printer.

- Range now honors `:bar-height` for both track and fill on SVG-capable
  graphical frames. Thickness stays centered inside a standard row, without
  changing the full-row hit target or retained fill updates. Text-only frames
  keep a thin rule.
- Slider arrows stop at the largest step-aligned value within the bounds,
  even when `:max` is not aligned. A bound slider no longer writes an invalid
  value and fails to render when Right reaches a non-step upper bound.
- The Gallery Splitter example converts gesture pixels using its live pane
  width rather than an assumed 600 pixels, so pointer and keyboard movement
  remain proportional after resizing. Copied examples use the same correction.
- Calendar weekday headings, leading blanks and dates use equal-width cells.
  Changing the selected date no longer shifts the remaining days in its week.
- Select choices, expanded tree branches, taskbar items and workspace items
  retain their padding and typeface when their state changes. Selection uses
  Theme paint only, and selected dropdown options suppress hover fill.
- Menu and selector triggers, accordion headings and tree branches show
  disclosure arrows instead of alphabetic `v` markers. Accordion control
  names stay equal to their labels when sections open or close.
- Gallery overview previews grow with their content instead of clipping
  multi-row avatars against the card caption.
- Gallery sidebar items, segmented choices, tabs and steps now highlight
  selection without changing label positions, control widths or font weights.
  A selected ghost Button uses the secondary Theme colors without switching
  variants or stacking a hover fill.

- Derived hover fills step away from the label in both palettes: a dark
  surface darkens and a light one lightens, so a hover never lowers the
  label's contrast toward unreadability and one control gets a distinct
  fill per Theme instead of one tint that only works in the palette it was
  chosen for.  A surface already at the light or dark extreme steps the
  other way and stays above 4.5:1.  `etaf-ui-button-hover-keeps-text-readable`
  now asserts the resting-contrast bound and per-palette distinctness.

- A Button with a caller-supplied `:bgcolor` derives its hover fill from
  that surface instead of repeating the variant token, so a chip whose
  surface equals the token no longer loses its hover feedback.
- Button, menu and toggle hover fills are derived from the application
  Theme when it names no hover colour: the catalog used fixed light tints,
  which turned into light text on a light fill under a dark application
  (a ghost label dropped to 2.2:1 contrast).  A Theme that provides
  `:ui-button-ghost-hover-bg`, `:ui-button-secondary-hover-bg`,
  `:ui-button-primary-hover-bg` or `:ui-accent-soft-bg` still wins.
- A linked inline code span that is also a code link keeps one
  `:text-decoration-line` instead of building a duplicate View property and
  failing to render.
- A Button keeps its label on one line: it no longer shrinks below its
  content in a narrow Flex line, so a toolbar wraps its buttons as whole
  items instead of splitting their text.  Tabs inherit this because their
  tabs are Buttons.
- A caller-supplied `:keymap` that binds framework-reserved keys (`Escape`,
  `Tab`, `?`, the arrows, `M-g`, `C-g`) is rejected with an
  `etaf-component-call-error` naming them, instead of silently replacing the
  framework binding.
- Full-bleed window side and bottom handles stay above the body for pointer
  feedback and dragging, including after geometry changes.
- Ordinary window body space uses the arrow pointer when pressed to focus;
  child controls retain their own pointer semantics.

### Changed

- Modal dialogs and drawers dismiss on a backdrop click without activating
  background controls; clicks inside their panel leave them open. Escape
  still exits native editing before closing the modal.
- Keyboard keycaps use compact rounded borders and subtle fills derived from
  the inherited panel palette in both light and dark Themes.

- `M-x etaf-ui-gallery-open` now opens a searchable component browser instead
  of the Atelier workspace: eight categories expose all 63 components with
  live specimens, scoped light/dark Themes, reset and complete copyable
  examples. Independent mounts keep their own state and preserve unrelated
  buffers. Category browsing adapts to wide and compact windows.

- A modal surface's default backdrop keeps the application painted and dims
  it through Ebox's `:backdrop-filter`, so covered text and images stay
  visible while covered controls keep their blocked pointers and focus
  targets.  `:backdrop` nil now paints no backdrop at all.

- Tile grids retain equal projected cell values, reducing rendering work when
  a shared observation changes only a few cells.

### Added

- A focused Button shows a visible cue without changing geometry: its label
  is underlined, and a Button that carries no surface of its own takes the
  ghost hover fill.
- Buttons and rendered links react to the pointer: an enabled,
  unselected Button paints its variant's hover token
  (`:ui-button-primary-hover-bg', `:ui-button-secondary-hover-bg' or
  `:ui-button-ghost-hover-bg') while hovered and declares `aria-selected'
  so selected tabs and segments keep their selected presentation, and a
  markdown link carries the `:accent-soft' palette color as its hover
  face.
- `etaf-pane-resizer` accepts `:ref` and puts it on the rendered divider,
  so a caller can focus or address the resize handle.
- `etaf-ui-markdown-parse`, `etaf-ui-markdown-view-block` and
  `etaf-ui-markdown-view-blocks` parse and render Markdown documents into
  ordinary ETAF Views.  The renderer takes the document tree and a `:palette`
  alist, and delegates links, footnotes, media, code blocks and code spans
  to caller callbacks (a `:code-link` callback can turn a code span into a
  link while it keeps its code style), so the previewer, the manual reader
  and other document views share one rendering path.  A `:code-bg' palette
  entry colors inline code and default code blocks, falling back to
  `:panel' when absent, so a document can keep code readable on tinted
  panels.  Table columns share the width by content, keep a short
  unbreakable run such as a CJK word whole, and wrap longer cells at word
  boundaries; the `:line-grid' environment keeps every line at the
  standard height for documents that scroll beside other content.
- `etaf-ui-svg-*` composes validated, XML-escaped SVG scenes and returns image
  descriptors for image sources and image Hosts such as `etaf-tile-grid`
  `:cell-image`, keeping ordinary box layout, focus and terminal text fallback.
- Tile grids can display caller-owned images or SVG in fixed multirow cells
  through `:cell-image` and `:cell-height`, retaining keyboard/mouse targets
  and text fallback. `:on-cell-focus` reports coordinates for media focus cues.
- `etaf-window` and `etaf-resizable-panel` accept `:full-bleed`: the default
  slot spans the panel's full body and enabled handles paint after it, so the
  body reaches the frame edges.  Pair it with handles whose cells sit in the
  header or in the body's own margin when the body must stay seamless.
- `etaf-text-grid` displays fixed-width character surfaces with independent
  retained rows, Unicode width validation and caller-owned data.
- `etaf-tile-grid` accepts `:cell-label` for meaningful accessibility names
  and help text while keeping its existing coordinate and activation contract.
- `etaf-tile-grid` accepts `:cell-color` to control each cell's foreground
  independently from its background, including reactive Theme colors.
- `etaf-window` wraps its body slot in a viewport region, so content rendered
  in the window reads the space it was given as `(PIXELS . ROWS)` with
  `etaf-viewport`.

- Catalog Components are fully keyboard operable through ETAF Host keys.
  Selectors, bars, tables, lists, trees, calendars and grids are single Tab
  stops navigated with arrows and `C-n`/`C-p`/`C-b`/`C-f`; `etaf-window` runs
  `:on-focus` when keyboard focus enters it, and moves with `M-<arrow>` and
  resizes with `M-S-<arrow>` from anywhere inside it;
  `etaf-range` and `etaf-slider` change with Left/Right (`etaf-range` adds
  Home/End and `:key-step`); splitter dividers and `etaf-pane-resizer` step with
  arrows; tree branches open with Right and close with Left.
- `etaf-ui-icon` and `etaf-ui-toggle-icon` accept `:tab-index`; a negative
  value keeps a pressable icon clickable but out of Tab order. They also accept
  `:aria-label`, which names them in `etaf-palette` and defaults to a string
  `:help-echo`.

- `etaf-search-field` renders a rounded search pill with an optional
  magnifier and a clear control, coloured by new `:ui-search-bg` and
  `:ui-search-fg` theme tokens.
- `etaf-pane-resizer` is a draggable divider reporting a caller-owned pane
  width clamped to `:min` and `:max`.
- `etaf-dropdown-menu` accepts `:icon` for an icon trigger and `:placement`
  for the menu's side; `etaf-text-input` accepts `:on-focus`.

- `etaf-media-viewer` shows an image or video in an in-buffer modal viewer
  that fits the live window, with a full video transport bar (play/pause,
  ten-second skips, clickable and draggable seek bar, speed, sound), gallery
  arrows, keys and swipes, and closing by Escape, q, the close control or a
  pointer press outside the media.

- `etaf-reactions` renders controlled reaction chips with counts, an
  accent tint for chosen ones that never changes their size, and an optional
  picker popover.

- `etaf-text-input` accepts `:variant 'plain` for a borderless field inside
  a styled container such as a chat composer; the default `outlined` field
  keeps its frame.

- The icon set adds `pin`, `bell-off`, `send`, `reply`, `users`, `megaphone`,
  `at`, a filled status `dot`, `info`, `menu`, `more-vertical`, `sidebar`,
  `eye` for view counts, and `smile`, `image`, `video`, `file` and
  `paperclip` for reaction and attachment affordances, with font glyphs, SVG
  shapes and line-safe text fallbacks.

- `etaf-avatar` accepts `:lines` for multi-row list avatars and
  `:background` for a solid identity color with white initials.
- `etaf-avatar` accepts `:src` for a photo and `:shape`; on graphical frames
  the default `circle` shape renders the photo, or the initials on a colored
  disc, as a round image. Use `:shape 'square` for the previous initials box.

- Native editor integrations can share an empty hint, edit observation and
  revision-guarded value replacement through `etaf-ui-editor-mode`. Existing
  editing keys, completion, selection and undo remain native; stale external
  updates cannot erase newer edits, even after undo restores identical text.

- `etaf-tile-grid` provides caller-controlled rectangular cells with stable
  coordinate identities, local reactive color/text, and shared keyboard/mouse
  activation. It contains no board state, algorithms or animation timers.

- `etaf-ui-icon-lines` exposes the existing line-safe icon text resolver for
  retained text cells, without requiring a positioned icon overlay.

- `etaf-ui-toggle-icon` renders one icon that switches between two names, or
  between two colours for one name, through retained Host text. A reactive
  `:value` publishes a text update instead of rebuilding the view in every
  placement.
- `etaf-ui-window-resize-open` mounts a runnable catalog window whose title
  moves and whose eight handles resize through controlled Behaviors, with
  Shift-locked gestures and Escape restoring the starting rectangle.
  `benchmarks/performance-scenarios.el` registers `window.resize.*`
  workloads comparing a direct `etaf-runtime-update-host-geometry` commit
  with mounted reactive state, plus the native corner gesture.
- `etaf-ui-dismiss-outside-press` closes every mounted floating surface whose
  panel the current press missed. A shell root calls it from `:on-press` and
  `:on-press-capture` to give unpainted modals and popovers click-outside
  dismissal; a surface opened by the same press stays open.
- Desktop Components read their colors from Desktop Theme tokens
  (`:ui-shell-*`, `:ui-accent*`, `:ui-window-*`, `:ui-divider-bg`,
  `:ui-picker-item-*`) inside retained Host properties, so a Theme provided
  with `etaf-theme-provide`, including a reactive one, restyles bars, window
  chrome, dividers and pickers through paint slots without re-rendering.
  Picker rows render a bold caption above a muted description on a full-width
  tinted row with an accent marker for the selected item.
- `etaf-splitter` overlay dividers accept refs or computeds for
  `:overlay-rect` (and its entries), `:z-index`, `:divider-content` and the
  new `:visible` property. A layout policy repositions, relabels or hides
  dividers through retained cells without re-rendering the tree.
- `etaf-workspace-bar` `:layout-label` accepts a ref or computed. The layout
  control reserves a fixed width so a changed label publishes as a prepared
  Text update instead of re-rendering the bar.
- `etaf-dialog` accepts `:close-label nil` to omit its default footer button
  so a confirmation footer can order its own Cancel and commit actions.
- `etaf-select` accepts `:presentation` (`auto`, `chips` or `dropdown`),
  `:hide-label`, `:width` and `:ref`. Selection stays in the UI: up to four
  options render as inline chips, more render an anchor pill that opens a
  Popover listing the options. `etaf-number-input` renders `−`/`+` steppers
  around its value pill and accepts `:hide-label`; `etaf-text-input` accepts
  `:hide-label`.
- The shared `svg` icon set adds `star`, `radio`, `disc`, `chart`, `mic` and
  `clock`, so applications can keep library and status surfaces in the same
  line-icon style as their player controls.

### Changed

- `etaf-window` no longer adds a built-in inset around its body slot.  The
  window provides the full body rectangle up to the frame's resize handles
  and content owns its own spacing, so an application can fill its window
  edge to edge.
- `etaf-text-input` edits its value in a native session inside the layout:
  the field grows with wrapped or new lines while keeping its padding and
  frame, mouse clicks and drags place the caret and select, printing keys
  bound by the application still type, and other application changes keep
  publishing while it is edited. Pressing outside or unmounting leaves the
  field and keeps its text instead of cancelling.
  `etaf-text-input-end`'s optional argument is now HOW: nil submits, `blur`
  leaves without callbacks and any other value cancels. Code that inserted
  text into the application buffer during a session must type keys instead.

- An outlined `etaf-text-input` keeps one reserved hairline frame and
  recolours it with the accent while focused; editing shows a bar caret
  instead of a blinking underline, and nothing moves when focus changes.

- The catalog runs on ETAF's fine-grained retained runtime and requires it.
  Component APIs are unchanged; each reactive prop now updates only its own
  retained node, and a failing update leaves the committed controls in place
  until the next write retries it.  Interactions report
  `etaf-runtime-revision` rather than generation or publication counters.

- `etaf-range` paints a track with an accent Fill overlay: the Fill is an
  absolutely positioned Host painted above the track, so the split is visible
  in every context while the track keeps the row's measurable width. A caller
  may advance the Fill through ETAF's retained geometry update without
  republishing the View, and a press or drag re-proportions the two parts
  through the component's own ref before the caller's value arrives. The bar
  advertises the hand pointer.
- Traffic-light controls use one-cell ASCII marks when SVG is unavailable,
  avoiding fallback symbol fonts with taller physical text rows.

- Checkbox, radio, switch, selection, disclosure and close markers use ASCII
  characters from the inherited text font. This avoids symbol-font fallback
  increasing an entire Emacs physical row and shifting neighboring panes.
  Checkbox markers reserve three character cells for `[x]` and `[ ]`.

- Window shells, title bars and traffic lights inherit the surrounding Emacs
  typography by default instead of forcing 14 CSS pixels (10.5 points).
  Window title/body sizes can independently override inheritance with positive
  CSS pixel values; panel `font-family` now reaches its rendered content.

- Traffic-light SVG glyphs fill with `currentColor`, so the control Host's
  `:color` paints them. Focus changes no longer replace the glyph Text, and
  an inactive window's lights use the `:ui-window-title-fg` Theme token in
  graphical and textual Emacs alike. The window title row gives its content
  column a zero flex basis so the row lays out in a single render.
- Buttons are borderless pills. `primary` fills the accent in bold,
  `secondary` uses the soft accent tint and `ghost` inherits its surface with
  narrower padding; the variant name is part of the Button class. Checkboxes,
  radios and switches drop their border and background: a selected control
  and the checkbox mark paint the secondary button tint
  (`:ui-button-secondary-fg` on `:ui-button-secondary-bg`), as does the
  selected launcher or switcher row, so they stay crisp inside a dialog
  while a Desktop dims the shell's accent tokens.
  The fallback palette no longer defines `:ui-button-*-border`,
  `:ui-selection-*` or `:ui-checkbox-*-bg/-border`; Themes may drop them.
- Floating surfaces share one card anatomy: a one-row header with the title
  under a hairline, a body padded by one row and two columns, and a
  right-aligned footer. Dialogs and drawers add a pointer-only x named
  "Dismiss" to the header; the dialog's default close button is `secondary`. A fixed dialog
  height needs the body rows plus five instead of seven.
- Desktop bars render pill items separated by one column; the taskbar
  launcher is a `primary` button and the workspace layout control a
  `secondary` one. Picker rows pad two columns and mark the selected item with
  `*` in bold; unselected captions use normal weight.

### Removed

- `etaf-taskbar` and `etaf-workspace-bar` no longer accept `:accent-color`;
  selection paints the `:ui-accent` and `:ui-accent-soft-bg` Theme tokens.
  Provide a Theme with those tokens to change the accent.

### Fixed

- `etaf-range` without `:ref` now seeks on pointer clicks and drags.
- `etaf-tabs` gives every tab the same padding in both variants, so labels
  keep their positions when the active tab changes.
- An icon inside a control no longer hides the control's tooltip.
- Open popovers, dialogs and drawers keep their navigation and close keys
  when the application binds the same keys through an emulation map.
- Surfaces and the media viewer now hide the cursor and install their keys in
  the mounted application buffer even when opened from another buffer.

- A stretched `etaf-text-input` next to a label or icon in a row fills the
  remaining width, and long lines wrap back to the field's column.

- Reopening a text input whose value spans several rows edits that value
  with the caret at its end, instead of the first row's layout padding.
- A text input begun by a key command, or emptied while editing, keeps the
  caret inside the field; typed text no longer lands beside it.
- An icon missing from the requested, default and `sys` sets now resolves
  through the built-in `svg` set (or its text variant) before falling back to
  its printed name.

- `etaf-number-input` keeps its `−`/`+` steppers and value on one line inside
  another wrapping row, such as the desktop settings grid. Ebox measures a
  field that stretches inside a wrapping parent at the whole row, so an
  embedded field with an explicit width sizes its own row to that width
  instead of forcing every stepper onto its own line.
- `etaf-divider` keeps an unlabelled horizontal rule continuous: the one
  character column gap is reserved only when a label is present.

- A disabled button keeps its variant's padding and, for `ghost`, its
  transparent surface, so disabling a stepper or chip no longer widens it
  or fills it with the disabled surface.
- Inactive window traffic lights are gray again in graphical Emacs. The SVG
  glyph received a deferred Theme token instead of a color, which made every
  inactive control render as a black circle.
- `etaf-workspace-bar` renders a single space when its `:status` is nil or
  empty, so the status Text keeps owning its row. An empty string made Ebox
  paint the blank as box-owned pixels, which rejected the retained
  publication of every later status change and fell back to a structural
  re-render on each workspace switch.
- `etaf-launcher` and `etaf-switcher` items show their caption above the
  optional description instead of replacing it, and their Dialog is sized to
  the item list and centered. Modal Dialogs without an explicit `:height`
  no longer stretch to 80% of the window. Both pickers accept `:backdrop`
  so a Desktop can keep its surface painted under the modal.

- `etaf-window` forwards `drag-lock-modifier` to every edge and corner resize
  handle as well as its title. Modified resize gestures can continue after
  release, confirm on the next press, or cancel through the existing Ebox
  gesture contract. Standalone `etaf-resizable-panel` supports the same
  property with locking disabled by default; explicit nil disables locking.

- Workspace status uses a clipped single-row region; layout and settings
  actions stay at the right edge when status length changes. Long titles no
  longer push these controls out of the bar.

- Native text and number inputs omit decorative edit glyphs, and native
  Select/Menu controls use an ASCII marker. Opening forms no longer increases
  line height through a taller fallback font for those decorations.

- `etaf-dialog` can use a bounded row height and compact single-row title.
  Centering measures the window displaying its buffer, so a modal no longer
  falls back to the left edge when no dynamic Ebox viewport is bound.

- An inactive window renders all three macOS traffic lights in one gray and
  the active window keeps red, yellow and green.  `etaf-window` exposes
  `:controls-active` and `etaf-desktop` sets it from the focused window.

- `etaf-window` renders its title bar across the complete panel width.  The
  frame no longer reserves handle columns inside the panel: side and bottom
  cells own the panel's outer tracks, the header owns the title row, and its
  two corner cells keep the top edge resizable while the title keeps the move
  gesture.  Title backgrounds and bottom rules stay closed across the window.

- `etaf-splitter` overlay dividers accept `:divider-content` and `:z-index`.
  A positioned divider paints only the content it has, so a caller that owns
  the panes supplies the divider's rendered extent and stacking order.

- `etaf-splitter` accepts a caller-owned `:overlay-rect` so nested and
  constrained split dividers can occupy the exact gap reserved by the layout.

- Gallery diagnostic traces include the complete input operation, including
  Ebox pressed-state and focus publications outside the application callback.
  Latency and profiler passes continue measuring the unobserved input route.

- `etaf-button` forwards `:id` to the rendered Host, so anchor-based surfaces
  that reference a Button by identity resolve it instead of depending on a
  focus reference.
- Floating surfaces treat an unmounted or not-yet-committed panel as
  unavailable during key lookup and mount settling instead of failing the
  activation that is already mid-flight.

### Changed

- `etaf-window`, `etaf-window-chrome` and `etaf-window-controls` publish a
  reactive `:mode` or `:visible` change as retained Host property bindings
  (mode classes, panel visibility and the collapsed content column) instead
  of re-rendering the shell. The green traffic light is one stable "Zoom"
  control that restores a maximized window and maximizes any other; the
  separate "Maximize"/"Restore" labels are gone. `etaf-resizable-panel`
  accepts a ref or computed `:class`, and `etaf-taskbar` item `:state`
  values may be refs or computed. Desktop bar item tones read their active
  and state sources unconditionally so their bindings stay prepared.

### Added

- `etaf-workspace-bar` accepts a caller-owned ref or computed `:status` value;
  nil clears the status text. Both desktop bars retain their input targets
  while ref or computed selection values change.

- Gallery Review has continuous callback, keyboard and mouse performance
  scenarios that reuse one page and verify both directions of the toggle.
  First-click scenarios remain available separately.
- Add Drawer and ContextMenu compositions using the existing floating surface,
  with bounded side placement, modal blocking, keyboard dismissal and focus return.
- Add Tag, Kbd, Steps and List. Button accepts non-interactive default-slot
  content, so rich list rows share the standard focus and activation contract.
- Add DatePicker, Tree, Calendar and CommandPalette as compositions of the
  shared input, navigation, list and Dialog surfaces.
- Atelier Gallery includes responsive catalog columns, a paginated collection
  browser, dismissible tags, steps and an inspector drawer. Run
  `make gui-check GUI_EXAMPLE=gallery` for its native Emacs interaction workflow.

- `etaf-popover`, `etaf-dropdown-menu` and `etaf-dialog` provide in-buffer
  floating content, disabled action items and modal composition. They share
  Ebox positioning, occlusion and scoped focus through ETAF; closing and
  nested handoff restore a valid prior entry. Escape/C-g dismiss and Tab or
  arrow keys navigate. The application owns dialog state and form values.
- `etaf-ui-surfaces-open` opens a runnable composition example. These
  components require ETAF's `etaf-focus-within` and its Ebox provider.

### Changed

- Gallery performance checks use the shared workspace runner and registered
  scenarios. Use `--diagnose` for separate phase, CPU and allocation passes and
  `--baseline` to compare saved evidence. `PERF_TOOL` selects the workspace tool
  when the package is checked out separately. Replace `--trace` with `--diagnose`
  and `--output FILE` with `--output-dir DIRECTORY`; previous Gallery JSON files
  are not compatible with the shared runner's baseline schema.

- DataGrid composes the same row Components as Table, including row layout,
  selection paint and custom cell state. ETAF owns automatic row references and
  publishes current callback inputs. Address rows by Host reference; callback
  object identity is no longer kept stable by a separate UI cache. Public
  DataGrid props and explicit row references are unchanged.

- DataGrid shows idle, background refresh and cancellation states. Refresh
  retains interactive rows; Pagination disables page changes while refreshing.
  Update ETAF together with UI for the asynchronous Data status contract.

### Fixed

- `etaf-divider` keeps an unlabelled horizontal rule continuous: the one
  character column gap is reserved only when a label is present.

- Passive Tooltip and Toast surfaces no longer move focus to an empty panel
  root after mounting. Their dismissal keymap remains active while the extra
  focus-only Ebox publication is avoided, reducing overlay interaction latency.
- Avatar derives visible initials from its name when initials are omitted.
  Steps retain each label and number, and Breadcrumb callbacks report the
  selected index instead of the final loop index.
- Panel content has consistent vertical spacing; Gallery columns follow their
  own content height instead of stretching small sections to match neighbours.

- NumberInput rejects malformed labels, bounds and current values with component
  and property context. UI input checks share ETAF's `etaf-check-prop`; update
  ETAF together with UI for this input validation contract.

- Custom cells continue publishing state changes after combined row and column
  reordering. Table and DataGrid use Ebox's shared source identity matching;
  row Components no longer repeat their key on an internal Host. Update Ebox
  together with UI for the corrected Range identity behavior.

- Table and DataGrid pass original rows through keyed iteration, preserving
  unchanged input identities. Replacement row objects update callbacks even
  when contents match, while stable keys retain cell state and focus.

- DataGrid no longer interprets a row's `:etaf-data-grid-state` or `:text`
  business fields as loading/error metadata.

- Label now supports its documented width, padding and border attributes.
  It composes an Ebox Box and Text, so constrained prose can wrap and reflow
  after content or viewport changes. The `etaf-label` class and forwarded
  attributes address the Box; selectors explicitly requiring a Text root
  should use `.etaf-label` instead. Raw `text` Hosts remain unchanged.

- Native pointer, help and hover feedback can be requested through control
  root attributes with the updated ETAF bridge. Correct the manual's claim
  that all controls provide this feedback by default.

- Empty accepted DataGrid pages still announce background refresh while preserving their empty-state message.

### Added

- Add Menu actions with disabled choices and a composable native confirmation
  dialog. Both reuse the existing Button/input ownership and focus behavior.

- Keep accepted DataGrid rows and their actions visible during pending writes, errors and cancellation, with separate status text.

- Add TextInput and Select with controlled values or `:bind`. All native inputs, including NumberInput, use the shared target lifetime and focus boundary; update ETAF and Ebox together.

- Checkbox and NumberInput accept `:bind` with an existing writable ETAF ref.
  The controls read and update that same ref through their controlled interface.
  Explicit value or `:on-change` props conflict with a non-nil binding, including
  explicit nil. Existing value/callback usage remains available for business
  operations and transformations.
