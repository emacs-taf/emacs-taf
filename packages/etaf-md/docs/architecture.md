# ETAF Markdown Preview architecture

## Module layout

| File | Responsibility |
| --- | --- |
| `etaf-md.el` | Package entry: the public API inventory, the feature closure and the `lisp/` load-path bootstrap. |
| `lisp/etaf-md-node.el` | The document model: one definition per node type (attributes, derivations, accepted children, child syntax) and the registry behind it. |
| `lisp/etaf-md-nodes.el` | The shipped definitions of the container vocabulary, written the way a reader writes one. |
| `lisp/etaf-md-components.el` | The site half of that catalogue: cards, code panes, link cards, tables, forms and the other shapes a documentation page writes. |
| `lisp/etaf-md-qrcode.el` | A `qrcode` block: reads a picture from the cache, requests one from `qrencode` in the background. |
| `lisp/etaf-md-env.el` | The paint environment each definition receives: node, session, palette, measure, and the helpers a paint may call. |
| `lisp/etaf-md-theme.el` | Palettes, semantic color lookup, typography helpers and the ETAF UI token plist. |
| `lisp/etaf-md-model.el` | Session state, source reading, the container pre-parse, refresh, reading measure, outline navigation, link opening and publishing. |
| `lisp/etaf-md-views.el` | Presentation of a markdown block: the reading column, the page header, inline runs and the media layer. |
| `lisp/etaf-md-app.el` | The Component, the buffer, the keymap, the interactive commands and the follow machinery. |
| `lisp/etaf-md-live.el` | Repainting a mounted page from its source buffer, block by block. |
| `lisp/etaf-md-typeset.el` | Diagram and formula pictures: cache keys, the background renderer and its process. |

Markdown itself is parsed by `etaf-ui-markdown`; this package parses the
`:::name` container syntax around it and owns what each node type paints.

Only ETAF and ETAF UI public interfaces are used by the application; the
buffer is an ordinary Emacs buffer rendered by Ebox through ETAF. The
previewer never calls an `ebox-` function directly.

## Data flow

```
file or text → parser → document plist → session refs → views → ETAF mount → Ebox retained tree
                                         ↑
                          theme / width / errors (reactive refs)
```

- **Parser.** `etaf-md--parse` is a pure function over a string. A document
  that writes `:::name {attrs}` containers goes through this package's own
  pre-parse, which reads the fences, nests them and parses each block's body;
  everything inside a block, and every document without containers, is handed
  to `etaf-ui-markdown-parse`, so the markdown grammar is written once for
  every viewer in the ecosystem. The output carries no presentation facts.
- **Model.** A session is a plist of `etaf-ref`s: document, title, theme,
  reading measure and error text. Every displayed value is read through
  `etaf-md--read` while rendering, so a refresh, a theme change or a
  measure change repaints the mounted preview through the ordinary ETAF
  reactive path; no code calls the renderer or the buffer directly. A window
  resize is not a session change: the column is viewport-relative and reflows
  through the renderer's own viewport update.
- **Views.** `etaf-md--view-document` composes a centered reading
  column from `etaf-node` values: flexible spacers center a column whose width
  stretches to the window up to the session's measure. Inline content becomes
  styled `text` runs; links and footnote references carry `:on-press`
  boundaries that ETAF turns into Ebox keymaps. Media blocks use the ETAF
  `image` Host, which owns graphics and terminal adapters and the video poster
  frame.
- **Application.** `etaf-md-app` is the only place that reads the
  session's refs; it also provides the palette tokens for its subtree. The
  shell adds what a Component cannot own: the buffer, the keymap, the initial
  measure and the commands.

## Rendering decisions

**Whole-document native scrolling.** The document is rendered as one tall
buffer instead of a fixed-height canvas with an internal scroll owner. A
window then scrolls the real buffer, so isearch, marks, `goto-char` and window
splitting behave normally, and heading navigation is a buffer search instead
of a scroll-offset protocol. The reading column is centered with flexible
spacers and stretches to the window up to the session's measure. The measure
is the only width the application owns, so a window resize is a framework
viewport update: the view is not rebuilt and the session does not change.

