# ETAF Org Extensions & Widgets Guide

`etaf-org` extends Org-mode through one unified node model: core Org constructs and extension containers share the same registry (`etaf-org-node-definitions`), attribute type system, style-rule cascade (`etaf-org-set-attr`), and twelve `env` rendering primitives.

## Org-native extension syntax

1. **Block containers (`#+begin_<name> :key val ... #+end_<name>`)**:

```org
#+begin_card :title "Architecture" :accent primary
Any standard Org blocks (lists, tables, code, formulas) live inside.
#+end_card
```

2. **Affiliated attributes (`#+attr_etaf:`)** attach to native Org blocks (`#+begin_src`, tables, quotes) or containers; inline arguments beat `#+attr_etaf:` which beats other `#+attr_*:` lines:

```org
#+attr_etaf: :sortable t :copy t :zebra t :highlight-rows "1" :align center
| Metric | Value |
|--------+-------|
| Parse  | 45 ms |
```

3. **Child markers (`#+<marker>:`)** split marker-based containers cleanly:

```org
#+begin_tabs
#+tab: Lisp
Code for Lisp.
#+tab: Python
Code for Python.
#+end_tabs
```

4. **Dynamic blocks (`#+BEGIN: <name> :key val ... #+END:`)**: native `clocktable` and `columnview` render their inner Org blocks; registered widgets such as `org-query` or `clock-summary` work in either `#+begin_` or `#+BEGIN:` syntax.

5. **Inline link micro-widgets**: `[[kbd:T]]`, `[[badge:success:Ready]]`, `[[sym:etaf-org-open]]`, `[[color:#0969da]]`, `[[spoiler:hidden]]`, `[[icon:star]]`, `[[abbr:ETAF]]`, `[[roam:note]]`, `[[denote:20261123]]`, plus `==mark==` and `!!spoiler!!`.

## Built-in widget catalog

Run `(etaf-org-describe-nodes)` to inspect every registered node, its exact attributes, accepted children, and active style rules.

- **Core Org nodes (styleable)**: `headline`, `src`, `table`, `quote`, `callout`, `drawer`, `planning`, `math`.
- **L0 callouts**: `note`, `info`, `tip`, `important`, `warning`, `caution`, `danger` (3px left accent bar + soft tint, optional `:title`, `:accent`, `:collapsible`, `:open`).
- **L0 layout & surfaces**: `box` (7 surfaces: `none`, `page`, `raised`, `sunken`, `quote`, `table-header`, `table-stripe`), `card` (6 semantic accents including `important`, optional `:text-align center`), `columns`/`col` (`:grow`, `:justify-content`, `:wrap`, `:divider`), `details`, `left`, `center`, `right`, `justify`, `window`, `panel`, `tab-panel`, `form`, `log`, `statusbar`.
- **L0 collections & interactive**: `steps`/`step`, `timeline`/`event` (`:time` eyebrow above bold wrapped title, degrades to vertical below 28ch per column), `stats`/`stat` (four-quadrant editorial layout, supports `:from <table-name>`), `field`, `file-tree` (`:lines`, `*focus*`/`**focus**`, `++`/`--`), `chat`, `tabs`, `code-tabs` (single frame), `accordion`, `swiper`, `code-tree` (bounded viewport height without half-line clipping), `home-box`, `link-card`, `image-card`, `qrcode`.
- **L0 visualization & comparison**: `chart` (`line`/`bar`/`stacked`/`heatmap` + `:from <table-name>`, no duplicate `%` label in `stacked`), `progress`, `keymap` (booktabs layout, `/` separator without keycap), `breadcrumb`, `diff` (paired split view, auto-unified on narrow viewports with `-` strictly before `+`), `pros-cons` (borderless 3px left accent bar + equal height), `demo` (clean top canvas + bottom toggle bar).
- **L1 workspace live views**: `include` (single frame), `code-ref` (single frame + balanced `forward-sexp` Elisp form extraction), `symbol` (API dictionary entry with complete first-paragraph docstring), `project-tree`, `git-log` (Git and Jujutsu), `git-diff` (Git and Jujutsu).
- **Org-exclusive L1 views**: `org-query`, `kanban`, `clock-summary`, `transclude`, `backlinks`.
- **L2 explicit actions**: `run`.

## Style rules (`etaf-org-set-attr`)

Resolution order: matching `etaf-org-styles` rules (later wins) > document attributes > declaration `:default` > read-only `:derived` attributes.

```elisp
;; Number top-level headings and prefix with section sign
(etaf-org-set-attr '(headline :level 1)
                   '((prefix "§ ") (numbering decimal)))

;; Enable zebra striping and numbering on all Org tables
(etaf-org-set-attr '(table) '((zebra t) (numbering decimal)))

;; Clear a rule
(etaf-org-set-attr '(headline :level 1) nil)
```

## Authoring custom nodes

Define a custom node in Emacs or drop a `.el` file under `etaf-org-node-directory` (`~/.emacs.d/etaf-org/nodes/`):

```elisp
(etaf-org-define-node 'release-note
  :name "release-note"
  :summary "Release summary callout"
  :attrs '((version :type string :required t :doc "Version tag")
           (accent :type accent :default primary :doc "Accent color"))
  :view (lambda (env)
          (etaf-node 'column
                     (list :width 'stretch
                           :border-left (list '(px 3) 'solid
                                              (etaf-org-accent env (etaf-org-attr env :accent)))
                           :background-color (etaf-org-surface env 'raised)
                           :padding '((lh 1) (ch 2)))
                     (list (etaf-node 'text
                                      (list :color (etaf-org-accent env (etaf-org-attr env :accent))
                                            :font-weight 'bold)
                                      (list (format "Release %s" (etaf-org-attr env :version))))
                           (etaf-org-content env)))))
```

To wrap an existing node's rendering without losing its default view, use `etaf-org-set-view` with `etaf-org-default-view`, and pass `nil` to restore. To replace rendering for a specific `#+begin_src <lang>`, add `(LANG . FN)` to `etaf-org-src-renderers`.
