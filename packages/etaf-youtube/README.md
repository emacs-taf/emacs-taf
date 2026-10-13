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
  quality selection, captions and theater mode.
- Appearance: the application's own dark and light palettes, independent of
  the active Emacs theme, plus a collapsible sidebar.
- Local state: playback preferences and per-video resume positions in a
  SQLite store; account lists and comments stay in memory because the account
  remains their authority.

## Requirements

- Emacs 29.1 or newer with the ETAF, ETAF UI, Ebox, ECSS and ETAF DB
  checkouts beside this repository (or `../../etaf` and so on from a nested
  checkout).
- `ffmpeg` and `ffplay` for video and sound.
- The shared `youtube` skill available through `pi-skill`, plus its controlled
  Chrome profile. See the skill's own documentation for the one-time login.

## Start

```elisp
(add-to-list 'load-path "/path/to/etaf-youtube")
(require 'etaf-youtube)
(etaf-youtube-open)
```

Application keys: `SPC` play/pause, `f`/`b` seek five seconds, `[`/`]` volume,
`m` mute, `s` sidebar, `t` theater, `d` appearance, `r` refresh, `u` back,
`RET` activate, `/` search. Escape, Tab, `?`, the arrows, `M-g` and `q` keep
their framework behavior.

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
