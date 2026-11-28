# ETAF Video Player

ETAF Video Player plays local videos, folders, `.m3u`/`.m3u8` playlists and HTTP(S) streams (including `yt-dlp` URLs when `libmpv` is active) inside an Emacs buffer as sharp image frames with synchronized sound. It consumes ETAF's native [`etaf-video`](https://github.com/emacs-taf/etaf) Component, automatically using ETAF's cross-platform `libmpv` native backend (hardware decoding, multi-audio tracks, embedded/ASS/PGS and bilingual secondary subtitles, instant seeking, backward frame-stepping, aspect/rotation/mirror/deinterlace/color equalizer, zero-gap audio/video sync) when available, and falling back transparently to `ffmpeg`/`ffplay` and terminal `ascii`/`color` half-block modes. Every frame publishes through ETAF's retained content boundary without full re-renders.

The player at a wide frame:

![The player at a wide frame](https://etaf.top/media/etaf-video-player/etaf-video-player-wide.webp)

The same layout in the light appearance:

![The player in the light appearance](https://etaf.top/media/etaf-video-player/etaf-video-player-light.webp)

## Capabilities

- Welcome / Continue Watching home screen: `M-x etaf-video-player-open` with no source opens a clean Obsidian Cinema / Alabaster Studio launcher displaying recent watch history with progress bars and one-click resume, engine status (`libmpv` / `ffmpeg`), quick open actions, and zero background decoder cost; `M-x etaf-video-player-demo` (`d`) opens the generated test pattern explicitly.
- Cross-platform `libmpv` native engine with automatic `ffmpeg` fallback: on macOS, Linux and Windows GUI Emacs (29.1+), ETAF's `libmpv` dynamic module delivers hardware-accelerated decoding, gapless A/V sync, instant scrubbing, native `libass` subtitle rendering, and in-place resize without restarting playback; on terminals or systems without `libmpv`, it automatically falls back to `ffmpeg`/`ffplay` (`image`, `ascii`, `color`).
- Drag-and-drop & rich sources: drop video files, folders, `.m3u`/`.m3u8` playlists, or external `.srt`/`.vtt`/`.ass`/`.ssa` subtitles directly from Finder / OS file managers into the player window, or open local files, directories, `.m3u` playlists and HTTP(S) / `yt-dlp` URLs via `o` and `u`.
- Cinema Theater & 4-tab Studio drawers: single videos open unobstructed in Cinema Theater mode (`w` toggles theater mode); `p` opens the left Media drawer (inline-filterable Queue with sibling auto-load, alphabetical sort and `K`/`J`/`D` editing; embedded Chapters via `M-n`/`M-p`; SQLite Bookmarks via `m`; Watch History); `i` opens the right Studio drawer with four tabs — `播放` (speed grid, A-B loop, stop-after-current, frame step, copy timestamp, screenshot), `轨道` (multi-audio selector, ±0.1 s audio delay, unified embedded + external subtitle selector, bilingual secondary subtitles, subtitle delay and font scale), `画面` (aspect override, 90° rotation, horizontal mirror, deinterlace, brightness/contrast/saturation equalizer, render mode) and `信息` (active engine, active hwdec, codec, bitrate, pixel format, audio layout).
- Precision transport: play/pause (`SPC` or click video), true frame-step forward (`.`, `n`) and backward (`,`), ±5 s / ±30 s seeking, enhanced timestamp jump (`g` accepting `SS`, `MM:SS`, `H:MM:SS`, `50%` or `+15`/`-10`), restart (`0`), copy timestamp (`y`), native A-B loop (`A` / `B`), stop-after-current, clickable remaining-time readout, live-preview timeline and volume scrubbing, `0.5x`–`3x` speed ladder (`+`/`-`/`=`, `DEL`), volume (`[`/`]`) and mute (`a`/`M`).
- Persistent SQLite history & bookmarks: local playback positions and timestamp bookmarks persist in one `etaf-db` SQLite database; reopening resumes automatically and the Welcome screen + History tab list recent plays with watched percentage.
- Screenshots: `S` captures the current frame (including rendered subtitles on `libmpv`, falling back to background `ffmpeg`) into a timestamped PNG beside the video.
- Obsidian Cinema (dark) and Alabaster Studio (light) themes preserve Emacs's mode line and frame background, adapting cleanly across wide, medium, compact and short viewports.

## Prerequisites

| Requirement | Why | Check |
| --- | --- | --- |
| Emacs 29.1 or newer | the ETAF runtime (with dynamic modules for `libmpv`) | `emacs --version` |
| `etaf`, `etaf-ui`, `ebox`, `ecss`, `etaf-db` | the framework and playback database on `load-path` | every checkout is readable |
| `libmpv` + `etaf/native/etaf-video-mpv` (recommended) | full native engine: hwdec, multi-audio, ASS/bilingual subs, filters, backward step, instant seek | `(etaf-video-mpv-available-p)` |
| `ffmpeg` (required fallback) | demo generator, fallback decoding, `ffprobe` media telemetry and `ffplay` fallback audio | `ffmpeg -version` |
| `yt-dlp` (optional) | direct playback of Bilibili / YouTube and web video URLs on `libmpv` | `yt-dlp --version` |

Install `mpv` (e.g. `brew install mpv` on macOS, `apt install libmpv2` / `pacman -S mpv` on Linux, or `libmpv-2.dll` on Windows) and install `etaf-video-player` via `M-x etaf-install` — the installer automatically downloads and verifies `etaf`'s prebuilt `etaf-video-mpv` dynamic module into `~/.cache/emacs-taf/native/` alongside Lisp dependencies with no compiler required (you can also run `M-x etaf-install-native` anytime, or `sh native/build-video-mpv-module.sh` inside an `etaf` source checkout). Run `M-x etaf-video-player-doctor` anytime to inspect active capabilities.

## Installation

Install from the ETAF package archive (`https://etaf.top/packages/`) with `M-x etaf-install` and select `etaf-video-player`.

From a source checkout, clone [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) and `etaf-video-player`, then add the package directories to `load-path`:

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui" "etaf-db"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/etaf-video-player")
(require 'etaf-video-player)

(global-set-key (kbd "C-c v") #'etaf-video-player-open)
```

## Minimal example

```elisp
(etaf-video-player-open)                       ; Welcome / Continue Watching home
(etaf-video-player-open-file "clip.mkv")       ; local video, directory or .m3u
(etaf-video-player-open-url "https://example.com/clip.mp4") ; HTTP(S) / yt-dlp stream
(etaf-video-player-demo)                       ; generated test pattern, no file
(etaf-video-player-open '(:file "clip.mp4" :columns 120 :rows 34 :volume 60))
(etaf-video-player-open '(:playlist ((:file "a.mp4") (:file "b.mp4")) :loop all))
(etaf-video-player-cycle-audio-track)          ; switch embedded audio (libmpv)
(etaf-video-player-set-secondary-subtitle 2)   ; bilingual secondary subtitle (libmpv)
(etaf-video-player-rotate)                     ; rotate 0 -> 90 -> 180 -> 270 (libmpv)
(etaf-video-player-subtitle-load "clip.srt")   ; attach external .srt/.vtt/.ass/.ssa
(etaf-video-player-save-screenshot "frame.png") ; save the current frame as PNG
(etaf-video-player-history-recent 10)          ; recent watch history records
```

## Keys

| Key | Action |
| --- | --- |
| `SPC` | play or pause |
| `.` / `n` / `,` | frame-step forward / backward |
| `f` / `b` | seek 5 seconds forward or backward |
| `C-f` / `C-b` | seek 30 seconds forward or backward |
| `g` | jump to timestamp (`SS`, `MM:SS`, `H:MM:SS`, `50%`, `+15`, `-10`) |
| `0` | restart from the beginning |
| `y` | copy current timestamp to `kill-ring` |
| `A` / `B` | set A-B loop start / end (pressing `B` again clears the loop) |
| `m` | add a timestamp bookmark at the current position |
| `M-n` / `M-p` | next / previous embedded chapter |
| `+` / `-` / `=` / `DEL` | raise / lower / reset (`1x`) playback speed (`0.5x` – `3x`) |
| `[` / `]` | lower or raise the volume by 10 |
| `a` / `M` | toggle sound / mute |
| `v` / `V` | cycle audio track / cycle subtitle track |
| `c` | hide, show or load subtitles |
| `z` / `x` | shift subtitles 0.5 seconds earlier / later |
| `r` | rotate video 90° (`0°` → `90°` → `180°` → `270°`, `libmpv`) |
| `w` / `p` / `i` | toggle Cinema Theater / left Media drawer / right Studio drawer |
| `1` .. `4` | grid presets (64, 96, 128, 176 columns, rows follow the aspect) |
| `F` | fit the canvas to the window |
| `C` | switch render mode (`image` / `ascii` / `color`, or `ascii` / `color` on a terminal) |
| `o` / `u` / `d` | open file, directory or `.m3u` / open URL / play built-in demo |
| `>` / `<` | next / previous playlist item |
| `K` / `J` / `D` | move current item up / down / remove from playlist |
| `S` | save the current frame as a PNG |
| `L` / `s` | cycle loop mode / toggle shuffle |
| `T` | switch dark/light appearance |
| `M-g` | jump to header, media drawer, studio drawer or transport region |
| `?` / `C-c h` | searchable help inside the player |
| `q` | close the player |

The header's help button opens the same read-only, themed modal. `/` searches the effective bindings; Escape leaves search editing before closing help. Clicking the dimmed background closes it and restores the player focus.

## Checks

```sh
make check    # structure + byte compilation (warnings as errors) + acceptance + API boundary
make test     # the public acceptance scenarios only
```

The acceptance suite covers both the fake `ffmpeg`/`ffprobe`/`ffplay` fixture path (zero external dependencies) and gated real `ffmpeg` and real `libmpv` multi-track scenarios when those tools are installed.

## Documentation

- [The manual](docs/manual.md): Welcome screen, `libmpv` setup, drag-and-drop, Studio drawers, scripting, variables and troubleshooting.
- [Architecture](docs/architecture.md): module responsibilities, data flow, invariants and the ownership boundary with ETAF.
- [The root entry Commentary](etaf-video-player.el): the authoritative list of supported functions and variables.
