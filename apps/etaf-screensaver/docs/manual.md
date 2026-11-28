# etaf-screensaver manual

This manual explains idle presentation, Lisp playback configuration and scene
authoring. The supported API inventory lives in `etaf-screensaver.el`.

## Automatic presentation and waking

```elisp
(require 'etaf-screensaver)
(setq etaf-screensaver-idle-delay 300)
(etaf-screensaver-mode 1)
```

After the idle interval, the selected Emacs frame shows only animation.
Automatic activation waits while the minibuffer is active or the frame is
hidden or unfocused. It never raises a frame or starts a child process.
`etaf-screensaver-start` starts the same presentation manually; an optional
program argument overrides configuration for that presentation only.

A key, mouse movement, completed click or wheel event restores the saved
windows and buffer positions. The wake event is consumed, not replayed into
an editor or another application's controls. A click dismisses on release;
its button-down event is consumed first. Stopping removes the animation timer,
transient input map, wake hooks, mouse-tracking change, Runtime and ephemeral
buffer. Repeated start does not overwrite the original window snapshot, and
repeated stop is harmless. Killing the presentation buffer also cleans up.
This is not a security lock and does not protect unattended sensitive data.

Automatic mode retains one idle watcher and a post-command rearming hook.
After dismissal it waits a fresh interval, including a mouse-only wake that
did not reset Emacs's native idle clock. `(etaf-screensaver-mode -1)` dismisses
any active presentation and releases the watcher and hook too. Re-enabling
replaces the watcher rather than accumulating timers; do this after changing
`etaf-screensaver-idle-delay` if the new delay should take effect immediately.

## Composing playback

For most configurations, the program is a flat list of names. A scene name
plays that work; a pack name expands that pack in place. The list order is
kept. A lone name is also accepted.

```elisp
;; A pack and one extra work, in order.
(setq etaf-screensaver-program '(poems matrix))

;; One pack.
(setq etaf-screensaver-program 'poems)

;; One work; a repeated page keeps it running.
(setq etaf-screensaver-program 'donut)

;; Per-work layout: poems use card, matrix uses full.
(setq etaf-screensaver-program '(poems matrix)
      etaf-screensaver-presentation 'card
      etaf-screensaver-scene-options '((matrix :presentation full)))
```

An advanced program is a scene symbol, a configured scene item, a named pack
item, or a group containing more programs. The root repeats after each finite
round. A start without an explicit program restarts the work/page interrupted
by the previous dismissal, then continues its queue and program random state.
It does not seek to the interrupted frame inside a recording. Effective scene
settings, pack contents, registrations or seed changes discard that position.
Explicit program arguments preview a fresh round without replacing the saved
position.

```elisp
;; A shuffled group.
(setq etaf-screensaver-program
      '(:order shuffle :scenes (matrix snow donut plasma)))

;; Choose groups randomly, but play the first group's sequence in order.
(setq etaf-screensaver-program
      '(:order random :count 2
        :scenes ((:order sequential :scenes (matrix snow))
                 (:order shuffle :scenes (snow plasma donut)))))
```

Groups take `:order` (default: `sequential`), a nonempty `:scenes` list and an
optional positive `:count` (default: child count). Sequential order wraps
through children; shuffle draws without replacement within each bag and
creates another bag if count exceeds child count; random samples with
replacement. Thus random can repeat a scene or group, whereas shuffle covers
every child in a bag. Nested groups remain contiguous; the parent chooses a
whole child program, not individual scenes flattened out of it.

Scene items specify `:scene`, optional positive `:duration` seconds,
`:frame-rate` and a `:params` alist. Per-scene settings can be shared:

```elisp
(setq etaf-screensaver-scene-duration 30
      etaf-screensaver-max-frame-rate 30
      etaf-screensaver-scene-options
      '((matrix :duration 20 :params ((speed . 4)))
        (equalizer :presentation full)
        (donut :params ((speed . 6) (detail . normal)))))
(setq etaf-screensaver-program
      '(:order sequential
        :scenes ((:scene matrix :duration 10 :params ((speed . 7)))
                 donut)))
```

