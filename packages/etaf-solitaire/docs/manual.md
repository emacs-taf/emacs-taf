# Playing Verdant

## Start a deal

Install GameKit's OpenSpiel backend, make the provider roots and this application
available on `load-path`, then run `M-x etaf-solitaire-open`. Every opening owns
an independent backend and buffer. A reproducible deal can be opened with
`(etaf-solitaire-open 11)`.

The native rules are OpenSpiel 2.0.2's K+ Klondike variant. Foundations ascend
from ace to king within one suit. Tableau sequences descend with alternating
colors; empty columns accept kings. K+ combines repeated draws into available
waste-card choices. `D` browses those choices without changing the native state.
The view projects the native observation and legal action labels; it does not
reimplement the rules. The native transition limit is configured to 600.

## Controls

- Click a face-up card to select it. Highlighted destinations accept a legal move.
- `Tab` and directions navigate controls; `RET` activates the focused target.
- `H` selects a legal move's source. It is not a solver or a promise of an optimal move.
- `U` and `Y` restore the preceding/following native action, including random reveals.
- `N` starts a new seeded deal. Save first if the current deal should be retained.
- `C-s` / Save and `C-o` / Load use explicit local snapshot files.
- `F1`, `?` and the toolbar's 说明 button open the same read-only help.
- `Escape` dismisses the innermost dialog, then clears the selection on a
  separate press. With neither present, an embedded table leaves Escape to its
  enclosing host (for example, returning to a desktop without closing the deal).
  A standalone table with nothing to dismiss keeps its position and game state.
- `Q` closes the instance and buffer. Closing never saves automatically.

Help shows the effective bindings and rules in the current game buffer, without
splitting the window or opening another application. Wide windows use two
columns; narrow ones use a scrolling column. `/` starts search. Escape leaves
search editing first, then closes help without clearing the selected card.
Clicking the shade also closes help without activating the covered table.
The compact **合法移动** dialog likewise closes from its shade; help opened over
it closes only the top layer and returns focus to that dialog.

## Appearance and layout

Both light and dark themes are required application surfaces. The default
`etaf-solitaire-appearance` value `auto` selects the opening frame's background
mode. Set it to `light` or `dark` to choose the initial mode of new games.
The theme button and `T` toggle the current instance independently; the backend,
deal and local selection remain alive, and other instances are not recolored.

The complete table is horizontally centered and sits slightly above the
vertical center, sharing surplus height 2:3 above and below. This outer space
disappears in short windows; the table never stretches to fill unused height.

Cards stay nine character columns by five text rows, with one-row exposed
corners in stacks. Wider windows show legal moves beside the table; narrower
ones expose that panel through the toolbar. Short windows remove secondary
spacing and subtitles, not card dimensions. The minimum canvas is 79 columns
by 30 text rows; smaller windows deliberately clip or scroll it.

## Save and recover

Snapshots are opaque GameKit/OpenSpiel files, including chance and history.
Loading validates the candidate before replacing the current deal. Invalid
loads leave the current deal usable and show the backend's reason. If the
connection itself fails, open a new instance and load an explicit snapshot.
No account, external network service or paid API is required to play.

## Validate the appearance

For GUI acceptance, load ETAF's `scripts/emacs-gui-verifier.el` and this
application's `scripts/etaf-solitaire-gui-scenarios.el` in a dedicated
graphical Emacs, then run `etaf-solitaire-gui-run` with a fresh evidence
directory. It drives native keys, both themes, the viewport matrix, a local
snapshot round trip and a second independent deal. Inspect the saved
screenshots; functional assertions alone do not certify appearance.
