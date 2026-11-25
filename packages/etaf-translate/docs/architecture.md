# etaf-translate Architecture

This document explains module responsibilities, dependency direction, data flow and invariants of `etaf-translate`. The authoritative public API list lives in [`../etaf-translate.el`](../etaf-translate.el), and user integration recipes live in [`manual.md`](manual.md).

## 1. Boundary and dependencies

`etaf-translate` is a native `etaf-ext` extension layered strictly above `etaf`, `etaf-ui`, `etaf-posframe` and `etaf-ext`:

```text
ecss -> ekp -> ebox -> etaf -> etaf-ui -> etaf-posframe -> etaf-ext -> etaf-translate
```

It never requires `ebox` or calls `ebox-*` functions directly. All Runtime lifecycle hooks (mount, commit, scroll/flush, theme change, unmount), compact mode-line badges, Pure Mode, circuit-breaker isolation, shared Host tree snapshots, geometry reads, link press forwarding, theme derivation, and atomic presentation flushes go through `etaf-ext`'s permission-checked public APIs (`etaf-ext-define`, `etaf-ext-tree`, `etaf-ext-geometries`, `etaf-ext-present`, `etaf-ext-clear-presentations`, `etaf-ext-press`, `etaf-ext-theme`, `etaf-ext-refresh-badge`, `etaf-ext-sync`), alongside ETAF's `:translate` semantic Host property (`t`, `yes`, `no`, `content`) and `etaf-scroll-by`.

Optional integration with downstream applications (`etaf-web`, `etaf-reader`, `maillist`, etc.) stays strictly decoupled: no application package imports or embeds `etaf-translate` controls, and `etaf-translate` probes public app symbols via `fboundp` or Host/buffer predicates without requiring any app.

## 2. Modules

Modules form a strict acyclic graph:

| Module | Responsibility |
| --- | --- |
| `etaf-translate-core.el` | Errors, customization options, script/language detection, spacing hygiene and SHA-256 hashing |
| `etaf-translate-store.el` | Native Emacs 29+ SQLite WAL L2 cache (TTL, LRU pruning, stats, graceful fallback) and `.eld` persistence for sparse panel preferences, user site rules and glossary |
| `etaf-translate-cache.el` | Bounded L1 memory cache wired to the default SQLite L2 store or a custom `:persistence` contract (`:get`, `:put`, `:remove`, `:clear`, `:stats`, `:prune`) |
| `etaf-translate-rules.el` | Four-tier policy resolver (overrides > rules > persisted panel `:prefs` > defaults), `:domain` wildcard matching, site-resolver hooks and persisted user state |
| `etaf-translate-extract.el` | Read-only Host tree walker, paragraph grouping, page title extraction, `<N>` / `⟦cN⟧` inline codec with LaTeX math atomic protection and exclusion heuristics |
| `etaf-translate-engine.el` | Async engine registry, named profiles, context/prompt-style builder, shared SSE transport and built-in `openai`, `anthropic`, `deepl`, `google`, `command` and `function` engines |
| `etaf-translate-render.el` | Theme-derived palette derivation and ETAF presentation builders for 3 editorial bilingual styles (`left-bar`, `muted`, `tinted`), `replace` with hover-original `:help-echo`, loading and retry states |
| `etaf-translate-scheduler.el` | Live viewport-first priority queue, batching, concurrency control, streaming `:on-unit-done`, solo auto-retry, fallback engine cascade and generation-guarded cancellation |
| `etaf-translate-session.el` | Native `etaf-ext-define` registration, per-context session state, conditional auto-translate activation, debounced incremental rescans, major page-switch cancellation, single-paragraph toggle (`etaf-translate-paragraph`) and virtualized provider protocol |
| `etaf-translate-ui.el` | Slim 6-row window-anchored control panel (`etaf-translate-panel`, repeat-call toggle, auto-dismiss on buffer switch) and pure-translation dynamic-height scrollable quick popup (`etaf-translate-at-point`) via `etaf-posframe` native `:theme 'auto` with reactive side-window fallback |
| `etaf-translate-integrations.el` | Built-in `etaf-web` URL/domain resolver, low-priority rules for ETAF ecosystem apps (`etaf-web`, `etaf-md`, `etaf-org`, `etaf-manual`, `etaf-rss`, `etaf-telega`, `maillist`, `etaf-reader`) and dedicated logical-paragraph providers for `etaf-reader` and `maillist` |

