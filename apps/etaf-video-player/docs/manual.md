# ETAF Video Player manual

## Welcome screen and opening sources

`M-x etaf-video-player-open` with no argument opens the Welcome / Continue Watching launcher screen inside `*Video Player*` without prompting or spawning any background decoder. From the Welcome screen you can click recent watch-history cards to resume where you left off, remove individual records, open a local video, folder or `.m3u`/`.m3u8` playlist (`o`), open an HTTP(S) or `yt-dlp` URL (`u`), switch dark/light appearance (`T`), or explicitly launch the generated 30-second test pattern (`d` or `M-x etaf-video-player-demo`).

Drag-and-drop works on both the Welcome screen and active playback: dropping a video file, directory or `.m3u`/`.m3u8` playlist from Finder or your OS file manager opens it immediately; dropping a `.srt`, `.vtt`, `.ass` or `.ssa` file while playing attaches that subtitle track directly.

To name a source up front, `etaf-video-player-open-file` plays a local file, expands a directory of videos into a sorted playlist, or parses a `.m3u`/`.m3u8` playlist (preserving `#EXTINF` titles and resolving relative paths). `etaf-video-player-open-url` (`u`) plays an HTTP(S) stream (and web video URLs when `libmpv` and `yt-dlp` are installed). All entry points reuse `*Video Player*`, saving the previous video's position and closing its session before opening the new source. `etaf-video-player-close` (`q`) and killing the buffer both save the position, cancel timers, destroy the native session and unmount the ETAF Runtime.

The player buffer hides its cursor and preserves Emacs's mode line and frame background so split windows and other buffers keep their own theme.

## Cross-platform libmpv engine and ffmpeg fallback

Decoding, scaling, sound and frame publication belong to ETAF's native `etaf-video` Component. When ETAF's dynamic module (`etaf/native/etaf-video-mpv.{dylib,so,dll}`) and the system `libmpv` shared library are available on a graphical Emacs 29.1+ frame, the player automatically uses `libmpv` (`etaf-video-engine` = `'auto`): hardware decoding (`hwdec=auto-safe`), gapless single-engine audio/video synchronization, instant scrubbing, backward frame stepping, live multi-audio and embedded/ASS/PGS/bilingual subtitle rendering via `libass`, live aspect/rotation/mirror/deinterlace/color equalizer controls, and in-place canvas resize without restarting playback.

To enable `libmpv` on macOS, Linux or Windows, install the system `libmpv` shared library (for example `brew install mpv` on macOS, `sudo apt install libmpv2` or `pacman -S mpv` on Linux, or `libmpv-2.dll` on Windows) and run `M-x etaf-install-native` (selecting `etaf`) to download the prebuilt `etaf-video-mpv` dynamic module into `~/.cache/emacs-taf/native/` without a compiler (in a source checkout, `sh native/build-video-mpv-module.sh` inside `etaf` also builds it locally; no `libmpv` headers are required at compile time because the module resolves `libmpv` via `dlopen`/`LoadLibrary` at runtime). Run `M-x etaf-video-player-doctor` to check `libmpv`, `ffmpeg`, `ffprobe`, `ffplay`, `yt-dlp` and SQLite availability.

When `libmpv` is unavailable, when playing `:demo`, when rendering `ascii` or `color` half-blocks, or on a terminal frame, the player falls back transparently to ETAF's `ffmpeg`/`ffplay` backend.

## Cinema Theater and 4-tab Studio workspace

The playback workspace uses Obsidian Cinema (dark) and Alabaster Studio (light) palettes: a single-row elevated header with title, quick spec badges, semantic status pill (`播放中`, `已暂停`, `缓冲中`, `出错`), drawer toggles (`媒体 p`, `控制 i`, `剧场 w`), open, theme and help buttons; an optional left Media drawer (`32` columns); the centered video stage; an optional right Studio drawer (`30` columns); a three-zone transport dock with click-or-drag progress bar, clickable elapsed/remaining clock, quick utility pills and volume slider; and a single-row context footer. By default (`etaf-video-player-default-layout` = `auto`), opening a single video starts in unobstructed Cinema Theater mode while opening a directory, `.m3u` or multi-item playlist opens the left Media drawer; `:layout` (`auto`, `theater`, `media`, `studio`) overrides this per session, and `w`, `p` and `i` toggle theater and drawers anytime.

The left Media drawer (`p`) provides four leaf tabs: `队列` (inline live filter, `同目录` sibling video loader, alphabetical `排序`, `K`/`J` reorder, `D` remove, watched-progress markers), `章节` (embedded container chapters from `libmpv` / `ffprobe`, also navigable via `M-n` / `M-p`), `书签` (SQLite timestamp bookmarks saved with `m`) and `历史` (recent SQLite watch history with watched percentages, one-click resume and delete).

The right Studio drawer (`i`) provides four leaf tabs:

- `播放`: one-click `0.5x`–`3x` speed matrix, A-B section loop (`设 A` / `设 B` / `清除`), `播完暂停` (stop-after-current), backward/forward frame stepping, `复制时间` (`y`) and `截图` (`S`).
- `轨道`: embedded multi-audio selector (`v`), ±0.1 s audio delay nudge and reset, unified embedded + external subtitle selector (`V`), bilingual secondary subtitle selector (`次字幕`, rendered simultaneously via `libmpv`), subtitle delay (`z`/`x`) and subtitle font scale (`0.4x`–`3.0x`).
- `画面`: aspect ratio override (`自动`, `16:9`, `4:3`, `2.39:1`), 90° video rotation (`r`), horizontal mirror, deinterlace toggle, brightness/contrast/saturation equalizer, one-click reset, render mode switcher (`图像`/`字符`/`彩色`) and fit-to-window (`F`).
- `信息`: active engine (`libmpv` / `ffmpeg`), active hardware decoder (`videotoolbox` / `vaapi` / `d3d11va` / `软解`), video codec/profile/bitrate/pixel format, audio codec/channels/sample rate, file container/size and live canvas dimensions.

## Transport, precision seeking and A-B loop

`SPC` (or clicking the video) pauses and resumes. `.` and `n` step one frame forward; `,` steps one frame backward (true frame-step-back on `libmpv`, -0.04 s fallback on `ffmpeg`). `f`/`b` seek ±5 s, `C-f`/`C-b` seek ±30 s, `0` restarts from zero, `y` copies the current timestamp to `kill-ring`, and `g` (`etaf-video-player-goto-time`) accepts `SS`, `MM:SS`, `H:MM:SS`, percentage (`50%`) or relative offsets (`+15`, `-10`). `+` and `-` step through `0.5x`, `0.75x`, `1x`, `1.25x`, `1.5x`, `2x` and `3x`, while `=` and `DEL` reset to `1x`. `A` and `B` set an A-B section loop (applied natively via `ab-loop-a`/`ab-loop-b` on `libmpv` and enforced in the status poll on `ffmpeg`); pressing `B` again or calling `etaf-video-player-clear-ab` clears it. `etaf-video-player-toggle-stop-after-current` halts playback automatically when the current item finishes even when playlist looping is enabled.

## Playlists, chapters, bookmarks and history

`etaf-video-player-open` accepts `:playlist`, a directory path, or a `.m3u`/`.m3u8` file alongside `:index`, `:loop` and `:shuffle`. `etaf-video-player-enqueue` appends a file, directory or `.m3u` without interrupting playback; `etaf-video-player-enqueue-siblings` appends all unqueued sibling videos from the current video's folder; `etaf-video-player-sort-queue` sorts the queue alphabetically while keeping the active item selected; `K`/`J`/`D` move or remove items. Non-active items probe lazily on selection. `>`/`<` move through the queue (respecting shuffle order), `L` cycles `none`/`all`/`one`, and `s` toggles shuffle.

Local playback positions and timestamp bookmarks persist in one `etaf-db` SQLite database (`~/.emacs.d/etaf-video-player/history.sqlite3` by default; `etaf-video-player-history-file` repoints it). Positions save periodically and on close; reopening resumes automatically when past five seconds and not within ten seconds of the end. The database fails open if SQLite is unavailable.

## Subtitles and screenshots

On `libmpv`, embedded soft subtitles (ASS/SSA/SRT/PGS/VobSub) and external `.srt`/`.vtt`/`.ass`/`.ssa` files (auto-discovered beside local videos, loaded via `etaf-video-player-subtitle-load`, or dropped into the window) render natively onto the video frame via `libass` with full font styling, delay (`z`/`x`), font scaling and bilingual secondary subtitles (`etaf-video-player-set-secondary-subtitle`). Because captions render inside the frame, no duplicate text strip is added below the stage. On the `ffmpeg` fallback backend, sibling `.srt` and `.vtt` tracks parse into timed cues (`etaf-video-player-subtitle-parse`, `etaf-video-player-subtitle-text-at`) and display on one reserved bottom stage row.

`S` (`etaf-video-player-save-screenshot`) writes `<video>-YYYYMMDD-HHMMSS.png` beside local videos (or in the temporary directory for streams) using `libmpv`'s `screenshot-to-file` (preserving rendered subtitles) or a background `ffmpeg` decode on fallback.

## Render modes and Retina frames

`etaf-video-player-render-mode` sets the default mode (`image`, `ascii` or `color`); `C` switches modes without losing position or rate. `image` decodes at the frame's device pixel ratio (`etaf-video-player-device-pixel-ratio`, 2x on Retina) and draws one display slice per character row. `color` draws two true-color pixels per `▀` half-block cell capped at `etaf-video-player-color-columns` (32 by default). Terminals fall back automatically from `image` to `ascii`.

## Keys

