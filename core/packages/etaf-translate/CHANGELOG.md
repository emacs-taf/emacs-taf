# Changelog

All notable changes to `etaf-translate` are documented in this file.

## Unreleased

### Added

- Native `etaf-ext` extension architecture: registers directly via `etaf-ext-define`, delegating Runtime lifecycle hooks, scroll observation, theme derivation (`etaf-ext-theme`), unified mode-line badges (`拼[译✓·...]`), shared Host tree caching, atomic mixed presentations (`etaf-ext-present`), Pure Mode and circuit-breaker isolation to `etaf-ext`.
- Universal zero-invasion immersive page translation for any mounted ETAF View through `etaf-ext` (`companion-inside`, `companion-after`, `override`), keeping application authoritative state untouched and restoring the exact original view on disable.
- Five orthogonal interactive commands:
  - `etaf-translate-toggle`: toggle immersive page translation on or off with echo-area status feedback.
  - `etaf-translate-panel`: toggle the slim 6-row top-right floating control panel (`etaf-posframe` with live `:theme 'auto` following and automatic dismissal on buffer switch; falls back to an ETAF side window when posframe is unavailable).
  - `etaf-translate-at-point`: pure-translation quick popup usable in any Emacs buffer (translates active region with hard-wrap joining or the word at point without repeating source text, auto-sizes up to 60% of frame height, and scrolls cleanly with mouse wheel or `j`/`k`/`SPC`/`DEL`).
  - `etaf-translate-paragraph`: toggle inline translation for the paragraph at point in ETAF buffers, or translate the paragraph at point in the floating popup in ordinary Emacs buffers.
  - `etaf-translate-mode-cycle`: cycle `bilingual-stacked` -> `replace` -> off with interactive mode feedback.
- Three distinct editorial bilingual styles (`left-bar`, `muted`, `tinted`) derived dynamically from the active Emacs theme, and in-place replacement with hover-original `:help-echo`.
- Inline run preservation (`<N>...</N>` for clickable links and emphasis) and atomic `⟦cN⟧` protection for inline code, footnotes and LaTeX math expressions (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`) without misclassifying currency amounts.
- Live viewport-first streaming scheduler supporting both Emacs windows and `:overflow 'scroll` containers, SSE incremental delivery (`openai`, `anthropic`), `deepl`, `google`, `command` and `function` engines, named profiles, prompt-style presets and automatic fallback failover.
- Persistent Emacs 29+ native SQLite WAL L2 cache (TTL, LRU pruning and stats), sparse panel preference persistence (`:mode`, `:style`, `:source-lang`, `:target-lang`, `:engine`) in `etaf-translate-state-file` without touching `init.el` or `custom-file`, automatic Runtime lifecycle hooks for remembered per-site auto/never rules and persisted glossaries without requiring a global minor mode, clickable buffer-local Mode-line indicator, and built-in logical-paragraph providers for `maillist` and `etaf-reader`.
