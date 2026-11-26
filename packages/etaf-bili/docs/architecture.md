# ETAF Bili architecture

## Ownership

| Module | Responsibility |
| --- | --- |
| `etaf-bili-service` | Bilibili HTTP/WBI protocol, cookie-mode isolation, zero-`ffprobe` DASH `fnval=4048` resolution, companion parsers (subtitles, chapters, danmaku XML, comments, related), direct BV/URL parsing and bounded cover cache |
| `etaf-bili-store` | Fail-open `etaf-db` SQLite persistence (`bili_progress` and `bili_prefs` tables) with in-memory fallback |
| `etaf-bili-model` | Reactive session struct, channel/pagination loaders, 30-minute TTL stream cache, non-destructive Toast state, companion loaders and pure subtitle/danmaku/timestamp helpers |
| `etaf-bili-account` | Node.js `backends/bili/bili.mjs` bridge for QR login polling, status check and logout with per-session timers |
| `etaf-bili-theme` | Dark and light palettes and catalog theme-token projection |
| `etaf-bili-views` | Pure Gallery grid geometry, bordered cover cards, header, expanded tabs, context filter strip and floating Toast banner |
| `etaf-bili-watch` | Responsive Watch View layout (split Theater + 38-column tabbed panel, narrow/Theater Drawer, quality/CDN picker dialog, Retained Host leaf anchors) |
| `etaf-bili-app` | Standalone (`etaf-app-open :mode-line t`) and embeddable (`etaf-bili-view`) shell lifecycle, `(etaf-viewport)` sync with Watch resize debounce, cover queue, 250 ms HUD tick, background audio, child-frame PiP, external `mpv` handoff and commands |

Applications and components call only ETAF, `etaf-ui` and `etaf-db` public APIs; EBox internals remain hidden behind ETAF.

## View modes and layout

The top-level `etaf-bili--shell` switches cleanly between `'gallery` and `'watch` over one reactive session:

- **Gallery View**: A normal-flow column with padded header (`lh 3`), channel tab bar (`lh 3`), optional context filter strip (`lh 2` for Ranking, Search, Favorites and UP Space), virtualized native-scroll cover grid (`etaf-bili--gallery`), and footer (`lh 3`) that converts into a compact mini-player strip when background audio-only mode is active.
- **Watch View**: A full-viewport column (`lh 2` header + body row). At `total-cols >= 120` (unless Theater mode `w` is active), the body splits into a left Theater column (author/stats strip, optional 1-row danmaku lane, aspect-fitted `etaf-video` / audio-only / inline error stage, 1-row subtitle strip and 3-row transport panel) and a right 38-column tabbed side panel. Narrow viewports or Theater mode allocate the full width to the Theater column and mount the same side panel inside an on-demand `etaf-drawer`.

Viewport sizing watches `(etaf-viewport)` so embedded hosts (`etaf-bili-view`) and standalone windows share one layout path. While Watch View is actively playing video, resize events are debounced by 200 ms so interactive window drags do not repeatedly kill and reconnect remote DASH streams.

## Retained Host HUD and playback lifecycle

Video playback runs through ETAF's native `etaf-video` component receiving pre-normalized `:kind 'url` plists (`:url`, `:audio-url`, `:width`, `:height`, `:fps`, `:duration`, `:audio t`, optional `:start`) produced directly from Bilibili's DASH JSON without invoking `ffprobe`.

A 250 ms timer (`etaf-bili--watch-tick`) polls `etaf-video-state` (or the background `ffplay` clock in audio-only mode) and updates only leaf Retained Host anchors (`etaf-set-host-content` for clock, duration, active CC subtitle, top danmaku lane and buffering status; `etaf-set-host-geometry` for the seek bar fill). Nothing in the 250 ms tick triggers a full View re-render.

Stream errors detected from `etaf-video-state` trigger automatic failover to `:backup-urls` / `:audio-backup-urls` before surfacing an inline recovery panel with Retry, Failover CDN and `mpv` handoff buttons. Unmounting or leaving Watch View persists local progress and sends a throttled cloud heartbeat when signed in.

## Cookie isolation, caching and cleanup

`backends/bili/bili.mjs` reads Netscape cookies including `#HttpOnly_` entries (such as `SESSDATA`), writes updates atomically via temporary file + rename, and is invoked with explicit `ETAF_BILI_STATE_DIRECTORY` / `ETAF_BILI_COOKIE_FILE` environment variables.

In `etaf-bili-service.el`, each `curl` call specifies an explicit cookie mode: `:read` (`-b`) for normal API reads and posts, `:read-write` (`-b` + `-c`) only when seeding a missing `buvid3`, and `:none` for `hdslb.com` cover downloads. This prevents concurrent transfers from truncating or overwriting freshly written session cookies.

Covers download atomically into `etaf-bili-state-directory/covers/` (capped at 3 concurrent transfers and pruned to 400 cached files). Unmounting cancels active cover processes, removes partial `.cover-*` temp files, resets `cover-active` to 0 and clears `'loading` map entries so `:keep-alive` remounts reload interrupted covers cleanly. Resolved stream URLs expire after 30 minutes and are invalidated immediately on login or logout.

## Validation

Offline acceptance tests in `tests/` validate WBI signing, target parsing, SQLite progress/preference/history persistence, subtitle binary search, danmaku windowing, timestamp extraction, `#HttpOnly_` cookie round-trips through Node, expanded channels and deduplicated pagination, non-destructive error Toasts, full Watch View lifecycle, mode-line preservation, live buffer reuse and unmount cover cleanup. Real graphical appearance, line-height invariants and live Bilibili playback are verified separately through `scripts/etaf-bili-gui-scenarios.el` and live GUI inspection.
