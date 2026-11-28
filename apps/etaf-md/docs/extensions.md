# Extension syntax

> **Status.** The container vocabulary, `@tab` marker syntax, site components, `etaf-md-define-node`, `etaf-md-set-attr` (for container node selectors), and `etaf-md-describe-nodes` are implemented and rendered. Source-buffer authoring helpers (`etaf-md-edit-mode`, section 7) and non-container core Markdown selectors remain planned proposals.
>
> **How to read it.** Writing a document: chapters 3, 5 and 6. Writing a container definition: chapters 9 and 10. Implementing the renderer: chapters 2, 7, 8 and 11. What works today: the status table in 6.17. Why a name is spelled that way: Appendix E.
>
> The Chinese and English versions run section for section. Change one, change the other.

## Quick reference

This is all a writer needs.

**Two rules.** `:::name {attrs}` opens a block, a line holding `:::` alone closes the one opened last. The last block in a file may omit its closing line.

A block container:

````markdown
:::card {title="Cache hit"}
Images and figures scale with the page instead of being redrawn.
:::
````

A parent container. A child's name and spelling are both interpreted by its parent; `tabs` writes one `@tab` per child:

````markdown
:::tabs
@tab Emacs 29
Uses the old `image-size` signature.
@tab {title="Emacs 30+" selected=true}
Passes the buffer directly.
:::
````

**The attributes that carry most documents.**

| Attribute | Type | Written on | Example |
| --- | --- | --- | --- |
| `title` | string | Containers and children | `title="Cache hit"` |
| `description` | string | card | `description="One line of summary"` |
| `surface` | surface | box, card | `surface=raised` |
| `accent` | accent | box, card, callouts | `accent=warning` |
| `text-align` | align | box, card | `text-align=center` |
| `columns` | number or string | columns, stats | `columns="2fr 1fr"` |
| `gap` | length | columns | `gap="2ch"` |
| `padding` | length | box, columns | `padding="1lh"` |
| `open` | boolean | collapse, callouts | `open=true` |
| `selected` | boolean | tab | `selected=true` |
| `list-style` | enum | steps, timeline, file-tree | `list-style=decimal` |
| `href` | string | card | `href="#install"` |

**Seven surfaces:** `none`, `page`, `raised`, `sunken`, `quote`, `table-header`, `table-stripe`. **Six accents:** `neutral`, `primary`, `success`, `warning`, `danger`, `important`.

A length always carries its unit, `2ch` or `1lh`; a bare `2` is wrong. A document never names a colour or a type size; the reader's theme and style table decide those.

When an attribute name slips your mind, ask `etaf-md-describe-nodes` (a dedicated source minor mode `etaf-md-edit-mode` is planned).

## 1. Place

### 1.1 What this package does

One thing: turn a Markdown document into ETAF views inside a buffer, for reading. The input is text; the output is boxes, text and faces on a character grid.

It ships a container vocabulary so a document can express structures plain Markdown cannot: callouts, cards, steps, tabs, timelines. The vocabulary is closed; a user can add to it through the seam in chapter 10, but a document cannot define anything itself.

### 1.2 The boundary: documents and pages

Pages, directories, routes, navigation, data sources and publishing are things this package knows nothing about. They belong to an application above it.

That application owns its page model, its layout registry, its outline tree, its site navigation and its data. It requires this package's root entry and calls only the public interfaces. Nothing here grows a switch or a parameter for that layer's policy.

The seam has one place: a document becomes a view. `etaf-md-view` returns a mountable ETAF View for a session created from text or a file, and `etaf-md-define-node` registers a container type; embedding applications consume those public entries alongside session lifecycle, navigation, state snapshots and capability diagnostics.

The package also emits no HTML. It paints a buffer. Serving a page to a browser is the application's own backend.

One confusion is worth pinning down: `columns` in chapter 5 is **a column inside a document**, deciding how a passage is laid out. A page's layout is a name in the application's registry, and it is out of scope here.

### 1.3 The reference and the distance from it

The design refers to `vuepress-theme-plume`. Its Markdown extensions live in `plugins/plugin-md-power/`, and the real structure is three things.

- **One container factory**, in `src/node/container/createContainer.ts`. It exposes `createContainerPlugin` and `createContainerSyntaxPlugin`; the first parses content as Markdown, the second handles content itself.
- **One registry**, in `src/node/container/index.ts`. It installs about twenty presets: `align`, `tabs`, `code-tabs`, `window`, `steps`, `card`, `card-grid`, `card-masonry`, `encrypt`, `npm-to`, `lang-repl`, `file-tree`, `code-tree`, `timeline`, `collapse`, `chat`, `field`, `table`.
- **About thirty client components**, among them `VPCodeTabs`, `VPTabs`, `VPCollapse`, `VPField`, `VPTimeline`, `VPCodeTree`, `VPTable`, `VPPlot`, `VPAnnotation`, `VPQRCode`, `VPPdf`, `VPArtPlayer`, `VPCodePen`, `VPCodeSandbox`, `VPCard`, `VPCardGrid`, `VPCaniuse`.

Copying it will not work. Three hard differences.

1. **The output differs.** Plume emits HTML, Vue components and CSS. We emit boxes, text and faces on a character grid. A container that lands in a buffer is a run of characters carrying text properties.
2. **The expression differs.** CSS has arbitrary lengths, absolute positioning, gradients, rounded corners, shadows and animation. A character grid has line height, character width, borders, fills, weight and underlines, plus box-drawing characters.
3. **The runtime differs.** A plume page carries client-side scripts. Our page is a plain-text result: a reader has to find it with isearch, copy it with `C-w`, export it through org, and read it in a terminal.

Copying shows immediately. A card's rounded corners and shadow become garbled glyphs, a tab strip's sliding animation becomes a repaint per frame, and a chat avatar becomes a missing-glyph box.

Two things are worth taking, and neither is an implementation.

1. **The container factory.** Twenty effects sharing two factory functions means the shape of a definition converged. We keep that shape, but the render hook returns an ETAF view.
2. **The effect inventory.** What plume solved is a requirement list. Ask of each one what it looks like on a character grid. What the grid can express gets absorbed; what it cannot gets declined, with the reason in Appendix D.

## 2. Model

### 2.1 One thing: the node

A document is a sequence of nodes. A node has a type, attributes and children. A paragraph, a heading, a code block, a table and a container are all nodes; only the type differs.

The parser knows three things: opening, closing and nesting. It does not know what `card` means, nor which attributes it takes. The registry owns the names, the declaration owns the attributes, and the paint owns the placement.

### 2.2 One model

The system has one kind of thing: the node type. Text types and container types sit in the same table and go through the same `etaf-md-define-node`.

| Type | Can a document write it? | Examples |
| --- | --- | --- |
| The parser makes it | No, it has no `:name` | `heading`, `quote`, `code`, `table` |
| A document writes it | `:::name` | `card`, `tabs`, `columns` |

The only difference is that **a type a document can write has a name** (the `:name`). `heading` has none, so `:::heading` does not exist and only `###` makes one.

A type that takes a fixed set of children declares `:accepts`, such as `columns` taking `col`; without it the content is any block. **A child is not a type and has no declaration of its own**; its name and spelling are interpreted by the parent. The default spelling is `:::name`; `tabs` and `code-tabs` use one `@name` line per child. So `@tab` is a marker only inside a container that declares `markers`; inside a note it is plain text, and `:::tab` inside `tabs` is an error.

The relationship does not cross layers. A `tab` may hold a `card`, but a `tab` may not hold another `tab`. To nest, wrap another `tabs`.

### 2.3 One carrier

Every fact is written in one place, by one role, and read by one consumer. Anything with no consumer is deleted.

| Fact | Written by | Lives in | Read by |
| --- | --- | --- | --- |
| Body text | The author | The node's children | The paint |
| Ordinary attributes `title`, `accent`, `prefix` | The document sets a default; the reader overrides with `set-attr` | Node attributes and style rules | The paint, via `attr` |
| Derived attributes `level`, `language`, `number` | The parser and the derive step | Node attributes | Rule selectors, the paint |
| Theme colours | The theme | The token table | Style rules only |
| The contract | The declaration | The registry | Validation, `describe-nodes` |
| Block state | Reader interaction | The block's state cell | The paint |
| Available width | The renderer | env | The paint |

Three consequences.

1. **A token never enters a paint.** A paint reads attributes, an attribute's value points at a token inside a style rule, so the reader can always override the colour.
2. **A document-wide value is written onto the node.** The section number arrives that way; env offers no function to read it.
3. **The node is the only source of data.** `attr` reads it and a rule overrides it, both on the same node; `env` adds render services, appearance conversion and block state, and keeps no second copy.

### 2.4 The pipeline

```
text → parse → node tree → derive → render → view
```

- **Parse**: closed. It calls the shared `etaf-doc-markdown-parse`, which this document does not change.
- **Derive**: computed once for the whole document. Section numbers, anchors and each block's display identity happen here, and the results are written onto node attributes.
- **Render**: per block. Declared attributes and the paint take effect here.

Derive earns its own step because blocks repaint independently while numbering depends on the whole document. Doing it in render would recompute the page to repaint one block; doing it in parse would mix display decisions into the syntax layer.

Two derive rules.

- **An anchor comes from the source, never from display text.** A heading's `◆` prefix belongs to the display layer, and changing it must not break someone's saved `#install` link.
- **Numbering is computed only when a style asks for it.** With `numbering` set to `none`, no `number` is written, so nothing is wasted.

### 2.5 Eight invariants

Every new type must satisfy all eight. Miss one and the type does not belong in the registry.

| Invariant | Test |
| --- | --- |
| One syntax | A new effect adds a name, never a punctuation mark |
| One kind of child | Children are declared by `:accepts` only; a child has no definition of its own |
| One content model | Content is nodes, never a string, never HTML |
| One carrier | Every fact has one declaration and one consumer |
| One attribute vocabulary | Names and types come from the shared vocabulary; a type selects, never invents a synonym |
| One layout set | Placement uses `box`, `columns` and the shared spacing attributes |
| One failure rule | A bad block keeps its source plus one line, and the page keeps rendering |
| One definition boundary | A definition declares, validates and translates; shells and interaction belong to components |

### 2.6 Three vocabularies

Vocabulary is split by who speaks it, not by package. A new name must fit one of the three, or it is not added.

| Who speaks | Which names | Examples |
| --- | --- | --- |
| The person writing a document | HTML attribute names, plus props mainstream component libraries share | `title`, `href`, `selected`, `columns`, `padding` |
| The person configuring appearance | CSS property names | `background`, `color`, `font-weight`, `prefix`, `margin-top` |
| The person writing a definition | JSON Schema type names, plus this document's declaration fields | `string`, `length`, `:derived`, `:default` |

Five rules.

1. **No abbreviations.** Write `padding`, not `pad`; write `columns`, not `cols`. Only `id` and `href` are exempt, because that is how HTML spells them.
2. **No numbering.** Write `surface-raised`, not `panel2`.
3. **One word, one meaning.** `number` is the section number and `numbering` is its format; `surface` is a surface and the style key is called `background`.
4. **Standard words for values.** `decimal` and `lower-roman` come from CSS `list-style-type`; `boolean` comes from JSON Schema.
5. **Look before borrowing.** Reuse an existing word for a meaning, borrow from an authority when none exists, and invent only as a last resort, saying why.

## 3. Syntax

### 3.1 Opening and closing

````markdown
:::card {title="Cache hit" surface=raised}
The image and the formula are each drawn once and scaled to the page.

- A hit reads the file
- A miss draws once
:::
````

| Rule | Meaning |
| --- | --- |
| Name | Lowercase letters, digits and hyphens: `card`, `code-tabs` |
| Attributes | `key=value` inside braces, space separated; omit the braces when there are none |
| Closing | One line of three colons, no name; it closes the innermost open container |
| Nesting | Nest directly; inner and outer both use three colons, and depth is not counted in colons |
| Depth | Eight levels at most. The ninth is an error, not a render |
| Empty | Allowed. It renders a title row or an empty slot, and that is not an error |
| Line start | `:::` occupies its own line, preceded by whitespace only |

There is one spelling for closing, so there is one reading: **close the innermost open container.** No counting, no name matching, so nothing can fail to match.

Nesting needs no extra colons, and that includes a container of the same name:

````markdown
:::card {title="Outside"}
:::card {title="Inside"}
Content
:::
:::
````

The two `:::` lines are last-in-first-out: inside closes first, outside second. Extra colons or name matching would bring a second rule, and a second rule only adds a second way to get it wrong.

The depth limit is eight rather than unbounded. Every level is a box, and a reader in a narrow window loses track of which level they are in; every level also costs one measurement and one reflow. The limit pins the worst case.

One cost is worth stating: **a child with no content still needs its own closing line.** A `:::stat` that carries only attributes is written on two lines. That is what one closing rule costs; a spelling that saves the line would require the parser to know names, and it does not.

