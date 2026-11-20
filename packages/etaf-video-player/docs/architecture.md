# ETAF Video Player architecture

## Responsibilities

`etaf-video-player` is an application. It owns the fitted canvas size, the
audio state and volume, the status line and the keys; the buffer, its canvas
settings and its single close path come from ETAF's application runtime
(`etaf-app-open`). Decoding,
Retina-sharp image frames, the audio sidecar and publication belong to ETAF's
native `etaf-video` Component, which this application places in a View and
drives through its public handle control functions. No framework mechanism is
re-implemented here.

| Module | Owns |
| --- | --- |
| `etaf-video-player-app` | player state (canvas, rate, audio, volume, status), the View assembly, the application opening and closing, the root keys, window fitting and the public commands |
| `etaf-video-player-views` | the shell Components (header, playlist, details, transport, footer) as pure projections |
| `etaf-video-player-theme` | the four-step palette for both appearances and the ETAF UI token projection |
| `etaf-video-player-subtitle` | SubRip/WebVTT parsing and the cue lookup for a playback second |
| `etaf-video-player-history` | the SQLite playback-position store; every operation fails open |

The root entry re-exports the supported subset; everything unlisted is
internal.

## Data flow

1. `etaf-video-player-open` normalizes and probes the source once through
   `etaf-video-source-info`, opens an ETAF application that displays the
   buffer, and mounts a View with the
   native `etaf-video` Component (`:mode 'image`) plus three status text Hosts.
   The shell is a fixed plane of absolute layers: playlist, stage, details,
   header, transport and footer.  Layer panes are what the framework's
   retained routes require; a frame then repaints the canvas plane instead of
   re-composing the surrounding application.
2. After the first publication the application reads the renderer's own
   viewport (`etaf-runtime-viewport`) and the stage Host's committed size
   (`etaf-host-ref-size`), then sizes the canvas to the measured stage and
   positions it there.  The application's fit function schedules the same
   sync after every settled window change and text scaling; it waits for the
   fitting batch to publish, so a resize re-measures the new stage instead of
   re-deriving geometry from window columns.  Lines borrowed by a transient
   minibuffer are not a resize, so ETAF does not call the fit function and the
   committed canvas stays until the prompt closes.
3. The Component owns the playback session: ffmpeg decodes at the device pixel
   size, the session keeps only the newest complete frame, and each displayed
   frame is published through `etaf-runtime-update-host-content` as image
   slices.  The optional ffplay sidecar follows the same play/pause state.
4. The application refreshes the status Hosts from `etaf-video-state` four
   times per second.  The texts live in plain player fields and reach their
   Hosts through one explicit retained content update; a reactive source write
   would re-render the consuming Component and republish the tree.  The
   progress fill stays a controlled range value because the range moves it
   through its own retained geometry binding.  The subtitle line rides the
   same update: the cue covering the current second comes from a binary search
   over the parsed track.
5. Playback positions persist for local files: a throttled write while
   playing, a forced write when the queue switches or the player closes, and
   one `history-position` lookup on open that seeks when the record is past
   the start margin and not near the end.  A broken database leaves playback
   untouched.
6. Controls are declarative or imperative depending on the fact: canvas size
   and rate are View props, volume, sound and speed are shared reactive
   sources the Component reads in its playback effect, and play/pause, step
   and seek call the Component's handle functions.
7. The application's close function restores the frame background it
   adopted, saves the playback position and cancels the status timer while the
   View is still mounted; unmounting then destroys the session and its
   sidecar.  ETAF runs it once however the buffer goes away: `q`,
   `etaf-video-player-close`, killing the buffer or opening another source.
   A failed open closes the application too, so no partial player survives a
   `user-error`.

## Invariants

- **One owner per fact.** The native session owns decoding, position, pacing
  and audio; the application owns canvas size, rate, volume and status text;
  ETAF owns publication. The View never decodes and commands never write
  buffer text directly.
- **Retina is a producer fact.** The session decodes at
  `columns * char-width * ratio` by `rows * char-height * ratio` device pixels
  and the image is drawn at `1 / ratio`, so the window system never upscales
  the picture.  `etaf-video-player-device-pixel-ratio` overrides the frame's
  `frame-scale-factor`, and the change applies on the next session restart.
- **Canvas geometry is measured.**  The canvas size comes from the stage
  Host's committed border-box size (`etaf-host-ref-size`) and the source
  aspect ratio; the pane lanes and responsive breakpoints come from the
  published viewport (`etaf-runtime-viewport`).  The application never
  estimates layout from window character columns.
- **The window edges belong to the application.**  Emacs reserves the last
  character cell of every line and any partial bottom line, and buffer text
  cannot paint those pixels.  While a player owns the frame, the application
  adopts the frame background color (saving and restoring the previous value)
  and every layout lane's outermost surface uses that same color, so the
  reserved pixels read as the application surface instead of the user's frame
  background.  The application canvas background follows the shell chrome
  color of the current appearance for sub-cell remainders inside the layout.
- **Probe once.** `etaf-video-source-info` returns authoritative metadata that
  the Component accepts as its source, so resizing or restarting a video does
  not repeat the ffprobe call.
- **Latest frame wins.** The session retains at most one complete frame; a slow
  display drops frames and the clock advances from delivered frames, so
  playback never replays a backlog.
- **Pause does not catch up.** Pausing releases the producer and the audio
  sidecar and remembers the position; resuming spawns a producer with `-ss
  POSITION` instead of continuing a wall-clock-paced one, so a long pause never
  produces a fast-forward burst.
- **Cleanup is unconditional.** Every open failure, close and buffer kill
  cancels the status timer and unmounts the Runtime, destroying the session,
  the producer and the audio sidecar with it.

## Measured behavior

Frame cost is the native Component's cost plus the retained publication of the
canvas plane.  The maintained measurements are the workspace performance
scenarios `video-player.frame`, `video-player.volume` and `video-player.mute`
(`benchmarks/performance-scenarios.el`), run with `--mode gui` on a real clip
through `TAF_VIDEO_SOURCE`; they record warmups, the slowest sample and the
focus conditions, so no number here substitutes for a fresh run.  A frame is
one retained content update of the canvas Host: it repaints the canvas plane
and does not re-compose the surrounding panes.  The status Hosts are refreshed
four times per second through the same retained content boundary, and the
progress fill moves through the range's retained geometry.

Two framework conditions decide whether those retained routes are available,
and both are observable per publication:

- `ebox-update-prepare-report` must report `ready` for the canvas content
  update.  It reports `unsupported` when the canvas placement is not an inline
  winner, which is why the Component declares `:position`/`:left`/`:top` on
  its own canvas node and why the application places the canvas as one
  root-level absolute plane using the measured stage.
- `ebox-buffer-update-report` should keep a panel update scoped.  A publication
  that falls back to an owner re-render reconciles the whole tree; the HUD
  texts therefore use explicit retained content updates instead of reactive
  source writes.

Machine load changes the absolute frame rate, so compare runs with the same
load and record the load with the evidence.  The presentation cap
(`etaf-video-player-display-fps`, 24 by default) is a pacing limit, not a
promise: the achieved rate is reported in the player state and drops when
presentation cannot keep up.
