# etaf-translate Manual

`etaf-translate` provides zero-invasion immersive page translation for any mounted ETAF buffer and a lightweight pure-translation quick popup for any Emacs buffer. See [`../etaf-translate.el`](../etaf-translate.el) for the full authoritative public API inventory.

## Quick start

Configure an engine and invoke any of the 5 interactive commands — no global minor mode is required:

```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-translate)

;; Any OpenAI-compatible server (OpenAI, DeepSeek, Ollama, vLLM, ...):
(setq etaf-translate-default-engine 'openai
      etaf-translate-openai-endpoint "https://api.deepseek.com/v1/chat/completions"
      etaf-translate-openai-model "deepseek-chat"
      etaf-translate-openai-api-key (lambda () (getenv "DEEPSEEK_API_KEY"))
      etaf-translate-target-lang "zh-CN")
```

The 5 interactive commands:

- `M-x etaf-translate-toggle`: turn immersive page translation on or off for the current ETAF buffer (turning it off restores the original view cleanly).
- `M-x etaf-translate-panel`: toggle the slim 6-row top-right floating control panel (mode, style, languages, engine, site auto/never memory; changes made in the panel persist automatically to `etaf-translate-state-file` as sparse overrides without touching `init.el` or `custom-file`, and the panel closes automatically when switching buffers or apps).
- `M-x etaf-translate-at-point`: quick-translate in any Emacs buffer. Translates the active region (joining hard line wraps cleanly) or the word at point, showing only the translated result in a dynamic-height floating popup (auto-fits up to 60% of frame height and scrolls with wheel or `j`/`k`/`SPC`/`DEL` for long selections).
- `M-x etaf-translate-paragraph`: toggle inline bilingual translation for the single paragraph under point in an ETAF buffer, or translate the paragraph at point in the floating pure-translation popup in any ordinary Emacs buffer.
- `M-x etaf-translate-mode-cycle`: cycle `bilingual-stacked` -> `replace` -> off without opening the panel.

## Multi-engine backends, named profiles and fallback

Built-in engines cover `openai` (SSE), `anthropic` (Claude Messages SSE), `deepl` (Free/Pro batch), `google` (zero-key HTTP), `command` and `function`. Register named profiles to switch presets cleanly without rewriting global custom variables, and optionally configure `etaf-translate-fallback-engine` for automatic failover:

```elisp
;; Named profiles on top of built-in engines:
(etaf-translate-register-profile
 'deepseek-tech
 :engine 'openai
 :label "DeepSeek Tech"
 :endpoint "https://api.deepseek.com/v1/chat/completions"
 :model "deepseek-chat"
 :api-key (lambda () (getenv "DEEPSEEK_API_KEY"))
 :prompt-style 'technical)

(etaf-translate-register-profile
 'claude-literary
 :engine 'anthropic
 :label "Claude Literary"
 :model "claude-sonnet-4-20250514"
 :api-key (lambda () (getenv "ANTHROPIC_API_KEY"))
 :prompt-style 'literary)

(setq etaf-translate-default-engine 'deepseek-tech
      etaf-translate-fallback-engine 'google
      etaf-translate-prompt-style 'technical)
```

Supported bilingual visual styles are `left-bar`, `muted` and `tinted`. Supported prompt styles are `technical`, `academic`, `literary`, `concise`, or any custom instruction string. When a page heading is detected, it is passed automatically to LLM engines as read-only `:context` for terminology consistency.

## Persistent L2 SQLite cache, site rules and glossaries

On Emacs 29+ built with SQLite, `etaf-translate` persists translations in `etaf-translate-cache-file` (`user-emacs-directory/etaf-translate-cache.sqlite`) with WAL journaling, TTL (`etaf-translate-cache-ttl-days`) and bounded LRU eviction (`etaf-translate-cache-max-disk-entries`). Inspect or maintain it programmatically with `etaf-translate-cache-stats`, `etaf-translate-cache-prune` and `etaf-translate-cache-clear`.

Loading `etaf-translate` installs lightweight Runtime lifecycle hooks automatically (O(1) idle cost when no `:auto-translate t` rule exists). Panel changes (mode, style, languages, engine), remembered site rules and persisted glossary terms are saved automatically to `etaf-translate-state-file` (`user-emacs-directory/etaf-translate-state.eld`). Policy resolution follows four tiers from highest to lowest: explicit per-call/transient overrides (`etaf-translate-mode-cycle`, `etaf-translate-set-*`) > matching site/declarative rules > panel-persisted sparse `:prefs` > `init.el` / `defcustom` defaults. Set `etaf-translate-state-file` to `nil` to disable disk state persistence completely:

```elisp
;; Persist per-domain auto-translate or never-translate policies:
(etaf-translate-remember-site "docs.python.org" 'auto)
(etaf-translate-remember-site "emacs-china.org" 'never)

;; Persist glossary terms to `etaf-translate-state-file':
(etaf-translate-add-glossary-term "ETAF" "ETAF" t)
(etaf-translate-add-glossary-term "Runtime" "Runtime" t)

;; Declarative rule with domain glob and custom style:
(etaf-translate-register-rule
 'arxiv-papers
 :priority 20
 :domain "*.arxiv.org"
 :mode 'bilingual-stacked
 :style 'muted
 :prompt-style 'academic
 :auto-translate t)
```

## LaTeX math protection

Inline (`$E = mc^2$`, `\(x + y\)`) and display (`$$\int_0^1 f(x)\,dx$$`, `\[...\]`) LaTeX math expressions are automatically protected as atomic `⟦cN⟧` placeholders and restored verbatim (while ordinary currency amounts such as `$100 and $200` remain translatable prose).

## Ecosystem integration and custom providers

`etaf-translate` ships with decoupled built-in rules for `etaf-web`, `etaf-md`, `etaf-org`, `etaf-manual`, `etaf-rss`, `etaf-telega`, `maillist` and `etaf-reader` without modifying any application UI:

- In `etaf-web`, domain-level rules resolve the active URL via public `etaf-web-state`.
- In `maillist`, a built-in logical-paragraph provider merges 72-column wrapped plain-text prose and quote lines into complete paragraphs, strips repeated `>` prefixes, skips sidebars/diffs/signatures, and renders restrained bilingual pairs.
- In `etaf-reader`, a built-in virtualized-page provider reconstructs logical paragraphs across fixed 1-line clipped rows (`reader-line-*`) so ebooks are translated whole instead of line-by-line.
- Applications and reusable components may attach `:translate 'no` to any ETAF Host to exclude its subtree from extraction.

## Registering a custom async engine or provider

An engine's `:translate` callback takes `(REQUEST ON-DONE ON-ERROR)` and returns an optional zero-argument cancel function. `REQUEST` is a plist containing `:units`, `:source-lang`, `:target-lang`, `:glossary`, `:context`, `:prompt-style`, and an optional streaming callback `:on-unit-done` (`(INDEX TRANSLATED-TEXT)`):

```elisp
(etaf-translate-register-engine
 'my-local-mt
 :label "Local MT"
 :supports-batch t
 :max-chars 2000
 :translate
 (lambda (request on-done on-error)
   (let ((units (plist-get request :units))
         (target (plist-get request :target-lang)))
     (condition-case err
         (funcall on-done
                  (mapcar (lambda (s) (format "[%s] %s" target s)) units))
       (error (funcall on-error (error-message-string err))))
     nil)))
```

Virtualized applications that pre-wrap paragraphs into fixed-height rows can register a custom provider via `etaf-translate-register-provider` with `:match`, `:extract`, `:apply` and `:clear` callbacks.
