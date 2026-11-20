# Changelog

## Unreleased

### Changed

- A playback program can now be a flat list of scene and pack names, such as
  `(poems matrix)`; a lone name plays one scene or one pack.  The advanced
  group and item forms remain available.  `etaf-screensaver-scene-options`
  accepts `:presentation`, so one work can use a different layout from the
  rest without an explicit item.
- A page that repeats the same work continues that work instead of recreating
  its scene. Particle fields, scrolling text and recorded works keep running,
  so a single-work program loops without a reset seam or a read/decoder stall.
  At the repeated page boundary the running scene now advances up to that
  instant instead of publishing its previous frame again, so the loop no
  longer loses one frame of motion.
- The bundled recordings drop their blank lead-in frames and their still
  tails, and the five Terminal Text Effects imports gain a short fade at each
  end so a loop starts and restarts with motion instead of pausing or cutting
  on an empty or settled canvas.  `scripts/trim-recording.py` reads and writes
  TTEREC directly and can trim a lead with `--skip-blank-lead`;
  `scripts/loop-recording.py` closes a recording with a fade.
- `scripts/plain-recording.py` is removed.  It depended on a Terminal Text
  Effects module that current releases no longer ship; paint a recording in
  one ink colour when you make it, or use the bundled poem reels.
- Enlarged recorded text keeps the work's transient glyphs beside the subject.
  It previously dropped every native cell between the enlarged subject's
  margins, leaving effects such as bubbles and rain blank for part of a loop.
- The bundled catalog now has four focused styles: neon (beams, synth grid,
  equalizer, code rain), space (black hole, fireworks), poems (fourteen ink
  lines) and ember (bubbles, falling sand).  The banner, life, quotes and
  starfield scenes and six near-duplicate Terminal Text Effects recordings
  are gone.  The `ink` pack became `poems` and no longer contains the
  equalizer.
- The equalizer is now a dark-page music visualizer: forty colored bars,
  white peak caps and a dim reflection under the baseline.  It keeps its
  own animation clock, so repeating the page does not restart the bars.
- A poem's settled large text now survives the blank closing frame.  Subject
  bounds come from the last visible frame instead of the blank loop frame, so
  the recording still enlarges the line before fading back to paper.
- Playback caps `gc-cons-threshold` at 32 MiB while a presentation is active
  and restores the caller's value on stop.  Continuous scenes no longer wait
  for one long collection pause; ordinary text rows also stop rescanning every
  blank run on each frame.
- The unused `banner` layer and `life` layer are gone.  Scene packs no longer
  accept `:theme` or `:summary`; both were validated but never read, so they
  now fail as unknown keys instead of implying behavior.  The optional gallery
  recipe contains only the four kept works and one `gallery-kept` pack.

- Presentations run on the ETAF application runtime and require etaf 0.3.0 and
  etaf-ui 0.2.0. The scene background follows the current page through the
  application canvas, and killing the presentation buffer releases it.

### Added

- Fourteen poem reels share one typewriter-and-ink style.  Each line is typed
  at the foot of the page, lifted to the centre, held, and faded into the
  paper; a blank opening and closing frame makes the recording loop without a
  still hold.  `scripts/bake-poems.py` rebuilds them from `scripts/poems.json`
  and writes TTEREC directly, so adding a line needs no external tool.
- Eased page reveals preserve outgoing colors while the next work moves,
  without per-frame image encoding. Configure the duration independently in
  Lisp or Customize; wake input remains available throughout.

- A rebuildable 24-work moving gallery, with six light compositions and three
  dark packs. Offline baking reuses Vanta and MilkDrop renderers, retains their
  attribution and licenses, and can crossfade each reel's loop seam.
- Bounded, atomic canvas baking with deterministic preset/effect seeds,
  frame-by-frame warmup, additional preset packs and offline CLI tests.

- Independent presentation selection: full canvas, gallery card, cinema band
  with clock, and a mosaic of up to four independently animated works. Choose
  globally or per program group/item; narrow walls stack their works.

- Recorded-animation reels adapt external tools without transcribing their
  algorithms. The built-in `tte` provider reads Terminal Text Effects
  recordings, and `etaf-screensaver-import-recording` and
  `etaf-screensaver-import-directory` validate, copy and report compatible
  files with dimensions, color depths and license. Fourteen recorded reels ship
  in `lisp/reels` and join the default program. Other tools can register a
  reader through `etaf-screensaver-define-reel-provider`.
- Image-frame reels: the built-in `frames` provider reads a JSON manifest
  plus baked stills; the canvas scales and slices them per character row,
  centers them and recycles decoded frames. `scripts/bake-canvas-frames.mjs`
  bakes Butterchurn/MilkDrop presets or any page canvas into a bundle.
  Baked bundles stay out of version control.
- Style packs and strategies: `etaf-screensaver-packs` groups scenes into a
  shared visual language (neon, space, ink, ember) and programs accept
  `(:pack NAME)` items, so a round can hold one pack, rotate whole packs,
  loop a single work or mix packs deliberately.  Recorded works register
  their recorded length as the scene duration and no longer get cut
  mid-loop.  Fourteen Terminal Text Effects recordings ship in `lisp/reels`,
  including a light-paper `ink` pack; `scripts/trim-recording.py` drops the
  still tail of a recording before import.

### Changed

- Enlarged recorded text uses the frame's own font stack, including its
  configured CJK family, instead of a family chosen by the application.  The
  automatic size now fills up to 95% of the work width and 70% of its height,
  capped at 24 cells per glyph dimension, so a poem reads as a page rather
  than a line of small type.
- The light page gains `equalizer` (墨线律动): monochrome level bars that follow
  the canvas instead of a stretched image.  Typewriter recordings drop the
  cursor block that would otherwise grow into a solid bar.
