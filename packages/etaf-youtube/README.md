# ETAF YouTube

ETAF YouTube is a native YouTube client rendered as one ETAF text
application. It browses the signed-in account's home, Shorts, subscriptions,
history, playlists, watch later, liked videos and live pages, searches with
filters, opens channels and playlists, reads a video with its comments and
recommendations, and plays the video with sound inside the application's own
canvas. Listings and playback media come from the shared `youtube` skill
through its protocol 1 JSON interface; a controlled browser keeps the account
session, so the application never stores credentials.

The application is the unit of state: `M-x etaf-youtube-open` mounts it in
`*YouTube*`, the shell adapts to the window width, and `etaf-youtube-close`
releases the session, its requests and its player.

## Capabilities

- Browsing: home, Shorts, subscriptions, history, playlists, watch later,
  liked videos and live, with the account's filter chips and channel tabs.
- Search: one query with the `all`, `videos`, `channels`, `playlists` and
  `live` filters.
- Video page: title, author, subscriber and view counts, published date,
  like/dislike, subscribe, save and a comment section with replies.
- Playback: the ETAF native video Component decodes the resolved stream into
  the application canvas, with audition, seek, volume, mute, playback rate,
  quality selection, captions rendered under the canvas and theater mode.
  Playback state is polled once a second, so the transport clock and position
  follow the decoder, and leaving a video stores its position for the next
  opening.
- Appearance: dark and light palettes independent of the Emacs theme,
  a fixed search/account bar, rounded filter buttons and SVG navigation.
  Video cards put titles ahead of channel and view metadata; durations sit
  on the thumbnail and Shorts use a separate portrait grid.
- Layout: the shell adapts from wide windows down to a compact one. The
  sidebar collapses to an icon rail, landscape cards become a single column,
  the watch page stacks and its transport wraps. The top bar has a stable
  height during loading, scrolling and resizing; navigation and content
  scroll independently below it. A short window shortens the canvas
  so the transport stays visible. Below about 40 columns or 12 rows the
  structure is kept and the viewport clips.
- Regions: the shell, sidebar, content and comment areas are named regions,
  so `M-g` selects one with a hint key and `C-c s`/`C-c c`/`C-c m` focus the
  sidebar, content and comments directly.
- Local state: playback preferences and per-video resume positions in a
  SQLite store; account lists and comments stay in memory because the account
  remains their authority.

## Requirements

- Emacs 29.1 or newer with the ETAF, ETAF UI, Ebox, ECSS and ETAF DB
  checkouts beside this repository (or `../etaf` and so on from a nested
  checkout).
- `ffmpeg` and `ffplay` for video and sound.
- Node.js for the backend bundled in `backends/youtube/`; it talks to the
  controlled Chrome page that keeps the account session. No external skill is
  needed: sign in from Emacs with `M-x etaf-youtube-login`, check with
  `M-x etaf-youtube-account`, and sign out with `M-x etaf-youtube-logout`.

## Start

```elisp
(add-to-list 'load-path "/path/to/etaf-youtube")
(require 'etaf-youtube)
(etaf-youtube-open)
```

Opening the application replaces the current window's buffer without splitting
it. The application owns its chrome, so it does not add an Emacs mode line or
borrow the editor header line for its multi-row top bar. ETAF measures and
follows the usable window viewport automatically, including the space the
editor reserves at the right edge. A newly loaded feed has no selected card;
route selection in the sidebar is independent of card selection.

Application keys: `SPC` play/pause, `f`/`b` seek five seconds, `[`/`]` volume,
`m` mute, `s` sidebar, `t` theater, `d` appearance, `r` refresh, `u` back,
`RET` activate, `/` search, and `C-c s`/`C-c c`/`C-c m` to focus the sidebar,
content and comment regions. `M-g` selects a region by hint key, `?` lists the
application keys and region hints, and a key never fires while the search
field (or any other text input) is editing. Escape, Tab, the arrows and `q`
keep their framework behavior.

## Documentation

The authoritative public API inventory is the Commentary in
`etaf-youtube.el`. The ETAF Reference Manual documents the framework
Components this application builds on.

## Development

```sh
make check   # structure, compile, public acceptance, API declarations
make test    # the public acceptance suite only
```

The public suite runs headless and offline: the skill transport, the
thumbnail downloader and the store are injected, and the fixtures contain
only synthetic, public-shaped data.
