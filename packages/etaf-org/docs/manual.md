# ETAF Org User Manual

`etaf-org` turns Org-mode files into interactive reading views inside Emacs while preserving pure Org text on disk.

## Opening and live preview

- `M-x etaf-org-open` is the primary reading entry. Called from an Org buffer without a prefix argument, it opens full-width in the current window with zero prompt and syncs point to the corresponding source line; pass `C-u` or invoke from a non-Org buffer to pick a file. Pressing `q` (`etaf-org-close`) switches back to the origin buffer in place without deleting your window. Re-invoking it on the same canonical file reuses the existing buffer, and files sharing a basename disambiguate automatically.
- `M-x etaf-org-preview` toggles a live side-by-side preview in a non-destructive right split beside the Org source buffer, keeps point in the source buffer, and turns on proportional follow-scroll; invoking it again (or pressing `q` in the preview) closes the preview and deletes only the split window it created. Invoked inside a preview buffer with no file argument, it delegates to `etaf-org-toggle-split`.
- Strictly `etaf-org-open` and `etaf-org-preview` are globally autoloaded `M-x` commands (matching `etaf-md`). All preview-buffer actions below are interactive commands scoped to preview buffers via `completion-predicate` (callable via `M-x` / `M-X` inside previews as well as single keys) with customizable bindings in `etaf-org-keys` that never shadow user prefix keys (`C-c`, `C-t`, `C-x`, etc.). Optional authoring helpers (`etaf-org-edit-mode` for soft font-lock, CAPF completion, and block-pair matching, plus `etaf-org-insert-block`) remain non-interactive Lisp functions suitable for `org-mode-hook` or custom keybindings.

## Reading keybindings

| Key | Command | Action |
| --- | --- | --- |
| `v` | `etaf-org-toggle-split` | Toggle single-window full-width reading ↔ left-source / right-preview split |
| `e` / `o` | `etaf-org-goto-source` | Jump to exact Org source line and highlight it (in place when single-window) |
| `n` | `etaf-org-next-heading` | Move to next visible headline |
| `p` | `etaf-org-previous-heading` | Move to previous visible headline |
| `j` | `etaf-org-goto-heading` | Jump to a headline via completion |
| `RET` | `etaf-org-open-link` | Activate link, footnote, control, or image |
| `K` | `etaf-org-preview-link` | Toggle floating peek dialog for link, footnote, citation, or symbol |
| `f` | `etaf-org-follow-scroll` | Toggle proportional source-to-preview scroll sync |
| `T` | `etaf-org-toggle-toc` | Toggle independent `*ETAF Org Outline*` side window (`etaf-org-toc-side` default `left`, `etaf-org-toc-width` default `28`) |
| `/` | `etaf-org-filter` | Filter sections live by TODO, `:tag:`, `#A`, or text |
| `z` / `Z` | `etaf-org-cycle-fold` / `etaf-org-cycle-global-fold` | Fold/unfold current section or whole document |
| `S` | `etaf-org-toggle-spoilers` | Reveal or mask all spoilers |
| `H` | `etaf-org-toggle-hidden` | Toggle comments, property drawers, logbooks, and metadata |
| `t` | `etaf-org-cycle-theme` | Cycle `dark` → `light` → `sepia` → `auto` |
| `[` / `]` | `etaf-org-narrower` / `etaf-org-wider` | Adjust maximum reading measure |
| `g` / `r` | `etaf-org-reload` | Reload and repaint from source |
| `?` | `etaf-help` | Show searchable in-buffer keybinding help |
| `q` | `etaf-org-close` | Unmount, close split if owned, and restore origin buffer |

Preview bindings live in the customizable variable `etaf-org-keys` (each entry is `(KEY COMMAND LABEL)`) instead of a traditional major-mode keymap. Run `M-x customize-variable RET etaf-org-keys`, or edit `etaf-org-keys` in Elisp (takes effect on newly opened previews):

