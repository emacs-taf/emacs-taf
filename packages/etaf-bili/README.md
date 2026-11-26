# ETAF Bili

Browse Bilibili inside Emacs: real cover cards, inline search, popular videos
and rankings, with playback in the same buffer. Built with
[ETAF](https://github.com/emacs-taf/etaf) and its UI catalog.

![Cover gallery in the dark theme](media/etaf-bili-wide.png)

[Light theme](media/etaf-bili-light.png)

## What it does

- A responsive one-to-four-column cover gallery, with aspect-preserving
  thumbnails, readable two-line titles, creator, duration and compact counts.
- A catalog SearchField, channel Tabs and continuous wheel/trackpad scrolling. Metadata
  opens in a Drawer instead of reserving an empty sidebar.
- Skeleton cards during the first load, readable error/retry and empty states,
  a scoped loading animation and a short selection transition. The shared
  `etaf-animation-enabled` switch disables motion.
- Dark and light application palettes without modifying the user's frame,
  title bar or theme. Minimum usable window: **64 columns × 28 lines**;
  smaller windows deliberately clip rather than compress the controls.
- Asynchronous public-feed requests and at most three concurrent cover
  downloads. Covers are cached locally; failure leaves a usable placeholder.
- `RET` or a card's play button resolves its stream and opens the catalog
  media viewer with the CDN headers required for playback.

This is an unofficial public-video client, not the Bilibili open platform.
Login, account libraries, comments, danmaku and entitlement management are
not implemented. Available quality and playback depend on the server.

## Install

Requires Emacs 29.1+, `etaf`, `etaf-ui`, `ebox`, `ecss`, curl, ffmpeg
(with ffprobe and ffplay for video metadata and sound) and Node.js for the
account backend bundled in `backends/bili/`.

```elisp
(dolist (package '("ecss" "ebox" "etaf" "etaf-ui" "etaf-bili"))
  (add-to-list 'load-path (expand-file-name package "/path/to/checkouts")))
(require 'etaf-bili)
(etaf-bili-open)
```

## Use

| Key | Action |
| --- | --- |
| `/` | Edit the in-page search field; Return submits, Escape keeps the draft |
| Arrow keys | Move through cards in two dimensions |
| `n` / `p` | Next / previous video (`j` / `k` also work in the default direction scheme) |
| `RET` | Activate the focused control or play the selected video |
| Wheel / trackpad | Scroll through the loaded results continuously |
| `1` / `2` | Popular feed / ranking |
| `g` | Refresh |
| `i` | Open details |
| `T` | Switch application theme |
| `?` / `M-g` | Framework help / region navigation |
| `q` | Close the current modal first, then the client |

## Embed in a panel or desktop

`M-x etaf-bili-open` is one host. A caller that already owns a window mounts
the same View instead:

```elisp
(require 'etaf-bili)
(let ((buffer (get-buffer-create "*Bili*")))
  (etaf-mount buffer (etaf-bili-view (etaf-bili-create)))
  buffer)
```

The View lays out for the region it is mounted into and follows that region's
resizes, so a floating panel or a desktop window reflows the card grid instead
of clipping it. Mounting adopts the host buffer, which keeps the client's keys,
the inline search and the session-level commands working there. The first
mount loads the popular feed; unmounting stops transfers and polling but keeps
the library, selection and account, so a panel reopened with `:keep-alive`
resumes where it was. `etaf-posframe-register-app` opens it with
`:create #'etaf-bili-create` and `:view #'etaf-bili-view`.

Sign-in happens over the running client: the header's account chip reads
「登录」 until somebody signs in and then shows that account's name. Pressing it
(or `M-x etaf-bili-login`) paints the site's code in a centered panel while the
library stays visible underneath, dimmed; a phone confirms the scan, the panel
closes and the gallery reloads. Only the code method exists, because Bilibili
gates its SMS endpoint behind a graphical captcha. `M-x etaf-bili-account`
reports who is signed in and `M-x etaf-bili-logout` signs out and clears those
cookies.

The media viewer owns playback keys while open: Space toggles playback,
Left/Right seek, `m` toggles sound, `.` cycles speed and `n`/`p` switch videos.

## Documentation and checks

- [Manual](docs/manual.md): workflows, caching, failure recovery and integration.
- [Architecture](docs/architecture.md): data ownership, scoped UI and lifecycle.
- [Entry Commentary](etaf-bili.el): authoritative supported API.

```sh
make test     # offline public acceptance suite, including mounted catalog controls
make check    # structure, byte compilation, acceptance and API boundaries
```

GUI scenarios live in `scripts/etaf-bili-gui-scenarios.el`; the workspace
performance driver loads `benchmarks/performance-scenarios.el` for the
`bili.appearance` and `bili.scroll` workloads. Screenshots and batch tests are not latency
certification; use the real GUI workflow in the manual.
