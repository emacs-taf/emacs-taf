# ETAF Org Preview architecture

## Module layout

| File | Responsibility |
| --- | --- |
| `etaf-org-preview.el` | Package entry: public API inventory, feature closure, `lisp/` load-path bootstrap, doctor. |
| `lisp/etaf-org-preview-entities.el` | Entity names to Unicode, plus the sub- and superscript tables. Generated from `org-entities` by `scripts/generate-entities.el`; never edited by hand. |
| `lisp/etaf-org-preview-parse.el` | Pure parser: text to a document tree. No file access, no buffer, no frame. |
| `lisp/etaf-org-preview-theme.el` | Fixed palettes, face-derived palette, heading contrast rule, ETAF UI token bridge. |
| `lisp/etaf-org-preview-model.el` | Session state: load, parse errors, section cells, navigation, targets, media resolution, keyed publishing, environment cache, refresh and live follow. |
| `lisp/etaf-org-preview-views.el` | Tree to ETAF Views: inline runs, blocks, keyed block and headline Components, document layout. |
| `lisp/etaf-org-preview-typeset.el` | Optional drawing of display formulas and `mermaid` blocks through mermaid-cli, with a content-and-palette cache and asynchronous repaint. |
| `lisp/etaf-org-preview-app.el` | Application shell: buffer, root keys, commands, width fitting. |
| `tests/` | Public behavior scenarios and their fixtures; `acceptance.json` inventories them. |
| `benchmarks/` | `performance-scenarios.el` for the shared driver and `render-large-document.el` for a local baseline. |
| `examples/` | The maintained sample document and its demo entry. |

Dependencies point one way: entry → app → views/model → theme/parse →
entities. Views and the parser never require the model, and nothing below the
application layer reads a buffer.

## Data flow

```
file or text ──> parser ──> document tree (plists + section structs)
                                │
       palette / width / section cells / hidden flag (reactive sources)
                                ↓
                            session
                                ↓
                             views
                                ↓
                  ETAF mount ──> Ebox retained tree ──> buffer
```

- The parser is a pure function of the text and the document's own settings.
- The session is the only mutable state. Width, palette, hidden content,
  document and every section's state are separate reactive sources.
- The views are a function of the tree plus an environment plist that carries
  the palette, the measure, the base font size, the section-cell accessor and the
  action callbacks.
- The application layer only builds the buffer, declares keys and binds
  commands. A geometry change reflows through the framework's viewport update;
  it never rebuilds the document.

## Parsing

The parser keeps a vector of lines and integer cursors; it never moves point
and never re-splits the text.

1. **Settings pass.** Every `#+KEY:` line is read into a context: title,
   author, keywords, TODO keywords, priorities, options, macros, link
   abbreviations. Org's own `org-todo-keywords` is consulted only when the file
   names none and Org is loaded; otherwise the built-in `TODO | DONE` set is
   used, so parsing stays deterministic.
2. **Block pass.** Lines are consumed by a dispatcher in a fixed order:
   directives and `#+BEGIN_` containers, comment lines, drawers, tables,
   fixed-width lines, lists, rules, LaTeX environments, display math, plain
   paragraphs. A container such as a quote or a special block recursively
   parses its own content with the same dispatcher. An unterminated container
   ends at the end of its parent and counts one degradation.
3. **Headline pass.** Headlines build a section tree with a stack: a new
   headline pops every section at the same or deeper level. A planning line
   directly below a headline belongs to it; a property drawer or `LOGBOOK` at
   the top of the body is lifted into the section, keeping both its parsed clock
   entries and its recorded lines.
4. **Attachments.** `#+CAPTION:`, `#+NAME:` and `#+ATTR_*:` lines attach to the
   next block in the same container. The keyword node stays in the list with
   `:attached`, so `C-c v` can still reveal it.
5. **Inline pass.** Each paragraph and table cell is scanned once for candidate
   starts (`[[`, `[fn:`, `[cite`, `[#`, `<YYYY`, `<<`, `{{{`, `@@`, `src_`,
   URLs, `\\`, and the emphasis characters). A candidate is matched with an
   anchor regexp; a failed match emits one character and advances, so the scan
   is linear. Emphasis checks the documented Org boundaries: the character
   before and after may not be alphanumeric. Targets and `#+NAME:` entries share
   one table on the document, so a reference jumps to the section that defines
   it; an export snippet keeps its backend apart from its payload, and only the
   payload is drawn.
6. **Ids.** A section id is its `CUSTOM_ID`, else its `ID`, else a positional
   path (`s1.1`). Section state, anchors and outline rows all key off that id,
   so a reload that moves a section keeps its anchor only when the id is
   stable.

Degradations are counted per kind (`unclosed-block`, `drawer`,
`dynamic-block`, `macro`, `directive`) and surface as one chip in the title
block.

## Section state

`etaf-org-preview-section` is a Component that receives its own section cell.
The reader has no fold control: every ordinary section is rendered in place,
so a headline carries no chevron and no press action. The cell still has two
states, and only a `COMMENT` section or an `:ARCHIVE:` section uses the hidden
one; its body stays out of the reading page while the headline and its marker
remain visible.

A published entry reuses the section's Component call while its key survives,
so a body edit rebuilds only the sections on its path and an unchanged sibling
keeps its instance, Hosts and state.

## Heading anchors and navigation

Each headline Component's root column carries `:id "org-section-<id>"`.
Positions are read back from the mounted tree with
`etaf-runtime-host-props-entries` and `etaf-host-ref-position`, so navigation
and imenu use the renderer's own positions instead of a second index that could
drift. `etaf-org-preview-locate` moves point to the first non-blank row of the
heading.

