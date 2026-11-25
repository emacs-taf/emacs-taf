# ETAF Org User Manual

`etaf-org` turns Org-mode files into interactive reading views inside Emacs while preserving pure Org text on disk.

## Opening and live preview

- `M-x etaf-org-open` is the primary reading entry. Called from an Org buffer without a prefix argument, it opens full-width in the current window with zero prompt and syncs point to the corresponding source line; pass `C-u` or invoke from a non-Org buffer to pick a file. Pressing `q` (`etaf-org-close`) switches back to the origin buffer in place without deleting your window. Re-invoking it on the same canonical file reuses the existing buffer, and files sharing a basename disambiguate automatically.
- `M-x etaf-org-preview` toggles a live side-by-side preview in a non-destructive right split beside the Org source buffer, keeps point in the source buffer, and turns on proportional follow-scroll; invoking it again (or pressing `q` in the preview) closes the preview and deletes only the split window it created. Invoked inside a preview buffer with no file argument, it delegates to `etaf-org-toggle-split`.
- Strictly `etaf-org-open` and `etaf-org-preview` are interactive `M-x` commands (matching `etaf-md`). All preview-buffer actions below are bound locally to keys in the preview buffer and remain callable from Lisp without polluting `M-x`. Optional authoring helpers (`etaf-org-edit-mode` for soft font-lock, CAPF completion, and block-pair matching, plus `etaf-org-insert-block`) are non-interactive Lisp functions suitable for `org-mode-hook` or custom keybindings.

## Reading keybindings

| Key | Command | Action |
| --- | --- | --- |
| `v` | `etaf-org-toggle-split` | Toggle single-window full-width reading ↔ left-source / right-preview split |
| `e` / `o` | `etaf-org-goto-source` | Jump to exact Org source line and highlight it (in place when single-window) |
| `n` / `C-c n` | `etaf-org-next-heading` | Move to next visible headline |
| `p` / `C-c p` | `etaf-org-previous-heading` | Move to previous visible headline |
| `C-c j` | `etaf-org-goto-heading` | Jump to a headline via completion |
| `RET` / `C-c C-o` | `etaf-org-open-link` | Activate link, footnote, control, or image |
| `K` | `etaf-org-preview-link` | Open/close in-buffer peek card for link, footnote, citation, or target |
| `f` | `etaf-org-follow-scroll` | Toggle proportional source-to-preview scroll sync |
| `C-c t` | `etaf-org-toggle-toc` | Toggle independent right-side `*ETAF Org Outline*` window |
| `C-c /` | `etaf-org-filter` | Filter sections live by TODO, `:tag:`, `#A`, or text |
| `z` / `Z` | `etaf-org-cycle-fold` / `etaf-org-cycle-global-fold` | Fold/unfold current section or whole document |
| `S` | `etaf-org-toggle-spoilers` | Reveal or mask all spoilers |
| `C-c v` | `etaf-org-toggle-hidden` | Toggle comments, property drawers, logbooks, and metadata |
| `t` | `etaf-org-cycle-theme` | Cycle `dark` → `light` → `sepia` → `auto` |
| `[` / `]` | `etaf-org-narrower` / `etaf-org-wider` | Adjust maximum reading measure |
| `g` / `r` | `etaf-org-reload` | Reload and repaint from source |
| `C-c h` / `?` | `etaf-help` | Show keybinding help |
| `q` | `etaf-org-close` | Unmount, close outline/split if owned, and restore origin buffer |

## Dialects (`etaf-org-flavor`)

- `etaf` (default): full native Org plus Org-native extension blocks, `#+attr_etaf:`, inline link micro-widgets, `==mark==`, and `!!spoiler!!`.
- `standard`: strict standard Org only (no extended containers, custom inline micro-widgets, or spoiler/mark sugars).
- Per-document override: write `#+ETAF_FLAVOR: standard` or `#+OPTIONS: etaf:nil`.
- Per-session override: pass `:flavor 'standard` or a feature plist `(:containers t :custom-links t :inline-marks nil :spoilers t :dynamic-widgets t)` to `etaf-org-create`.

## Themes and appearance

`etaf-org-theme` defaults to `auto`, which derives all surfaces and inks from the active Emacs frame's faces and paints no page background override. Fixed palettes are `dark`, `light`, and `sepia`. Switch interactively with `t` or programmatically with `(etaf-org-set-theme session 'sepia)`. Use `(etaf-org-theme-tokens theme)` to obtain the normalized 6-digit `#RRGGBB` ETAF UI token plist for any theme or palette.

## Trust policy and workspace sandbox

`etaf-org` separates capabilities into three explicit trust levels:

- **L0 (Pure reading)**: zero disk, process, or network access during render.
- **L1 (Read-only workspace sandbox)**: `etaf-org-allow-local-read` (default `t`) governs `#+SETUPFILE:`, `#+INCLUDE:`, `#+BIBLIOGRAPHY:`, `include`, `code-ref`, `symbol`, `project-tree`, `org-query`, `kanban`, `clock-summary`, `transclude`, `git-log`, `git-diff`, and `backlinks`. Paths resolving outside the canonical project root are always rejected.
- **L2 (Explicit user-triggered actions)**: `etaf-org-allow-actions` (default `'ask`) prompts before running `run` commands (set to `nil` to disable); `etaf-org-allow-babel` (default `nil`) keeps `#+begin_src` strictly non-executable unless explicitly enabled (`'ask` or `t`); `etaf-org-interactive-checkbox` (default `t`) lets clicking a checkbox toggle `[ ]` / `[X]` in source and update enclosing `[n/m]` or `[p%]` cookies; `etaf-org-interactive-todo` (default `nil`) optionally cycles headline TODO keywords on click.

## Embedding and scripting

Use `etaf-org-create` and `etaf-org-view` to embed Org views inside any ETAF layout or drive them headlessly:

```elisp
(let* ((session (etaf-org-create
                 :file "~/notes.org"
                 :theme 'auto
                 :today "2026-11-23"
                 :on-link (lambda (target)
                            (when (string-prefix-p "myapp:" target)
                              (message "Custom link: %s" target)
                              t))))
       (view (etaf-org-view session)))
  (etaf-mount (generate-new-buffer " *embedded-org*") view
              '(:viewport-width 100 :viewport-height 40)))
```

Use `(etaf-org-update-block session "block-id" new-view)` to dynamically replace a named block's rendered View, or `(etaf-org-set-filter session ":work:")` to filter visible sections.

## Troubleshooting and recovery

- Run `M-x etaf-org-doctor` to check availability of optional external tools (`mmdc`, `ffmpeg`, `qrencode`, `git`, `jj`, `rg`, `dot`, `plantuml`).
- Malformed container attributes, unclosed blocks, or invalid paths degrade inline with line-numbered diagnostics without blocking surrounding sections.
- Failed file reloads signal `etaf-org-error` and keep the last valid render.
- Remote images (`etaf-org-remote-images`) and diagram/formula caches are bounded by `etaf-org-cache-max-bytes` (default 100 MiB) with lazy LRU eviction.
