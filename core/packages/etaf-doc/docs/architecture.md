# etaf-doc Architecture

`etaf-doc` is the shared document engine layer for ETAF document applications (`etaf-md`, `etaf-org`, `etaf-web`, `etaf-manual`, `etaf-translate`), keeping `etaf-ui` focused on general-purpose UI controls and eliminating duplicated infrastructure between Markdown and Org readers.

## Module Layers

| Module | Responsibility |
| --- | --- |
| `lisp/etaf-doc-markdown-parse.el` | CommonMark / GFM / ETAF Markdown block and inline parser |
| `lisp/etaf-doc-highlight.el` | Syntax highlighting across major modes and built-in lexers |
| `lisp/etaf-doc-markdown.el` | Markdown AST to ETAF View block/inline renderer |
| `lisp/etaf-doc-cache.el` | Bounded LRU disk pruning and async HTTP(S) remote image cache |
| `lisp/etaf-doc-qrcode.el` | Asynchronous `qrencode` PNG generator and cache attachment |
| `lisp/etaf-doc-typeset.el` | Shared QuickJS (`etaf-md-typeset-native`) worker for Mermaid and MathJax SVGs |
| `lisp/etaf-doc-assets.el` | Local-file resolution, traversal guard, CSV/JSON parsing and project tree helpers |
| `lisp/etaf-doc-protocol.el` | Unified document node contract, attribute type conversion and selector style rules |
| `lisp/etaf-doc-widgets.el` | Shared editorial block widgets (card, callout, metric, progress, charts, code frame) |
