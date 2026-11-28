# Changelog

All notable user-visible changes to ETAF NCM.

## Unreleased

### Changed

- Reissued as 0.2.5 after package-loading and workspace updates since 0.2.4.

### Changed

- Reissued: the source had moved ahead of this version without a
  release, so the published file no longer matched it.  Changed since
  0.2.3 was cut: `CHANGELOG.md`, `README.md`, `backends/netease/mpv-ctl.mjs`, `backends/netease/netease-api.mjs` and 7 more.
### Added

- A playing page for the whole window.  `o` — or a press on the cover in the
  player bar or the card — opens the playing song as one page: the cover
  blurred across it, a sharp copy of the same cover over the blur, and the
  track, the lyric pool, the progress line, the transport and a spectrum that
  follows the audio.  `Esc` or the back control returns to the player without
  touching the library or the open panel.  Every layout has the key, including
  the card and tile that draw no cover.
- The page has three designs, cycled with `m`: `auto` (the default) splits a
  wide window in half and turns a narrow or short one into a poster, `split`
  keeps two panes, `immersive` is the poster with the information band across
  the bottom.  `etaf-ncm-state` reports `:now-mode`.
- The backdrop is one picture baked by ffmpeg: the whole cover fitted to the
  page and padded with its own average colour, blurred, with a sharp copy over
  the free area and a fade into the panel colour.  Nothing is cropped or
  stretched, so the page shows the whole artwork at every window shape.  It is
  cached per cover, size and design, rendered at the frame's scale factor for a
  crisp sharp copy, and rebuilt once per resize.
- The spectrum is decoded from the source mpv is playing by a second,
  rate-paced ffmpeg, analysed with a Goertzel band per column.  It rises at
  once and falls slowly, restarts after a seek, and sits at silence when there
  is no source or no ffmpeg.

### Fixed

- Playing works on Windows.  `play`, the transport keys, volume, seek, queue,
  cover and like all ran through `netease-music.sh`, and Windows has no native
  `bash`.  They are now commands of `scripts/netease-cli.mjs`, so one Node
  implementation serves every system, and the mpv bridge opens a named pipe
  on Windows instead of a Unix socket.  Queue snapshots and downloads still
  live in the shell entry, which is POSIX only by design.

- Playback addresses come back.  `song/enhance/player/url/v1` started
  answering `code: 404` with a `null` url for every song, which the player
  reported as 「可能要 VIP 或没有版权」 even for songs the account owns; the
  request now carries the `immerseType` the endpoint expects, and the same
  songs resolve to a signed URL again.

- Signing in works on Windows.  The sign-in ran through `netease-music.sh`,
  and Windows has no native `bash`: the `bash.exe` in `C:/Windows/System32`
  launches WSL, which reads the script's Windows path as a relative name and
  exits 127.  The request never reached the backend, so no SMS went out and
  the player never asked for the code.  The SMS sign-in now runs as
  `scripts/netease-cli.mjs`, one Node implementation for every system, which
  needs no shell; a request that still needs the shell entry is refused on
  Windows with a message instead of failing as exit 127.

- Signing in with an SMS code finishes even when NetEase answers with its own
  verification step.  A code the service accepts can come back as `8860`
  「请确认是否本人账号」 instead of a session: that is a request to confirm the
  account, not a wrong code.  The backend now keeps one cookie session for the
  whole sign-in, acknowledges a recycled phone number, and, when the service
  asks for a security check, shows the QR code it returns so the same account's
  phone app can confirm it.  The login request keeps waiting for that
  confirmation instead of failing at once, and a refusal reports the service's
  own reason.

- A text terminal draws the player transport as words (`上一首`, `播放` /
  `暂停` in the accent colour, `下一首`) instead of the artwork icons and the
  accent pill.  Terminal fonts render the transport glyphs at uneven sizes, and
  the pill's fixed three cells left the pause glyph off centre.  The words name
  the action, keep every control one line high and match the card's other text
  controls.  A graphical frame keeps its icons and the accent pill.

- The library list is one scrolling canvas instead of a painted page.  Ebox
  scrolls it natively, so a wheel or trackpad gesture keeps running instead of
  needing a pause and a pointer move between ticks, and every loaded row is
  reachable.  The selection still clamps at both ends and the canvas follows
  it; the footer now names the loaded count and the total.