## 3. Data flow

1. **Extract**: `etaf-runtime-host-tree` returns the application's authoritative Host tree (excluding transient surfaces and attached companions). `etaf-translate-extract-units` groups inline-only `box` Hosts into paragraph units, serializes styled/interactive runs with `<N>...</N>`, protects inline code, footnotes and LaTeX math expressions (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`, guarding currency amounts) as atomic `⟦cM⟧` placeholders, and skips excluded subtrees, code blocks, technical lists and text already in the target language. When a virtualized provider matches (such as the built-in `maillist` or `etaf-reader` providers), it extracts logical paragraphs from pre-wrapped line Hosts instead.
2. **Lookup & schedule**: Each unit's cache key combines engine/profile, source/target language, prompt style, glossary hash and markup hash. L1 and L2 SQLite hits paint immediately in one atomic `etaf-runtime-set-host-presentations` call; misses enter the live viewport-first scheduler, which queries `etaf-runtime-host-geometries` to prioritize visible and prefetch units while deferring far off-screen units without ghost placeholders. Both Emacs window scrolling and `:overflow 'scroll` flushes (`etaf-runtime-after-flush-functions`) re-prioritize dynamically. Streaming engines (`openai`, `anthropic`) emit each completed segment via `:on-unit-done`; transient failures auto-retry solo and can cascade to `etaf-translate-fallback-engine`.
3. **Render**: `etaf-translate-render.el` converts decoded runs into ETAF Views without shrinking `:font-size` and with colors derived dynamically from the active appearance via `etaf-ui-color-mix` / `etaf-ui-color-legible`.
   - `bilingual-stacked` supports three distinct editorial styles (`left-bar`, `muted`, `tinted`), using `companion-inside` on `box` Hosts and `companion-after` on standalone `text` Hosts. Headings render as quiet subtitles without vertical bars, and `maillist` quote paragraphs keep a single continuous quote rail.
   - `replace` uses `override` and attaches the original plain text as `:help-echo` so hovering reveals the source paragraph.
   - Fixed single-line clipped chrome (`:height '(lh 1)` + `:overflow 'hidden`) degrades to `replace` so translations never overflow or clip.
4. **Incremental survival & page switches**: Application commits fire `etaf-runtime-after-commit-functions` (presentation-only flushes do not). Sessions diff extracted units by `(host-id . source-hash)` and translate only new or changed units. When a buffer switches to a largely different page (e.g. clicking another `etaf-rss` article or navigating in `etaf-web`), stale in-flight requests are canceled before scheduling the new content. Unmounting cancels all jobs, removes Mode-line indicators and cleans up associated panels.

## 4. Invariants

1. **Authoritative source untouched**: Application refs, Component state and Host source text are never mutated; disabling restores the exact original display in one flush.
2. **No hook feedback loops**: Presentation flushes never trigger `etaf-runtime-after-commit-functions`.
3. **Mode-line and theme respect**: The Mode-line indicator is attached via a buffer-local `minor-mode-alist` entry without clearing `mode-line-format`, overriding faces, or adding interactive commands; all UI surfaces and companion styles derive colors from the active theme and never shrink `:font-size`.
4. **Graceful degradation**: Missing SQLite falls back to L1 memory; missing `posframe` or non-graphical frames fall back to a native ETAF side window; malformed engine tags never drop text; failed units isolate a retry affordance without blocking sibling paragraphs.
5. **Zero-cost idle**: When no session is active and no registered rule sets `:auto-translate t`, Runtime mounts and commits short-circuit in O(1) without allocating policy plists or scanning trees.
