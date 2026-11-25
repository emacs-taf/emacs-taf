# Changelog

All notable changes to `etaf-export` are documented in this file.

## [Unreleased]

### Added

- Initial `etaf-ext` extension providing zero-browser vector PDF (`rsvg-convert -f pdf`) and standalone SVG export for any mounted ETAF page.
- Support for ISO A4 (`a4`), US Letter (`letter`) and continuous single-page (`single`) pagination with smart diagram and heading break protection.
- Support for live palette preservation (`current`) and perceptual dark-to-light white-paper remapping (`light`) without modifying the open buffer.
- Namespace-scoped inline `<svg>` embedding so Mermaid diagrams, MathJax equations and Ebox rounded borders stay true vectors with selectable text inside exported PDFs.
- Interactive floating export options panel (`C-c C-e x x` / `M-x etaf-export-popup`) and `etaf-export-doctor` diagnostics.
- Readable typography and wide-diagram scaling: derives canonical page width from prose columns rather than overflowing multi-row diagrams, matches logical font size cleanly on macOS/Linux, and fits wide Mermaid/SVG figures inside the page width with `preserveAspectRatio="xMidYMid meet"`.