### 3.2 Children

A child's name and spelling are both interpreted by the parent type. The parent declares `:accepts`, which decides the names it takes and the attributes that apply, and `:child-syntax`, which decides how a child is written.

````markdown
:::columns {columns="2fr 1fr" gap="2ch"}
:::col
The left column is ordinary Markdown.
:::
:::col
So is the right one.
:::
:::
````

A parent type must handle three edge cases without crashing or painting half a block.

- **No children**: paint its own empty state, no error.
- **Children out of order**: interpret them in source order, never reorder.
- **A child missing a required attribute**: that child degrades; the others still render.

One container has one spelling of its children:

| `:child-syntax` | Spelling | Used by |
| --- | --- | --- |
| `blocks` (default) | `:::name`, one block per child | Structure, collections, most interactive containers |
| `markers` | `@name Title` or `@name {attrs}`, one line per child | `tabs`, `code-tabs` |

`markers` is scoped to the container that declares it:

- An `@tab` inside a note or card is ordinary text; an `@tab` inside a fence stays code.
- Nothing but blank lines may come before the first marker; otherwise the page reports a line.
- A marker's body may hold `:::` containers; the parser expands `@` into the same child blocks, so `:accepts` and rendering are unchanged.
- A container recognises only one spelling: `:::tab` inside `tabs` is an error, never a silent second page.

### 3.3 Attributes

Nine types. Attributes come in two classes, separated by one flag.

| Class | Who writes it | Who may change it | How it is marked |
| --- | --- | --- | --- |
| Derived | The parser or the derive step | Neither; a reader may only select on it | Its own `:derived` table |
| Ordinary | The document, in the braces, with `:default` when omitted | The reader, with `set-attr` | The `:attrs` table |

The test is one sentence: **does this value have a spelling in the Markdown text?** If it does, it goes in `:attrs`; if it does not, it goes in `:derived`. Two tables side by side, never mixed.

| Type | Spelling | Domain | Invalid |
| --- | --- | --- | --- |
| `string` | `title="Cache hit"` | An optional `:pattern` | `title=cache hit` |
| `number` | `start=2` | Optional `:min`, `:max`, `:integer` | `start=two` |
| `boolean` | `open=true` | `true` or `false`, nothing else | `open=yes` |
| `length` | `gap="2ch"` | Units `ch`, `lh`, `%` | `gap=2` |
| `surface` | `surface=raised` | `none`, `page`, `raised`, `sunken`, `quote`, `table-header`, `table-stripe` | `surface="#24262a"` |
| `accent` | `accent=warning` | `neutral`, `primary`, `success`, `warning`, `danger`, `important` | `accent=urgent` |
| `align` | `text-align=center` | `start`, `center`, `end` | `text-align=middle` |
| `enum` | `list-style=decimal` | The declaration's `:one-of`, which is required | `list-style=number` |
| `color` | `color=primary` | A token name; only a reader rule may write a literal | `color=blue` |

The three semantic types keep their word lists as constants of the package, see 4.1, so a declaration never repeats them. A type that wants only some of the words narrows them right there:

```elisp
(accent :type accent :one-of (neutral warning) :doc "Two accents only")
```

Validation converts each value into the shape the renderer wants, so a declaration never parses a unit itself.

| Type | Written as | The value a paint receives |
| --- | --- | --- |
| `string` | `title="Cache Hit"` | The string `"Cache Hit"` |
| `number` | `start=2` | The number `2` |
| `boolean` | `selected=true` | `t` or `nil` |
| `length` | `padding="2ch"` | ETAF's length `(ch 2)`, ready to pass as a property |
| `surface` | `surface=raised` | The symbol `raised` |
| `accent` | `accent=warning` | The symbol `warning` |
| `align` | `text-align=center` | The symbol `center` |
| `enum` | `list-style=decimal` | The symbol `decimal` |
| `color` | Tokens only | The resolved colour |

Three conventions.

- **Attribute names are shared.** `title` means the same in a card, a callout and a fold. A type selects from the vocabulary and never invents `heading` or `caption`.
- **One name, one type.** `columns` is always a column count, never anything else.
- **No unit, no length.** `gap=2` is wrong and `gap="2ch"` is right. One bare number could mean characters, lines or percent, and guessing wrong mislays the layout once per guess.

Writing the same attribute twice is an error, not a last-one-wins. A duplicate usually means the author changed half of it, and silently picking one hides the problem.

**Derived attributes come from the built-in syntax, and none of them may be guessed.** A.2 lists every one per type, and that table is `etaf-md-node-definitions` in code; read one type's derived attributes with `(etaf-md-derived-attributes TYPE)`, see 10.7.

The shared attribute table is Appendix A, one table for ordinary attributes and one for derived. How a declaration writes them is 10.2.

### 3.4 Validation, degradation and the failure catalogue

Validation runs once, before a view is built, and reports every error in the block together. An error is a muted line above the block's source, numbered by the line that opened the container.

````markdown
:::card {title="" colour=blue accent=urgent}
Content
:::
````

```
line 42: card does not take "colour"; it takes title, accent
line 42: title cannot be blank
line 42: card's accent is "urgent"; it takes neutral, primary, success, warning, danger, important
line 44: nesting level 9 exceeds the limit of 8
```

Failures come in twenty-one kinds. Each has a determined page result; none is "it depends".

| Case | Page result | Scope |
| --- | --- | --- |
| Unknown name | Source plus one line | This block |
| Unknown attribute | Source, and the line lists what it takes | This block |
| Value outside its domain | Source, and the line gives the domain | This block |
| Required attribute missing | Source, and the line names it | This block |
| The same attribute written twice | Source, and the line names the duplicate | This block |
| A derived attribute written by the document | Source, and the line says it has no spelling in the text and is filled by the parser or derive | This block |
| A parent with no children | Empty state, no error | This block |
| A child's attribute unknown or invalid | That child degrades; the others render | This child |
| Two children declare `selected` | Only the first counts, with one line | This group |
| Nesting beyond 8 | Source, and the line gives the depth | This block |
| A container left unclosed | Content renders, and the line sits on the opening line | From that line |
| A child outside its parent type | Source, and the line names the `:accepts` that takes it | This block |
| A container in a place it cannot go | Source, and the line says top level or container content | This block |
| A definition signals | Source, and the line names the definition and its error | This block |
| Contract version mismatch | Source, and the line names the version it needs | This block |
| A style rule selects on an undeclared attribute | The whole rule is ignored, with one line | The page |
| A style rule's key is a derived attribute | That key is ignored, with a line saying it can only be a selector | The page |
| `target` names no block | The selector stays pressable, with one line | That selector |
| Two selectors point at one region | The later one wins, with one line | That region |
| Duplicate child keys | The first is taken, with one line | That group |
| The selected key has no content | The region shows `empty`, or nothing when absent, with one line | That region |

Four rules that hold everywhere.

1. **No dialogs.** An error is part of the page, not an Emacs signal. A file with ten mistakes would pop ten windows, and nobody could read it.
2. **Never abort the page.** Only the failing block degrades; a bad style rule costs one rule.
3. **One line each.** Several errors in one block each get a line, ordered as the declaration orders the attributes.
4. **The wording comes from the declaration.** Which attributes exist and what the domain is are read from the declaration, never written by hand.

The wording follows the page's language. A Chinese page reports in Chinese, an English page in English, on the same mechanism as the callout titles.

### 3.5 Unclosed containers and recovery

A container still open at the end of the file is treated as closed there: its content renders, and one line at the end of the page names the line that opened it.

````markdown
:::card {title="Missing its closing line"}
This is still body text.

## The heading below still counts
````

The choice favours the reader. Turning the block into source makes the preview look broken; swallowing half a document is much worse than one extra line, and the author would also have a harder time finding it.

### 3.6 Code blocks

A fence's info takes four kinds of options after the language, in any order.

| Writing | Meaning |
| --- | --- |
| `title="x"` | Names the block; without it the header shows the language |
| `:line-numbers`, `:line-numbers=3`, `:no-line-numbers` | Turns numbering on, starts at 3, or off; off by default |
| `{1,4-7}` | Paints those rows on the accent surface |
| A `[!code highlight]`, `focus`, `++`, `--`, `warning` or `error` at the end of a row | Paints that row as highlighted, focused, added, removed, warned or failed |

````markdown
```elisp title="lisp/etaf-md-env.el" :line-numbers
(defun etaf-md--muted (env)
  (or (etaf-md--palette-value (etaf-md-env-palette env) :muted)
      "#9198a1"))
```

```elisp
(defun etaf-md--toggle-line (env block line)
  (let ((open (etaf-md-block-state env :open)))        ; [!code --]
    (etaf-md-set-block-state env :open (not open))))   ; [!code ++]
```
````

The markers choose the paint and never reach the code.  Inside a focused block the rows that are not focused recede into the surface, and every ink is made readable against the fill it sits on, in light and dark themes alike.  The copy action in the header puts the code, markers removed, on the kill ring.

Code blocks are painted by the `etaf-ui` markdown renderer; the page theme only supplies the palette.

### 3.7 Editing the source buffer

A rendered page carries no markup, so the whole cost of it falls on the writer. Everything here happens in the source buffer. It changes neither the syntax nor the rendered result.

Four layers, in order of payoff. All four form one optional minor mode named `etaf-md-edit-mode`, off by default.

| Layer | What it does | What it fixes |
| --- | --- | --- |
| One | Push the markup back: `:::`, the braces and the equals sign in `markdown-markup-face`; the container name in the language keyword face; attribute names and values in two different faces | The colons stop competing with the prose |
| Two | Pair hint: while point is inside a container, its opening and closing lines are each lifted one step; both fall back on leaving | No counting which colon matches which |
| Three | Insert and complete: one command writes the opening line, a blank line and the closing line; container names and the attributes each container takes complete in place | Names and attributes need not be memorised |
| Four | Fold: keep the container's opening line only | Read structure first in a long document |

Four hard constraints, each one a test of "hurts no existing Markdown habit".

1. **Add, never replace.** The new font-lock rules match `^:::` and the attribute braces only; markdown-mode has no rule for either today, so nothing is overridden. Its keymap, indent function, `electric-pair` and `markdown-hide-markup` stay untouched.
2. **Never change buffer text.** Dimming, lifting and folding are faces, overlays and the `invisible` property only; `buffer-string` is identical before and after. Otherwise saving writes a different file.
3. **Off means gone.** Disabling removes the font-lock keywords, deletes the overlays, clears the hook and drops its `completion-at-point-functions` entry. A test asserts that `font-lock-keywords` after an enable-and-disable cycle is `equal` to what it was before.
4. **Never take a key.** Only its own prefix; no existing command is remapped.

Performance budget, measured the same way as 8.3.

| Action | Budget | What guarantees it |
| --- | --- | --- |
| Open a 2000-line document | 50 milliseconds of extra work at most | font-lock runs per chunk, never over the whole file |
| Move point to another line | 5 milliseconds at most | computed once per line change |
| Typing inside one line | no pair computation at all | the previous row |
| Idle | no timers | no polling, no background refresh |
| Fold and unfold | one overlay added or removed | text is never touched |

The pair hint has to find the container's opening line, so it has a line limit. One backward search in a document of a few thousand lines, skipping the hint beyond that limit; never an unbounded reverse scan.

Three places it cannot help, recorded here so it is never mistaken for a promise: on GitHub, in someone else's editor, and in a fragment pasted elsewhere. The syntax therefore has to read well as bare text; this section is only a bonus, and it is never a reason to add syntax.

## 4. Appearance and style

### 4.1 Surface and accent

A document writes two appearance attributes: `surface` for the fill, `accent` for the accent colour. They are separate words because they are separate things. Every value of both maps onto exactly one token, with no exceptions; see Appendix B.

| `surface` | Token | Used for |
| --- | --- | --- |
| `none` | No fill | Default. Cards in prose, blocks side by side |
| `page` | `background` | Places that must separate from the prose |
| `raised` | `surface-raised` | Code blocks, cards that need a boundary |
| `sunken` | `surface-sunken` | Table headers, stripes, secondary information |
| `quote` | `quote` | Quotation-like blocks |

| `accent` | Foreground | Soft fill | Meaning |
| --- | --- | --- | --- |
| `neutral` | `foreground` | `surface-raised` | No emphasis |
| `primary` | `primary` | `primary-soft` | Note, link |
| `success` | `success` | `success-soft` | Success, advice |
| `warning` | `warning` | `warning-soft` | Caution |
| `danger` | `danger` | `danger-soft` | Danger |
| `important` | `important` | `important-soft` | Important |

One accent value decides the accent colour and the soft fill only. It never changes type size, weight or line height. For stronger emphasis, change the accent value, do not stack effects.

### 4.2 Tokens

A token is a name inside the renderer. A document writes `surface=raised`, never the `surface-raised` token, and certainly never a colour value. The names come from shadcn/ui, because that is today's most widespread semantic token set.

