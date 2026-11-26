# Changelog

All notable changes to `etaf-export` are documented in this file.

## [0.2.1] - 2026-11-26

### Changed

- Updated README and manual to lead with public `M-x` commands and explicitly document `etaf-ext`'s configurable dispatcher prefix, `:prefix-hint` / `:subkey` defaults, and user key customization instead of listing fixed key chords.

## [0.2.0] - 2026-11-26

### Added

- Live zero-browser vector Export Preview workspace (`M-x etaf-export` / `C-c C-e x x`) with interactive pagination, fit-page/fit-width zoom, instant option controls (`a4`/`letter`/`single`, `current`/`light`, margin presets, page numbers), persisted preferences via `etaf-ext` storage and text-terminal fallback.
- Actionable export notifications with one-click file opening and live `etaf-ext` activity status during PDF compilation.

### Changed

- Streamlined the public interactive command surface to three core commands (`etaf-export`, `etaf-export-pdf`, `etaf-export-svg`) and three `etaf-ext` subcommands (`C-c C-e x x`, `x p`, `x s`), letting `etaf-export-pdf` and `etaf-export-svg` serve both direct interactive use and parameterized custom wrappers; removed `etaf-export-current-pdf` and `etaf-export-popup`.
- Rebuilt the compact manager popup on `etaf-segmented`, `etaf-divider`, `etaf-badge`, Theme tokens and reactive in-place updates.

### Fixed

- Resolved horizontal border drift on rows containing unsliced inline SVG icons (such as `etaf-ui-icon`) or mixed CJK/Latin/bold typography by measuring runs with Emacs's native `image-size` / intrinsic media header parsing and `etaf-string-pixel-width`, aligning inline icons vertically via `:ascent`, and forwarding face foreground color for `currentColor` SVGs.
- Eliminated `Stack overflow in regexp matcher` crashes during live preview rendering, window resizing and dragging on large documents by replacing the backtracking `<svg>...</svg>` matcher with an O(1)-stack linear substring extractor and bounding the preview descriptor cache.
- Expanded literal tabs before SVG emission, eliminated duplicate full-buffer snapshotting during interactive path prompts, extended SVG light-paper remapping to `#rgb`, `rgb(...)` and common CSS named colors, and preserved live theme synchronization across popup option changes.

## [0.1.0] - 2026-11-26

### Added

- Initial `etaf-ext` extension providing zero-browser vector PDF (`rsvg-convert -f pdf`) and standalone SVG export for any mounted ETAF page.
- Support for ISO A4 (`a4`), US Letter (`letter`) and continuous single-page (`single`) pagination with smart diagram and heading break protection.
- Support for live palette preservation (`current`) and perceptual dark-to-light white-paper remapping (`light`) without modifying the open buffer.
- Namespace-scoped inline `<svg>` embedding so Mermaid diagrams, MathJax equations and Ebox rounded borders stay true vectors with selectable text inside exported PDFs.
- Diagnostics via `etaf-export-doctor`.
