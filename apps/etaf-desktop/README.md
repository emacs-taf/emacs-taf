# ETAF Desktop

ETAF Desktop is an application-level desktop manager built on ETAF and ETAF UI.
It owns windows, workspaces, focus order, z-order, geometry policy and the
normal/minimized/maximized lifecycle. Ebox remains the retained layout and
incremental publication provider; ETAF UI's `etaf-window` is the controlled
presentation shell.

The demo desktop at a wide frame:

![The demo desktop at a wide frame](https://etaf.top/media/etaf-desktop/etaf-desktop-wide.webp)

## Installation

<!-- BEGIN:GENERATED:pkg-install-en:etaf-desktop -->
### From the ETAF package archive (recommended)

```elisp
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(etaf-install-ensure '(etaf-desktop))
```

Or run `M-x etaf-install` and select `etaf-desktop` interactively.

### From a source checkout

All core framework packages live in [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf):

```sh
git clone https://github.com/emacs-taf/etaf.git
git clone https://github.com/emacs-taf/etaf-desktop.git
```

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/etaf-desktop")
(require 'etaf-desktop)
```
<!-- END:GENERATED:pkg-install-en:etaf-desktop -->

## Minimal example

```elisp
(require 'etaf-desktop)
(let ((desktop (etaf-desktop-open)))
  (etaf-desktop-open-window desktop 'notes
    :title "Notes"
    ;; A window is seamless; the application keeps the frame margin clear.
    :view (etaf-view
           (box :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                (text "Hello")))))
```

Use the public mutation functions to move, resize, focus, maximize, minimize,
restore and close windows. `?` shows searchable, read-only help in the Desktop
buffer, using the focused application's bindings and reachable Desktop keys.
Escape leaves search editing before closing help; clicking outside also closes
it and restores focus, without splitting an Emacs window. Command execution
remains available through `M-x etaf-palette`.

See [the manual](docs/manual.md) for the complete
contract and [architecture](docs/architecture.md) for ownership boundaries.

## Runnable demo

`M-x etaf-desktop-demo-open` mounts a complete desktop with six sample
applications (Notes, Tasks, Clock, Calculator, Chat and Monitor) spread over
two workspaces. From a source checkout beside `etaf`:

```sh
cd etaf-desktop
emacs -Q -L ../etaf/packages/ecss -L ../etaf/packages/ebox \
  -L ../etaf/packages/etaf -L ../etaf/packages/etaf-ui -L . \
  -l etaf-desktop -f etaf-desktop-demo-open
```

The source is [examples/etaf-desktop-demo.el](examples/etaf-desktop-demo.el);
each application is a compact model of the `etaf-desktop-register-app`
contract described in [the manual](docs/manual.md#applications-and-instances).

## Checks

Run `make check` with Emacs 29.1 or newer and the core packages from
[`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) (`ecss`, `ebox`, `etaf`
and `etaf-ui`).

The workspace's `scripts/performance.py` includes native mouse workloads named
`etaf-desktop.demo.*`. They run the complete six-application demo with its Clock
timer, covering Notes launch/close, Settings open/close and all four tabs, and
Notes/Tasks content focus. Every sample checks lifecycle, active window and the
unchanged geometry of existing windows. Launch/close samples use fresh demos;
shell and focus samples retain their demo within a set. These workloads reopen
the demo through its public entry, which closes any previous demo controller.
Run them against your normal configured Emacs server, for example from the
workspace root:

```sh
python3 scripts/performance.py run --mode gui \
  --scenario 'etaf-desktop.demo.settings-*' --scenario etaf-desktop.demo.focus \
  --sets 1 --samples 3 --diagnose
```

This is a diagnostic screen; the workspace performance manual describes the
three-set acceptance protocol and its 10 ms interaction budget. Native input is
prequeued and does not certify physical pointer-to-display latency.
