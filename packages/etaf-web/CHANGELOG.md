# Changelog

## Unreleased

### Added

- Initial `etaf-web` application package compiling HTML articles and technical
  documentation into `etaf-md` intermediate language (`index.md` with YAML
  front matter, Markdown and `:::` containers) and opening them in `etaf-md`'s
  reading view.
- Public API: `etaf-web-to-markdown`, `etaf-web-open`, `etaf-web-error`, plus
  customization options `etaf-web-cache-directory`, `etaf-web-download-images`
  and `etaf-web-fetch-timeout` (default 30 seconds, with distinct HTTP status,
  timeout and connection-failure diagnostics).
- Built-in libxml sanitization, main-content extraction (`<article>`, `<main>`,
  bottom-up Readability prose scoring and structural wrapper tightening),
  layout-table unwrapping vs data-table preservation, interactive `<form>` and
  orphan-heading pruning, consecutive `<br><br>` paragraph normalization,
  bounded HTML `<img>` dimension preservation and tracking-pixel filtering,
  leading duplicate `<h1>` suppression (including site suffixes and prefixes), `YYYY-MM-DD` date normalization, lazy-load image
  attribute and widest `srcset` selection, overlong/title-duplicate image alt
  cleanup, `<figcaption>`-to-image-alt consolidation, makeinfo navigation /
  permalink (`¶`) / breadcrumb / tail noise pruning, footnote collection,
  `<details>` and docs callout container compilation, layout-aware mapping for
  card grids (`:::columns` + `:::card`, stripping decorative card-leading
  ordinals), docs tabs (`:::tabs`), steps (`:::steps`) and timelines
  (`:::timeline`), inline sibling spacing normalization, charset detection,
  on-disk page cache and bounded local image downloading (5 MB per image, 30
  images per page).
- Headless rendering for pages whose content a script builds: a document with
  no prose of its own whose HTML runs a script is rendered through a
  Chromium-based browser and compiled from that DOM, and a page with no
  renderer available opens a notice naming the situation and linking the
  original address.  Public options `etaf-web-render-command` (auto-detect,
  `off`, or an executable) and `etaf-web-render-timeout` (default 25 seconds).
- Reopening a cached page retries images its first pass could not save, so a
  failed download no longer leaves placeholders until the cache is cleared.
- Interactive Emacs-native browser shell: inherits the active Emacs theme's
  frame background with zero chrome background slabs or bottom footer bar;
  independent `*Web: <host>*` buffers per page; constant-height `1lh` top bar
  (`后退 前进 刷新/停止 │ https://host/path   状态`) with full scheme always
  visible, retained-Host pure-text loading progress (`阶段 38% · 2.4s`) on the
  same row without vertical jitter; per-buffer history stack with scroll
  restoration (`etaf-web-back`, `etaf-web-forward`), cache-bypassing reload
  (`etaf-web-reload`), in-flight cancellation (`etaf-web-stop`), inline plain
  address editing with URL history completion (`etaf-web-focus-address`),
  external browser handoff (`etaf-web-open-external`), clean close
  (`etaf-web-close`), state snapshot (`etaf-web-state`), narrow-viewport
  folding (`‹ › ⟳` `< 72ch`), and an Emacs-plain error recovery block.
- Non-blocking asynchronous loading pipeline: async HTTP fetching (`curl` via
  `etaf-process-run` with async `url-retrieve` fallback), async headless
  Chromium rendering (`--blink-settings=imagesEnabled=false
  --virtual-time-budget=3000` + shared disk cache), text-first display with
  concurrent background image backfill, and retained-Host progress updates
  without full-page rerenders.
- Universal HTML layout/extraction compiler improvements (compiler version 10):
  pruning inline hidden nodes (preserving `role="tabpanel"`), ARIA overlays
  (`tooltip`/`menu`/`dialog`/`alertdialog`), non-form short search bars and
  lone punctuation/pipe leaf blocks; gating `:::timeline` against counter bars;
  clustering 2–6 consecutive short metadata siblings into single ` · `-joined
  lines; formatting repeated homogeneous entry streams as headings + prose
  summary + metadata line + `---`; dropping empty-alt inline images, degrading
  badge image runs to `alt` text, and stripping PUA / variation selectors while
  preserving standard emoji.
