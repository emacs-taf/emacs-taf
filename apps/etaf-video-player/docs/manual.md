# ETAF Video Player manual

## Playing a video

`M-x etaf-video-player-open` opens the player without asking for a source:
it plays the built-in demo, and `o` or `u` switches to a file or a stream
from inside the player.  To name the source up front,
`etaf-video-player-open-file` plays a local file with sound;
`etaf-video-player-open-url` (`u`) plays an HTTP(S) URL as a stream: ffmpeg
decodes it directly, so nothing is downloaded first.  Seeking needs the server
to support range requests, and a dropped connection is retried for up to five
seconds.  ffmpeg's HTTP reader reads the lowercase `http_proxy` environment
variable when a proxy is needed.  `etaf-video-player-demo` plays a generated
30 second test pattern and needs no file.  All of them create one buffer named
`*Video Player*` and reuse it: opening another source closes the previous
player first.  `etaf-video-player-close` (also `q`) saves the playback
position of a local file, cancels the status timer, destroys the native
session and its audio sidecar, and unmounts the ETAF Runtime.  Killing the
buffer closes the player the same way.

The player buffer hides its cursor, so no cursor frame flashes around the
picture.

The window is a themed shell: a header row with the title and the live
playback status, a playlist column and a details column that appear when the
published viewport is wide enough, the video stage between them, a transport
with a click-or-drag progress bar and a centred control row, and a hint
footer.  The page, panes, header and transport each paint one depth step of
the palette, so panes stay separated in both appearances; the stage follows
the appearance while letterbox frames stay black.  The play/pause and sound
glyphs change with the state, and the progress bar moves through retained
geometry instead of republishing the View.

The canvas is measured, not guessed: after every layout change the
application reads the framework's published viewport and the stage Host's
committed size (`etaf-host-ref-size`), keeps the source aspect ratio, and
sizes the canvas to fit.  `F` re-runs that fit.  Because Emacs reserves the
last character cell of each line and any partial bottom line, the player
adopts the frame background color with the application surface color while
it is open and restores the previous value on close, so no foreign strip
remains at the window edges.

Playback starts immediately. `SPC` pauses and resumes, `n` pauses and presents
exactly one more frame, `f` and `b` seek five seconds, and `+`/`-` step through
0.5x, 1x, 2x, 4x and 8x. Pausing releases the producer and the audio sidecar,
and resuming starts a new producer at the pause position, so a long pause
never makes playback jump forward to catch up. Seeking and rate changes
restart the producer at the current position too, so they are safe while
paused. When the file ends the last picture stays visible and the status line
shows `ended`; `SPC` replays from the start.

The producer's own frame rate may be lower or higher than
`etaf-video-player-display-fps` (24 by default). Display always claims only
the newest complete frame, so a slower display drops frames instead of
replaying a backlog; `etaf-video-player-state` reports the dropped count. The rate shown
in the status line is the number of frames presented in the last sample
window, not the timer rate, so a canvas too large for the display cost reports
a lower number instead of a hopeful one.

## Playlists

`etaf-video-player-open` accepts `:playlist` with a list of sources and
`:index` to select the starting one; `etaf-video-player-enqueue` appends a
source while the current item keeps playing, and `etaf-video-player-remove`
drops one item.  `etaf-video-player-next`/`-previous` (also `>` and `<`)
move through the queue, `etaf-video-player-play-index` jumps to an item, and
`L` cycles the loop mode (off, list, one) while `s` toggles shuffle.  The
sidebar lists the queue with the current item highlighted; clicking an entry
plays it.  When an item ends the queue advances per the loop mode and the
last item either wraps (list loop) or stops.

## Image frames

Decoding, scaling and publication belong to the native `etaf-video` Component,
which this application places in a layout with `:mode 'image`; see the ETAF
manual for the full contract.  On a graphical frame ffmpeg emits one JPEG per
frame at the canvas pixel size and the Component publishes it as an image
display shared by one slice per canvas row. Neighbouring text therefore
keeps its normal line height. Publication updates the retained Text inside
the canvas, leaving its geometry and the surrounding controls in place.
Achieved frame rate depends on the machine, canvas and workload; the
presentation cap is not a performance guarantee.  On a terminal the
Component falls back to a density-ramp canvas (`etaf-video-player-state`
reports `:render-mode 'ascii`), so the same command still works over SSH.

Retina screens stay sharp because the producer decodes at the display's device
pixel ratio: the canvas is `columns` by `rows` character cells, and the frames
are produced at `columns * char-width * ratio` by `rows * char-height * ratio`
pixels and drawn back down at `1 / ratio`.  `frame-scale-factor` supplies the
ratio (2 on Retina); set `etaf-video-player-device-pixel-ratio` to 1 to force
logical-pixel frames (softer, cheaper), or to a fixed number for testing.
Changing the variable applies to the next session restart (a resize, mode or
source change).

