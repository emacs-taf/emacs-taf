# etaf-ext

[中文说明](README.zh-CN.md)

`etaf-ext` is a pure, universal Chrome/VS Code-style extension engine and manager for any mounted ETAF View. It contains only the engine runtime, permission gating, isolated storage, circuit-breaker isolation, Pure Mode, and the responsive Extension Manager (`M-x etaf-ext-manage`); concrete extensions live in their own independent packages (such as `etaf-translate`, `etaf-hints`, and `etaf-highlight`) or in a user's personal Emacs configuration.

## Capabilities

- Declarative manifests (`etaf-ext-define` / `etaf-ext-register`) with app, kind, URI, buffer, and predicate matching plus persisted per-app `allow` and `deny` policies.
- Strict capability permission gating (`read-tree`, `decorate`, `companion`, `override`, `overlay`, `interact`, `inspect`, `storage`, `keys`, `popup`, `notify`) raising `etaf-ext-permission-error` on undeclared calls.
- Multi-owner coexistence over ETAF's Host presentation buckets and named root overlays: text decorations, stacked companions, overlays, and key layers compose by priority and tear down cleanly without residue.
- Per-extension isolated SQLite WAL key-value storage with automatic in-memory fallback when SQLite is unavailable or `etaf-ext-storage-file` is nil.
- Shared commit-revision Host tree snapshot caching, per-extension debouncing, theme-change dispatch, public theme token derivation (`etaf-ext-theme`), error logging, automatic circuit-breaker suspension, and per-page Pure Mode (`etaf-ext-pure-mode-toggle`).
- Conflict-free command-first keybinding system: extensions declare `:prefix-hint` and `:subkey` (plus optional `:suggested-key`), unified under `etaf-ext-key-prefix` (`C-c C-e` / `etaf-ext-dispatch`) and fuzzy `etaf-ext-command-palette`, protected by a global/minor-mode/app conflict firewall and SQLite-persisted user overrides (`etaf-ext-set-key`).
- Interactive responsive Extension Manager (`M-x etaf-ext-manage`) preserving the user's mode-line, surfacing keybinding conflicts live, supporting in-UI rebinding, and deriving all colors from the active Emacs theme.

## Ecosystem Extensions

- [etaf-translate](https://github.com/emacs-taf/etaf-translate): universal zero-invasion immersive page translation and quick popup built natively on `etaf-ext` (`C-c C-e t`).
- [etaf-hints](https://github.com/emacs-taf/etaf-hints): standalone Vimium-style quick-jump badges (`M-f` / `C-c C-e f`).
- [etaf-highlight](https://github.com/emacs-taf/etaf-highlight): standalone universal span highlighter and persisted companion note cards (`C-c C-e h`).
- [etaf-export](https://github.com/emacs-taf/etaf-export): zero-browser vector PDF and SVG exporter for any mounted ETAF page (`C-c C-e x`).

## Prerequisites

- Emacs 29.1 or newer (native SQLite recommended for persistent storage).
- `ecss`, `ekp`, `ebox`, `etaf` (>= 0.3.6), `etaf-ui` (>= 0.3.4), and `etaf-posframe` (>= 0.3.0) on `load-path`.

## Quick Start

Enable the engine and load whichever independent extension packages you want:

```elisp
(require 'etaf-ext)
(require 'etaf-hints)
(require 'etaf-highlight)
(etaf-ext-mode 1)
```

Open `M-x etaf-ext-manage` (full buffer) or `M-x etaf-ext-manage-popup` (centered floating `etaf-posframe`) from any mounted ETAF page to manage installed extensions, filter by keyword (`/`), inspect permissions and error logs, set per-app policies, or toggle Pure Mode (`P`).

## Documentation

- Public API inventory and signatures: Commentary in [etaf-ext.el](etaf-ext.el).
- User and extension authoring workflows: [docs/manual.md](docs/manual.md).
- Maintainer architecture and invariants: [docs/architecture.md](docs/architecture.md).
- Release history: [CHANGELOG.md](CHANGELOG.md).

## Checks

```sh
make check
```
