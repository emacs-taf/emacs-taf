# ETAF Web

ETAF Web compiles HTML web pages into the text-level intermediate language accepted by [etaf-md](https://github.com/emacs-taf/etaf-md) (YAML front matter, Markdown and `:::` containers) and opens them inside Emacs using `etaf-md`'s reading view.

## Capabilities

- **Pure HTML-to-IR compiler** (`etaf-web-to-markdown`): uses Emacs's built-in `libxml-parse-html-region` with zero external dependencies.  Sanitizes unsafe tags (`script`, `style`, `noscript`, `iframe`, `object`, `embed`, `template`, `svg`), strips `on*` event attributes and `javascript:`/`vbscript:`/`data:text/html` links, extracts the primary article content (`<article>`, `<main>`, or text-density fallback) while pruning navigation, footers, sidebars, comments, share bars and ads.
- **Rich Markdown and container emission**: maps headings, paragraphs, hard breaks, inline styles (`em`, `strong`, `del`, `code`, `mark`, `kbd`, `sub`, `sup`), absolute links and `#anchor` fragments, images (`<img>`, `<picture>`, `<figure>` + `<figcaption>`), fenced code blocks with language detection (defaulting to `text`), GFM pipe tables (with `colspan`/`rowspan` expansion and multi-block cell compaction), nested and task lists, definition lists, blockquotes, rules, GFM footnotes, `<details>` (`:::details`), docs callouts (`:::note`, `:::tip`, `:::warning`, `:::caution`, `:::important`, `:::danger`), responsive multi-column card grids (`:::columns` + `:::card`), documentation tabs (`:::tabs`), ordered steps (`:::steps`) and timelines (`:::timeline`).
- **Local page cache and bounded assets** (`etaf-web-open`): reads local HTML files or fetches HTTP(S) pages with `Content-Type` / `<meta charset>` decoding, writes `index.md`, `source.html`, `meta.json` and cached images under `etaf-web-cache-directory` (default `~/.cache/etaf-web/`), reuses cached pages on repeat opens, and enforces hard image limits (5 MB per image, at most 30 images per page; toggleable via `etaf-web-download-images`).

## Prerequisites

- Emacs 29.1 or newer built with libxml support (`(libxml-available-p)`).
- Core framework packages (`ecss`, `ebox`, `etaf`, `etaf-ui` from [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf)) and `etaf-md` on `load-path`.

## Installation

Add the framework package directories, `etaf-md` and `etaf-web` to `load-path`, then require `etaf-web`:

```elisp
(dolist (pkg '("ecss" "ebox" "etaf-ui" "etaf"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/etaf-md")
(add-to-list 'load-path "/path/to/etaf-web")
(require 'etaf-web)
```

## Usage

Open a URL or local HTML file in an `etaf-md` reading buffer:

```elisp
(etaf-web-open "https://example.com/article")
(etaf-web-open "/path/to/article.html" t)
```

Or compile HTML purely without disk or network I/O:

```elisp
(etaf-web-to-markdown "<article><h1>Hello</h1><p>World</p></article>"
                      :base-url "https://example.com/posts/1/")
```

## Documentation and Checks

- Supported API inventory: Commentary of [etaf-web.el](etaf-web.el).
- Workflows, caching and compilation details: [docs/manual.md](docs/manual.md).
- Run all package checks from the workspace root:

```sh
make -C apps/etaf-web check
```