- One wheel tick scrolls three library or queue rows instead of one
  (`etaf-ncm-wheel-rows`), matching the step the rest of the canvas uses.  A
  small card needed one notch per song before, so a flick looked stuck.
- The header reload action is named for what it can do: `换一批` only on
  private FM, which answers a reload with new songs, and `刷新` on every other
  library, where the same request returns the same rows.  The daily
  recommendation is one batch per day, so its old `换一批` label promised a
  change the backend cannot deliver.
- The player and a panel framing it share one appearance state: `T` and the
  panel's title-bar switch write the same mode cell, the panel paints the
  player's palette, and either switch repaints both.  `etaf-ncm-theme-mode` now
  seeds the live mode instead of replacing it at runtime.

- A card names the two libraries a small frame is read for instead of a
  generic list tab: `收藏`, `歌词` and `推荐`.  Pressing a library tab loads it
  into the list pane, the queue keeps `i` as its way in, and a card never
  shows a page counter: a page is a window, the wheel and the arrows walk the
  whole library.
- The play/pause pill keeps a white glyph on its red block in both palettes. It
  used the body ink, which is near black in the light palette and left the glyph
  reading as a dark smear; the pill is also one cell narrower, so the block reads
  as a button instead of a bar.

- A frame too small for the stacked layout now becomes a card instead of
  squeezing the header, chip strip and player bar into it. The card keeps the
  cover, the track, one pane, its `列表` / `歌词` / `队列` switch and the
  transport, with one clear row between the bands, and opens on the lyric. A
  still smaller frame becomes a tile: the track, the lyric and the transport
  only, without the progress line or a switch row, so every remaining row
  belongs to the lyric. `v` and `i` still switch panes there, and growing the
  window restores the larger layout.

- `v` switches between the library list and the lyrics and queue panel in a
  wide layout too; the player no longer resets the pane on its own layout
  pass.

- The player opens as an ETAF application: every key, the wheel included,
  is a root key of its View, the canvas follows the palette and `q` closes
  the window through the application lifecycle. It requires ETAF 0.3.0 and
  ETAF UI 0.2.0.

- The sidebar marks are Han characters (`荐` `台` `心` `单` `碟` `人` `榜` `筒`
  `近`) in terminal frames: a terminal draws CJK at one exact width in its own
  font, so the category column shares size and alignment, and each entry keeps
  a distinct mark.  `c` opens the playing track's album art in the system image
  viewer, and a terminal cover uses a wider grid (18x9) so the approximation
  keeps more of the artwork.

- Terminal frames size album art by the cell's half-block pixels, so a square
  cover keeps its aspect instead of turning into a tall mosaic, and the lyric
  pane gives the cover a wider grid.

- The seek and volume meters draw a one-pixel rule again. `etaf-range` now
  honors `:bar-height` on graphical frames, so an unset value made both bars
  six pixels tall; the player asks for the hairline its native-style bar
  reserves inside the full-height hit row.
- Installing from the package archive now compiles every module: the entry
  resolves its `lisp/` directory from the file being compiled, so an
  installation started from a script cannot point the compiler at the script's
  own directory.

- The NetEase backend now ships inside this package under `backends/netease/`
  and no longer needs a Pi skill, `pi-skill`, or a separate `netease-music-cli`
  checkout. Node.js, Python 3 and mpv are the system tools; `qrencode` is
  optional and only used by QR sign-in. The login, queue and saved queues move
  to `${XDG_STATE_HOME:-~/.local/state}/netease-music`; the client passes the
  state directory to the backend, so both always agree.
  `etaf-ncm-skill-directory` became `etaf-ncm-backend-directory`, the client
  keyword `:skill-directory` became `:backend-directory`, and
  `etaf-ncm-doctor` reports the tools, the bundled scripts and the login state.

- `?` shows searchable, read-only key help inside the player without splitting
  its window or changing playback. Escape and backdrop dismissal restore the
  opening focus; command execution stays in `M-x etaf-palette`. The volume
  `=` alias is included alongside `+` in the effective binding list.