- The light `ink` reels now carry Su Shi lines — 《和子由渑池怀旧》「人生到处知何似
  应似飞鸿踏雪泥」, 《定风波》「一蓑烟雨任平生」 and 《临江仙》「小舟从此逝
  江海寄余生」 — type-set one character at a time in a single ink color, without
  color gradients, with matching titles and summaries.

- Single-work recorded text subjects grow to a readable size in graphical SVG builds,
  without changing the caption font, recording timing or surrounding effects.
  `etaf-screensaver-reel-text-scale` selects automatic sizing or a fixed 1–12
  scale; 1 keeps the native size, also used without graphical SVG support.

- Gallery cards inset their thin frame by an even mat of about three line
  heights on every side instead of touching the viewport edge. The side mat is
  derived from the frame's cell metrics so the four distances match on screen;
  compact windows shrink it before the work drops below four content rows, and
  the two ordinary lower-left caption rows stay inside the frame. The echo row
  below the window is painted with the mat and counted in the bottom inset, so
  the four visual distances stay equal. Images retain
  their native size when they fit and only scale down proportionally, avoiding
  blurred enlargement. Generated gallery scenes retain their own background in
  both standalone and pack playback.

- The application is now a canvas-only screensaver. Configure it in Lisp or
  Customize; any key, mouse movement, completed click or wheel input wakes it.
  Dismissal restores the editor and releases all presentation resources.
- Playback programs compose sequential, shuffled and random groups, including
  nested animation sequences, selection counts and per-scene settings.
- **Breaking:** replace `etaf-screensaver-open`/`present` with
  `etaf-screensaver-start`, `close` with `etaf-screensaver-stop`, and
  `etaf-screensaver-idle-mode` with `etaf-screensaver-mode`. Workspace controls
  (pause, resume, step, reset, select-scene, set-param, set-frame-rate and
  set-seed) are removed; use the program and scene-options configuration.
  Replace default-scene/cycle-seconds with program/scene-duration. Status no
  longer takes a buffer name. Use `etaf-screensaver-load-scenes` before a new
  start instead of live reload. Scene pointer callbacks and sand painting
  are removed because pointer input always wakes the editor.
- ETAF UI is no longer a runtime dependency.

### Fixed

- Sequential ANSI color and attribute changes no longer alter preceding runs
  in recorded frames; foreground/background and attribute resets stay local.

- Frame cadence stays aligned to each page's clock instead of accumulating
  timer delay; late frames skip expired slots and natural page deadlines stay
  independent of the outgoing frame's timing.

- Gallery playback reuses fitted image rows and avoids repeated image-width
  measurement and per-cell rendering allocations for empty margins while preserving frame size,
  letterboxing, clipping, styled blank widths and aligned mosaic borders.

- Image-bundle imports recognize file headers even in a headless Emacs build.
  Image composition remains testable without decoding pixels; graphical
  playback still checks decoder support. Validated formats are reused during
  playback instead of reopening each still to redetect its type.

- Repeating gallery rounds reuse validated recording metadata within a shared
  payload budget. Padding shorter rows preserves their image runs without
  unnecessary cropping or reconstruction.

- Image-bundle validation reuses a header buffer and canonical bundle root
  instead of repeating editor-buffer hooks and path traversal for every still.
  Common image signatures use a short initial read, with a bounded fallback
  for longer headers. Import revalidates current assets even when its manifest
  is unchanged; suffixes never replace content checks.

- Image bundle imports reject escaping frame paths and oversized manifests,
  declared canvases, frame lists and encoded image payloads before copying.
- Color-only animation frames now repaint instead of freezing after the first
  tick. Image rows reserve their complete footprint and align to whole rows.
- Default pack playback includes its trailing works instead of repeatedly
  selecting only an initial subset.
- Resuming honors changed effective settings and preserves scene seeds and the
  program's random state. Explicit previews no longer replace that position.
- Frame scheduling no longer adds render time to every nominal frame interval.
- Gallery and mosaic playback reuse their static borders and captions rather
  than rebuilding them on every animation tick. Dense fields reuse invariant
  calculations and reduce per-cell temporary allocations without reducing
  sampling density or changing randomness. Generative scenes reuse their
  current-size scratch canvas without retaining old glyphs or colors. Life
  counts neighbors from live cells and reuses its generation buffers.
- A manually started background preview survives global focus rechecks; it
  still dismisses when its own frame actually loses focus or receives input.
- Scenes can draw Unicode symbols and mixed-width text on Emacs 31, including
  Matrix, Life and Chinese quotes, without failing to write a canvas cell.
- Random expressions use the session seed throughout the scene lifecycle,
  allowing Snow and Starfield to initialize and reset reproducibly.

## 0.1.0

Initial release.

- A scene registry with two public paths: inert scene specs interpreted by the
  generic DSL, and `etaf-screensaver-define-scene` for code scenes.
- Generic layer kinds: `life`, `rain`, `sand`, `particles`, `field`, `text`
  and `banner` (ASCII banner with random terminal effects).
- A pure expression language for layer properties with parameters, globals
  (`w`, `h`, `cx`, `cy`, `t`, `dt`, `tick`, `i`) and arithmetic,
  trigonometric and comparison functions.
- Scene spec files (`.esc`) loaded from `etaf-screensaver-scene-directories`
  with in-place override, tolerant error reporting and live reload.
- A workspace with play, pause, single step, reset, seed, frame rate, scene
  switching, a parameter panel built from ETAF UI components, cinema mode and
  an optional idle presentation mode.
- A retained canvas and HUD line, so a running scene publishes frames without
  re-rendering the application.
- Nine bundled scenes and acceptance tests for the catalog, controls, the DSL,
  the loader and the mount lifecycle.
