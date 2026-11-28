# Building games with GameKit

## Create a separate game project

A game is an application that depends on GameKit. Keep its entry, rules, UI and
assets in its own repository. The framework does not need to know the
application's name or add a launcher for it.

Add the GameKit and ETAF repository roots to `load-path`, or install them as
packages. Add etaf-ui when the game uses catalog components. A minimal game
entry `my-poker.el` can contain:

```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-gamekit)
(require 'etaf-ui)

(defun my-poker-view (instance)
  (etaf-view
   (etaf-panel :title "My Poker"
     (etaf-label :text (or (etaf-gamekit-view instance :information_state)
                          "Starting game…"))
     (etaf-button :for (action (etaf-gamekit-view instance :legal_actions))
       :key (plist-get action :id)
       :label (plist-get action :label)
       :on-press (lambda ()
                   (etaf-gamekit-action instance "act"
                                        (list :action (plist-get action :id))))))))

(etaf-gamekit-define-game my-poker-game
  :title "My Poker" :backend 'openspiel
  :options '(:game "kuhn_poker" :player 0 :seed 42)
  :view #'my-poker-view)

(defun my-poker-open ()
  (interactive)
  (let ((instance (etaf-gamekit-start my-poker-game)))
    (pop-to-buffer (etaf-gamekit-buffer instance))
    (etaf-refit (etaf-runtime-for-buffer (etaf-gamekit-buffer instance))
                (selected-window))
    instance))

(provide 'my-poker)
```

`my-poker-game` is an inert definition. Each start creates a new instance with
its own state, buffer and lifetime. This small interface controls player 0;
a complete local table supplies its own player-switching controls through the
adapter's `set-player` action. Games with different interfaces still use the
same definition/start/action/state/lifetime contract.

A definition binds the game's title, backend configuration, view factory and
optional observation validator. Configuration consists of JSON-compatible
keyword data. Per-instance `:options` override matching keys without changing
the definition, for example a different seed or player. Views and validation
belong to the game project. The callback receives a detached observation and
must return exactly `t`; a false result or signaled error fails the instance
with diagnostic context.

A view factory receives the running instance and returns any ETAF View.
`etaf-gamekit-game-info` supplies the game's name/title/backend, including
during its first render. Use local component refs for selection, dialogs and
unsent input. Authoritative game state remains behind the backend adapter.

Game applications are independent packages beside the framework packages.
For example, Salvage Station keeps its Godot project and complete ETAF interface
in `etaf-salvage`; GameKit contains no game-specific launcher or presentation.

## Read state and submit actions

Use `etaf-gamekit-view` inside views and computed values. Its optional top-level
field argument avoids copying unrelated fields. Use value equality on computed
JSON fields so unchanged data does not invalidate unrelated panels.
`etaf-gamekit-observation` returns the latest accepted state immediately.
Both interfaces return detached values; editing a returned value never changes
the game or the framework's retained observation.

Unsolicited publication is coalesced to at most 60 Hz. An update outside the
current rate window publishes on the next Emacs event-loop turn; updates inside
the window share its remaining delay rather than starting another full wait.
Intermediate streamed frames may be skipped. Acknowledged input bypasses the
rate window and publishes on the next turn, with a response burst sharing one
publication. Rendering and event-loop work add to those scheduling intervals.

Actions use an advertised operation string and keyword-plist arguments. Objects
are keyword plists, outgoing arrays are vectors, JSON false is `:false` and null
is nil. The backend validates the action against the current game state.
Advertised operations describe routing capabilities; they do not mean every
move is currently legal. The game supplies legal actions, active players,
resource requirements or other availability facts in its observation.

Up to eight requests may be outstanding. Acknowledgments must arrive in order;
a full queue rejects additional actions synchronously. The deadline for each
request begins when sent, and defaults to 15 seconds through
`etaf-gamekit-request-timeout`. A successful acknowledgment clears the previous
rejection. Unsolicited frames cannot clear it.

A `ready` status means that backend responses have been accepted, not that
coalesced display publication has completed. After an action, an observation
can already describe the next screen while `etaf-gamekit-view` and the painted
controls still describe the previous one. Before a verification script sends
UI input, wait for the expected accepted state **and** the relevant published
view/target. Do not replace this condition with a fixed sleep or a larger timeout.

For bounded integration scripts, use a predicate over public observations and
view fields. This helper is for the outer control loop, not a render function or
an event callback; normal application views remain reactive:

```elisp
;;; -*- lexical-binding: t; -*-
(defun my-game-await (instance published-p &optional seconds)
  "Await INSTANCE and PUBLISHED-P, or report its rejection/failure/deadline."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while
        (progn
          (when (memq (etaf-gamekit-status instance) '(failed closed))
            (error "Game is %s: %s" (etaf-gamekit-status instance)
                   (or (etaf-gamekit-last-error instance) "no live instance")))
          (when-let* ((reason (etaf-gamekit-last-error instance)))
            (error "Game action rejected: %s" reason))
          (not (and (eq (etaf-gamekit-status instance) 'ready)
                    (funcall published-p))))
      (when (>= (float-time) deadline)
        (error "Expected game view was not published before the deadline"))
      (accept-process-output nil 0.01)))
  t)

;; With my-poker-game from the example above:
(let ((instance (etaf-gamekit-start my-poker-game)))
  (unwind-protect
      (progn
        (my-game-await
         instance (lambda () (and (etaf-gamekit-capabilities instance)
                                   (etaf-gamekit-view instance :legal_actions))))
        (let* ((next (1+ (plist-get (etaf-gamekit-observation instance) :action_count)))
               (action (car (etaf-gamekit-view instance :legal_actions))))
          (etaf-gamekit-action instance "act" (list :action (plist-get action :id)))
          (my-game-await
           instance (lambda ()
                      (and (equal next (plist-get (etaf-gamekit-observation instance)
                                                  :action_count))
                           (equal next (etaf-gamekit-view instance :action_count)))))))
    (etaf-gamekit-close instance)
    (kill-buffer (etaf-gamekit-buffer instance))))
```

For a screen transition, compare its application-defined phase in both state
surfaces rather than requiring whole-observation equality: a real-time stream
may skip intermediate display frames. If the next input needs a specific Host,
include its published availability in the predicate through ETAF's public
queries. A non-nil `etaf-host-ref-position` alone is not enough: require a
nonempty `etaf-host-ref-bounds` span, the expected enabled props, and visibility
in the window receiving native input. Re-resolve the target after publication;
never keep old buffer positions across a screen change. A rejected action or
failed/closed instance is a failure, not a reason to keep waiting or retry it.

GameKit does not prescribe boards, stories or widget trees. Observations may
contain entities, cards, inventories, timelines and asset IDs. Resolve asset
IDs through the game's own content manifest. Compose ETAF image/video and
etaf-ui media components as needed. Binary assets do not belong in state
messages; a rendered canvas is published out of band and described by a small
frame object, as the next section explains.

## Publish and show native frames

A game whose native kernel renders a canvas can publish it as image strips and
show it with `etaf-gamekit-frame-canvas`. The producer writes one PNG per text
line, and the observation carries a frame description while the application
composes the canvas from reactive frame, geometry and fallback text inputs.

The frame description is:

| Field | Meaning |
| --- | --- |
| `id` | Id of the newest complete publication. |
| `block` | Device pixels the producer draws one logical block in. |
| `line` | Device pixel height of one strip. |
| `width` | Device pixel canvas width. |
| `strips` | Per-row publication ids, top row first. |

Strip `ROW` of publication `SERIAL` is `ROW-SERIAL.png` in the canvas
directory: `:line` device pixels tall and `:width` device pixels wide. The
client decodes only rows whose id differs from the shown frame, so a producer
that keeps the ids of unchanged rows republishes cheaply and owns retirement
of old files. A row whose named file is already gone keeps its previous image.

The application owns the geometry plist, and it configures the producer with
the matching values.

| Key | Meaning |
| --- | --- |
| `:graphic` | Non-nil to display native frames; nil shows `:text`. |
| `:density` | Device pixels per logical pixel (the display density factor). |
| `:device-block`, `:device-line` | Values the producer draws with. |
| `:pixel-width` | Logical canvas width; a frame must report `:pixel-width` times `:density` as its `:width`. |
| `:columns`, `:rows` | Host box size in character columns and text lines. |
| `:ascent` | Image baseline percentage passed to `create-image`. |

```elisp
(etaf-gamekit-frame-canvas
 :frame (etaf-computed (lambda () (etaf-gamekit-view session :frame)) :test #'equal)
 :text (etaf-computed (lambda () (board-as-text)) :test #'equal)
 :geometry (etaf-computed (lambda () (board-geometry)) :test #'equal)
 :directory directory :label "Battlefield" :ref 'board)
```

