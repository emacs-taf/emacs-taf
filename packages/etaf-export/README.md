# etaf-export

[中文说明](README.zh-CN.md)

`etaf-export` is a standalone zero-browser vector PDF and SVG export extension for any mounted ETAF application, built strictly on the public `etaf-ext` extension engine API.

## Capabilities

- Captures any mounted ETAF buffer WYSIWYG — preserving headings, faces, backgrounds, box borders, underlines, pixel-aligned tables, inline icons, raster images and embedded Mermaid/MathJax SVGs — and compiles directly to vector PDF via `rsvg-convert -f pdf` with zero browser, Node.js or Python dependency.
- Includes a live zero-browser vector Export Preview workspace (`M-x etaf-export`) showing real paginated paper sheets alongside instant controls for page mode (`a4`, `letter`, `single`), color theme (`current`, `light`), margin presets and page numbers before exporting.
- Embeds Mermaid/MathJax SVGs, Ebox rounded borders and `etaf-ui-icon` glyphs as namespace-scoped nested `<svg>` elements with inherited foreground color and exact pixel widths so borders never drift and diagrams stay infinite-resolution vectors with selectable text.
- Supports exporting in the live page palette (`current`, default) or remapping dark pages onto clean white paper for printing (`light`) without mutating the live Emacs buffer.

## Prerequisites

- Emacs 29.1 or newer with `etaf`, `etaf-ui` and `etaf-ext`.
- `rsvg-convert` (`librsvg`, e.g. `brew install librsvg` on macOS or `apt install librsvg2-bin` on Debian/Ubuntu) for PDF generation; live vector preview and SVG export work with zero external tools. Run `(etaf-export-doctor)` to verify.

## Quick Start

```elisp
(require 'etaf-ext)
(require 'etaf-export)
(etaf-ext-mode 1)
```

Inside any mounted ETAF page (`etaf-md`, `etaf-org`, `etaf-manual`, `etaf-agenda`, etc.), invoke the public commands directly:

- `M-x etaf-export`: open the live vector Export Preview workspace.
- `M-x etaf-export-pdf`: export the current page to vector PDF.
- `M-x etaf-export-svg`: export the current page to standalone vector SVG file(s).

With `etaf-ext-mode` enabled, these commands are also reachable inside ETAF buffers via `M-x etaf-ext-command-palette` or the configurable two-step dispatcher `M-x etaf-ext-dispatch` (default `etaf-ext-key-prefix` is `C-c C-e`, with default extension hint `x` and subkeys `x`, `p`, `s`); customize or disable the prefix and bind personal direct shortcuts in `M-x etaf-ext-manage` or via `etaf-ext-set-key`.

## Documentation

- Public API inventory: Commentary in [etaf-export.el](etaf-export.el).
- Usage manual: [docs/manual.md](docs/manual.md).
- Release history: [CHANGELOG.md](CHANGELOG.md).

## Checks

```sh
make check
```
