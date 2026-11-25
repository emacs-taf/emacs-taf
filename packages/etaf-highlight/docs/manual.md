# etaf-highlight Manual

`etaf-highlight` registers as an `on-match` extension inside `etaf-ext` (automatically skipping the `etaf-ext-manager` tool buffer) with priority `60` and permissions `(read-tree decorate companion interact storage keys popup notify)`.

## Commands

- `C-c C-e h h` (`etaf-highlight-add`): highlights the active region inside a text Host, or the entire text Host at point when no region is active.
- `C-c C-e h n`: prompts for a note string and attaches a companion note card beneath the highlighted paragraph.
- `C-c C-e h d` (`etaf-highlight-remove`): removes highlights attached to the text Host at point.
- `C-c C-e h l` (`etaf-highlight-list`): opens the floating highlights overview popup listing every highlight on the current page.

## Programmatic Usage

```elisp
(etaf-highlight-apply runtime host-id 0 24 :color 'green :note "Important passage")
(etaf-highlight-entries runtime)
```

Highlights persist in `etaf-ext`'s isolated storage namespace keyed by Runtime `:uri` (or buffer name). When the page is reopened, `etaf-highlight` re-anchors saved snippets automatically and re-paints colors whenever the Emacs theme switches.
