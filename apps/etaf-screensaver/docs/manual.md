# etaf-screensaver manual

This manual explains automatic idle presentation, playback configuration and writing custom screensavers in Emacs Lisp. The authoritative public API inventory lives in [etaf-screensaver.el](../etaf-screensaver.el).

## Automatic presentation and waking

```elisp
(require 'etaf-screensaver)
(setq etaf-screensaver-idle-delay 300)
(etaf-screensaver-mode 1)
```

After `etaf-screensaver-idle-delay` seconds without input, the selected frame switches to a canvas-only animation buffer. Automatic activation defers while the minibuffer is active or the frame is hidden or unfocused; it never creates or raises a frame and never spawns a child process.

Any key press, mouse movement, completed click or wheel event restores the prior window configuration, buffer and cursor position. The wake event is consumed rather than replayed into your document, and mouse clicks dismiss on button release so the release event cannot trigger controls in the restored buffer. `M-x etaf-screensaver-open` starts playback manually (`C-u` prompts for a single scene), `M-x etaf-screensaver-preview` picks any registered scene to preview, and `M-x etaf-screensaver-stop` dismisses explicitly. Killing the presentation buffer also cleans up.

Automatic mode retains one idle timer and one `post-command-hook` rearming hook. After a mouse-only wake that did not reset Emacs's native idle clock, the next idle interval offsets by the current idle duration so it still waits a full delay. `(etaf-screensaver-mode -1)` dismisses any active presentation and releases both the timer and hook. Re-enable the mode after changing `etaf-screensaver-idle-delay` if you want the new delay to apply immediately.

## Playback configuration

All user settings live under `M-x customize-group RET etaf-screensaver` or ordinary Emacs Lisp:

| Variable | Default | Purpose |
| --- | --- | --- |
| `etaf-screensaver-idle-delay` | `300` | Positive idle seconds before automatic presentation starts. |
| `etaf-screensaver-playlist` | `'(matrix snow donut plasma equalizer sand poems clock)` | Scene symbol, configured item `(SCENE :key val ...)`, or a list mixing both. |
| `etaf-screensaver-order` | `'sequential` | Round ordering: `sequential`, `shuffle` (each item once per round) or `random` (with replacement). |
| `etaf-screensaver-duration` | `30` | Default seconds per scene when neither the item nor the scene sets `:duration`. |
| `etaf-screensaver-frame-rate` | `30` | Global frame-rate cap in `(0, 60]`; caps every scene's requested rate. |
| `etaf-screensaver-background` | `"#05070B"` | Fallback canvas background color when a scene does not specify its own. |
| `etaf-screensaver-frame` | `nil` | Global framing override: `nil` keeps each scene's own `:frame`, `full` fills the window, `card` adds a thin border and lower-left caption. |
| `etaf-screensaver-transition-duration` | `1.0` | Top-to-bottom reveal seconds between different pages in `[0, 5]`; `0` disables transitions. |

### Playlist syntax and precedence

`etaf-screensaver-playlist` accepts a single scene name, a single configured item, or a flat list mixing both:

```elisp
;; One scene running continuously without reset seams.
(setq etaf-screensaver-playlist 'snow)

;; One configured scene with inline parameter overrides.
(setq etaf-screensaver-playlist '(matrix :speed 14 :color "#22D3EE"))

;; A shuffled playlist with per-item duration, framing and parameters.
(setq etaf-screensaver-order 'shuffle
      etaf-screensaver-playlist
      '((poems :duration 25)
        (matrix :speed 12 :duration 20)
        (donut :speed 8 :detail fine)
        (clock :seconds nil :frame card)
        equalizer))
```

Each configured item `(SCENE :key val ...)` accepts reserved playback keys `:duration`, `:frame-rate`, `:background`, `:frame` and `:params` (an alist), plus any keyword naming one of the scene's own parameters directly. Precedence is uniform across every setting: explicit item option overrides global setting (when applicable), which overrides the scene's own default. Invalid scenes, unknown parameter names or out-of-range values signal `etaf-screensaver-error` before modifying any windows.

### Framing, transitions and resuming

`full` draws edge-to-edge across the window. `card` extends the work's background across the window and echo row, insets a thin Unicode border by an even mat of up to three line heights vertically (and the matching pixel width horizontally), and shows the scene's `:title` and `:summary` at the lower left. Very compact windows (smaller than 24×10) fall back cleanly to `full`.

