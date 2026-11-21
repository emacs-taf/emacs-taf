# ETAF Markdown Preview manual

This manual covers the workflows a reader performs. The root entry's
Commentary owns the supported API inventory; this document links to it instead
of repeating signatures.

## Keys

| Key | Action |
| --- | --- |
| `n` / `p` | Move to the next / previous heading of the document |
| `C-c j` | Choose a heading from a completion list |
| `RET`, mouse-1 | Activate the link or image under point; play or pause a video |
| `r` | Re-read the file and repaint |
| `t` | Cycle the palette (dark, light, sepia) |
| `[` / `]` | Narrow / widen the maximum reading measure by four columns |
| `?`, `C-c h` | Search the current key bindings in an in-buffer help modal |
| `q` | Unmount the preview and kill its buffer |
| `C-s`, `C-v`, `M-v`, wheel | Native isearch and scrolling |

The buffer is an ordinary Emacs buffer, so isearch, `occur`, window splitting,
`C-x C-s`-style buffer handling and `imenu` all keep working. `M-x imenu`
lists the document outline. Help stays in the preview window and follows its
theme. `/` searches; Escape first leaves search editing, then closes help.
Clicking outside the panel also closes it and restores the reading focus.

## Supported Markdown

The parser covers CommonMark blocks and inlines plus the GitHub extensions a
preview needs:

- Headings: ATX (`#` … `######`) and Setext (`===`, `---`), with stable
  anchors used by tables of contents and `#fragment` links.
- Paragraphs with emphasis, strong emphasis, strikethrough, inline code,
  links (inline, reference and shortcut), autolinks and raw inline HTML
  (rendered literally).
- Fenced code blocks with an info string (shown as a language tag) and
  indented code blocks; long lines wrap so no code is hidden.
- Blockquotes, nested ordered and unordered lists, and task list items
  (`- [x]`, `- [ ]`).
- Pipe tables with left, center and right alignment, drawn as a full grid
  with an outer frame, row and column separators and a header rule.
