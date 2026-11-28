# etaf-ext Manual

This manual covers configuring `etaf-ext`, authoring independent ETAF extensions, managing permissions and policies, and handling errors and recovery. For exact symbol signatures, see the Public API Commentary in [../etaf-ext.el](../etaf-ext.el).

## Enabling and Managing Extensions

Enable `etaf-ext-mode` and load whichever standalone extension packages you want to use:

```elisp
(require 'etaf-ext)
(require 'etaf-hints)
(require 'etaf-highlight)
(etaf-ext-mode 1)
```

Open `M-x etaf-ext-manage` from any mounted ETAF buffer to manage installed extensions interactively. The manager targets the originating ETAF page so you can toggle per-page Pure Mode (`P`), enable or disable individual extensions (`SPC`), attach or detach an extension on the target page, open an extension's floating popup, set per-app `allow` or `deny` overrides, and inspect or reset circuit-breaker error logs (`R`).

To temporarily hide all extensions on the current ETAF page without changing global enablement, invoke `M-x etaf-ext-pure-mode-toggle` or middle-click the compact mode-line indicator (`拼`). Toggling Pure Mode off re-runs matching and restores all active extensions cleanly.

## Organizing Extensions

- Keep `etaf-ext` strictly for the engine and manager UI.
- Package reusable extensions as independent packages (`core/packages/etaf-<name>` in the monorepo, `packages/etaf-<name>` in `emacs-taf/etaf`) depending on `etaf-ext` (for example `etaf-hints` and `etaf-highlight`).
- Write small personal tweaks directly in your Emacs init file via `etaf-ext-define`.

## Authoring an Extension

Register an extension with `etaf-ext-define` (or `etaf-ext-register`). Every extension declares its matching scope, activation mode, permissions, optional commands, and lifecycle callbacks:

```elisp
(etaf-ext-define my-code-badge
  :name "Code Block Tagger"
  :version "0.1.0"
  :description "Decorate paragraphs containing TODO markers."
  :prefix-hint "b"
  :activation 'on-match
  :matches '(:apps t :kinds (document))
  :priority 55
  :debounce 0.1
  :permissions '(read-tree decorate companion keys notify)
  :commands '((scan :subkey "s" :label "Scan TODO markers"
                    :fn my-code-badge--scan))
  :on-attach #'my-code-badge--scan
  :on-commit #'my-code-badge--scan)
```

### Manifest Keys