Compute the geometry from `etaf-display-metrics` (character width, line height
and ascent) plus the display density, and send the producer the theme and
device block/line whenever the geometry changes. A frame that does not match
the current geometry is ignored until the producer adopts it, so the canvas
keeps showing the previous strips across a resize. Only a graphic geometry
displays frames; `:text` shows on text displays and before the first matching
frame.

### Godot frame publication

GameKit's Godot bridge exposes the shared strip publisher to game scripts:

```gdscript
var native_dir: String = Engine.get_meta("gamekit_native_dir")
var FrameStrips = load(native_dir.path_join("frame_strips.gd"))
var strips = FrameStrips.new()
```

The class composes a canvas from a background image the game paints plus an
ordered list of draw operations, and writes only the changed strips. The game:

1. calls `configure(device_block, device_line, width, height)` when the
   geometry changes;
2. paints `strips.base` and calls `mark_all()` or `mark_rows(top, bottom)`
   after changing it;
3. calls `begin()` at the start of each frame and records artwork with
   `draw(key, image, at, source)`, where a stable `key` is what lets the
   publisher recognize an unchanged strip;
4. calls `publish(directory, id)`, which returns `""` or a failure message,
   and reports `strips.description()` as the observation's `frame`.

The included `native/godot/frame_strips.gd` keeps 16 file versions per strip
and encodes on the worker pool. Artwork, layers and simulation stay the
game's.

## Choose and configure a backend

Only the selected backend is required to run a game. Framework development's
complete `make check` needs all included backends.

### Godot

`M-x etaf-gamekit-install-godot` installs the pinned official release after
SHA-256 verification, from an archive installation or a checkout, because the
package ships the setup script. Installation runs in the background: progress
goes to `*ETAF engine install*` and the echo area reports the result. One run
happens at a time, a cached archive that cannot verify is dropped before the
retry, and a failure keeps an already working runtime in place. With a prefix
argument the command registers an existing Godot 4.7+ executable instead of
downloading. Python 3.9+ performs setup. The installer supports macOS universal
and Linux x86-64/arm64.

A source checkout reaches the same result from the shell: `make engine`
downloads the pinned release, and
`python3 native/godot/install-godot.py --godot /path/to/godot` registers an
existing executable. Files stay under `~/.cache/emacs-taf/game-engines`,
respecting `XDG_CACHE_HOME`; `--cache DIRECTORY` selects another cache, after
which `etaf-gamekit-godot-program` must point to its `bin/godot`. Setup does
not change PATH or Emacs init.

A game definition uses `:backend 'godot` and
`:options (list :project "/path/to/my-game/godot-project")`.
The project contains `project.godot` with `gamekit/game_script` pointing to a
script extending Node or Node2D. The script implements:

- `capabilities() -> Array`: advertised operation names.
- `command(operation: String, args: Dictionary) -> String`: apply a valid action;
  return an empty string on success or an explanatory rejection without partial mutation.
- `observe() -> Dictionary`: the game's complete JSON observation.

The framework's shared bridge handles stdin, ordered requests, shutdown and
changed-state publication. `gamekit/observation_hz` in `project.godot` selects
the maximum unsolicited state rate, from 1 to 60 Hz; omission keeps the 20 Hz
default. Invalid rates fail startup with an explanatory error. For example:

```ini
[gamekit]
game_script="res://game.gd"
observation_hz=60
```