- The window and the client are separate now.  `q` (or `etaf-ncm-close`) closes
  the window and leaves the backend playing, like a client minimized to the
  tray; `Q` (or `etaf-ncm-quit`) quits the client: it stops the backend player
  before the window closes.  Exiting Emacs stops a player the app started, so
  mpv never keeps playing as an orphan, while playback the CLI started is left
  alone.
- Picking a song shows it at once: the playing marker, the title, the artist,
  the length and the queue count move to the picked row before the backend
  answers.  A status poll that still reports the previous song no longer moves
  the marker back while the play command is in flight, so double-pressing a
  row no longer flashes another song's marker on the way.
- The selection and playing highlight bars slide onto their new row on ETAF's
  shared animation clock instead of jumping, and the cursor follows the bar
  while it moves.
- The player keeps its own clear lines: one row of top padding inside each
  panel and one closing padding row inside the player bar, so a hosting
  window needs no inset and the surface stays one background at every size.
- The player lays out for the region it is given: its buffer window standing
  alone, or the window, pane or tab that embeds it.  Breakpoints, column and
  row budgets follow that region through `etaf-viewport` instead of reading
  the buffer's Emacs window, so an embedded player resizes with its host
  exactly like a standalone one.
- Every control is keyboard-operable through ETAF's shared navigation instead
  of an app keymap. `TAB` / `S-TAB` move between regions, arrows and
  `C-n` / `C-p` / `C-b` / `C-f` move inside the sidebar, chips, tabs, queue and
  player controls, the focused sliders step with `←` / `→`, and `?` opens a
  palette of all keys and controls. List navigation keys (`↑` / `↓`, `RET`,
  `Home` / `End`, `PageUp` / `PageDown`) act on the focused song list, and the
  cursor follows its selection. `etaf-ncm-mode-map` is removed; customize keys
  through the view instead.

- The player adapts to the window as one planned system instead of fixed
  breakpoints and squeezed parts. The tiers (`wide`, `medium`, `narrow`) are
  still there, but their thresholds are derived from the columns the header
  and a row actually need, the row variant is chosen by fit, and the chip
  strip shrinks its gaps and chips so no library falls off a narrow window.
  A narrow list folds the artist into the name cell and drops the album and
  badge in a defined order; a playlist or song name never disappears, and a
  name column always keeps its minimum width.
- The player bar sits one padding row above its content and none below: the
  window's echo area is the single clear line under it, so the content ends
  one row from the window edge. The top strip above the panels is gone; the
  sidebar, list header and lyric panel each keep their own one-row inset.
- The library page fills every row the window budget leaves after the header,
  the chip strip, the pane switch and the player bar; the wheel scrolls the
  window through all loaded rows and the footer labels the visible range and
  the loaded total (dropped only in a very short frame).
- The login row is now a status line: an account icon with the nickname and a
  `VIP` tag when signed in, `未登录 · L 登录` when not, and pressing it starts
  the same sign-in as `L`. The green state square is gone; the glyph rail
  shows the account icon alone with its state in the tooltip.
- The lyric and queue tabs use a tinted pill for the active tab instead of an
  underline, matching the compact pane switch.
- Header actions keep their intrinsic width, so `换一批` and `播放全部` are
  never clipped into shorter words at the wide-layout boundary.
- One type scale replaces the scattered small sizes: the frame default for
  anything a reader acts on, and `etaf-ncm-font-meta` (about 11 pt on a 14 pt
  frame) for subtitles, counters, hints and credits. Emphasis uses weight, and
  a short frame drops the subtitle and the hint rather than shrinking text.
- Cover art follows track changes immediately after the image is available,
  including consecutive songs with equally sized artwork and cached revisits.
  Playback status corrects an earlier queue reply's cover without waiting for
  the queue to refresh again.
- Opening the minibuffer (`M-x`, a completion popup or the player's own
  prompts) no longer shrinks the library page, the panes or the player bar to
  the lines the prompt borrows. The player keeps the layout it committed for
  the window and returns to the full view unchanged once the prompt closes.
- The selection and playing highlight are two overlay bars moved as retained
  host geometry. Moving the selection or changing the playing song no longer
  repaints the list plane; a row update costs content only, so a long list
  stays responsive.
