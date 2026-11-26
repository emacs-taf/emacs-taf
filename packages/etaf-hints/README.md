# etaf-hints

[中文说明](README.zh-CN.md)

`etaf-hints` is a standalone Vimium-style quick-jump extension for any mounted ETAF application, built strictly on the public `etaf-ext` extension engine API.

## Capabilities

- Invoking `etaf-hints-start` overlays prefix-free letter badges over every visible clickable or focusable Host in the active ETAF page.
- Typing a badge code filters candidates live and dispatches semantic `etaf-ext-press` (or `etaf-ext-focus` for focus-only targets), clearing the overlay immediately afterward.
- Adapts badge contrast automatically to light and dark Emacs themes and exposes a compact `跳N` status indicator while active.

## Quick Start

```elisp
(require 'etaf-ext)
(require 'etaf-hints)
(etaf-ext-mode 1)
```

Inside any mounted ETAF buffer, run `M-x etaf-hints-start` to display jump badges, type a label to activate, or press `Esc` / `C-g` to cancel. With `etaf-ext-mode` enabled, `etaf-hints` is also reachable via `M-x etaf-ext-command-palette`, via the configurable per-page dispatcher `M-x etaf-ext-dispatch` (default `etaf-ext-key-prefix` is `C-c C-e`, default extension hint `f`), and under the default `safe` `etaf-ext-keybinding-policy` registers a conflict-checked suggested direct key `M-f`; customize or unbind any key in `M-x etaf-ext-manage` or via `etaf-ext-set-key`.

## Documentation

- Public API inventory: Commentary in [etaf-hints.el](etaf-hints.el).
- Usage manual: [docs/manual.md](docs/manual.md).
- Release history: [CHANGELOG.md](CHANGELOG.md).

## Checks

```sh
make check
```
