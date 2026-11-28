# ecss

Source layout: add the repository root to `load-path` and use
`(require 'ecss)`. The supported API and usage notes are in
[`ecss.el`](ecss.el); implementation modules live in `lisp/`.

[中文](README.zh-CN.md)

`ecss` is an independent, pure, extensible CSS cascade engine for Emacs Lisp. It owns selectors, specificity, stylesheets, origins and importance, cascade layers, CSS-wide values, custom properties, `var()`, inheritance, computed styles, and provenance. It does not own text-property writes, reactive updates, buffer publication, or Box/Flex/Grid layout.

This repository is a new lowercase `ecss` project. It neither modifies nor depends on the historical uppercase `ECSS` repository, and it provides no forwarding compatibility layer to that project.

## Independent use

`ecss` does not embed Ebox properties or depend on a rendering runtime. Any program can register its own property vocabulary, expose nodes through built-in `ecss-subject` values or an adapter, and receive a pure-data computed style. The caller decides whether those values drive text, widgets, a DOM, layout, diagnostics, or another domain.

```elisp
(require 'ecss)

(let* ((package
        (ecss-schema-package-create
         'demo
         '((:id demo/color :initial "black" :inherits t
                :validator stringp :aliases (:color) :impacts (paint)))))
       (schemas (ecss-schema-set-compose package))
       (sheet (ecss-stylesheet-create))
       (button (ecss-subject-create
                :type "button" :classes '("primary"))))
  (ecss-stylesheet-add-rule
   sheet schemas "button.primary" '(demo/color "royalblue"))
  (ecss-computed-style-value
   (ecss-compute-style schemas button :stylesheet sheet)
   'demo/color))
;; => "royalblue"
```

## Core boundary

- `ecss-selector.el` owns the selector AST, parser, matcher, specificity, and generic subject adapter.
- `ecss-cascade.el` owns immutable package schemas, surface schema sets, stylesheets, complete winner ordering, inheritance, variable resolution, and provenance.
- `ecss.el` is the public package facade and has no behavioral load side effects.
- Package schemas and composed schema sets are immutable. Stylesheets change only through explicit authoring APIs. `ecss-compute-style` mutates neither its inputs nor the current buffer.
- An ordinary function value always remains a value. ECSS calls code only through an explicitly supplied `:value-resolver`; ECSS itself knows nothing about reactive bindings, Ebox nodes, or consumer-specific value-source types.

See [Architecture](docs/architecture.md) and the [ECSS chapters](https://etaf.top/ecss-schema-packages/) of the ETAF Reference Manual for the complete contract.

## Verification

```sh
make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make checkdoc EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make package-lint EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make diff-check
```

`package-lint` is an external development tool. If it is absent from the `emacs -Q` load path, provide it explicitly with `PACKAGE_LINT_LOAD_EXTRA='-L /path/to/package-lint'`. It is not an `ecss` runtime dependency.

The minimum Emacs version is 28.1. The current package version is 0.1.0.

## Development

After cloning, run `make setup-hooks`. Before submitting a change, run `make check`; `make structure-check` is the fast organization gate.

[Reference manual](https://etaf.top/ecss-schema-packages/) · [docs/architecture.md](docs/architecture.md) · [CHANGELOG.md](CHANGELOG.md)

`make check` runs structure checks, compilation and the public acceptance scenarios listed in [tests/acceptance.json](tests/acceptance.json). `make test` runs the same public API suite. The inventory covers every maintained Lisp test. GUI and performance checks use separate targets.

## Source layout

Add the repository root to `load-path` and require `ecss`. The root entry
loads the implementation in `lisp/` and documents the supported public APIs in
its Commentary. Package archives include both the root entry and `lisp/`.