## Render modes

The player draws its source three ways.  `etaf-video-player-render-mode` picks
the mode for the next player; `:mode` in the source plist overrides it once,
and `C` switches a running player without losing its position, rate or audio
state.

| Mode | Picture | Notes |
| --- | --- | --- |
| `image` | one scaled image per frame | graphical frames only; a terminal falls back to `ascii` |
| `ascii` | one density-ramp character per pixel | readable anywhere; `etaf-video-density-ramp` holds the ramp |
| `color` | two true-color pixels per `▀` half-block cell | one face property per cell, so the fitted width stops at `etaf-video-player-color-columns` |

Color cells cost one face property each and the renderer publishes one
property operation per run, so the color mode caps its fitted canvas (32
columns by default).  Set `etaf-video-player-color-columns` to nil to fit the
whole window, or raise it for a sharper, slower picture.  An explicit
`etaf-video-player-set-grid` is always honored, because the caller asked for
that size.

Character cells are about twice as tall as wide, so the default fitting keeps
the video aspect ratio by sampling `rows * aspect * 2` columns. The built-in
demo is 640x360; a file's real size comes from ffprobe, and the source
defaults are 640x360 when ffprobe is unavailable.

## Sound

An ffplay sidecar plays the source's audio track.  It starts with playback,
restarts at the current position when the volume changes, is released on
pause, and follows `a` and the volume keys:

| Key | Action |
| --- | --- |
| `[` / `]` | lower or raise the volume by 10 |
| `a` | toggle sound |

`etaf-video-player-volume` (default 100) and `etaf-video-player-audio`
(default t) set the initial state for new players; `:volume` and `:audio` in a
source plist override them for one session.  A source that reports no audio
stream stays silent, and so does a missing ffplay. The sound icon and the
details pane report the requested state, not proof of audible output.  ffplay is part of the normal
ffmpeg installation; `etaf-video-ffplay-program` points at another one.

## Resume and screenshots

Local playback positions persist in a small SQLite database built with
`etaf-db` (`~/.emacs.d/etaf-video-player/history.sqlite3` by default;
`etaf-video-player-history-file` repoints it).  The position is written while
playing on a slow cadence and again when the file closes; reopening a file
seeks to the saved second when it is past five seconds and not within ten
seconds of the end, and the echo area reports where playback resumed.  The
database fails open: without SQLite, history is off and playback is
unaffected.  `etaf-video-player-history-record` and
`etaf-video-player-history-position` read and write records directly.

`S` (`etaf-video-player-save-screenshot`) decodes the current frame with
ffmpeg into a PNG beside the video, named `<video>-HHMMSS.png`, and reports
the path in the echo area; a stream writes into the temporary directory.  The
decode runs in the background, so playback is not interrupted.  The built-in
demo has no frame to capture and signals `user-error`.

## Subtitles

A local file loads the first readable track beside it automatically, checking
`movie.srt`, `movie.vtt` and the common Chinese suffixes (`movie.zh.srt`);
`etaf-video-player-subtitle-extensions` lists the probe order.  The cue
covering the playback second renders as one line under the canvas and
repaints through the retained content boundary with the clocks.  `c` hides
the current track, shows it again, or asks for a subtitle file when none is
loaded; `etaf-video-player-subtitle-load` attaches one explicitly.

SubRip and WebVTT files parse; malformed blocks are skipped and inline markup
(`<i>`, font tags, `{\...}` styling) is stripped, so a track with a few bad
cues still plays.  `etaf-video-player-subtitle-parse` returns the cue list
and `etaf-video-player-subtitle-text-at` answers a playback second; a track
that cannot be read signals `etaf-video-player-subtitle-error`.

## Keys

| Key | Action |
| --- | --- |
| `SPC` | play or pause |
| `n` | one frame while paused |
| `f`, `b` | +5 s / -5 s |
| `+`, `-` | next / previous rate |
| `[`, `]` | volume down / up |
| `a` | toggle sound |
| `1` .. `4` | 64, 96, 128, 176 columns |
| `F` | fit to the window |
| `o`, `u`, `d` | open a file / open a URL / demo |
| `>`, `<` | next / previous playlist item |
| `c` | hide, show or load subtitles |
| `S` | save the current frame as a PNG |
| `C` | switch render mode (image, ascii, color) |
| `L`, `s` | loop off/list/one, shuffle |
| `T` | switch dark/light appearance |
| `?`, `C-c h` | searchable help in the player |
| `q` | close the player |

