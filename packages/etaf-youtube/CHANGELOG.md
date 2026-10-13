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
  page offers seek, volume, mute, playback rate, quality, captions and
  theater mode.
- Explicit account writes: like, dislike, unsubscribe, save and comment are
  previewed offline unless the caller confirms, submitted writes that could
  not be read back are reported as unverified and never retried, and an
  account without a YouTube channel reports the blocked comment state.
- The application's own dark and light palettes with a collapsible sidebar
  and a viewport-adaptive card grid, plus a SQLite store for playback
  preferences and per-video resume positions.
