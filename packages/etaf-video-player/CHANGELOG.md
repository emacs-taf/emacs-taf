# Changelog

## Unreleased

### Changed

- The player opens as an ETAF application: its keys are root keys of the
  View, the canvas follows the appearance and refits once a window resize
  settles, and closing goes through the application lifecycle. It requires
  ETAF 0.3.0 and ETAF UI 0.2.0.

### Added

- Three render modes in one player: `etaf-video-player-render-mode` and the
  `:mode` hint choose `image`, `ascii` (density ramp) or `color` (true-color
  half blocks), and `C` switches a running player without losing its position,
  rate or audio state.  `etaf-video-player-color-columns` caps the fitted
  color canvas.  This replaces the separate `etaf-ascii-video` application.

- `etaf-video-player-doctor` reports ffmpeg, ffprobe and SQLite availability in the
  same shape as `etaf-install-doctor`, so the installer can show what is missing
  before the player opens.

### Fixed

- A canvas fits a frame that cannot answer `posn-at-point` (batch, headless or
  a mounted-but-unshown buffer): the fitted grid comes from the measured stage
  size and only its placement needs the pointer position.

- Killing the player buffer saves the playback position like `q`; it kept
  only the last periodic write, so reopening could resume earlier than where
  playback stopped.

- `etaf-video-player-close` outside a player buffer signals `user-error`
  instead of killing the current buffer.

- Closing the player restores the frame's own background. The player saved a
  frame parameter that does not exist, so the frame kept the player's chrome
  color after it closed.

- Declare the `etaf-db` dependency. Playback history requires it, but the header
  omitted it, so `package.el` could install the player without it.

## Unreleased

### Fixed

- The open prompt reads file names the way `find-file` does: a pasted
  absolute or `~` path is accepted instead of being refused with
  "(match required)" because it does not match the current directory's
  completions.

- A source typed as `~/Videos/clip.mp4` or a name relative to the calling
  buffer plays the file instead of falling back to default metadata; the
  player resolves the name before the decoder opens it.

### Added

- Video playback in an ETAF buffer as sharp image frames with sound, built on
  the framework's native `etaf-video` Component: ffmpeg decodes at the
  display's device pixel ratio, an ffplay sidecar plays the source's audio, and
  every frame is one incremental publication of a fixed canvas Host.
- Local files, HTTP(S) streams and a generated built-in demo; play/pause,
  single-frame stepping, seeking, 0.5x to 8x rates, volume keys, a sound
  toggle, four grid presets and window fitting.
- Retina-sharp frames by default (`etaf-video-player-device-pixel-ratio` can
  force logical pixels) and an automatic density-ramp fallback when the frame
  cannot show images.
- A playlist sidebar: open several sources as one queue, click an item to
  play it, move with next/previous, and let a finished item advance per the
  loop mode (off, list, one).  Shuffle is a toggle; enqueue and remove edit
  the queue without interrupting the running item.
- A themed application shell with an etaf-ui transport: header status, a
  `etaf-range` progress bar you can click or drag to seek, and buttons for
  play/pause, ±5 s, volume and mute.  The play/pause and sound glyphs follow
  the live state through retained Host updates, so the View is never
  republished for a playback second.
- Subtitles: a local video loads the first readable `.srt` or `.vtt` track
  beside it (including `movie.zh.srt`) and shows one line under the canvas;
  `c` hides, shows or loads a track and `etaf-video-player-subtitle-load`
  attaches one from Lisp.  Malformed cues are skipped and inline markup is
  stripped.
- Resume: local playback positions persist in a small `etaf-db` SQLite
  database (`etaf-video-player-history-file`); reopening continues past five
  seconds unless the record is near the end, and the database fails open so
  playback never depends on it.
- Screenshots: `S` decodes the current frame with ffmpeg into a PNG beside the
  video (or the temporary directory for a stream) in the background.
- `etaf-video-player-state` exposes the live player as plain data for scripts
  and tests.
- Acceptance scenarios over fake ffmpeg, ffprobe and ffplay fixtures plus
  gated real-ffmpeg demo and screenshot scenarios, so the public path stays
  testable without a decoder, network or sound card.

### Changed

- `M-x etaf-video-player-open` opens the player on the built-in demo instead
  of asking for a video file; `etaf-video-player-open-file` (also `o`) and
  `etaf-video-player-open-url` (`u`) are the commands that read a source.

- `?`, `C-c h` and the header help button share a searchable, themed modal
  inside the player. Concise labels follow the effective bindings; Escape
  exits one layer at a time, and clicking outside closes help without
  changing playback or splitting the window.

- The three-pane shell was rebuilt around a four-step depth palette: the
  page, panes, header and transport each paint one step, the details pane
  groups facts into 视频信息/播放设置/画布 sections with aligned values, and
  the transport is a full-width timeline with a centred control row.  The
  light appearance no longer paints every surface the same near-white, and
  the stage follows the appearance (near-black dark, shallow grey light)
  while letterbox frames stay black.
- The header reports only the playback status; the frame-rate sample moved out
  of the status line, and the key-hint footer shrank to the common keys.
- Narrow windows use a short hint footer and drop the loop/shuffle buttons
  without changing the underlying keys.
- The player buffer no longer shows a mode line.
- The playlist sidebar draws a count badge instead of a bare number.

### Fixed

- The minibuffer and echo area borrow window lines without refitting the
  canvas: the player keeps the size it committed until the prompt closes.