The header's help button opens the same read-only modal, using the current
appearance and effective key bindings. `/` searches; Escape leaves search
editing before closing help. Clicking outside also closes it and restores focus
without changing playback or splitting the window.

`F` and `etaf-video-player-fit` reserve six rows for the header, transport
and footer.  From about 100 character columns the playlist occupies 30
columns; from about 143 the details pane occupies another 28 (the thresholds
compare the published viewport in logical pixels).  The remaining space
determines the aspect-preserving canvas size. The same fitting runs
automatically once a window resize settles and after text scaling, so a
resized frame keeps a canvas that fits; a minibuffer prompt that borrows
lines does not refit it.

## Scripting

`etaf-video-player-open` accepts a file name or a plist, so a whole session
can be built from Lisp:

```elisp
(etaf-video-player-open '(:file "clip.mp4" :columns 100 :rows 28 :volume 60))
(etaf-video-player-seek 12.5)
(etaf-video-player-set-speed 0.5)
(etaf-video-player-set-audio nil)
(etaf-video-player-subtitle-load "clip.srt")
(etaf-video-player-save-screenshot "/tmp/frame.png")
(etaf-video-player-state)
;; => (:source "clip.mp4" :playing t :position 12.5 :duration 300.0 ...)
```

Every control function operates on the current buffer's player and signals
`user-error` elsewhere, so scripts should call them from the player buffer or
from an interactive command bound there. `etaf-video-player-state` returns a
detached plist; the interesting keys are `:playing`, `:position`, `:duration`,
`:render-mode`, `:source-width`, `:source-height`, `:received`, `:presented`,
`:dropped`, `:audio`, `:volume`, `:subtitle-file`, `:subtitle-on` and
`:ended`.

| Variable | Meaning |
| --- | --- |
| `etaf-video-player-audio` | play sound for new players, default t |
| `etaf-video-player-volume` | initial volume for new players, 0 to 100 |
| `etaf-video-player-device-pixel-ratio` | image device pixel ratio; nil derives it from the frame |
| `etaf-video-player-grid-presets` | character to canvas width, used by `1`-`4` |
| `etaf-video-player-display-fps` | presentation cap for new players, default 24 |
| `etaf-video-player-theme-mode` | `dark` (default) or `light`; T switches the running player |
| `etaf-video-player-subtitle-extensions` | file suffixes probed beside a local video |
| `etaf-video-player-history-file` | playback database file; nil uses the Emacs user directory |
| `etaf-video-ffmpeg-program` | ffmpeg name or path; use a wrapper to add decoder options (ETAF) |
| `etaf-video-ffprobe-program` | ffprobe name or path; optional (ETAF) |
| `etaf-video-ffplay-program` | ffplay name or path used for sound (ETAF) |

The native Component passes ffmpeg the documented argument shape
`-hide_banner -loglevel error [-ss START] -readrate SPEED -i INPUT -vf
scale=PIXEL-WIDTH:PIXEL-HEIGHT:flags=lanczos -q:v 3 -f image2pipe -c:v mjpeg -`,
with `-f lavfi -i testsrc2=size=640x360:rate=30 -t 30` for the demo instead of
`-i INPUT`. A wrapper set through `etaf-video-ffmpeg-program` receives these
arguments unchanged. The audio sidecar receives
`-nodisp -autoexit -loglevel error -volume VOLUME [-ss POSITION] TARGET`.

## Troubleshooting

- `ffmpeg is not available`: install ffmpeg or set
  `etaf-video-ffmpeg-program` to its absolute path.
- No sound: install ffplay or set `etaf-video-ffplay-program`; check the
  volume keys and that the source has an audio stream. The sound icon shows
  the requested state; it does not prove that a sidecar is producing sound.
- `Video file is not readable`: the path is wrong or the file is not a local
  readable file; use `etaf-video-player-open-url` for network streams.
- A URL does not play: check the network and, behind a proxy, `ffmpeg`'s
  lowercase `http_proxy` / `https_proxy` environment variables. Non-HTTP(S)
  schemes are rejected before any process starts.
- No total duration in the status line: ffprobe is missing or the container
  does not report one; playback still works.
- The picture looks squashed: the canvas no longer matches the video aspect
  ratio. Press `F` or call `etaf-video-player-fit`.
- The picture is soft on a Retina screen: check
  `etaf-video-player-device-pixel-ratio` (nil means automatic) and remember
  that the change applies on the next session restart.
- The picture lags after resizing or switching monitors: the grid refits
  automatically, and a session restart is part of that change.
