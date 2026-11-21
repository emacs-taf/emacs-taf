# ETAF Web Manual

This manual covers how to browse web pages and local HTML documents with
`etaf-web`, how asynchronous loading and caching work, and how HTML compiles
into `etaf-md` intermediate language.  The root entry [etaf-web.el](../etaf-web.el)
Commentary is the authoritative public API inventory.

## Browsing pages

Call `M-x etaf-web-open` (or invoke `etaf-web-open` from Lisp) with an
`http://` / `https://` URL, a `file://` URL, or a local HTML file path:

```elisp
(let ((buf (etaf-web-open "/path/to/article.html")))
  (with-current-buffer buf
    (etaf-web-close)))
```

Every call creates its own browser buffer named `*Web: <host>*`, so multiple
pages can remain open side by side.  Pass a non-nil `other-window` argument
(or prefix argument `C-u`) to display the buffer in another window.

The browser shell inherits the active Emacs theme's frame background (no tinted
chrome panels, no input box fill, and no bottom footer bar).  A single
constant-height `1lh` top bar separated by a thin hairline renders, from left
to right: fixed-width actions (`后退`, `前进`, `刷新`, switching to `停止` with
the same width during loading; disabled items stay muted so layout never
shifts), the full URL always including `https://` (muted scheme, bold host,
muted path; editable inline in-place without changing row height), and a
right-hand text status slot (`渲染中 38% · 2.4s` while loading, `缓存` or empty
when ready, `失败` on error).  No second progress row or in-tab transition
banner is inserted, so vertical height never jitters.  On narrow windows
(`< 72ch`), the three actions fold to single-cell glyphs (`‹ › ⟳`, or `×` while
loading), the URL middle-truncates its path while keeping scheme and host, the
right status shows only percentage, and the reading column fills `window - 4ch`
down to a `36ch` floor (minimum usable viewport `44ch × 14lh`, clipping or
scrolling below that without shrinking type size).

### Keyboard navigation

All commands are bound through the root Host's `:keys` and appear in `?`:

| Key | Command | Action |
| --- | --- | --- |
| `M-<left>` / `B` | `etaf-web-back` | Go back in history and restore scroll position |
| `M-<right>` / `F` | `etaf-web-forward` | Go forward in history and restore scroll position |
| `r` | `etaf-web-reload` | Re-fetch and recompile current page bypassing cache |
| `x` | `etaf-web-stop` | Cancel in-flight fetch or headless render |
| `g` / `C-l` | `etaf-web-focus-address` | Edit address bar inline with URL history completion |
| `o` | `etaf-web-open-external` | Open current URL in the external system browser |
| `n` / `p` / `C-c j` | heading navigation | Jump to next, previous or chosen outline heading |
| `t` / `[` / `]` | theme & width | Cycle palette or adjust reading column width |
| `?` / `C-c h` | `etaf-help` | Show buffer key bindings |
| `q` | `etaf-web-close` | Cancel active loads and close the browser buffer |

Activating an `http://` or `https://` link inside a page navigates within the
browser buffer (pushing onto its history stack); `#anchor` links jump to the
matching heading in-document; `browser:` links hand off to `browse-url`.

Inspect a buffer's current browser state from Lisp via `(etaf-web-state &optional buffer)`.

## Pure compilation

`etaf-web-to-markdown` converts an HTML string directly into `etaf-md`
intermediate language text without touching the disk or network:

```elisp
(etaf-web-to-markdown
 "<article><h1>Notes</h1><p>Read <a href=\"guide.html\">the guide</a>.</p></article>"
 :base-url "https://example.com/docs/index.html")
```

Universal compilation and layout recovery rules:

- Hidden and non-document overlays are pruned: inline `display: none` /
  `visibility: hidden` (except `role="tabpanel"` so inactive docs tabs stay
  intact), ARIA `tooltip` / `menu` / `dialog` / `alertdialog`, short
  non-`<form>` search bars containing `<input type="text|search">`, and
  punctuation/pipe-only leaf blocks (`|`, `·`, `/`).
- If the first content block is an `<h1>` whose plain text matches the front
  matter `title` (exact match, after stripping common site suffixes such as
  ` - Site` / ` | Site`, or as a prefix), that leading `<h1>` is omitted while
  later `<h1>` headings in the body are kept.
- ISO 8601 and numeric dates in metadata are normalized to `YYYY-MM-DD`;
  unrecognized date formats are kept verbatim.