- GitHub alerts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`,
  `[!CAUTION]`) rendered as titled callout blocks.
- Thematic breaks, character references, backslash escapes and hard line
  breaks.
- Footnotes: `[^label]` references render numbered and definitions collect at
  the end of the document; activating a reference jumps to its definition.
- YAML front matter is removed from the body; its `title` becomes the document
  title and its author, date, version, license and status keys render in a
  title area at the top of the document.

Emoji short codes such as `:smile:` are drawn as their character.

Beside markdown, a document may write containers: `:::name {attrs}` around a
block of markdown, and `@tab` markers inside a container that owns them.  A
container is a documentation shape — a callout, a card, a set of tabs, a
timeline, a file tree, a table with highlighted rows — and the vocabulary,
its attributes and how to add your own are in
[the extension syntax](extensions.md).

`etaf-md-create` selects the dialect with its `:flavor` argument:
`gfm` (the default) enables the GitHub extensions and front matter,
`commonmark` parses the core specification only, and a feature plist such as
`(:tables t :task-lists nil)` toggles individual extensions.

Image syntax and HTML `<img>` / `<video>` tags render as media cards. Relative paths resolve against the document's directory. A local image
renders through ETAF's image Host; a local video starts as a still poster
(its first frame through the image Host) and RET (or a click) mounts the
native video Component to play it in place. Further presses on the playing
card toggle play/pause without leaving Emacs. Without ffmpeg on `exec-path`
the card keeps the poster and RET opens the video in the operating system's
default player.
Remote images render a labeled placeholder whose activation
opens the URL. A missing or unreadable file renders a placeholder card, never
an error.

## Theming and layout

`etaf-md-theme` chooses the document's colors. The default `auto`
derives them from the active frame's own faces: the page keeps the Emacs
theme's background, muted text follows `shadow`, headings `outline-1`, links
`link`, callouts `success`/`warning`/`error`, and panel surfaces (code blocks,
table headers and stripes, rules) are small blends of the frame's background
toward its foreground. The preview therefore matches whatever Emacs theme is
active without painting a page background of its own. The fixed `dark`,
`light` and `sepia` palettes remain available when a self-contained page is
wanted: selecting one paints its page background. `t` cycles the fixed
palettes, `etaf-md-set-theme` pins one, and the resulting colors are
published as `:ui-*` theme tokens, so shared ETAF UI components used inside
the preview follow them.

The reading measure is capped and centered in the window. The session stores a
maximum; the column stretches to the window and never exceeds it, so a narrow
window fills the available columns. The column keeps a two-cell gutter on each
side outside the measure, so the text never starts or ends on the window edge
and a table's border stays off the column where the renderer extends the last
cell's paint across the window's sub-cell remainder. `[` and `]` adjust the
maximum manually in both directions, and the result is clamped between
`etaf-md-width-min` and `etaf-md-width-max`. A window resize
reflows through the renderer's viewport update rather than rebuilding the
document, and because the preview publishes into one buffer, resizing never
restarts the session.

The narrowest useful window is the minimum measure plus the two gutters, about
44 columns. Below that a block that cannot shrink to the measure, such as a
table whose columns must keep their words whole, is clipped at the measure
instead of painting over the gutter; text still wraps and the page keeps its
layout.

## Following the source

An opened preview follows its source buffer: each edit repaints the document
on the next frame, about 16 ms later, so a typing hand sees the render change
as it types. A burst of keys coalesces into one repaint per frame, and a save
or an outside write takes the same path. Each top-level block is published as its own
Component, keyed by its type and source text, so a repaint renders the block
that changed and keeps every other block's rendered output, video handles and
reading position. Inserting or removing a block re-renders the blocks after
it, because their position changed; typing inside a block never does.

## Customization

Four options cover the supported personalization; every other appearance
decision follows the document and the frame.

| Option | Default | Effect |
| --- | --- | --- |
| `etaf-md-theme` | `auto` | Initial palette; `auto` derives the colors from the Emacs theme's faces and paints no page background. |
| `etaf-md-flavor` | `gfm` | Default Markdown dialect when `etaf-md-create` gets no `:flavor`. |
| `etaf-md-width-min` | `40` | Narrowest reading measure, in character cells. |
| `etaf-md-width-max` | `96` | Widest reading measure; a wider window keeps it and centers the column. |

## Scripting and headless use

`etaf-md-create` builds a session from a file or from text without any
buffer; `etaf-md-view` returns the mountable view; `etaf-md-state`
reports a detached snapshot. A session created from text is a complete
headless preview, which is what the acceptance tests use:

```elisp
(let* ((session (etaf-md-create :text "# Notes\n\n**bold** body.\n"))
       (buffer (etaf-md-open session)))
  (etaf-md-locate session 0)
  (etaf-md-set-theme session 'sepia)
  (etaf-md-refresh session)
  (with-current-buffer buffer (etaf-md-close)))
```

`etaf-md-open` accepts a file path or a session, so callers can render
a document they built themselves. `etaf-md-locate` moves point to an
outline index; `etaf-md-outline` returns the outline itself.

### Intercepting links and media

Applications embedding a markdown view can supply `:on-link` and `:on-media`
to `etaf-md-create` to take over link or media activation. Both callbacks
follow the same convention: returning a non-nil value marks the activation
handled, while returning `nil` falls back to the built-in behavior (in-document
anchor jump, browser/file opening, or inline video playback). `:on-link`
receives `(URL)`; `:on-media` receives `(KIND PATH)`, where `KIND` is the
symbol `image` or `video` and `PATH` is the resolved local file path or remote
URL:

```elisp
(let* ((session
        (etaf-md-create
         :text "Read [guide](https://example.com/guide) or ![shot](shot.png).\n"
         :on-link (lambda (url)
                    (when (string-prefix-p "https://example.com/" url)
                      (message "Handled in app: %s" url)
                      t))
         :on-media (lambda (kind path)
                     (when (eq kind 'image)
                       (message "Open image viewer for %s" path)
                       t))))
       (buffer (etaf-md-open session)))
  (with-current-buffer buffer (etaf-md-close)))
```

`scripts/etaf-md-gui-probe.el` drives a live frame for GUI verification: it
opens a document at a given frame size, reports one-line state, sends real
keys and checks layout invariants (no over-wide line, an interactive link, an
outline).

## Troubleshooting

- **A heading jump lands on the wrong occurrence.** Heading navigation finds
  the rendered heading text at the start of a buffer line, in outline order.
  Two headings with identical text are matched in order; an unusual document
  whose paragraph starts with the same text at line start may be matched
  first.
- **An image shows dots or a colored block grid.** The frame has no usable
  graphics support for that file, so Ebox fell back to its terminal
  converters; install ffmpeg for better terminal rendering, or view the file
  in a graphical frame.
- **A video opens in the system player instead of playing inline.** ffmpeg is
  not available on `exec-path`, so the card keeps its poster fallback.
- **RET on a finished video restarts it from the beginning.** A completed
  video has no paused state left to resume, so the next press replays it. The
  last frame stays on the canvas until then, and a short clip may have ended
  before the next press.
- **Theme changes do not repaint shared components.** The preview publishes
  its palette for its own subtree only; a surrounding application keeps its
  own theme context.
