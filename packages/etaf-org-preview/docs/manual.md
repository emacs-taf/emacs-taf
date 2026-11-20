# ETAF Org Preview manual

This manual covers the workflows a reader performs. The root entry's
Commentary owns the supported API inventory; this document links to it instead
of repeating signatures.

## Opening a document

| Entry point | Use |
| --- | --- |
| `M-x etaf-org-preview-open` | Render the Org file at point, or prompt for one |
| `(etaf-org-preview-open PATH)` | Render a known file |
| `etaf-org-preview-create` + `etaf-org-preview-view` | Build a session and mount it inside your own layout |

Opening a file that already has a preview selects that buffer instead of
rendering it twice. The buffer name is `*ETAF Org: NAME*`.

`etaf-org-preview-open` also accepts a session, so an application can build
the document model first and display it later.

Closing with `q` unmounts the runtime, removes the file watch and kills the
buffer.

## Keys

| Key | Action |
| --- | --- |
| `C-c n` / `C-c p` | Next / previous headline (`n` also works) |
| `C-c j` | Choose a headline from the completion list |
| `RET` or click | Activate a link, a footnote or an image |
| `C-c C-o` | Activate the control at point |
| `C-c t` | Show or hide the table of contents |
| `C-c v` | Show or hide comments, properties, drawers and metadata lines |
| `t` | Switch to the next fixed palette |
| `[` / `]` | Narrow / widen the reading measure by four cells |
| `r` | Re-read and repaint the document |
| `C-c h` | Show the effective key bindings |
| `q` | Close the preview |

`TAB`, `S-TAB`, `?`, `SPC`, `DEL`, `C-v`, `M-v`, the wheel and `n`/`q` are
framework-owned keys. An application cannot rebind them; native search, marks,
windows and scrolling work unchanged.

## Headings

Every section heading uses the shared Markdown type ladder. Level 1 is twice
the body, level 2 one and a half times the body, level 3 one and a quarter,
level 4 a little above the body, and deeper levels keep the body size in muted
ink. Levels 1 to 4 use one deep heading blue; deeper levels use the muted ink.
Levels 1 and 2 carry the Markdown rule, and every heading keeps one blank line
above it. No level indents or acts as a fold button: TODO keywords, priority,
tags and planning lines give the rest of the row its shape.

The document title is the largest line, at 2.15 times the body. A 120-section document
mounts in about 257 ms with syntax-coloured code, and an edit repaints only the
block it changed, so a paragraph costs about 28 ms including the painted page. `make benchmark` prints
these numbers with `ORG_PREVIEW_BENCH_SECTIONS` controlling the size; the
registered scenarios in `benchmarks/performance-scenarios.el` cover parse,
mount, edit and refit for the maintained sample.

A document opened from a file follows that file. Saving the source, changing
it on disk, or typing in its buffer without saving repaints after the edit
settles (250 ms for a file write, 300 ms of quiet for a buffer edit) and keeps
the reader in the section it was reading. Closing the source buffer falls back
to the file on disk. `r` reloads on demand, and an unsaved revision is read as
it stands instead of being replaced by the file.

## Syntax coverage

### Document

| Org syntax | Rendering |
| --- | --- |
| `#+TITLE`, `#+SUBTITLE` | Title block |
| `#+AUTHOR`, `#+DATE` | Metadata line; a file session appends the modification time |
| `#+KEYWORDS`, `#+FILETAGS` | Tag chips under the metadata line |
| `#+TODO:`, `#+SEQ_TODO:`, `#+TYP_TODO:` | Keyword set and its state colors |
| `#+PRIORITIES:` | Priority range |
| `#+OPTIONS: toc:n` | Table-of-contents depth; `toc:nil` hides it |
| `#+OPTIONS: tags:nil todo:nil pri:nil` | Hides tags, keywords or priorities |
| `#+STARTUP:` | Ignored by the reader; every normal section opens |
| `#+MACRO:` | Inline macro expansion, including `title`, `author`, `date`, `email` and `input-file` |
| `#+LINK:` | Link abbreviations |
| `#+CAPTION:`, `#+NAME:`, `#+ATTR_*:` | Attached to the next block; the caption renders under it. `:width` and `:height` (pixels or a percentage) cap an image, `:alt` becomes its help text |
| `#+RESULTS:` | A result card |
| `#+INCLUDE:`, `#+CALL:`, dynamic blocks | Cards that name what was not executed |
| `#+TBLFM:` | A grey footnote under its table |
| Other `#+KEY:` lines | Hidden by default, shown with `C-c v` |

