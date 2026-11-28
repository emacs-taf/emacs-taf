# Changelog

All notable changes to `etaf-media` are documented in this file.

## [0.1.0] - 2026-11-28

### Added

- Extracted native video playback (`etaf-video` Component, source probing, audio sidecar, `libmpv` / `ffmpeg` playback sessions, hardware GPU overlay layers and `native/manifest.json`) from `etaf` into the standalone `etaf-media` core package.
- Registered GPU overlay synchronization via `etaf-overlay-sync-functions` and UI viewer integration via `etaf-video-driver`.
