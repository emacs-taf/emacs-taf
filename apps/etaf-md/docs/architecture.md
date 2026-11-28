# ETAF Markdown Preview architecture

## Module layout

| File | Responsibility |
| --- | --- |
| `etaf-md.el` | Package entry: the public API inventory, the feature closure and the `lisp/` load-path bootstrap. |
| `lisp/etaf-md-node.el` | The document model: one definition per node type (attributes, derivations, accepted children, child syntax) and the registry behind it. |
| `lisp/etaf-md-nodes.el` | The shipped definitions of the container vocabulary, written the way a reader writes one. |
| `lisp/etaf-md-components.el` | The site half of that catalogue: cards, code panes, link cards, tables, forms and the other shapes a documentation page writes. |
| `lisp/etaf-md-widgets.el` | Editorial and Emacs-native living-document containers (`progress`, `keymap`, `breadcrumb`, `diff`, `pros-cons`, `demo`, `chart`, `include`, `code-ref`, `symbol`, `project-tree`, `git-log`, `git-diff`, `run`). |
| `lisp/etaf-md-assets.el` | Sandboxed workspace-root reader (`etaf-md-allow-local-read`) and trust-gated action runner (`etaf-md-allow-actions`) that pre-attach live data outside `:render`. |
| `lisp/etaf-md-qrcode.el` | A `qrcode` block: reads a picture from the cache, requests one asynchronously via `etaf-process-run` (`qrencode`). |
| `lisp/etaf-md-cache.el` | Shared LRU disk cache eviction (`etaf-md-cache-max-bytes`) and asynchronous remote HTTP(S) image fetching (`etaf-md-remote-images`). |
| `lisp/etaf-md-env.el` | The paint environment each definition receives: node, session, palette, measure, per-block isolated state refs and paint helpers. |
| `lisp/etaf-md-theme.el` | Palettes, semantic color lookup, typography helpers and the ETAF UI token plist. |
| `lisp/etaf-md-model.el` | Session state, source reading, the container pre-parse, refresh, reading measure, outline navigation, link opening and publishing. |
| `lisp/etaf-md-views.el` | Presentation of a markdown block: the reading column, the page header, inline runs and the media layer. |
| `lisp/etaf-md-app.el` | The Component, the buffer, the keymap, the interactive commands and the follow machinery. |
| `lisp/etaf-md-live.el` | Repainting a mounted page from its source buffer, block by block. |
| `lisp/etaf-md-typeset.el` | Diagram and formula pictures: cache keys, embedded QuickJS native backend dispatch and `mermaid-cli` fallback. |
| `native/` | Optional Emacs dynamic module (`etaf-md-typeset-native`) embedding QuickJS, vendored Obsidian Pele (Mermaid→SVG), MathJax (TeX→SVG) and CoreText/Pango text measurement, inspired by [LuciusChen/pele.el](https://github.com/LuciusChen/pele.el). |

Markdown itself is parsed by `etaf-doc-markdown`; this package parses the `:::name` container syntax around it and owns what each node type paints.

Only ETAF and ETAF UI public interfaces are used by the application; the buffer is an ordinary Emacs buffer rendered by Ebox through ETAF. The previewer never calls an `ebox-` function directly.

## Data flow

```
file or text → parser → document plist → session refs → views → ETAF mount → Ebox retained tree
                                         ↑
                          theme / width / errors (reactive refs)
```

- **Parser.** `etaf-md--parse` is a pure function over a string. A document that writes `:::name {attrs}` containers goes through this package's own pre-parse, which reads the fences, nests them and parses each block's body; everything inside a block, and every document without containers, is handed to `etaf-doc-markdown-parse`, so the markdown grammar is written once for every viewer in the ecosystem. The output carries no presentation facts.
- **Model.** A session is a plist of `etaf-ref`s: document, title, theme, reading measure and error text. Every displayed value is read through `etaf-md--read` while rendering, so a refresh, a theme change or a measure change repaints the mounted preview through the ordinary ETAF reactive path; no code calls the renderer or the buffer directly. A window resize is not a session change: the column is viewport-relative and reflows through the renderer's own viewport update.
- **Views.** `etaf-md--view-document` composes a centered reading column from `etaf-node` values: flexible spacers center a column whose width stretches to the window up to the session's measure. Inline content becomes styled `text` runs; links and footnote references carry `:on-press` boundaries that ETAF turns into Ebox keymaps. Media blocks use the ETAF `image` Host, which owns graphics and terminal adapters and the video poster frame.
- **Application.** `etaf-md-app` is the only place that reads the session's refs; it also provides the palette tokens for its subtree. The shell adds what a Component cannot own: the buffer, the keymap, the initial measure and the commands.

## Rendering decisions

**Whole-document native scrolling.** The document is rendered as one tall buffer instead of a fixed-height canvas with an internal scroll owner. A window then scrolls the real buffer, so isearch, marks, `goto-char` and window splitting behave normally, and heading navigation is a buffer search instead of a scroll-offset protocol. The reading column is centered with flexible spacers and stretches to the window up to the session's measure. The measure is the only width the application owns, so a window resize is a framework viewport update: the view is not rebuilt and the session does not change.

The column is padding, not a margin: two cells of gutter sit on each side of the measure, and the column clips at its padding edge. Both follow from the renderer: a window that fills the measure leaves no room for centering, and the mount extends the last cell's background into the window's sub-cell remainder, so a table border on the reading edge would paint a bar across the gutter. Clipping is also what keeps a too-wide block inside the measure when the window is narrower than the minimum measure.

**Inline runs are separate `text` Hosts.** Inline style is expressed as one `text` Host per run inside a normal `box` with `word` wrapping; Ebox composes the children into one wrapped flow, so the application keeps no inline layout algorithm of its own.

**Media through the ETAF image Host.** Images and video posters are prepared by Ebox's image protocol (`ebox-image-prepare`/`ebox-image-create`) behind the public ETAF `image` Host. The app computes the cell grid from the source's pixel size (ffprobe for videos) and the frame metrics, caps the height, and wraps the image in an interactive Box for opening (or launching the in-buffer media lightbox when `etaf-md-media-lightbox` is enabled). Remote HTTP(S) images fetch asynchronously into the bounded LRU disk cache (`etaf-md-remote-images`, `etaf-md-cache-max-bytes`) once mounted and repaint in place upon arrival; missing files and uncached remote URLs render labeled placeholder cards rather than errors.

**A typeset block is a file the page points at.** A `$$` display formula and a `mermaid` fence are rendered asynchronously into `~/.cache/etaf-md/typeset/`, and the block carries the resulting `:picture` path. The cache key hashes the backend (`native`), block kind, pipeline version, source text, page palette, font stack and type size, so unchanged blocks hit disk in O(1) while theme, font or renderer changes draw fresh pictures. While live-editing a previously rendered block, the slot keeps its last valid picture visible (stale-while-revalidate) until the replacement SVG lands, avoiding flashes back to raw source when syntax is transiently incomplete.

The renderer is the optional C11 Emacs dynamic module `etaf-md-typeset-native.{dylib,so}` (downloaded into `~/.cache/emacs-taf/native/etaf-md/1/` via `M-x etaf-install-native` from the checksum-verified `native/manifest.json`, or built locally in a source checkout with `make native-build`), whose architecture is directly inspired by [LuciusChen/pele.el](https://github.com/LuciusChen/pele.el). A single dedicated `pthread` owns a sandboxed [QuickJS](https://github.com/bellard/quickjs) runtime (256 MiB memory cap, per-job `JS_SetInterruptHandler` deadline, atomic cancellation, zero OS/filesystem/network bindings) and wakes Emacs through `env->open_channel` on an Emacs pipe process without spawning any child processes or browsers. Mermaid fences are rendered by unmodified vendored [Pele](https://github.com/obsidianmd/pele) (`native/vendor/pele/pele.global.js`) using native CoreText (macOS) or Pango (Linux, dynamically loaded via `dlopen` in portable builds with estimator fallback) label measurement (`__etafMdMeasureText`) and static CSS custom-property resolution (`portableSvg`) so `librsvg` paints exact page-theme colors and rounded corners without `<foreignObject>`. Display math `$$...$$` blocks lazily initialize vendored [MathJax](https://github.com/mathjax/MathJax-src) TeX-to-SVG (`native/vendor/mathjax/mathjax-tex-svg.global.js`, `fontCache: 'none'`) inside the same worker thread, emitting standalone `<svg>` paths centered in whole text rows (`cell`) with the page's ink color and font stack for CJK `\text{...}` runs. When the native module is absent, diagrams stay as fenced code blocks and formulas keep their clean text rendering.

A picture is placed in cells, so its grid is measured in the cells the page paints rather than the frame's defaults: `etaf-display-metrics` is a reactive read, and the framework republishes it when the buffer's text scaling settles, which is what makes a scaled page lay its pictures out again instead of leaving slices cut for the old line height. Unlike standalone photo cards (capped at 20 rows), typeset diagrams are bounded by the reading measure's width with a generous 120-row safety ceiling so vertical flowcharts, state machines and ER diagrams keep crisp 1:1 typography while scrolling naturally with the document; activating a diagram opens the in-buffer media lightbox when enabled so wide diagrams can be inspected at full window width.

**The page is a paint; the source is where text is written.** A preview listens to the buffer visiting its file and republishes the page from the edited text on the next frame, so a reader who edits above the preview sees it change without leaving the text.  Motion, paging, the wheel, isearch and all scrolling belong to the buffer: one cell is one painted character, so Emacs owns them.  There is no editing session on the page and no projection back to the source; the markdown is edited in its own buffer with the commands the reader already has.

A repaint is a parse plus a publish, and both are incremental in O(Δ).  Source edits capture exact `(old-beg old-end new-end)` dirty spans from `after-change-functions`, coalesce on a 16 ms tick and yield while `input-pending-p` up to a 60 ms deadline.  `etaf-md--splice-parse` reuses unchanged prefix and suffix blocks (including block 0 edits, blank-line insertions and paragraph splits), provisionally closes newly opened unclosed code fences while typing (settling on close or save), injects cached document-wide link/abbreviation definitions into slices, and incrementally recomputes outline heading IDs.  Each top-level block owns a stable opaque slot (used as the `:key` on its outer `box`), a dedicated `:cell` reactive ref, and— for containers — its own pre-allocated interactive state ref; trailing blank lines fold into `:margin-bottom` instead of spawning separate Components. In-place text edits update only that block's `:cell` without touching `:page-structure`, so `etaf-md-app` does zero work and Ebox patches only the changed lines.  External asset jobs (mermaid/KaTeX, `qrencode`, remote images) are idle-debounced during live typing and refresh only the owning block's `:cell` upon arrival, with bounded LRU eviction across the cache directories.

**Session as the only state.** There is no second copy of the outline, theme or document. Navigation recomputes heading positions from the live buffer on demand; the state snapshot copies values for tests and scripts. This keeps the model usable without a buffer and keeps rendering reproducible from the document plus the environment.

## Performance envelope

`benchmarks/performance-scenarios.el` registers this application's accepted budgets with the workspace performance driver:

- `md-preview.mount.manual` parses and mounts `examples/sample.markdown`: 100 ms.
- `md-preview.republish.diagrams` republishes `examples/all-syntax.markdown` (47k characters, thirty-four diagrams) after an edit: 500 ms.  It guards the picture path: a page's generated mermaid configuration is a per-page constant, and building it once per diagram made a republish cost 2.4 s.
- `md-preview.refit.width` cycles the reading measure through several widths on a mounted page: 10 ms.
- `md-preview.live-edit.top-block`, `md-preview.live-edit.insert-blank-top`, `md-preview.live-edit.split-para-top` and `md-preview.live-edit.code-block` measure incremental live edits on `benchmarks/live-edit-document.markdown`: budgets 12 / 12 / 20 / 20 ms respectively, enforcing Ebox `'lines` strategy.

All scenarios run in batch and GUI modes. Three batch sets of 10 samples on the shared development machine (Emacs 31.1, aarch64) measure sample mount p50 41.7 ms (p95 57.1 ms) and refit p50 5.6 ms (p95 7.3 ms); the diagram republish costs p50 93 ms.  Parsing and publishing the diagram page from nothing — `etaf-md-create` — costs 274 ms; mounting it is a separate 1.4 s of layout for three thousand painted lines, which is the renderer's cost rather than the previewer's.

A mount builds the retained Ebox tree once and writes the buffer once. A refit keeps that tree: Ebox relays out only the width-dependent paragraphs and rewrites the lines whose text changed, so its cost follows the wrapped text, not the number of Hosts.

## Verification

- Public behaviour tests mount real runtimes in batch Emacs and read the visible buffer back (text, faces, keymaps, placeholders). They are inventoried in `tests/acceptance.json` and run by `make acceptance`.
- `scripts/etaf-md-gui-probe.el` checks the frame-level invariants a batch run cannot see: no line wider than its window, an interactive link present, a nonempty outline.
- `benchmarks/render-large-document.el` prints parse, mount and refresh times for a deterministic generated document; it is a comparison baseline, not a gate.
- `benchmarks/performance-scenarios.el` registers the mount and refit workloads with the workspace driver (`--mode batch|gui`); the budgets and the diagnostic passes live there rather than in `make check`.
