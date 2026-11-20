# Changelog

All notable changes to the ETAF Reference Manual and the `etaf-manual` package are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Changed

- The archive pages file a package by where it belongs: adding `etaf-posframe`
  to the archive shipped it under "Other" until a section named it.  The writer
  now reports every package no section places, and the publisher refuses to
  deploy such a page, so a new package cannot reach readers as a nameless
  entry.

### Added

- A reader mounted by a host records the buffer it renders into, so its keys,
  its scrolling, its progressive rendering and its position saving work in a
  floating panel or a desktop host, not only in the buffer `etaf-manual-open`
  creates.

- The manual documents `etaf-posframe`: a "Floating Panels" part with the panel
  surface, the placement options, the title bar and theme toggle, the keyboard,
  the palette and the border strengths, and a "Panel Applications" chapter for
  registering, opening, keeping alive and binding a whole application.  The two
  chapters are now that package's only user documentation.
- `etaf-manual-reader-session` returns the reader session mounted in a buffer,
  or nil.  `etaf-manual-open` is one host of `etaf-manual-reader-view'; a
  floating panel or a desktop host is another, and each records its session in
  the buffer it renders into, so the reader's commands and their Host keys find
  the session instead of signalling that the buffer is not a reader.

### Changed

- The reader's palette mode gained `auto`: it is the default and follows the
  appearance the host provides, which a panel keeps in step with the Emacs
  theme, so a reader follows the theme until `t` pins light or dark.
- A reader mounted under a host declares its palette, its palette mode and the
  `亮`/`随`/`暗` modes there, so a panel framing it paints the reader's palette
  and its title bar offers the same three-mode switch as every other panel:
  both switches write one cell.
- The reader's header no longer carries its own palette switch; `t` switches
  the palette in the reader buffer and a panel's title bar offers all three
  modes.

### Fixed

- `n` and `p` now move the article, not only the navigation column: a host
  records the buffer the session renders into, which is what the scroll after
  a navigation reads.  Closing a host-mounted reader also finds its session.

- Unmounting a reader clears its partial render extent, so a kept-alive
  session reopens complete instead of resuming an extent no buffer grows.

- The archive's download count now counts installations instead of file fetches:
  a tarball counts only when the same client also requested its signature (what
  package.el does), one client counts once per package per UTC day, and the
  deployment verifier's requests stay excluded. Reprocessing the current access
  log turns 287 counted fetches into 83 installs.

### Added

- Every archive row names the package's author, linking the `emacs-taf`
  organization or the third-party author's GitHub account. Packages other
  authors publish through the archive are grouped under Community, and their page
  states the license, links the author's repository and explains that
  `M-x etaf-install` does not list them.
- The archive pages state when each package last changed, and each package page
  lists the newest `CHANGELOG.md` entries shipped with that version, the
  downloaded size and file count, and the packages that require it. The date is
  the newest commit that touched the files the package ships, so a release does
  not reset it. The index also filters by name, summary or requirement.
  `site/scripts/archive_pages.py` now owns page generation and runs against any
  published archive.
- `etaf-ui-qr-paint` and `etaf-ui-qr-login` have definition entries in both
  languages, so the manual covers etaf-ui 0.2.1 completely again.  The Gallery
  chapter states that its 63 specimens do not include the modal QR sign-in
  panel.
- The `check-book` gate validates package/version tables against the entry
  headers, so a version column cannot drift while the prose check still passes.

- Scoped `:on-help-open` preparation is documented in both languages, including
  modal boundaries, failure propagation and retained application state on close.

- The keyboard and overlay chapters document in-application modal help,
  effective-key snapshots, scoped notes, search and backdrop-click dismissal
  in both languages. The reader's `?` help stays in its original window.

- The manual is published as a website at <https://etaf.top> (`/` for English,
  `/zh-cn/` for Simplified Chinese).  It is built from the same book sources by
  `make site` and deployed by `make site-publish`; the other repositories now
  link chapters with site URLs (`https://etaf.top/<chapter>/`), and
  `scripts/check-references.py` resolves those links against the book.
- The gate checks bare `⇒` result lines without evaluating them: the line
  must follow a complete form and read as a value or end in a `; display`
  comment, and a wrapped value continues on the next line.  Appendix A, B
  and D must name every public error, hook and variable of the core packages.
- The Style System, Viewport and Scrolling chapters show one inline figure
  each, in both languages.
- The Emacs manual reader: `etaf-manual-open`, `etaf-manual-close` and
  `etaf-manual-lookup`, plus the headless session API
  (`etaf-manual-reader-create`, `etaf-manual-reader-state`,
  `etaf-manual-reader-view` and the navigation functions).  The reader shows
  an adaptive two-column layout with a collapsible navigation column,
  definition cards, language and palette switches, an index jump, and
  runnable examples that render in place with source, preview and
  side-by-side modes.  Every line keeps the standard line height, so
  scrolling never shifts the layout.  The reader's keys are declared on the page Host as
  `:keys', so `?' opens the ETAF key help listing them with their labels.
  A long chapter shows its first sections at once and appends the rest while
  Emacs is idle; a lookup renders through its entry immediately.
