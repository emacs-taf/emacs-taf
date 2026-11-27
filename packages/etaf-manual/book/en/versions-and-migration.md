# Versions and Migration

The manual documents the version combination in the table below. Except for EKP 1.0.1 and Ebox 3.1.0 these are pre-1.0 release lines, so an interface may change between releases; each package's `CHANGELOG.md` is the authoritative list of user-visible changes. This appendix gives the requirements and the changes that need edits in existing code or files.

<!-- index: version; requirements; migration -->

## Versions

| Package | Version | Documented with |
| --- | --- | --- |
| `ecss` | 0.1.4 | Emacs 28.1 |
| `ekp` | 1.0.6 | Emacs 29.1 |
| `ebox` | 3.1.12 | Emacs 29.1, `ecss 0.1.4` |
| `etaf` | 0.3.16 | Emacs 29.1, `ebox 3.1.12`, `ecss 0.1.4` |
| `etaf-ui` | 0.3.11 | Emacs 29.1, `etaf 0.3.16`, `ebox 3.1.12` |
| `etaf-db` | 0.1.3 | Emacs 29.1, `etaf 0.3.16` |
| `etaf-posframe` | 0.3.4 | Emacs 29.1, `etaf 0.3.16`, `etaf-ui 0.3.11`, Posframe 0.9.0 |
| `etaf-manual` | 0.1.23 | Emacs 29.1, `etaf 0.3.16`, `etaf-ui 0.3.11` |

The third column is the combination this edition documents.  Each package's `Package-Requires` header states the minimum it installs with, which can be lower.

## Requirements

Emacs 29.1 or newer runs every package; ECSS alone also supports Emacs 28.1. The optional pieces are described in [Installation, Loading and Building](installation-and-loading.md): EKP's C module needs a C compiler, the macOS colour-emoji helper is compiled with `swiftc`, video playback needs the ffmpeg programs (`etaf-video-ffmpeg-program`, `etaf-video-ffplay-program` and `etaf-video-ffprobe-program`), ETAF DB needs an Emacs build with SQLite support, and EKP hyphenation reads the dictionaries shipped under `dictionaries/`.

## Migration notes

- **Package entry at the repository root.** Load a source checkout by adding its repository root to `load-path` and requiring the package entry, as in `(require 'etaf)`. The feature modules below `lisp/` are internal and are not a supported import path; packages installed from an archive keep the same layout.
- **ECSS rule files.** A static `.ecss` file now contains an unquoted rule list. Remove the outer quote from existing files.
- **ECSS Scope parent.** The optional parent of `ecss-scope-create` is passed as `:parent PARENT`, not positionally.
- **Runtime generations.** The earlier generation APIs were removed. Compare `etaf-runtime-revision`, or the value `etaf-runtime-flush` returns, to observe that a publication reached the buffer.
- **Ebox engine.** The earlier engine's canonical inputs, source builders and explicit update APIs were removed. Keep node references: `ebox-node-insert`, `ebox-node-remove`, `ebox-node-move` and `ebox-node-replace-children` change children; `ebox-node-set-text` and `ebox-node-set-image` change content; `ebox-node-set-props`, `ebox-node-put`, `ebox-node-set-states` and `ebox-node-restyle` change properties; `ebox-with-batch` groups work. Build or copy a retained root and mount it instead of supplying a full input replacement.
- **Data reconciliation.** The success state is `reconciled`, not `projected`; consumers that compare `etaf-data-reconciliation-state` symbols should update.
- **Accent controls.** `etaf-taskbar` and `etaf-workspace-bar` no longer accept `:accent-color`; provide a Theme with `:ui-accent` and `:ui-accent-soft-bg` instead.
- **EKP dictionaries.** The bundled inventory is pinned and verified per file. The Sanskrit dictionary was removed because the pinned upstream data has no authoritative license statement; check that hyphenation still selects a dictionary when a document's language is no longer covered.
