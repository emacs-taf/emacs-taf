# ETAF Bili

Browse and watch Bilibili inside Emacs: a responsive cover-card gallery paired with a dedicated Watch View supporting WBI-signed DASH streams, multi-part episodes, CC/AI subtitles with searchable transcript jump, danmaku, hot comments with timestamp jumps, local and cloud resume, background audio-only mode, Picture-in-Picture and external `mpv` handoff. Built with [ETAF](https://github.com/emacs-taf/etaf), `etaf-ui` and `etaf-db`.

![Cover gallery in the dark theme](https://etaf.top/media/etaf-bili/etaf-bili-wide.webp)

[Light theme](https://etaf.top/media/etaf-bili/etaf-bili-light.webp)

## What it does

- Responsive 1-to-4-column bordered cover gallery with aspect-preserving thumbnails, bottom-right duration badges, top-left multi-part/resume badges, creator links (`u` to open UP space) and infinite scroll pagination.
- In-page SearchField (`/`) that handles both keyword WBI search (with sort filters) and direct navigation when pasting a `BV` ID, `av` number, `bilibili.com/video/...` URL (with `?p=` / `&t=`) or `b23.tv` short link.
- Public and signed-in channels: Popular (`1`), Partitioned Ranking (`2`), Personalized Recommendations (`3`), Following Dynamics (`4`), Watch Later (`5`), Watch History (`6`) and Favorites (`7`), plus QR sign-in overlay (`M-x etaf-bili-login`) sharing an atomic Netscape cookie jar.
- Dedicated responsive Watch View: wide windows (`≥ 120` cols) split 16:9 theater and a 38-column tabbed panel (Parts/Chapters, Searchable Subtitle Transcript, Live Danmaku, Comments with clickable `MM:SS` timestamps and Related videos); narrow windows and Theater mode (`w`) expand the stage and open the side panel in a Drawer (`i`).
- Zero-`ffprobe` WBI `fnval=4048` DASH resolution with quality/codec preference (`H.264 > HEVC > AV1`), instant quality switching (`Q`) preserving the current second, automatic CDN `backupUrl` failover, 250 ms Retained Host clock/progress/subtitle/danmaku updates, and SQLite persistence (`etaf-db`) for viewing preferences and exact local + cloud resume.
- Emacs-native viewing workflows: zero-CPU background audio-only listening (`A`) with a persistent gallery mini-player, floating child-frame Picture-in-Picture (`v`), one-key external `mpv` handoff (`o`) at the exact second, browser handoff (`O`), and Org timestamp link copy (`y`) reopened by `etaf-bili-open-video`.
- Dark and light application palettes (`T`) that preserve the user's Emacs frame, title bar, theme and mode-line (`:mode-line t`). Minimum usable viewport: **64 columns × 28 lines**.

This is an unofficial client for personal Bilibili viewing inside Emacs. Available streams, highest quality tiers (such as 1080P60/4K) and AI subtitles depend on the server and account entitlements.

## Install

<!-- BEGIN:GENERATED:pkg-install-en:etaf-bili -->
### From the ETAF package archive (recommended)

```elisp
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(etaf-install-ensure '(etaf-bili))
```

Or run `M-x etaf-install` and select `etaf-bili` interactively.

### From a source checkout

All core framework packages live in [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf):

```sh
git clone https://github.com/emacs-taf/etaf.git
git clone https://github.com/emacs-taf/etaf-bili.git
```

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-media" "etaf-ui" "etaf-db"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/etaf-bili")
(require 'etaf-bili)
```
<!-- END:GENERATED:pkg-install-en:etaf-bili -->

Installing `etaf-bili` via `etaf-install` also downloads the prebuilt `etaf-video-mpv` native module for `etaf` automatically.

Requires Emacs 29.1+ (with built-in SQLite for local resume/preferences), `curl`, Node.js (for QR sign-in in `backends/bili/`), and optionally `libmpv` / `ffmpeg` (with `ffplay`) / `mpv`.

```elisp
(require 'etaf-bili)
(etaf-bili-open)
```

## Use

### Gallery View

| Key | Action |
| --- | --- |
| `/` | Edit the in-page search field (keywords or paste BV / av / URL / b23.tv) |
| Arrow keys / `n` / `p` | Move across cards in two dimensions or sequentially |
| `RET` | Activate the focused control or open the selected video in Watch View |
| `1` – `7` | Popular / Ranking / Recommendations / Dynamics / Watch Later / History / Favorites |
| `u` | Open the selected creator's upload space |
| `w` | Return to the active Watch View session |
| `i` | Open the video metadata Drawer |
| `g` | Refresh current channel |
| `T` | Switch dark / light application palette |
| `?` / `M-g` | Framework shortcut help / region navigation |
| `q` | Close the current modal first, then the client buffer |

### Watch View

| Key | Action |
| --- | --- |
| `SPC` | Play / pause |
| `←` / `→` | Seek `-5s` / `+5s` |
| `j` / `l` | Seek `-10s` / `+10s` |
| `0` – `9` | Jump to `0%` – `90%` of duration |
| `,` | Step one frame while paused |
| `↑` / `↓` or `[` / `]` | Adjust volume `-10%` / `+10%` |
| `m` | Mute / unmute sound |
| `.` / `+` / `-` | Cycle or step playback speed (`0.5x` – `2.0x`) |
| `Q` | Open quality, codec and CDN failover dialog |
| `c` / `d` | Cycle CC/AI subtitles / toggle danmaku lane |
| `w` / `i` | Toggle wide Theater mode / open side panel Drawer |
| `N` / `P` (or `n` / `p`) | Next / previous part, episode or gallery video |
| `L` | Toggle auto-advance to next part or video |
| `A` | Toggle zero-CPU background audio-only mode |
| `v` | Toggle floating child-frame Picture-in-Picture |
| `o` / `O` | Open at current second in `mpv` / web browser |
| `y` | Copy Org timestamp link (`[[elisp:(etaf-bili-open-video ...)]]`) |
| `b` / `Esc` / `q` | Close topmost Watch overlay, or return to Gallery View |

## Embed in a panel or desktop

`M-x etaf-bili-open` opens or focuses the standalone `*Bili*` buffer (pass a prefix argument to start fresh). A caller that already owns a buffer or floating panel mounts the same View directly:

```elisp
(require 'etaf-bili)
(let ((buffer (get-buffer-create "*Bili*")))
  (etaf-mount buffer (etaf-bili-view (etaf-bili-create)))
  buffer)
```

The View reads `(etaf-viewport)` so a desktop window or posframe reflows the card grid and Watch split automatically. Unmounting stops transfers, timers, audio and PiP while retaining the library, selection and account for `:keep-alive` remounts.

## Documentation and checks

- [Manual](docs/manual.md): workflows, Watch View controls, caching, persistence and integration.
- [Architecture](docs/architecture.md): module ownership, Retained Host HUD, cookie isolation and lifecycle.
- [Entry Commentary](etaf-bili.el): authoritative supported public API.

```sh
make test     # offline public acceptance suite (Gallery, Watch, Store, Cookie jar)
make check    # structure, byte compilation, acceptance and API boundaries
```

GUI scenarios live in `scripts/etaf-bili-gui-scenarios.el`; the workspace performance driver loads `benchmarks/performance-scenarios.el` for `bili.appearance` and `bili.scroll`.
