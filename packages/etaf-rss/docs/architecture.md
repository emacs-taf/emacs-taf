# etaf-rss architecture

This document describes the implemented system: responsibilities, dependency
direction, data flow and invariants. It is not a plan.

## Responsibility and dependencies

ETAF RSS is a text application built on the ETAF ecosystem. It depends on
`etaf` (components, state, runtime), `etaf-ui` (controls and theme tokens) and
their providers `ebox` and `ecss`; it depends on no other application. The
framework never depends on this repository.

The application uses only the public interfaces declared in the provider
entries: no `ebox-` calls, no `ecss` calls, no internal modules.

## Layers

```
etaf-rss.el        entry: Commentary API inventory, autoloads, requires
lisp/
  etaf-rss-theme.el    palette, ETAF UI theme tokens, the error type
  etaf-rss-parse.el    feed/OPML parsing, HTML to blocks, wrapping (pure)
  etaf-rss-store.el    JSON persistence, schema normalization, retention
  etaf-rss-service.el  the store owner: fetch, merge, scopes, OPML (client)
  etaf-rss-miniflux.el a second backend: the same requests over a REST API
  etaf-rss-model.el    one session: reactive state and user actions
  etaf-rss-views.el    internal Components: plain values in, callbacks out
  etaf-rss-app.el      the application Component, keymap, open/close
```

Each layer has one responsibility and only depends on the ones above it in
this list. `views` and `app` are the only files that require `etaf-ui`.

## Data flow

```
keys / mouse ─→ app commands ─→ model actions ─→ service client
                                     ↑                 │
                                     │   (:ok DATA)    │  fetch/parse/merge
                                     └─────────────────┘
                                     reactive refs
                                          │
                     app Component reads refs ─→ views ─→ Ebox flush
```

- The **service client** is the only code that touches the network and the
  store file. It answers plist requests asynchronously and keeps its answers
  in the session, not in the view. Local queries answer from an event-loop
  timer; fetches answer from their transfer callback, one at a time.
  A client is the local struct, a function of (REQUEST CALLBACK), or a plist
  `(:call FUNCTION [:cancel FUNCTION])`; `etaf-rss-miniflux.el` is the last
  kind and answers the same request protocol from a server's REST API, so
  every layer above the client is backend-agnostic and the Miniflux sessions
  are tested with a transport function instead of the network.
- The **model** owns a plist of `etaf-ref` sources plus the follow/refresh/
  read timers. It never talks to the file or the network directly, and every
  reply is guarded by a generation counter so a superseded scope, search or
  article reply is dropped.
- The **application Component** is the only place that reads refs. A ref
  write repaints the mounted view; the views themselves never read the model,
  so they can render from plain data in tests and previews.
- **Views** contain no application logic. They resolve every color through
  `etaf-rss-color', so the two palettes share one layout.

## Invariants

- **Layout budget.** The model computes the page size and the reading width
  from the window before the app paints, and `:page-size` counts planned rows
  while the reader slices pre-wrapped lines. A resize or a palette change
  re-fits the layout; no glyph may grow a row, because an icon falls back to a
  taller font otherwise. Lines borrowed by an active minibuffer or completion
  popup are not a resize (`etaf-transient-space-borrowed-p'): the reader keeps
  the budget it committed until the prompt closes, like the canvas, which Ebox
  leaves at its committed viewport.
- **Reading width.** The article is wrapped once per article and width; the
  reader only slices the result. `etaf-rss--reader-capacity` takes the share
  the flex row actually gives the reading pane (in a wide frame the sidebar
  first, then an even split with the article list), subtracts the pane's
  insets and a safety column, and `etaf-rss-reading-measure` caps the column,
  so a line is never clipped and prose is not stretched across a wide frame.
- **Retention.** Each feed keeps its newest `etaf-rss-articles-per-feed`
  articles; starred articles beyond that are kept up to
  `etaf-rss-starred-limit`. The store is pruned at write time, so its size is
  bounded by configuration.
- **Identity.** An article ID is the hash of the feed URL and the item's GUID,
  link or title, so read and starred state survives refreshes.
- **Offline purity.** A session created without a client factory talks to the
  service client, but the service only reads the data file and the network on
  request. Tests and benchmarks inject a scripted client and never touch
  either.

## Store schema

One JSON document, written atomically through a neighbour file and a rename:

```
((schema . 1)
 (feeds    . [((id url title site folder updated last_fetch etag
                last_modified error) …)])
 (articles . [((id feed feed-title title url author published added
                summary content read starred) …)])
 (settings . ((theme . "dark"))))
```

Numbers are floats, booleans are JSON booleans, and absent values are null;
`etaf-rss-store--feed-json` / `--article-json` make the mapping explicit
because a nil alist value would serialize as an empty object.

## Known framework interaction

`column` and `row` are simple-axis Ebox layouts: they accept `:item-gap` and
`:cross-align` and reject flex participation on their children. A container
that hosts children with `:flex-grow` / `:flex-shrink` / `:flex-basis` must be
a `flex` with `:flex-direction`; conditional and list-rendered containers
follow the same rule. The views apply this consistently.
