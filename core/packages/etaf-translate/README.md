# etaf-translate

[中文](README.zh-CN.md)

Universal immersive page translation for any mounted [ETAF](https://github.com/emacs-taf/etaf) View, plus a lightweight pure-translation quick popup for any Emacs buffer.

## Capabilities

- **Native `etaf-ext` extension**: registers directly with [etaf-ext](https://github.com/emacs-taf/etaf-ext) for shared Host tree caching, atomic multi-owner presentations (`companion-inside`, `companion-after`, `override`), unified mode-line badges, Pure Mode, circuit-breaker isolation, and management inside `M-x etaf-ext-manage`.
- **Five focused commands**: `etaf-translate-toggle`, `etaf-translate-panel`, `etaf-translate-at-point`, `etaf-translate-paragraph` and `etaf-translate-mode-cycle` — zero redundant minor modes or overlapping commands.
- **Two modes and three editorial styles**: bilingual stacked (`left-bar`, `muted`, `tinted`) and in-place replacement with hover-original `:help-echo` — switching instantly from cache.
- **Minimal floating UI**: slim 6-row top-right control panel (`etaf-translate-panel` with live `:theme 'auto` following, automatic sparse persistence to `etaf-translate-state-file`, and auto-dismiss on buffer switch), pure-translation quick popup (`etaf-translate-at-point` translating active region or word at point without repeating original text, auto-sizing up to 60% frame height with scrolling), and a clickable buffer-local Mode-line indicator (`译[54/155]` / `译✓` / `译!N`) that preserves the active theme's mode-line.
- **Structure- and math-aware extraction**: groups inline runs into paragraphs, preserves clickable links and emphasis via `<N>...</N>`, protects inline code, footnotes and LaTeX math (`$...$`, `$$...$$`, `\(...\)`, `\[...\]` without misclassifying currency) via atomic `⟦cN⟧` placeholders, skips code blocks and UI chrome, and honors `:translate 'no`.
- **Viewport-first streaming & persistent L2 cache**: tracks live Host visibility across Emacs windows and `:overflow 'scroll` containers, streams SSE replies paragraph-by-paragraph, dynamically re-prioritizes on scroll, retries and cascades through a configurable fallback engine, and persists translations in an Emacs 29+ native SQLite WAL L2 cache alongside remembered site rules and glossaries.
- **Multi-engine suite & built-in providers**: built-in `openai` (OpenAI / DeepSeek / Ollama SSE), `anthropic` (Claude Messages SSE), `deepl` (Free/Pro batch), `google` (zero-key HTTP), `command` and `function` engines; named profiles; context title and prompt-style presets (`technical`, `academic`, `literary`, `concise`); and built-in logical-paragraph providers for `maillist` and `etaf-reader` plus domain/app rules for `etaf-web`, `etaf-md`, `etaf-org`, `etaf-manual`, `etaf-rss` and `etaf-telega`.

## Prerequisites

- Emacs 29.1 or newer (built-in SQLite enables persistent L2 caching automatically; degrades cleanly to L1 memory otherwise)
- `etaf` (>= 0.3.6), `etaf-ui` (>= 0.3.4), `etaf-posframe` (>= 0.3.0) and `etaf-ext` (>= 0.1.0)
- `curl` on `exec-path` for the HTTP engines (`openai`, `anthropic`, `deepl`, `google`)

## Minimal Example

```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-translate)

(setq etaf-translate-target-lang "zh-CN"
      etaf-translate-default-engine 'openai
      etaf-translate-openai-endpoint "https://api.deepseek.com/v1/chat/completions"
      etaf-translate-openai-model "deepseek-chat"
      etaf-translate-openai-api-key (lambda () (getenv "DEEPSEEK_API_KEY")))

;; Inside any mounted ETAF buffer (etaf-web, etaf-md, maillist, etaf-reader, ...):
(etaf-translate-toggle)
;; Toggle the slim top-right control panel:
(etaf-translate-panel)
;; Quick-translate the active region or word at point in any Emacs buffer:
(etaf-translate-at-point)
```

## Documentation

- Public API inventory: [etaf-translate.el](etaf-translate.el)
- Usage and extension guide: [docs/manual.md](docs/manual.md)
- Maintainer architecture: [docs/architecture.md](docs/architecture.md)

## Validation

```sh
make -C packages/etaf-translate check
```