- `:name`, `:version`, `:description`: Human-readable strings displayed in `etaf-ext-manage`.
- `:icon`, `:tone`: Optional monogram glyph string (such as `"T"`) and semantic tone (`accent`, `info`, `success`, `warning`, `danger`, or `neutral`) used by `etaf-ext-manage` to style the extension's emblem without coupling the engine to concrete packages.
- `:prefix-hint`: Optional single-key string (such as `"b"`) suggested for this extension inside the unified two-step extension dispatcher (`etaf-ext-dispatch` under `etaf-ext-key-prefix`, default `C-c C-e`). Collisions between extensions are resolved automatically by priority.
- `:matches`: Keyword plist controlling automatic eligibility: `:apps` (`t` or list of app symbols), `:kinds` (list of symbols such as `document`, `reader`, `tool`), `:uri-regexp`, `:buffer-regexp`, and `:predicate` `(lambda (runtime meta buffer) ...)`.
- `:activation`: `on-match` (default, attaches automatically on mount or metadata change), `on-command` (installs declared command key bindings with zero runtime cost until invoked), or a predicate function `(lambda (runtime) ...)` that auto-attaches on mount, metadata change, or commit whenever the condition holds (for example, `etaf-translate`'s remembered per-site auto-translate rules).
- `:permissions`: Required list of symbols from `etaf-ext-known-permissions`. Calling any context primitive whose capability is missing signals `etaf-ext-permission-error`.
- `:priority`: Integer ordering priority (default `50`; lower numbers run and render first).
- `:debounce`: Non-negative seconds used to coalesce `:on-commit` and `:on-scroll` callbacks on interactive frames.
- `:commands`: List of `(CMD-ID :label LABEL :fn FN [:subkey STR] [:suggested-key KEY])`. Extensions never hardcode user-reserved `C-c <letter>` prefixes: `:subkey` declares a single-letter mnemonic under `etaf-ext-key-prefix`, and optional `:suggested-key` (intended only for high-frequency triggers like `M-f`) is guarded by the conflict firewall and `etaf-ext-keybinding-policy`.
- `:popup`: Optional `(ctx)` function returning an ETAF View shown via `etaf-ext-open-popup`.
- `:badge`: Optional `(ctx)` function returning `(:text STR :variant SYM)` for the compact mode-line indicator.
- `:on-attach`, `:on-commit`, `:on-scroll`, `:on-meta`, `:on-focus`, `:on-theme`, `:on-detach`: Optional lifecycle callbacks receiving `ctx` (plus `meta` for `:on-meta` and `prev-id next-id` for `:on-focus`).

## Command Dispatch, Conflict Firewall, and Custom Keybindings

All extension commands are reachable without key collisions through three unified entry points:

- `etaf-ext-dispatch` (`etaf-ext-key-prefix`, default `C-c C-e`): opens a two-step key dispatcher for the active ETAF page. Press an extension's prefix letter (auto-executing single-command extensions or opening subcommands), `/` for `etaf-ext-command-palette`, `M` for `etaf-ext-manage-popup`, or `P` for Pure Mode. Set `etaf-ext-key-prefix` to `nil` to disable installing any prefix inside ETAF buffers.
- `etaf-ext-command-palette`: fuzzy-searches all enabled commands for the active ETAF page using `completing-read`.
- `etaf-ext-manage` / `etaf-ext-manage-popup`: shows each command's resolved binding, flags skipped conflicts with their exact reason, and provides in-UI `改键` / `解绑` / `恢复` actions persisted to SQLite.

Direct `:suggested-key` bindings are filtered by `etaf-ext-keybinding-policy` (`safe`, `prefix-only`, or `manual`) and `etaf-ext-check-key-conflict`. Under the default `safe` policy, any suggested key that collides with ETAF framework-reserved keys, the active page's application keys, `global-map` (including global prefix keymaps such as `C-c e`), active minor modes, single printing characters, or a higher-priority extension is skipped rather than silently shadowing user bindings. Users retain full ownership via `(etaf-ext-set-key EXT CMD KEY)` (accepting a `kbd` string, `:unbound`, or `nil`) and `(etaf-ext-reset-key EXT CMD)`.

## Context Primitives, Theme Helper, and Permissions

- `etaf-ext-theme`: derives WCAG-legible `:ext-*` and `:ui-*` palette tokens from the active Emacs frame so extension overlays, cards, and popups follow light and dark themes automatically.
- `etaf-ext-context`, `etaf-ext-ctx-trigger`, `etaf-ext-refresh-badge`, `etaf-ext-sync`: inspect an active context without triggering lazy attachment, distinguish `auto` / `manual` / `command` / `popup` triggers, refresh async mode-line badges, and reconcile conditional auto-activation rules.
- `read-tree`: `etaf-ext-tree`, `etaf-ext-geometries`, `etaf-ext-host-at-point`, `etaf-ext-host-text-at-point`.
- `inspect`: `etaf-ext-inspect-host`, `etaf-ext-commit-summary`.
- `decorate` / `companion` / `override`: `etaf-ext-decorate` (additive spans/faces), `etaf-ext-companion` (priority-ordered companion Views), `etaf-ext-override` (priority-stacked Host overrides), and `etaf-ext-present` (atomic mixed batch updates enforcing per-entry permissions in one flush).
- `overlay`: `etaf-ext-set-overlay` manages one named `:layer 'root` overlay per extension without triggering application commit hooks.
- `interact`: `etaf-ext-press`, `etaf-ext-focus`, `etaf-ext-scroll-to`.
- `storage`: `etaf-ext-storage-get`, `etaf-ext-storage-set`, `etaf-ext-storage-delete`, `etaf-ext-storage-keys` inside an isolated SQLite WAL namespace per extension ID.
- `popup`: `etaf-ext-show-popup` displays a floating child frame via `etaf-posframe` (or a themed ETAF side window on non-graphic displays); `etaf-ext-hide-popup` closes it.
- `notify`: `etaf-ext-notify` routes notifications through `etaf-ext-notify-function` or `message`.

## Failures, Circuit Breaker, and Recovery

All lifecycle callbacks and commands run inside error isolation. Errors are appended to the extension's bounded log (`etaf-ext-errors`). When consecutive failures reach `etaf-ext-circuit-breaker-threshold` (default `3`), the engine suspends the extension (`etaf-ext-suspended-p`), detaches it from all Runtimes, and wipes its presentations, overlays, popups, and key layers. Inspect the recorded trace in `M-x etaf-ext-manage` or via `etaf-ext-errors`, fix the issue, and recover with `(etaf-ext-reset 'my-ext)` or `R` in the manager.

When `etaf-ext-storage-file` is set to `nil` or native SQLite is unavailable, `etaf-ext` transparently falls back to in-memory storage for the current Emacs session without failing extension startup.
