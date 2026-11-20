# 超级马里奥 · Super Mario in Emacs text

A side-scrolling platformer drawn entirely with ordinary Emacs characters and
faces. Every brick, question block, pipe, coin, enemy and Mario is a small
character picture composed by hand; nothing paints a scene background, so the
buffer's own theme background shows through. The world runs on a deterministic
60 Hz simulation, which makes the game reproducible in a headless test as well
as in a graphical Emacs.

## Capabilities

- Four original stages: a daylit plain, an underground corridor, a sky of
  floating platforms and a castle over lava. Each owns its map, enemy spawns,
  time limit and palette.
- Walking, running, held jumps, coyote time and jump buffering; block bumps
  release coins, mushrooms, fire flowers and stars.
- Goombas squash, koopas turn into kickable shells, fireballs and stomps work,
  and lava, pits and the level clock each end a life.
- Character-grid art: one world block is four characters wide and two text rows
  tall, bottom aligned. Adjacent blocks join into one border, and the two halves
  of a pipe form one rim without a seam.
- A camera that scrolls in single character cells and keeps the player a third
  of the way in; actors keep their offset inside their block, so walking does
  not jump a whole block at a time.
- A HUD with score, coins, world, time, power badge and lives, plus title,
  pause, settings, level-select and result dialogs.
- Best score and unlocked stages persist between sessions.

## Prerequisites

| Requirement | Why | Check |
| --- | --- | --- |
| Emacs 29.1 or newer | the ETAF runtime | `emacs --version` |
| `ecss`, `ebox`, `etaf`, `etaf-ui` | the framework and catalog components | every root entry is on `load-path` |

No external game engine, database or network service is used.

## Installation

```sh
git clone https://github.com/emacs-taf/ecss.git
git clone https://github.com/emacs-taf/ebox.git
git clone https://github.com/emacs-taf/etaf.git
git clone https://github.com/emacs-taf/etaf-ui.git
git clone https://github.com/emacs-taf/etaf-mario.git
```

Add every provider root and this repository to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ui")
(add-to-list 'load-path "/path/to/etaf-mario")
(require 'etaf-mario)

(global-set-key (kbd "C-c m") #'etaf-mario-open)
```

`M-x etaf-mario-open` opens the game on a title screen over a paused stage; the
optional prefix argument is a zero-based stage index.

## Keys

| Input | Action |
| --- | --- |
| `←` / `→` | Walk; hold with `X` to run |
| `Z` | Jump; hold for a higher jump |
| `X` | Run, or throw a fireball once Mario has the fire flower |
| `↓` | Duck as big Mario |
| `P` | Pause or resume |
| `R` | Restart the current stage |
| `S` | Settings (frame rate, jump feel, light or dark palette) |
| `T` | Switch the light and dark palette |
| `F1` / `?` | Searchable help with the effective keys |
| `Q` | Quit |

## Configuration

| Variable | Meaning |
| --- | --- |
| `etaf-mario-appearance` | Initial palette: `auto` (follow the frame), `light` or `dark` |
| `etaf-mario-frame-rate` | Canvas refresh rate for new games: 30 (default) or 60 |
| `etaf-mario-jump-feel` | Jump height for new games: `normal`, `high` or `low` |
| `etaf-mario-progress-file` | File remembering the best score and unlocked stages |

## Checks

```sh
make check   # structure, compilation, API and headless behavior scenarios
```

The headless scenarios drive the deterministic world, parse every bundled
level, and assert the rendered characters row by row; they do not compare
screenshots. The real GUI acceptance recipe is in
[docs/architecture.md](docs/architecture.md).

## Documentation

- [Architecture](docs/architecture.md) — responsibilities, data flow,
  invariants and GUI acceptance.
- [Package entry](etaf-mario.el) — the supported API inventory.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE).