| Token | Use |
| --- | --- |
| `background` | Page background |
| `foreground` | Body text |
| `muted` | Secondary text and notes |
| `faint` | The weakest layer: numbering, separators |
| `border` | Borders and rules |
| `surface-raised` | A raised surface: cards, code blocks |
| `surface-sunken` | A sunken surface: table headers, stripes |
| `quote` | Quote fill |
| `quote-bar` | The quote's left bar |
| `table-header` | Table header |
| `table-stripe` | Table stripe |
| `heading` | Headings |
| `primary` / `primary-soft` | Informational |
| `success` / `success-soft` | Success |
| `warning` / `warning-soft` | Caution |
| `danger` / `danger-soft` | Danger |
| `important` / `important-soft` | Important |

Every token has a value in all three palettes, and the face-derived mode computes them from the active frame. A container declares a surface and an accent, and follows the palette when it changes.

**Why no hexadecimal.** A `#24262a` that looks right on a dark page is a black blot on a paper-coloured one. A hexadecimal value is an error, and the error line lists the semantic words that attribute accepts.

### 4.3 Style rules

Style rules are where a reader changes appearance. They form a list of rules, each opening with a selector and followed by key-value pairs. A key is an attribute name the type declares.

```elisp
(setq etaf-md-styles
      '(((heading)          (:font-weight bold) (:color heading) (:numbering decimal))
        ((heading :level 1) (:prefix "◆ "))
        ((heading :level 2) (:prefix "◇ "))
        ((quote)            (:background quote) (:border-left-width "1ch"))
        ((code)             (:background surface-raised) (:label-color muted))
        ((link)             (:color primary) (:text-decoration underline))))
```

A selector is always a list, in one of two forms: `(type)` covers every node of that type, `(type :attr value …)` adds conditions. There is no third form and no omission.

Three matching rules.

1. A rule matches when the type is equal and every attribute listed in the selector equals the node's attribute of that name.
2. Matching rules accumulate in table order, and a later rule wins per key.
3. A key no rule mentions takes the node's attribute value; with no attribute either, it takes the declaration's `:default`.

`## Dependencies` has `level` 2, so the first and third rules match, `font-weight`, `color`, `numbering` and `prefix` all resolve, and the second rule takes no part.

A reader changes appearance by writing a rule of the same shape:

```elisp
(etaf-md-set-attr '(heading :level 2) '((:prefix "## ")))
```

Exactly the shipped form, so the reader learns one spelling.

The declaration decides which keys are legal.

| Legal key | Basis |
| --- | --- |
| An ordinary attribute of that type | `title`, `accent`, `prefix`, `color`, `font-weight`, `numbering` |
| A derived attribute | Never a key, only a selector; writing one costs a line that lists the legal keys |

Three special values.

- **Omitted inherits, `nil` disables, `:default` returns to the shipped value.** `(:prefix nil)` drops the prefix; deleting the `:prefix` key inherits from elsewhere; `:color :default` goes back to the shipped colour.
- **`:numbering` is read by the derive step.** It decides whether a `number` is written, and takes no part in the paint.
- **The shipped rules live in this same table.** No literal colour appears in code, so what you change and what you see are one thing.

Editing the table repaints the page and recomputes the derive step, but never re-parses it; see 8.2.

### 4.4 Two colour rights

| Who | May write | Why |
| --- | --- | --- |
| The document | Semantic words and token names such as `surface=raised`, `accent=warning`, `color=heading` | A document has to read on any theme and any machine |
| The reader's style rules | A token name, or a literal `"#ff0000"` | The reader owns the page |

A literal costs something: it stops following the theme. A blue chosen on a dark page may be unreadable on a paper one, so a document never writes a literal, and that is a hard rule.

For an ordinary attribute the document's value is a default and one reader rule overrides it. A derived attribute answers to the parser and the derive step alone, and a reader using it as a key gets an error.

A token name appears only inside a style rule, never in a paint. A paint always receives a resolved colour, so switching themes needs no change to any declaration.

### 4.5 Type size and measures

A document has no size attribute and no equivalent. A container and the body always share one size.

A style rule carries no scaling key either. Type size comes from the user's default font alone, and containers, headings and tables inherit it alike; none is a size larger than another.

Hierarchy comes from weight, colour, a prefix, a rule and a fill, never from size. The block flow uses each block's real height and never assumes one row.

Two counter-examples. A `size=large` card occupies three rows at 12-point and five at 20-point, so the same document lays out differently on two machines. A table squeezed to 80% makes its text smaller than the body, and the reader concludes they zoomed the page.

### 4.6 Decoration characters

Decoration uses ASCII and box-drawing characters only. No emoji, no variation selectors.

The allowed set: `-`, `=`, `|`, `+`, `*`, `` ` ``, `.`, `o`, plus `─│┌┐└┘├┤┬┴┼`.

The reason: every character in that set occupies one cell in a monospace font. An emoji's width is decided by the font, so it may take one cell or two, and may become a box when the glyph is missing; a variation selector (U+FE0E) can raise the whole line and clip the bottom row.

Box-drawing characters are for trees and tables only, not for card borders. The renderer draws card borders; there is no "border character" attribute.

## 5. Layout

### 5.1 One structural container

There is one way to make columns: `columns`. The former `layout`, `flex` and `card-grid` merge into it, because their differences were only defaults. One attribute takes two forms: a number for equal columns, a track list for proportions.

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `columns` | number or string | none | A number of equal columns, or a track list in `fr`, `ch` or `%` |
| `gap` | length | `"2ch"` | Space between columns |
| `padding` | length | none | Left and right padding; the block axis comes from the view |
| `min-width` | length | `"24ch"` | Smallest column; below it the columns stack |
| `align-items` | enum | `stretch` | Cross-axis alignment: `start`, `center`, `end`, `stretch` |
| `justify-content` | enum | `start` | Main axis: `start`, `center`, `end`, `between` |
| `wrap` | boolean | `false` | Wrap when it does not fit instead of stacking |
| `align-self` | enum | `start` | The container's own horizontal position: `start`, `center`, `end` |

The child is `col`, with one attribute.

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `grow` | number | `1` | Share of the remaining width |

````markdown
:::columns {columns="2fr 1fr" gap="2ch"}
:::col
## One hit

The cache holds one image; a hit reads it from disk and never starts the renderer.
:::
:::col
The note beside it is an ordinary paragraph; the column decides its width.
:::
:::
````

Three cards side by side is `columns` holding three `card` blocks.

````markdown
:::columns {columns=3}
:::card {title="Parse"}
Text to a semantic tree.
:::
:::card {title="Lay out"}
Tree to views.
:::
:::card {title="Publish"}
Views to a buffer.
:::
:::
````

### 5.2 Tracks, gaps, padding

- `columns=3` is three equal `1fr` columns.
- `columns="2fr 1fr"` is an explicit track list, in Ebox spelling: `(fr 2)` is written `2fr`, a fixed width `20ch`, a percentage `30%`.
- `gap` separates siblings only, never the outside. The outside ring belongs to `padding`.
- `padding` takes one length and applies it on four sides. No `padding-x` or `padding-y`: splitting the axes lets one page show two different paddings.
- Vertical spacing uses whole multiples of `lh`. Pixels would misalign the line spacing and put borders on top of glyphs.

### 5.3 Narrow windows

When side-by-side columns do not fit, the layout degrades in order, never scrolling sideways.

1. **Fewer columns.** `columns=3` drops to 2, then to 1, with every column at least `min-width`.
2. **Stacking.** With a track list, a column below `min-width` stacks the whole block into one column with a blank row between former columns.
3. **Tighter spacing.** `padding` drops from 2ch to 1ch and `gap` from 2ch to 1ch; the frame stays.
4. **Same type size.** At every step the type size and line height stay.

With `wrap=true`, the row wraps first, and only stacks when one column still does not fit.

### 5.4 Choosing among the three structural containers

There are only three, and the test is the content's relationship.

| What you want | Use | Why |
| --- | --- | --- |
| Things side by side | `columns` | The only column mechanism |
| A piece of material with a title and a boundary | `card` | The title is heavier than body text, lighter than a section heading |
| A fill or padding with no title | `box` | The simplest form of a card, with no title row |

**Where not to use them.** Two parallel passages are not a table, so do not force them into `columns`; use a table. Three key-value pairs are not a card; that is `field`.

## 6. The container catalogue

### 6.1 Families

| Family | Containers | Shared property |
| --- | --- | --- |
| Structure | `columns`, `card`, `box` | Decide placement and boundary only, never interpret content |
| Callouts | `note`, `tip`, `important`, `warning`, `caution` | Five definitions sharing one view, fixed accent values |
| Collections | `steps`, `timeline`, `stats`, `field`, `file-tree`, `chat` | Children carry labels and are ordered or named |
| Interaction | `tabs`, `code-tabs`, `accordion` (child `collapse`) | Stateful, switchable by key |
| Documents | `table`, `window` | Wrap something else and change how it presents |

### 6.2 Callouts

What ships today is the GitHub spelling, with the marker on the first line of a blockquote.

```markdown
> [!WARNING]
> This only works on Emacs 30 and later.
```

The container spelling is implemented too: seven names share one attribute set and one view (`details` belongs to the same family as a single-block fold, see 6.13).

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `title` | string | The accent's fixed title | Replaces the title text |
| `collapsible` | boolean | `false` | Allow the block to collapse |
| `open` | boolean | `true` | Whether it starts expanded |
| `background` | surface | `quote` | Fill, see 4.1 |
| `border-left-width` | length | `1ch` | Width of the left bar |

```markdown
:::warning {title="Compatibility" collapsible=true}
This only works on Emacs 30 and later.
:::
```

Both spellings render the same thing, from one view. The name-to-accent mapping is fixed: `note` to `primary`, `tip` to `success`, `important` to `important`, `warning` to `warning`, `caution` to `danger`.

Why keep both. A document pasted from GitHub works immediately, which is the commonest entry; a long document written with containers aligns with the other containers and can carry attributes.

### 6.3 Card

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `title` | string | none | Title; omit it and there is no title row |
| `description` | string | none | One muted summary line under the title |
| `accent` | accent | `neutral` | See 4.1 |
| `href` | string | none | The whole card activates and opens this target |
| `text-align` | align | `start` | Horizontal position of its content |
| `width` | length | `stretch` | Its own width |

The case it solves: a group of parallel material needs one boundary. A section heading lifts it to the level of a section, and a list flattens a figure into one item.

Component: `etaf-card`, whose default slot takes the body and whose `title` and `description` map directly. A card's fill is the component's own panel, so `card` declares no `surface`.

### 6.4 Box

Four alignment containers: `:::left`, `:::center`, `:::right` and `:::justify`.  Each does one thing, aligning the whole body the way its name says; blocks inside are written as usual.

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `surface` | surface | `none` | See 4.1 |
| `accent` | accent | `neutral` | See 4.1 |
| `padding` | length | none | Padding |
| `text-align` | align | `start` | Horizontal position of its content |
| `width` | length | `stretch` | Its own width |

A box is a card without a title. Centring a figure is what it is for.

```markdown
:::box {text-align=center padding="1lh"}
![A cache hit](figures/hit.png)
:::
```

### 6.5 Steps

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `start` | number | `1` | First number |
| `list-style` | enum | `decimal` | `decimal` for digits, `bullet` for a dot |

The child is `step`, with a required `title`.  An ordered list works too: each item is one step and its text is the title.

````markdown
:::steps
:::step {title="Locate"}
Take a stack with `sample` before guessing.
:::
:::step {title="Fix the cause"}
Change the layer that produces the symptom, not its result.
:::
:::
````

````markdown
:::steps
1. Locate: take a stack with `sample`
2. Fix the cause: change the layer that produces the symptom
3. Recheck: run the same input again
:::
````

The list form carries only the title; write `step` children when a step needs a body.

The case it solves: in a procedure a reader wants to see how many steps there are and which one they are on. An ordered list can do it, but the number and the title share a line, and a wrapped title leaves the number alone on its row.

Component: `etaf-steps`.

### 6.6 Timeline

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `list-style` | enum | `bullet` | `bullet`, `decimal`, `none` |
| `start` | number | `1` | Number of the first entry |

The child is `event`, with a required `title`; `time` writes the date, and `status` takes `success`, `warning`, `danger` or `info` to colour the dot and paint a badge.

````markdown
:::timeline
:::event {time="2026-11-12" title="Found the cost in drawing"}
`image-size` actually drew the picture.
:::
:::event {time="2026-11-13" title="Read the header instead" status="success"}
Opening dropped from 5.4 s to 0.33 s.
:::
:::
````

The case it solves: release notes and incident timelines. A list loses the "time above, content below" alignment.

Component: `etaf-timeline`.

### 6.7 Field

One container, two forms: a card for one parameter, or a table of names and values.

**Parameter card** (Plume's `::: field`): the attributes describe the value and the body is its description.

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | string | none | Parameter name; the card form is used when it is present |
| `type` | string | none | Type annotation |
| `type-link` | string | none | Link for the type, so the type can be opened |
| `default` | string | none | Default value |
| `required` | boolean | `false` | Draws a required chip after the name |
| `deprecated` | string | none | Draws a deprecated chip with this note |
| `experimental` | string | none | Draws an experimental chip with this note |
| `enum` | string | none | Candidate values, separated by `\|` or commas |
| `unit` | string | none | Unit |
| `format` | string | none | Format |
| `constraint` | string | none | Constraint |
| `since` | string | none | Version that introduced it |

The name owns the first row with its state chips; the type, default and since values share the second; the candidate values, unit, format and constraint merge into the last row; the body keeps its blocks.

```markdown
:::field {name="width" type="number" default="46" unit="columns"
          required=true since="0.1"
          enum="8 | 16 | 46" constraint="8 ≤ width ≤ 120"}
