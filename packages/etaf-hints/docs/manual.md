# etaf-hints Manual

`etaf-hints` registers as an `on-command` extension inside `etaf-ext` requiring `(read-tree overlay interact keys notify)`. It consumes zero layout or runtime cost until `etaf-hints-start` is invoked.

## Configuration

Customize `etaf-hints-alphabet` to choose which home-row letters are used to assign hint codes:

```elisp
(require 'etaf-ext)
(require 'etaf-hints)
(setq etaf-hints-alphabet "asdfghjklqwertyuiop")
(etaf-ext-mode 1)
```

## Commands and Lifecycle

- `M-x etaf-hints-start (&optional runtime)`: collects visible enabled pressable or focusable Hosts, renders floating root-layer badges, and installs a transient capture keymap.
- `etaf-hints-input (keys &optional runtime)`: programmatically feeds hint characters (`:prefix`, `:activated` or `:cancelled`).
- `M-x etaf-hints-cancel (&optional runtime)` (`Esc` / `C-g` while hints are active): clears active badges immediately.
- `etaf-hints-active-codes (&optional runtime)`: returns the live `(CODE . HOST-ID)` alist while hints are displayed.

With `etaf-ext-mode` enabled, `etaf-hints` registers `:prefix-hint "f"` and `:subkey "f"` under `etaf-ext`'s configurable dispatcher (`etaf-ext-key-prefix`, default `C-c C-e`, or `nil` to disable), plus a conflict-checked optional `:suggested-key "M-f"` honored only when free of conflicts under `etaf-ext-keybinding-policy` (`safe`). Customize or unbind keys at any time in `M-x etaf-ext-manage` or via `etaf-ext-set-key`.

Detaching `etaf-hints`, disabling it in `etaf-ext-manage`, or entering Pure Mode automatically clears any open hint overlay and exits the transient keymap.
