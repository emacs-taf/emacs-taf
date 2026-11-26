# Changelog

## Unreleased

### Added

- Dedicated responsive Watch View (`etaf-bili-watch.el`) replacing the modal viewer for video playback: 16:9 theater stage with wide split (`≥ 120` cols) tabbed side panel (Parts/Collection/Chapters, Searchable CC/AI Subtitle Transcript, Live Danmaku, Comments with clickable `MM:SS` timestamp jumps and Related videos), narrow/Theater mode (`w`) Drawer (`i`), and 250 ms Retained Host leaf updates for clock, hairline progress bar, live subtitle strip and optional top danmaku lane.
- WBI-signed `/x/player/wbi/playurl` (`fnval=4048`, `fourk=1`, `try_look=1`) DASH resolution returning pre-normalized video/audio sources (`:width`, `:height`, `:fps`, `:duration`, `:audio t`) with codec preference (`H.264 > HEVC > AV1`), quality switcher dialog (`Q`) keeping the current timestamp, and automatic CDN `backupUrl` failover without running `ffprobe`.
- Fail-open SQLite persistence (`etaf-bili-store.el` via `etaf-db`) storing per-`(bvid, cid)` local resume points (merged with cloud `last_play_time` and heartbeat write-back), viewing preferences (audio on by default, volume, speed, quality, subtitle, danmaku, auto-next) and deduplicated search history.
- Expanded Gallery channels and filters: Personalized Recommendations (`3`), Partitioned Ranking (`2` with category filter strip), Search sort strip (`totalrank`, `click`, `pubdate`, `dm`), Following Dynamics (`4`), Watch Later (`5`), Watch History (`6`), Favorites (`7` with folder switcher), UP creator space (`u`), direct BV/av/URL/`b23.tv` search bar navigation, and infinite-scroll pagination.
- Emacs-native viewing workflows: zero-CPU background audio-only mode (`A`) with persistent Gallery mini-player, floating child-frame Picture-in-Picture (`v`), external `mpv` handoff (`o`) at the exact second, browser handoff (`O`), Org timestamp link copy (`y`) paired with `etaf-bili-open-video`, and signed-in like/coin/favorite/Watch Later actions.
- `M-x etaf-bili-create` and `etaf-bili-view` embeddable View API adapting to `(etaf-viewport)`, plus `M-x etaf-bili-login` QR sign-in overlay (`etaf-ui-qr-login`), `M-x etaf-bili-account` and `M-x etaf-bili-logout`.

### Changed

- Migrated `etaf-bili-open` onto `etaf-app-open` with `:mode-line t` (preserving the user's mode-line) and live `*Bili*` buffer reuse.
- Upgraded Gallery cards to 1 px bordered cards with bottom-right duration badges, top-left multi-part/resume badges, strict title/author-only hover preserving child colors, and non-destructive Toast notifications so single-video failures never wipe the gallery.
- Debounced Watch View resize relayout (200 ms) while playing so frame drags do not repeatedly reconnect HTTPS streams.

### Fixed

- Fixed Netscape `#HttpOnly_` cookie parsing in `backends/bili/bili.mjs` (previously discarding `SESSDATA` on read), separated `httpOnly` from `includeSubdomains`, and made cookie jar writes atomic via temp file rename.
- Isolated cookie modes in `etaf-bili-service.el` (`:read` for API calls, `:read-write` only when seeding missing `buvid3`, `:none` for `hdslb.com` cover downloads), eliminating concurrent `cookies.txt` corruption.
- Fixed unmount cleanup to reset `cover-active`, clear `'loading` cover states and remove partial `.cover-*` temp files so `:keep-alive` remounts never stall cover loading; capped local cover cache size (400 files) and enforced 30-minute TTL with login/logout invalidation on stream URLs.
- Fixed match-data clobbering in timestamp extraction and danmaku XML parsing, and moved Watch View Escape handling to ETAF's `:on-dismiss` contract.

### Removed

- Removed dead SMS sign-in commands from `backends/bili/bili.mjs` (gated by graphical captcha).