Largest column count of an image card; it narrows to the page.
:::
```

Plume writes `@type`, `@default` and the other JSDoc tags in the body; here they are container attributes, and a value carries no quotes of its own (write `default="empty string"`).

**Field table**: without `name`, the body is a list whose text before the first colon is the name; its attributes are `label-width` and `separator`.

```markdown
:::field
- Version: 12.3.0
- Renderer: Chromium, resident
- Cache: `~/.cache/etaf-md/typeset`
:::
```

The case it solves: parameter notes and environment facts. A two-column table needs a header row and an alignment row, which is too much machinery.

### 6.8 Statistics

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `columns` | number | `3` | Numbers per row; a narrow window reduces it |

The child is `stat`, with a required `title` (the caption) and a required `value` (the number as text). A child with no content still needs its closing line.

````markdown
:::stats
:::stat {title="Open" value="0.33 s"}
:::
:::stat {title="Resize" value="0.18 s"}
:::
:::stat {title="Memory" value="349 MB"}
:::
:::
````

The number takes `foreground` in bold, the caption `muted`. A fourth entry wraps instead of shrinking text. Component: `etaf-statistic`.

### 6.9 File tree

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `title` | string | none | One title line above the tree |
| `lines` | boolean | `true` | Draw tree lines. Off keeps indentation only |

The body is an indented list, one `-` per level.

```markdown
:::file-tree {title="lisp/"}
- lisp/
  - etaf-md-model.el
  - etaf-md-views.el
- etaf-md.el
:::
```

The case it solves: saying what a directory holds. A fenced block can show the same thing, but its lines have to line up with the indentation, and hand-written ones are off by a cell sooner or later. The marks use only the characters 4.6 allows.

A comment after `#` follows the name in muted ink; `++ name` marks a new file and `-- name` a removed one, green and red; a name wrapped in `**` is bold, to point at the entry a reader should look at first.  `icon` accepts plume's values and paints no file icon on a text page.

Component: the page draws its own guides, one row per entry, with no interaction.

### 6.10 Chat

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `title` | string | none | Title above the conversation |

The messages are grouped by marker lines, the way plume writes them: `{name}` starts a message, `{.}` is the reader themself, and `{:time}` changes the time. The blocks after a marker belong to that message, so a message may hold several paragraphs, a list or code.

````markdown
:::chat {title="Why does the preview not refresh"}
{:2026-11-14 14:20}

{ask}
Why does the preview not refresh?

{.}
It refreshes after saving, so half typed text does not reflow.
:::
````

What the reader writes sits on the right and the other side on the left; the time takes a row of its own.  The case it solves: putting a conversation into a document as text instead of a screenshot.

Component: `etaf-chat` when the catalog has one, painted in place otherwise.

### 6.11 Tabs

The child is `tab`, written one `@tab` per line. `title` is required and may be the rest of the marker line; `selected` is optional (a boolean; one child per group may set it).

````markdown
:::tabs
@tab Emacs 29
Uses the old `image-size` signature.
@tab {title="Emacs 30+" selected=true}
Passes the buffer directly.
:::
````

`@tab Title` is shorthand for `@tab {title="Title"}`; write the braces when you need other attributes. `tabs` recognises only this spelling; `:::tab` is an error, see 3.2.

Keyboard: `TAB` enters the strip and lands on the selected tab; Left and Right move focus; `RET` opens the page. At either end the key is consumed: no bell and no wrap.

When two children both set `selected`, only the first counts and the page says so; see 3.4.

The case it solves: several spellings of one thing in parallel, of which a reader needs one. Three parallel subsections lengthen the outline; tabs occupy one block.

Interaction follows the contract in chapter 7; no rules are restated here. The component is `etaf-tabs`: controlled, with its state supplied by the block.

### 6.12 Code tabs

The children are `tab` too, also one `@tab` per line; `title` is optional here and falls back to the fence's language. So `code-tabs` has its own `:accepts` rather than copying `tabs`.

````markdown
:::code-tabs
@tab
```elisp
(etaf-md-open)
```
@tab
```python
print("hi")
```
:::
````

It is not new meaning. It renders along the same path as `tabs` with a different declaration: `title` on `tab` is optional here and falls back to the language of the first fenced block.

### 6.13 Collapse

The child is `collapse`, used inside `:::accordion`, with one open at a time. A single fold is a group of one.

A child's attributes: `title` required (the title while closed), `open` optional (a boolean, `false` by default).

````markdown
:::accordion
:::collapse {title="The complete error"}
```
The long text goes here.
```
:::
:::collapse {title="Version differences"}
:::
:::
````

For one fold, write one child:

````markdown
:::accordion
:::collapse {title="The complete error" open=true}
```
The long text.
```
:::
:::
````

The case it solves: long derivations, long logs, a complete error report. They stay on the page for reference without blocking the way.

Component: `etaf-accordion`, controlled, with `open` and `multiple` supplied by the block; `multiple` defaults to `false`, so one section is open at a time.

### 6.14 Table

A plain pipe table already works. This container owns the table's **presentation**, never the table itself: it sets one title line, marks the rows, columns and single cells to look at, aligns the whole table, and copies it as tab separated text.  The frame hugs the grid, and the caption and copy line stay outside it. Without it the table renders as usual, just without a title or emphasis.

With a title as its only job, the name would belong to captions. It also carries highlighting, and a table's alignment and footnotes would land here too, so its duty is wider than a caption and the name stays `table`.

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `title` | string | none | One title line above the table |
| `highlight-rows` | string | none | Highlighted row numbers, space separated, e.g. `2 3` |
| `highlight-columns` | string | none | Highlighted column numbers, space separated, e.g. `1` |
| `highlight-cells` | string | none | Highlighted cells written `row:column`, space separated, e.g. `2:3 3:1` |
| `align` | enum | inherits `text-align` | Table-wide alignment: `left`, `center`, `right`; wins over a cell's own |
| `copy` | boolean | `false` | Draw a copy line under the title that puts the table on the kill ring as tab separated text |
| `highlight` | accent | `warning` | Which accent the highlight uses |
| `background` | surface | `page` | Table fill |
| `color` | color | `foreground` | Table ink |
| `header-background` | surface | `table-header` | Header fill |
| `stripe-background` | surface | `table-stripe` | Stripe fill |
| `text-align` | align | `start` | Cell text position |
| `margin-top` | length | `0` | Distance from the block above |
| `margin-bottom` | length | `0` | Distance from the block below |
| `numbering` | enum | `decimal` | Table numbering format, read by derive |

```markdown
:::table {title="Opening cost" highlight-rows="3" highlight=warning}
| Version | Cost |
| --- | --- |
| 0.1.9 | 5.4 s |
| 0.2.0 | 0.33 s |
:::
```

The reason: the two commonest table needs are a title and a marked row. A paragraph of prose cannot do either.

### 6.15 Demo window

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `title` | string | none | Title bar text |
| `height` | length | computed | Content height |

```markdown
:::window {title="etaf-md-preview"}
A screenshot or a passage of text.
:::
```

A transformation of plume's `window`, which draws rounded corners and a shadow; we draw one title bar. Rounded corners cannot be drawn on a character grid, and forcing them produces a row of stray glyphs.

### 6.16 Pane containers

Three containers paint a rule a cell already owns instead of spending a row on it: a panel puts its title on its top rule, tabs sit in that rule, and a form hangs its value under a single line.

#### Panel

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `title` | string | none | Title on the top rule |
| `status` | string | none | Note at the right end of that rule |
| `variant` | enum | `default` | `flat` keeps the rule and drops the surface |
| `focus` | boolean | `false` | Paints the whole rule in the accent colour |
| `accent` | accent | `neutral` | Colour of the rule and the title |
| `width` | length | the row | Panel width |
| `margin-top` | length | `1lh` | Distance from the block above |

```markdown
:::panel {title="Read settings" status="12.3.0" accent=primary}
The panel names itself on its top rule; the body starts on the next row.
:::
```

The case it solves: several blocks sit side by side, each has to say what it is, and none of them wants to spend a whole row on a heading.

Component: `etaf-edge-panel`.

#### Tab panel

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `accent` | accent | `neutral` | Colour of the rule and the chosen tab |
| `width` | length | the row | Panel width |
| `margin-top` | length | `1lh` | Distance from the block above |

The child is `tab`, with a required `title` and an optional `selected`.

```markdown
:::tab-panel {accent=primary}
@tab notes.md
The first page.
@tab {title="todo.md" selected=true}
The second page.
:::
```

The tabs and the body share one frame: the tab row is the top rule, the chosen tab is filled with the accent colour, and switching a tab swaps only the body. This separates it from `tabs` in 6.11: `tabs` is a strip of its own, while a tab panel grows its tabs on the pane's edge.

Component: `etaf-edge-tabs`.

#### Form

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `width` | length | the row | Form width |

The body is a list, one `label: value` per item; the label sits above the value and a line closes the value.

```markdown
:::form
- Repository: github.com/emacs-taf
- Renderer: Ebox
:::
```

The case it solves: settings and environment facts, one column of names and one of values, with no need for a table's header row and alignment row.

Component: `etaf-underline-field`.

### 6.17 Status table

| Container / syntax | Family | Implementation | Status |
| --- | --- | --- | --- |
| GitHub / Obsidian alerts `> [!NOTE]` (with `+/-` folding and custom titles) | Callouts | Primitives | Implemented |
| `note`, `info`, `tip`, `important`, `warning`, `caution`, `danger` | Callouts | Primitives | Implemented |
| `box`, `card`, `columns` + `col`, `details`, `left`/`center`/`right`/`justify` | Structure | Primitives / `etaf-card` / `etaf-accordion` | Implemented |
| `steps` + `step`, `timeline` + `event` (`orientation=horizontal`, `card`) | Collections | `etaf-steps` / `etaf-timeline` | Implemented |
| `stats` + `stat` (`trend`, `accent`, `spark`) | Collections | `etaf-statistic` | Implemented |
| `field`, `file-tree` (`lines`, `collapsible`, `clickable`), `chat` | Collections | Primitives | Implemented |
| `tabs` + `tab`, `code-tabs` + `tab`, `accordion` + `collapse`, `swiper` | Interaction | `etaf-tabs` / `etaf-accordion` | Implemented |
| `table` (`align`, `sortable` column sorting & copy), `window` | Documents | Primitives / `etaf-window-chrome` | Implemented |
| `panel`, `tab-panel` + `tab`, `form`, `log`, `statusbar` | Pane | `etaf-edge-panel` / `etaf-edge-tabs` / `etaf-underline-field` / `etaf-log` / `etaf-status-bar` | Implemented |
| `chart` (`line`, `bar`, `stacked`, `heatmap`) | Visualization | `etaf-braille-chart` / Primitives | Implemented |
| `progress`, `keymap`, `breadcrumb` | Editorial structure | Primitives | Implemented |
| `diff` (`@before`/`@after`), `pros-cons` (`@pro`/`@con`), `demo` | Comparison & live examples | Primitives | Implemented |
| `home-box`, `image-card`, `link-card`, `npm-badge`, `qrcode`, `code-tree`, `npm-to` | Site & showcase | Primitives / `etaf-badge` / `etaf-qr` | Implemented |
| `include`, `code-ref`, `symbol`, `project-tree`, `git-log`, `git-diff` | Emacs-native living docs (L1 read-only) | Sandboxed asset layer (`:asset-data`) | Implemented |
| `run` | Emacs-native living docs (L2 explicit action) | Trust-gated actions (`etaf-md-allow-actions`) | Implemented |
| Inline semantics: `!!spoiler!!`, `[+note]`, `[[wiki]]`, `%%comment%%`, `:color[...]`, `:sym[...]` | Inline extensions | `etaf-doc-markdown` | Implemented |
| Code fence upgrades: `:collapsed-lines[=N]`, `/word/`, `[!code word:...]`, `:whitespace`, `:indent-guides` | Code blocks | `etaf-doc-markdown` | Implemented |
| Interactive GFM task checkboxes, `T` independent configurable TOC side window, `S` global spoilers, `K` floating link/symbol peek dialog, media lightbox | Reader shell | `etaf-md-app` / `etaf-media-viewer` | Implemented |

