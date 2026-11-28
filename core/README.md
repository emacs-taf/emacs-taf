# ETAF — Emacs Text Application Framework (Core)

[中文说明](README.zh-CN.md) · [Documentation](https://etaf.top) · [Monorepo](https://github.com/emacs-taf/emacs-taf) · [Package Archive](https://etaf.top/packages/)

> **Read-only core projection.** This repository aggregates all 15 ETAF core framework packages, universal extensions, the official installer and the bilingual reference manual from [`core/`](https://github.com/emacs-taf/emacs-taf/tree/main/core) in the **[Emacs TAF Monorepo](https://github.com/emacs-taf/emacs-taf)**.
>
> Please submit all pull requests to **[emacs-taf/emacs-taf](https://github.com/emacs-taf/emacs-taf/pulls)**.

## Install (Recommended)

Install any ETAF framework package, extension, application or game from the official `package.el` archive (Emacs 29.1+):

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

Or add the subdirectories under `packages/` of this checkout directly to `load-path`:

```elisp
(dolist (dir '("ecss" "ekp" "ebox" "etaf" "etaf-ui" "etaf-ext"))
  (add-to-list 'load-path (expand-file-name (concat "packages/" dir) "/path/to/etaf")))
(require 'etaf)
```

## Packages in this Repository

### Core Framework

| Package | Role |
| --- | --- |
| [`ecss`](packages/ecss) | CSS cascade engine: selectors, specificity, custom properties and computed styles |
| [`ekp`](packages/ekp) | Knuth–Plass paragraph line breaking, with optional prebuilt C module |
| [`ebox`](packages/ebox) | Box/Flex/Grid layout, rendering and incremental buffer publication |
| [`etaf`](packages/etaf) | Declarative components, reactive state, hosts and application lifecycle |
| [`etaf-ui`](packages/etaf-ui) | Reusable UI components: buttons, forms, panels, tables, navigation and window shells |
| [`etaf-posframe`](packages/etaf-posframe) | Floating child-frame panels for any ETAF View |
| [`etaf-ext`](packages/etaf-ext) | Universal extension engine, lifecycle manager and host hooks |
| [`etaf-db`](packages/etaf-db) | Data storage backends for ETAF applications (SQLite) |
| [`etaf-gamekit`](packages/etaf-gamekit) | Game definitions, independent instances and Godot / OpenSpiel bridges |
| [`etaf-install`](packages/etaf-install) | Official `package.el` installer, capability doctor, native module manager and package manager |

### Universal Extensions

| Extension | Description |
| --- | --- |
| [`etaf-hints`](packages/etaf-hints) | Vimium-style quick keyboard jump hints for interactive targets |
| [`etaf-highlight`](packages/etaf-highlight) | Persistent text highlighting and anchored notes across ETAF views |
| [`etaf-translate`](packages/etaf-translate) | Immersive inline and side-by-side translation for ETAF views |
| [`etaf-export`](packages/etaf-export) | Zero-browser vector SVG and PDF export for rendered ETAF pages |

### Documentation & Reference Manual

| Package | Description |
| --- | --- |
| [`etaf-manual`](packages/etaf-manual) | Bilingual ETAF Reference Manual (`M-x etaf-manual-open`) and `https://etaf.top` site source |

## Contributing

All development, tests and CI run in the **[Emacs TAF Monorepo](https://github.com/emacs-taf/emacs-taf)**. See the organization [CONTRIBUTING.md](https://github.com/emacs-taf/.github/blob/main/CONTRIBUTING.md) before opening pull requests.

## License

GNU General Public License v3.0 or later ([LICENSE](LICENSE)).
