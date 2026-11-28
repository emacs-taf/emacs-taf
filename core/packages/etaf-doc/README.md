# etaf-doc

[中文](README.zh-CN.md)

Shared document engine for [ETAF](https://github.com/emacs-taf/etaf): Markdown parsing, syntax highlighting, block view rendering, bounded disk caches, async QR/Mermaid/MathJax typesetting, unified node protocol and editorial widgets.

## Prerequisites

- Emacs 29.1 or newer
- `etaf`, `etaf-ui`, `ebox`, `ecss`

## Installation

Install from the ETAF package archive with `M-x etaf-install` (`etaf-doc`), or load from a source checkout of [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf):

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui" "etaf-doc"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(require 'etaf-doc)
```

## Documentation

- Public API inventory: [etaf-doc.el](etaf-doc.el) Commentary
- Architecture: [docs/architecture.md](docs/architecture.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)

## Checks

```sh
make -C core/packages/etaf-doc check
```
