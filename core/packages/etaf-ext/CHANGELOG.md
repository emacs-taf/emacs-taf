# Changelog

All notable changes to `etaf-ext` are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Fixed

- Removed redundant `;;;###autoload` cookies from `lisp/*.el` submodules so flattened builds (`straight.el` / Doom) route `etaf-ext-mode` and interactive commands through the `etaf-ext` root entry instead of bypassing `etaf-ext-keys` and `etaf-ext-ui`.
- Hardened the autoloaded `lisp/` `load-path` guard to verify that `etaf-ext.el(c)` sits beside `lisp/`, preventing `package-quickstart` from matching unrelated user `lisp/` directories.

## [0.1.1] - 2026-11-26

### Changed

- Updated README ecosystem extension descriptions to avoid presenting configurable `etaf-ext` dispatcher chords as fixed keybindings and included `etaf-export`'s live vector preview capability.

## [0.1.0] - 2026-11-26

### Added

- Pure universal extension engine (`etaf-ext-mode`, `etaf-ext-define`, `etaf-ext-register`, `etaf-ext-unregister`, `etaf-ext-enable`, `etaf-ext-disable`, `etaf-ext-set-app-policy`, `etaf-ext-pure-mode-toggle`, `etaf-ext-reset`, `etaf-ext-theme`, `etaf-ext-context`, `etaf-ext-ctx-trigger`, `etaf-ext-present`, `etaf-ext-refresh-badge`, `etaf-ext-sync`).
- Permission-checked context API covering read-only Host tree access, shared commit-revision tree cache, geometry/text-offset queries, box-model/ECSS inspection, additive text decorations, coexisting companion views, priority overrides, atomic mixed presentations (`etaf-ext-present`), named root overlays, semantic actions, isolated SQLite WAL storage, floating popups, and notifications.
- Conditional predicate `:activation` support, shared buffer-local scroll observation, automatic error isolation, error ring buffer, circuit breaker suspension after consecutive callback errors, and compact theme-preserving mode-line status badge.
- Responsive interactive Extension Manager (`etaf-ext-manage` centered 124ch card workspace and `etaf-ext-manage-popup` centered floating `etaf-posframe`) with lifted three-tier theme derivation, keyword search, monogram extension cards, live ON/OFF switches, metadata grid, hairline-separated command tables, live conflict badges and interactive key rebinding (`改键`/`解绑`/`恢复`) across ultrawide, wide, compact, narrow, and short viewports.
- Conflict-free command-first keybinding architecture: unified two-step prefix dispatcher (`etaf-ext-dispatch` under `etaf-ext-key-prefix`, default `C-c C-e`), fuzzy command palette (`etaf-ext-command-palette`), configurable policy (`etaf-ext-keybinding-policy`: `safe`, `prefix-only`, `manual`), automatic conflict firewall against framework, application, minor-mode, global-map and sibling extension bindings (`etaf-ext-check-key-conflict`, `etaf-ext-command-bindings`), and SQLite-persisted user overrides (`etaf-ext-set-key`, `etaf-ext-reset-key`, `etaf-ext-key-override`).
