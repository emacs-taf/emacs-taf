# etaf-ext Architecture

## Purpose and Layering

`etaf-ext` sits above `etaf`, `etaf-ui`, and `etaf-posframe` and consumes only their declared public APIs. It never calls `ebox-` primitives or internal `etaf--` / `etaf-ui--` symbols, and it bundles zero concrete business plugins. Independent extension packages (`etaf-translate`, `etaf-hints`, `etaf-highlight`, third-party extensions, and user scripts) depend unidirectionally on `etaf-ext`, while standalone developer tools such as `etaf-devtools` remain completely independent.

```
ecss -> ekp -> ebox -> etaf -> etaf-ui -> etaf-posframe -> etaf-ext
                                                             ^
               +--------------------+------------------+-----+------------+
               |                    |                  |                  |
        etaf-translate          etaf-hints       etaf-highlight      user scripts
```

## Module Responsibilities

- `etaf-ext.el`: Root feature entry, authoritative Public API Commentary, autoload declarations, and module loading.
- `lisp/etaf-ext-core.el`: Error conditions (`etaf-ext-error`, `etaf-ext-permission-error`), customization options, manifest validation (`etaf-ext-register`, `etaf-ext-define`), `on-match` / `on-command` / conditional activation, priority-sorted registry, and Runtime matching (`etaf-ext-match-p`).
- `lisp/etaf-ext-store.el`: Native SQLite WAL storage with in-memory hash fallback, namespaced KV primitives, and persisted global enablement, per-app `allow`/`deny` policies, and user keybinding overrides.
- `lisp/etaf-ext-runtime.el`: Per-Runtime attachment lifecycle, strict permission-checked Context API (`etaf-ext-present`, `etaf-ext-ctx-trigger`, `etaf-ext-refresh-badge`, `etaf-ext-sync`), public theme token helper (`etaf-ext-theme`) and context lookup (`etaf-ext-context`), shared commit-revision Host tree cache, shared scroll observers, per-extension debouncing, circuit-breaker error isolation, pure mode, theme-change dispatch, and compact mode-line indicator.
- `lisp/etaf-ext-keys.el`: Command-first two-pass keybinding resolver, conflict firewall (`etaf-ext-check-key-conflict`, `etaf-ext-command-bindings`), persisted user override API (`etaf-ext-set-key`, `etaf-ext-reset-key`), collision-free prefix allocator, unified two-step dispatcher (`etaf-ext-dispatch`), and fuzzy command palette (`etaf-ext-command-palette`).
- `lisp/etaf-ext-ui.el`: Responsive Chrome-style Extension Manager (`etaf-ext-manage`) built with `etaf-app-open` (`:mode-line t`), live conflict visibility and interactive key rebinding, reactive theme derivation, and 4-tier hover discipline.

## Data Flow and Key Invariants

1. **Single authoritative Host tree**: Applications remain the sole owners of DOM/Host truth. Extensions read detached snapshots via `etaf-ext-tree` (cached per Runtime and `etaf-runtime-revision`, invalidated on `etaf-runtime-after-commit-functions`) and mutate only their own presentation owner slot (`etaf-ext-decorate`, `etaf-ext-companion`, `etaf-ext-override`, `etaf-ext-present`) or named root overlay (`etaf-ext-set-overlay`).
2. **No feedback loops**: Setting presentations or overlays does not fire `etaf-runtime-after-commit-functions`, preventing infinite commit cascades when multiple extensions update simultaneously.
3. **Coexistence and clean teardown**: Each extension uses its extension ID symbol as owner key across Host presentation buckets, named root overlays, and Runtime extension key layers. Detaching an extension, disabling it, tripping its circuit breaker, or toggling Pure Mode clears every presentation, overlay, popup, timer, and key layer owned by that ID without touching any other extension or application state.
4. **Conflict-free key resolution**: `etaf-ext-keys` reconciles all extension key layers together per Runtime in two passes (user explicit overrides before suggested keys). Extension layers register via `etaf-runtime-set-key-layer`, strictly below Host `:keys` and framework defaults (`Tab`, `ESC`, `?`, `M-g`), and suggested keys colliding with `global-map`, active minor modes, app keys, printing keys, or higher-priority extensions are skipped and surfaced in `etaf-ext-command-bindings` and `etaf-ext-manage`.
5. **Fault isolation**: Every extension lifecycle callback and command runs inside `etaf-ext--safe-call`. Consecutive failures increment a per-extension streak; reaching `etaf-ext-circuit-breaker-threshold` automatically suspends the extension, detaches it from every live Runtime, and records the error trace for inspection in `etaf-ext-manage`.
6. **Weak Runtime tables**: Attachment maps, tree caches, scroll observers, and pure-mode flags use weak-key hash tables keyed by `etaf-runtime`, paired with explicit cleanup on `etaf-runtime-unmount-functions`, preventing buffer or Runtime memory leaks.
