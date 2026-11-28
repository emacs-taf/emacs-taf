# etaf-devtools Manual

## Opening and placement

Run `M-x etaf-devtools` (or `M-x etaf-devtools-open`) from any mounted ETAF buffer to open the inspector docked on the right side of the current frame. Press `d` or run `M-x etaf-devtools-toggle-dock` to cycle between right side window, bottom side window and a draggable floating `etaf-posframe` panel. Run `M-x etaf-devtools-close` to close the panel and release every overlay, hook and recording attachment.

Customize `etaf-devtools-default-dock` (`right`, `bottom` or `posframe`), `etaf-devtools-right-width` and `etaf-devtools-bottom-height` to adjust default geometry.

## Inspecting elements

Run `M-x etaf-devtools-inspect` (or press `i` inside DevTools) to enter Element Picker mode in the target ETAF buffer:

- Move with arrow keys, `j`/`k`/`h`/`l` or `n`/`p`, or click directly with the mouse.
- Press `[` to step outward to the parent Host and `]` to step inward.
- Press `RET` or click to confirm the selection and inspect its Box Model and ECSS cascade rules.
- Press `ESC`, `q` or `C-g` to cancel without altering target application state.

## Panels and shortcuts

- `1` (`Tree`): browse Component or full Host hierarchy (`m` switches mode), filter via search, jump to Component source (`g`), scroll and highlight in target (`v`), or trigger enabled `:on-press` (`a`).
- `2` (`Styles`): inspect the 4-layer Box Model diagram, matched ECSS rules with overridden declarations struck through, color swatches and WCAG contrast ratios.
- `3` (`State`): inspect Component props, named `:bindings`, Context and local refs; press `编辑` on any writable `etaf-ref` to edit its Lisp value live, or `切换` to flip booleans.
- `4` (`Perf`): monitor live Flush/Commit counts with a Braille sparkline and toggle deep `etaf-performance` stage recording (`r`).
- `5` (`Keys`): inspect focused Host identity, ordered Tab focus stops (click any row to test `etaf-focus`), declared `:region` entries and active `:keys` scopes.
- `6` (`Runtime`): switch between live mounted Runtimes, pin a target (`p`), run one-click viewport presets (`W` or toolbar buttons) and review lifecycle diagnostics.
- `?`: open ETAF's native read-only keyboard help modal.

## Standalone Highlight Updates

Run `M-x etaf-devtools-highlight-updates` from any ETAF buffer (or press `h` inside DevTools) to flash changed buffer lines on every flush without mutating the target buffer or distorting performance measurements.

## Embedding as a floating panel app

`etaf-devtools-create`, `etaf-devtools-view` and `etaf-devtools-dispose` expose the standard headless session contract for `etaf-posframe-register-app`:

```elisp
(etaf-posframe-register-app
 'devtools
 :title "DevTools"
 :create #'etaf-devtools-create
 :view #'etaf-devtools-view
 :on-stop #'etaf-devtools-dispose
 :width '(fraction 0.78)
 :height '(fraction 0.72)
 :at 'frame-center
 :draggable t)
```
