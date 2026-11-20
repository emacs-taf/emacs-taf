# ETAF Pomodoro

A focus timer built as an ETAF application: one ordinary Emacs buffer with a
countdown, or the same timer mounted as a floating panel through
[etaf-posframe](https://github.com/emacs-taf/etaf-posframe). The session is
reactive, so a tick, a button or a key repaints the surface without a refresh
call, and the palette follows the appearance the host reports.

## Capabilities

- `M-x etaf-pomodoro-open` opens the timer as an ETAF application
  (`etaf-app-open`): the framework owns the buffer, the default face, the fit
  callback and the close hook.
- The same session mounts anywhere with `etaf-pomodoro-create` and
  `etaf-pomodoro-view`, including a floating panel registered with
  `etaf-posframe-register-app`.
- Three styles, `minimal`, `ring` and `card`, that occupy the same rows, so
  switching style inside a panel never changes the panel's size.
- The surface paints no border of its own and adds only one padding cell: the
  host's frame is the card, so a panel border stays one pixel wide on every
  side.
- The palette follows the appearance the host provides and the Emacs theme
  otherwise, so a panel inside a dark frame can stay light.
- The one-second tick runs while a View is mounted; closing the window or the
  panel stops it and the countdown keeps its value.
- One option, `etaf-pomodoro-default-minutes` (25).

## Prerequisites

| Requirement | Why | Check |
| --- | --- | --- |
| Emacs 29.1 or newer | the ETAF runtime and Ebox | `emacs --version` |
| ETAF, ETAF UI, Ebox and ECSS on `load-path` | rendering and the component catalog | see Installation |
| etaf-posframe (optional) | the floating panel | `(locate-library "etaf-posframe")` |

## Installation

Checkout users add the repository roots to `load-path` and require the entry:

```elisp
(add-to-list 'load-path "/path/to/etaf-pomodoro")
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ui")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/ecss")
(require 'etaf-pomodoro)
```

## Quick start

```elisp
;; A standalone timer window.
(etaf-pomodoro-open)           ; or M-x etaf-pomodoro-open
(etaf-pomodoro-stop)           ; closes the window and stops the tick
```

Register the same timer as a floating panel:

```elisp
(require 'etaf-posframe)
(etaf-posframe-register-app
 'pomodoro :title "≡ 番茄钟"
 :create #'etaf-pomodoro-create :view #'etaf-pomodoro-view
 :require 'etaf-pomodoro
 :width 42 :shortcut "p" :at 'frame-top-right :stack t
 :focusable t :draggable t)
(global-set-key (kbd "C-c e") #'etaf-posframe-app-prefix)
```

### Keys

| Key | Action |
| --- | --- |
| `p` | start or pause the countdown |
| `r` | reset to the full length and pause |
| `+` | add five minutes |
| `t` | switch to the next style |
| `q` | close the standalone window; the renderer closes a floating panel with its own `q` |
| `SPC` / wheel / arrows | scrolling, owned by the renderer |

## Documentation

- [User manual](docs/manual.md): workflows, embedding, lifecycle and failure
  semantics.
- [Architecture](docs/architecture.md): responsibilities, data flow and
  invariants.
- The root entry Commentary in `etaf-pomodoro.el` is the authoritative API
  inventory.
- [Changelog](CHANGELOG.md).

## Development

```sh
make check          # structure, compile, acceptance and entry API checks
make compile
make test
make structure-check
```

The package is one root entry, `etaf-pomodoro.el`, with the implementation in
`lisp/`, the correctness scenarios in `tests/` and their inventory in
`tests/acceptance.json`. Consumers require the root entry and use only the
interfaces it declares; unlisted symbols are internal.

## License

GPL-3.0-or-later.
