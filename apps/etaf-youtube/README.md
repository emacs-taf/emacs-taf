# ETAF YouTube

ETAF YouTube is a native YouTube client rendered inside Emacs as an ETAF text application. It pairs a zero-dependency Node.js backend (`backends/youtube/`) with `yt-dlp` and ETAF's native `etaf-video` engine (`libmpv` hardware decoding with `ffmpeg`/`ffplay` fallback) so browsing, searching, reading chapters/transcripts/comments, and watching adaptive 4K/2K/1080p60 streams all happen inside one cohesive interface without storing credentials in Emacs.

## Capabilities

- Browsing: home, Shorts, subscriptions, live, watch history, playlists, watch later, and liked videos across an 8-destination sidebar and a compact 8-icon rail on narrow windows, with topic filter chips and channel tabs.
- Search and direct URLs: search with `all`, `videos`, `channels`, `playlists`, and `live` filter pills, or paste any YouTube watch/Shorts/live/`youtu.be` URL (with `&t=` timestamps), 11-character video ID, `UC...` channel ID, `@handle`, or `PL...` playlist ID directly into the search bar.
- Cinema Watch View: pure dark `#050608` 16:9 theater canvas with a 1-row cinema subtitle strip, de-boxed Studio transport deck, 200ms Retained Host HUD updates (zero full-view reflow during playback), and a 5-tab workbench (`简介` with full description & clickable chapters, `字幕` with multi-language tracks & searchable transcript jump, `评论` with sort pills, composer, clickable timestamps, reactive collapsible replies & pagination, `推荐` with auto-next & load more, and `队列`).
- Smooth high-resolution playback: single `yt-dlp -J` probe returns the full curated stream ladder (`2160p60 4K` through `144p`) with paired audio and alternate protocol failover, enabling instant in-place quality switching (`Q`) at the exact second without re-running `yt-dlp`. Hardware-accelerated `libmpv` playback keeps zero A/V sync drift and reconnects automatically over flaky networks.
- Background listening and workflows: zero-CPU audio-only mode (`A`) with a persistent mini-player bar, floating Picture-in-Picture (`v`), external `mpv` handoff (`o`) at the exact second, Org timestamp link copy (`y`), and live status publication to `etaf-activity-publish`.
- Explicit account writes: like, dislike, unrate, subscribe/unsubscribe, save, and comment require explicit confirmation (`--yes`); unverified submissions warn once and never auto-retry, and preview/blocked responses never mutate local UI state.
- Dual palettes and mode-line preservation: Obsidian Cinema (dark) and Editorial Daylight (light) palettes independent of the Emacs theme while preserving the user's original Emacs mode-line (`:mode-line t`).
- Local persistence: SQLite store via `etaf-db` for volume, speed, quality, theme, auto-next, and per-video resume positions with an O(1) in-memory cache for feed resume badges.

## Installation

Install directly from the ETAF archive with `M-x etaf-install` and select `etaf-youtube`. Installing `etaf-youtube` automatically pulls its package dependencies (`etaf`, `etaf-ui`, `etaf-db`) and downloads and verifies the prebuilt `etaf-video-mpv` native binary for `etaf` with no local compiler required.

Run `M-x etaf-install-doctor` (or inspect `(etaf-youtube-doctor)`) to check system tools:

- Required: `node` (Node.js 18+), `yt-dlp`, and `curl`.
- Optional: `libmpv` (`brew install mpv`) for hardware-accelerated playback and external `mpv` / audio-only mode; `ffmpeg`/`ffplay` as software fallback; Emacs built with SQLite for local persistence.
- Account session: run `M-x etaf-youtube-login` to sign in inside the controlled Chrome browser, `M-x etaf-youtube-account` to inspect the active account, and `M-x etaf-youtube-logout` to clear the YouTube session.

## Start

```elisp
(require 'etaf-youtube)
(etaf-youtube-open)
```

- Gallery keys: `1`–`8` switch feeds, `n`/`p` select cards, `RET` activates the focused control or selected card, `/` focuses search (or pastes a URL/ID), `s` toggles the sidebar, `w` returns to the active Watch video, `d`/`T` switches dark/light appearance, `r`/`g` refreshes, `u` goes back, and `C-c s`/`C-c c`/`C-c m` or `M-g` jump between regions.
- Watch keys: `SPC`/`k` play/pause, `f` +5s, `j`/`l` ±10s, `0`–`9` jump to 0%–90%, `,`/`.` frame step, `+`/`-` speed, `[`/`]` volume, `m` mute, `Q` quality & engine dialog, `c` cycle subtitles, `w`/`t` theater mode, `i` toggle workbench drawer, `A` audio-only background mode, `v` floating PiP, `N`/`P` queue next/prev, `L` auto-next, `M-n`/`M-p` next/prev chapter, `o` external `mpv`, `O` browser, `y` copy Org timestamp link, `u` author channel, `b` back to feed, `?` key help.

## Documentation

The authoritative public API inventory is the Commentary in [etaf-youtube.el](etaf-youtube.el). The ETAF Reference Manual documents the framework Components this application builds on.

## Development

```sh
make check   # structure, compile, public acceptance, API declarations
make test    # public acceptance suite only
```

The public acceptance suite runs headless and offline with injected transport, thumbnail fetcher, and store fixtures.
