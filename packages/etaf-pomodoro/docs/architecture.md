# Architecture

## Responsibilities

| File | Responsibility |
| --- | --- |
| `etaf-pomodoro.el` | Public API inventory, options, and loading of the implementation |
| `lisp/etaf-pomodoro-theme.el` | One token set per appearance (light and dark) |
| `lisp/etaf-pomodoro-session.el` | Countdown state (four refs), commands, and the one-second tick |
| `lisp/etaf-pomodoro-views.el` | The timer surface: three styles, progress line, actions, footer, root keys |
| `lisp/etaf-pomodoro-app.el` | The application shell (`etaf-app-open`), the embeddable View, buffer commands |

Dependencies point one way: the entry loads the theme, the session, the views
and the app; the app depends on the views and the session; the views depend on
the session and the theme.  No module requires the entry, and consumers require
`etaf-pomodoro` only.

## Data flow

A session owns `remaining`, `total`, `running` and `style` as reactive refs and
holds its tick timer.  The root component binds those refs, renders from their
values and provides the palette for its subtree.  A tick, a button, a key or
`etaf-pomodoro-toggle` writes one ref; the framework repaints the surface from
the new value, so there is no refresh call and no second source of truth.

The Component also owns lifecycle: `etaf-on-mounted` starts the tick and
`etaf-on-unmounted` stops it.  That single rule covers a standalone buffer, a
floating panel and any other host, and it is why a closed surface cannot leave a
timer running.

## Invariants

- **One tick per session.**  `etaf-pomodoro--start` creates the timer only when
  the session has none, and every close path cancels it.
- **Styles share the body height.**  Each style paints the same four-row body,
  which keeps a panel's size constant across a style switch.
- **The surface paints no border.**  It adds one padding cell and lets the host
  frame be the card.  A border here would sit inside the panel's own border and
  make the panel edge look thicker on the sides where both are visible.
- **The palette comes from the appearance.**  The component reads
  `etaf-appearance` in a computed, so a host that provides an appearance ref can
  switch the timer without remounting it, and a standalone window follows the
  frame's theme.
- **The public API is the entry Commentary.**  Everything else, including the
  session structure and the tick, is internal.
