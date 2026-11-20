# ETAF Slides architecture

## Module layout

| File | Responsibility |
| --- | --- |
| `etaf-slides.el` | Package entry: the public API inventory, the feature closure and the `lisp/` load-path bootstrap. |
| `lisp/etaf-slides-theme.el` | Light and dark palettes, the semantic color reader and the `:ui-*` token projection. |
| `lisp/etaf-slides-model.el` | Deck parsing, session state, stage geometry and the row estimate behind the overflow report. |
| `lisp/etaf-slides-views.el` | Presentation: session values plus palette to ETAF nodes. |
| `lisp/etaf-slides-app.el` | The Component, the buffer, the root keys, the presentation shell and the clock. |

Only ETAF and ETAF UI public interfaces are used by the application; the buffer
is an ordinary Emacs buffer rendered by Ebox through ETAF. The application
never calls an `ebox-` function directly.

## Data flow

```
deck.markdown -> parse -> slides -> session cells -> view -> ETAF mount
                                    ^
                       index / mode / theme / notes / clock / viewport
```

- **Parse.** `etaf-slides--parse` is a pure function over a string: it splits
  the front matter, the slides and the notes blocks, then hands each slide body
  to `etaf-ui-markdown-parse`. The result carries no presentation facts.
- **Session.** A session is a plist of `etaf-ref` cells. `etaf-slides-create`
  is headless and testable; the navigation functions write one cell each, and
  `etaf-slides-state` reports the session as plain data.
- **Stage.** `etaf-slides-stage` turns a pixel width and a row count into the
  aspect-preserving character grid: the stage takes the full width when the
  window is wide enough, otherwise the full height, and never exceeds either
  budget. Below the minimum usable size it reports `:clipped` rather than
  shrinking type.
- **Views.** `etaf-slides--frame` reads the cells and composes ordinary nodes.
  The slide body is rendered by `etaf-ui-markdown-view-blocks`, so the
  application owns one renderer for lists, quotes, code, tables and images
  rather than a second Markdown implementation.
- **Application.** `etaf-slides-app` owns the buffer, the root `:keys`, the
  `:on-fit` callback that records the viewport, and the clock timer. It is the
  only module that reads a session to decide what to show.

## Rendering decisions

**One stage, one slide, one mount.** The stage is a fixed-size box with
`:overflow hidden` inside a centered column, so a slide never scrolls and a
long slide clips at the stage edge. The overview replaces the stage in the same
buffer; there is no second Runtime for the same session.

**Aspect ratio instead of absolute positions.** A slide is composed with flow
layout inside the stage, not placed on an absolute pixel grid. The stage size
follows the window; the content reflows inside it. That keeps the deck readable
at any window size and keeps text size in the user's hands, which an absolute
canvas cannot do without scaling type.

**The body is the catalog's Markdown renderer.** Slide bodies are lists, code,
tables and paragraphs already implemented by `etaf-ui-markdown`. Using it keeps
one rendering behaviour across the previewer, the manual and the slides, at the
cost of accepting its heading scale for headings inside a body.

**Type size is Emacs' own text scaling.** The application sets no `:font-size`
anywhere: it calls `text-scale-set' on its buffer, and an ETAF Runtime
republishes the display metrics after settled scaling. The stage geometry then
recomputes its column and row count from the new cell size, so the slide is
drawn with fewer, bigger characters inside the same 16:9 area instead of being
clipped. `+`, `-` and `0` drive the same mechanism, which is why a zoomed deck
still lays out correctly and keeps the user's font family.

**Hairlines are borders on reserved rows.** An Ebox box takes row units for its
height, so a 1px box is not expressible. A rule is the bottom border of a
one-row box; the row is part of the layout budget.

**The overflow report is an estimate.** `etaf-slides-lines` counts wrapped
lines with a character-width model (wide characters count two columns). The
renderer wraps by pixels, so the estimate is only used to mark a slide in the
overview as possibly over budget; it never decides what is drawn.

**Selection is a bar, not a fill.** An overview row paints its selection as an
accent bar at the left plus ink text, and only unselected rows take a hover
fill. The bar also keeps the row's text off a background drawn by a nested
layout node, which reported a half-row offset when the row carried a fixed
height and an inner flex container.