Item values override per-scene defaults, which override the scene's parameters
and frame rate or the global default duration. The one exception is
`:presentation`: a per-scene setting wins over an item or pack style, so one
work can be full while the rest are cards. Parameter alists merge by key;
symbol and keyword forms address the same parameter. The global frame-rate cap
always applies. It is a ceiling, not a promise of physical refresh frequency.
A duration must be at most one day, frame rates at most 120, group child/count
values at most 1000, nesting at most 16 and an expanded round at most 10000
nodes. These bounds keep erroneous configurations from blocking the editor.

A page that repeats the same work continues that work instead of recreating
its scene. Particle fields, scrolling text and recorded works keep their
current positions, so a single-work program loops without a reset seam and
without re-reading or re-decoding its recording. At the page boundary the
running work advances up to that instant, rather than publishing its previous
frame once more, so a continuous field does not lose a frame at every loop.
Only a different page starts a fresh scene state.

`etaf-screensaver-seed` is nil by default, giving each presentation a new seed.
An integer reproduces the program choices and initial scene states. Later
frames depend on elapsed time and viewport dimensions as well. Configuration
is validated and snapshotted at start; edit it outside the screen, then stop
and start to apply it. `etaf-screensaver-status` reports the active item,
effective parameters and remaining scenes without showing an on-screen HUD.

Invalid configuration fails before window takeover. A callback or rendering
failure tears down the presentation, reports its cause and disables automatic
mode to prevent repeated idle errors. Correct the configuration or scene,
then enable the mode again.

### Between works

Different pages use a 1.2-second, eased top-to-bottom reveal instead of a
whole-canvas hard cut. The outgoing page keeps its original colors; the
incoming work continues moving. This reuses native image slices and text,
not browser rendering or per-frame image encoding.

```elisp
(setq etaf-screensaver-transition-duration 1.2) ; 0 disables; maximum 5 seconds
```

The reveal does not change content, layout, order or dwell time. It occupies
at most half of the incoming page's duration. An identical repeated page has
no transition; resizing finishes a reveal immediately. Status reports
`:transition-progress` while revealing. Wake input remains active throughout.
This is a spatial reveal, not an alpha crossfade. A reel's baked loop blend
is a separate operation. Neither removes flashing already present in a work;
avoid very short programs alternating light and dark pages.

## Style packs and playback strategies

A style pack is a named list of scenes that share one visual language, with
defaults applied to every scene in it:

```elisp
;; Bundled: neon, space, poems (light), ember.  Add your own any time.
(add-to-list 'etaf-screensaver-packs
             '(flow :title "Flow" :background "#000000"
                    :scenes (frames-royal)))
```

A pack entry takes :title, :order, :background, :duration, :frame-rate,
:presentation, :params and :scenes.  Background gives a pack its paper: the
light `poems` pack paints cream behind dark-ink recordings.

A pack name can also appear directly in the flat program list.  The
`(:pack NAME)` item remains available when a pack needs overrides:

```elisp
;; One pack from end to end.
(setq etaf-screensaver-program '(:pack poems))

;; Rotate whole packs; each pack finishes before the next starts.
(setq etaf-screensaver-program
      '(:order sequential :scenes ((:pack neon) (:pack space) (:pack poems))))

;; Hold one style for six works, then move on.
(setq etaf-screensaver-program
      '(:order sequential :scenes ((:pack neon :count 6) (:pack poems :count 4))))

;; A single work on loop; the root repeats whatever it is given.
(setq etaf-screensaver-program '(:scene tte-ink-river))

;; Two packs in a shuffled bag, then the ember pack.
(setq etaf-screensaver-program
      '(:order shuffle :scenes ((:pack neon) (:pack ember))))
```

Pack items accept :order, :count, :duration, :frame-rate, :background,
:presentation and :params overrides. The default program selects every work
in each of its packs, not a permanently truncated prefix. An explicitly
smaller sequential :count selects only that many children per visit; omit it
to cover the full pack, or use shuffle to sample a different subset.  A recorded work registers its recorded length as its
natural :duration, so `(:pack poems)` plays each recording once instead of
cutting it mid-loop; set `:duration` explicitly to loop a work instead.

## Presentation independently of content

Keep the program and choose its presentation separately:

```elisp
(setq etaf-screensaver-program '(:pack poems)
      etaf-screensaver-presentation 'card)
```