The bridge retains the fractional interval remainder instead of losing a
simulation tick at each publication. Unchanged observations are not sent;
acknowledged commands are independent of this rate. This setting does not
change the game's physics rate or promise a display frame rate. Commands and
simulation run on Godot's main thread. Godot starts with
`--headless --no-header`; ETAF owns presentation and input. Game scripts keep
stdout reserved for the bridge. A project that draws publishes frame strips as
described in [Publish and show native frames](#publish-and-show-native-frames).

### boardgame.io

Install Node.js 18+, then run `make engine-boardgame-io`. The standard npm lock
file pins the adapter's dependencies; generated `node_modules` is untracked.
`etaf-gamekit-node-program` selects the Node executable.

A game definition selects `boardgame-io`. Its options are `:game` (an absolute
JavaScript module path), `:num-players` (default 2), optional `:player` (a string
ID) and `:seed` (a string). The module exports a normal boardgame.io Game as
`default` or `game`; regular imports resolve in that game's own project.

The adapter uses the public Client API. boardgame.io owns rules, phases, turns,
player activity, undo/redo and seeded random state. The observation's
`state.G` is filtered through the game's `playerView`; `state.ctx` contains its
native turn/phase context. `moves` and `events` list dispatcher names.

| Operation | Arguments |
| --- | --- |
| `move` | `:name` and optional `:args` vector |
| `event` | `:name` and optional `:args` vector |
| `undo`, `redo`, `reset` | None; the native game determines availability |
| `set-player` | `:player` string or nil for the client's unassigned-player mode |
| `save`, `load` | `:path` to an opaque local snapshot |

This adapter owns one local match. It does not start a network server, lobby or
AI player. Player switching is a local application's control, not an
authentication boundary.

The pinned Client has no public state-loading API. Snapshots therefore record
seeded command history and replay it into a candidate client, comparing the
result before replacing the current match. Games must use deterministic moves
and boardgame.io's seeded random API. Snapshots also check the engine version,
entry-module fingerprint and player configuration. Imported rule changes need
a corresponding entry-module version change. Applications do not parse or edit
these files. Native invalid-move diagnostics remain on stderr.

### OpenSpiel

`M-x etaf-gamekit-install-openspiel` creates a private environment at
`~/.cache/emacs-taf/game-engines/openspiel`, honouring XDG_CACHE_HOME, and
installs the pinned OpenSpiel from `native/openspiel/requirements.txt`. Setup
needs Python 3.11+ and picks the newest one on PATH; with a prefix argument the
command asks for an interpreter instead. The new environment is imported and
checked against the pinned version before an older one is replaced, so a failed
run keeps a working environment in place. Installation runs in the background:
progress goes to `*ETAF engine install*` and the echo area reports the result.
A source checkout can run `make engine-openspiel GAMEKIT_PYTHON=python3.11`
instead. `etaf-gamekit-openspiel-python-program` selects a different environment.

A game definition selects `openspiel` with `:game` containing an OpenSpiel game
specification, plus optional integer `:player` and `:seed` (both default 0).
Discover the installed native rules with:

```sh
~/.cache/emacs-taf/game-engines/openspiel/bin/python \
  native/openspiel/bridge.py --list
```

The adapter supports sequential and simultaneous rules with explicit chance
nodes. It samples chance outcomes from a per-instance seeded RNG. Mean-field
updates and sampled-stochastic kernels require a specialized adapter and are
rejected explicitly. A catalog entry is not a claim that every game has been
individually accepted with an ETAF frontend.

Observations include the chosen player's observation string/tensor and
information state when provided by the kernel, legal action IDs/labels,
current player, simultaneous/terminal flags, rewards and returns. They contain
no executable frontend descriptions. The game decides how to turn these
native facts into its own interface.

| Operation | Arguments |
| --- | --- |
| `act` | Integer `:action`, legal for the currently selected active player |
| `joint-action` | `:actions` vector with one legal action per player |
| `set-player` | Integer `:player` perspective for local play |
| `bot` | `:policy` (`search` or `random`) plus the search budget: integer `:depth` plies and number `:seconds` |
| `undo`, `redo` | Optional integer `:count` (default 1); restore that many preceding/following accepted player actions, chance state and perspective |
| `reset` | Optional integer `:seed`; reset the native state, using that seed or the current seed |
| `save`, `load` | `:path` to an opaque local snapshot |

Sequential kernels advertise `bot`, which plays one move for the side to move
regardless of the perspective `set-player` selected, so a frontend can let a
local opponent answer on its own turn. The `search` policy uses iterative
alpha-beta over native legal moves, with material and soldier advancement as a
bounded evaluation; native terminal wins always outrank material gains. This
casual opponent currently supports xiangqi, not a tournament-strength engine.
`:depth` defaults to 4 and accepts integers 1–12; `:seconds` defaults to 1 and
accepts 0.05–10. Search runs in the backend process, not Emacs. On deadline it
uses the last completed iteration, or a legal fallback if none completed.
The caller's request timeout must exceed the budget plus transport overhead.
`random` chooses a uniformly random legal action in any sequential kernel.
Bot tie-breaking uses the match seed and action count, without consuming the
chance sampler. Repeatability requires the same completed search depth.

The observation's `bot` field reports the last bot decision: policy, requested
and completed depth (`requested_depth`/`depth`), nodes, score, elapsed seconds,
action and label. The random policy reports depth zero and has no search budget.
Diagnostics clear after manual play, history navigation, reset or load; they are
not saved. The move itself is an ordinary player action for undo, redo and
snapshots. Rejected searches retain the position and last diagnostic.

Observations also contain `can_undo`, `can_redo` and `action_count`. The adapter
retains up to 128 player-action checkpoints. Undo includes resolved chance and
the acting player's perspective; changing perspective alone is not a turn.
`undo` and `redo` take an optional integer `:count`, clamped to the available
history, so a frontend can restore a whole local round without observing
intermediate positions. A new action after undo discards redo history. Reset
clears both histories; a different seed starts a new deal for stochastic games.
Rejected operations preserve the state, sampler and histories.

Snapshots use OpenSpiel's native game/state serialization and preserve the
adapter's chance RNG and undo/redo histories. Loading validates every candidate
checkpoint before changing the running instance. The maintained kernel scenarios
cover chance, sequential play and saved undo/redo with poker and solitaire,
and simultaneous play with the rock-paper-scissors matrix game.

## Save, recover and close

A game can use the common `save`/`load` operations when advertised by its
backend. The backend owns snapshot representation and compatibility. The two
rule-library adapters limit snapshots to 8 MiB and publish files atomically.
Individual Godot games define their own format and limits. No implicit save is
performed when an instance closes.

Rejected actions preserve the usable connection and expose their reason through
`etaf-gamekit-last-error`. Invalid framing/schema, a deadline or unexpected
process exit marks the instance failed while retaining its last observation.
Start a new instance of the same game and restore an explicit snapshot to
recover. Closing, killing or unmounting its buffer releases the process and
timers. Closing twice is safe; the caller remains responsible for the buffer.

## Add a backend adapter

Backend authors register an adapter with a launch function that receives game
configuration and returns a program/argument list. The framework owns process
creation and lifetime. Registration adds a backend capability; it does not
register or open an application.

```elisp
(etaf-gamekit-register-backend 'my-rules
  :title "My rule kernel" :features '(turns snapshots)
  :launch (lambda (options)
            (list "/path/to/my-rules-adapter"
                  "--rules" (plist-get options :rules))))

(etaf-gamekit-define-game my-game
  :title "My Game" :backend 'my-rules
  :options '(:rules "/path/to/my-game/rules.json")
  :view #'my-game-view)
```

Registry descriptions are detached metadata. Duplicate registration fails unless
`:replace t` is explicit. Replacing or unregistering a backend affects future
game starts, not already running instances. The detailed supported API inventory
is the [entry Commentary](../etaf-gamekit.el).

## Adapter wire contract

The process owns authoritative state. UTF-8 JSON objects are separated by
newlines, with at most 1 MiB per value. stdout is exclusively protocol data;
diagnostics go to stderr. Requests contain version 1, a positive increasing
integer ID, operation string and argument object. The first operation is
`start`; adapters reject repeated starts.

```json
{"version":1,"id":1,"op":"start","args":{}}
{"version":1,"id":2,"op":"act","args":{"action":0}}
```

Every response contains:

```json
{"version":1,"id":2,"revision":7,"capabilities":["act","save","load"],"observation":{"schema":"my-game/1","score":10},"error":null}
```

Revisions strictly increase across acknowledgments and unsolicited observations.
An acknowledgment echoes the oldest outstanding request ID; unsolicited state
uses `id: null` and `error: null`. Rejections echo their ID with a nonempty error
string and the current valid observation. Missing fields, stale revisions and
uncorrelated replies fail the instance. EOF ends the backend's lifetime.
Decoded objects are keyword plists, arrays are lists, false is `:false`, and
null is nil. The observation schema belongs to the game or its chosen adapter.

## Validate framework changes

`make check` runs structure/API validation, compilation, game-definition and
lifetime scenarios, native library transitions and snapshot recovery. The
controlled protocol peer exercises malformed input, queue bounds and failure;
boardgame.io and OpenSpiel scenarios use the actual installed kernels.

The framework's transport workloads use the shared workspace performance driver:

```sh
python3 scripts/performance.py run --mode batch \
  --scenario-file etaf-gamekit/benchmarks/performance-scenarios.el \
  --load-path etaf-gamekit --scenario 'etaf-gamekit.grid.*' \
  --sets 3 --samples 30 --warmups 5
```

Select `etaf-gamekit.kernel.*` with the same command for native boardgame.io and
OpenSpiel action-to-publication workloads. Each action must reach the backend,
be acknowledged and appear in the game-owned view; the 16.67 ms budget is an
acceptance target, not a measured claim.

Each game owns its integration workloads and GUI acceptance in its own
repository. Framework transport measurements cannot replace application
acceptance. Batch and background GUI timing do not certify OS input latency.