## 7. The interaction contract

### 7.1 Interaction comes from the component

A document cannot give anything behaviour, and neither can a definition. **Something is interactive because a component stands behind it, not because a definition says so.** The definition supplies a state cell and a callback; keys, focus and arrow keys all live in the component.

A connection between two blocks is a different job: what one block selects and what another block should show are invisible to both components. **The renderer draws that line, see 7.5.**

This is the same statement as "components are thick" in chapter 9: `etaf-tabs` already works from the keyboard; `:::tabs` only connects it to a document. So there is no keyword for declaring interactivity, and none is needed.

### 7.2 Selector and region

Every interactive block reduces to one model: **one selector, one region, and the selected key decides what the region shows.**

| Role | What it does | What it does not know |
| --- | --- | --- |
| Selector | Collects the selection, reports changes, paints its own appearance | What the region holds |
| Region | Shows the content that matches the selected key | Where the selection came from |

There are only three wirings.

| Wiring | Where the state lives | Examples |
| --- | --- | --- |
| Inside a block | The parent's block state | Tabs, collapse, steps |
| Across blocks | On the selector, copied to the region's block | File tree with a side pane, table with a detail pane, contents with a body |
| The host | The application | A row that fetches its data from a backend |

One model covers these cases:

| Case | Selector | Region |
| --- | --- | --- |
| Tabs | The tab row | The selected page |
| Collapse | The header rows | The expanded blocks |
| File tree | The tree | The file content in the side pane |
| Table row selection | A row | A detail pane |
| Steps | The current step | That step's body |
| Site contents | A side list | The body |
| Conversation list | A conversation | The message pane |
| Card group | One card | The detail |
| Pagination | A page number | The list content |
| Tag filter | A set of tags | The filtered list |

### 7.3 Selection values

- A selection is a set of keys. Single selection is a set with at most one member.
- A child without a key takes its position: the first is `0`, the second `1`.
- A tree holds two sets: `:selected` and `:expanded`.
- The set lives in block state and never on disk. A reflow, a theme change or a width change keeps it; reloading the document returns to defaults.

### 7.4 Attributes

| Attribute | Type | Default | Meaning |
| --- | --- | --- | --- |
| `selected` | boolean or string | none | The initial selection: `true` on a child, one key on a selector |
| `target` | string | none | The region `id` a selector points at |
| `key` | string or number | its position | A child's selection value |
| `multiple` | boolean | `false` | Allow more than one selection |
| `empty` | string | none | What the region shows when nothing is selected |

```markdown
:::columns {columns="20ch 1fr"}
:::col
:::tree {target="preview"}
- lisp/
  - etaf-md.el
  - views.el
:::
:::
:::col
:::box {id="preview" empty="Pick a file"}
Pick a file on the left.
:::
:::
:::
```

### 7.5 Wiring across blocks

1. The selector writes its selection into its own block state.
2. When a block with `target` changes, the renderer copies the same value into the target block's `:selected`.
3. It repaints the target block only.
4. If the target is not on the page, nothing moves and one line is reported.

Conflicts follow 3.4: a `target` that names no block reports a line; two selectors pointing at one region let the later one win and report a line; a duplicate child key takes the first and reports a line; a selected key with no content shows `empty`, or nothing when `empty` is absent, and reports a line.

### 7.6 Host push

When the data lives in the application, the region keeps a placeholder and the host replaces it:

```elisp
(etaf-md-update-block SESSION ID VIEW)
```

- `ID` is the region block's `id`; `VIEW` is a view, either primitives or another rendered document.
- Only that block repaints; when its height changes, the blocks below it move.
- Reloading the document returns to the placeholder written in the document.
- An unknown `ID` moves nothing and reports a line.

### 7.7 Focus and keys

- A focusable target is an element the container draws, not the text itself. `TAB` and `S-TAB` move between them.
- `RET` activates the current target.
- Inside a group, left and right arrows switch, for a tab row or a collapse group.
- When focus enters a container, the container shows a visible focus mark; it returns to its resting paint when focus leaves.
- Focus order follows document order, not visual position. It is the same after a narrow window degrades.

### 7.8 State and repaint

- State lives on the container, not on the document, and never on disk.
- A reflow, a theme change or a width change keeps it. Reloading the document returns to defaults.
- A state change repaints that block only, never the page.
- The default state comes from attributes; `selected`, `open` and `key` are enough.
- Attributes settle the first value, then state owns it: rules and the document value decide the initial value, and a later rule change seeds it again.
- A block with an `id` keeps its identity by that `id`, one without by position; inserting a block above resets the ones below.

### 7.9 Search, copy, export

- **isearch**: hidden content still takes part. A match opens the block and puts focus on the match. That opening is a temporary override; it writes no state, so the block returns to its earlier fold afterwards.
- **Copy**: the visible text is copied, including container labels, excluding hidden content.
- **Export**: an org or HTML export flattens interactive containers the way 7.10 describes, so the reader's text is complete.

### 7.10 Flattening without interaction

Where there is no keyboard and no focus, such as batch rendering, export or a terminal capture, an interactive container must flatten.

| Container | Flattened |
| --- | --- |
| Tabs | One section per tab, titled by its label, all expanded |
| Code tabs | The same as tabs |
| Collapse | All expanded, titles kept |

Flattening is not degradation; it is the same content in another arrangement. That is why the tests can run in batch without simulating keys.

## 8. Rendering and performance

### 8.1 One block, one component

Every top-level block is its own Component, keyed by block type and source. Changing one word repaints that block alone; the others are not even touched.

A container is no exception. A `card` is one block, a `columns` is one block, and the `col` children are painted inside it.

### 8.2 Repaint scope

| What happened | What repaints |
| --- | --- |
| One word of prose changed | That block |
| A fold opened | That block |
| A tab switched | That block |
| The theme changed | The page, but each block only recolours, never reflows |
| The style table changed | The page repaints and re-derives; nothing is re-parsed |
| The window width changed | The page reflows, and nothing is rebuilt |
| A container definition changed | The blocks that use it |

A style can change a block's height, so the flow uses each block's real height. A heading occupies several rows, and the next block starts below them.

### 8.3 Cost and budget

- Every block is measured once per width. An unchanged width is never re-measured.
- A nested column measures its own subtree, not the page.
- A block's reflow targets 50 milliseconds. A 200-block document targets one second for its first open.
- No timers, no background refresh. A still page does nothing.
- The style table is looked up once per node: one hash lookup, never inside a character loop.

The budget is written down so acceptance has a number to compare with. The concrete numbers are calibrated against the benchmark during implementation, and this section changes with them.

## 9. Definitions and components

This chapter settles two things: how thin a definition should be, and where reusable parts live.

### 9.1 Three layers

| Layer | Things | In one line | Called by |
| --- | --- | --- | --- |
| Engine | `box`, `column`, `grid`, text properties | Places and paints, knows no meaning | Components |
| Components | `etaf-card`, `etaf-tabs`, `etaf-accordion` | Named, parameterised, reusable | Apps and definitions |
| Syntax | `:::card`, `:::tabs` | Turns a document's names and attributes into component calls | The renderer |

The test is one line: **delete this layer, can anyone else still use it?** Delete `etaf-card` and no other app can draw a card, so it belongs to the component layer; delete `:::card` and only this document loses the spelling, so it belongs to the syntax layer.

### 9.2 From a component to syntax

A new container follows a fixed order of three steps, and the test is the one in 9.1.

1. **Look for a component first.** When `etaf-ui` has one whose semantics fit, the definition writes those three lines of translation and nothing else. This is the common case and the thinnest one.
2. **With no component, and a shape a second place will use, write the component first and wrap it after.** The component goes into `etaf-ui` with its parameters, tests and documentation; the definition shrinks back to translation.
3. **Used exactly once, build it with `etaf-view` inside `:view`.** The DSL is the default; only what it cannot say (a tag or a list known at run time) drops to `etaf-node`. Once a second place needs it, it moves up under 9.6.

Step 3 is not an exception, it is the first implementation. Its risk is staying inside the definition forever, which is why the promotion rule in 9.6 follows it.

**The interface boundary.** `:body` may call public interfaces whose names start with `etaf-`; it may not call the engine's internals, which start with `ebox-`. The same rule already binds applications and components.

**Shipped containers take the same route.** The implementation column in 6.17 names the component each shipped container uses, or says it is built from primitives. A custom container reads that column to decide its own route.

### 9.3 A definition does three things

A type definition writes three things, and no more.

1. **Declare**: which attributes a document may write, which are derived, each one's type and value domain.
2. **Validate**: the renderer does it uniformly; the declaration only describes.
3. **Translate**: the document's semantics into component parameters.

```elisp
(etaf-md-define-node 'card
  :name "card"
  :summary "A card with a title"
  :attrs '((title       :type string :required t :pattern "\\S" :doc "Card title")
           (description :type string                          :doc "One line under the title")
           (href        :type string                          :doc "The whole card opens this target")
           (accent      :type accent  :default neutral        :doc "Emphasis")
           (text-align  :type align   :default start          :doc "Horizontal position")
           (width       :type length                          :doc "Its own width"))
  :view (lambda (env)
          (etaf-view
           (box :width (or (etaf-md-attr env :width) 'stretch)
                :text-align (etaf-md-attr env :text-align)
                :on-press (when-let* ((href (etaf-md-attr env :href)))
                            (lambda () (etaf-md-follow-link env href)))
             (etaf-card :title (etaf-md-attr env :title)
                        :description (etaf-md-attr env :description)
                        :variant (etaf-md-attr env :accent)
               (expr (etaf-md-content env))))))
```

The outer `box` carries only width, position and the click; borders and padding still live in `etaf-card`. The definition only translates the document's words into component parameters, and **`accent` passes straight through**: the six accents are shared vocabulary, so the component reads all of them and the definition maps nothing.

### 9.4 Components take semantic parameters

A component's parameters serve the person writing Elisp, not the document.

- **No document vocabulary.** A component never mentions `:container` or `:::card`; another application must not be forced to understand Markdown.
- **No colour values.** A component takes semantic roles such as `accent` and `surface`, never `"#c00"`. It must accept every value of the shared vocabulary; anything less is the component falling short.
- **As few geometry parameters as possible.** Padding and spacing are the component's own defaults; a definition overrides them only when it must.

Two counter-examples: a `:markdown-level` inside a component, which leaks syntax into it, and a hand-written table in a definition that collapses six accents into three, which loses information silently.

### 9.5 One authority per visual fact

| Fact | Authority |
| --- | --- |
| How headings, quotes, code and tables look | Style rules; the reader may change them |
| How a container looks | The parameters its definition passes to a component |
| A component's own baseline | The component |
| Colours | Tokens, one set per palette |

Two places able to change one fact is a bug. A component's default is only a baseline and a definition may override it; a definition's value is the document default and an ordinary attribute may still be overridden by the reader, see 10.3.

### 9.6 Two uses promote a widget

A new type needs a shell nobody has, so the definition builds it from primitives. That is not reinventing a wheel, it is the first implementation. The risk is that it stays in the definition forever.

The rule: **when a second application needs it, it moves into `etaf-ui`**, together with its parameters, tests and documentation. The definition shrinks back to those three lines of translation.

### 9.7 Shipped definitions are definitions too

`box`, `card` and `columns` are not special cases in the renderer; they are three definitions in the same registry. So are `heading`, `quote` and `code`, except those have no name.

This is what decides whether the whole split survives. One type with a private branch in the renderer means the API was never proven, and a user will hit the capability that only that branch has.

Three consequences.

- The shipped definitions live in `lisp/etaf-md-nodes.el` and register through the same entry as user definitions.
- A test must replace the shipped `card` with a user definition and the page must still render.
- When a component changes a parameter, the definition test turns red first, not the user.

## 10. Extending

### 10.1 The definition of one type

A definition is data plus one function, not code inside a document.

```elisp
(etaf-md-define-node 'heading
  :summary "A heading whose level comes from the number of #"
  :derived '((level  :type number :min 1 :max 6 :integer t :doc "Number of # characters")
             (number :type string                            :doc "Section number such as 1.1; absent when numbering is off"))
  :attrs '((font-weight :type enum :one-of (normal bold)     :default bold    :doc "Weight")
           (color      :type color                           :default heading :doc "Ink")
           (prefix     :type string                          :default ""      :doc "Display prefix")
           (numbering  :type enum  :one-of (none decimal lower-roman upper-alpha)
                       :default decimal :doc "Section number format, read by derive"))
  :view (lambda (env) …))
```

**"Derived" is this document's name for one class of values: the ones the parse or the derive stage computes and writes, which have no spelling in the Markdown text.** `level` comes from the number of `#` characters and `number` from the document's section order; neither is something the author types. They therefore get their own `:derived` table, apart from the `:attrs` the author writes.