| Style | Presentation |
| --- | --- |
| `full` | The work occupies the whole canvas, with no caption. |
| `card` | A thin frame inset by an even mat of about three line heights on every side, with its title and summary in ordinary text at the lower left. The horizontal mat is measured from the frame's cell metrics so the four distances match on screen. |
| `band` | A wide cinema strip, a clock row and a caption. The clock never overwrites the work. |
| `mosaic` | Up to four independent works on one page, each with its own state, seed, background and caption. Narrow windows stack them vertically. |

For `card`, an ordinary frame gets three line heights of mat on every side.
The echo row below the window is painted with the work's background and
counted in the bottom mat, so the four visual distances stay equal. Compact
windows shrink the mat before the work drops below four content rows.

The default `etaf-screensaver-presentation` is nil: each pack supplies its
suggestion, and standalone works use full. A non-nil global value overrides
pack suggestions. An explicit `:presentation` on a group or item has priority;
children inherit a group's style unless they specify their own.

```elisp
;; Four chosen works concurrently; the next page has only the fifth work.
(setq etaf-screensaver-program
      '(:presentation mosaic
        :scenes (tte-beams tte-synthgrid tte-bubbles tte-blackhole)))

;; Keep two packs separate, with independently chosen presentation/order.
(setq etaf-screensaver-program
      '(:order shuffle
        :scenes ((:pack neon :presentation mosaic :order shuffle)
                 (:pack poems :presentation card :order sequential))))
```

Consecutive mosaic selections form pages of at most four works without
crossing pack boundaries. A partial page never repeats a work to fill empty
slots. Explicit repetitions in a program, or random sampling with replacement,
can still select the same work more than once. The page stays for its longest
work's duration; shorter recordings loop at native speed. Raw recordings can
have an end-to-start seam; the image baker's `--loop` option crossfades that
seam offline. `:count` counts selected works before
pagination, while status `:index` counts pages. `:works` and `:up-next-works`
report the actual concurrent selections.

A drawable canvas of **64 columns by 24 rows** is the minimum recommended
viewport for the four presentations. Short windows retain their borders and
captions with less artwork. Below the minimum, fixed framing geometry is
clipped deliberately; glyphs are not squeezed. Recorded text adapts its subject
size as described below; image recordings retain native pixel dimensions when
possible and only scale down, preserving aspect ratio, to fit their allocated tile.
Resizing preserves reel position and passes the new content rectangle to each
work's resize callback, without changing page order.

### Recorded text size

Graphical Emacs with SVG support enlarges a text recording's subject without
stretching pixels or changing the border/caption font. The subject is the
nonblank cell rectangle of the last visible frame; a blank closing frame is
ignored, so a loop that fades to paper still enlarges the settled line. Its
current animated characters are drawn larger at the center; surrounding
beams, rain and other effects keep playing at their native cell size. The recording's timing stays intact, and the
enlarged subject keeps one ink colour chosen to contrast with the work
background. For a single work, the automatic scale fills up to 95% of the work
width and 70% of its height. Concurrent works keep their native overview
instead of competing magnified subjects; an explicit integer scale still
applies to every work. A recording with no visible frame keeps native text.

```elisp
(setq etaf-screensaver-reel-text-scale 'auto) ; default, adapts on resize
;; Or choose a fixed integer 1–24; 1 preserves native text.
```

Small windows bound a fixed scale too. Terminals and graphical builds without
SVG use native text without losing content. This setting never enlarges image
recordings and is snapshotted at start, including later pages. Stop and restart
to apply a change. Values other than `auto` or integers 1–24 fail before window
takeover. For recordings whose last visible frame is not a meaningful
subject, use 1.

## Concepts

A **scene** is a pure generative program registered under an identifier. It
builds a state, advances it by one frame and projects it into canvas rows. The
presentation owns the clock and composed publication; each simultaneous work
has independent scene state, seed and parameter values. It creates no extra frame and changes no user buffer contents.

A **spec** is inert data describing a scene: a title, parameters and a stack of
**layers**. Each layer names a registered **kind** and its properties. The DSL
interprets the spec into ordinary scene callbacks, so adding a screensaver
means adding a data file.

A **frame** is a list of row strings, each exactly as wide as the canvas (or a
single newline-separated string). Rows may carry `face` properties for color;
adjacent cells with the same color become one text-property run, so quantized
color is cheap and per-cell rainbow noise is not.

## Scene spec