A document without `#+TITLE` uses its file name, then the session title.

### Headlines

| Org syntax | Rendering |
| --- | --- |
| `*` … `********` | The Markdown ladder: 2.0, 1.5, 1.25, 1.1, then body size; levels 1 and 2 carry a rule, no indent |
| `TODO`/`DONE`-style keywords | A chip; `NEXT`/`STARTED` read as in progress, `WAIT`/`HOLD` as waiting, `CANCELLED` as dropped |
| `[#A]` priority | A thin outlined chip |
| `:tag:list:` | Right-aligned chips |
| `[2/5]`, `[50%]` cookie | A monospace pill |
| `COMMENT` | A “注释” chip; its body stays out of the reading page |
| `:ARCHIVE:` tag or property | An “归档” chip; its body stays out of the reading page |
| `SCHEDULED:`, `DEADLINE:`, `CLOSED:` | A planning line with written labels and dates |
| `:PROPERTIES:` | A chip with the entry count; `C-c v` shows the properties grid |
| `LOGBOOK` clock entries | A chip with the entry count and total time; `C-c v` also shows the recorded lines |
| Other drawers | A named chip; `C-c v` shows the drawer text, so no content disappears |

### Body

| Org syntax | Rendering |
| --- | --- |
| Paragraph | One wrapped paragraph; adjacent CJK lines join without a space |
| `-`, `+`, `*` lists | A bullet in a marker column just wide enough for the mark plus one cell of air; a nested list starts at its parent’s text column |
| `1.`, `1)` lists | The original marker (`1.` or `1)`), padded to the widest number in the list |
| `[@3]` | Overrides the displayed number of that item only |
| `[ ]`, `[-]`, `[X]` | Three marks: an empty box, a dashed box for a task in progress, and a check |
| `- term :: description` | A bold term on its own line; the definition hangs behind a quiet left rule |
| Tables | A closed grid: header tint, a hairline around the table and between every row and column, compact rows and explicit `|---` rules. Alignment and width cookies, `<n>` minimum widths; a wide cell wraps inside its column instead of overflowing |
| Multi-rule tables `|---` | A hairline at each explicit rule row |
| `#+BEGIN_SRC` | A code card with its language, syntax-coloured through that language's own major mode; the `-n` and `-n 20` switches add a line-number gutter |
| `#+BEGIN_EXAMPLE` | A code card without a language |
| `#+BEGIN_QUOTE` | A quiet card with its attribution line, right-aligned under the quote |
| `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION` | A callout with a written label and its semantic color |
| Other special blocks | A card with the block name |
| `#+BEGIN_CENTER` | Centered content capped at 80% of the measure |
| `#+BEGIN_VERSE` | Line breaks kept |
| `#+BEGIN_COMMENT` | Hidden by default |
| `#+BEGIN_EXPORT` | A card labeled with its backend |
| `# comment` lines | Hidden by default |
| `: fixed width` | Monospace text |
| `-----` | A hairline divider |
| `#+BEGIN_SRC mermaid` | A diagram drawn through mermaid-cli, in the page's colours; its source when the program is absent |
| LaTeX environments and `\[ … \]` / `$$ … $$` | Typeset through KaTeX when mermaid-cli is installed, otherwise centered monospace source with entities substituted |

### Inline

| Org syntax | Rendering |
| --- | --- |
| `*bold*`, `/italic/`, `_underline_`, `+strike+` | The matching face |
| `=verbatim=`, `~code~` | Monospace with a soft background |
| Entities (`\alpha`, `\to`) | Unicode spelling from Org's own table |
| `H_2`, `x^2` | Unicode sub- and superscripts; an unmappable value keeps its marker |
| `[[target][description]]` | An underlined link in the theme's muted link tone, not a raw hyperlink blue |
| Bare URLs | Links |
| Timestamps | Date, Chinese weekday and time; active and inactive differ in color |
| `[fn:1]`, `[fn::text]` | A numbered reference set smaller than the paragraph; the footnote is listed at the end |
| `[cite:@key]`, `[@key]` | Monospace citation text |
| `{{{macro}}}`, `{{{title}}}` | Expanded |
| `src_py{…}` | Monospace with a soft background |
| `@@html:…@@` | Its payload in a neutral source surface; the backend marker is removed and the payload is never interpreted |
| `<<target>>`, `<<<radio>>>` | The definition is a quiet anchor; a reference is link text that jumps to it |
| `\\` | A line break |

