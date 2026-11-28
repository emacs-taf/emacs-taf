# Screensaver architecture

## Ownership and dependency direction

`etaf-screensaver` depends solely on Emacs 29.1+ and ETAF's public application and retained Host APIs (`etaf-app-open`, `etaf-view`, `etaf-define-component`, `etaf-ref`, `etaf-runtime-update-host-contents`, `etaf-runtime-flush`, `etaf-display-metrics`). ETAF owns rendering and mount resources; `etaf-screensaver` owns idle watching, window takeover, input dismissal, playback timing and scene execution. No external binary, process or image decoder is used.

## Module map

All runtime modules stay flat under `lisp/` with a strict one-way dependency DAG (`canvas` → `scene` → `engine` → `app`, and `canvas` + `scene` → `builtins`):

| File | Responsibility |
| --- | --- |
| `etaf-screensaver.el` | Public API inventory, autoloads and package entry |
| `lisp/etaf-screensaver-canvas.el` | Error condition, hex color mixing/ramps and wide-character-safe cell canvas with merged face-run projection |
| `lisp/etaf-screensaver-scene.el` | Scene registry, validation, `etaf-screensaver-define-scene` and high-level builders (`text`, `field`, `particle`) |
| `lisp/etaf-screensaver-engine.el` | Playlist compilation, card framing, session state, smoothstep row reveal and ETAF retained-Host view/publication |
| `lisp/etaf-screensaver-app.el` | Idle minor mode, window/frame/GC snapshot and restore, wake interception, absolute-grid timer and interactive commands |
| `lisp/etaf-screensaver-builtins.el` | Built-in pure-Elisp scenes (`matrix`, `snow`, `plasma`, `donut`, `equalizer`, `sand`, `poems`, `clock`) |

## Canvas and scene model

Each active session allocates one mutable `etaf-screensaver--canvas` sized to its drawable content rectangle and clears it before every `:render`. Wide CJK characters write a private continuation sentinel in their trailing cell; overlapping writes clear any split neighbor so row projection always produces exact display-width strings. Projection scans each row once, omitting continuation cells and coalescing adjacent identical faces into single `put-text-property` runs.

Built-in and user scenes share the same registry and builders. High-level builders (`define-text-scene`, `define-field-scene`, `define-particle-scene`) compile directly down to native Elisp closures registered through `etaf-screensaver--register`, avoiding any custom interpreter overhead while benefiting from byte and native compilation.

## Framing, transitions and retained publication

Playlist compilation validates all options, scene IDs and parameter overrides up front and applies one uniform precedence order (`item > global > scene default`).

Framing supports `full` and `card`. For `card`, static mat, hairline border and lower-left caption pieces are built once per page or resize; compact windows under 24×10 degrade cleanly to `full`. Horizontal side margins derive from `etaf-display-metrics` (with frame cell fallback) so top, side and bottom-plus-echo pixel margins match visually.

Page transitions snapshot at most one outgoing page with its background face baked into each row, then mix complete rows top-to-bottom on a smoothstep curve over at most half the incoming dwell. Repeating the same page skips the reveal and keeps the existing scene state running without a reset seam.

The ETAF component `etaf-screensaver--view` renders one retained `text` Host per row inside a fixed-dimension `box`. On each tick, `etaf-screensaver--session-publish` compares immutable row strings via `equal-including-properties` and sends only changed rows in one batched `etaf-runtime-update-host-contents` call. Resize flushes structural Host changes before publishing updated rows.

## Lifecycle and safety invariants

- **Validate before takeover**: configuration errors signal `etaf-screensaver-error` before modifying windows, frame parameters or `gc-cons-threshold`.
- **Single-owner idempotent teardown**: `etaf-screensaver-stop` clears `etaf-screensaver--active` before cancelling timers, removing hooks, unmounting ETAF, restoring frame/window configuration and killing the ephemeral buffer, making reentrant calls from buffer-kill or unmount hooks safe.
- **Input dismissal**: a transient map plus `pre-command-hook` consumes wake input without replaying it. Mouse button-down events are consumed while dismissal happens on release, preventing stray clicks on restored buffers.
- **External environment guards**: `window-configuration-change-hook`, `delete-frame-functions`, `after-focus-change-function` (only on true-to-false transitions of the owning frame) and `etaf-app-open`'s `:on-close` release the presentation if its host disappears.
- **Absolute frame grid**: the single-shot animation timer schedules the next integer frame slot relative to the page start time, skipping missed slots instead of bursting old frames or accumulating render latency.
- **Error isolation**: a runtime error during playback tears down cleanly, restores windows, reports a warning and disables `etaf-screensaver-mode` to prevent repeated idle error loops.
- **Automatic idle mode**: owns one idle timer and one `post-command-hook` rearming hook. Mouse-only wakes offset the next idle timer by `current-idle-time` so a full delay still elapses.

## Verification boundaries

`make check` verifies repository structure, zero-warning byte compilation, all public ERT acceptance scenarios in `tests/etaf-screensaver-tests.el` (driving real timers and native command-loop events through public APIs only) and entry signature/boundary compliance. `scripts/etaf-screensaver-gui-scenarios.el` validates visual rendering, card/full viewport matrices, resizing and wake routing in a real graphical Emacs; `benchmarks/performance-scenarios.el` measures autonomous frame cadence including timer wait and publication.
