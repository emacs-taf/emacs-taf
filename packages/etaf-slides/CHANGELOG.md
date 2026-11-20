# Changelog

All notable user-visible changes to this package are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## Unreleased

## 0.1.0

### Added

- Markdown decks with optional front matter and dash-separated slides, where
  the first heading of a slide is its title.
- `::: notes` blocks rendered in a band above the footer when notes are shown.
- An aspect-preserving 16:9 stage that fills the window, centered with a
  letterbox, plus a footer carrying the deck title, the position and the clock.
- A presentation opens at four text scale steps, about twice the body size,
  with `+` and `-` to change it and `0` to return; the stage re-fits around the
  larger cells, so the type stays the user's own font scaled up.
- Cover, section and content layouts, with the slide body rendered by the
  shared ETAF UI Markdown renderer.
- A slide overview with notes and overflow markers.
- Keys for paging, the overview, jumping by number, the theme, the notes, the
  clock, fullscreen, editing the source and closing.
- Sessions with reactive state: a slide, theme, mode or notes change repaints
  the mounted deck without a remount.
