# etaf-hints

[中文说明](README.zh-CN.md)

`etaf-hints` is a standalone Vimium-style quick-jump extension for any mounted ETAF application, built strictly on the public `etaf-ext` extension engine API.

## Capabilities

- Pressing `M-f` overlays prefix-free letter badges over every visible clickable or focusable Host in the active ETAF page.
- Typing a badge code filters candidates live and dispatches semantic `etaf-ext-press` (or `etaf-ext-focus` for focus-only targets), clearing the overlay immediately afterward.
- Adapts badge contrast automatically to light and dark Emacs themes and exposes a compact `跳N` status indicator while active.

## Quick Start

```elisp
(require 'etaf-ext)
(require 'etaf-hints)
(etaf-ext-mode 1)
```

Press `M-f` (or `M-x etaf-hints-start`) inside any mounted ETAF buffer to display jump badges, type a label to activate, or press `Esc` / `C-g` to cancel.

## Documentation

- Public API inventory: Commentary in [etaf-hints.el](etaf-hints.el).
- Usage manual: [docs/manual.md](docs/manual.md).
- Release history: [CHANGELOG.md](CHANGELOG.md).

## Checks

```sh
make check
```
