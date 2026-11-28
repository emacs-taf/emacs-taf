# ETAF Org (`etaf-org`)

`etaf-org` renders native Org-mode documents as modern interactive reading views inside Emacs using [ETAF](https://github.com/emacs-taf/etaf) and [Ebox](https://github.com/emacs-taf/etaf/tree/main/packages/ebox), and extends Org through a unified node registry, style-rule engine, Org-native container syntax, workspace live views, and an O(Δ) live-editing preview shell.

![ETAF Org at a wide frame](https://etaf.top/media/etaf-org/etaf-org-wide.webp)

## Capabilities

- **Complete native Org rendering.** Headlines with accumulating `#+TODO:` sequences, priorities, inherited tags, statistics cookies, `COMMENT` / `:ARCHIVE:`, real overdue calculation, planning lines, property drawers, `LOGBOOK` clock/state summaries, nested and description lists, clickable checkboxes, three-line booktabs tables (alignment/width cookies, whole-table centering, sorting, table copy, zebra, row/column/cell highlights), syntax-highlighted source blocks (line numbers, `[!code ...]` markers, word highlight, folding, copy, paired `#+RESULTS:`), quotes with formatted attributions, indented verses with inline markup, strict `$...$` math vs currency disambiguation, multi-paragraph footnotes with `↩` return links, `#+TOC:`, `#+SETUPFILE:`, `#+INCLUDE:`, `#+BIBLIOGRAPHY:` / `org-cite` / `#+PRINT_BIBLIOGRAPHY:`, entities, timestamps/ranges, targets, and links.
- **Unified node & style-rule engine.** Every core Org construct (`headline`, `src`, `table`, `quote`, `drawer`, `planning`, `math`) and every extended container lives in `etaf-org-node-definitions`. Style rules (`etaf-org-set-attr`) and view overrides (`etaf-org-set-view`) apply uniformly; user nodes load automatically from `etaf-org-node-directory`.
- **Focused editorial & Org living-document vocabulary.** Write containers as standard Org `#+begin_<name> :key val ... #+end_<name>`, affiliated `#+attr_etaf:`, `#+<marker>:` child markers, `#+BEGIN:` dynamic blocks, and inline link micro-widgets (`[[kbd:...]]`, `[[badge:...]]`, `[[sym:...]]`, `[[color:...]]`, `[[spoiler:...]]`, `[[icon:...]]`, `[[abbr:...]]`, `[[roam:...]]`, `[[denote:...]]`). Includes curated L0 layout/collection/visualization/comparison widgets, bounded workspace L1 views (`include`, `code-ref`, `symbol`, `project-tree`, `git-log`, `git-diff` supporting Git and Jujutsu), Org-exclusive live views (`org-query`, `kanban`, `clock-summary`, `transclude`, `backlinks`), and explicit confirmation-gated L2 actions (`run`, opt-in Babel). Switch to pure Org at any time with `:flavor 'standard` or `#+OPTIONS: etaf:nil`.
- **Clean single-window reading & O(Δ) live editing.** `M-x etaf-org-open` opens full-width in the current window with zero prompt on `.org` buffers and syncs to the source line; `M-x etaf-org-preview` toggles a non-destructive right split with proportional follow-scroll (`f`) and cleans up only its own window; `v` toggles single-window ↔ side-by-side split; `e` / `o` jumps back to source; `T` toggles an independent configurable TOC side window (`*ETAF Org Outline*`, `etaf-org-toc-side` defaulting to `left`, `etaf-org-toc-width` defaulting to `28`); `/` filters sections live; `K` toggles a floating peek dialog; `z`/`Z` folds sections; `S` toggles spoilers; `H` toggles hidden metadata; `t` cycles themes; every preview action is also a preview-scoped `M-x` command (see [Quick start](#quick-start) to customize keys); and `etaf-org-edit-mode` provides optional Lisp-enabled authoring help.
- **Native zero-browser Mermaid & MathJax rendering.** Display formulas (`$$...$$`, `\[...\]`, `\begin{align}...\end{align}`) and `mermaid` blocks render asynchronously inside a sandboxed QuickJS native module (vendored Obsidian Pele + MathJax TeX-to-SVG, auto-installed via `M-x etaf-install` / `M-x etaf-install-native`, zero browser or Node.js required) into a bounded LRU disk cache tinted to the active palette (`auto`, `dark`, `light`, `sepia`). Pluggable `etaf-org-src-renderers` plus optional `svg`, `dot`, `plantuml`, and `qrencode` support.

## Requirements

- Emacs 29.1 or newer.
- [ETAF](https://github.com/emacs-taf/etaf) 0.3.11+, `etaf-ui` 0.3.11+, `ebox`, and `ecss`.
- Prebuilt QuickJS native module (`typeset-native`, downloaded and SHA-256 verified automatically by `M-x etaf-install` or `M-x etaf-install-native` into `~/.cache/emacs-taf/native/`) for Mermaid and MathJax SVGs.
- Optional external CLI tools (inspect via `(etaf-org-doctor)`): `ffmpeg` (inline video), `qrencode`, `git` / `jj`, `rg`, `dot`, `plantuml`.

## Installation

<!-- BEGIN:GENERATED:pkg-install-en:etaf-org -->
### From the ETAF package archive (recommended)

```elisp
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(etaf-install-ensure '(etaf-org))
```

Or run `M-x etaf-install` and select `etaf-org` interactively.

### From a source checkout

All core framework packages live in [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf):

```sh
git clone https://github.com/emacs-taf/etaf.git
git clone https://github.com/emacs-taf/etaf-org.git
```

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-media" "etaf-ui"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/etaf-org")
(require 'etaf-org)
```
<!-- END:GENERATED:pkg-install-en:etaf-org -->

Installing via `M-x etaf-install` installs all framework dependencies plus the prebuilt native Mermaid/MathJax module automatically. From a source checkout, optionally run `make -C etaf-org compile`.

## Quick start

- `M-x etaf-org-open`: open a full-width reading view in the current window (zero prompt when visiting a `.org` buffer; pass `C-u` to pick another file).
- `M-x etaf-org-preview`: toggle a non-destructive right-hand live split beside the current `.org` source buffer with proportional follow-scroll (or toggle split when invoked inside a preview buffer).
- Optional Lisp hook: `(add-hook 'org-mode-hook #'etaf-org-edit-mode)` enables soft highlighting, CAPF completion, and block-pair matching in Org source buffers without adding extra global `M-x` commands.

### Keybindings and customizing keys

Inside a preview buffer, press `?` to browse all active single-key shortcuts (`n`/`p` headings, `j` jump, `T` TOC side window, `e`/`o` goto source, `v` toggle split, `f` follow scroll, `/` filter, `z`/`Z` fold, `K` peek, `S` spoilers, `H` hidden metadata, `t` theme, `[`/`]` measure, `g`/`r` reload, `q` close). See [docs/manual.md](docs/manual.md#reading-keybindings) for the full command table.

Preview bindings are defined in the customizable variable `etaf-org-keys` rather than a traditional major-mode keymap (defaults use single keys only so `C-c` / `C-t` / `C-x` prefixes are never shadowed, and every action is also callable via `M-x` / `M-X` inside a preview buffer). Each entry has the form `(KEY COMMAND LABEL)`.

Run `M-x customize-variable RET etaf-org-keys`, or edit `etaf-org-keys` in your init file (changes apply to newly opened previews):

```elisp
(with-eval-after-load 'etaf-org
  ;; Rebind `e' to `C-c e' and unbind `o':
  (setq etaf-org-keys
        (cons '("C-c e" etaf-org-goto-source "Jump to source")
              (assoc-delete-all "o"
                                (assoc-delete-all "e" (copy-sequence etaf-org-keys))))))

;; Or disable all default single-key bindings (useful for Evil / Meow users):
;; (setq etaf-org-keys nil)
```

Headless embedding example:

```elisp
(let* ((session (etaf-org-create :file "~/notes.org" :theme 'auto))
       (buffer (etaf-mount (generate-new-buffer " *org*")
                           (etaf-org-view session)
                           '(:viewport-width 100 :viewport-height 40))))
  (etaf-org-state session))
```

The root entry's Commentary in [etaf-org.el](etaf-org.el) is the authoritative public API inventory.

## Documentation

- [User Manual](docs/manual.md) / [用户手册](docs/manual.zh-CN.md): reading workflows, keybindings, flavors, trust policy, and embedding.
- [Extensions & Widgets Guide](docs/extensions.md) / [扩展与组件指南](docs/extensions.zh-CN.md): unified node model, style rules, L0/L1/L2 & Org-exclusive widgets, and custom node authoring.
- [Architecture](docs/architecture.md): module DAG, parse/derive/publish/render pipeline, O(Δ) live editing, and performance baseline.
- [Changelog](CHANGELOG.md).

## Development

```sh
make compile          # byte-compile with warnings as errors
make test             # public behavior scenarios (tests/acceptance.json)
make check            # structure, compile, acceptance, and API boundary gates
make benchmark        # parse, mount, fold, and edit/repaint timings
```

Runnable examples: `examples/complete-gallery.org`, `examples/widgets-showcase.org`, and `examples/etaf-org-demo.el`.