## Media

Media is resolved when a document is loaded or refreshed, not while rendering.
A paragraph that reduces to a single link to a local file becomes a media
descriptor:

- image extensions: pixel size via `image-size`, `exists` via `file-exists-p`;
- video extensions: a card;
- everything else: an ordinary link.

The render path only reads the descriptor, so it never touches the disk. A
missing file or a remote URL keeps a placeholder card.

## Theming

A palette is an alist of semantic keys (`:ink`, `:panel`, `:border`, `:todo`,
`:done`, `:urgent`, …). The `auto` palette derives every key from the frame's
own faces: background and foreground from `default`, secondary text from
`shadow`, the accent from `link`/`button`, semantic colors from
`success`/`warning`/`error`, and every surface as a blend of the background
toward the foreground or the accent. A heading color that sits too close to the
body ink (contrast below 1.12) is replaced by an accent blend, so a dark theme
cannot render headings and body in the same color.

The same palette is converted to ETAF UI theme tokens and provided to the
subtree, so shared components (`etaf-check-mark`, `etaf-tag`) follow the
document's colors instead of the frame's.

A fixed palette also paints the page background; `auto` leaves the Emacs theme
background in place.

## Update paths

| Change | Update |
| --- | --- |
| Palette | Theme ref → republish so drawn pictures follow the page, then recolored blocks |
| Reading measure | Width ref → block environment change, reflow, no re-parse |
| Refresh from an edit | New document with keyed entries; only the changed block's call is new |
| Hidden content | Hidden ref → block/section environment change, no publish |

A body edit is the path that has to stay cheap: its key changes on one block
and on the headlines above it, and every other block keeps its Component call.

## Keyed publishing

Every publish turns the parsed tree into entries. A body block's key is a
digest of its content, including a drawn picture; a headline's key also covers
its heading fields, its body-block keys and its child keys. An entry whose key
survives reuses the previous Component call, so ETAF hands the runtime the same
value and the block never renders again. An edit therefore creates one new
block call on its path to the root; every unchanged sibling keeps its instance,
hosts and state. Two identical blocks are told apart by an occurrence
number in the key.

The rendering environment is built from reactive inputs only (palette, width,
hidden flag, title, table-of-contents depth) and cached until one changes. It
does not read the document, so publishing a document does not re-render every
block that reads it. A block Component reads this environment in its own
render; a palette or width change therefore reaches every block without a
publish, while the keyed calls stay stable.

## Live editing and drawing

A displayed file session follows its source buffer through
`after-change-functions`: an edit schedules one repaint after 300 ms of quiet,
reads the buffer text as it stands, and publishes it. A save or an external
write still schedules the file watcher; closing the source buffer falls back to
the file. Text read from the buffer is never written back.

A display formula or a `mermaid` source block is drawn asynchronously when
mermaid-cli is present. Publication only attaches a picture that is already in
the cache, so a keystroke never starts a program. After a publish, a timer
starts one render per missing picture; the finished PNG is keyed by source,
palette and body size, and the page is published once more, which repaints only
the blocks whose picture key changed. A program that refuses a source is
remembered for the session and that block keeps its source.

## Refresh and follow

A displayed file session registers a file watch and an `after-save-hook`. A
change schedules a repaint after 250 ms; the watcher is re-armed because some
backends drop the watch when the file is replaced. Repaint keeps the reading
section by id, then re-centers. A parse or read failure keeps the last good
document and reports the error; the preview never goes blank.

Closing the buffer unregisters the watch, cancels a pending repaint and
unmounts the runtime.

## Performance baseline

Measured in batch on the maintained benchmark (`120` sections, 40 KB, 2272
rendered lines, 900×50 viewport), Emacs 31, Apple silicon:

| Path | Time |
| --- | --- |
| Parse | 34 ms |
| Mount, every section open | 257 ms |
| Edit one paragraph and repaint | 28 ms |

A publish keys every block by content, so the edit row repaints one paragraph
instead of the document. `make benchmark` prints these numbers with
`ORG_PREVIEW_BENCH_SECTIONS` controlling the size; the registered scenarios in
`benchmarks/performance-scenarios.el` cover parse, mount, edit and refit for the
shared performance driver.

## Correctness boundaries

- The parser never signals on malformed input; truncation is a degradation, not
  an error.
- Public errors are limited to `etaf-org-preview-error`: a missing source, an
  unreadable file, an unknown palette, an unknown section or fold state.
- Rendering performs no I/O: no file reads, no subprocesses, no network.
- The preview never writes the document. Checkboxes, keywords and cookies are
  display only.

## Testing

| Layer | What it proves |
| --- | --- |
| Document model | Metadata, outline fields, counts, detached snapshots, refresh success and failure |
| Section state | Comment and archive bodies stay hidden, a body edit repaints a scoped region |
| Rendering | Emphasis faces, entity and subscript spelling, inline links, timestamps, planning, checkboxes, description lists, tables, code, callouts, footnotes, comments, degraded blocks, media placeholders |
| Display | Palette cycling and rejection, measure clamping, TOC toggle, narrow mount |
| Navigation | Locate moves point to the heading row of the chosen outline entry |

Every test drives the package through the interfaces declared in
`etaf-org-preview.el`; none reaches into the parser or the session plist.
GUI appearance and interaction latency are verified separately in a real
graphical session, as the workspace rules require.