The column is padding, not a margin: two cells of gutter sit on each side of
the measure, and the column clips at its padding edge. Both follow from the
renderer: a window that fills the measure leaves no room for centering, and
the mount extends the last cell's background into the window's sub-cell
remainder, so a table border on the reading edge would paint a bar across the
gutter. Clipping is also what keeps a too-wide block inside the measure when
the window is narrower than the minimum measure.

**Inline runs are separate `text` Hosts.** Inline style is expressed as one
`text` Host per run inside a normal `box` with `word` wrapping; Ebox composes
the children into one wrapped flow, so the application keeps no inline layout
algorithm of its own.

**Media through the ETAF image Host.** Images and video posters are prepared
by Ebox's image protocol (`ebox-image-prepare`/`ebox-image-create`) behind the
public ETAF `image` Host. The app computes the cell grid from the source's
pixel size (ffprobe for videos) and the frame metrics, caps the height, and
wraps the image in an interactive Box for opening. Missing files and remote
URLs never reach the Host; they become labeled placeholder cards.

**A typeset block is a file the page points at.** A `$$` display formula and a
`mermaid` fence are drawn by `scripts/mermaid-render.mjs` into the cache
directory, and the block names the picture. The cache key hashes the source,
the page's palette, the frame's type size and the version of the drawing
pipeline, so a document that did not change keeps its pictures across reloads,
while a theme, size or renderer change draws them again. The render runs
asynchronously and republishes the page when its picture lands, so a slow
diagram never blocks the first paint. While it runs, or when the program fails,
the block stays its source text: a diagram that cannot be parsed shows its
fence and the parser's message, not a broken picture.

The renderer is one process for the session, not one per block. Starting
Chromium costs seconds and drawing into a running one costs a fraction of that,
so the process starts once, keeps a few pages that draw in parallel, and stops
itself after a while without work. It answers requests by number, which is what
lets the page take pictures in whatever order they finish.

The configuration is generated from the page rather than taken from mermaid's
fixed themes, so a diagram is drawn in the page's ink, boxes and borders. It
travels to the renderer as the JSON text the preview generated, because a
round trip through an Emacs plist turns every `false` into the string
`"false"`, which mermaid reads as true. Three parts of it answer to mermaid's
quirks:

- Mermaid sizes each kind of diagram on its own and gives several of them a
  minimum box (a state node 120 pixels wide, an entity 100 by 75, a requirement
  200), which left a short Chinese label in a frame with room to spare; the
  configuration lowers those floors and tells every kind the page's size.
- Mermaid colours everything that separates items by hue - pie slices, git
  branches, timeline periods, journey sections, mind-map children - from scales
  it derives by darkening the page's box colour. On a dark page that derivation
  ends at black, and mermaid has no way to know the page is dark. The scales
  therefore come from the page's callout colours, mixed into the page
  background just far enough that the page's ink reads on the fill and the fill
  still stands off the page.
- A few surfaces are fixed light-page colours whatever the page is: a gantt's
  finished, running and late tasks are light grey, white and red, its section
  bands and grid are greys, an entity's attribute rows lighten the box towards
  white, and a cluster, an edge label and a journey's title take colours that
  vanish on a dark page. Each takes the page's own colour for the same idea -
  finished is its success colour, running its accent, late its danger, and the
  remaining surfaces a tint of the page towards its ink.

A picture is the diagram's own canvas: the viewBox mermaid sized the drawing
to, at the size of the page's type. An explicit height is dropped because
several kinds declare one that does not match their drawing, which is what left
a band of empty picture under a journey. A picture wider than the reading
measure is narrowed in whole cells, and the width decides the height, so the
right edge of a wide diagram is never cut off by its column.

A diagram is shown from its vector copy. The renderer writes the drawing's own
SVG beside the raster and the page places that, so the text stays sharp at any
size and no twice-size bitmap is held in memory; the raster remains the
fallback, and a kind whose labels mermaid writes as HTML stays a raster because
nothing outside a browser can draw one. Two parts of the drawing exist for that
renderer rather than for a browser: the configuration asks for text labels
instead of `foreignObject`, and the SVG declares its own size so a viewer can
place it without measuring the page.