Switching between two different pages plays a smoothstep top-to-bottom row reveal lasting `etaf-screensaver-transition-duration` seconds (capped at half the incoming page's duration), preserving the outgoing page's background colors while the incoming page animates. Repeating the same page skips the transition and keeps the running scene state intact so continuous animations loop seamlessly.

Dismissing a configured presentation remembers the current playlist position, queue and RNG state; the next `etaf-screensaver-open` without arguments resumes from that scene if `etaf-screensaver-playlist` and `etaf-screensaver-order` are unchanged. Previews (`etaf-screensaver-preview` or passing an explicit playlist/seed to `etaf-screensaver-open`) never alter that saved position.

## Built-in scenes and parameters

| Scene | Default frame | Parameters |
| --- | --- | --- |
| `matrix` | `full` | `speed` (`8`), `tail` (`10`), `color` (`"#3BF07A"`) |
| `snow` | `full` | `speed` (`4`), `count` (`120`), `sway` (`4`) |
| `plasma` | `full` | `speed` (`3`) |
| `donut` | `full` | `speed` (`6`), `detail` (`normal`, `coarse` or `fine`), `color` (`"#CBD5E1"`) |
| `equalizer` | `full` | `speed` (`1.0`) |
| `sand` | `full` | `grains` (`3`), `color` (`"#D9C08A"`) |
| `poems` | `card` | `items` (list of `(:text ... :caption ...)`), `style` (`typewriter`), `color` (`"#2B3036"`), `hold` (`3.2`), `fade` (`0.8`), `speed` (`6.0`), `letter-spacing` (`t`), `order` (`shuffle`) |
| `clock` | `full` | `color` (`"#93C5FD"`), `seconds` (`t`), `drift` (`t`) |

For example, to replace the bundled poems with your own lines without defining a new scene:

```elisp
(setq etaf-screensaver-playlist
      '((poems :items ((:text "山高月小，水落石出" :caption "苏轼 · 《后赤壁赋》")
                       (:text "行到水穷处，坐看云起时" :caption "王维 · 《终南别业》")))))
```

## Authoring custom screensavers

Scene authoring is layered from high-level builders down to general pure callbacks, all registered in the same catalog and immediately selectable through `etaf-screensaver-preview` and `etaf-screensaver-playlist`. Registering an existing ID replaces it in place.

### Text, quote and live-status scenes

Use `etaf-screensaver-define-text-scene` for poetry, mottos, ASCII art or live read-only status boards:

```elisp
(etaf-screensaver-define-text-scene daily-notes
  :title "每日摘录"
  :summary "宣纸淡入淡出"
  :background "#F4F1EA"
  :frame 'card
  :style 'fade
  :hold 4.0
  :fade 0.8
  :items '((:text "知止而后有定" :caption "《大学》")
           (:text "致虚极，守静笃" :caption "《道德经》")))
```

Supported `:style` values are `typewriter`, `fade`, `scroll` and `static`. Passing a zero-argument function as `:items` lets a `static` scene refresh dynamically (for example reading a formatted timestamp or a cached quote string).

### Scalar field scenes

Use `etaf-screensaver-define-field-scene` for stateless 2D mathematical fields driven by native compiled Emacs Lisp:

```elisp
(etaf-screensaver-define-field-scene ripples
  :title "水波"
  :summary "同心圆干涉波纹"
  :frame-rate 15
  :range '(-1.0 1.0)
  :ramp " .:-=+*#%@"
  :palette '("#07101F" "#123456" "#2563EB" "#38BDF8" "#E0F2FE")
  :value (lambda (x y ctx)
           (let* ((dx (- x (* 0.5 (plist-get ctx :columns))))
                  (dy (* 2.0 (- y (* 0.5 (plist-get ctx :rows)))))
                  (dist (sqrt (+ (* dx dx) (* dy dy)))))
             (sin (- (* dist 0.45) (* (plist-get ctx :elapsed) 3.0))))))
```

Use `:block '(2 1)` to evaluate coarser cells for expensive formulas while keeping smooth palette run merging.

### Particle scenes

Use `etaf-screensaver-define-particle-scene` for fireflies, starfields, snow or falling petals:

```elisp
(etaf-screensaver-define-particle-scene fireflies
  :title "萤火"
  :summary "夜色中明灭游荡的萤火虫"
  :background "#04080F"
  :params '((count . 45))
  :spawn (lambda (_i ctx)
           (let ((r (plist-get ctx :random)))
             (vector (* (funcall r) (plist-get ctx :columns))
                     (* (funcall r) (plist-get ctx :rows))
                     (* (funcall r) 6.28)
                     (- (* (funcall r) 4.0) 2.0)
                     (- (* (funcall r) 2.0) 1.0))))
  :update (lambda (p ctx)
            (let ((dt (plist-get ctx :dt))
                  (w (float (plist-get ctx :columns)))
                  (h (float (plist-get ctx :rows))))
              (aset p 0 (mod (+ (aref p 0) (* dt (aref p 3))) w))
              (aset p 1 (mod (+ (aref p 1) (* dt (aref p 4))) h))
              (aset p 2 (+ (aref p 2) (* dt 2.2)))))
  :draw (lambda (p canvas _ctx)
          (let ((glow (* 0.5 (1+ (sin (aref p 2))))))
            (etaf-screensaver-canvas-put
             canvas (round (aref p 1)) (round (aref p 0))
             (if (> glow 0.6) ?● ?·)
             (etaf-screensaver-color-mix "#1E3A2F" "#D9F99D" glow)))))
```

### General scenes and the canvas toolkit

When a scene needs custom state or algorithms, use `etaf-screensaver-define-scene`. Only `:render` is required; `:create`, `:step` and `:resize` are optional. During `:render`, `ctx` includes a pre-cleared, exact-dimension scratch `:canvas` you can draw onto and return directly:

```elisp
(etaf-screensaver-define-scene breathing-box
  :title "呼吸方框"
  :frame-rate 20
  :render
  (lambda (_state ctx)
    (let* ((c (plist-get ctx :canvas))
           (cols (plist-get ctx :columns))
           (rows (plist-get ctx :rows))
           (k (* 0.5 (1+ (sin (* (plist-get ctx :elapsed) 1.4)))))
           (color (etaf-screensaver-color-mix "#1E293B" "#38BDF8" k))
           (w (max 8 (min (- cols 4) 36)))
           (h (max 5 (min (- rows 4) 9)))
           (r (/ (- rows h) 2))
           (col (/ (- cols w) 2)))
      (etaf-screensaver-canvas-box c r col w h color)
      (etaf-screensaver-canvas-text c (+ r (/ h 2)) 'center "Breathe" color)
      c)))
```

Callback context (`ctx`) keys: `:columns`, `:rows`, `:elapsed`, `:dt`, `:tick`, `:seed`, `:background`, `:params` (effective alist), `:param` (`(lambda (key))`), `:random` (`(lambda (&optional limit))`) and `:canvas` (during `:render`). Callbacks must stay pure: never create timers or processes, perform I/O or modify editor buffers.

Public drawing and color helpers:
- `etaf-screensaver-canvas-create`, `etaf-screensaver-canvas-clear`, `etaf-screensaver-canvas-rows`: allocate, reset and project cell grids with merged face runs.
- `etaf-screensaver-canvas-put`: draw a character (CJK wide-character safe) with a color string or face plist.
- `etaf-screensaver-canvas-text`: draw text at an integer column or `left`, `center` or `right`.
- `etaf-screensaver-canvas-fill`, `etaf-screensaver-canvas-box`: draw filled rectangles and thin Unicode frames.
- `etaf-screensaver-color-mix`, `etaf-screensaver-ramp`: blend `#RRGGBB` colors and sample character or color ramps.

## Failure recovery and performance notes

- Invalid configuration fails before window takeover, leaving your layout untouched.
- If a scene callback signals an error during playback, the presentation stops immediately, restores the previous windows, disables `etaf-screensaver-mode` (preventing an idle error loop) and displays a warning.
- While presenting, `gc-cons-threshold` is locally capped at 32 MiB and restored on stop so continuous animations avoid long GC pauses without altering your global Emacs GC setting.
- Keep palettes quantized (for example 4–12 distinct colors) so adjacent cells merge into few face runs per row and only changed rows cross ETAF's retained Host boundary.
