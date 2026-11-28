# Changelog

## Unreleased

### Added

- Welcome / Continue Watching home screen: calling `M-x etaf-video-player-open` with no source now opens a clean launcher displaying recent watch history with progress bars, engine status and quick open actions without spawning any background decoder; `M-x etaf-video-player-demo` (`d`) opens the built-in test pattern explicitly.
- Cross-platform `libmpv` native backend integration (powered by ETAF's `etaf-video` dynamic module with automatic `ffmpeg`/`ffplay` fallback): hardware decoding telemetry, gapless audio/video sync, instant scrubbing, native `libass` subtitle rendering (embedded ASS/SSA/SRT/PGS + external subtitles without duplicate bottom text strips) and in-place canvas resize.
- Finder / OS drag-and-drop support (`dnd-protocol-alist`): drop video files, folders, `.m3u`/`.m3u8` playlists or `.srt`/`.vtt`/`.ass`/`.ssa` subtitle files directly onto the player window.
- 4-tab right Studio drawer (`播放` / `轨道` / `画面` / `信息`): multi-audio track selector (`v`, `etaf-video-player-set-audio-track`, `etaf-video-player-cycle-audio-track`), ±0.1 s audio delay, unified embedded + external subtitle selector (`V`, `etaf-video-player-set-subtitle-track`, `etaf-video-player-cycle-subtitle-track`), bilingual secondary subtitles (`etaf-video-player-set-secondary-subtitle`), subtitle font scaling, aspect ratio override (`auto`/`16:9`/`4:3`/`2.39:1`), 90° rotation (`r`, `etaf-video-player-rotate`), horizontal mirror, deinterlace, live brightness/contrast/saturation equalizer and active engine/hwdec diagnostics.
- Additional product workflow commands: `.m3u`/`.m3u8` playlist parsing, sibling video loader (`etaf-video-player-enqueue-siblings`), alphabetical queue sort (`etaf-video-player-sort-queue`), backward frame step (`,`, `etaf-video-player-step-back`), copy timestamp (`y`, `etaf-video-player-copy-timestamp`), stop-after-current (`etaf-video-player-toggle-stop-after-current`), speed reset (`=` / `DEL`), mute alias (`M`) and percentage/relative `g` jumps (`50%`, `+15`, `-10`).
- Cinema Theater and Studio collapsible drawers: single videos open unobstructed in Cinema Theater mode (`w` toggles theater mode, `p` toggles the left Media drawer, `i` toggles the right Studio drawer; `etaf-video-player-default-layout` and `:layout` configure the initial state).
- Left Media drawer tabs: inline-filterable Queue with reorder (`K` / `J`), remove (`D`) and watched progress indicators; embedded container Chapters (`M-n` / `M-p`) probed asynchronously via `ffprobe -of json`; persistent SQLite timestamp Bookmarks (`m`, `etaf-video-player-add-bookmark`, `etaf-video-player-bookmarks`, `etaf-video-player-bookmark-add`, `etaf-video-player-bookmark-remove`); and browsable Watch History (`etaf-video-player-history-recent`, `etaf-video-player-history-delete`, `etaf-video-player-history-clear`).
- Right Studio drawer tabs: interactive Controls (one-click `0.5x`–`3x` speed matrix, A-B loop controls, multi-track subtitle selector and offset nudge, render-mode switcher and fit/screenshot buttons) and full `ffprobe` Media Info (video codec/profile/pixel format/color space/bitrate, audio codec/channels/sample rate and file size).
- Precision playback controls: A-B section looping (`A`, `B`, `etaf-video-player-set-ab-start`, `etaf-video-player-set-ab-end`, `etaf-video-player-clear-ab`), exact timestamp jump (`g`, `etaf-video-player-goto-time`), clickable remaining-time readout, multi-language sibling subtitle discovery and transient context-footer action feedback.
- Directory playback: `etaf-video-player-open`, `etaf-video-player-open-file` and `etaf-video-player-enqueue` expand a directory into a sorted playlist of video files, and non-active playlist items probe lazily on selection instead of blocking startup.
- Scrollable playlist sidebar and semantic `:region` navigation (`M-g` for header, media drawer, studio drawer and transport).
- Buffering (`缓冲中`) and decoder error (`出错`) status reporting in the header HUD and `:buffering` / `:error` keys in `etaf-video-player-state`.
- Live clock and volume readout preview while dragging the timeline or volume `etaf-range` sliders.
- Quick playback keys: `0` (restart from zero), `C-f` / `C-b` (±30 s seek) and `z` / `x` (±0.5 s subtitle timing offset).
- Single-dimension grid hints: passing `:columns` or `:rows` alone to `etaf-video-player-open` derives the other dimension from the source aspect ratio.

### Changed

- Redesigned the interface around the Obsidian Cinema (dark) and Alabaster Studio (light) palettes, single-row elevated header with quick spec badges and semantic status pill, three-zone transport dock and leaf-scoped reactive drawers.
- Refined the playback speed ladder to `0.5x`, `0.75x`, `1x`, `1.25x`, `1.5x`, `2x` and `3x`.
- The player preserves Emacs's mode line (`:mode-line t`) and never modifies the frame's default background face; window edge alignment uses buffer-local `fringe` remapping instead.
- All public configuration variables are now `defcustom` options under the `etaf-video-player` group, and `etaf-video-player-doctor` checks `etaf-video-ffmpeg-program` (required) plus `etaf-video-ffprobe-program`, `etaf-video-ffplay-program` and SQLite (optional).
- Playback refs (`speed`, `loop`, `shuffle`, `audio`, `volume`, `ab-loop`, drawer tabs, async media info) now update leaf Components without republishing the root shell, idle status ticks skip unchanged retained Host writes, and opening a local video with resume history starts ffmpeg once at the fitted size and saved offset.
- Cycling render mode (`C`) on a text terminal switches directly between `ascii` and `color` and re-fits the canvas when entering or leaving `color` mode.

### Fixed

- Body panes (playlist, stage and details) now match `body-rows` instead of overshooting behind the transport bar by two rows, restoring the playlist summary, true vertical centering of the video and full visibility of height-constrained frames; the duplicate `:ref 'video-theme` button in the details pane and stale `:font-size` overrides were removed.
- Single-item repeat (`loop = 'one`), repeated playlist entries, shuffle navigation (`>` / `<`), and `loop = 'none` + `shuffle` termination now behave accurately, and `etaf-video-player-play-index` starts from the beginning instead of jumping to saved history.
- Subtitle timestamp parsing handles integer seconds (`00:00:01`), variable-length fractions (`.5`, `,50`), `SS.mmm`, WebVTT `NOTE` blocks, UTF-8 BOMs and overlapping cues; empty or unparseable subtitle files beside a video no longer block `c` from prompting for another file.
- History database caching compares expanded paths so `~/` paths do not re-initialize SQLite on every tick, and `etaf-video-player-save-screenshot` expands `~/` targets, forwards stream `:headers`/`:proxy`, and avoids same-second filename collisions.
- Clicking the video canvas updates the play/pause UI immediately, `etaf-video-player-set-grid` re-centers the canvas in the stage, and the loop button tooltip names uppercase `(L)`.

### Changed

- Reissued: the source had moved ahead of this version without a release, so the published file no longer matched it. Changed since 0.2.1 was cut: `lisp/etaf-video-player-app.el`, `lisp/etaf-video-player-views.el`.
### Changed

- The player opens as an ETAF application: its keys are root keys of the View, the canvas follows the appearance and refits once a window resize settles, and closing goes through the application lifecycle. It requires ETAF 0.3.0 and ETAF UI 0.2.0.

### Added

- Three render modes in one player: `etaf-video-player-render-mode` and the `:mode` hint choose `image`, `ascii` (density ramp) or `color` (true-color half blocks), and `C` switches a running player without losing its position, rate or audio state.  `etaf-video-player-color-columns` caps the fitted color canvas.  This replaces the separate `etaf-ascii-video` application.

- `etaf-video-player-doctor` reports ffmpeg, ffprobe and SQLite availability in the same shape as `etaf-install-doctor`, so the installer can show what is missing before the player opens.

### Fixed

- A canvas fits a frame that cannot answer `posn-at-point` (batch, headless or a mounted-but-unshown buffer): the fitted grid comes from the measured stage size and only its placement needs the pointer position.

- Killing the player buffer saves the playback position like `q`; it kept only the last periodic write, so reopening could resume earlier than where playback stopped.

- `etaf-video-player-close` outside a player buffer signals `user-error` instead of killing the current buffer.

- Closing the player restores the frame's own background. The player saved a frame parameter that does not exist, so the frame kept the player's chrome color after it closed.

- Declare the `etaf-db` dependency. Playback history requires it, but the header omitted it, so `package.el` could install the player without it.

## Unreleased

### Fixed

- The open prompt reads file names the way `find-file` does: a pasted absolute or `~` path is accepted instead of being refused with "(match required)" because it does not match the current directory's completions.

- A source typed as `~/Videos/clip.mp4` or a name relative to the calling buffer plays the file instead of falling back to default metadata; the player resolves the name before the decoder opens it.

### Added

- Video playback in an ETAF buffer as sharp image frames with sound, built on the framework's native `etaf-video` Component: ffmpeg decodes at the display's device pixel ratio, an ffplay sidecar plays the source's audio, and every frame is one incremental publication of a fixed canvas Host.
- Local files, HTTP(S) streams and a generated built-in demo; play/pause, single-frame stepping, seeking, 0.5x to 8x rates, volume keys, a sound toggle, four grid presets and window fitting.
- Retina-sharp frames by default (`etaf-video-player-device-pixel-ratio` can force logical pixels) and an automatic density-ramp fallback when the frame cannot show images.
- A playlist sidebar: open several sources as one queue, click an item to play it, move with next/previous, and let a finished item advance per the loop mode (off, list, one).  Shuffle is a toggle; enqueue and remove edit the queue without interrupting the running item.
- A themed application shell with an etaf-ui transport: header status, a `etaf-range` progress bar you can click or drag to seek, and buttons for play/pause, ±5 s, volume and mute.  The play/pause and sound glyphs follow the live state through retained Host updates, so the View is never republished for a playback second.
- Subtitles: a local video loads the first readable `.srt` or `.vtt` track beside it (including `movie.zh.srt`) and shows one line under the canvas; `c` hides, shows or loads a track and `etaf-video-player-subtitle-load` attaches one from Lisp.  Malformed cues are skipped and inline markup is stripped.
- Resume: local playback positions persist in a small `etaf-db` SQLite database (`etaf-video-player-history-file`); reopening continues past five seconds unless the record is near the end, and the database fails open so playback never depends on it.
- Screenshots: `S` decodes the current frame with ffmpeg into a PNG beside the video (or the temporary directory for a stream) in the background.
- `etaf-video-player-state` exposes the live player as plain data for scripts and tests.
- Acceptance scenarios over fake ffmpeg, ffprobe and ffplay fixtures plus gated real-ffmpeg demo and screenshot scenarios, so the public path stays testable without a decoder, network or sound card.

### Changed

- `M-x etaf-video-player-open` opens the player on the built-in demo instead of asking for a video file; `etaf-video-player-open-file` (also `o`) and `etaf-video-player-open-url` (`u`) are the commands that read a source.

- `?`, `C-c h` and the header help button share a searchable, themed modal inside the player. Concise labels follow the effective bindings; Escape exits one layer at a time, and clicking outside closes help without changing playback or splitting the window.

- The three-pane shell was rebuilt around a four-step depth palette: the page, panes, header and transport each paint one step, the details pane groups facts into 视频信息/播放设置/画布 sections with aligned values, and the transport is a full-width timeline with a centred control row.  The light appearance no longer paints every surface the same near-white, and the stage follows the appearance (near-black dark, shallow grey light) while letterbox frames stay black.
- The header reports only the playback status; the frame-rate sample moved out of the status line, and the key-hint footer shrank to the common keys.
- Narrow windows use a short hint footer and drop the loop/shuffle buttons without changing the underlying keys.
- The player buffer no longer shows a mode line.
- The playlist sidebar draws a count badge instead of a bare number.

### Fixed

- The minibuffer and echo area borrow window lines without refitting the canvas: the player keeps the size it committed until the prompt closes.
