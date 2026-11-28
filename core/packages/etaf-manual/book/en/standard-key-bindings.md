# Standard Key Bindings

The framework reserves a small set of keys and gives every mounted buffer a navigation map; everything else is application data declared through `:keys` or a session `:keymap`. The tables below list the standard bindings by context. Host-declared keys shadow the mounted buffer's bindings of the same key, framework keys cannot be rebound, and any key with no binding falls through to the buffer's remaining maps.

<!-- index: key binding; framework keys; buffer mode map; region selector -->

## Framework keys

| Key | Effect |
| --- | --- |
| `Escape` | Dismiss the nearest enabled Host with `:on-dismiss` in the scope chain. |
| `M-g` | Enter region selection; the selector reads one key. |
| `C-g` | Keep Emacs's native keyboard quit; it never dismisses a Host. |
| `?` | Open the read-only `*ETAF Help*` buffer for the current scope. |
| `TAB`, `S-TAB` | Move one focus stop forward or backward. |
| Arrow keys | Run `etaf-direction`: the nearest `:on-direction` handler, a separator or slider step, region adjacency, Ebox spatial movement, then one viewport scroll step. |
| `Home`, `End` | Reach the group's or scope's first and last focus stop. |

## Mounted buffer keys

The bindings come from `ebox-buffer-mode-map`, the keymap of a mounted canvas.

| Key | Effect |
| --- | --- |
| `n`, `p` | Scroll one line down or up. |
| `C-v`, `SPC`, `<next>` | Scroll a page down, also through the `scroll-up-command` remap. |
| `M-v`, `S-SPC`, `<prior>` | Scroll a page up, also through the `scroll-down-command` remap. |
| Wheel events | Scroll the canvas; the same bindings apply in the fringes and margins. |
| Horizontal wheel events | Scroll sideways. |
| `TAB`, `S-TAB` | Move one focus stop. |
| `RET`, `<return>` | Activate the focused control. |
| Arrows, `C-n`, `C-p`, `C-b`, `C-f` | Move focus with `ebox-focus-direction`; scroll when no stop lies that way. |
| `Home`, `M-<` | Reach the group's or scope's first focus stop. |
| `End`, `M->` | Reach the last focus stop. |
| `q` | Quit the window. |
| Motion events | Dispatch hover content through `mouse-movement`. |
| Primary press and drag | Move point; the canvas has no text selection. |
| Any unbound printing key | Suppressed, so a mounted canvas never becomes editable. |

## Region selector keys

The selector is the modal one-key interaction behind `M-g`; it stays open until one key ends it.

| Key | Effect |
| --- | --- |
| A region's hint key | Focus that region's effective entry. |
| Arrow keys; `h`, `j`, `k`, `l` under the `vim` scheme | Move to the adjacent region in that direction. |
| `?` | Repeat the hint with an explanation. |
| `Escape` | Cancel, leaving focus alone. |
| `C-g` | Abort like any native quit. |
| Any other key | Stay open and show a notice naming the key. |

## Input session keys

While a session edits a field, ordinary Emacs editing commands run against the hidden value buffer, and the commands in `ebox-input-edit-commands` — `newline`, `open-line`, `newline-and-indent`, `electric-newline-and-maybe-indent`, `completion-at-point`, `indent-for-tab-command` and `yank` — edit the value when a session `:keymap` binds them. Any other session keymap binding runs in the mounted buffer, which is how a field can bind RET to submit while `C-j` or Shift-RET inserts a newline. A press places the caret and a drag extends the selection; a double press selects the word, a triple press the whole value.

## Notes

- `etaf-direction-scheme` is `arrows` (the default) or `vim`; under `vim` the four letters dispatch as direction keys in navigation state. Set it through `etaf-set-direction-scheme`, which reports Host `:keys` and region hint conflicts before changing the scheme.
- The command palette is deliberately not a key: reach it with `M-x etaf-palette`, which runs a labelled command or focuses a named control.
- While a native input session edits, keys fall through the framework layer to the session's own editing commands.
