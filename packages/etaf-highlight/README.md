# etaf-highlight

[中文说明](README.zh-CN.md)

`etaf-highlight` is a standalone universal highlighter and persistent companion notes extension for any mounted ETAF application, built strictly on the public `etaf-ext` extension engine API.

## Capabilities

- Non-destructive character-span highlighting (`yellow`, `green`, `blue`, `pink`) via `etaf-ext-decorate`, automatically adapting contrast for light and dark Emacs themes.
- Optional companion note cards (`etaf-ext-companion`) rendered below highlighted paragraphs with inline `[删除]` actions.
- Automatic SQLite persistence keyed by page `:uri` (or buffer name) with text-anchor re-attachment across remounts and page navigation.
- Floating highlights overview popup (`etaf-highlight-list`) with one-click jump (`etaf-ext-scroll-to`) and delete.
- Seamless multi-owner coexistence on the exact same paragraph with `etaf-translate`, `etaf-hints`, and `etaf-devtools`.

## Quick Start

```elisp
(require 'etaf-ext)
(require 'etaf-highlight)
(etaf-ext-mode 1)
```

Inside any mounted ETAF page, invoke the public commands directly:

- `M-x etaf-highlight-add`: highlight the active region or current paragraph (with optional color and companion note).
- `M-x etaf-highlight-remove`: clear highlights on the current paragraph.
- `M-x etaf-highlight-list`: open the floating highlights overview popup for the current page.

With `etaf-ext-mode` enabled, all highlight actions (`highlight`, `note`, `remove`, `list`) are also reachable inside ETAF buffers via `M-x etaf-ext-command-palette` or the configurable two-step dispatcher `M-x etaf-ext-dispatch` (default `etaf-ext-key-prefix` is `C-c C-e`, with default extension hint `h` and subkeys `h`, `n`, `d`, `l`); customize or disable the prefix and bind personal direct shortcuts in `M-x etaf-ext-manage` or via `etaf-ext-set-key`.

## Documentation

- Public API inventory: Commentary in [etaf-highlight.el](etaf-highlight.el).
- Usage manual: [docs/manual.md](docs/manual.md).
- Release history: [CHANGELOG.md](CHANGELOG.md).

## Checks

```sh
make check
```