## Links

| Target | Activation |
| --- | --- |
| `https:`, `http:`, `mailto:` | System browser or mail client |
| `file:path` | `.org` files open a preview, images and videos open outside Emacs, other files use `find-file` |
| `file:path::*Headline`, `::#custom-id` | Reveal and jump to the anchor in this document |
| `*Headline` | Jump to the headline |
| `#custom-id` | Jump to the section with that `CUSTOM_ID` |
| `id:uuid` | Resolved through Org when it is loaded |
| `attachment:file` | Treated as a file relative to the document |
| `elisp:`, `shell:` and unknown schemes | Reported as not activatable; nothing runs |

The target is centered, and an anchor in another section is reached in place.

## Media

A paragraph that holds a single link to a local image becomes an image card:
the picture is centered, sized from its own pixels and the reading measure,
capped by `etaf-org-preview-image-max-height`, with its `#+CAPTION:` below.
`RET` opens the file.

A local video link becomes a card that names the file and opens it with the
system player. A missing file, or a remote URL, keeps a placeholder card that
shows the path or URL instead of failing.

## Display controls

| Control | Effect |
| --- | --- |
| Palette | `t` cycles `light`, `sepia`, `dark`; `etaf-org-preview-set-theme` accepts `auto` to follow the frame's faces again |
| Reading measure | `[` and `]` change the maximum; a resize refits the measure, a narrower window fills the available columns, and below the preferred minimum the page keeps reflowing instead of scrolling sideways |
| Table of contents | `C-c t`; depth comes from `#+OPTIONS: toc` (default 2) |
| Hidden content | `C-c v` reveals comment lines, comment blocks, property drawers, other drawers, logbook lines and metadata keywords |

`auto` paints no page background, so the preview uses the Emacs theme's own
background. A fixed palette paints its own page, and every surface — chips,
tables, callouts, code cards — comes from the same palette.

## Degraded content and recovery

Parsing never signals on malformed input. An unclosed block ends at the end of
its container, an unknown construct keeps its source text, and every
degradation is counted. When the count is not zero, the title block shows a
“N 处已降级” chip.

Unsupported constructs are shown as source rather than as an error:

- `#+INCLUDE:` is not expanded; the card names the file.
- `#+CALL:` and dynamic blocks are not evaluated; the card says so.
- `#+TBLFM:` is not computed; the formula is a footnote.
- `elisp:` and `shell:` links never run.

## Sessions and scripting

```elisp
(let* ((session (etaf-org-preview-create :file "~/notes.org"
                                         :theme 'dark))
       (state (etaf-org-preview-state session)))
  (plist-get state :counts)   ; (:todo 3 :done 8 :deadline 2 :overdue 1)
  (etaf-org-preview-refresh session))
```

`etaf-org-preview-create` takes `:file` or `:text`, plus optional `:title`,
`:theme` and `:toc`. A read failure signals
`etaf-org-preview-error`; `etaf-org-preview-refresh` keeps the last good
document when a reload fails.

Mount a session yourself with `etaf-org-preview-view`:

```elisp
(etaf-mount buffer (etaf-org-preview-view session)
            '(:viewport-width 900 :viewport-height 50))
```

`etaf-org-preview-locate` jumps to an outline entry, `etaf-org-preview-outline`
returns `(LEVEL TITLE ID TODO TAGS)` rows, and `etaf-org-preview-state` reports
the whole session as detached data.

## Diagnostics

`M-x etaf-org-preview-doctor` reports whether Org and ffmpeg are available.
Ordinary reading, tables and images need neither. Org improves `id:` links and
keyword defaults, ffmpeg
only matters for video previews.
