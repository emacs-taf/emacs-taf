# Changelog

All notable user-visible changes to ETAF YouTube are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The client runs on the ETAF application runtime and requires etaf 0.3.0
  and etaf-ui 0.2.0. Running `M-x etaf-youtube-open` again shows the open
  session instead of mounting it a second time.

### Fixed

- The window area around the interface now uses the client's dark or light
  appearance and follows `d`, instead of keeping the Emacs theme's background.

### Added

- `M-x etaf-youtube-login` signs in from Emacs: it opens the controlled browser,
  waits for the page to report a session, then reloads the open sessions;
  `M-x etaf-youtube-account` reports the account. The client runs the YouTube
  backend bundled in `backends/youtube/` instead of calling `pi-skill`, and
  `M-x etaf-youtube-logout` clears this site's session in that browser.

- A native YouTube client as one ETAF text application: home, Shorts,
  subscriptions, history, playlists, watch later, liked and live feeds;
  search with filters; channel and playlist pages; and a video page with
  details, comments, replies and recommendations.
- Native playback through the ETAF video Component: the skill resolves
  separate video and audio streams with their headers and proxy, the video
  decoder and the ffplay sidecar receive the same network options, and the
  page offers seek, volume, mute, playback rate, quality, theater mode and
  captions, which render the cue that covers the playback position as one
  subtitle line under the canvas.
- Explicit account writes: like, dislike, unsubscribe, save and comment are
  previewed offline unless the caller confirms, submitted writes that could
  not be read back are reported as unverified and never retried, and an
  account without a YouTube channel reports the blocked comment state.
- The application's own dark and light palettes with a collapsible sidebar
  and a viewport-adaptive card grid, plus a SQLite store for playback
  preferences and per-video resume positions.

### Fixed

- The native point caret no longer draws a second selection bar over
  navigation content: focused controls show the catalog's own focus cue
  (underline, plus a fill when the control has no surface), while a text
  field keeps its caret inside the input session.  Chips and rail items
  derive a visible hover fill from their own surface instead of hovering in
  their resting color.
- The account avatar shares the toolbar icons' line metrics. A three-row
  toolbar and tighter feed/rail spacing keep navigation and the first row
  of videos close together instead of stacking large empty padding bands.
- Window fitting now uses ETAF's automatic usable viewport instead of raw
  window pixels, preventing whole padding rows from disappearing when the
  sidebar is hidden. Duration labels use an opaque palette surface supported
  by both text faces and rounded backgrounds. Thumbnail dimensions round to
  the nearest display cell, keeping the duration over the picture rather
  than dropping a full image row.
- Fresh feeds no longer highlight the first card before any selection.
  Model API consumers must accept nil for `:selected`; explicit selection
  chooses the first item (or the last when moving backwards), and activation
  without a selection does nothing.
  Sidebar controls and filter chips use balanced vertical padding rather
  than rounding a one-line label into the first of two layout rows.
- Card selection and thumbnail completion update only cards whose visible
  state changed, avoiding repeated rebuilding of the rest of the feed.
- The complete top bar now keeps a fixed layout slot while only the content
  below it scrolls. Scrolling, loading and resizing no longer replace it with
  the empty first row of a single-line sticky header.
- Navigation has consistent SVG icons and selected states in both sidebar
  sizes. Filter chips have larger targets, video cards separate title/channel
  metadata and duration badges, and Shorts use their own portrait grid.
  Opening the application no longer splits the current window.
- The header centers its theme-aware search field between balanced control
  groups, with SVG icons and a circular account avatar. Resizing clears stale
  horizontal scroll so the header cannot remain shifted out of the window.
- Missing custom thumbnail variants fall back to the video's standard JPEG
  on the same route; HTTP errors do not trigger a slow direct-network probe.
  Refresh retries failed artwork. Portrait covers keep their aspect ratio,
  and Shorts retain their label instead of showing a false zero duration.
- Application keys are declared on the view instead of a buffer keymap, so
  they keep working while a row has focus, `?` lists them, and the search
  field keeps every key while it edits.  The mounted player is connected to
  the session, so the transport clock and
  the recorded position follow playback, and pause, seek, volume and mute
  reach the decoder.
- Content below the sidebar breakpoint lays out inside the icon rail instead
  of running under it, and the watch transport wraps or shortens the canvas
  in narrow and short windows instead of clipping its controls.