A spec is a plist; a `.esc` file wraps it in `(etaf-scene ...)`. Keys:

| Key | Required | Meaning |
| --- | --- | --- |
| `:id` | yes | symbol registered as the scene identifier |
| `:title` | no | display name (defaults to the identifier's name) |
| `:summary` | no | one-line description |
| `:tags` | no | list of symbols for grouping |
| `:frame-rate` | no | preferred frames per second (default 15) |
| `:background` | no | canvas color; defaults to `etaf-screensaver-background` |
| `:params` | no | parameter descriptors (see below) |
| `:layers` | yes | nonempty list of layers, drawn back to front |

Registering the same `:id` again replaces the previous scene in place, which
is what makes reloading a file update the mounted scene.

### Parameters

Each descriptor is a plist:

| Key | Applies to | Meaning |
| --- | --- | --- |
| `:key` | all | symbol used in expressions and the configured `:params` alist |
| `:label` | all | nonempty display label |
| `:type` | all | `number`, `choice` or `toggle` |
| `:default` | all | initial value, valid for the type |
| `:min`, `:max` | number | inclusive integer bounds |
| `:step` | number | positive integer alignment (default 1) |
| `:options` | choice | alist of unique keys to nonempty labels |

Parameters are configured through `etaf-screensaver-scene-options` or program
items, never through an in-screen control. A parameter is addressed by its key
symbol in expressions; Lisp configuration may use the equivalent keyword
(`:speed` or `speed`).

### Context

Every callback receives a plist:

| Key | Value |
| --- | --- |
| `:columns`, `:rows` | canvas size in cells |
| `:seed` | the session's seed |
| `:tick` | completed steps before this one |
| `:elapsed` | seconds before this step |
| `:dt` | seconds since the previous step (0 for a single step) |
| `:params` | list of parameter keys |
| `:param` | key to value function |
| `:random` | no argument returns a float in [0,1); a positive limit returns an integer below it |

## Expression language

Layer properties may be literals, parameter symbols, or expressions. An
expression is a number, a string, `t`, `nil`, a variable or a list whose head
is one of the forms below. The evaluator never calls `eval`; unknown
variables, functions and forms signal `etaf-screensaver-error`.

### Variables

- the scene parameters (`speed`, `density`, ...);
- a particle's or field cell's own fields (`x`, `y`, `vx`, ...);
- the globals `w`, `h` (canvas size), `cx`, `cy` (center), `t` (seconds),
  `dt` (step seconds), `tick` (steps), `i` (particle index), `pi` and `e`.

A field binding shadows a parameter of the same name, and a parameter shadows
a global.

### Forms

`(if TEST THEN [ELSE])`, `(and ...)`, `(or ...)`, `(not X)`.

### Functions

| Group | Functions |
| --- | --- |
| arithmetic | `+`, `-`, `*`, `/`, `mod`/`%` |
| comparison | `<`, `<=`, `>`, `>=`, `=`, `/=` |
| rounding | `floor`, `ceiling`, `round`, `abs`, `sign`, `float` |
| selection | `min`, `max`, `clamp` |
| power and roots | `pow`, `sqrt` |
| trigonometry | `sin`, `cos`, `tan` |
| random | `(rnd)` in [0,1), `(rnd LIMIT)` in [0,LIMIT), `(rndi LIMIT)` integer |

Comparisons are variadic: `(< a b c)` is true when the sequence increases.
Random expressions use the session's seeded generator during creation, steps,
rendering and resize. Starting with the same seed replays the same sequence
when the viewport, parameters and elapsed-time steps are unchanged.

## Layers

The bundled works use `rain`, `sand`, `particles` and `field`.  `text` stays
available for custom specs.

### `rain`

One driven drop per column with a visible tail.

| Property | Meaning |
| --- | --- |
| `:glyphs` | string of characters a drop may show (default `01`) |
| `:head` | the leading character (default `▓`) |
| `:tail` | rows a tail spans (default 8) |
| `:speed` | fall speed (default 8) |
| `:direction` | `down` (default) or `up` |
| `:color` | whole-layer color |

### `sand`

Falling materials with declarative movement and optional continuous emission.
Mouse input dismisses the screensaver; there is no painting mode.

| Property | Meaning |
| --- | --- |
| `:materials` | nonempty list of material plists (see below) |
| `:rain` | grains emitted at the top per step (default 0) |
| `:rain-material` | material key the rain uses (default the first one) |

A material plist holds `:key`, `:char`, optional `:color`, `:moves` (an
ordered list of `down`, `down-left`, `down-right`, `left`, `right`, `up`,
`up-left`, `up-right`) and optional `:flows-through`, a list of material keys
that may enter this material. Opposite moves are tried in random order, so a
pile spreads naturally. An empty `:moves` list makes a material static (a
wall).

### `particles`

Numeric particles driven by expressions.

| Property | Meaning |
| --- | --- |
| `:count` | particle count (default 50) |
| `:init` | alist of field to expression, evaluated at creation |
| `:update` | alist of field to expression, applied every step |
| `:wrap` | list of `(:field LOW HIGH)`: values under LOW jump to HIGH and over HIGH jump to LOW |
| `:recycle` | `(:when EXPR :fields ALIST)`: when EXPR is true, reinitialize the listed fields |
| `:draw` | plist with `:x`, `:y`, `:char` and `:color` expressions |
| `:color` | fallback color for a particle without a `:color` expression |

Fields default to `x`, `y`, and particles are drawn at rounded coordinates.
Out-of-canvas draws are clipped by the canvas, so effects may start off screen.

### `field`

One expression per cell: a stateless color or character field.

| Property | Meaning |
| --- | --- |
| `:value` | expression evaluated with `x` and `y` in cell coordinates |
| `:range` | `(LOW HIGH)` value range used for normalization (default 0 to 1) |
| `:ramp` | character ramp, indexed by the normalized value |
| `:palette` | optional list of colors, indexed by the normalized value |
| `:block` | `(WIDTH HEIGHT)` cells per evaluation (default 1 by 1) |

The palette is quantized: adjacent cells that land on the same entry merge
into one run, which keeps a smooth field cheap to publish.

### `text`

| Property | Meaning |
| --- | --- |
| `:lines` | a string or a list of strings |
| `:speed` | lines per second when scrolling (default 1) |
| `:scroll` | whether the block scrolls upwards (default true) |
| `:align` | `left`, `center` (default) or `right` |
| `:color` | text color |

Empty strings keep paragraph gaps. Wide characters are placed with their own
display width, so CJK text stays aligned.

## Scene files

`etaf-screensaver-scene-directories` lists the scanned directories in order.
Each `*.esc` file holds exactly one `(etaf-scene ...)` form and each `*.esr`
file one `(etaf-reel ...)` form. Bundled scenes live in `lisp/scenes` and
bundled reels in `lisp/reels`; the default user directory is
`~/.emacs.d/etaf-screensaver/scenes`. A later directory replaces a scene whose
`:id` matches, so a user file overrides a bundled scene.

- `etaf-screensaver-load-scenes` loads every configured directory and returns
  how many files loaded; a file that fails to read or validate reports and is
  skipped while the rest still load.
- Call the loader outside presentation after editing files, then start a new
  presentation to use the updated registrations.
- `etaf-screensaver-register-scene` registers a spec programmatically, and
  `etaf-screensaver-register-reel` registers a recorded animation directly.

## Recorded animations

A *reel* plays a recording that an external animation tool produced, without
running that tool or transcribing its algorithms. The native recording stays
in its own format; a small `.esr` spec names the provider, dimensions, frame
count and license. Playback follows the recording's own per-frame timing. Text uses the subject sizing described
above, with native center-fitting for the surrounding animation; image frames
center without enlargement. A scene duration longer than the recording loops it.

Many recorded effects are entrance animations: the text resolves and the
frames then hold. Choose a recording that keeps changing — the bundled
`tte-beams`, `tte-synthgrid` and `tte-blackhole` all do — or shorten its
item duration so the still hold does not dominate. Importing validates format
and safety; it does not judge whether the animation stays in motion.

Terminal Text Effects (TTE) recordings (`*.tterec`) are supported out of the
box. Record one with the tool, then import it:

```sh
echo "Hello" | tte --record animation.tterec --seed 7 --canvas-width 80 \
  --canvas-height 24 --anchor-text c --anchor-canvas c matrix
```

```elisp
(etaf-screensaver-import-recording "/path/animation.tterec")
(etaf-screensaver-load-scenes)
(etaf-screensaver-start 'tte-animation)
```

`etaf-screensaver-import-recording` validates the recording, copies it beside
a new `.esr` spec in the user scene directory and returns a report plist. It
signals `etaf-screensaver-error` for an unrecognized format or an invalid
recording and writes nothing. Importing never transcodes frames: replacing
the recording file re-reads it at the next start.

For several files:

```elisp
(etaf-screensaver-import-directory "~/recordings")
```

The batch report holds `:imported`, `:skipped` and `:failed` lists. Every
imported entry names the provider, output spec, canvas, frame rate, frame
count, color depths and license, so incompatible files are visible before
playback instead of silently accepted. Only extensions registered by a
provider are scanned; a recognized file whose content fails validation is
reported as failed. Files other providers own are ignored, not claimed.

An `.esr` file is ordinary Lisp data and may be written by hand:

```elisp
(etaf-reel :id tte-matrix :provider tte :recording "matrix.tterec"
           :title "Terminal Text Effects: matrix"
           :width 80 :height 24 :frame-rate 20 :frame-count 306
           :source "matrix" :license "MIT")
```

A relative `:recording` resolves against the directory of the `.esr` file.
Recordings usually start with a blank lead-in and end with the resolved text
sitting still; run `scripts/trim-recording.py animation.tterec
--skip-blank-lead` to drop that dead lead, and pass `--hold` to keep only a
short still tail (`--keep-tail` preserves an authored hold).  The tool reads
and writes TTEREC version 1 directly, so it needs no Terminal Text Effects
installation; import the trimmed file next.  A trimmed work loops its motion
instead of freezing, and a reel that knows its frame count registers that
length as its natural duration so a program plays it once before moving on.
`scripts/loop-recording.py animation.tterec --fade 0.35` wraps a recording in
a blank and colour fade at each end, so its last frame meets its first; use it
when a recording begins and ends at full strength.  It writes a separate
`.loop.tterec` file and refuses to overwrite its input.
A paper page can use a recording already painted in one ink colour, such as
the poem reels below; the screen does not recolor imported text.

`lisp/reels` ships nineteen reels grouped by the bundled neon, space, poems
and ember packs.  Five are Terminal Text Effects imports; fourteen are poem
reels baked by `scripts/bake-poems.py` from `scripts/poems.json`.  Each poem
line is typed at the foot of the page, lifted to the centre, held long enough
to read, then faded into the paper.  A blank frame opens and closes every poem
recording, so the last frame equals the first and a single poem loops without
a still hold or a hard cut.  The light `poems` pack reads as a page rather
than a color show. These are short typographic effects; the optional moving
gallery below supplies sustained canvas artwork. The MIT license covers the
TTE tool and these bundled recordings' generation; verify the rights of your
own input text before publishing a recording.

Add a line to `scripts/poems.json` and run `python3 scripts/bake-poems.py
--force` to rebuild the poem reels and their `.esr` specs.  Each entry holds an
id, title, source summary, display line and recording name.  The baker writes
TTEREC version 1 directly; it does not need Terminal Text Effects.  Its
`--hold` and `--fade` control how long the line stays readable and how long it
takes to dissolve into the page.

A provider for another tool registers a reader:

```elisp
(etaf-screensaver-define-reel-provider 'my-tool
  :title "My Animation Tool"
  :license "MIT"
  :extensions '("myanim")
  :match (lambda (file) (string-suffix-p ".myanim" file))
  :read (lambda (file)
          (list :width 80 :height 24 :frame-rate 30
                :ansi t                 ; frame text may carry SGR runs
                :frames (my-tool-read-frames file))))
```

`:read` must return `:width` and `:height` in cells, `:frame-rate` and a
nonempty `:frames` vector of frame strings whose rows have exactly that
width; optional `:durations` gives seconds per frame, `:ansi` marks SGR runs
and `:source` names the work. Providers are trusted code and run in the
presentation's thread. Custom providers are read when their scene starts;
recent unchanged reads are cached. Registration itself holds only metadata.
The built-in image reader can validate the next queued page in small chunks
while the current page plays, without creating another timer or decoding
images early. Remaining validation completes at selection. A broken next
page does not interrupt the current work early: it reports and stops when
selected. Stopping discards unfinished reads; changing a manifest's size or
modification time invalidates prepared metadata. Import always validates
again, including assets changed without a manifest edit.

### Baking image recordings

A reel does not have to be text. The built-in `frames` provider reads a
baked bundle — a JSON manifest plus still frames — and plays it as images.
Use it for renderers Emacs cannot run: MilkDrop (butterchurn), shader
previews or p5.js sketches. Baking happens offline; playback only decodes
images. Import and header validation do not require graphical support.
Headless buffers retain image descriptors for composition checks, but visible
image playback requires a graphical Emacs with the corresponding decoders.
An image provider can return `:image-types`, one format symbol per file,
to reuse its validated header results; otherwise formats are detected lazily.

`scripts/bake-canvas-frames.mjs` produces a bundle. For Butterchurn presets
it needs `npm install butterchurn butterchurn-presets` somewhere (pass
`--modules`) and a Chrome with remote debugging on `--cdp-port` (default
9222); it opens and closes its own tab and never touches other tabs:

```sh
node scripts/bake-canvas-frames.mjs --list-presets
node scripts/bake-canvas-frames.mjs \
  --preset "$$$ Royal - Mashup (197)" \
  --seconds 8 --fps 15 --width 960 --height 540 --warmup 6 \
  --out /tmp/royal --format jpeg --quality 0.75 \
  --modules /path/to/node_modules \
  --source "MilkDrop preset via butterchurn" --license "butterchurn-presets MIT"
```

Preset and Vanta effect baking use a seeded random stream and virtual time,
including every warmup frame. They run as fast as the renderer can produce
frames; browser/GPU changes need not be bit-identical. `--packs` selects the
upstream Butterchurn packs (base, extra and extra2 by default). `--effect`
selects an upstream Vanta renderer; `--effect-options` accepts its numeric,
boolean and hex-color options as a JSON file. `--url URL [--canvas SELECTOR]`
captures a page in real time instead; arbitrary pages are not deterministic.
The canvas's actual dimensions and encoded MIME must match the requested
bundle. Import the result like any recording:

```elisp
(etaf-screensaver-import-recording "/tmp/royal/royal.frames.json")
(etaf-screensaver-load-scenes)
(etaf-screensaver-start 'frames-royal)
```

The import copies the whole bundle into one directory named after the reel,
so the `.esr` spec and its frames stay together. Frames are still images and
a bundle is much larger than a text recording; keep the canvas and frame
count modest (for example 960×540 at 12–15 fps for 10 seconds), choose
`--format jpeg` or `webp`, and keep baked bundles out of version control.
Each frame is centered without enlargement. Smaller canvases scale it down
uniformly; a larger window restores its native dimensions, never stretching it.
The final partial character row retains its pixels without leaving a seam.
The engine releases the previous frame from Emacs's image cache as the next one
is published.

The baker never overwrites an existing output. It builds in a sibling staging
directory, then renames on success. An error, interrupted socket, signal or
expired deadline closes only its own tab and removes staging. `--timeout`
bounds the whole operation; `--request-timeout` bounds each browser request.
Frames and canvas pixels are bounded, and `--max-bytes` limits encoded output.
Run `help` for exact defaults and limits. A failed collection build reports
failed work ids and retains completed independent bundles, but writes no
`gallery.el` success configuration.

A `frames` manifest is at most 1 MiB. Its declared dimensions are 1–2048 pixels
per axis and at most 2,073,600 pixels, its rate is 1–120 fps, and it lists
1–7200 frame basenames. Absolute paths, directory traversal and symlinks
escaping the bundle are rejected. Each encoded image is at most 16 MiB and
the total is at most 1 GiB. Validation precedes import writes. These are
resource bounds, not a sandbox for an image decoder: only import trusted art.

### Curated moving gallery

`scripts/gallery.json` is a rebuildable collection recipe, not downloaded
images: four works in one pack.  Three are light compositions (paper birds, a
blueprint network and a kinetic point field); the fourth is a dark orbital
sculpture.  Titles, source authors, pack membership, Vanta settings and baking
defaults live in that recipe.  Each generated scene owns its paper color, taken
from the renderer's explicit background or the pack's fallback.  This keeps a
standalone preview and pack playback on the same paper.

The four works use Vanta through Three.js.  Install those pinned renderers
outside the checkout, start Chrome with a local CDP endpoint, then build into
persistent user storage:

```sh
npm install --prefix "$HOME/.cache/etaf-screensaver-renderers" \
  vanta@0.5.24 three@0.134.0
node scripts/bake-gallery.mjs \
  --modules "$HOME/.cache/etaf-screensaver-renderers/node_modules" \
  --out "$HOME/.emacs.d/etaf-screensaver/scenes/gallery"
```

`--list` shows the works; `--only ID,ID` builds a subset.  Smaller `--width`,
`--height` and `--seconds` overrides make review copies in a separate output
directory.  Upstream attribution travels inside each manifest.  Renderers are
build-time dependencies only; neither Node, Chrome nor an external decoder is
used while the screen plays.

```elisp
(load (locate-user-emacs-file "etaf-screensaver/scenes/gallery/gallery.el"))
(setq etaf-screensaver-program 'gallery-kept)
;; Optional independent override; nil keeps the pack's suggested layout.
(setq etaf-screensaver-presentation nil)
```

Loading `gallery.el` adds its scene directory and the `gallery-kept` pack and
loads its `.esr` specs.  It does not enable idle mode or replace the user's
program.  Use `etaf-screensaver-start` for a preview or enable automatic mode
separately.  To remove the collection, remove the load form and its program
references before deleting the generated directory.  It is reproducible user
content, not part of the source checkout.

The default bake records 26 seconds at 15 fps and crossfades its last two
seconds into its first two. It omits those leading two seconds, producing a
24-second moving loop whose last and first frames are neighboring motion.
This smooths a reel's own loop. The playback reveal described above handles
changes between different works separately. Baked
files still require visual review for motion, exposure, flash and the seam;
a completed bake is not a quality certification.

## Code scenes

A scene that outgrows the DSL registers ordinary callbacks with
`etaf-screensaver-define-scene`:

```elisp
(etaf-screensaver-define-scene my-scene
  :title "Custom"
  :summary "Shows a counter"
  :params '((:key step :label "Step" :type number :min 1 :max 5 :step 1 :default 1))
  :create (lambda (context) (list :count 0))
  :step (lambda (state context)
          (setf (plist-get state :count)
                (+ (plist-get state :count)
                   (funcall (plist-get context :param) :step))))
  :render (lambda (state context)
            (list (format "count=%d" (plist-get state :count)))))
```

The callbacks are `:create`, `:step`, `:render` and optional `:resize`, which
returns state fitting a resized canvas. They must be pure apart from their
own scene state: no I/O, processes, timers, buffers or editor changes. All
input belongs to the screensaver lifecycle and dismisses it. Use data specs
for ordinary scenes; callbacks are the escape hatch for algorithms the spec
language cannot express.

## Performance notes

The optional `etaf-screensaver.gallery.*` performance scenarios require the
full-size installed gallery (or `ETAF_SCREENSAVER_GALLERY` pointing to its
directory). They measure real 360-frame bundles, concurrent works and page
boundaries, not the two-frame repository fixture. GUI boundary/reveal runs
keep the natural 24-second dwell; pass `--timeout 40` for preparation. Short
stress cycles run only in batch mode, never as visible light/dark flashing.
`make gui-transition SERVER=...` captures one normal-length day-to-night
change and wake, then stops; inspect those captures separately from timing.

- While a presentation is active, the package caps `gc-cons-threshold` at
  32 MiB and restores the previous value on stop.  A large global threshold
  would otherwise collect once every many seconds and freeze a continuous
  scene for about half a second; the cap spreads that work into short pauses.
  It is a playback-local policy, not a new global GC setting.
- Quantize palettes and merge adjacent color runs; arbitrary per-cell colors
  cost more to publish than coherent runs.
- Recorded reels convert SGR runs once per frame and slice cached cells on
  resize, and recent unchanged recordings are decompressed once per session.
- Use `:frame-rate` and the global cap to bound refresh work. Playback stops
  and cleans up if its buffer/window disappears; no hidden animation probe
  remains running.
- Keep particle counts and field resolutions modest; `:block` in a field or a
  coarse ramp trades detail for computation time.
- Frame content uses ETAF's retained Host boundary. Scene switches and resize
  change the view; ordinary frames update only the canvas content.
- The maintained performance scenarios time the next autonomous frame, including
  its timer wait and publication. Background measurements do not certify
  physical input latency or foreground automatic activation.
