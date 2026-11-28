# etaf-devtools Architecture

This document explains module responsibilities, dependency direction, data flow and invariants of `etaf-devtools`. The authoritative public API inventory lives in [etaf-devtools.el](../etaf-devtools.el), and user workflows live in [manual.md](manual.md).

## 1. Boundary and dependencies

`etaf-devtools` is a framework tooling package layered strictly above `etaf`, `etaf-ui` and `etaf-posframe`:

```text
ecss -> ebox -> etaf -> etaf-ui / etaf-posframe -> etaf-devtools
```

It never requires `ebox` or `ecss` directly and never calls private `--` symbols. All Runtime inspection goes through ETAF's public introspection facade (`etaf-runtime-list`, `etaf-runtime-inspect-tree`, `etaf-runtime-host-id-at`, `etaf-runtime-inspect-host`, `etaf-runtime-inspect-component`, `etaf-runtime-set-component-binding`, `etaf-runtime-inspect-focus`, `etaf-runtime-commit-summary`), lifecycle hooks (`etaf-runtime-mount-functions`, `etaf-runtime-after-commit-functions`, `etaf-runtime-after-flush-functions`, `etaf-runtime-unmount-functions`) and optional `etaf-performance-*` recording APIs.

## 2. Modules

Modules form a strict acyclic graph:

| Module | Responsibility |
| --- | --- |
| `etaf-devtools-core.el` | Errors, user options, theme-derived dynamic palette (matching active Emacs frame faces), cyclic-safe value formatting, safe Lisp input parser and source-jump helper |
| `etaf-devtools-overlay.el` | Zero-distortion target-buffer read-only overlays from exact `:row-spans`, optional floating `etaf-posframe` dimension badge and single-timer Highlight Updates flash manager |
| `etaf-devtools-target.el` | Self-buffer exclusion registry, live Runtime discovery, Highlight Updates buffer set and lazy global Runtime hook installation |
| `etaf-devtools-model.el` | Reactive session state, debounced snapshot refresh, tree ancestor expansion, controlled live `etaf-ref` editing, Flush history ring, performance recorder bridge and QA viewport refit commands |
| `etaf-devtools-picker.el` | Transient-keymap Element Picker supporting mouse click/position and keyboard/TTY movement with `[` / `]` ancestor stepping |
| `etaf-devtools-view.el` | Responsive 3-tier (`wide` / `medium` / `narrow`) ETAF view shell and all 6 panels (Tree, Styles/Box Model, State, Perf, Keys/Focus, Runtime) |
| `etaf-devtools-ui.el` | Docked side-window (`right` / `bottom`) and floating `etaf-posframe` hosting, session lifecycle, interactive commands and `etaf-devtools-doctor` |

## 3. Invariants

1. **Zero-cost idle**: when no session is open and no buffer enables Highlight Updates, zero hooks, timers or observers remain installed.
2. **Zero measurement and layout distortion**: selection highlights and Highlight Updates use read-only Emacs overlays over exact per-row buffer spans without mutating target text or invoking Ebox flushes.
3. **Self-inspection immunity**: every buffer owned by `etaf-devtools` (docked panel, posframe panel and picker badge) is registered before mount and filtered from target discovery and Runtime hooks.
4. **Cyclic-safe formatting**: all value previews bind `print-circle`, `print-length` and `print-level` so cyclic closures or keymaps never hang Emacs.
5. **Theme and mode-line discipline**: all colors derive dynamically from the active Emacs theme, `:font-size` is never set, and docked buffers preserve the native Emacs mode-line (`:mode-line t`).