| Keyword | Value | Meaning |
| --- | --- | --- |
| The name | A symbol, the first argument | The type name, the registry key |
| `:name` | A string | The spelling a document writes; `"card"` is `:::card`. Omitted means a document cannot |
| `:summary` | A string | One line, used in help and errors |
| `:attrs` | An attribute table | Ordinary attributes: a document writes them, a reader overrides them |
| `:derived` | An attribute table | Derived attributes: parse or derive fills them, nobody writes them |
| `:accepts` | A child table | Which children it takes; with it the type is a parent |
| `:child-syntax` | `blocks` or `markers` | How children are written: default `:::name`, `markers` uses one `@name` per child |
| `:contract` | An integer, `1` today | The version of the document-side table, see 10.6 |
| `:view` | A function | `(lambda (env) VIEW)`, the default paint |
| `:extends t` | A flag | Keep the shipped declaration and paint, add yours |
| `:replace t` | A flag | Drop the shipped declaration and paint |

**`view` takes one argument, `env`.** It is what you hold while painting one block: the current node plus the capabilities the renderer lends you. One is built per block and dropped when the block is done; two cards painted at once each get their own. Attributes are validated and defaulted, derived ones included.

Nothing beyond these exists, which is why a definition cannot read a file, reach the network or change a global.

| Group | Function | What it gives |
| --- | --- | --- |
| The node | `(etaf-md-attr env :title)` | One attribute's final value, see 10.3. For a child, pass the node last: `(etaf-md-attr env :title tab)` |
| | `(etaf-md-type env)` | The type name, for a paint shared by several names |
| | `(etaf-md-children env)` | The child nodes in order. Walk them only when placing blocks one at a time |
| Appearance | `(etaf-md-surface env 'raised)` | A surface as a fill; `none` gives `nil` |
| | `(etaf-md-accent env 'warning)` | An accent value as a colour |
| Painting | `(etaf-md-content env)` | Every child of this block as a view. Use it when the content goes in whole |
| | `(etaf-md-render env nodes)` | The given nodes as a view, one or several. Use it when placing blocks one at a time |
| | `(etaf-md-default-view env)` | This node painted with the shipped view |
| Services | `(etaf-md-follow-link env href)` | Open a target |
| | `(etaf-md-block-state env :selected)` | Read this block's state, with a default `(etaf-md-block-state env :selected v)` |
| | `(etaf-md-set-block-state env :selected VALUE)` | Write this block's state |
| | `(etaf-md-available-width env)` | This block's usable width |

`content` and `render` split one way: a component that takes the content whole gets `content`; a component that takes one item at a time gets each item from `render`. `children` serves only the second case, to walk the blocks and read each one's attributes.

Twelve, no thirteenth. Formatting an ordinal belongs to the derive step and never reaches a view, so there is no function for it either.

### 10.2 Declaring an attribute

An ordinary attribute states four things: name, type, value domain, default. A derived one states three: name, type, value domain, because it has no default. Missing one is a load error.

```elisp
;; Ordinary attributes, in :attrs
(title  :type string :required t :pattern "\\S" :doc "Card title")
(accent :type accent :default neutral :one-of (neutral warning) :doc "Emphasis")
(prefix :type string :default "" :doc "Display prefix")

;; Derived attributes, in :derived; same shape, without :default or :required
(level  :type number :min 1 :max 6 :integer t :doc "Number of # characters")
(number :type string                         :doc "Section number")
```

| Field | Required | Meaning |
| --- | --- | --- |
| `:type` | Yes | `string`, `number`, `boolean`, `length`, `surface`, `accent`, `align`, `enum`, `color` |
| `:default` | No | Omitted means `nil`; it applies inside `:attrs` only |
| `:required` | No | Ordinary attributes only, and exclusive with `:default` |
| `:pattern` | No | `string` only |
| `:min`, `:max`, `:integer` | No | `number` only |
| `:one-of` | No | Required for `enum`; the three semantic types use it to narrow |
| `:doc` | Recommended | Appears in help and in errors |

Three rules.

- **Two tables, two classes.** `:attrs` holds ordinary attributes: a document writes them and a reader overrides them. `:derived` holds derived ones: a document cannot write them, a reader cannot change them, and only a selector may match on them.
- **The derived table writes no `:default` and no `:required`.** Parse or derive supplies the value, and its absence means `nil`.
- **A child table** entry, `:accepts`, is written the same way with one extra `title` supplied by the renderer, never redeclared here.

### 10.3 How one value is decided

Four layers, in a fixed order. A paint calls `attr` once and never learns which layer answered.

| Order | Source | Example |
| --- | --- | --- |
| 1 | The reader's style rule | `(:accent danger)` |
| 2 | The value the document wrote | `accent=warning` |
| 3 | The declaration's `:default` | `neutral` |
| 4 | The value the parser or derive wrote | `level=2`, `number="1.1"` |

The first three answer for ordinary attributes. The fourth is the only source for a derived attribute, and the other three layers never touch it.

### 10.4 A paint uses the DSL by default

`etaf-view` is shorter than building nodes by hand and shows the structure: properties first, children last, property values plain Elisp, and a computed child wrapped in `(expr …)`.

```elisp
(etaf-view
 (box :padding '((lh 1) (ch 2))
   (text "Title")
   (expr (etaf-md-content env))))
```

Exactly one case drops to `etaf-node`: a tag or a property that is only known at run time, as when `mapcar` builds a list of rows. The DSL cannot say that, so it is a limit of the language, not a style choice.

### 10.5 Giving one type a new paint

```elisp
(etaf-md-set-view 'heading
  (lambda (env)
    (etaf-view
     (box :background-color (etaf-md-surface env (etaf-md-attr env :background))
       (expr (etaf-md-default-view env)))))
  :extends t
  :style-keys '((background :type surface :default none :doc "Heading fill")))
```

| Part | Meaning |
| --- | --- |
| The first argument | A type name. `heading` and `card` both work; neither is special |
| The second argument | `(lambda (env) VIEW)`, the same signature as `:view` |
| `:extends t` | Keep the shipped declaration and paint, add yours |
| `:replace t` | Drop the shipped declaration and paint |
| `:style-keys` | New attribute declarations, legal only here and only with a function |

Three rules.

- It must return a view and must not change the node tree.
- When it signals, the type falls back to the shipped paint, the page keeps rendering, and the error reaches `doctor`.
- **A new attribute needs a function.** A data definition cannot add one, and an attribute nobody reads is dead configuration.

### 10.6 Overriding and unloading

Three forms, one table.

| Form | Effect | Use it when |
| --- | --- | --- |
| `:extends t` | Keep the shipped declaration and paint, add yours | You want more attributes or one wrapper |
| `:replace t` | Drop the shipped definition; the declaration and paint are yours | You want a different way altogether |
| Neither | Applies only when no type of that name exists; a duplicate is an error | A new type |

Four constraints.

- **The document-side attribute table only grows.** A new attribute may only be appended; a rename or a removal is breaking, bumps `:contract`, and old documents degrade under 3.4 with a line that says so.
- **An attribute name and a child name have one declaration each.** No aliases, no synonyms.
- **`:default` always means the shipped value.** The loader keeps a snapshot of the shipped definition, otherwise "back to the default" would mean nothing.
- **An override leaves a trace.** A `:replace t` error names the definition it replaced, and `doctor` lists the override chain and the source file.

Unloading takes three forms, which is what lets a test say "install it, remove it, the page is shipped again".

| Action | How |
| --- | --- |
| Remove one style rule | `(etaf-md-set-attr '(heading) nil)` |
| Remove your paint | `(etaf-md-set-view 'heading nil)` |
| Remove a type definition | `(etaf-md-undefine-node 'card)` |

Removing a shipped type restores the shipped definition; removing a user type makes the name disappear, and a document that writes it gets "unknown name".

### 10.7 Where definitions live and when they are read

- The shipped definitions live in `lisp/etaf-md-nodes.el` and register once in order: text types, then callouts, then structure, then collections, then interaction. They go through the same `etaf-md-define-node` as user definitions.
- User definitions are `.el` files inside the directory named by `etaf-md-node-directory`, one file each.
- Load order is fixed: the package's own definitions first, the user directory after, and file name order within a directory. A later definition may override an earlier one, but only by saying so; see 10.6.
- A session reads the registry once when created and does not touch the disk again. A changed definition needs `r` or a fresh preview.
- A document cannot register a type and cannot run Elisp. Sharing a document is not sharing code.
- **The document declares its contract version.** Front matter may carry `contract: 1`; without it the current version is assumed.
- **The registry is a variable, not something hidden in a function.** `etaf-md-node-definitions` holds the type-to-definition table, shipped and user definitions alike, one entry per type.
- **Derived attributes are read from the registry.** `(etaf-md-derived-attributes 'heading)` gives `(level number)`; derive fills values from it, validation refuses document spellings with it, and `describe-nodes` prints it. A.2 is the printed form of that table.

### 10.8 Debugging

`etaf-md-describe-nodes` prints the registry, one type per entry:

```
heading            built in; a document cannot write its name
  derived   level  number
  ordinary  font-weight  color  prefix  numbering
  rules     (heading)  (heading :level 1)  (heading :level 2)
```

- When something looks wrong, follow one chain: what type is this block, which definition renders it, which component it calls, which layer supplied each value, and which token that landed on.
- The error line is always on the page, so no log has to be opened.
- `etaf-md-doctor` answers for the optional capabilities a page can use — `typeset-native`, `ffmpeg`, `qrencode` and `git` — so a reader learns why a block kept its source text. Reporting the registry itself (how many types, which override is in place) is planned.

### 10.9 Trust model

- A document has no execution rights. It can only name things and supply attributes.
- Definitions load only from the directory the user configured; never the working directory, never the directory beside a document.
- A definition may not read files, make network requests, start timers or change global state. Data arrives through attributes.
- A render has no side effects. A view reads refs and cached values only.

## 11. Roadmap

### 11.1 Phases

| Phase | Content | Done when |
| --- | --- | --- |
| 0 | GitHub alerts | Implemented, covered by 51 tests |
| 1 | Render path: parsing, derive, style rules, the failure catalogue, with `heading`, `box`, `columns` and `card` written as definitions | One assertion for each of the 21 failure kinds; three-level nesting and the limit; captures at three widths; a user definition replaces the shipped `card`; one reader attribute changes each built-in type; editing rules never re-parses |
| 2 | Callout containers: five definitions share one view and land on the GitHub spelling's result | Both spellings produce the same buffer text; each of the five accents maps to its own type |
| 3 | Collections: `steps`, `timeline`, `stats`, `field`, `file-tree`, `chat` | Each container has a positive case, a counter-example and captures in three palettes |
| 4 | Interaction: `tabs`, `code-tabs`, `accordion` and its child `collapse`, plus cross-block wiring and host push | Keys go through the command loop; state survives reflow and a theme change; flattened output loses nothing; a selection change repaints the target block only |
| 5 | Documents: `table`, `window` | Row and column highlights land; the window draws only a title bar |
| 6 | Registry and user definitions | A sample definition installs, uninstalls, and the page returns to the shipped view; a new reader attribute on a shipped type takes effect; `:default` still reaches the shipped view after an override; a contract mismatch is reported; `doctor` reports counts and the override chain |
| 7 | Editing the source buffer: dimming, pair hint, insert and complete, folding, as `etaf-md-edit-mode` | `font-lock-keywords` is `equal` before and after an enable-and-disable cycle; `buffer-string` is unchanged; a 2000-line document costs 50 milliseconds of extra work at most; typing inside one line triggers no pair computation |

### 11.2 The acceptance matrix per container

Every container passes these six cells; fewer is not done.

| Cell | What it checks |
| --- | --- |
| Positive | A document writes it and it renders as intended |
| Counter-example | One missing required attribute or one wrong value degrades the page with an accurate line |
| Nesting | Inside a `columns` column and inside a `card`, it still holds |
| Palette | Dark, light, sepia and face-derived: readable in all four |
| Narrow | Wide, medium and narrow: nothing lost, type size unchanged |
| Style | One style key changes its appearance; an unknown key is reported and falls back to the shipped style |

The render path carries four more assertions, independent of any container.

- Editing the style table leaves the parse count unchanged.
- A heading prefix does not change its anchor.
- With numbering off, the derive step is skipped.
- After overriding `heading`'s rendering, `etaf-md-default-view` still returns the shipped view.

### 11.3 Done means

A phase is done only when all three hold.

1. `make check` passes: structure, compilation, tests and the API check.
2. The affected examples have been run in a real GUI and their captures reviewed.
3. The attribute table in Appendix A, the style keys in Appendix C, the mapping in Appendix D and the vocabulary in Appendix E are updated with it.

## 12. What this will not do

