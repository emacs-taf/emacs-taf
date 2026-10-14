# Changelog

All notable user-visible changes to ETAF YouTube are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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
