# ETAF Pomodoro manual

A focus timer built with ETAF: one window or one floating panel, a reactive
countdown, three styles and a palette that follows the host.

## Open and close

`M-x etaf-pomodoro-open` opens the timer in its own buffer through
`etaf-app-open`.  The framework owns the buffer, the default face, the fit
callback and the close hook, so the timer needs no resize or lifecycle code of
its own.  An already open timer is selected instead of opening a second one.

`M-x etaf-pomodoro-stop` closes that buffer and stops the tick.  Closing the
buffer by any other means (`q` on the surface, `C-x k`, the frame going away)
runs the same close hook, so the countdown never keeps a timer alive after its
window is gone.

The timer starts paused.  Nothing counts until you press `p`; a fresh session
shows its full length, and the countdown stops at `00:00` with an echo-area
message.  `r` returns to the full length and pauses, `+` adds five minutes to
both the remaining time and the full length so the progress line keeps
measuring the whole countdown, and `t` cycles `minimal` → `ring` → `card`.

## Sessions

A session is the unit of state.  `etaf-pomodoro-create` returns one:

```elisp
(let ((session (etaf-pomodoro-create :minutes 50 :style 'ring)))
  (etaf-pomodoro-state session))
;; => (:remaining 3000 :total 3000 :running nil :style ring)
```

The session holds four reactive refs (seconds left, full length, running, style)
and the one-second tick.  The public commands take the session:

| Function | Effect |
| --- | --- |
| `etaf-pomodoro-toggle` | start or pause; returns the new running state |
| `etaf-pomodoro-reset` | full length again, paused |
| `etaf-pomodoro-extend` | `+5` minutes by default, or an explicit number |
| `etaf-pomodoro-next-style` | next of `minimal`, `ring`, `card` |
| `etaf-pomodoro-state` | a plist with `:remaining`, `:total`, `:running`, `:style` |
| `etaf-pomodoro-stop-session` | stop the tick, keeping the values |

`etaf-pomodoro-create` signals `etaf-pomodoro-error` for a focus length that is
not a positive whole number of minutes or a style outside the three.  The same
error covers a non-positive extension.

## Embedding in a floating panel

The View is mountable in any host:

```elisp
(require 'etaf-posframe)
(etaf-posframe-register-app
 'pomodoro :title "≡ 番茄钟"
 :create #'etaf-pomodoro-create :view #'etaf-pomodoro-view
 :require 'etaf-pomodoro
 :width 42 :shortcut "p" :at 'frame-top-right :stack t
 :focusable t :draggable t)
```

`etaf-posframe-register-app` calls `etaf-pomodoro-create` for each opening and
mounts `etaf-pomodoro-view` in a child frame.  The tick starts when the View
mounts and stops when the panel closes, so a closed panel costs nothing.  The
surface paints no border and adds one padding cell only: the panel frame is the
card, which keeps its border one pixel wide on every side.

The three styles have the same height on purpose.  A panel settles its frame
size when it opens, so a style that needed an extra row would clip; with one
four-row body the styles switch inside a panel without resizing it.

The panel keeps the timer keys (`p`, `r`, `+`, `t`) in its root Host.  The
renderer's own minor-mode map keeps `SPC`, the wheel and `q`: inside a panel `q`
closes the panel, and the application's `q` only closes the standalone window.

## Appearance

The palette is one compact token set per appearance (light and dark) in
`lisp/etaf-pomodoro-theme.el`.  The application provides the tokens of the
appearance its host reports through `etaf-appearance`, so a light panel inside a
dark frame stays light and a standalone window follows the Emacs theme.  A
theme switch reaches the timer through the framework's own re-derivation, so
the countdown surface repaints without being reopened.

## Lifecycle and failures

- The tick is a single `run-at-time` timer per session, started on mount and
  cancelled on unmount or by `etaf-pomodoro-stop-session`.  Mounting the same
  session again continues from its values.
- The countdown stops at zero and clears the running flag; no timer is left
  running beyond the session's own tick.
- `etaf-pomodoro-create` validates its inputs before creating refs, so a bad
  argument leaves nothing behind.
- A panel and a standalone window may run at the same time; they own separate
  sessions.

## A runnable example

```elisp
(require 'etaf-pomodoro)
(etaf-pomodoro-open 10)             ; ten minutes
```

Press `p` to start, watch the progress line move, `+` for five more minutes,
`t` to change style, and `q` to close the window.  The countdown stops with the
window; the next `etaf-pomodoro-open` begins a fresh session.
