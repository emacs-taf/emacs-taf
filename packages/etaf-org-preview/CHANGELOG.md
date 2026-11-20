# Changelog

## 0.3.1

### Changed

- Tables are a closed grid again: a hairline around the table and between every
  row and column, a header tint and explicit `|---` rules. The rows no longer
  reserve a blank line above each cell, and the grid uses its own visible
  border token in every palette.
- Links use a muted link token derived from the reader's own link color, and an
  inline code or export snippet gets a neutral surface. The raw hyperlink blue
  is no longer painted across paragraph text.
- Chips and code cards have square edges, so they keep the ETAF square box
  model.
- A `CAUTION` callout reads “小心”, distinct from `WARNING`; a quote attribution
  sits on its own right-aligned line under the quote.
- List items keep their one-cell marker gap and gain a small vertical margin.
- Source blocks are syntax-coloured through the same font-lock highlighter the
  Markdown preview uses, so keywords, strings, functions and comments read the
  same in both views. A logbook that opens a section body is summarised as a
  chip instead of falling through as an unknown drawer.

## 0.3.0

### Changed

- Headlines use the shared Markdown type ladder: level 1 is twice the body,
  level 2 one and a half, level 3 one and a quarter, level 4 a little above the
  body, and deeper levels keep the body size in muted ink. Levels 1 to 4 use a
  deep heading blue, the document title sits above the ladder at 2.15 times the
  body, levels 1 and 2 carry the Markdown rule, and every heading keeps one
  blank line above it; no level indents.
- A headline is no longer a fold control. The chevron, `C-c TAB`, `C-c f` and
  the initial `#+STARTUP:` fold state are gone; every ordinary section is
  rendered in place. `COMMENT` and `:ARCHIVE:`
  bodies remain out of the reading page, with their markers visible.
- Lists are tighter: the marker column is only as wide as the widest mark plus
  one cell, a checkbox has its own cell, nested lists start at the parent's
  text column, and description terms sit on their own line above a quiet rule.
- Tables use one compact body row with a header tint, a header rule, hairline
  column rules and explicit `|---` rules. The outer frame and the rules between
  body rows are gone.

### Fixed

- A LaTeX environment is unwrapped before KaTeX sees it, so `equation`,
  `aligned` and `align` no longer draw their own `\begin`/`\end` text on top of
  the formula.
- Mermaid uses the reader's first font with a CJK fallback stack and one font
  size across diagram kinds, instead of fixed 12px labels beside 14px actors.
- An inline `src_LANG{...}` snippet renders its code instead of its marker.

## 0.2.2

### Fixed

- A list mark no longer reserves a wide fixed column: the marker column fits
  the widest number in its list plus one cell, so a bullet or checkbox sits one
  space from its text, and a two-digit number still lines up with a one-digit
  one.
- A parenthesized ordered list keeps `1)` instead of turning into `1.`, and an
  item counter `[@3]` changes only its own number.
- A nested list starts at its parent's text column instead of adding a second
  fixed indent.

### Changed

- Description lists put the bold term on its own line and hang the definition
  behind a quiet left rule, matching the shared Markdown glossary layout.
- Tables drop the outer frame and the rules between body rows.  A header tint,
  one rule under the header, hairline rules between columns and explicit
  `|---` rule rows remain, so the table reads as columns instead of a
  spreadsheet.

## 0.2.1

### Fixed

- The manual's performance baseline named the pre-0.2.0 mount and edit costs.
  It now states the measured 72 ms outline mount, 170 ms full mount and 26 ms
  paragraph edit.

## 0.2.0

### Added

- Display formulas (`$$…$$`, `\[…\]`, LaTeX environments) are typeset through
  KaTeX and `mermaid` source blocks are drawn through mermaid-cli, each in the
  page's own colours and cached by source, palette and body size.  A page never
  waits for a program; a finished picture repaints only its block.  Without
  mermaid-cli both keep their source, controlled by `etaf-org-preview-typeset`.
- A displayed preview follows unsaved edits in its source buffer: typing
  repaints after 300 ms of quiet, saving and external writes keep working, and
  closing the source buffer falls back to the file on disk.

### Changed

- Publishing is keyed by block content.  An unchanged block keeps its Component
  instance, so an edit repaints only the changed block and the sections on its
  path instead of the document.  The rendering environment is cached from
  reactive inputs and no longer reads the document, so palette and width
  changes do not re-render every block.
- Mounting the 120-section benchmark fell from 354 ms to 170 ms, and editing one
  paragraph and repainting it costs about 26 ms instead of a full refresh.

## 0.1.1

### Fixed

- An unknown drawer is no longer dropped: it keeps a named chip, and `C-c v`
  reveals its text. `C-c v` also reveals the recorded `LOGBOOK` lines and now
  reaches comment blocks and metadata in section bodies, which previously
  ignored the toggle.
- Radio targets (`<<<name>>>`) and target references (`<<name>>`) render as an
  anchor and a link that jumps to the defining section, instead of leaking the
  raw markers. `#+NAME:` targets join the same table.
- Inline export snippets show their payload in source style without the
  `@@backend:` markers, and a payload is never interpreted.

### Added

- `#+ATTR_*:` `:width` and `:height` cap an image in pixels or as a percentage
  of the reading measure while keeping its aspect ratio; `:alt` becomes the
  image's help text.
- A source block with the `-n` or `-n 20` switch renders an aligned line-number
  gutter whose width follows the last number.

## 0.1.0

First release.

### Added

- An Org reading view in ETAF: centered reading measure, typographic headline
  ladder, keyword, priority, tag and statistics chips, planning lines, property
  and logbook chips, footnotes and a table of contents.
- Org syntax coverage for headlines, nested and description lists, checkboxes,
  tables with alignment and width cookies, source, example, fixed-width, quote,
  verse, center, comment and export blocks, callouts, entities, sub- and
  superscripts, timestamps, citations, macros, targets, links and layout
  keywords.
- Structural folding: `C-c TAB` cycles folded, children and open; `C-c f`
  switches between the outline and the full document. A closed section is not
  rendered at all, so a large file opens as an outline.
- A preview opened from a file follows it: saving or changing the file on disk
  repaints the document and keeps the reader in the same section.
- `auto`, `dark`, `light` and `sepia` palettes; `auto` derives every surface
  from the frame's own faces, and a fixed palette paints its own page.
- Headless sessions: `etaf-org-preview-create`, `etaf-org-preview-view`,
  `etaf-org-preview-state`, `etaf-org-preview-outline`,
  `etaf-org-preview-locate`, `etaf-org-preview-fold`,
  `etaf-org-preview-fold-all`, `etaf-org-preview-set-theme`,
  `etaf-org-preview-show-toc` and `etaf-org-preview-show-hidden`.
- Degraded rather than failing input: an unclosed block, an unevaluated block
  or an unknown construct keeps its source text and is counted in the title
  block.
