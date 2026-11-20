# ETAF Slides

ETAF Slides presents a Markdown deck as a slide show inside Emacs. It draws the
deck with [ETAF](https://github.com/emacs-taf/etaf) components and the
[Ebox](https://github.com/emacs-taf/ebox) renderer: an aspect-preserving 16:9
stage fills the window, the slide body renders through ETAF UI's Markdown
renderer, and a footer carries the deck title, the position and the
presentation clock.

## Capabilities

- One Markdown file is the deck. Optional front matter (title, theme, author,
  date), then slides separated by a line of three or more dashes, and the first
  heading of a slide is its title.
- A `::: notes` block holds the speaker notes. `s` shows them in a band above
  the footer, so the notes never cover the slide.
- Three slide layouts: a centered cover for a heading with at most two
  paragraphs, a section divider for a heading alone, and a titled content slide
  whose body is rendered by the shared ETAF UI Markdown renderer (lists, quotes,
  code blocks, tables and local images).
- The stage keeps the 16:9 ratio inside the window and is centered with a
  letterbox; the footer keeps the position and the clock outside the stage.
  A window that is too small reports clipping instead of shrinking the type.
- A slide is read from across a room, so a presentation opens at four text
  scale steps, about twice the frame's body size. `+` and `-` change the size
  and `0` returns to the opening size; the stage re-fits around the bigger
  cells instead of clipping them. Nothing sets a per-node font size, so the
  deck still follows the user's font.
- `o` lists every slide with its notes and overflow markers, `#` jumps to a
  slide number, `+` and `-` resize the type, `t` cycles light, dark and the frame's own appearance, `c`
  starts and stops the clock, `f` toggles fullscreen and `?` lists every key.
- One session, one buffer, one mount: reopening a deck selects the existing
  buffer instead of mounting the same state twice.

## Requirements

- Emacs 29.1 or newer.
- The [ETAF](https://github.com/emacs-taf/etaf),
  [ETAF UI](https://github.com/emacs-taf/etaf-ui), [Ebox](https://github.com/emacs-taf/ebox)
  and [ECSS](https://github.com/emacs-taf/ecss) providers on `load-path`.
  The ETAF package archive at <https://etaf.top/packages/> provides all four.

## Installation

Add this repository root and the provider roots to `load-path`, then:

```elisp
(require 'etaf-slides)
```

With the ETAF archive configured, `M-x etaf-install` installs the application
and its providers from the archive.

## Use

```
M-x etaf-slides-present RET   ; fill the frame and start the clock
M-x etaf-slides-open RET      ; open in the current window, clock stopped
```

A deck is ordinary Markdown:

```markdown
---
title: ETAF 幻灯片
theme: auto
---

# 一套内容，多种投影

ETAF 把 markdown 变成放映现场。

---

## 要点页

- 第一个要点
- 第二个要点

::: notes
这一页的讲稿。
:::
```

`examples/demo.markdown` is a runnable three-slide deck.

## Documentation

- `docs/architecture.md`: module responsibilities, data flow and the layout
  decisions behind the stage and the slide body.
- `CHANGELOG.md`: user-visible changes.

## Development

```sh
make compile        # byte-compile every source with warnings as errors
make check          # structure, compile, public acceptance, API boundary
make test           # the public acceptance scenarios only
```

The acceptance inventory lives in `tests/acceptance.json`; every scenario
drives the application through the interfaces declared in `etaf-slides.el`.
