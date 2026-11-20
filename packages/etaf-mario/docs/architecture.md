# Architecture

Super Mario is one ETAF application: a deterministic world simulation, a
character renderer and a retained publication loop. There is no game engine,
database or network backend; the framework providers `ecss`, `ebox`, `etaf` and
`etaf-ui` are the only dependencies, and every one of them is consumed through
its root entry.

## Responsibilities

| File | Responsibility |
| --- | --- |
| `etaf-mario.el` | Provides the package, resolves the repository root, loads `lisp/` and declares the supported API in its Commentary |
| `lisp/etaf-mario-art.el` | Named colour roles for the four themes; no geometry |
| `lisp/etaf-mario-levels.el` | Bundled block maps, the map parser, tile predicates and the block-clearance invariant |
| `lisp/etaf-mario-model.el` | Fixed-step physics, collision, blocks, items, enemies, damage and the level clock |
| `lisp/etaf-mario-render.el` | Sprite table, neighbour-aware tile variants, camera, actor placement and row encoding |
| `lisp/etaf-mario-theme.el` | ETAF contribution theme built from the palette roles |
| `lisp/etaf-mario-session.el` | Mutable session state, reactive refs and the HUD/size snapshots |
| `lisp/etaf-mario-views.el` | HUD, canvas, footer and controlled dialogs |
| `lisp/etaf-mario-app.el` | Frame loop, input, retained publication, settings, progress and lifetime |

The dependency direction is `entry → app → views/session → render/model/levels
→ art`. No lower module reads a session or a view, and the renderer never
mutates the world.

## Data flow

1. Key presses extend an intent timestamp in the session; the loop samples them
   once per fixed simulation step.
2. `etaf-mario-world-step` advances the world by exactly `1/60` second. All
   collision, block, item, enemy and clock rules live here, so an input
   sequence produces the same state on every run.
3. The loop copies changed counters into reactive refs, composes a frame and
   publishes only changed canvas rows and HUD values through ETAF's retained
   Host boundary.
4. `etaf-mario-render-frame` is a pure function of the world and the viewport:
   it returns the first visible cell and a list of propertized strings.

The editor timer is only a clock. A slow frame delays the next publication; the
simulation catches up in fixed steps, so gameplay speed does not depend on the
rendering rate.

## Invariants

- One world block is `4` cells wide and `2` text rows tall
  (`etaf-mario-render--cell-width` / `--cell-height`).
- A sprite shorter than a block is centred horizontally; every actor is
  bottom aligned on the text row nearest its feet.
- Floating blocks keep at least two empty block rows above the surface below
  them. Zero empty rows is a step resting on that surface. A one-row shelf
  would be too small for big Mario to pass under and too narrow to jump
  through, so `etaf-mario-level-parse` rejects a map that contains one and
  `etaf-mario-doctor` reports it.
- Block borders join across neighbours: a run keeps a vertical edge only at its
  ends, and the two halves of a pipe share one rim.
- The camera scrolls in single cells and clamps to both level ends; actors keep
  their sub-block offset, so their screen column changes by at most one cell per
  step during a steady walk.
- Nothing paints a scene background. A space in a sprite is transparent, so a
  theme's own background remains visible; scenery (clouds and hills) is drawn
  only for outdoor themes.
- The canvas height is the stage's block-grid height, so a tall window
  letterboxes the game instead of stretching empty sky between the HUD and the
  ground. A short window clips the top of the stage and keeps the ground
  visible.
- The composed frame is two cells narrower than the window. The canvas box
  keeps that slack beyond the text, so a full row never reaches the box edge
  (layout rounding there can drop the last cell and paint it with the row's
  background).

## Level maps

`etaf-mario-levels` is the campaign. Each definition is a plist with `:name`,
`:theme`, `:time` and `:map`, the map being rows of single characters:

| Character | Meaning | Character | Meaning |
| --- | --- | --- | --- |
| `.` | empty | `#` | ground |
| `B` | brick | `?` | coin block |
| `M` | mushroom block | `W` | fire-flower block |
| `S` | star block | `U` | used block |
| `o` | coin | `(` `)` | pipe top left and right |
| `[` `]` | pipe body left and right | `C` | castle stone |
| `L` | lava | `=` | bridge |
| `F` | flagpole | `@` | start |
| `g` | goomba spawn | `k` | koopa spawn |

Rows may differ in length; the parser pads them to the widest row. The parsed
level exposes a row-major tile vector, a hash table of block contents, enemy
spawn records, the start cell and the flag column.

## Publication cost

The simulation advances at 60 Hz and the canvas publishes at 30 or 60 Hz. The
session diffs the composed rows against the previous frame, so a walking frame
updates a handful of rows, not the whole application. Horizontal scrolling
changes most canvas rows by design; the HUD and footer remain separate Hosts
and are only published when their values change.

## GUI acceptance

`scripts/etaf-mario-gui-scenarios.el` is the maintained graphical scenario.  It
starts from a disposable progress file with every stage unlocked, drives the
documented keys from the title through a question block, the mushroom, a
goomba, the pause/settings/help dialogs, both palettes, restart, level select,
the wide/ordinary/compact/short resize matrix, the castle lava and a pit death.
It then restores the frame, the progress file and the temporary canvas face
remap.  The run writes a JSON manifest and window screenshots as evidence;
functional assertions only certify behavior, not appearance.

Run it in a dedicated graphical frame with a fresh run directory:

```sh
pi-skill eac instance open --name mario
pi-skill eac --server mario eval - <<'EOF'
(add-to-list 'load-path "/path/to/etaf-mario")
(add-to-list 'load-path "/path/to/etaf-mario/scripts")
(add-to-list 'load-path "/path/to/etaf/scripts")
(require 'etaf-mario-gui-scenarios)
(etaf-mario-gui-run "/tmp/mario-gui-run")
EOF
pi-skill eac instance close --name mario
```

The verifier refuses a directory that already contains a manifest or result.
Review the captures in `frames/` for alignment, sprite height, block borders,
pipe seams, lava, empty space and both palettes.  The scenario deliberately
paints the canvas background to match the light or dark palette it is
reviewing, because the game itself keeps the scene transparent.
