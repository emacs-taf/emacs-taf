# Changelog

All notable user-visible changes to ETAF YouTube are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-11-26

### Added

- Full-bleed Cinema Watch View with pure dark `#050608` video stage, 1-row Retained Host subtitle strip, de-boxed Studio transport deck, 200ms zero-reflow HUD telemetry, and a 5-tab workbench (`简介`, `字幕`, `评论`, `推荐`, `队列`) plus narrow/theater `etaf-drawer` (`i`).
- Single-probe full stream ladder (`2160p60 4K` through `144p`) in `backends/youtube/lib/source.mjs` with CDP cookie export (eliminating macOS Keychain `--cookies-from-browser` failures), native chapter metadata, prioritized subtitle lists, direct fast `--url` caption fetch, and instant in-place quality switching (`Q`) with alternate protocol failover.
- Complete YouTube-native playback workflow: `0`–`9` percentage jumps, `j`/`l` ±10s, `,`/`.` frame stepping, `M-n`/`M-p` chapters, `N`/`P` playback queue with `L` auto-next, `A` zero-CPU audio-only background mode with persistent mini-player bar, `v` floating PiP window, `o` external `mpv` handoff, `O` browser launch, `y` Org timestamp links, direct URL/ID paste in search, account menu dialog, and `etaf-activity-publish` integration.
- `etaf-youtube-doctor` integrated with `M-x etaf-install` and `M-x etaf-install-doctor`, plus full monorepo and archive packaging support.
- Obsidian Cinema (dark) and Editorial Daylight (light) four-tier palettes with full-bleed bordered video cards, O(1) cached resume badges and progress strips, all 8 destinations in both expanded sidebar and compact icon rail, and search filter pills.

### Changed

- Preserved the user's original Emacs mode-line (`:mode-line t`) in `etaf-youtube-open` and aligned interactive state transitions to invariant border geometry with strict hover discipline.
- Replaced per-second full-tree Watch re-renders with 200ms Retained Host leaf updates and O(log N) binary-search caption lookup.

### Fixed

- Fixed `etaf-youtube-subscribe` sending the video ID instead of `:channel_id` (`UC...`) to the backend.
- Fixed empty-string `:proxy` and `:audio_url` values crashing `etaf-video` and `etaf-youtube-images` on direct network routes.
- Fixed preview and blocked write responses mutating local `:like_status` or `:subscribed` UI state before confirmation.
- Fixed `etaf-youtube-login` / `etaf-youtube-logout` refreshing mounted `etaf-app` sessions via `(etaf-app-state)` instead of a removed legacy variable.
- Fixed `RET` ignoring the focused interactive Host control in favor of the selected list card.
- Fixed comment reply loading reactivity, reply collapse/expand, comment/related pagination, expandable long video descriptions, and auto-dismissing toast timers.

## [0.1.1]

### Added

- Initial native ETAF YouTube client with bundled `backends/youtube/`, feed browsing, search, watch page playback, explicit confirmed writes, SQLite preferences and resume storage, and dark/light themes.
