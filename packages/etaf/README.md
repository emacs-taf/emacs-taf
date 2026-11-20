<h1 align="center"><img src="design/etaf-logo.svg" alt="ETAF — Emacs Text Application Framework" width="480"></h1>

ETAF builds text applications from reusable Components above the independent
[Ebox](https://github.com/emacs-taf/ebox/blob/main/) layout and rendering engine.

## Installation

In Emacs 29.1 or newer, evaluate this once and choose the framework or the
component gallery. Package.el installs dependencies without Git, Python or a
system compiler, and your existing configuration is preserved.

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

Then use `M-x etaf-install` to reopen installed targets offline and
`M-x etaf-install-doctor` for capability checks. Update or remove packages with
`M-x list-packages`; restart after an update or a failed installation. Do not mix
package installations with source load paths for the same dependencies.
See [installation and recovery](https://etaf.top/introduction/#installation).

## First View

Start with `etaf-view` and `etaf-mount`. Properties precede children in
`(name :property value ... child ...)`; property values are ordinary Elisp.
Evaluate the complete example, switch to `*etaf-hello*`, and activate “Say hello”:

<!-- etaf-example: hello -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-mount
 "*etaf-hello*"
 (etaf-view
  (column
    (text :font-weight 'bold "Hello")
    (box :ref 'hello :role 'button :tab-index 0
         :on-press (lambda () (message "Hello ETAF"))
      "Say hello"))))
```

A Component receives declared props and optional content through slots. Use the
exact name passed to `etaf-define-component`; the registry creates no aliases.
`(expr FORM)` evaluates one child expression. In a structural child position it
may return nil, text, a typed Host or Component View, or a proper sequence of
those values. Inside `text`, an expression must return a string.

<!-- etaf-example: card -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-define-component demo-card (&key title)
  :view
  (column
    (text :font-weight 'bold (expr title))
    (slot)
    (slot :name 'footer)))

(etaf-mount
 "*etaf-card*"
 (etaf-view
  (demo-card :title "Account"
    (text "Connected")
    (slot :name 'footer (text "Footer")))))
```

Use `:bindings` to initialize named state once per retained instance. The View
and its callbacks use these handles directly. Add `:setup` for lifecycle work;
`:render` and `etaf-node` remain available for programmatic View construction.

<!-- etaf-example: counter -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf)

(etaf-define-component demo-counter ()
  :bindings ((count (etaf-ref 0)))
  :view
  (column
    (text (expr (format "Count: %d" (etaf-value count))))
    (box :role 'button :tab-index 0
         :on-press (lambda () (cl-incf (etaf-value count)))
      "Increment")))

(etaf-mount "*etaf-counter*" (etaf-view (demo-counter)))
```

Keep `etaf-value` reads inside the property or `expr` that should update. Event
callbacks capture the named handles and the current render's lexical props.
Use a lexical-binding `.el` file for reusable application code. `etaf-node` is
available for programmatic View builders. Context, Data, Behavior, and named
Actions are optional capabilities; simple callbacks need no Action registration.

Use exact catalog names such as `etaf-button` after `(require 'etaf-ui)`.
Core does not load `.etaf` files: Playground treats them as inert structure,
with its explicit companion registration handling executable Elisp.

## Performance records

ETAF provides an independent, opt-in, application-neutral timing recorder.  It
consumes public Runtime observer reports without advice or private cross-package
probes.  Runtime operations such as Event, Action, mount, and refit are
recorded automatically; Ebox flushes, Data, Resource, and SQLite stages
inside the same operation are correlated by sequence.

```elisp
(require 'etaf)
;; In a buffer with a mounted ETAF Runtime:
(etaf-performance-mode 1)
;; Use any mounted ETAF application normally.
(etaf-performance-show)
```

For an interactive capture, run `M-x etaf-performance-clear` first.  After
reproducing the operations, press `c` in the panel (or run
`M-x etaf-performance-copy-report`) to copy a complete report.  Press `w` (or
run `M-x etaf-performance-export`) to save the same report as an `.eld` file.
The portable report includes the Emacs/display environment, power source,
low-power mode, native-JIT state, system load, grouped p50/p95/max, individual
operations, GC deltas, and ordered provider stages.  The panel header exposes
the same environment context so a machine-wide slowdown is not mistaken for
one package hotspot.

The `*ETAF Performance*` panel shows operation IDs, revision changes, total
latency, GC deltas, and each flat provider stage in sequence.  Provider stages
may overlap, so they are not presented as exclusive/self time.  Records are
bounded by `etaf-performance-max-records`; disabling the mode only detaches the
Runtime observer and never rewrites functions.  `etaf-performance-summary`
computes operation p50/p95/max statistics on demand, while
`etaf-performance-operation-stage-summary` groups one operation's flat stages
by provider category.  `etaf-performance-records` returns defensive operation
and stage copies; caller mutation cannot rewrite retained history.
Pass a numeric observer runtime ID to `etaf-performance-records` to select one
mount's history even when a buffer name is reused. Summary and report functions
use all retained records when called without an argument; an explicit `nil`
means an empty selection. The exported environment describes report creation,
not each historical operation. These synchronous operation durations do not
measure physical input-to-presentation latency; use the GUI measurement entry
in [README.md](README.md) for per-action condition checks.

Use `etaf-performance-call-operation` or
`etaf-performance-with-operation` to trace an arbitrary operation that has no
built-in public boundary.  Both delegate to the same Runtime operation boundary;
they do not create a second timer.

## Executable examples

The [`examples/`](README.md) directory contains four core-only best-practice applications: retained state and Actions, Data Controller ownership, Resource error/cleanup lifecycle, and time-driven animation. They are byte-compiled and driven through mounted public event paths by `make check`.

```elisp
(add-to-list 'load-path "/path/to/github/etaf/examples")
(require 'etaf)
(etaf-counter-example-open)
```

## Documentation

- [Architecture](docs/architecture.md) · [中文架构](docs/architecture.zh-CN.md)
- [Reference manual](https://etaf.top/introduction/) · [参考手册（中文）](https://etaf.top/zh-cn/introduction/)
- [Best-practice examples](README.md) · [中文示例](README.zh-CN.md)

## Independent packages

| Package | Role |
| --- | --- |
| [`etaf-ui`](https://github.com/emacs-taf/etaf-ui/blob/main/README.md) | Official Component catalog: Button, Checkbox, Label, Panel, and DataGrid. |
| [`etaf-db`](https://github.com/emacs-taf/etaf-db/blob/main/README.md) | Database backend package, currently providing SQLite; the Data Controller remains in ETAF core. |
| [`etaf-playground`](https://github.com/emacs-taf/etaf-playground/blob/main/README.md) | ETAF examples, with the UI catalog loaded only when requested. |
| [`ebox-playground`](https://github.com/emacs-taf/ebox-playground/blob/main/README.md) | Ebox-only layout examples, independent from ETAF. |

There is no separate `etaf-data` install: Data is a core ETAF capability. There is no generic `etaf-adapters` package: other databases, services, files, or ORMs should provide concrete Data Source packages with explicit names.

## Source development

For checkout-based development, load ECSS before Ebox, then ETAF. ETAF declares ECSS directly to
preserve deferred cascade values when resolving Theme tokens. ETAF uses Ebox as
its retained node, layout, focus, input and buffer engine; applications stay on
ETAF public APIs.

During development, load the sibling Ebox checkout before ETAF:

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/ebox")
(add-to-list 'load-path "/path/to/github/etaf")
(require 'etaf)
```

For interactive speed, run `make native` in the Ebox and ETAF checkouts after
each update. Each target byte-compiles its package and stores native code in
your `eln-cache`, which Emacs loads in place of the bytecode without further
configuration, even when JIT native compilation is disabled. A source file
edited later runs as bytecode until the next `make native`.

Run the complete local gate:

```sh
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

The core gate byte-compiles the implementation, runs the core/Data/Resource tests, and checks documentation/API boundaries. Run `make check` in the sibling `etaf-ui`, `etaf-db`, `etaf-playground`, and `ebox-playground` repositories for their independent gates; none is loaded by the core facade.



## Development

After cloning, run `make setup-hooks`. Before submitting a change, run `make check`; `make structure-check` is the fast organization gate.

[Reference manual](https://etaf.top/introduction/) · [docs/architecture.md](docs/architecture.md) · [CHANGELOG.md](CHANGELOG.md)

`make check` runs structure checks, compilation and the public acceptance scenarios listed in [tests/acceptance.json](tests/acceptance.json). `make test` runs the same public API suite. The inventory covers every maintained Lisp test. GUI and performance checks use separate targets.

## Source layout

Add the repository root to `load-path` and require `etaf`. The root entry
loads the implementation in `lisp/` and documents the supported public APIs in
its Commentary. Package archives include both the root entry and `lisp/`.
