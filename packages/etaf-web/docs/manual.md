# ETAF Web Manual

This manual covers how to open web pages and local HTML documents with
`etaf-web`, how the cache is laid out, and how compilation behaves on common
HTML constructs.  The root entry [etaf-web.el](../etaf-web.el) Commentary is
the authoritative public API inventory.

## Opening pages

Call `M-x etaf-web-open` (or invoke `etaf-web-open` from Lisp) with an
`http://` / `https://` URL, a `file://` URL, or a local HTML file path:

```elisp
(let ((buf (etaf-web-open "/path/to/article.html")))
  (with-current-buffer buf
    (etaf-md-close)))
```

Pass a non-nil `other-window` argument (or prefix argument `C-u`) to display
the preview in another window.  The buffer uses `etaf-md`'s standard reading
keys (`n`/`p`, `C-c j`, `t`, `[`/`]`, `?`, `q`).  Activating an `http://` or
`https://` link inside the page opens the target through `etaf-web-open`;
`#anchor` links jump in-document via `etaf-md`.

## Pure compilation

`etaf-web-to-markdown` converts an HTML string directly into `etaf-md`
intermediate language text without touching the disk or network:

```elisp
(etaf-web-to-markdown
 "<article><h1>Notes</h1><p>Read <a href=\"guide.html\">the guide</a>.</p></article>"
 :base-url "https://example.com/docs/index.html")
```

To avoid duplicate headings and captions when rendered by `etaf-md`:

- If the first content block is an `<h1>` whose plain text matches the front
  matter `title` (exact match, after stripping common site suffixes such as
  ` - Site` / ` | Site`, or as a prefix), that leading `<h1>` is omitted while
  later `<h1>` headings in the body are kept.
- ISO 8601 and numeric dates in metadata are normalized to `YYYY-MM-DD`;
  unrecognized date formats are kept verbatim.
- Lazy-loaded images prefer `data-src`, `data-original`, `data-lazy-src`,
  `data-actualsrc`, `data-original-src` and `data-url` (plus the widest
  candidate in `data-srcset` / `srcset`) before falling back to `src`.
- For an image `<figure>` with a `<figcaption>`, the caption's plain text
  becomes the image's alt text and no separate caption paragraph is emitted;
  for plain images without `<figcaption>`, alt text longer than 60 characters
  or identical to the document title is omitted.
- Structured page layouts preserve their visual structure using `etaf-md`
  containers instead of flattening to single-column prose:
  - Card grids (by grid/card/feature/gallery/tile/catalog class, inline
    `grid-template-columns`, or 2–6 homogeneous titled siblings with compact
    bodies) compile to responsive `:::columns {columns="..." min-width="22ch"
    divider=false}` blocks holding `:::col` + `:::card` entries, with 5+ cards
    split into 3-column batches (e.g. 5 into 3+2).  Decorative 1–3 digit
    leading ordinal paragraphs inside cards (such as `01`) are stripped while
    numeric paragraphs in normal prose stay intact.  Consecutive paragraphs,
    ordinary lists, code blocks and single-child wrappers stay flat.
  - Documentation tabs (`role="tablist"` + `role="tabpanel"` or `tabs` /
    `tab-list` / `code-tabs` classes) compile to `:::tabs` with `@tab
    {title="..." [selected=true]}` entries while keeping inactive `hidden`
    panels intact.
  - Numbered `steps` / `stepper` / `how-it-works` containers compile to
    `:::steps {list-style="decimal"}` (`:::step`), and `timeline` containers
    compile to `:::timeline` (`:::event` with optional `time`).

## Cache layout and image limits

`etaf-web-open` stores compiled pages under `etaf-web-cache-directory` (default
`~/.cache/etaf-web/`):

```text
<cache>/pages/<sha1(canonical-url + compiler-version)>/
  index.md       Compiled Markdown + ::: containers
  source.html    Decoded HTML snapshot
  meta.json      URL, UTC fetch timestamp, title, ETag, compiler version
  assets/        Cached images (<sha1(image-url)>.<ext>)
```

Opening the same HTTP(S) URL again renders the existing `index.md` directly
without refetching.

When `etaf-web-download-images` is non-nil (the default), `etaf-web-open`
downloads images into `assets/` and rewrites their URLs in `index.md` to
relative `assets/...` paths.  Hard safety caps apply: images larger than 5 MB
are skipped, and at most 30 images are downloaded per page.  Any failed or
skipped image keeps its remote URL so `etaf-md` displays a placeholder card
without aborting the page.  Set `etaf-web-download-images` to `nil` to disable
image downloads entirely.

## Errors and recovery

`etaf-web-fetch-timeout` controls the synchronous HTTP(S) fetch timeout in
seconds (default `30`, integer or float).

All user-facing failures signal `etaf-web-error` with distinct diagnostics:

- Non-string HTML input or an Emacs build lacking libxml support.
- Unreadable or missing local HTML files.
- HTTP error responses (`HTTP <status> ...`, e.g. 403/404/500), fetch timeouts
  (`Timed out after <N>s ...`), and connection failures (`Connection failed ...`).

To force a fresh fetch of a cached URL, remove its directory under
`etaf-web-cache-directory`.
