# etaf-hints Manual

`etaf-hints` registers as an `on-command` extension inside `etaf-ext` requiring `(read-tree overlay interact keys notify)`. It consumes zero layout or runtime cost until `M-f` (`etaf-hints-start`) is invoked.

## Configuration

Customize `etaf-hints-alphabet` to choose which home-row letters are used to assign hint codes:

```elisp
(require 'etaf-ext)
(require 'etaf-hints)
(setq etaf-hints-alphabet "asdfghjklqwertyuiop")
(etaf-ext-mode 1)
```

## Commands and Lifecycle

- `etaf-hints-start (&optional runtime)` (`M-f`): collects visible enabled pressable or focusable Hosts, renders floating root-layer badges, and installs a transient capture keymap.
- `etaf-hints-input (keys &optional runtime)`: programmatically feeds hint characters (`:prefix`, `:activated` or `:cancelled`).
- `etaf-hints-cancel (&optional runtime)` (`Esc` / `C-g`): clears active badges immediately.
- `etaf-hints-active-codes (&optional runtime)`: returns the live `(CODE . HOST-ID)` alist while hints are displayed.

Detaching `etaf-hints`, disabling it in `etaf-ext-manage`, or entering Pure Mode automatically clears any open hint overlay and exits the transient keymap.
