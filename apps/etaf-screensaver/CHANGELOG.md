# Changelog

## Unreleased

### Changed

- **Breaking:** streamlined the package around pure-Elisp built-in scenes and composable Emacs Lisp customization, removing the external recording pipeline (`tte` / `frames` reels, ANSI parser, SVG glyph scaler, importer, `.esc`/`.esr` file loader and offline Node/Python baking scripts), the sandboxed `.esc` expression DSL, style packs (`etaf-screensaver-packs`), `etaf-screensaver-scene-options`, `etaf-screensaver-seed` and the `band`/`mosaic` layouts.
- **Breaking:** renamed `etaf-screensaver-start` to `etaf-screensaver-open` (matching the ETAF application convention; `C-u` interactively picks a scene) and simplified playback configuration to `etaf-screensaver-playlist`, `etaf-screensaver-order`, `etaf-screensaver-duration`, `etaf-screensaver-frame-rate`, `etaf-screensaver-background`, `etaf-screensaver-frame`, `etaf-screensaver-transition-duration` and `etaf-screensaver-idle-delay` with one uniform `item > global > scene` precedence rule.
- **Breaking:** simplified `etaf-screensaver-define-scene` so `:create`, `:step` and `:resize` are optional, `:params` takes a plain `(KEY . DEFAULT)` alist instead of UI metadata descriptors, and `:render` receives a pre-cleared scratch `:canvas` in `ctx` that it may return directly.
- Reimplemented `matrix`, `snow`, `plasma`, `donut`, `equalizer`, `sand` and `poems` in pure Emacs Lisp on top of the public canvas and scene builders, eliminating dead shade tables, duplicate hex color helpers and per-frame validation overhead.

### Added

- Interactive `etaf-screensaver-preview` command with `completing-read` title and summary annotations.
- High-level scene authoring builders: `etaf-screensaver-define-text-scene` (`typewriter`, `fade`, `scroll` and `static` styles with static lists or live generators), `etaf-screensaver-define-field-scene` and `etaf-screensaver-define-particle-scene`.
- Public canvas and color toolkit for custom scenes: `etaf-screensaver-canvas-create`, `etaf-screensaver-canvas-clear`, `etaf-screensaver-canvas-put` (with CJK wide-character overlap safety), `etaf-screensaver-canvas-text`, `etaf-screensaver-canvas-fill`, `etaf-screensaver-canvas-box`, `etaf-screensaver-canvas-rows`, `etaf-screensaver-color-mix` and `etaf-screensaver-ramp`.
- Built-in `clock` scene rendering a 5-row Unicode block-element digital clock and date with gentle anti-burn-in drift.

## 0.1.0

Initial release.

- A scene registry with inert scene specs interpreted by the DSL and `etaf-screensaver-define-scene` for code scenes.
- Initial workspace UI, retained canvas publication, nine bundled scenes and acceptance tests.
