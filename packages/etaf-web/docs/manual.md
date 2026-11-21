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
  matter `title`, that leading `<h1>` is omitted while later `<h1>` headings in
  the body are kept.
- For an image `<figure>` with a `<figcaption>`, the caption's plain text
  becomes the image's alt text and no separate caption paragraph is emitted;
  without `<figcaption>`, the image keeps its original `alt`.

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

All user-facing failures signal `etaf-web-error`:

- Non-string HTML input or an Emacs build lacking libxml support.
- Unreadable or missing local HTML files.
- Network timeouts or HTTP 4xx/5xx responses when fetching a page.

To force a fresh fetch of a cached URL, remove its directory under
`etaf-web-cache-directory`.
