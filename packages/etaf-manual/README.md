# ETAF Reference Manual

[中文](README.zh-CN.md)

The ETAF Reference Manual documents every public interface of the core ETAF packages: ecss, ekp, ebox, etaf, etaf-ui and etaf-db. Like the Emacs Lisp Reference Manual, it is organized by subsystem and object, gives one definition entry for each public function, macro, variable, hook, error, component, Host, property, style property and theme token, and explains how each subsystem works through concepts and public interfaces. It is written in English and Simplified Chinese.

This repository holds the book source, the `etaf-manual` package, which reads the book as data for Emacs tools and the site build, and the Emacs reader application built with ETAF itself. The book is checked against the code: a build fails when a signature differs from its package's Commentary, when the text names a symbol that is not public, when a stated version is out of date, when a translation diverges, or when a runnable example fails to mount.

The book is complete: 87 chapters in twelve parts, appendices A-K, the concept index and the symbol index, in both languages. `M-x etaf-manual-open` opens it in Emacs, and the same sources are published as a website at <https://etaf.top>: English at the root, Simplified Chinese under `/zh-cn/`. `make site` builds the site from `book/`; `make site-publish` publishes it.

## Requirements

Emacs 29.1 or later, ETAF 0.2.2 and etaf-ui 0.1.3. The gate also reads the ecss, ekp, ebox, etaf, etaf-ui and etaf-db checkouts, which it expects next to this repository.

## Use

Add the repository root to `load-path`, together with ETAF and its dependencies, then require the package:

```elisp
(require 'etaf-manual)

(plist-get (etaf-manual-definition 'etaf-ref) :chapter)
     ⇒ reactivity
```

To read a chapter as Markdown, open its file below `book/en/` or `book/zh-CN/`; to read the manual as an application, use the reader below. The supported API is listed in the Commentary of [`etaf-manual.el`](etaf-manual.el).

## Reading the manual in Emacs

`M-x etaf-manual-open` opens the manual in its own buffer, built with ETAF itself. The reader reopens at the remembered reading position and shows a navigation column listing the parts and chapters, the article with definition cards and runnable examples, and — on wide frames — an on-this-page column that marks the section being read. Drag the divider beside either side column to resize it, or focus the divider and press Left/Right; the remembered position includes the widths. A header carries the breadcrumb and the language switch, a footer shows the key hints, and each chapter ends with previous/next chapter cards. The palette is `auto` by default and follows the Emacs theme; `t` switches between the light and dark palette, and a floating panel's title bar offers `亮`, `随` and `暗`, writing the same palette mode. Every line keeps the standard line height, so scrolling never shifts the layout; on a narrow frame the navigation column collapses into an overview screen that also lists the current chapter's sections, so page navigation stays reachable.

![The reader at a wide frame: navigation column, article and key-hint footer](examples/etaf-manual-reader-wide.png)

![The reader at a narrow frame: the navigation column collapses to the overview switch](examples/etaf-manual-reader-narrow.png)

- `n` / `p` move between sections, `u` goes one level up, `l` / `r` walk the reading history.
- `[` / `]` change chapter, `/` searches the whole book and `M-n` / `M-p` walk the matching sections, `i` jumps to a chapter, section, definition entry or index term, `g` switches between Chinese and English, `t` switches the palette, `q` closes the reader.
- `?` opens the ETAF key help listing the reader's keys with their labels.
- `TAB`, the arrows, `RET`, `M-g` and `Escape` keep the framework behaviours, so controls inside runnable examples stay focusable and operable.

A code span in the article whose text names a definition entry is itself a link: `RET` or a click over it opens that entry.

Every `elisp :run` example renders in place. Its viewer card offers *source*, *preview* and *side-by-side* modes, a run/rerun control and a stop control; the preview is the real, interactive ETAF View the example builds, not a screenshot. Press `e` (or the card's *Edit* button) to open the example in a native editor and `C-c C-c` to store the text as the example's draft and rerun it in place. Press `w` (or a code block's *Copy* button) to copy a code block, or the edited example source, to the kill ring.

An `elisp :figure` block is an inline illustration: the reader evaluates its last form and renders the View directly in the chapter, with a caption and no run controls, so a box model, a layout or a component can be shown where prose alone is not enough.

`M-x etaf-manual-lookup` opens the manual at a symbol's definition entry from any buffer; interactively it starts from the symbol at point when that symbol has an entry.

## Documentation

- [Writing the manual](docs/manual.md): the book format, the gate and the commands.
- [Introduction](book/en/introduction.md): the scope of the book and its notation.

## Development

Run `make setup-hooks` after cloning. `make book-check` runs the gate, `make coverage` prints how many interfaces of each package have an entry, and `make check` adds structure, compilation, the public scenarios in [tests/acceptance.json](tests/acceptance.json), the API boundary check and the gate's tool tests.