| Key | Action |
| --- | --- |
| `SPC` | play or pause |
| `.`, `n` / `,` | frame-step forward / backward |
| `f`, `b` | +5 s / -5 s |
| `C-f`, `C-b` | +30 s / -30 s |
| `g` | jump to timestamp (`SS`, `MM:SS`, `H:MM:SS`, `50%`, `+15`, `-10`) |
| `0` | restart from the beginning |
| `y` | copy current timestamp to `kill-ring` |
| `A`, `B` | set A-B loop start / end (pressing `B` again clears the loop) |
| `m` | add a persistent timestamp bookmark |
| `M-n`, `M-p` | next / previous embedded chapter |
| `+`, `-`, `=`, `DEL` | raise / lower / reset (`1x`) playback rate (`0.5x` – `3x`) |
| `[`, `]` | volume down / up |
| `a`, `M` | toggle sound / mute |
| `v`, `V` | cycle audio track / cycle subtitle track |
| `c` | hide, show or load subtitles |
| `z`, `x` | shift subtitles 0.5 s earlier / later |
| `r` | rotate video 90° (`0°` → `90°` → `180°` → `270°`, `libmpv`) |
| `w`, `p`, `i` | toggle Cinema Theater / left Media drawer / right Studio drawer |
| `1` .. `4` | 64, 96, 128, 176 columns |
| `F` | fit to the window |
| `o`, `u`, `d` | open file, directory or `.m3u` / open URL / play built-in demo |
| `>`, `<` | next / previous playlist item |
| `K`, `J`, `D` | move current item up / down / remove from playlist |
| `S` | save the current frame as a PNG |
| `C` | switch render mode (`image`, `ascii`, `color`; or `ascii`, `color` on a terminal) |
| `L`, `s` | loop off/list/one, shuffle |
| `T` | switch dark/light appearance |
| `M-g` | jump to header (`b`), media drawer (`m`), studio drawer (`r`) or transport (`c`) region |
| `?`, `C-c h` | searchable help in the player |
| `q` | close the player |

## Scripting

```elisp
(etaf-video-player-open) ; Welcome screen
(etaf-video-player-open '(:file "clip.mkv" :columns 100 :rows 28 :volume 60))
(etaf-video-player-goto-time "50%")
(etaf-video-player-set-speed 1.25)
(etaf-video-player-cycle-audio-track)
(etaf-video-player-set-secondary-subtitle 2)
(etaf-video-player-rotate 90)
(etaf-video-player-save-screenshot "/tmp/frame.png")
(etaf-video-player-state)
;; => (:welcome nil :engine mpv :source "clip.mkv" :playing t :position 12.5 ...)
```

Every playback control signals `user-error` outside a player buffer or while on the Welcome screen. `etaf-video-player-state` returns a detached plist including `:welcome`, `:engine`, `:source`, `:playing`, `:position`, `:duration`, `:speed`, `:mode`, `:render-mode`, `:audio`, `:volume`, `:ab-loop`, `:stop-after-current`, `:theater`, `:media-panel`, `:inspector`, `:chapters`, `:bookmarks`, `:tracks`, `:rotate`, `:aspect`, `:subtitle-file`, `:subtitle-on`, `:buffering`, `:error` and `:ended`.

| Variable | Meaning |
| --- | --- |
| `etaf-video-player-default-layout` | opening drawer policy: `auto` (default), `theater`, `media` or `studio` |
| `etaf-video-player-audio` | play sound for new players, default t |
| `etaf-video-player-volume` | initial volume for new players, 0 to 100 |
| `etaf-video-player-device-pixel-ratio` | image device pixel ratio; nil derives it from the frame |
| `etaf-video-player-grid-presets` | character to canvas width, used by `1`–`4` |
| `etaf-video-player-display-fps` | presentation cap for new players, default 24 |
| `etaf-video-player-theme-mode` | `dark` (default, Obsidian Cinema) or `light` (Alabaster Studio); `T` switches live |
| `etaf-video-player-subtitle-extensions` | file suffixes probed beside a local video |
| `etaf-video-player-history-file` | SQLite database for watch history and bookmarks; nil uses user Emacs directory |
| `etaf-video-engine` | backend selector: `auto` (default, prefers `libmpv`), `mpv` or `ffmpeg` (ETAF) |
| `etaf-video-mpv-library` | optional explicit path to `libmpv` shared library (ETAF) |
| `etaf-video-ffmpeg-program` | `ffmpeg` name or path (ETAF) |
| `etaf-video-ffprobe-program` | `ffprobe` name or path; optional (ETAF) |
| `etaf-video-ffplay-program` | `ffplay` name or path for fallback sound (ETAF) |

## Troubleshooting

- Multi-audio, bilingual subtitles, rotation or color EQ report that `libmpv` is required: install `mpv` / `libmpv` and run `M-x etaf-install-native` (selecting `etaf`), then verify `(etaf-video-mpv-available-p)` or `M-x etaf-video-player-doctor`.
- `ffmpeg is not available`: install `ffmpeg` or set `etaf-video-ffmpeg-program` to its absolute path.
- No sound on the `ffmpeg` fallback: install `ffplay` or set `etaf-video-ffplay-program`; check volume and mute (`a`). On `libmpv`, audio plays natively inside the same engine.
- A URL does not play: check network access and proxy variables (`http_proxy` / `https_proxy`); for video web pages install `yt-dlp` alongside `libmpv`.
- Picture looks squashed: press `F` (`etaf-video-player-fit`) or reset aspect ratio in the `画面` Studio tab.
