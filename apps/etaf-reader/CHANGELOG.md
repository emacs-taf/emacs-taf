# Changelog

## Unreleased

### Removed

- `etaf-reader-mode-map` is removed. The reader runs as an ETAF application and declares its keys on its root View; `C-c h` lists them. Keys the reader does not declare fall through to your own bindings, so bind an extra command globally instead.

### Changed

- The library is a three-region shelf: a sidebar with reading-state counts and format and author facets, a reflowing grid of book fronts on shelf boards with a reading meter per book, and a detail panel that previews the shelf cursor. `j`/`k`/`h`/`l` move the cursor, `RET` opens, `d` toggles the panel, and pressing a cover twice opens it. The palettes now come from one Radix sand and indigo scale in every mode, so the shelf, the panels and the paper share one colour system.
- The shelf also lists the library: the toolbar's 网格/列表 switch swaps the grid for a table of author, format, chapters, reading meter and last read time, and the facet chips beside it narrow the shelf by state, format and author with a count on each choice.
- The reading page is one flat surface: the text block is centred with equal margins and carries no fill of its own, and hairlines close the running head and open the status line. The column blocks used to sit on a lighter panel band with hard edges, and a growing spacer put the text against the sidebar.

- The reading view gains a chapter sidebar: the book card, the chapters around the current one with it marked, and a reading progress line. `d` toggles the sidebar while reading and the detail panel on the shelf, so one key covers whichever view is open; narrow windows drop the sidebar instead of squeezing the page.

- The detail panel previews the cursor book's annotations: a 标注 section counts them and quotes the first three, reading them outside the render pass.

- `etaf-reader-close` closes the open reader from any buffer, and killing the reader buffer directly also saves the reading position.

- `?`, `C-c h` and More → Shortcuts share a searchable, read-only help modal inside the reader. Effective bindings supply its short labels; Escape or an outside click closes it and restores focus.
- `etaf-reader-show-pane` with `help` now opens that modal without setting `:pane` to `help`; it requires a mounted session. Use `etaf-help-close` to close help alone, or pass nil to `etaf-reader-show-pane` to close all panes.

### Fixed

- Pages turn when the shown or the next page holds a chapter picture. The page turn used to stop with `Unknown committed Host reader-column-1`.
- The arrow keys turn pages and extend a keyboard selection wherever point rests. They used to reach the page only with point inside the text body, and otherwise moved focus to a toolbar control.
- `t` repaints the cells beyond the page in the new theme instead of keeping the theme the reader opened with.
- The minibuffer and echo area borrow window lines without shrinking the shelf or the reading metrics: the reader keeps the layout it committed until the prompt closes.
- Switching books saves the previous position before replacing book identity; replacing a mounted session releases its old progress timer and bindings.
- Application shortcuts remain active while a toolbar control is focused. Library search no longer leaves the canvas horizontally scrolled, and blank metadata titles fall back to the file name.
- The reader no longer touches the store while ETAF renders: the shelf View reads cached rows, and store work happens before mounting.
- `SPC`, `DEL`, the page keys, `n`, `q`, `RET` and the wheel are no longer shadowed by the renderer's minor-mode map; `RET` confirms a selection or activates the focused control, and `H`/`L` move between chapters.
- Line kinds are real symbols (`body`, `heading`, `quote`, `pre`), so headings render bold, quotes get their bar, and the page-turn fast path can classify a window.
- Final partial pages clear unused rows instead of keeping stale text. Source coordinates follow their text across both columns; selection no longer mistakes physical buffer rows for chapter lines.
- Reading columns leave space for the footer, and light/sepia text uses the matching foreground. Deferred progress saves retain their originating store.
- Opening a book whose parser found no chapter no longer fails with a data controller error: the import writes no chapter row and the reader reports that the book has nothing to read.

### Performance

- Opening a long book writes all chapters as one batch per table instead of one Controller mutation per row: a synthetic 1000-chapter import dropped from 7.7 s to 0.064 s, and a 1692-chapter 28 MB EPUB imported end to end in 5.6 s in a GUI session (extraction included).

- Heading and annotated pages now use retained content updates too: each column is one styled text Host, rather than a subtree per line/segment. Selection toolbars temporarily restore line anchors. This removes the unconditional whole-view fallback for styled pages; latency must still be verified with the maintained keyboard workload on the target display.

### Changed

- Reading settings, the shortcut help and content panels open over the reading surface with the shared modal backdrop: the page stays visible and dimmed instead of losing its background, and closing restores it.

### Added

- A reading toolbar, paper-like columns and comfortable paragraph spacing. Reading settings persist palette, mode, column width and paragraph density.
- Searchable, sorted and paged library views with cached cover thumbnails and reading-state filters. Long contents, notes, search and bookmark lists have page controls; bookmarks can be removed and navigation jumps can be undone.
- A maintained native GUI workflow covering a real local book, library search, settings, bookmarks, selection, highlighting and the Markdown export prompt, plus a four-size layout scenario.
- Local ebook reader application: shelf, library scan and import through the `ebook-parse` skill, SQLite storage through ETAF DB, paged and scrolling reading layout, dark/light/sepia palettes, adjustable reading width.
- Text selection with the mouse or a keyboard selection mode and a floating toolbar for highlight, straight underline, wavy underline, thoughts, copy, search and delete; annotations anchor on chapter text offsets.
- Table of contents, notes pane, in-book search, bookmarks, percentage jumps, per-book reading progress with reading time and Markdown note export.
- Public session API (`etaf-reader-create`, `etaf-reader-open-book`, `etaf-reader-state`) that works without a buffer, plus a replaceable parser contract for tests and other frontends.
