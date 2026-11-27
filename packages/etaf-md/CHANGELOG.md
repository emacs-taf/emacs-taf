# Changelog

All notable user-visible changes to `etaf-md` are documented in this file.

## Unreleased

### Changed

- Redesigned the independent `*ETAF Outline*` TOC side window (`T` / `M-x etaf-md-toggle-toc`, configurable via `etaf-md-toc-side` defaulting to `'left` and `etaf-md-toc-width` defaulting to `28`) so variable-height headings and media in the preview buffer never stretch or jitter TOC rows during scrolling, while preserving pure native whole-buffer scrolling, active-heading highlighting, and automatic teardown on close.
- Upgraded `etaf-md-preview-link` (`K`) to a viewport-centered floating `etaf-dialog` with scrollable body and second-press toggle dismissal, visible from any scroll position.
- Adopted a two-tier interactive command surface and customizable single-key defaults (`etaf-md-keys`): globally autoloaded `M-x` still exposes strictly `etaf-md-open` and `etaf-md-preview`, while all preview actions are now buffer-scoped interactive commands (`completion-predicate`) bound to single keys with zero `C-c` / `C-t` / `C-x` prefix shadowing.

- The official ETAF package archive now ships `examples/`, `docs/`, `scripts/`, `tests/`, `benchmarks/`, `Makefile`, and `native/` sources (still excluding `native/build/` and compiled binaries) so archive installations include all example documents, documentation, and local source-build files.

### Fixed

- Guarded the autoloaded `lisp/` `load-path` setup against missing `lisp/` directories and `nil` path candidates during eager macro-expansion, flattened builds (`straight.el` / Doom / MELPA), and `package-quickstart`.
- Clicking any heading in the TOC sidebar now jumps to that exact heading instead of always capturing the final heading index in the `cl-loop`.
- Up and down arrow keys now scroll the Markdown reading viewport smoothly one line at a time instead of jumping between focusable controls, and unfocused code-tree blocks let page scrolling glide past them.

## [0.3.0] - 2026-11-25

### Added

