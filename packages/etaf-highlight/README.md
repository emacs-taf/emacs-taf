# etaf-highlight

[中文说明](README.zh-CN.md)

`etaf-highlight` is a standalone universal highlighter and persistent companion notes extension for any mounted ETAF application, built strictly on the public `etaf-ext` extension engine API.

## Capabilities

- Non-destructive character-span highlighting (`yellow`, `green`, `blue`, `pink`) via `etaf-ext-decorate`, automatically adapting contrast for light and dark Emacs themes.
- Optional companion note cards (`etaf-ext-companion`) rendered below highlighted paragraphs with inline `[删除]` actions.
- Automatic SQLite persistence keyed by page `:uri` (or buffer name) with text-anchor re-attachment across remounts and page navigation.
- Floating highlights overview popup (`C-c C-e h l`) with one-click jump (`etaf-ext-scroll-to`) and delete.
- Seamless multi-owner coexistence on the exact same paragraph with `etaf-translate`, `etaf-hints`, and `etaf-devtools`.

## Quick Start

```elisp
(require 'etaf-ext)
(require 'etaf-highlight)
(etaf-ext-mode 1)
```

Use `C-c C-e h h` to highlight the selection or current paragraph, `C-c C-e h n` to attach a note card, `C-c C-e h d` to clear highlights on the current paragraph, and `C-c C-e h l` to inspect all highlights on the page (or invoke any command via `M-x etaf-ext-command-palette` and customize direct keys in `M-x etaf-ext-manage`).

## Documentation

- Public API inventory: Commentary in [etaf-highlight.el](etaf-highlight.el).
- Usage manual: [docs/manual.md](docs/manual.md).
- Release history: [CHANGELOG.md](CHANGELOG.md).

## Checks

```sh
make check
```