- Reader navigation and search: `/` searches the whole book and `M-n` /
  `M-p` walk the matching sections; `i` opens a jump completion over every
  chapter, section, definition entry and index term
  (`etaf-manual-reader-jump-targets`); and a code span in the article whose
  text names a definition entry links to that entry, so `RET` or a click
  over it opens the definition.  `etaf-manual-reader-search`,
  `etaf-manual-reader-search-next`, `etaf-manual-reader-search-previous`
  and `etaf-manual-reader-search-match` drive the same search headlessly,
  and `etaf-manual-lookup` starts from the symbol at point when it has an
  entry.
- Reader browsing: the navigation column lists the parts and chapters;
  the current chapter's sections live in the on-this-page column on wide
  frames and in the narrow overview screen otherwise; each chapter ends
  with previous/next chapter cards; and the reader remembers its reading
  position across sessions (`etaf-manual-reader-position-file',
  `etaf-manual-reader-remember', `etaf-manual-reader-restore').  Both
  side columns are draggable dividers: dragging resizes the column, a
  focused divider steps one column per arrow press, and
  `etaf-manual-reader-set-sidebar-width' / `-set-outline-width' set the
  widths programmatically; the remembered position includes them.
- Runnable examples can be edited in place: `e' opens the focused (or the
  current section's) example in a native editor and `C-c C-c' stores the
  text as its draft and reruns it beside the preview; the draft is what
  the run control, the source pane and `w' use.  `w' copies the focused
  code block, the focused example's draft or the current section's first
  code block to the kill ring, and every static code block carries a copy
  button.
- Reader polish: inline code and code blocks use a dedicated `:code-bg'
  palette color, so code stays readable inside tinted definition cards;
  a heading-only section keeps its following heading close instead of
  a full section gap; the on-this-page column hugs the current chapter's
  longest section title; and an example's toolbar keeps every control on
  one intact row, reserving the stop control's slot so running an
  example never resizes the card.
- Inline figures: a `elisp :figure' block evaluates its last form and the
  reader renders the View in the chapter as a static illustration with a
  caption, without run controls; six chapters show one, the book format
  documents the fence, and the acceptance tests mount every figure in
  both languages.
- The reader hides the buffer caret, so scrolling no longer makes a
  caret jump between contents; editing fields still raise their own bar
  cursor.
- Interactive reader surfaces react to the pointer: navigation and
  outline rows, chapter cards and code blocks paint the theme's `:hover'
  surface while hovered, and rendered links use the shared accent hover.
  Consecutive Chinese and Latin text keeps a separating space, including
  joined labels such as a chapter card's "上一章 18 盒与常规流".
- The generated concept index groups terms under symbols and A–Z, filing
  Chinese terms by the Pinyin of their first character; the symbol index
  groups functions, macros, variables, hooks and errors by package and the
  other entries by kind.
- The Introduction and the Reactivity chapter in English and Simplified Chinese.
- The `etaf-manual` package: `etaf-manual-book`, `etaf-manual-definition`, `etaf-manual-example-view`, the `etaf-manual-language` option and the `etaf-manual-error` condition.
- A gate that checks the book against the provider packages: signatures, public names, versions, links, coverage, translation structure and one line per paragraph. Runnable examples are mounted by the acceptance tests.
- The gate evaluates every `;; ⇒` result line in an `elisp` block and reports a value the form before it does not return, a result line without a preceding form, and a result value that is no readable datum; a line ending in a `; display` comment describes an object without a stable printed form and is not compared.
- The Values, Selectors, Style Properties and Component Styles and Themes chapters show one inline figure each, in both languages.

### Fixed

- The Introduction describes the published website and the Emacs reader
  instead of calling them unimplemented, names the reader commands, states that
  every definition entry belongs to one package, and notes that ECSS alone
  supports Emacs 28.1.

- The dependency chapter links to the version appendix instead of repeating a
  stale version table.  The appendix names its third column "Documented with"
  and states that each package's `Package-Requires` header holds the minimum.

- The Context condition messages and the focus-root message match the code, and
  the Chinese error entries quote their English messages instead of starting
  with an untranslated sentence.

- Version 0.1.5.

### Changed

- The version appendix documents etaf-ui 0.2.1, which adds the painted code
  and the sign-in panel.

- The site home page is a splash page: the icon, the pitch, one aligned
  capability grid and application and game galleries replace the single
  paragraph.  Every picture is a real session, links to its repository and
  opens full screen in a lightbox; the layout adapts down to a phone
  viewport, and the landing sets its text in a modern sans pairing (Inter
  and Space Grotesk) instead of the manual's reading fonts.
- The "Testing and Validation" and "Development and Release" chapters are folded into "Extending the Framework" as "How a change is verified" and "How a change is delivered", and the chapter that referred to them links to the new location.