- Lazy-loaded images prefer `data-src`, `data-original`, `data-lazy-src`,
  `data-actualsrc`, `data-original-src` and `data-url` (plus the widest
  candidate in `data-srcset` / `srcset`) before falling back to `src`.
- Standalone images declaring bounded CSS pixel dimensions (`<= 480` px via
  `width`/`height` attributes or inline `style` `width`/`height`/`max-width`/
  `max-height`) emit standard HTML `<img src="..." alt="..." width="..."
  height="...">` blocks so icons, avatars and Retina thumbnails render at
  their intended page size in `etaf-md`.  Tracking pixels (`<= 4` px) and
  empty-alt decorative inline images are dropped.  Consecutive runs of inline
  badge images degrade to `alt` text joined with ` · `.  Private-use glyphs
  (`U+E000–U+F8FF`) and variation selectors (`U+FE0E`/`U+FE0F`) are stripped
  while standard Unicode emoji in prose stay intact.
- Primary content extraction uses semantic landmarks (`<article>` / `<main>`),
  bottom-up Readability-style prose scoring with continuous link-density
  weighting, structural wrapper tightening, interactive `<form>` widget and
  orphan-heading pruning, and layout-table unwrapping (while preserving real
  data tables with `<th>` / `<thead>`).
- Consecutive 2–6 short single-line metadata siblings (`<= 24` chars, non-heading/
  code/image, outside `:::card`) merge into one `项1 · 项2 · 项3` line.
- Repeated homogeneous entry streams (`>= 3` compact same-tag entries each
  carrying a primary title link) compile to `### [标题](url)`, unwrapped
  plain-prose summary, single-line metadata, and `---` separators.
- Structured page layouts preserve their visual structure using `etaf-md`
  containers: card grids (`:::columns` + `:::col` + `:::card`), documentation
  tabs (`:::tabs` + `@tab`), numbered steps (`:::steps` + `:::step`), and
  timelines (`:::timeline` + `:::event`, gated so entries require `<time>` or
  substantive `> 15`-char text rather than counter/action bars).

## Asynchronous loading and script-driven pages

`etaf-web-open` returns the browser buffer immediately while HTTP fetching,
optional headless Chromium rendering, and background image caching run
asynchronously without blocking Emacs:

1. **Text-first pipeline**: HTML is fetched asynchronously (via `curl` under
   `etaf-process-run`, falling back to async `url-retrieve`), compiled, and
   displayed immediately while remote images download concurrently in the
   background and refresh the buffer in place when saved.
2. **Retained progress updates**: Stage progress (`抓取中 → 渲染中 → 编译中 → 完成`)
   and elapsed time update via retained Host span patching without triggering
   full-page rerenders.
3. **Cancellation**: Pressing `x` or calling `etaf-web-stop` (or closing the
   buffer with `q`) cancels active fetch, Chromium render and image jobs
   without leaving orphan processes.

When a page's initial HTML carries `<script>` tags and yields no prose of its
own, `etaf-web-open` renders it asynchronously through a headless Chromium
browser (`--blink-settings=imagesEnabled=false --virtual-time-budget=3000`
with a private temporary `--user-data-dir` and shared disk cache).

```elisp
(setq etaf-web-render-command "/Applications/Chromium.app/Contents/MacOS/Chromium")
```

`etaf-web-render-command` defaults to `nil` (auto-detect), `off` skips
rendering, and a string names an executable.  `etaf-web-render-timeout`
(default 25 seconds) bounds the render wait.  When no browser is available or
rendering still yields no prose, the page displays an explanatory notice with
a `browser:` link to open in the external browser.

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

Opening the same HTTP(S) URL again renders the cached `index.md` immediately
without refetching the page, and retries any missing remote images in the
background.  Press `r` (`etaf-web-reload`) to bypass cache and fetch fresh
HTML.  Hard safety caps always apply: 5 MB per image and 30 images per page.

## Errors and recovery

`etaf-web-fetch-timeout` controls the HTTP(S) fetch timeout in seconds
(default `30`, integer or float).

- **Synchronous `etaf-web-error`** is signaled to Lisp callers for invalid
  inputs (non-string HTML to `etaf-web-to-markdown`, empty/invalid source to
  `etaf-web-open`), missing libxml support, and missing or unreadable local
  HTML files.
- **In-page error card**: Asynchronous network, timeout (`Timed out after <N>s`),
  HTTP status (`HTTP <status>`), and user-cancelled failures render a readable
  error card inside the browser buffer displaying the cause, target URL, and
  interactive **重试 (r)**, **外部浏览器 (o)**, **返回上页 (←)**, and
  **查看旧缓存** actions.
