# 坦克大战

A Battle City-style tank game for Emacs. Each game runs an independent
headless Godot world that owns the rules, a fixed simulation clock and the
battlefield renderer; the ETAF application owns the stage select, battle panel,
map editor, settings, dialogs and file prompts. Requiring GameKit never loads
or launches this game.

```elisp
(add-to-list 'load-path "/path/to/emacs-taf/etaf-tanks")
(require 'etaf-tanks)
(etaf-tanks-open)
```

Install ETAF, etaf-ui and GameKit before opening, then install the Godot runtime
once with `M-x etaf-gamekit-install-godot`.
The bundled project is `native/godot/`, resolved relative to this package's own
entry. The [entry Commentary](../etaf-tanks.el) documents the supported Lisp API.

## Rules

Defend the eagle base at the bottom of the field and destroy every enemy tank
of the stage. The battle is lost when an enemy shell (or your own) hits the
base or when your last tank is destroyed. Enemies enter in batches from the
spawn points at the top; only a limited number are on the field at once. The
battle panel lists the tanks still waiting, your lives, score and firepower.

| Enemy | Behaviour | Points |
| --- | --- | --- |
| Basic | Slow | 100 |
| Fast | Twice as fast | 200 |
| Power | Fires fast shells | 300 |
| Armored | Takes four hits; its colour shows the remaining armour | 400 |

Enemies that flash red drop a bonus when destroyed (500 points when collected):
the helmet shields your tank for 10 seconds, the clock freezes enemies for 10
seconds, the shovel walls the base with steel for 20 seconds, the star upgrades
your cannon, the grenade destroys every enemy on the field and the tank adds a
life. Each star makes shells faster, then allows two shells in flight, then
breaks steel; losing a tank resets the cannon. Every 20,000 points add a life.
A new tank is shielded for 3 seconds.

A shell chips one quarter-block layer of brick across a tank's width; a
three-star shell cuts two layers and also breaks steel. Water blocks tanks but
not shells, forest hides tanks beneath it and ice makes tanks slide.

Difficulty is easy (five lives, four enemies on the field), normal (three
lives, five enemies) or hard (seven enemies, faster spawns and fire, more
armored upgrades). Later stages spawn and fire faster and put one more enemy on the
field from stage 10. Clearing stage 20 continues with stage 1 at a higher loop
level. Lives, score and firepower carry into the next stage; retrying restores
the stage's opening resources.

## Keys

| Screen | Key | Action |
| --- | --- | --- |
| Menu | Arrows, Return, G | Choose a stage; start it |
| Menu | E, N, D | Edit the selected map, create a new map, cycle difficulty |
| Battle | Arrow keys | Drive |
| Battle | Shift+arrow | Turn in place |
| Battle | F, X | Fire; stop driving |
| Battle | P, R, N, M | Pause or resume, retry the stage, next stage, return |
| Battle | C-s, C-o | Save or load a snapshot through a file prompt |
| Editor | Arrows, 1–9 | Move the cursor; choose a brush |
| Editor | F, D, B, U | Paint, toggle continuous painting, brush size, undo |
| Editor | P, C-s, M | Test-play, save the map, return to the menu |
| Any | S, T, ? / F1, Q | Settings, light/dark palette, rules and keys, close |

`?`, `F1` and **说明** open the same read-only, searchable help modal inside
the current game buffer. It lists the active screen's real bindings and keeps
the game rules as usage notes, rather than a second static key table. Wide
windows use two columns; narrow windows use a scrolling column. Escape first
leaves search editing, then closes help. Clicking the outer shade also closes
it without activating the game underneath; the opening focus is restored.

Every key also has a button. Help, settings and file prompts pause a running
battle first and dismissing them does not resume it. The game pauses when its
buffer stops being the selected window's buffer, or when real keyboard focus
leaves an embedded game for its host or another application. Returning restores
the game without resuming it; press `P` explicitly to continue. Backend screen
updates do not reclaim focus from the host. In an embedded game, Escape closes
help or settings before returning to the host, one layer per press, without
closing or restarting the battle. Retrying or leaving a running battle asks
for confirmation; a paused battle is left immediately.

## Settings

`S` opens the settings, which take effect immediately: game speed and the
player's tank speed (50–200 %), arrow-key sensitivity (follow the system key
repeat, sensitive, standard or smooth), driving mode (drive while an arrow is
held, or keep driving after one press until X or Shift+arrow), the frame
rate (30 or 60) and, on graphic displays, the board size (small, medium or
large: 12, 16 or 20 pixels per block). *Save as default* stores them, with the difficulty, through
Customize in the `etaf-tanks-*` variables listed in the Commentary.

## Maps and the editor

The campaign tab lists the twenty built-in 40×30 stages, each with four enemy
spawns, with a ✓ on the ones cleared;
`etaf-tanks-progress-file` records cleared stages and best scores per
difficulty. The custom tab lists the maps in `etaf-tanks-map-directory`;
*Import* opens any map file in the editor.

A map is a UTF-8 text file:

```
name: Two Rivers
enemies: 14 4 2 0
map:
EE..........EE..........EE
...
```

`name:` is optional (1–24 characters). `enemies:` gives the basic, fast, power
and armored counts (1–60 in total). The `map:` section has equal rows of 12–52
columns by 12–40 rows; each character is a quarter of a tank: `.` ground,
`#` brick, `@` steel, `~` water, `*` forest and `=` ice. 2×2 groups mark the
base `H` (exactly one), the player start `P` (exactly one) and one to four
enemy spawns `E`. Lines beginning with `;` are comments; files over 64 KiB are
rejected. The menu preview reports a map's defects before it can be played.