- Embedded QuickJS native typesetting module (`native/etaf-md-typeset-native.{dylib,so}`, built via `make native-build`) for zero-browser Mermaid and `$$` display-math SVG rendering, directly inspired by [LuciusChen/pele.el](https://github.com/LuciusChen/pele.el):
  - Runs unmodified vendored [Obsidian Pele](https://github.com/obsidianmd/pele) (1.13.0) with native CoreText (macOS) / Pango (Linux) label measurement and static CSS custom-property resolution (`portableSvg`) plus lazily initialized vendored [MathJax](https://github.com/mathjax/MathJax-src) (3.2.2) TeX-to-SVG inside a single sandboxed QuickJS (2026-06-04) background `pthread` waking Emacs through `open_channel` (zero Chromium, Node.js or child processes).
  - Supports Mermaid diagrams and display formulas inside `:::` containers, keeps the last valid picture visible while live-editing incomplete syntax (stale-while-revalidate), reports `typeset-native` in `etaf-md-doctor`, and automatically falls back to `scripts/mermaid-render.mjs` when the native module is absent or for unsupported Mermaid dialects (picture cache version 7).
- Curated editorial and Emacs living-document containers (`lisp/etaf-md-widgets.el`) plus sandboxed workspace asset and trust layer (`lisp/etaf-md-assets.el`):
  - Lightweight editorial structure: `progress` (single/multi-row), booktabs `keymap` (fixed-width keycap column with `/` rendered as a plain separator), and inline `breadcrumb`.
  - Comparison & live examples: paired aligned `diff` (`@before`/`@after` with side-by-side/unified toggle and automatic narrow fallback), borderless equal-height `pros-cons` (`@pro`/`@con`), and `demo` (clean preview canvas with a thin footer bar and flush expandable source).
  - Emacs-native living-document widgets: read-only workspace-sandboxed L1 widgets (`include`, `code-ref` with full top-level Elisp sexp extraction, API-style `symbol` with intact first-paragraph docstrings, `project-tree`, booktabs `git-log` supporting Git and Jujutsu, `git-diff`) pre-attached outside `:render`, plus trust-gated Runbook `run` controlled by `etaf-md-allow-local-read` and `etaf-md-allow-actions`.
  - Upgraded `table` (`align`, width clamping, `sortable=true` booktabs layout and unified header/copy strip), 4-quadrant `stats`/`stat` (`trend`, `note`, `accent`, `spark`), equal-height horizontal `timeline` (`orientation=horizontal`, `card=true`), `file-tree` (`lines=false`, bold focus, `collapsible=true`, `clickable=true`), and `chart` (`type=bar|stacked|heatmap`, `labels`, `unit`, `accent`).
  - Extended `etaf` dialect inline and fence syntax via `etaf-ui-markdown`: `!!spoiler!!`, `[+label]` rich inline annotations, interactive `*[ABBR]:` cards, `[[wiki-link]]`, `%%comment%%`, `:color[...]`, `:sym[...]`, Obsidian collapsible `> [!tip]-` alerts, `:collapsed-lines[=N]`, `/word/` and `[!code word:...]` highlighting, `:whitespace`, and `:indent-guides`.
  - Reader shell affordances: independent right side-window `*ETAF Outline*` (`C-c t`, `etaf-md-toggle-toc`), global spoiler reveal/hide (`S`, `etaf-md-toggle-spoilers`), in-buffer link/symbol preview card (`K`, `etaf-md-preview-link`), interactive GFM task checkbox write-back (`etaf-md-interactive-checkbox`), in-buffer media lightbox (`etaf-md-media-lightbox`), and `git` capability reporting in `etaf-md-doctor`.
  - Strict leaf-only pointer hover discipline across all widgets, tabs, tables, code blocks, callouts, and cards.
- Asynchronous remote HTTP(S) image caching (`etaf-md-remote-images`, default `t`) and bounded LRU disk cache eviction (`etaf-md-cache-max-bytes`, default 100 MiB) shared across rendered diagrams, QR codes and remote images, with zero network or disk I/O during headless `etaf-md-create` or `:render`.
- `etaf-md-create` accepts `:on-link` (`(url)`) and `:on-media` (`(kind path)`, where `kind` is `image` or `video`) callbacks so embedding applications can intercept link and media activation, plus `:link-hover` and `:heading-underline` presentation flags.
- Added Chinese README ([README.zh-CN.md](README.zh-CN.md)) and bundled `native/` sources in archive releases so `M-x etaf-install` users can build the native QuickJS renderer offline.

### Changed

- Simplified the global `M-x` command surface to strictly two interactive entry commands (no minor mode, zero leaked preview-local commands even with default `read-extended-command-predicate = nil`):
  - `etaf-md-open` is the single-window full-width default reading entry (opens the current visiting Markdown file directly without prompting or splitting windows and syncs to the current source line; pass `C-u` or run from another buffer to prompt for a file; `q` restores the originating buffer in place without deleting the window).
  - `etaf-md-preview` toggles a non-destructive right-split live preview with proportional scroll-follow beside the Markdown source window while keeping point in the source (running it again or pressing `q` in the preview closes only the split it created, and manual window closing leaves zero stale mode state). Inside a preview buffer, `v` (`etaf-md-toggle-split`) toggles side-by-side editing in place, `e` joins `o` for jumping to source, and `g` joins `r` for reload.
  - All 14 preview-buffer actions (`etaf-md-close`, `etaf-md-toggle-split`, `etaf-md-cycle-theme`, `etaf-md-toggle-toc`, `etaf-md-toggle-spoilers`, `etaf-md-preview-link`, `etaf-md-follow-scroll`, `etaf-md-next-heading`, `etaf-md-previous-heading`, `etaf-md-goto-heading`, `etaf-md-goto-source`, `etaf-md-reload`, `etaf-md-wider`, `etaf-md-narrower`) are plain non-interactive Lisp functions dispatched directly by preview-buffer keys, remaining callable from Lisp without polluting global `M-x`.
- `etaf-md-cycle-theme` (`t`) now includes `auto` in the cycle (`dark` → `light` → `sepia` → `auto` → `dark`), `etaf-md-locate` pushes mark before jumping, and code/table copy actions echo confirmation messages.
- `etaf-md-goto-source` (`e` / `o`) jumps from preview point back to the corresponding line in the source buffer with proportional intra-block mapping and a momentary line highlight; `f` (`etaf-md-follow-scroll`) tracks both keyboard motion and mouse/trackpad scrolling via `window-scroll-functions` using O(1) buffer markers.
- Typeset Mermaid diagrams and display formulas now size by reading-column width (with a 120-row safety ceiling instead of the 20-row photo card cap), keeping portrait flowcharts, state machines, ER diagrams and sequence diagrams at crisp 1:1 body-text scale instead of shrinking their labels; pressing `RET` or clicking a Mermaid diagram opens it in the in-buffer media lightbox when `etaf-md-media-lightbox` is enabled.

### Fixed

- Restored full vertical grid borders (`:border-left` / `:border-right`) on `:::table` containers so container tables match the complete grid presentation of standard Markdown pipe tables while keeping header emphasis, sorting, alignment and copy controls.
- Fixed multi-tab headless Chromium CDP screenshot deadlocks in the `scripts/mermaid-render.mjs` fallback by serializing diagram rendering to a single recycled page (`WORKERS = 1`), starting per-job timeouts after page acquisition rather than while queued, and closing/reopening the page on timeout or error; serialized concurrent KaTeX display-math renders so multiple `$$...$$` blocks never poison disk cache entries.
- Trailing footnote/link/abbreviation definitions after the final body block no longer accumulate one blank row per definition into `:margin-bottom` above the footnotes divider, keeping a single compact blank line between the body end and `脚注` regardless of footnote count.
- Incremental live editing no longer falls back to full-document repaints on top-block edits, blank-line insertions, paragraph splits, or newly opened unclosed code fences: blocks keep stable opaque slots and per-block reactive cells, blank lines fold into `:margin-bottom`, splice-parsing uses exact `after-change-functions` dirty spans with provisional closing for unsaved unclosed fences, and outline headings plus document-wide reference links/abbreviations stay synchronized.
- Narrow windows wrap prose cleanly without right-edge clipping and expand back up to the reading-measure cap when widened (`:width 'stretch` with `:max-width`).
- Two files sharing a basename in different directories open distinct preview buffers with disambiguated names, and symlinked files synchronize live edits through `find-buffer-visiting` and canonical paths.
- Footnote reference jumps land on the bottom definition (using host ref positions and enclosing scroll viewports), push mark before jumping, and footnote definitions include a clickable `↩` back-link returning to the reference.
- Interactive container state (`:::tabs`, `:::details`, `:::accordion`) is isolated per block slot rather than keyed by source byte offset, so toggling one container repaints only that block and edits above no longer reset state.
- `card` semantic accents (`neutral`, `primary`, `success`, `warning`, `danger`, `important`) paint distinct title colors and 3px left accent rules across all themes via `etaf-card`, and `text-align` aligns card body prose as well as titles; differentiated all seven `box` surfaces (`none`, `page`, `raised`, `sunken`, `quote`, `table-header`, `table-stripe`) across `dark`, `light`, `sepia` and `auto` themes with valid 6-digit `#RRGGBB` colors.
- Fixed `columns` (`col :grow`, explicit track counts, `justify-content`, narrow `wrap=true`, width propagation into nested blocks), `table` (inline runs in cells, `align=left|center|right`, narrow-window clamping), `file-tree` (`lines=false` and `**focus** # comment`), `code-tabs` (eliminated double nested code frame and preserved page services), `code-tree` (prevented bottom-line clipping and mid-word splits), `image-card` (symmetric horizontal padding), `npm-to` (preserved spaces around `&&` and page services), `box` (narrowed inner child width), malformed `:::chart` inline failure degradation, `file://` media URI resolution, async `qrencode` via `etaf-process-run`, and inline `.tip` marks/badges mapped to success green.
- `etaf-md-follow-scroll` aligns the preview window start to the beginning of the target block's first row, defers `window-scroll-functions` sync out of `redisplay_internal` via a coalesced 0-second timer, and updates `window-point` plus `force-window-update`, so the left-padding gutter is never clipped and macOS/GUI ports always repaint the unselected preview window smoothly in real time during trackpad/wheel/keyboard scrolling.
- Raw HTML `<img>` blocks with declared CSS pixel `width`/`height` attributes render at their declared dimensions instead of inflating to intrinsic pixel size.
- Documents containing `:::` containers retain every heading in document order with unique anchor IDs and resolve footnotes across container boundaries; heading navigation lands accurately behind container or line-grid left borders.
- Added missing `SPDX-License-Identifier` header in `lisp/etaf-md-live.el` and fixed ELPA Commentary/docstring hygiene.

## [0.2.1] - 2026-11-22

### Added

- Full extension container vocabulary (`steps`, `timeline`, `stats`, `field`, `file-tree`, `chat`, `tabs`, `code-tabs`, `accordion`/`collapse`, `details`, `table`, `window`, `panel`, `tab-panel`, `form`, `log`, `statusbar`, `left`/`center`/`right`/`justify`), site component catalog (`home-box`, `image-card`, `link-card`, `npm-badge`, `qrcode`, `swiper`, `code-tree`, `npm-to`), and inline extensions (`==highlight==`, `::icon::`, `:kbd[...]`, `:badge[...]`).
- Fenced code options (`title=`, `:line-numbers[=N]`, `{1,4-7}`, `[!code ...]`) with copy action.
- Vector SVG diagram rendering with per-page palette/typography configuration, `etaf-display-metrics` text-scale reactivity, Windows compatibility for `scripts/mermaid-render.mjs`, and `qrencode` reporting in `etaf-md-doctor`.
- Following links to local Markdown documents (including `#fragment` anchors) and `mailto:` / `tel:` links.

### Changed

- Renamed the package from `etaf-md-preview` to `etaf-md` (`etaf-md.el`); all `etaf-md-preview-*` symbols dropped the `-preview-` segment (`etaf-md-open`, `etaf-md-create`, `etaf-md-theme`, `etaf-md-error`).
- `tabs` and `code-tabs` adopted `@tab Title` / `@tab {attrs}` marker children instead of `:::tab` blocks.
- Scaled front-matter title and body headings proportionally above body text.
- Unified examples into `examples/all-syntax.markdown`.

### Removed

- Removed in-preview text editing (`etaf-md-edit-document`, `etaf-md-insert`, `etaf-md-delete-char`, `etaf-md-editing-p`, `etaf-md-projection`, `etaf-md-after-repaint-functions`); Markdown is edited in its source buffer while the preview follows live.

### Fixed

- Package reloads cleanly on double-load during `package.el` activation.
- Cached per-page Mermaid configuration, SVG header sizing, dark/sepia/light categorical diagram palettes, CJK font stacks, and single-daemon Chromium lifecycle.
