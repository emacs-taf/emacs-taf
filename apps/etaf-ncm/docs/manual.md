# ETAF NCM manual

ETAF NCM is a NetEase Cloud Music client for Emacs. The player is a single ETAF
view: a sidebar of libraries, the library list, a side panel with the
synchronized lyric or the queue, and a playback bar. Playback itself stays in
mpv, driven by the `netease-music` backend; the player is the interface over it.

The [root entry Commentary](../etaf-ncm.el) is the authoritative list of
supported functions, variables, the app Component and the error type. This
manual describes the workflows and the contracts behind them.

## Prerequisites

- Emacs 29.1 or newer.
- Core framework packages (`ecss`, `ebox`, `etaf` and `etaf-ui` from `emacs-taf/etaf`) on `load-path` for a source checkout, or installed via `M-x etaf-install`.
- The bundled backend, Node.js, Python 3 and mpv, with a signed-in account.
  The backend ships inside this package under `backends/netease/`; the README's
  "The bundled backend and its one-time login" section gives the check, login
  and state directory. The backend keeps its login state and queue under
  `etaf-ncm-state-directory`, which the client passes to it.

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/etaf-ncm")
(require 'etaf-ncm)
```

## Opening the player

```elisp
M-x etaf-ncm-open
```

The player mounts in `etaf-ncm-buffer-name` (default `*ETAF 网易云音乐*`), hides
its mode line and fills the selected window instead of letting a display
rule split the frame; it takes the window selection and focuses the song
list. Every control is reachable from the keyboard through ETAF's shared
navigation: `TAB` / `S-TAB` move between regions (sidebar, chips, list, pane
tabs, side panel, player controls), arrows and `C-n` / `C-p` / `C-b` / `C-f`
move inside a region, `RET` / `SPC` activate the focused control and `?`
opens read-only, searchable help inside the same buffer and Emacs window.
Its bindings come from the current player region; browsing help does not
change playback or the queue. Escape leaves search editing first, then closes
help, while clicking the backdrop closes it directly and restores the opening
focus. The execution palette remains available via `M-x etaf-palette`.
`M-x etaf-ncm-close` unmounts the
player and kills the buffer; the session behind it stays usable, so reopening
with the same session keeps its library, selection and queue.

The window and the client are two different things. `q` (or
`M-x etaf-ncm-close`) only closes the window: the backend player keeps
playing, like a client minimized to the tray. `Q` (or `M-x etaf-ncm-quit`)
quits the client: it stops the backend player and then closes the window.
Exiting Emacs stops a player the app started as well, so mpv never keeps
playing behind a closed Emacs; a player the CLI started is left alone. The
backend keeps its queue snapshots either way, so the CLI can still bring the
queue back.

Repeated `C-x b` switching away from the buffer does not close the player.
Killing the buffer directly has the same effect as `etaf-ncm-close`: mounting
and unmounting are what start and stop polling, and a session that was unmounted
is revived by its next mount.

### Keys

| Key | Action |
| --- | --- |
| `↓` / `↑`, `C-n` / `C-p` in the focused list | Move the library selection, scrolling a page at the ends |
| wheel | Scroll the queue window when over the visible queue panel; otherwise scroll the visible library window without moving the selection |
| click a row | Select it; pressing the selected row plays it |
| `RET` in the focused list | Play the selected row |
| `Home` / `End` in the focused list | Jump to the first / last loaded row of the library |
| `PageUp` / `PageDown` in the focused list | Move the selection by one page |
| `↑` / `↓` in the focused queue | Move between queue entries, scrolling the queue at its edges |
| `←` / `→` on the focused progress / volume slider | Seek / change volume by five |
| click or drag the progress bar | Seek to the position under the pointer |
| click or drag the volume slider | Set volume at the pointer, from 0 to 130% |
| click the cover / `词` / queue control | Show lyrics / lyrics / the queue, preserving the current selection and queue window |
| click a row's download / `+` icon | Download / add to queue directly; the compact layout keeps download |
| `SPC` | Pause or resume; with an empty queue it plays the selected song |
| `c` | Open the playing track's album art in the system image viewer |
| `n` / `p` | Next / previous queue entry |
| `a` | Append the selected song to the queue |
| `d` | Download the selected song into the local library |
| `s`, `/` | Search songs (a `read-string` prompt) |
| `L` | Sign in with an SMS verification code (a minibuffer prompt for the phone number and then the code) |
| `g` | Refresh the library, playback status, queue and account |
| `i` | Switch the side panel between the lyric and the queue |
| `o` | Open the full-page view of the playing song; `Esc` or `← 返回` returns |
| `m` | Cycle the full-page view between the auto, split and poster designs |
| `v` | Switch between the library list and the side panel in a compact layout |
| `r` | Toggle list repeat (`列表循环`) |
| `z` | Toggle shuffle |
| `f` / `F` | Like / unlike the playing song |
| `+` / `=` / `-` | Volume up / down by ten |
| `,` / `.` | Seek ten seconds back / forward |
| `1`-`9` | Jump to the nth sidebar library |
| `T` | Switch between the dark and the light palette |
| `?` | Open read-only, searchable keyboard help inside the player |
| `TAB` / `S-TAB` | Move focus between regions; arrows move inside the sidebar, chips, tabs and player controls |
| `Esc` | Close an open surface |
| `q` | Close the player window; the backend keeps playing |
| `Q` | Quit the client: stop the backend player, then close |

`n` and `p` intentionally replace Ebox's line scrolling: the player view is
paginated to its region, and the wheel scrolls the library's row window
without moving the selection. Resizing that region updates the layout and
re-fits the page; standing alone the region is the buffer window, and an
embedded player follows the window, pane or tab that hosts it; see
[Window layouts](#window-layouts).

### Signing in

```elisp
M-x etaf-ncm-login
;; or press L in the player
```

The command signs in with an SMS verification code. It reads the phone number
in the minibuffer — the number the backend remembers from the last sign-in is
offered as the default, so pressing `RET` reuses it — asks the backend to text
the code, and then reads the code once the backend reports the message went
out. On success the backend stores the cookie in its own state directory and
the player reloads its account and libraries; the login state then follows the
normal backend resolution order (environment, then the stored cookie).

The same sign-in is available in a shell (`netease-music login --sms <phone>`,
then `login --sms-code <code>`; see the README for the bundled command), and
QR sign-in (`login`) remains available there.  A code NetEase accepts can still
come back as `8860`「请确认是否本人账号」: that is the service asking for the
account to be confirmed, not a wrong code.  The command then shows the QR code
that step returns; scanning it with the same account's app completes the
sign-in without a second code.  When a backend reply says the login expired, the player's
banner says so and names `L`; no shell detour is needed.

A failure the backend explains stays on display in the red banner above the
library — wrapped over as many lines as it needs — until a newer message
replaces it, so a message the reader has to act on is never lost to routine
playback polls.

### Window layouts

The player reads the width and the height of the region that shows it and
adapts, so a narrow frame behaves like a phone and a small one behaves like a
widget instead of squeezing three columns into either:

| Region | Layout | What is visible |
| --- | --- | --- |
| `etaf-ncm-wide-columns` and wider | `wide` | Library sidebar, song list and side panel at the same time |
| `etaf-ncm-medium-columns` up to that width | `medium` | Glyph-only library rail, one pane at a time |
| `narrow` width, enough rows for a page | `narrow` | Library chips under the header, one full-width pane |
| Narrower than 46 columns, or too short for a ten-row page | `card` | Cover, track, one pane, its switch and the transport |
| Narrower than 30 columns, or shorter than 16 rows | `tile` | Track, the lyric and the transport |

The card family is the small-size player: it draws no header, no library
strip and no player bar.  A card keeps the cover band, the track, one content
pane, the `收藏` / `歌词` / `推荐` switch and the transport, with one clear row
between the bands; it opens on the lyric when the window shrinks from a larger
layout.  The switch names the two libraries a small frame is read for, so a
press on `收藏` or `推荐` loads that library into the list pane, and `歌词`
brings the panel back; the queue keeps its own way in through `i`, and every
other library stays one digit key away.  A small frame shows a page, not the
library: the wheel and the arrows walk the whole loaded list, and the card
draws no counter, so nothing suggests the page is the end of it.  A tile drops
the cover, the progress line and the switch row, so every row it has left
belongs to the lyric; `v` and `i` still switch panes there.  Growing the window
restores the larger layout, and neither size keeps hidden state of its own.

The thresholds are derived from what the panes are made of, not from a screen
size: the header and a full row declare the columns their labels and actions
need, the list pane's minimum is the larger of those, and each breakpoint adds
the sidebar or the rail to it.  Changing a label or an action moves the
breakpoints with it; the defcustoms remain as overrides.  Rows adapt inside a
tier too: a narrow list folds the artist into the name cell and drops the
album, then the badge, while the name column keeps its minimum.  The chip strip
shrinks its gaps and then its chips, so every library stays reachable.

In `medium` and `narrow` the header gains pane tabs and the player bar stacks
into three lines, dropping its cover and quality badge while keeping the track,
transport, pane controls, progress and volume. The page fills every row the
window budget leaves after the header, chip strip, pane switch and player bar;
the wheel scrolls the window through all loaded rows (`etaf-ncm-wheel-rows`
rows per tick, the same step the canvas uses), and the footer names the loaded
count and the backend total.
The library list itself is one scrolling canvas: rows are laid out once and
Ebox scrolls them natively, so a wheel or trackpad gesture runs continuously
instead of stepping a painted page. `v` switches between the list and the side
panel there, `i` shows the lyric or queue panel, and `etaf-ncm-show-pane` does
the same from Lisp. `etaf-ncm-state` reports the current `:layout` and `:pane`.

Two type sizes are used: the frame's default for anything a reader acts on, and
`etaf-ncm-font-meta` for subtitles, counters, hints and credits.  Emphasis uses
weight, never a larger size; a very short frame drops the subtitle and the hint
rather than shrinking the text. The login row shows an account icon with the
nickname (and `VIP` when the backend reports it) and reads `未登录 · L 登录`
while signed out; pressing it starts the same sign-in as `L`.

The queue and lyric windows also fit the panel's height. Enlarging the window
shows more entries; shrinking it keeps the playing queue entry or current lyric
line visible. Translations share the lyric's line budget.

Both width thresholds are defcustoms, so a font or a display scale that makes
the text wider only needs a different pair of numbers. A session without a
window, as in a headless batch run, keeps the `wide` layout.

### The playing page

`o` — or a press on the cover in the player bar or the card — opens one page
for the playing song, the way a phone player does.  It reads the same retained
sources as the bar, so playback, the lyric and the spectrum keep moving behind
it; `Esc`, the back control or a dismiss returns to the player without
touching the library, the selection or the open panel.

The page is one picture.  `etaf-ncm-hero-file` bakes it with ffmpeg: the whole
cover, scaled to fit the page and padded with its own average colour, blurred
hard so the page takes the artwork's colour outward instead of cutting the
artwork away; then a sharp copy of the same cover over the part the text does
not cover, fading into the panel colour on the edge where the text begins.  The
picture is cached per cover, size and design under `etaf-ncm-state-directory`,
drawn at the frame's scale factor so the sharp copy stays crisp on a Retina
frame, and rendered synchronously — a resize rebuilds it once, and a failed
render is visible instead of silently leaving a blank page.  Without ffmpeg or
without a cover the page is the panel colour and everything else keeps working.

Three designs share the same content, chosen by `:now-mode`:

- `auto` (the default) splits a wide page and turns a narrow or short one into
  a poster: a side column would squeeze the text on a narrow frame, while two
  halves each read well on a wide one.
- `split` gives the picture one pane and the text the other — half and half on
  a wide frame, stacked on a narrow or short one.
- `immersive` is the poster: the picture across the whole page, the
  information under it in a band across the bottom.

`m` cycles the design; `etaf-ncm-state` reports `:now-mode`.  The text carries
the track, the artist, the lyric pool, the spectrum, the progress line and the
transport, each centred in its column.  Nothing in it paints a background of
its own, and the progress line tracks the panel colour instead of drawing a
rail.

The parts appear by height, so a small page stays a poster with its controls
instead of squeezing everything in: the header at 16 rows, the artist at 20,
the spectrum at 24, and the lyric only when the fixed parts leave at least five
rows for it.  Whatever the lyric does not take is an elastic gap that pushes
the progress and the transport to the bottom.

The spectrum follows the audio.  `etaf-ncm-meter-start` decodes the same source
mpv reports (`status`'s `path`) with a second, rate-paced ffmpeg, and
`etaf-ncm-meter-levels` turns the newest block into one Goertzel band per
column, with a fast rise and a slow fall.  A paused player, a missing ffmpeg or
an ended track leaves the bars at silence, and a seek restarts the decoder from
the new position.

## Libraries and search

The sidebar groups the backend's libraries: the daily recommendation, the
private FM, the liked songs, the user's playlists, the saved albums and artists,
the charts, the podcasts and the recent plays. Selecting one loads it and resets
the selection to its first row. `etaf-ncm-sections` holds the inventory, so a
package can rebind it to show a different catalog.

Search queries the catalog by song by default; the search library accepts a
playlist scope as well. Results behave like any other library: they can be
played, and songs can be queued.

Library loads request 1000 rows by default. Set `etaf-ncm-list-limit` to change
that budget; the actual request is at least `etaf-ncm-fetch-limit` (the existing
lower bound) and three visible pages. `Home`, `End`, `PageUp` and `PageDown`
navigate every loaded row, including those beyond the first 100.

The footer shows `第 X-Y 首 / 共 N 首` with the backend's total when supplied.
If the backend returns only part of a library, a second line says
`已加载 M / 共 N 首` instead of presenting that partial count as the library
size. Raise the limit and press
`g` to request more; the backend may still impose its own limit. Cached lists
retain their totals while refreshing.

## Playback and the queue

The wide player bar follows the native client's arrangement. On the left, a
cover placeholder opens the lyrics; a reported VIP badge precedes the title
and artist on one line. Small actions below add the selected song (`+`, `a`),
like the playing song (`♡`, `f`; `F` unlikes), toggle shuffle, stop, and open the
queue beside its count. The message below these actions reports command feedback.
The centre has like, previous, a prominent red play/pause pill, next and list
repeat. Elapsed time, a thin seek bar and duration sit under that cluster. The
bar's controls and icons are `etaf-ui-icon' SVGs: one optical size, one style,
and no glyph can change the row height.

On the right, quality appears only when playback status reports it: `无损` for
lossless, otherwise the supplied quality, bitrate or VIP hint. `词 ON/OFF`
indicates whether the lyrics are visible; pressing it opens that pane. The
queue control opens the queue. The speaker, slider and percentage show volume.
Clicking or releasing a drag on either slider selects the value under the
pointer. Volume changes appear immediately, then reconcile with the backend's
reply. The existing volume and seek keys still work; no new key is required.

Every playback action is a backend command; the player reports what it sent in
the message line and then re-reads playback truth, so the displayed state never
stays a guess. Transport commands show their effect immediately and reconcile
with the reply; a command that can move the queue reloads it.

A press selects a row and a press on the selected row plays it: a double click
therefore starts the song even when the first repaint took a moment. In the
daily recommendation, liked songs and private FM, playing a song row queues
the loaded songs and starts directly at that row, without playing the first
song beforehand. `n` and `p` continue through those loaded songs in order. The `播放全部` button appears
only in those libraries, where whole-list playback is supported.

Songs in search results or recent plays still play directly. A playlist, album,
artist, chart, podcast or episode row is resolved by the backend into its
playable songs. `r` controls list repeat (`列表循环`), the backend's mpv
`loop-playlist` setting. The header's reload action names what it can do:
`换一批` on private FM, where the backend answers with a new batch, and `刷新`
elsewhere, because the same library request returns the same rows -- the daily
recommendation is one batch per day.

The queue panel opens around the playing position and shows
`第 X-Y 首 / 共 N 首` using the loaded window and backend count. Roll the wheel
over the panel to reach any loaded queue entry without changing the library
selection or playback. That window stays where you scrolled through unchanged
status refreshes; a new playing entry or changed queue centres it on playback
again. Clicking an entry jumps to it, and visible entries remain reachable by
`TAB` and `RET`. The current entry is marked in the list.

## Local downloads

The row's download icon downloads it directly; the `+` icon adds it to the
queue. There is no options menu. Compact rows keep the download icon; `a`
still adds the selected song to the queue. `d` downloads the selection.
The download arrow becomes a check mark when the file is on this machine;
clicking that check downloads it again. The message line reports progress.

The backend does the downloading: it takes the best quality the account can
play, stores the file under its own download directory and registers it, so
the marker is the backend's truth, not a local guess. The Emacs player only
sends the row's id and reads the registry back, so a file downloaded from the
command line shows the same check mark after `g`.

Playback prefers the local file: when a queue is built, every registered song
whose file is still on disk is played from its path instead of fetching a new
stream URL, and the keepalive never replaces it. A downloaded song therefore
keeps playing without a network round trip and without the five-minute URL
expiry. Downloading a song that is already local refreshes the file in place.

## Lyric, translation and theme

The lyric is fetched for the playing song id, parsed from LRC into timed lines
and shown with the line of the elapsed position emphasized. When the backend has
a translation for the song, each line shows its translation next to it. The
panel switches to the queue with `i`.

The palette has a dark and a light variant. `etaf-ncm-theme-mode` seeds the
mode a new Emacs session starts with; the live mode is one reactive cell, and
`etaf-ncm-color` resolves single colours from it while
`etaf-ncm-theme-defaults` publishes the `:ui-*` tokens the mounted player hands
to the shared ETAF UI controls, so buttons, inputs and badges follow the same
palette.

`T` and the title-bar switch of a panel framing the player write that same
cell, and the player declares it to its host with `etaf-surface-declare`.  A
panel therefore paints the player's palette and offers the player's modes with
the current one selected; switching on either side repaints both, so the
appearance is one state rather than one per surface.  Pressing `T` alone still
repaints the mounted player, because the palette follows the cell.

## Scripting the player

A session is complete without a buffer: `etaf-ncm-create` returns a headless
player, the action functions drive it, and `etaf-ncm-state` reports what it
knows as a detached plist.

```elisp
(require 'etaf-ncm)
(let* ((player (etaf-ncm-create))
       (client (etaf-ncm-make-client)))
  (plist-put player :client client)
  (etaf-ncm-refresh player)
  (while (plist-get (etaf-ncm-state player) :loading)
    (sit-for 0.05))
  (etaf-ncm-move-selection player 2)
  (etaf-ncm-activate-selection player)
  (plist-get (etaf-ncm-state player) :status))
```

`etaf-ncm-state` copies every value, so reading it can never change the player
and asserting against it is safe. Requests are asynchronous: an action returns
after sending its request, and the reply updates the state. Loading carries a
generation counter, so a reply from a superseded library or search is dropped
instead of overwriting the newer result.

`etaf-ncm-press-row` performs the list gesture a click uses:
`(etaf-ncm-press-row player 3)` selects the third row, and pressing it again
plays it. Transport commands show their effect immediately and reconcile with
the backend reply, so `etaf-ncm-state` right after `etaf-ncm-toggle-playback`
already reports the new playback state.

To embed the player in a larger layout, mount the view yourself:

```elisp
(let* ((player (etaf-ncm-create))
       (buffer (get-buffer-create "*my-music*")))
  (plist-put player :buffer buffer)
  (etaf-mount buffer (etaf-ncm-view player)
              (list :viewport-width 1200 :viewport-height 40))
  (pop-to-buffer buffer))
```

`etaf-ncm-view` returns the View; `etaf-mount` owns the runtime. Unmounting the
runtime disposes the session's polling, subscriptions and pending requests.

## Custom backends

The player talks to a *client*, a function or a structure that accepts a request
plist and a callback. `etaf-ncm-client-factory` is the function of no arguments
that new sessions use, so binding it is enough to drive the whole player from
another backend:

```elisp
(setq etaf-ncm-client-factory
      (lambda ()
        (lambda (request callback)
          (funcall callback
                   (pcase (plist-get request :op)
                     (:browse (list :ok (my-songs)))
                     (:status (list :ok (my-status)))
                     (_ (list :ok (list :ok t))))))))
(etaf-ncm-open)
```

The reply is `(:ok DATA)` on success and `(:error MESSAGE :hint HINT)` on
failure, delivered at most once. A backend failure never signals: it lands in
the session's `:error` and `:message`, so a missing network or a stopped mpv
leaves the player usable and `g` retries. Only invalid player operations, such
as an unknown library, a blank search keyword or a row without a playable
target, signal `etaf-ncm-error`; the entry Commentary lists those cases.

Playback status may include `:vip`, `:lossless`, `:quality`, `:bitrate` and
`:vip_hint`. Flags accept booleans, positive numbers, or `"true"` / `"1"` /
`"yes"`. Bitrate numbers above 1000 are interpreted as bits per second and
displayed as kbps; a textual bitrate hint is preserved. Missing hints produce
no quality badge. These fields describe the playing song, independently of
the selected library row.

`etaf-ncm-make-client` builds the default client: pass `:backend-directory`,
`:state-directory`, `:node-program` or `:timeout` to point it at a different
checkout, state directory, Node.js binary or request budget.

## Polling and cost

While a song is playing the player ticks once per `etaf-ncm-status-interval`
(one second by default), advancing the local clock for a smooth progress bar and
asking the backend for playback truth. A tick never overlaps the previous
request. The playing position is a retained source, so the elapsed label, the
progress fill and the lyric window update in place through their Host getters
and a playing second does not republish the view. The player bar itself is a retained
panel: the play/pause pill, the heart, shuffle, repeat and the status message
read their own reactive sources inside Host bindings, so pressing one of them
publishes a retained update instead of rebuilding the view. The lyrics and
queue panels are two fixed-canvas variants whose visibility follows the
`:aside` source, and every library row reads the selection source in its own
paint bindings; switching panels publishes retained updates, and moving the
selection or the playing song slides the matching highlight bar onto the new
row on ETAF's shared animation clock instead of jumping to it. While nothing is
playing it checks every `etaf-ncm-idle-poll-interval`
(fifteen seconds). A lyric is fetched only when the playing song id changes, and
the queue list is read from the backend's queue state file rather than
re-downloaded.

Sidebar libraries are local-first, including across app/Emacs restarts. The
previous `library-cache.eld` in `etaf-ncm-state-directory` is restored before
mounting. Clicking a cached section performs no disk I/O or backend request;
it immediately shows the cache, including an empty cached library. The
snapshot contains only library metadata, not audio URLs or credentials. It is
bounded to 4 MiB, private (0600), atomically saved after replies settle, and tied
to the current credential configuration. Reopen after changing accounts.
Corrupt/incompatible snapshots are ignored and rebuilt; the backend remains
the authority. Only a never-cached section needs its first network load.

Lyrics and downloaded cover art persist across restarts in a second cache,
`media-cache.sqlite`, a SQLite database built on ETAF DB beside that snapshot.
A lyric is stored per song id together with its translation, and a cover is
indexed per song id with the URL it was downloaded from. A cache hit publishes
the lyric lines or the cover file immediately without asking the backend; a
changed cover URL or a deleted file is a miss and downloads again. A session
without a snapshot path (a function client) keeps both in memory only.

The mounted player warms missing sidebar lists one at a time and revalidates
lists older than `etaf-ncm-library-refresh-interval` (five minutes). Equal
replies do not update row sources or repaint; changed replies retain selected
song and viewport identities. Revisiting a section also restores its previous
position. In-flight requests for the same list are shared. Failed refreshes
keep old data, back off, and pause on an expired login until a successful load.
`g` requests a revalidation without blanking cached content. Background work
pauses when the player is hidden; setting `etaf-ncm-prefetch-libraries` to nil
disables automatic library refresh/warming (manual `g` remains available).

Unmounting cancels the timer and drops late replies, so a closed player costs
nothing. A long-running Emacs that keeps a player mounted only pays the poll it
selected.

## Troubleshooting

| Symptom | Cause and remedy |
| --- | --- |
| The message line shows `Netease backend script is missing: ...` | `etaf-ncm-backend-directory` does not point at a backend; reinstall etaf-ncm or set it to a valid copy. |
| The message line shows the backend error | Login, Node.js or mpv is the usual cause. Run `netease-music status` in a shell, then press `g`. |
| The banner says `登录已过期：按 L 用短信验证码重新登录` | Press `L` (or `M-x etaf-ncm-login`), confirm the phone number, then enter the code from the SMS. |
| The sign-in stops at `code=8860`「请确认是否本人账号」 | NetEase wants the account confirmed, not another code: a QR image opens, and scanning it with the same account's app finishes the sign-in. A recycled phone number is acknowledged automatically. |
| Every library is empty | The backend replied with an error; check `:error` in `etaf-ncm-state`. |
| The progress bar jumps instead of moving | Only `:elapsed` is interpolated locally; the backend is the truth, so a slow backend shows its own pace. |
| The window shows fewer rows after a resize | Press `g`; the page count is re-fitted on refresh. |
| The lyric panel says `这首歌没有歌词` | The track has no lyric, which is normal for instrumental music. |
