# etaf-highlight Manual

`etaf-highlight` registers as an `on-match` extension inside `etaf-ext` (automatically skipping the `etaf-ext-manager` tool buffer) with priority `60` and permissions `(read-tree decorate companion interact storage keys popup notify)`.

## Commands

Invoke `etaf-highlight` commands directly via `M-x` on any mounted ETAF page:

- `M-x etaf-highlight-add`: highlights the active region inside a text Host, or the entire text Host at point when no region is active (accepts optional color and note).
- `M-x etaf-highlight-remove`: removes highlights attached to the text Host at point.
- `M-x etaf-highlight-list`: opens the floating highlights overview popup listing every highlight on the current page.

Inside `etaf-ext`, `etaf-highlight` also registers four extension actions (`highlight`, `note`, `remove`, `list`, with default `:prefix-hint "h"` and subkeys `"h"`, `"n"`, `"d"`, `"l"`). With `etaf-ext-mode` enabled, reach them through `M-x etaf-ext-command-palette` or the configurable per-page dispatcher `M-x etaf-ext-dispatch` (`etaf-ext-key-prefix`, default `C-c C-e`, or `nil` to disable), and customize direct shortcuts in `M-x etaf-ext-manage` or via `etaf-ext-set-key`.

## Programmatic Usage

```elisp
(etaf-highlight-apply runtime host-id 0 24 :color 'green :note "Important passage")
(etaf-highlight-entries runtime)
```

Highlights persist in `etaf-ext`'s isolated storage namespace keyed by Runtime `:uri` (or buffer name). When the page is reopened, `etaf-highlight` re-anchors saved snippets automatically and re-paints colors whenever the Emacs theme switches.
