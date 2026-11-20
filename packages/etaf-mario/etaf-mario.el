;;; -*- lexical-binding: t; -*-
;;; etaf-mario.el --- A text-mode Super Mario platformer for Emacs

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.3.0"))
;; Keywords: games
;; URL: https://github.com/emacs-taf/etaf-mario

;;; Commentary:
;; Super Mario is a side-scrolling platformer built entirely from Emacs text.
;; The world is simulated at a fixed 60 Hz and drawn as an 8-pixel block
;; grid: one world block is four text cells wide and two text rows tall, and
;; every element -- brick, question block, pipe, coin, enemy, Mario -- is its
;; own little character picture aligned to the bottom of its block.  Elements
;; wear faces but never paint a scene background, so the buffer's own theme
;; background shows through.  Only the canvas rows that changed are
;; republished, and the HUD counters use the same retained Host boundary, so a
;; running game does not rebuild the application.
;;
;; The campaign has four original stages; every stage owns its tiles, enemy
;; spawns, time limit and palette.  Mario walks, runs and jumps with a held
;; jump; blocks release coins, mushrooms, fire flowers and stars; goombas
;; squash, koopas become kickable shells, and lava, pits and the clock can end
;; a life.  Scores, coins, lives, best score and unlocked stages persist.
;;
;; The application requires the framework roots of `etaf', `etaf-ui', `ebox'
;; and `ecss' on `load-path' beside its own repository.  Load this package and
;; add this repository root to `load-path'; the internal modules below lisp/
;; are not a consumer surface.
;;
;; Function: etaf-mario-open (&optional level)
;;;###autoload (autoload 'etaf-mario-open "etaf-mario" nil t)
;; Open or reselect the game buffer and return it.  LEVEL is an optional
;; zero-based campaign index; omitted starts at the first stage.  Opening
;; mounts the title menu over a paused stage, so no clock runs until the
;; player starts.  The buffer is reusable: calling again with an open game
;; selects it instead of starting another.
;;
;; Function: etaf-mario-close (&optional buffer-or-name)
;;;###autoload (autoload 'etaf-mario-close "etaf-mario" nil t)
;; Close the game in BUFFER-OR-NAME, by default the current buffer, and save
;; its best score and unlocked stages.  Releasing the buffer directly does the
;; same through the application close callback.
;;
;; Function: etaf-mario-doctor ()
;; Return a list of problems with the bundled campaign and its artwork, or nil
;; when everything is healthy.  It parses every level, checks that each
;; floating block leaves two empty rows above the surface below it, and checks
;; that every sprite character has a colour in every theme.  Each problem is a
;; plist whose :kind names the fault: level (:index :message), shelf
;; (:index :column :row) or sprite (:sprite :character).
;;
;; Variable: etaf-mario-levels
;; Bundled campaign definitions in play order.  Each is a plist carrying
;; :name, :theme, :time and :map, the list of block-map rows.  The map format
;; uses one character per 8x8 world block: `.` empty, `#` ground, `B` brick,
;; `?` coin block, `M` mushroom block, `W` fire-flower block, `S` star block,
;; `U` used block, `o` coin, `(` and `)` pipe top, `[` and `]` pipe body,
;; `C` castle stone, `L` lava, `=` bridge, `F` flagpole, `@` start and
;; `g`/`k` enemy spawns.  A floating block needs two empty rows below it, so a
;; level that leaves a one-row shelf is rejected by the parser.
;;
;; Function: etaf-mario-level-by-index (index)
;; Return the parsed level at campaign INDEX, wrapping around the campaign.
;; The result is a plist with :name, :theme, :time, :width, :height, :tiles
;; (a vector of tile symbols in row-major order), :items (a hash table of
;; block contents keyed by tile index), :spawns, :start and :flag.
;;
;; Function: etaf-mario-world-create (index &optional previous)
;; Return a world running level INDEX.  PREVIOUS, when given, carries :score,
;; :coins, :lives, :time, :big and :jump from the previous stage.  The world
;; is a deterministic 60 Hz simulation: the same input sequence always
;; produces the same state, so tests and tools can run it headless.
;;
;; Function: etaf-mario-world-step (world input)
;; Advance WORLD one fixed 1/60 second step under INPUT, a plist of `:left',
;; `:right', `:run', `:jump', `:jump-held', `:duck' and `:fire' booleans.
;; Tile collisions, block bumps, enemies, items, damage and the clock are
;; resolved in this step; the caller owns presentation and timing.
;;
;; Function: etaf-mario-world-snapshot (world)
;; Return WORLD's observable state as a plist: `:level-index', `:theme',
;; `:status' (playing, dying, cleared or gameover), `:score', `:coins',
;; `:lives', `:time', `:player' and `:entities'.  The player plist has `:x',
;; `:y', `:vx', `:vy', `:width', `:height', `:on-ground', `:big', `:fire',
;; `:star' and `:dead'; each entity plist has `:kind', `:x', `:y', `:width',
;; `:height', `:state' and `:direction'.  Coordinates are world pixels from
;; the top left of the stage.
;;
;; Function: etaf-mario-world-tile (world column row)
;; Return WORLD's tile symbol at block COLUMN and ROW.  Outside the side edges
;; is ground, above the top and below the bottom is empty.  Reading is always
;; safe; blocks the player bumps change in place.
;;
;; Function: etaf-mario-render-frame (world columns rows)
;; Compose WORLD into a text frame COLUMNS cells wide and ROWS rows tall.
;; Return `(CAMERA . ROWS)' where CAMERA is the first visible world cell and
;; ROWS is a list of propertized strings.  Every element is an ordinary text
;; character painted with a face; the scene background is left transparent so
;; the frame's own theme background shows through.  An actor keeps its pixel
;; offset inside its block, so the frame stays still during sub-block
;; movement.
;;
;; Variable: etaf-mario-appearance
;; Initial appearance of a new game: auto (default), light or dark.  Auto
;; follows the frame's background mode; a running game switches independently
;; with T or the settings dialog.
;;
;; Variable: etaf-mario-frame-rate
;; Canvas refresh rate for new games: 30 (default) or 60 frames per second.
;; The simulation always advances in 60 Hz steps; a lower rate only publishes
;; fewer frames.  The settings dialog changes the running game immediately.
;;
;; Variable: etaf-mario-jump-feel
;; Jump height of new games: normal (default), high or low.  It scales the
;; initial upward speed; holding the jump key still extends a jump.
;;
;; Variable: etaf-mario-progress-file
;; File remembering the best score and the highest unlocked stage.  A missing
;; or unreadable file starts a fresh record.

;;; Code:

;;;###autoload
(eval-and-compile
  (defconst etaf-mario--root
    (file-name-directory
     (or (and load-file-name
              (not (string-suffix-p ".eln" load-file-name))
              load-file-name)
         (bound-and-true-p byte-compile-current-file)
         (locate-library "etaf-mario")
         buffer-file-name))
    "Directory of this package entry, resolved when it is loaded.")
  (add-to-list 'load-path (expand-file-name "lisp" etaf-mario--root)))

(require 'etaf-mario-app)

(provide 'etaf-mario)
;;; etaf-mario.el ends here
