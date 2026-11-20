# etaf-ui

`etaf-ui` is the official ETAF Component catalog. It is a normal optional package above `etaf`; it does not add a second Control or Widget model. Button, Checkbox, Label, Panel, and DataGrid are all ordinary Components with the same View, props, slots, events, and Data contracts.
It requires Emacs 29.1+, ETAF 0.2.2+, and Ebox 3.0.1+.

## Installation

Evaluate this once in Emacs and accept the default component gallery:

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

Package.el installs ETAF and its dependencies without Git, Python or a system
compiler; your configuration is not replaced. Reopen with `M-x etaf-install` or
`M-x etaf-ui-gallery-open`, including offline. Use `M-x list-packages` to update
or remove packages and restart after updates or installation failures. See
[installation and recovery](https://etaf.top/introduction/#installation).

## First Component

Use the exact registered names `etaf-panel`, `etaf-label`, `etaf-button`, and
`etaf-checkbox` in every View. Evaluate this complete example in a lexical-binding
`.el` file, then switch to `*etaf-preferences*` to use its controls.

<!-- etaf-example: preferences -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-ui)

(etaf-define-component demo-preferences ()
  :bindings ((done (etaf-ref nil))
             (saved (etaf-ref "Unsaved"))
             (rows (etaf-ref 3)))
  :view
  (etaf-panel :title "Account"
    (slot :name 'header
      (etaf-button :label "Save" :ref 'save-button
                   :on-press (lambda () (setf (etaf-value saved) "Saved"))))
    (etaf-label :text (etaf-value saved))
    (etaf-checkbox :bind done :label "Done" :ref 'done-checkbox)
    (etaf-number-input :bind rows :label "Rows" :ref 'rows-input :min 1 :max 10)
    (text (expr (if (etaf-value done) "Complete" "Pending")))))

(etaf-mount "*etaf-preferences*" (etaf-view (demo-preferences)))
```

[Complete usage and interface contracts](https://etaf.top/ui-overview/).

Run `M-x etaf-ui-gallery-open` to browse all 63 components in eight categories.
The Gallery includes live previews, Chinese/English search, scoped light/dark
Themes and reset. Each usage panel includes the public signature, parameter
meanings, required/default values, units, callback arguments and constraints,
followed by the same runnable, copyable example as the live specimen. Reference
text is read from the installed `etaf-ui.el` Commentary before mounting; no
separate API catalog or manual package is needed. It uses local data only. Wide windows show a sidebar and two-column overview; compact
windows use a category picker and a scrolling single column. Allow at least
72 character widths and 24 rows; smaller windows deliberately clip the layout.
See [Gallery workflows and lifecycle](https://etaf.top/ui-gallery-and-acceptance/).

For in-buffer floating UI, compose `etaf-popover`, `etaf-dropdown-menu` and
`etaf-dialog` with ordinary controls and slots. Run `M-x etaf-ui-surfaces-open`
for the [menu and preferences example](examples/etaf-ui-surfaces.el).
Placement and occlusion come from Ebox; panel navigation uses its shared focus.
Run `make gui-check` against the existing graphical Emacs server for the
maintained keyboard/mouse interaction workflow.
Use `make gui-check GUI_EXAMPLE=fonts` to compare actual physical row heights
and an unchanged neighboring row across native control toggles, selection,
tabs and dialogs in the current Emacs font configuration.
Use `make gui-check GUI_EXAMPLE=gallery` for the integrated Gallery workflow,
including drawer handoff, Chinese input, controlled selection and pagination.

Run `make perf-check PERF_ARGS='--diagnose'` from the development
workspace to measure the existing graphical Emacs. The shared runner uses the
registered Gallery callback, keyboard and mouse scenarios, with three sets of
ten samples and separate phase, CPU and allocation passes. Budgets remain
50 ms for the checkbox, 100 ms for floating UI and a separate 500 ms hard limit.
`PERF_TOOL=/path/to/workspace/scripts/performance.py` selects the same tool for
a separate checkout. The workspace's `docs/manual.md` documents baseline
comparison, source freshness and evidence boundaries.

Gallery selection has separate fresh-page and repeated-toggle workloads:
`gallery.selection.callback` and `gallery.selection.mouse` create a page per
sample; their `.steady.` counterparts retain one page and alternate checked
values. `gallery.categories.steady.callback` and `.mouse` cycle through input,
data and overview pages. Menu, tooltip, toast and mixed sequences cover overlays.
Owned fixtures resolve their viewport before timing; batch uses 160 character
widths and 50 rows. These versioned catalog-browser workloads are not comparable
with the former Atelier workspace workloads.

## Development

After cloning, run `make setup-hooks`. Before submitting a change, run `make check`; `make structure-check` is the fast organization gate.

`make check` runs structure checks, compilation and the public acceptance scenarios listed in [tests/acceptance.json](tests/acceptance.json). `make test` runs the same public API suite. The inventory covers every maintained Lisp test. GUI and performance checks use separate targets.

## Source layout

Add the repository root to `load-path` and require `etaf-ui`. The root entry
loads the implementation in `lisp/` and documents the supported public APIs in
its Commentary. Package archives include both the root entry and `lisp/`.
