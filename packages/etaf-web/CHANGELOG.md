# Changelog

## Unreleased

### Added

- Initial `etaf-web` application package compiling HTML articles and technical
  documentation into `etaf-md` intermediate language (`index.md` with YAML
  front matter, Markdown and `:::` containers) and opening them in `etaf-md`'s
  reading view.
- Public API: `etaf-web-to-markdown`, `etaf-web-open`, `etaf-web-error`, plus
  customization options `etaf-web-cache-directory` and `etaf-web-download-images`.
- Built-in libxml sanitization, main-content extraction (`<article>`, `<main>`,
  and density fallback), leading duplicate `<h1>` suppression when matching
  front-matter `title`, `<figcaption>`-to-image-alt consolidation, footnote
  collection, `<details>` and docs callout container compilation, charset
  detection, on-disk page cache and bounded local image downloading (5 MB per
  image, 30 images per page).
