# etaf-devtools

[中文](README.zh-CN.md)

Interactive runtime inspector and developer tools for any mounted [ETAF](https://github.com/emacs-taf/etaf) application, built strictly over ETAF's public introspection interfaces.

## Capabilities

- **Unified Component & Host Tree**: switch between Components-only and full Host trees, filter by component name, `#id`, `.class`, `:ref` or text, jump directly to `(etaf-define-component ...)` source (`g`), scroll any Host into view (`v`), or trigger enabled `:on-press` handlers (`a`).
- **Pure-Text Box Model & On-Demand ECSS Provenance**: inspect resolved `margin`, `border`, `padding` and `content` dimensions, layout mode, scroll offset, clipping visibility, matched ECSS cascade rules with strikethrough overrides, color swatches and WCAG AA contrast ratios — computed on demand with zero hot-path overhead.
- **Reactive State & Live `etaf-ref` Editing**: inspect Component props, named `:bindings` (`ref`, `computed`, `resource`, `data-controller`), dependency chains, Context and local refs, and safely edit writable `etaf-ref` values in place without restarting the target application.
- **Zero-Distortion Picker & Highlight Updates**: highlight selected Hosts via exact per-line read-only overlays that never bleed across multi-column Flex/Grid layouts or mutate target buffers, pick elements by mouse or keyboard (`[`/`]` step ancestors), and flash incremental vs full redraw ranges live.
- **Flush & Performance Profiling**: live Flush/Commit timeline with a Braille sparkline and on-demand `etaf-performance` operation stage breakdowns with GC counts and 50 ms budget indicators.
- **Focus, Regions & Key Scope Diagnostics + QA Viewport Presets**: inspect live Tab stop order, click to test `etaf-focus`, audit `:region` declarations and `:keys` scopes, and simulate wide/ordinary/compact/short viewports via `etaf-runtime-refit`.
- **Docked or Floating, Theme-Following**: defaults to a right-docked Emacs side window preserving your native mode-line, with one-key cycling (`d`) across right side window, bottom side window and draggable `etaf-posframe` floating panel, adapting cleanly across wide, medium and narrow viewports.

## Prerequisites

- Emacs 29.1 or newer
- `etaf` (>= 0.3.6), `etaf-ui` (>= 0.3.4) and `etaf-posframe` (>= 0.3.0)

## Minimal Example

```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-devtools)

;; Open docked on the right side of the current ETAF application:
(etaf-devtools)
;; Pick any element in the target ETAF buffer (mouse or keyboard):
(etaf-devtools-inspect)
;; Toggle live Highlight Updates flash overlays:
(etaf-devtools-highlight-updates)
;; Cycle right side window -> bottom side window -> floating posframe:
(etaf-devtools-toggle-dock)
;; Close and release every overlay, timer and hook:
(etaf-devtools-close)
```

## Documentation

- Public API inventory: [etaf-devtools.el](etaf-devtools.el)
- Usage guide: [docs/manual.md](docs/manual.md)
- Maintainer architecture: [docs/architecture.md](docs/architecture.md)

## Validation

```sh
make -C core/packages/etaf-devtools check
```
