# ETAF Video Player architecture

## Responsibilities

`etaf-video-player` is an application. It owns the Welcome / Continue Watching home screen, OS drag-and-drop handling, `.m3u` and directory queue expansion, fitted canvas geometry, Cinema Theater and 4-tab Studio drawers, subtitles, playback history and bookmarks, status reporting and keys; the buffer, its canvas settings, mode line preservation and single close path come from ETAF's application runtime (`etaf-app-open`). Decoding, `libmpv` native playback (with runtime `dlopen`/`LoadLibrary`, hardware decoding, `libass` subtitles, filters and audio), `ffmpeg`/`ffplay` fallback and retained frame publication belong to ETAF's native `etaf-video` Component, driven exclusively through ETAF's public handle APIs (`etaf-video-play`, `etaf-video-pause`, `etaf-video-seek`, `etaf-video-step`, `etaf-video-step-back`, `etaf-video-set-property`, `etaf-video-get-property`, `etaf-video-command`). No framework mechanism or `ebox-` internal is re-implemented or called here.

| Module | Owns |
| --- | --- |
| `etaf-video-player-app` | single-source reactive player state, Welcome mode, buffer-local Finder DND, `.m3u`/directory expansion, drawer layout policy, `libmpv` property/command bridge (tracks, dual subtitles, audio delay, rotation/mirror/deinterlace/color EQ, native A-B loop, `screenshot-to-file`), chapters/bookmarks/history actions, deterministic stage fitting, shell assembly, dirty-checked retained status updates, root keys and public commands |
| `etaf-video-player-views` | layout breakpoints and pure shell Components (Welcome / Continue Watching launcher, elevated header, collapsible left Media drawer with Queue/Chapters/Bookmarks/History leaf tabs, collapsible right Studio drawer with Playback/Tracks/Video/Media Info leaf tabs, three-zone transport dock with leaf controls, context footer) |
| `etaf-video-player-theme` | Obsidian Cinema (dark) and Alabaster Studio (light) surface/semantic palettes and their ETAF UI token projection |
| `etaf-video-player-media` | non-blocking `ffprobe -of json` stream/chapter telemetry with target caching, multi-language sibling subtitle discovery and byte/bitrate formatters |
| `etaf-video-player-subtitle` | SubRip/WebVTT parsing and O(log n) overlapping-aware cue lookup for the `ffmpeg` fallback subtitle strip |
| `etaf-video-player-history` | `etaf-db` SQLite store (`playback_history` and `bookmarks` tables) with expanded-path caching; every operation fails open |

The root entry re-exports the supported subset and implements `etaf-video-player-doctor`; everything unlisted is internal.

## Data flow

1. `etaf-video-player-open` with `nil` mounts a Welcome player (`:welcome t`) showing recent SQLite watch history and engine availability without spawning any decoder or status timer. With a source (file, directory, `.m3u`/`.m3u8` playlist, HTTP(S) URL or plist), it validates entries up front, probes only the starting item through `etaf-video-source-info`, attaches `:start` when resumable from SQLite history, chooses initial drawer state from `:layout` or `etaf-video-player-default-layout`, installs buffer-local `dnd-protocol-alist`, and opens `*Video Player*` with `:mode-line t`.
2. During initial mount, `etaf-video-player--shell` computes the real fitted canvas size from `(etaf-viewport)` so `etaf-video` spawns once at final dimensions and resume offset. On `libmpv`, canvas resizes update the render dimensions in place without restarting decoding. In parallel, `etaf-video-player-media-probe-async` runs `ffprobe -of json` via `etaf-process-run` to enrich container/bitrate/codec metadata.
3. The `etaf-video` Component owns the playback session (`libmpv` when available on GUI `image` mode, otherwise `ffmpeg`/`ffplay`), publishing frames through `etaf-runtime-update-host-content`. On `libmpv`, subtitles render directly into video frames via `libass`, so `--shell` sets `caption-row` to `nil` (avoiding duplicate subtitles and reclaiming one vertical row); on `ffmpeg`, `--shell` reserves one bottom stage row for parsed `.srt`/`.vtt` text cues.
4. The status timer polls `etaf-video-state` four times per second: on `libmpv` it synchronizes live `track-list`, `chapter-list`, `hwdec-current`, `sub-visibility` and active audio/subtitle selections into leaf refs; it enforces A-B loopback on `ffmpeg` (native `ab-loop-a`/`ab-loop-b` handles `libmpv`), enforces `stop-after-current` on track end, and diffs each retained Host string against cached values so idle paused ticks perform zero buffer writes.
5. Interactive state (`speed`, `loop`, `shuffle`, `audio`, `volume`, `playing`, `progress`, `ab-loop`, `stop-after-current`, `media-info`, `chapters`, `tracks`, `hwdec`, `audio-delay`, `subtitle-offset`, `subtitle-scale`, `secondary-sid`, `rotate`, `mirror`, `deinterlace`, `brightness`, `contrast`, `saturation`, `bookmarks`, `history`, `left-tab`, `right-tab`, `queue-filter`) lives in reactive refs passed by reference to leaf Components and is never dereferenced in `--shell`, so adjusting any control, switching any drawer tab, or receiving live track/telemetry updates never republishes the root shell.
6. Closing (`q`, `etaf-video-player-close`, killing the buffer, or opening another source) saves the local playback position and cancels the status timer before unmounting the ETAF Runtime and destroying the native playback session.

## Invariants

- **One owner per fact.** Reactive refs are the single source of truth for player state; the native session owns decoding, timing, audio and `libmpv` filters; the application owns Welcome state, canvas geometry, drawer visibility, queue policy and status text; ETAF owns publication.
- **Zero idle decoder on Welcome.** Opening the player without a source spawns zero decoder or probe processes until the user selects media or explicitly invokes demo mode.
- **Retained isolation.** Changing volume, audio, speed, loop, shuffle, playing, progress, A-B loop, stop-after-current, tracks, audio/subtitle delay, color EQ, rotation, mirror, deinterlace, drawer tabs, queue filter or async media info never re-renders `--shell`. Idle paused ticks perform zero retained Host updates.
- **Buffer-scoped appearance.** The player keeps Emacs's mode line (`:mode-line t`) and never modifies the frame's `default` face or other windows; buffer-local `default` and `fringe` remappings align the player's own window edges with its palette.
- **Exact pane partition.** Header (`1` row), body (`body-rows` shared by optional left Media drawer, stage and optional right Studio drawer), transport (`5` rows) and footer (`1` row) partition `viewport-rows` without overlap.
- **Cleanup is unconditional.** Every open failure, close, buffer kill or timer tick after buffer death cancels the status timer and releases the Runtime and native session.

## Measured behavior

Frame cost is the native Component's cost (`libmpv` SW render + PPM image creation, or `ffmpeg` MJPEG pipe) plus retained publication of the canvas plane. Maintained workspace benchmarks (`video-player.frame`, `video-player.volume`, `video-player.mute` in `benchmarks/performance-scenarios.el`) run with `--mode gui` on a real clip through `TAF_VIDEO_SOURCE`.

- `ebox-update-prepare-report` must report `ready` for the canvas content update, which is why `etaf-video` declares `:position`/`:left`/`:top` directly as a root-level absolute plane.
- `ebox-buffer-update-report` keeps control updates scoped: toggling volume, mute, tracks, color EQ or Studio tabs updates zero root-shell owners.
