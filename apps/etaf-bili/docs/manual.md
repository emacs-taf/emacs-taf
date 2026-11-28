# ETAF Bili manual

## Discover, filter and search

Run `M-x etaf-bili-open`. The standalone buffer reuses an already-open `*Bili*` session without interrupting playback (pass a prefix argument `C-u` to start fresh) and preserves your Emacs mode-line (`:mode-line t`). The popular feed loads asynchronously into a 1-to-4-column bordered cover gallery.

Click the channel tabs or press `1`–`7` to switch between Popular (`1`), Ranking (`2`), Personalized Recommendations (`3`), Following Dynamics (`4`), Watch Later (`5`), Watch History (`6`) and Favorites (`7`). Ranking, Search, Favorites and UP Creator Space (`u`) automatically show a context filter strip for partitions, sort order (`综合`, `最多播放`, `最新发布`, `最多弹幕`), favorite folders or returning from a creator's space.

Press `/` to edit the in-page SearchField. Entering keywords runs a WBI-signed video search and records the query in local search history. Pasting a `BV` ID, `av` number, `https://www.bilibili.com/video/BV...?p=2&t=95` link or `https://b23.tv/...` short link resolves and opens that video directly in Watch View at the requested part and second.

Each card renders an aspect-preserving cover, a bottom-right duration badge, an optional top-left badge (`续播 MM:SS`, `NP` or recommendation tag), a two-line title, a clickable creator link (`u`) and compact view/date metadata. Hover feedback is scoped strictly to homogeneous text targets so semantic colors and badges stay intact. Scrolling near the bottom automatically appends the next deduplicated page. Minimum usable viewport is 64 columns by 28 lines.

## Watch View

Press `RET` or click any card (or call `M-x etaf-bili-open-video`) to enter the dedicated Watch View. Single-video stream errors show a non-destructive Toast above the footer and leave the Gallery intact.

On wide viewports (`≥ 120` columns), Watch View displays a 16:9 theater stage on the left and a 38-column tabbed panel on the right (`选集`, `字幕`, `弹幕`, `评论`, `相关`). Pressing `w` enters wide Theater mode, collapsing the side panel to maximize the video; on narrow viewports or in Theater mode, press `i` to open the same panel in a Drawer.

Stream resolution calls WBI-signed `/x/player/wbi/playurl` (`fnval=4048`, `fourk=1`, `try_look=1`), selects the highest quality at or below your preferred tier (`etaf-bili-preferred-quality`, default 80 = 1080P) using codec preference `etaf-bili-preferred-codecs` (`H.264 > HEVC > AV1`), and delivers a pre-normalized source (`:width`, `:height`, `:fps`, `:duration`, `:audio t`) directly to `etaf-video` so no blocking `ffprobe` process is spawned. Press `Q` to switch quality or codecs at the exact current second, or to trigger CDN `backupUrl` failover manually (automatic failover also triggers on stream errors).

During playback, a 250 ms timer updates elapsed time, total duration, hairline seek bar fill, active CC/AI subtitle text, buffering status and the optional top danmaku lane through ETAF Retained Host leaf updates without re-rendering the view tree. Audio starts enabled by default with saved volume (default 85%) and speed (`0.5x`–`2.0x`).

## Subtitles, danmaku, comments and chapters

When Watch View opens a video, companion loaders asynchronously fetch `/x/player/wbi/v2` (CC/AI subtitle tracks, clickable chapters and cloud `last_play_time`), `comment.bilibili.com/<cid>.xml` (danmaku), `/x/v2/reply/wbi/main` (pinned + hot comments) and `/x/web-interface/archive/related` (related videos).

- Press `c` to toggle or cycle subtitle tracks. The `字幕` tab includes a live search filter; clicking any transcript cue seeks directly to that second.
- Press `d` to toggle the top danmaku lane. The `弹幕` tab lists nearby entries with clickable timestamps.
- The `评论` tab parses `MM:SS` and `HH:MM:SS` timestamps in comments into clickable `↗ MM:SS` jump chips.
- The `选集` tab switches multi-part pages (`P1`, `P2`, ...), `ugc_season` collection episodes and clickable chapters, and toggles auto-advance (`L`).