- Library rows compose in flow order instead of absolute offsets: a row paint
  change (selection or playing marker) no longer re-renders the whole list
  plane, so selecting in a long library stays cheap. Wide and compact layouts
  paint identically.
- The mouse wheel scrolls a visible library window one row per tick without
  moving the selection; `j`/`k`, `RET` and clicks still select and bring the
  row back into view. Queue scrolling and its hit test are unchanged.
- Lyrics and downloaded cover art persist across restarts in a
  `media-cache.sqlite` SQLite database built with ETAF DB beside the sidebar
  snapshot. A cache hit publishes the lyric or the indexed cover file without a
  backend request; a changed cover URL or a missing file refreshes normally.
  Function clients without a snapshot path keep both in memory only.
- Sidebar libraries restore a private local snapshot before mounting, so
  cached navigation does no network or disk work even after restarting Emacs.
  Periodic refresh deduplicates in-flight requests, skips unchanged replies,
  preserves song/scroll identities and keeps old data when offline.
- Library rows retain viewport-sized slots and row-number bindings across
  scrolling and section changes. The playing glyph shares a text Host with
  the row number rather than using a hidden positioned overlay.
- Volume uses a retained numeric source for optimistic updates and replies,
  keeping the slider callback stable instead of rebuilding the player.
- Compact list/lyrics/queue tabs form one left-aligned, equal-width row.
  Only the visible pane is highlighted; the player follows without a blank row.
- Double-click starts directly on the selected song using the loaded list,
  rather than playing its first entry and issuing a later jump.
- Sidebar highlighting and library rows have independent drawing areas;
  switching cached lists updates retained text and colours.
- Row download and queue actions are visible inline; the options popup is
  removed. The `d` key downloads the selection. A downloaded row carries a
  check mark, and the backend plays the local file on the next queue instead of
  fetching a fresh stream URL and never lets the URL keepalive replace it.  The
  registry is the backend's `downloads` truth, so files downloaded from the
  command line show the same mark after `g`; downloading a song that is already
  local refreshes the file in place.
- Every interaction the app documents is now retained: play/pause, the
  heart, shuffle, repeat, the status message, the lyrics/queue switch, the
  compact pane switch and the library selection read their own reactive
  sources inside Host bindings, and measuring the scripted fixture gives
  11-90 ms with zero whole-candidate renders in either order.  Loading a new
  library now repaints through retained row slots: each visible row keeps its
  source across switches, and its title, meta, badge, time and play marker are
  prepared updates, so the library switch itself publishes no whole-candidate
  render.  The scripted benchmark reports about 300 ms for the first switch
  and about 144 ms once the row scenes exist, down from about 600 ms; the
  remaining cost is the per-row retained boundary render, which the framework
  still does once per row.  The library, the two aside variants and the player bar are
  absolutely positioned panels of the root stage; keep their anchors there
  when adding a panel whose Hosts must update in place.
- Pressing `SPC` or the play pill with an empty queue plays the selected song
  instead of sending a toggle the backend cannot act on.  Selecting a row and
  pressing play now starts that song, and the play/pause button no longer
  flashes back to paused.
- Every row stays within the frame's line height, so the canvas is never taller
  than the window and the bottom bar is not clipped. Glyphs that fell back to a
  taller font (`♪`, `♫`, `▶︎` with its variation selector, `↻`, `●`, `…`) are
  replaced with the shared SVG icons, plain text or a block; the GUI scenario
  now fails a checkpoint when any line exceeds the line height or a resize
  leaves the canvas taller than the window.
- The bottom player bar follows the native client's layout and keeps one clear
  line above and below itself: cover, VIP/title and track actions on the left, a
  red play/pause pill with the seek bar in the centre, and reported quality,
  lyrics, queue and volume on the right. Compact bars retain the controls in
  three rows without the cover or quality badge.
- Bar controls stay inside their columns at every width: a control shrinks to
  its content instead of filling the window, so the transport stays centred and
  the tools stay at the right edge. The play/pause glyph spans the pill, so its
  insets match on both sides.
