# etaf-export

[中文说明](README.zh-CN.md)

`etaf-export` is a standalone zero-browser vector PDF and SVG export extension for any mounted ETAF application, built strictly on the public `etaf-ext` extension engine API.

## Capabilities

- Captures any mounted ETAF buffer WYSIWYG — preserving headings, faces, backgrounds, box borders, underlines, pixel-aligned tables, raster images and embedded Mermaid/MathJax SVGs — and compiles directly to vector PDF via `rsvg-convert -f pdf` with zero browser, Node.js or Python dependency.
- Supports three page modes: ISO A4 paginated (`a4`, default), US Letter paginated (`letter`) and continuous single-page PDF (`single`), with smart page breaks that avoid splitting diagrams or leaving orphaned headings.
- Embeds Mermaid/MathJax SVGs and Ebox rounded borders as namespace-scoped nested `<svg>` elements so diagrams stay infinite-resolution vectors and text stays selectable inside the exported PDF.
- Supports exporting in the live page palette (`current`, default) or remapping dark pages onto clean white paper for printing (`light`) without mutating the live Emacs buffer.

## Prerequisites

- Emacs 29.1 or newer with `etaf`, `etaf-ui` and `etaf-ext`.
- `rsvg-convert` (`librsvg`, e.g. `brew install librsvg` on macOS or `apt install librsvg2-bin` on Debian/Ubuntu) for PDF generation; SVG export works with zero external tools. Run `(etaf-export-doctor)` to verify.

## Quick Start

```elisp
(require 'etaf-ext)
(require 'etaf-export)
(etaf-ext-mode 1)
```

Inside any mounted ETAF page (`etaf-md`, `etaf-org`, `etaf-manual`, `etaf-agenda`, etc.):

- `C-c C-e x p` (`M-x etaf-export-current-pdf`): export current page as A4 paginated PDF following the current theme.
- `C-c C-e x l`: export as a continuous single-page PDF.
- `C-c C-e x L`: force light print-ready palette and export as A4 PDF.
- `C-c C-e x s`: export as standalone vector SVG file(s).
- `C-c C-e x x` (`M-x etaf-export-popup`): open the floating export options panel.

## Documentation

- Public API inventory: Commentary in [etaf-export.el](etaf-export.el).
- Usage manual: [docs/manual.md](docs/manual.md).
- Release history: [CHANGELOG.md](CHANGELOG.md).

## Checks

```sh
make check
```