The right-hand painting tools show the editing keys without opening Help.
Choose a brush with 1–9 and move the yellow cursor with the arrows: drawing is
on by default, so every step paints the brush and a held arrow draws a stroke.
Hold `Shift` with an arrow to move without painting, and press `F` or click
**绘制 · F** to paint the current cell alone. Choosing a brush alone does not
paint. **撤销 · U** undoes a change and is disabled when there is nothing to
undo. The **绘制：开/关 · D** button turns painting on and off for plain cursor
movement.

The editor paints with 1×1 or 2×2 brushes, undoes strokes, edits the name and
enemy counts, test-plays the draft (M returns to the editor) and saves into the
map directory, asking before overwriting a file.

## Snapshots and programmatic callers

A definition can be started with `etaf-gamekit-start etaf-tanks-game`; the
caller owns its buffer and uses `etaf-gamekit-close` to release it. Read the
current state with `etaf-gamekit-observation`, or `etaf-gamekit-view` in
reactive views. Wait for `etaf-gamekit-status` to report `ready` before the
first command. Commands go through `etaf-gamekit-action`:

- `begin` takes a map text `:map` and optional `:stage` (1–999),
  `:difficulty` (`"easy"`, `"normal"`, `"hard"`), `:seed` and carried
  `:lives`, `:score`, `:star` and `:next_life`.
- `next` takes the following `:map` and `:stage` after a cleared stage and
  carries lives, score and firepower; `restart` retries the current stage
  with its opening resources.
- `menu` previews an optional `:map`; `edit` previews `:map` with an editor
  cursor at `:x`, `:y` and brush `:size` (1 or 2).
- `drive` and `aim` take `:direction` (`"n"`, `"e"`, `"s"` or `"w"`); `fire`
  and `stop` take no arguments.
- `pause` toggles a running battle, or sets `:paused` to `t` or `:false`.
- `settings` takes `:speed`, `:player_speed`, `:hold`, `:repeat`, `:latch` and
  `:frame_rate`.
- `display` takes the frame `:directory`, the `:theme` (`"light"` or
  `"dark"`), the device pixels per map block `:block` (an even number from 8
  to 96) and per text line `:line` (6–256).
- `save` and `load` take an explicit `:path` string.

The observation reports `phase` (`menu`, `edit`, `intro`, `play`, `cleared`
or `over`), `paused`, the map `size`, the battle `hud`, the player `actor` and
the end-of-stage `tally`; without a frame directory it also reports the
`world` grid of units, shells and bonuses. With a frame directory, `frame`
describes the newest published frame once one exists: its `id`, `block`,
`line` and pixel `width`, and `strips`, the file version of each horizontal
strip, top to bottom. Strip *i* at version *v* is the PNG
`DIRECTORY/i-v.png`, `line` pixels tall; a new version is written only when
the strip changed. The 16 newest versions of each strip are kept, so a reader
that lags a few frames behind still finds its files. The caller owns the
directory and deletes it after closing. A rejected command reports its
reason through `etaf-gamekit-last-error` and leaves the state unchanged.

Snapshots are written only to explicit paths, atomically. Loading validates the
complete file against its map before replacing the battle, resumes paused and
clears in-flight shells and spawns. Malformed files leave the current battle
untouched. Closing never saves.

## Display

The header, battlefield and controls form one horizontally centered table.
Surplus vertical space is divided 2:3 above and below it, placing the table
slightly above the window center. Short windows remove this outer space before
clipping; the controls and battlefield are not stretched to fill a large window.

On graphic displays Godot draws the battlefield as flat vector art with soft
lighting, rasterized at the screen's device pixels so high-density screens stay
sharp. The board uses the preferred block size from the settings; when the
window cannot hold it, the block shrinks in 2-pixel steps down to 10 pixels,
and below that the window clips the board. In battle a compact panel moves
below the board when that allows larger blocks. Each frame is divided into
strips one text line tall, and only the strips that changed are encoded and
replaced, so Emacs decodes just those lines. The frame rate paces steady
animation; a frame answering a drive, aim, fire or pause key is drawn on the
next 60 Hz simulation step instead of waiting for the next paced frame. After a
resize the previous frame stays visible until Godot has drawn one for the new
size. Buffer text scaling also updates the public ETAF display metrics: the
board keeps its pixel width and Godot repartitions it into strips at the new
line height and baseline. Zooming in, out or back to the default size preserves
the selected stage, paused battle and keyboard focus; labels reflow around the
board rather than stretching the map. Palette changes affect presentation only and never restart or pause the
battle. Text displays show a two-character-per-block grid instead.

Correctness lives in `tests/acceptance.json`, which runs the real Godot backend
through public game and UI interfaces. `scripts/etaf-tanks-gui-scenarios.el`
drives the application in a dedicated graphical frame with exactly one visible
frame: load it with `scripts/emacs-gui-verifier.el` from ETAF and call
`etaf-tanks-gui-run` with an evidence directory. It covers both palettes
across the viewport matrix, battle keys, snapshot prompts, the editor, a
cleared stage and a defeat.

The workspace performance driver runs `benchmarks/performance-scenarios.el`.
The `etaf-tanks.keys.*` workloads measure driving, aiming, firing and
driving while firing on the final stage on hard: native key input, the
Godot response and the changed board image offered to redisplay. Theme, pause
and resize workloads are measured separately. Background GUI results do not
certify foreground operating-system input latency.
