# ETAF Org Architecture

`etaf-org` is structured as an acyclic 17-module pipeline under `lisp/`, re-exported through the single root entry [etaf-org.el](../etaf-org.el). It depends only on Emacs 29.1+, `etaf`, and `etaf-ui` public APIs — never on `ebox` internal symbols or `etaf-md`.

## Module dependency DAG

```text
Level 0 (leaves)
  etaf-org-entities   Org named entities & LaTeX-to-Unicode table
  etaf-org-cache      Bounded LRU disk cache pruning & async remote images
  etaf-org-theme      Batch-safe RGB/WCAG contrast, 6-digit hex tokens, palettes & display metrics
  etaf-org-node       Node registry, 9-type validator, style cascade, `etaf-org-error'

Level 1 (parse, derive, rendering env)
  etaf-org-parse      Pure Org + extension parser (flavors, line spans, splice-parse)
  etaf-org-derive     Document-wide derivation (IDs, outline, numbering, overdue, indexes)
  etaf-org-env        `etaf-org-env' struct, 12 public env primitives, leaf-only hover

Level 2 (publish-time & async assets — zero I/O in `:render')
  etaf-org-qrcode     Async `qrencode' PNG generation
  etaf-org-typeset    Embedded QuickJS native module (Pele Mermaid + MathJax TeX-to-SVG), `dot'/`plantuml'/`svg'
  etaf-org-assets     L1 workspace sandbox (`#+SETUPFILE:', `#+INCLUDE:', bib,
                      `org-query', `kanban', `clock-summary', `transclude',
                      `backlinks', `include', `code-ref', `symbol', `project-tree',
                      `git-log'/`git-diff' for Git & Jujutsu) & L2 explicit `run'

Level 3 (registered node definitions)
  etaf-org-nodes      Core Org nodes + L0 layout/collection/interactive/showcase nodes
  etaf-org-widgets    Visualization, comparison, L1, Org-exclusive & L2 widgets

Level 4 (views & reactive session model)
  etaf-org-views      Pure AST -> ETAF View rendering, chrome (filter, peek, lightbox)
  etaf-org-model      Reactive session refs, keyed block slots, links, navigation

Level 5 (live editing, application shell, authoring mode)
  etaf-org-live       16 ms coalescing, `input-pending-p' yield, O(Δ) body splice, filenotify
  etaf-org-app        `etaf-org-open', `etaf-org-preview', `etaf-org-toggle-split',
                      independent configurable TOC side window and `etaf-org-keys' keymap
  etaf-org-edit       Optional non-destructive `etaf-org-edit-mode' & `etaf-org-insert-block' (Lisp helpers)
```

## Core invariants

1. **Zero I/O during `:render`**: No file reads, directory scans, subprocess spawns, or network requests ever run inside ETAF view functions. Media dimensions, L1 workspace snapshots (`:asset-data`), and cached graphics (`:picture`) attach during publish (`etaf-org--install`) or asynchronously via `etaf-org--refresh-block-assets`, which updates only the `:cell` ref of blocks whose attached asset actually changed.
2. **Per-block reactive slots & O(Δ) live editing**: Every published block owns a stable slot `(:key :cell :state :override :section)`. Local widget interactions (tabs, sorting, code fold, drawer toggle) write only `:state`. Typing in a linked Org source buffer coalesces on a 16 ms frame timer (yielding up to 60 ms while `input-pending-p`). Edits confined to one section's body without structural changes splice-parse only that section (`etaf-org--parse-body-slice`) and update the single changed `:cell` ref; structural edits fall back to keyed document publish, keeping unchanged block and section instances intact.
3. **Typography, integer spacing & 4-tier hover discipline**: All prose, chips, tags, tables, drawers, footnotes, code cards, outline items, and widgets render at standard `1.0x` body metrics with integer `(lh N)` vertical padding (preventing blank-line SVG cursor boxes); only document title (`2.2x`) and H1–H4 (`2.0/1.5/1.25/1.1x`) scale. All interactive controls use leaf-only `:hover-style` (`etaf-org--leaf-button`), suppressing hover and hand pointer on selected or disabled leaves and never painting hover fills over static text, code lines, table cells, or multi-styled containers.
4. **Workspace sandbox**: Every L1 path resolves via `file-truename` and is checked with `file-in-directory-p` against the canonical VCS/document root. All L2 actions (`run`, Babel) require explicit user activation and honor `etaf-org-allow-actions` / `etaf-org-allow-babel`.
5. **Two-tier `M-x` surface & independent configurable TOC side window**: Strictly `etaf-org-open` and `etaf-org-preview` are globally autoloaded `M-x` commands (matching `etaf-md`); preview-buffer actions are interactive commands scoped to preview buffers via `completion-predicate` with customizable single-key defaults (`etaf-org-keys`, never shadowing `C-c`/`C-t` prefixes), and the TOC opens as an independent Emacs side window (`*ETAF Org Outline*`, configured via `etaf-org-toc-side` defaulting to `left` and `etaf-org-toc-width` defaulting to `28`) so variable-height headlines never stretch or jitter TOC rows during scrolling.

## Measured performance baseline

Measured in batch mode via `make -C packages/etaf-org benchmark` on a generated 120-section, 40,789-character, 2,272-line Org document:

| Path | Elapsed |
| --- | --- |
| Parse + derive (`etaf-org-create`) | ~45 ms |
| Full mount (`etaf-mount`) | ~215 ms |
| Single-section fold (`etaf-org-fold`) | ~0.5 ms |
| Paragraph edit + repaint | ~32 ms |
