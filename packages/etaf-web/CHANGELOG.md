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