## Local resume, background listening, PiP and handoff

Watch positions and viewing preferences (`audio`, `volume`, `speed`, `quality`, `subtitle`, `danmaku`, `auto-next`, `search-history`) are stored in SQLite via `etaf-db` at `etaf-bili-state-directory/state.sqlite3` (overridable via `etaf-bili-store-file`). When SQLite is unavailable, persistence degrades gracefully to an in-memory fallback. Reopening a video compares local progress against cloud `last_play_time` and resumes automatically when the position is beyond 5 seconds and more than 12 seconds before the end; signed-in playback also sends periodic watch heartbeats.

- Press `A` to switch into zero-CPU background audio-only mode (stops video decoding and plays the DASH audio stream through `ffplay`). Pressing `b` returns to the Gallery with a persistent mini-player bar in the footer while you browse or switch to another Emacs buffer; press `w` to return to Watch View.
- Press `v` in graphical Emacs to open a floating child-frame Picture-in-Picture window positioned at the bottom-right corner (`SPC` toggles playback, `q` or `v` closes PiP).
- Press `o` to launch `etaf-bili-external-player` (`mpv` by default) at the exact current second with matching `Referer`, `User-Agent` and `--audio-file`, pausing in-Emacs playback automatically. Press `O` to open the video URL with `?p=` and `&t=` in the system browser.
- Press `y` to copy an Org timestamp link `[[elisp:(etaf-bili-open-video "BV..." SEC CID)][Title (MM:SS)]]` directly into the kill ring.

## Signing in and account isolation

Click the header account chip or run `M-x etaf-bili-login` to display the QR code inside an `etaf-ui-qr-login` overlay while the client stays dimmed underneath. Confirming on your phone writes `.bilibili.com` cookies (preserving `#HttpOnly_` prefixes such as `SESSDATA`) atomically through `backends/bili/bili.mjs`, invalidates guest stream caches and reloads the active feed. Signed-in accounts unlock personalized feeds, higher quality tiers, AI subtitles and header like/coin/favorite/Watch Later actions (`bili_jct` CSRF).

`M-x etaf-bili-account` reports the signed-in user and `M-x etaf-bili-logout` signs out and clears `.bilibili.com` cookies. API curl requests use read-only cookie mode (`-b`) after `buvid3` is seeded, and `hdslb.com` cover transfers pass no cookies at all so concurrent requests never corrupt `cookies.txt`.

## Hosting the client and integration

`etaf-bili-create` creates a headless session and `etaf-bili-view` returns its embeddable View. The View watches `(etaf-viewport)` so floating panels or desktop windows reflow both the Gallery grid and Watch split automatically. Unmounting stops transfers, timers, audio-only processes and PiP while preserving the library, selection and account for `:keep-alive` remounts.

For programmatic use and offline testing, `etaf-bili-client-factory` accepts a function returning a `(REQUEST CALLBACK)` client answering `(:ok DATA)` or `(:error MESSAGE)`. See `etaf-bili.el` Commentary for the complete public API.

## GUI and performance verification

Run real graphical verification with ETAF's maintained verifier and this package's scenario adapter:

```elisp
(load "core/packages/etaf/scripts/emacs-gui-verifier.el")
(load "apps/etaf-bili/scripts/etaf-bili-gui-scenarios.el")
(etaf-bili-gui-run "/tmp/bili-gui-evidence")
```

Run `bili.appearance` and `bili.scroll` through the workspace performance driver:

```sh
python3 scripts/performance.py --scenario-file apps/etaf-bili/benchmarks/performance-scenarios.el --scenario bili.appearance --load-path apps/etaf-bili --mode batch
```