A picture is placed in cells, so its grid is measured in the cells the page
paints rather than the frame's defaults: `etaf-display-metrics` is a reactive
read, and the framework republishes it when the buffer's text scaling settles,
which is what makes a scaled page lay its pictures out again instead of leaving
slices cut for the old line height.

The document keeps the last word: a `%%{init: ...}%%` directive or a YAML front
matter `config` block in the block's own source overrides the generated
configuration, which is mermaid's own precedence. `make mermaid-check` drives
`scripts/mermaid-render.mjs` over a fixture of every kind in each page palette
and asserts what a picture must satisfy: a categorical fill carries its label
and stands off the page, the vector exists and holds its words as text, and a
renderer that is not a browser - `rsvg-convert`, the engine Emacs draws SVG
with - paints the same extent and a similar amount of ink.

**The page is a paint; the source is where text is written.** A preview
listens to the buffer visiting its file and republishes the page from the
edited text on the next frame, so a reader who edits above the preview sees it
change without leaving the text.  Motion, paging, the wheel, isearch and all
scrolling belong to the buffer: one cell is one painted character, so Emacs
owns them.  There is no editing session on the page and no projection back to
the source; the markdown is edited in its own buffer with the commands the
reader already has.

A repaint is a parse plus a publish, and both are keyed by block.  The parse
re-uses the blocks an edit left alone and re-reads only the block under the
edit and its neighbours, because deleting one blank line can merge two blocks
into one.  The publish names each top-level block by its type and a digest of
its own source, so an unchanged block keeps its published Component instance,
its video handles and its reading position, and only the edited block renders
again.  The page's picture constants — the mermaid configuration generated
from its colours and type size — are built once per page instead of once per
diagram, which is what keeps a keystroke cheap on a document that holds many
diagrams.

**Session as the only state.** There is no second copy of the outline, theme
or document. Navigation recomputes heading positions from the live buffer on
demand; the state snapshot copies values for tests and scripts. This keeps the
model usable without a buffer and keeps rendering reproducible from the
document plus the environment.

## Performance envelope

`benchmarks/performance-scenarios.el` registers this application's accepted
budgets with the workspace performance driver:

- `md-preview.mount.manual` parses and mounts `examples/sample.markdown`:
  100 ms.
- `md-preview.republish.diagrams` republishes `examples/all-syntax.markdown`
  (47k characters, thirty-four diagrams) after an edit: 500 ms.  It guards the
  picture path: a page's generated mermaid configuration is a per-page
  constant, and building it once per diagram made a republish cost 2.4 s.
- `md-preview.refit.width` cycles the reading measure through several widths
  on a mounted page: 10 ms.

All scenarios run in batch and GUI modes. Three batch sets of 10 samples on the
shared development machine (Emacs 31.1, aarch64) measure sample mount p50
41.7 ms (p95 57.1 ms) and refit p50 5.6 ms (p95 7.3 ms); the diagram
republish costs p50 93 ms.  Parsing and publishing the diagram page from
nothing — `etaf-md-create` — costs 274 ms; mounting it is a separate 1.4 s
of layout for three thousand painted lines, which is the renderer's cost
rather than the previewer's.

A mount builds the retained Ebox tree once and writes the buffer once. A refit
keeps that tree: Ebox relays out only the width-dependent paragraphs and
rewrites the lines whose text changed, so its cost follows the wrapped text,
not the number of Hosts.

## Verification

- Public behaviour tests mount real runtimes in batch Emacs and read the
  visible buffer back (text, faces, keymaps, placeholders). They are
  inventoried in `tests/acceptance.json` and run by `make acceptance`.
- `scripts/etaf-md-gui-probe.el` checks the frame-level invariants a batch
  run cannot see: no line wider than its window, an interactive link present,
  a nonempty outline.
- `benchmarks/render-large-document.el` prints parse, mount and refresh times
  for a deterministic generated document; it is a comparison baseline, not a
  gate.
- `benchmarks/performance-scenarios.el` registers the mount and refit
  workloads with the workspace driver (`--mode batch|gui`); the budgets and
  the diagnostic passes live there rather than in `make check`.