- No HTML subset, no CSS subset, no `<style>` tag. Two layout systems in one renderer blur the boundary until nobody can say which layer produced a gap.
- No scripts in documents, and no container registration from documents.
- No type-size parameter and no scaling parameter. Type size comes from the user's default font, and neither a view nor a rule touches it.
- No remote frames, remote players or remote code execution.
- No rounded corners, shadows, gradients or animation.
- No second document format beside Markdown.
- No pages, routes, navigation or publishing. That is the application's work, see 1.2.
- No `justify` text. A character grid has no inter-word space to stretch, so it can only pad with blanks, and Chinese paragraphs get holes at the line ends.
- The first version does not parse inline emphasis or links; `**bold**` in a heading comes out as asterisks and text. The limitation is recorded rather than papered over.

## Appendix A: attribute reference

Two tables. An ordinary attribute is written by the document and overridden by the reader; a derived attribute comes from the parser or the derive step and nobody writes it. A type selects names from here and never invents a synonym.

### A.1 Ordinary attributes

| Attribute | Type | Domain | Default | Meaning | On |
| --- | --- | --- | --- | --- | --- |
| `title` | string | optional `:pattern` | none | Title text | Callouts, card, steps, timeline, file-tree, accordion, table, window, and children |
| `description` | string | | none | Summary under the title | card |
| `href` | string | | none | Target | card |
| `id` | string | `:pattern "^[^\\s]+$"` | none | Stable anchor | every block |
| `surface` | surface | five surfaces | see 6.x | Fill | box |
| `accent` | accent | six accents | see 6.x | Emphasis | box, card, callouts |
| `text-align` | align | three positions | start | Horizontal position of content | box, card |
| `width` | length | `ch`, `lh`, `%` | omitted means full | Own width | box, card |
| `height` | length | same | omitted follows content | Content height | window |
| `padding` | length | same | none | Inner padding | box, columns |
| `gap` | length | same | 2ch | Gap between children | columns |
| `columns` | number or string | 1 to 6, or a track string | see 6.x | Column count or tracks | columns, stats |
| `min-width` | length | | 24ch | Minimum column width | columns |
| `align-items` | enum | start center end stretch | stretch | Cross-axis alignment | columns |
| `justify-content` | enum | start center end between | start | Main-axis alignment | columns |
| `align-self` | enum | start center end | start | Its own position in the parent | columns |
| `wrap` | boolean | | false | Wrap when it does not fit | columns |
| `list-style` | enum | decimal bullet none | see 6.x | List marker | steps, timeline |
| `start` | number | `:integer t` | 1 | First number | steps |
| `open` | boolean | | see 6.x | Starts expanded | Callouts, the collapse child |
| `collapsible` | boolean | | false | May be folded | Callouts |
| `selected` | boolean or string | | none | The initial selection | Every selector, the tab child |
| `target` | string | | none | The region `id` a selector points at | Selectors |
| `key` | string or number | | its position | A child's selection value | Children |
| `multiple` | boolean | | false | Allow more than one selection | Selectors, the collapse child |
| `empty` | string | | none | What the region shows when nothing is selected | Regions |
| `grow` | number | | 1 | Share of the width | `col` children |
| `time` | string | | none | Time text | `event` and `message` children |
| `value` | string | | none | Numeric text | `stat` children |
| `from` | string | | none | Sender | `message` children |
| `label-width` | length | | automatic | Width of the label column | field |
| `separator` | enum | colon none | colon | Separator between label and value | field |
| `self` | enum | left right | left | Which side is you | chat |
| `highlight-rows` | string | space-separated row numbers | none | Rows to highlight | table |
| `highlight-columns` | string | space-separated column numbers | none | Columns to highlight | table |
| `highlight` | accent | six accents | warning | Which accent the highlight uses | table |
| `lines` | boolean | | true | Draw tree lines | file-tree |
| `background` | surface or colour | five surfaces, or a literal | none | Fill | quote, code, table, callouts |
| `color` | color | a token, or a literal | heading | Ink | heading, code |
| `font-weight` | enum | normal bold | bold | Weight | heading |
| `font-style` | enum | normal italic | normal | Slant | quote |
| `prefix` | string | | `""` | Heading prefix, never the anchor | heading |
| `numbering` | enum | none decimal lower-roman upper-alpha | decimal | Section number format, read by derive | heading, table |
| `margin-top` | length | | `0` | Space above | quote, code, table |
| `margin-bottom` | length | | `0` | Space below | quote, code, table |
| `border-left-width` | length | | `1ch` | Width of the left rule | quote, callouts |
| `label-color` | color | | muted | Fence language label | code |
| `header-background` | surface or colour | | table-header | Table header fill | table |
| `stripe-background` | surface or colour | | table-stripe | Table stripe fill | table |

The default column states the shared default; when a type's own table gives another value, that table wins.

A type declares only the ones it reads; the rest need not appear.

### A.2 Derived attributes

A document cannot write these, a reader cannot change them, but a style rule may select on them.

| Type | Derived attributes | Filled by |
| --- | --- | --- |
| `heading` | `level`, `number` | The parser fills `level`, derive fills `number` |
| `code` | `language` | The parser |
| `table` | `number` | Derive |
| Every other type | None | — |

This table is not a second copy; it is the printed form of the registry. The registry is a variable with one writer: `etaf-md-define-node`, which is how both shipped and user definitions arrive. Nobody `setq`s the variable.

```elisp
;; Shipped definitions are etaf-md-define-node calls in lisp/etaf-md-nodes.el,
;; so once loaded the registry holds one entry per type and nothing else.
(alist-get 'heading etaf-md-node-definitions)
;; => (:summary "A heading whose level comes from the number of #"
;;     :derived ((level …) (number …))
;;     :attrs ((font-weight …) (prefix …) …)
;;     :view …)

;; Derived attributes are not another table; they are filtered out of that entry
(etaf-md-derived-attributes 'heading)   ; => (level number)
(etaf-md-derived-attributes 'paragraph) ; => nil
```

Three rules.

- **Only `etaf-md-define-node` writes the registry.** A user does not `setq` it either; to change an entry, define it again with `:extends` or `:replace`.
- **Derived attributes get their own table.** Inside one definition `:derived` sits beside `:attrs`, with the same entry shape, and `etaf-md-derived-attributes` reads `:derived`.
- **Three places, one source.** `describe-nodes`, the derive step and this appendix all read that same variable, so they cannot drift apart.

## Appendix B: surfaces, accents and tokens

Every `surface` value maps to one token, and every `accent` value maps to a pair.

| Value | Foreground | Fill | Meaning |
| --- | --- | --- | --- |
| `surface=none` | — | none | No fill |
| `surface=page` | — | `background` | Separated from the prose |
| `surface=raised` | — | `surface-raised` | Code blocks, cards |
| `surface=sunken` | — | `surface-sunken` | Table headers, secondary information |
| `surface=quote` | — | `quote` | Quotation-like |
| `accent=neutral` | `foreground` | `surface-raised` | No emphasis |
| `accent=primary` | `primary` | `primary-soft` | Note, link |
| `accent=success` | `success` | `success-soft` | Success |
| `accent=warning` | `warning` | `warning-soft` | Caution |
| `accent=danger` | `danger` | `danger-soft` | Danger |
| `accent=important` | `important` | `important-soft` | Important |

The mapping from the five callout names to accents is in 6.2.

## Appendix C: writing a style rule

A rule is data with four parts: a selector, key-value pairs, three special values, and the door for new attributes. A key is an ordinary attribute name the type declares in A.1, so this appendix lists no second key table.

```elisp
(setq etaf-md-styles
      '(((heading)          (:font-weight bold) (:color heading) (:numbering decimal))
        ((heading :level 2) (:prefix "◇ "))))
```

A selector has two forms, both lists: `(type)` covers everything, `(type :attr value …)` adds conditions. There is no third form and no omission.

| Rule | Meaning |
| --- | --- |
| The final value | Matching rules accumulate in table order and a later rule wins per key; no rule mentioning the key means the node's attribute value; no attribute either means the declaration's `:default` |
| What a selector may name | Every attribute in the selector must be declared by that type; a bad one drops the whole rule with one line |
| Which keys are legal | An ordinary attribute of that type; a derived attribute may only appear in a selector |

Three special values.

| Spelling | Effect |
| --- | --- |
| `(:prefix nil)` | Disables this one |
| Deleting the `:prefix` key | Does not override; the node's attribute value or the `:default` applies |
| `(:color :default)` | Returns to the shipped value, whatever was written elsewhere |

Giving a type a new attribute happens only inside `etaf-md-set-view`'s `:style-keys`, and only with a function; see 10.5. A new attribute joins the `:style-keys` declaration first, then A.1; a key declared in neither place is a load error.

## Appendix D: the plume map

| Plume | Our decision | Note |
| --- | --- | --- |
| `align` | Folded into `box`'s `text-align` attribute | One alignment does not deserve a container |
| `flex` | Folded into `columns` | One container handles rows, wrapping and proportions |
| `card` | Absorbed as `card` | Rounded corners and shadow become one border and a surface |
| `card-grid` | Folded into `columns {columns=N}` | Cards side by side are cards in columns |
| `card-masonry` | Declined | Row heights are fixed, so packing yields a grid |
| `steps` | Absorbed as `steps` + `step` | Number plus title |
| `tabs` | Absorbed as `tabs` + `tab` | Keyboard reachable; a switch repaints one block |
| `code-tabs` | Based on `tabs`, with its own declaration | Children hold fenced code; `title` is optional and defaults to the fence's language |
| `collapse` | Absorbed as the child of `accordion` | One open at a time, plus auto-expansion on a search hit |
| `field` | Absorbed as `field` | Auto-aligned name column |
| `timeline` | Absorbed as `timeline` + `event` | Optional marks |
| `table` | Partly absorbed | Title and row/column highlights |
| `file-tree` | Absorbed as `file-tree` | Marks use only the allowed characters |
| `code-tree` | Absorbed as `code-tree` | A file list beside a code panel, sharing the tabs' `@file` markers |
| `chat` | Absorbed as `chat` + `message` | Alternating sides and indentation, no bubbles |
| `window` | Absorbed with a change, as `window` | Title bar only |
| `encrypt` | Declined | A document that must stay secret does not belong in a preview |
| `npm-to` | Absorbed as `npm-to` | Rewrites from a fixed command table; never runs a command |
| `lang-repl` | Declined | Needs an interpreter |
| `qrcode` | Absorbed as `qrcode` | Drawn by `qrencode` as a PNG; keeps its text when the program is missing |
| `plot`, `pdf` | Declined | Plume's `plot` is its spoiler component, not a chart; a PDF needs an embedded document |
| `annotation`, `abbreviation` | Declined | Needs marks over an image and a hover popup |
| `code-pen`, `code-sandbox`, `repl`, `caniuse` | Declined | Needs a browser and a network |

## Appendix E: vocabulary

This table is the ground for naming. A new name is looked up here first; if it is absent, borrow one from the authority column and add it here.

### E.1 Attribute names

| Name | Source | Meaning | Not |
| --- | --- | --- | --- |
| `title` | HTML | Title text | `heading`, `caption` |
| `description` | Ant, Primer | Summary under the title | `summary`, `subtitle` |
| `surface` | Material, Polaris | Fill role | `background`, `fill`, `panel` |
| `accent` | shadcn/ui | Accent value | `tone`, `variant`, `type`, `intent` |
| `text-align` | CSS | Horizontal position of content | `align`, `position` |
| `align-self` | CSS | Own position within the parent | `self-align`, `align` |
| `align-items` | CSS | Children's cross-axis alignment | `items`, `cross-align` |
| `justify-content` | CSS | Children's main-axis alignment | `justify` |
| `width` | CSS | Own width | `w` |
| `height` | CSS | Content height | `h` |
| `padding` | CSS | Padding | `pad`, `inset` |
| `gap` | CSS | Space between siblings | `spacing`, `space` |
| `columns` | Bootstrap grid, CSS | Column count or track list | `cols`, `tracks`, `grid` |
| `min-width` | CSS | Smallest column | `min`, `threshold` |
| `wrap` | CSS `flex-wrap`, Ant | Wrap when it does not fit | `flex-wrap`, `nowrap` |
| `grow` | Tailwind | Width share | `flex`, `ratio`, `weight` |
| `list-style` | CSS `list-style-type` | List marks | `marker`, `bullet` |
| `open` | HTML `<details open>` | Starts expanded | `expanded`, `visible` |
| `collapsible` | Bootstrap, Primer | May collapse | `foldable`, `toggle` |
| `selected` | HTML `<option selected>` | This child is selected by default | `active`, `current` |
| `derived` | This document's parse and derive stages | A derived attribute; a document cannot write it | `read-only`, `computed` |
| `href` | HTML | Target | `url`, `link`, `to` |
| `start` | HTML `<ol start>` | First number | `begin`, `from` |
| `separator` | General | Name/value separator | `divider` |
| `label-width` | CSS-style compound | Name column width | `label-w`, `width` |
| `self` | Chat interfaces | The reader's own side | `me`, `own` |
| `target` | This document's wiring | The region a selector points at | `for`, `pane` |
| `key` | SVG, React | A child's selection value | `value`, `index` |
| `multiple` | HTML `<select multiple>` | Allow more than one selection | `multi`, `many` |
| `empty` | General | The placeholder when nothing is selected | `placeholder`, `empty-text` |
| `from` | Mail, chat | Sender | `sender`, `author` |
| `time` | HTML `<time>` | Timestamp | `date`, `at` |
| `value` | HTML `<input value>` | The number as text | `number`, `figure` |
| `highlight-rows` | General | Highlighted row numbers | `hl-rows`, `mark` |
| `highlight-columns` | General | Highlighted column numbers | `hl-cols`, `mark` |
| `highlight` | Naming rule of this table | Accent used for the highlight | `tone`, `mark-color` |
| `id` | HTML | Stable anchor | `anchor`, `slug` |