- The sidebar and the narrow chip strip draw the same shared SVG icons as the
  player bar (`star`, `radio`, `disc`, `chart`, `mic` and `clock` joined the
  set), instead of a mix of text glyphs.
- The volume bar follows the native 0–100% scale, so its filled width matches
  the percentage label, and both the seek and volume bars keep the pointed
  position while the backend applies a gesture instead of jumping back.
- The like control flips between the filled and hollow heart as soon as it is
  pressed and returns to its previous state when the request fails.
- `n`, `p`, `SPC`, `<next>`, `<prior>`, `q` and `RET` reach the player in a
  mounted buffer even though the renderer binds them in its own minor-mode map.
  `RET` activates the focused control and falls back to the selected row.
- Bar controls use the shared `etaf-ui-icon' SVG set, so every icon shares one
  optical size and style and none of them changes the row height.
- Click or drag the seek or volume bar to set the position or 0–130% volume,
  with immediate feedback and backend reconciliation; the seek and volume bars
  are the shared `etaf-range' Component and never round the ratio to whole
  blocks. Cover, lyric and queue controls reveal their panes without resetting
  the library or queue window.
- While a song plays, the elapsed label and progress fill move through ETAF's
  retained Host updates instead of republishing the view every second.
- The player background reaches the window edge: the mount viewport uses the window
  body width in pixels, the buffer's default face follows the palette and the
  truncation slot stays blank, so a sub-cell remainder no longer shows as a gap.
- A selected sidebar entry highlights only its text line, while its whole
  two-line cell remains clickable and reachable through TAB/RET.
- Sidebar group labels keep a blank line between the label and the first entry.
- Queue windows fit the panel height, show the visible range and backend total,
  and let the wheel reach every loaded entry. Scrolling over the panel leaves
  the library selection alone; playback changes centre the queue again.
- Library loads request 1000 rows by default through `etaf-ncm-list-limit`,
  retaining `etaf-ncm-fetch-limit` as a lower bound. Footers preserve backend
  totals, label partial loads, and show one-based ranges across all loaded rows.
- Playing a song in daily recommendations, liked songs or private FM queues
  that library before jumping to the song. `播放全部` appears only where
  whole-list playback is supported.
- Repeat controls and help now say `列表循环`, matching the backend's list loop.
- The lyric window fits the panel height, including translations, while keeping
  the current line emphasized.
- A press on the row that is already selected plays it, so starting a song no
  longer depends on a second click arriving inside a timing window.
- Playback commands show their effect immediately: the play/pause state, the
  volume, the shuffle and repeat flags and the message line change before the
  backend answers, and the reply reconciles them.
- Library switches use a cached list when one exists and refresh it in the
  background; a mounted player warms the lists it has not seen yet, and
  `etaf-ncm-library-refresh-interval` (five minutes) keeps cached lists fresh.
  `etaf-ncm-prefetch-libraries` turns the background warming off.
- A list update re-renders only the rows whose data changed: the view passes
  stable callbacks instead of a fresh closure per row.

## 0.1.0

First release.

- Mount the player with `etaf-ncm-open`; the sidebar covers the daily
  recommendation, private FM, liked songs, playlists, saved albums and artists,
  charts, podcasts and recent plays, plus song search with a playlist scope.
- Play a row or a whole list, pause, skip, stop, set volume, seek, shuffle,
  repeat, like and unlike, and jump anywhere in the queue.
- Lyric panel with the current line highlighted and translations next to it;
  panel switches between lyric and queue.
- Dark and light palettes with one key, published as ETAF UI theme tokens.
- Headless sessions (`etaf-ncm-create` + actions + `etaf-ncm-state`) and a
  pluggable client (`etaf-ncm-client-factory`) for scripts and tests.
- The layout follows the window width: a wide frame keeps all three columns, a
  medium one keeps a glyph-only library rail with one visible pane, and a narrow
  one stacks the header and shows one full-width pane. `etaf-ncm-wide-columns`
  and `etaf-ncm-medium-columns` set the thresholds, `v` switches the visible
  pane and `etaf-ncm-show-pane` does it from Lisp.
- Runnable demo on a scripted library: `M-x etaf-ncm-demo-open`.
