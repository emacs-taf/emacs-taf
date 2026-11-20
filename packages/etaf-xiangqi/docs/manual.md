# Chu He · 中国象棋

Chu He is a standalone GameKit application. It presents the OpenSpiel xiangqi
rule set on a native ETAF board with both palettes, a computer opponent and
hot-seat play. The application owns its presentation, colors, opponent settings,
launcher and tests; it uses only public GameKit, ETAF and catalog APIs.

Install GameKit, ETAF, etaf-ui and GameKit's OpenSpiel runtime, then add the
application directory to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/emacs-taf/etaf-xiangqi")
(require 'etaf-xiangqi)
(etaf-xiangqi-open)
```

`etaf-xiangqi-game` is a game definition. `etaf-xiangqi-open` starts an
independent OpenSpiel match, displays its buffer and fits the view to its
window. `etaf-xiangqi-open` accepts an optional integer seed for a reproducible
opening. The application's [entry Commentary](../etaf-xiangqi.el) describes its
public API.

Red (bottom) moves first. `etaf-xiangqi-opponent` chooses who plays which side
in new matches: `computer-black` (the default, with the human on red),
`computer-red`, or `hot-seat`. The computer starts searching immediately, but
its reply is not displayed until at least 0.6 seconds after its turn begins.
This leaves your own move visible first. A longer search consumes that interval
already; there is no extra fixed wait after it finishes. The status reads
电脑思考中… while searching or holding an early reply, then 电脑落子中… during
the move animation. The engine remains authoritative throughout.
`etaf-xiangqi-level` selects `easy`, `normal` (the default) or `hard`, whose
limits are 2 plies/1 second, 4 plies/2 seconds and 8 plies/4 seconds per move.
A time limit can stop search before the depth cap. This is an offline casual
opponent, not a tournament engine; no network account or extra engine is needed.
OpenSpiel owns legality, check, repetition and history, and the GameKit OpenSpiel adapter
owns the computer's search; the application never re-implements a move.

| Input | Action |
| --- | --- |
| Click a stone / Enter | Select it and highlight its legal targets |
| Click a highlighted point | Submit that native move |
| 走法 → select a move | Open the legal moves dialog and submit that move directly |
| U / Y | Undo or redo the last local round; one move each in hot-seat play |
| N / New match | Start a fresh match with a random seed |
| O / Opponent | Choose the opponent and difficulty for the running match |
| C-s / C-o | Save or load an explicit local snapshot |
| T / Light–Dark | Switch between the paper and night palettes |
| ? / F1 / 规则 | Open searchable rules and effective controls in the current buffer |
| Q | Close the match |

Help is a read-only modal in the match buffer, without splitting the window or
opening another application. Wide windows use two columns; narrow ones use a
scrolling column. `/` starts search; Escape leaves editing first, then closes
help without clearing a selected stone. Clicking the shade also closes it
without activating the board. Help does not pause computer search or the
presentation of its reply. The **可走位置** and **对局设置** dialogs also close from
their shades; help opened over either dismisses only its own top layer.

The opponent dialog changes sides when the backend is ready and never resets
the match. Switching to a computer side makes it play the next turn it owns;
switching difficulty affects the next search. Human moves, history and snapshot
commands are unavailable until the reply has visibly landed; theme, help and
closing remain responsive. Undo returns to the previous human decision point, including after
a terminal move; before the computer's red opening has received a human reply,
there is no human move to undo. Hot-seat play follows the side to move.

Snapshots preserve the native match and history, not opponent, difficulty or
appearance settings. Loading continues under the current instance's settings.
A rejected operation displays its error and does not trigger a retry loop; a
new match or a valid manual operation can clear it. A failed connection requires
closing and reopening the match. Online multiplayer is not implemented.

`etaf-xiangqi-appearance` selects the initial palette: `auto` (the default)
follows the frame's background mode, or set `light`/`dark` before calling
`etaf-xiangqi-open`. Switching the palette at runtime repaints the board and
never resets the match.

## Following the computer's move

Graphical boards move the actual stone smoothly from its origin to its target
using ETAF's scoped `etaf-transition` and shared clock. A short move takes about
0.25 seconds; longer moves take up to 0.45 seconds at the normal animation speed.
The artwork updates only the retained cells whose image changes, not a separate
Emacs frame or a replacement board. Captured stones stay visible until covered
by the moving stone, then disappear when it lands.

An amber dashed outline marks the origin and a solid outline marks the target.
They remain until the next accepted move or a history/reset/load operation;
selecting a stone takes visual precedence over its old move marker. The caption
below the board names the moving side, piece and endpoints, plus a captured
piece when present, for example `电脑：红炮 b2 → b9，吃黑馬`. Files `a`–`i` run
left to right; ranks `9`–`0` run top to bottom. Cell accessibility labels also
identify the computer's origin and destination.

Terminal displays and `etaf-animation-enabled` set to nil retain the reading
interval, endpoint marks and caption without interpolated movement. An already
paused animation clock skips new move animations; pausing during a move holds
its current position until resumed. Closing disposes the timer and animation
scope. A backend reset, load, undo or error supersedes any pending presentation,
so an old reply cannot reappear afterwards. These are presentation effects,
not a second rule engine or extra backend turns; they are not saved in snapshots.

The board is the primary surface, with compact controls above it. Legal moves
are marked by dots (empty intersections) or rings (captures); **走法** opens
an optional list instead of taking permanent space beside the board. A solid
jade ring identifies the selected stone; a dotted ring identifies keyboard
focus. Arrow keys move focus, Enter selects or moves, and Escape first closes
an open dialog, then clears selection on the next press.

## Reading a check

The side to move being checked comes from the same observation the board draws:
the status line appends 被将军 in the palette's danger colour and the general's
intersection carries a danger frame, so a position that restricts almost every
stone explains itself. Pressing a stone with no legal target then says why in
the caption below the board — `红傌 解不了将` while checked, otherwise
`红傌 本回合没有合法走法` — and **走法** titles its list 被将军：只有解将的招法.
The warning clears as soon as any accepted move answers the check. It only
describes the public position; the engine still decides which stones may move
and how the match ends.

Graphical Emacs with SVG support renders an intersection lattice, river and
palaces with circular ivory stones. Each intersection is a native ETAF tile,
not a screenshot with a separate hit-testing overlay. The image Host divides
its artwork into ordinary text rows, preserving line height and keyboard input.
Terminals use named text cells with the same native rules and activation paths.

The header, board and controls form a horizontally centered table. Surplus
height is shared 2:3 above and below the table, placing it slightly above the
window center. Short windows remove this outer space without shrinking stones.

Cell dimensions are chosen once from the opening frame's metrics: three text
rows, and the nearest character width to a square. A typical 7 × 16 pixel font
uses 49 × 48 pixel cells, making the board 441 × 480 pixels. Resizing does not
stretch or replace the stones. Short windows remove vertical gaps and padding;
at those metrics the complete compact table needs 67 columns × 34 rows.
Below that minimum the board stays anchored at the left and may be clipped or
scrolled. Closing makes no implicit save.

For GUI acceptance, load ETAF's `scripts/emacs-gui-verifier.el` and this
application's `scripts/etaf-xiangqi-gui-scenarios.el` in a dedicated graphical
Emacs, then run `etaf-xiangqi-gui-run` with a fresh evidence directory. It covers
both themes, fixed metrics across viewport sizes, native keys, dialogs,
history and switching to a computer opponent. It captures a real in-flight
move in both palettes using ETAF's public pause control, then resumes and
checks the landed caption. Inspect the saved screenshots; functional assertions
alone do not certify appearance. `benchmarks/performance-scenarios.el` registers selection,
theme and resize workloads for the enclosing workspace's performance driver.