### E.2 Types

| Name | Source | Meaning | Not |
| --- | --- | --- | --- |
| `string` | JSON Schema | Text | `str`, `text` |
| `number` | JSON Schema | Integer or decimal | `int`, `float`, `num` |
| `boolean` | JSON Schema | `true` or `false` | `bool`, `flag` |
| `length` | CSS value type | A number with a unit | `size`, `dimension` |
| `enum` | JSON Schema | One of the listed words | `one-of`, `choice` |
| `surface` | Material, Polaris | One of five fill values | `background`, `fill` |
| `align` | CSS | One of three horizontal positions | `text-align`, `justify` |
| `accent` | shadcn/ui | One of six accent values | `tone`, `variant` |

### E.3 Tokens

| Name | Source | Meaning | Not |
| --- | --- | --- | --- |
| `background` | shadcn/ui | Page background | `bg`, `page` |
| `foreground` | shadcn/ui | Body text | `ink`, `text` |
| `muted` | shadcn/ui | Secondary text | `secondary`, `dim` |
| `faint` | General | The weakest layer | `subtle`, `ghost` |
| `border` | shadcn/ui | Borders | `line`, `stroke` |
| `surface-raised` | Material layering | A raised surface | `panel`, `card-bg` |
| `surface-sunken` | Material layering | A sunken surface | `panel2`, `inset` |
| `quote` | General | Quote fill | `quote-bg`, `blockquote` |
| `quote-bar` | General | The quote's bar | `bar`, `accent-bar` |
| `table-header` | General | Table header fill | `th`, `header` |
| `table-stripe` | General | Table stripe fill | `stripe`, `zebra` |
| `heading` | HTML | Heading colour | `title`, `h` |
| `primary` | shadcn/ui | Primary emphasis | `accent`, `brand`, `info` |
| `primary-soft` | shadcn's `-foreground` style | Primary soft fill | `accent-soft` |
| `success` | Bootstrap, shadcn | Success | `ok`, `positive`, `green` |
| `success-soft` | Same | Success soft fill | `ok-soft` |
| `warning` | Bootstrap, shadcn | Caution | `warn`, `caution` |
| `warning-soft` | Same | Caution soft fill | `warn-soft` |
| `danger` | Bootstrap, shadcn | Danger | `error`, `red`, `critical` |
| `danger-soft` | Same | Danger soft fill | `error-soft` |
| `important` | GitHub alerts | Important | `note`, `emphasis` |
| `important-soft` | Same | Important soft fill | — |

### E.4 Declaration fields

| Name | Source | Meaning | Do not write |
| --- | --- | --- | --- |
| `:name` | HTML `name` | The spelling a document writes | `tag`, `keyword` |
| `:summary` | General | One line of description | `desc`, `description` (that is a card attribute) |
| `:attrs` | JSON Schema `properties` | The attribute table | `props`, `fields` |
| `:accepts` | General | Which children it takes | `children`, `:kind` |
| `:child-syntax` | This table's naming rule | The child spelling, `blocks` or `markers` | `:children`, `:child-form` |
| `:view` | ETAF | The default paint | `:body`, `:render` |
| `:contract` | General | Version of the document-side table | `:version` |
| `:extends` / `:replace` | General | Which shipped definition is overridden | `:override`, `:merge` |
| `:style-keys` | Naming rule of this table | Attributes added with a new paint | `:keys` |
| `:type` | JSON Schema | The attribute's type | `:kind`, `:value-type` |
| `:derived` | Naming rule of this table | The table of derived attribute declarations | `:read-only`, `:computed`, `:source` |
| `:default` | JSON Schema | The default value | `:fallback` |
| `:required` | JSON Schema | Must be written | `:mandatory` |
| `:pattern` | JSON Schema | A regular expression for `string` | `:regex` |
| `:min` / `:max` | JSON Schema | A range for `number` | `:range` |
| `:integer` | JSON Schema | Integers only | `:int` |
| `:one-of` | JSON Schema | The word list | `:choices`, `:enum` |
| `:doc` | General | Text for help and errors | `:help`, `:comment` |

### E.5 Functions

| Name | Meaning |
| --- | --- |
| `etaf-md-define-node` | Register a type, or override one with `:extends` / `:replace` |
| `etaf-md-undefine-node` | Remove a type definition |
| `etaf-md-set-attr` | Set a style rule on one selector; `nil` removes it |
| `etaf-md-set-view` | Give one type a new paint; `nil` removes it |
| `etaf-md-describe-nodes` | List the registry |
| `etaf-md-doctor` | Diagnose |
| `etaf-md-node-directory` | Where user definitions live |
| `etaf-md-node-definitions` | The registry: type to definition, shipped and user alike |
| `etaf-md-derived-attributes` | Read one type's derived attribute names |
| `etaf-md-styles` | The style rule table |
| `etaf-md-attr` | Read one attribute's final value |
| `etaf-md-type` | Read the type name |
| `etaf-md-children` | Read the child nodes in order, for placing blocks one at a time |
| `etaf-md-surface` | Turn a surface into a fill |
| `etaf-md-accent` | Turn an accent value into a colour |
| `etaf-md-content` | Paint this block's children as a view, for content that goes in whole |
| `etaf-md-render` | Paint the given nodes as a view |
| `etaf-md-default-view` | Read one node's shipped paint |
| `etaf-md-follow-link` | Open a target |
| `etaf-md-block-state` | Read this block's state |
| `etaf-md-set-block-state` | Write this block's state |
| `etaf-md-available-width` | This block's usable width |

`etaf-card`, `etaf-tabs`, `etaf-accordion`, `etaf-steps`, `etaf-timeline`, `etaf-statistic` and `etaf-tree` belong to the `etaf-ui` component catalogue; this package calls them and renames none.

## Appendix F: two complete examples

One custom container and one built-in syntax. Both run from document to page, and every name they use can be traced into the chapters above.

### F.1 A custom container: the document

````markdown
:::card {title="Cache hit" description="One scale, no redraw" href="#cache"
        accent=warning text-align=start width="48ch"}
Images and figures scale with the page instead of being redrawn.
:::
````

### F.2 A custom container: styles

The definition is in 9.3; this section shows only the styles and the page.

```elisp
;; The shipped rule: a card has one overridable attribute; the rest is etaf-card's baseline
(setq etaf-md-styles '(((card) (:accent neutral))))

;; The reader changes one thing; the document does not move
(etaf-md-set-attr '(card) '((:accent danger)))
```

The page:

```
┌ Cache hit ────────────────────────────┐    accent=warning, from the document
│ Images and figures scale with the page.│
└───────────────────────────────────────┘

┌ Cache hit ────────────────────────────┐    after the reader writes (:accent danger)
│ Images and figures scale with the page.│
└───────────────────────────────────────┘
```

### F.3 A custom container: how the parts line up

| Step | Written where | Value | Read by |
| --- | --- | --- | --- |
| The document | In the braces | `title`, `description`, `href`, `accent`, `text-align`, `width` | Validation |
| The declaration | `:attrs` | `title` required, `accent` defaulting to `neutral`, the rest optional | Validation, `describe-nodes` |
| The view | `attr` | Title, description and accent | Component parameters |
| The component | `etaf-card`'s `:title`, `:description` and `:variant` | Unchanged, no mapping | The component paints it |
| The shell | The outer `box`'s `:width`, `:text-align`, `:on-press` | Unchanged | Width, position, the click |
| The reader | `set-attr '(card)` | `:accent danger` | Overrides the document, see 10.3 |

`env` functions used: `attr`, `content`. `surface` is absent because the fill belongs to the component.

### F.4 A built-in syntax: the document

```markdown
# Install

## Dependencies
```

What the parser produces:

| Item | The first heading | The second heading |
| --- | --- | --- |
| Type | `heading` | `heading` |
| `level` | `1` | `2` |
| `number` | `"1"` | `"1.1"` |
| Children | One text node | One text node |

The `#` characters leave no trace and become `level`; document order yields `number`. The type has no `:name`, so `:::heading` does not exist.

### F.5 A built-in syntax: definition and styles

The definition is the same as in 10.1; this section shows only the rules and the page.

```elisp
;; The shipped rules; every selector is a list
(setq etaf-md-styles
      '(((heading)          (:font-weight bold) (:color heading) (:numbering decimal))
        ((heading :level 1) (:prefix "◆ "))
        ((heading :level 2) (:prefix "◇ "))))

;; The reader changes two things
(etaf-md-set-attr '(heading) '((:color primary)))
(etaf-md-set-attr '(heading :level 2) '((:prefix "## ")))
```

The page:

| Case | Output |
| --- | --- |
| Nothing changed | `◆ 1 Install` / `◇ 1.1 Dependencies` |
| After the reader's rules | The same, in the primary colour, with `## ` on level 2 |
| `numbering` set to `none` | `◆ Install` / `◇ Dependencies`, and no `number` at all |

### F.6 A built-in syntax: how the parts line up

| Step | Written by | Value | Read by |
| --- | --- | --- | --- |
| `## Dependencies` | The author | Two `#` characters and one line of text | The parser |
| `level = 2` | The parser | 2 | The rule selector `(heading :level 2)` |
| `number = "1.1"` | Derive | A formatted string | The view, via `attr` |
| `prefix`, `color`, `font-weight` | Reader attributes | `"◇ "`, the `heading` token, `bold` | The view, via `attr` |
| Prefix and section number | The view | `"◇ "` and `"1.1 "` | A `text` node |
| Heading text | The view | The children's text | `content`, painted as a view |

`env` functions used: `attr`, `content`.

### F.7 The two side by side

| Item | `card` | `heading` |
| --- | --- | --- |
| `:name` | `"card"`; a document writes it | Absent; only the parser makes one |
| Document attributes | `title`, `accent` | None |
| Reader attributes | None; appearance belongs to the component | `font-weight`, `color`, `prefix`, `numbering` |
| Derived attributes | None | `level`, `number` |
| Selectors | `(card)` | `(heading)`, `(heading :level 2)` |
| Entry | `etaf-md-define-node` | The same |

Together the two say one thing: **the document writes semantics, the declaration fixes the contract, the paint translates, the reader changes appearance, and every fact has one carrier.**

### 6.18 Site components

Sections 6.2–6.15 are the containers inside a document's prose; this one is the set a documentation site writes around it. They register through the same definitions and views as a callout, and the renderer itself is unchanged.

| Type | Written as | Purpose | Children |
| --- | --- | --- | --- |
| `home-box` | `:::home-box {title description href}` | A first-screen block: accent title, summary, action link and prose | any block |
| `image-card` | `:::image-card {src title description href}` | An image above its title and description | none |
| `link-card` | `:::link-card {href title description}` | A link card whose whole surface follows the target | none |
| `npm-badge` | `:::npm-badge {name version downloads}` | One static npm badge row | none |
| `qrcode` | `:::qrcode {text title}` | A scannable code; the text stays when `qrencode` is missing | none |
| `swiper` | `:::swiper` + `@slide {title}` | One page at a time, with a strip naming the pages | `slide` |
| `code-tree` | `:::code-tree {height}` + `@file path` | A file list beside the selected file's code; `height` is the code area's lines, scrollable beyond | `file` |
| `npm-to` | `:::npm-to {tabs}` + one `sh` fence | One npm command rewritten per package manager, shown as code tabs | one code block |

The shared markdown renderer also paints four inline forms: `==highlighted==` (with an optional `{.warning}` colour), `::icon-name::`, `:kbd[Ctrl+B]` and `:badge[text]{.tip}`. Emoji shortcodes such as `:tada:` were already part of the `etaf` dialect.

A QR is drawn outside a render, like a diagram: a publish reads the cache, a timer asks `qrencode` for what is missing, and a finished drawing republishes once. `npm-to` rewrites only the commands it knows and copies the rest; the selection of a `swiper` or a `code-tree` lives in the block state, so a theme switch or a resize keeps it.