```elisp
(with-eval-after-load 'etaf-org
  ;; Rebind `e' to `C-c e' and remove `o':
  (setq etaf-org-keys
        (cons '("C-c e" etaf-org-goto-source "Jump to source")
              (assoc-delete-all "o"
                                (assoc-delete-all "e" (copy-sequence etaf-org-keys))))))

;; Set to nil to disable all default single-key bindings:
;; (setq etaf-org-keys nil)
```

## Customization

Eighteen options cover keybindings, themes, layout, dialects, native typesetting, media, workspace trust gates and caching:

| Option | Default | Effect |
| --- | --- | --- |
| `etaf-org-keys` | single-key alist | Preview buffer key bindings as `(KEY COMMAND LABEL)` entries; set to `nil` to disable default single-key bindings. |
| `etaf-org-theme` | `auto` | Initial palette (`auto`, `dark`, `light`, `sepia`); `auto` derives colors from frame faces without painting a page background. |
| `etaf-org-flavor` | `etaf` | Default Org dialect (`etaf`, `standard`, or a feature plist) when `etaf-org-create` receives no `:flavor`. |
| `etaf-org-width-min` | `40` | Narrowest reading measure, in character cells. |
| `etaf-org-width-max` | `96` | Widest reading measure, in character cells; wider windows center the column. |
| `etaf-org-toc-side` | `left` | Side of the frame where `*ETAF Org Outline*` opens (`left` or `right`). |
| `etaf-org-toc-width` | `28` | Width of the independent TOC side window in character cells (clamped `18..52`). |
| `etaf-org-image-max-height` | `24` | Maximum image card height in text lines. |
| `etaf-org-media-lightbox` | `auto` | Open local images inside the in-buffer media lightbox (`auto` on graphical frames, `t` always, `nil` external opener). |
| `etaf-org-typeset` | `t` | Render display math and `mermaid` blocks as SVGs via the prebuilt QuickJS native module (`M-x etaf-install-native`). |
| `etaf-org-node-directory` | `~/.emacs.d/etaf-org/nodes` | Directory holding custom `.el` node definitions loaded after built-in nodes. |
| `etaf-org-allow-local-read` | `t` | Permit read-only L1 workspace features (`#+INCLUDE:`, `code-ref`, `org-query`, `git-log`, etc.) inside the project root. |
| `etaf-org-allow-actions` | `ask` | Policy for executable `run` widget cards: `ask` prompts before running, `t` runs directly, `nil` disables execution. |
| `etaf-org-allow-babel` | `nil` | Control `[运行]` Babel execution triggers on `#+begin_src` blocks (`nil` disabled, `ask` prompts, `t` runs directly). |
| `etaf-org-interactive-checkbox` | `t` | Clicking a task checkbox toggles `[ ]` / `[X]` in source and updates enclosing `[n/m]` / `[p%]` cookies. |
| `etaf-org-interactive-todo` | `nil` | When non-nil, clicking a headline TODO chip cycles its keyword in source. |
| `etaf-org-remote-images` | `t` | Asynchronously fetch and cache remote HTTP(S) images in mounted previews. |
| `etaf-org-cache-max-bytes` | 100 MiB | Soft disk size ceiling for cached diagrams, formulas and remote images (lazy LRU eviction). |

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

- Run `M-x etaf-install-doctor` or evaluate `(etaf-org-doctor)` to check availability of the prebuilt native QuickJS typeset module (`typeset-native`, installed via `M-x etaf-install-native`) and optional external CLI tools (`ffmpeg`, `qrencode`, `git`, `jj`, `rg`, `dot`, `plantuml`).
- Malformed container attributes, unclosed blocks, or invalid paths degrade inline with line-numbered diagnostics without blocking surrounding sections.
- Failed file reloads signal `etaf-org-error` and keep the last valid render.
- Remote images (`etaf-org-remote-images`) and diagram/formula caches are bounded by `etaf-org-cache-max-bytes` (default 100 MiB) with lazy LRU eviction.
