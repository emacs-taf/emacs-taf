;;; -*- lexical-binding: t; -*-
;;; etaf-tanks.el --- A Battle City-style tank game for Emacs

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.2.10
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-gamekit "0.2.0") (etaf-ui "0.1.0"))
;;; Commentary:
;; This game follows the rules of the 1985 arcade tank battle: defend the
;; eagle base at the bottom of the field, destroy every enemy tank of the
;; stage, and lose when the base falls or the last life is gone.  A headless
;; Godot world owns the rules, a fixed simulation clock and the renderer,
;; which draws flat vector art with soft lighting at the display's own
;; resolution; ETAF shows the changed lines of each frame, the stage select,
;; the battle HUD, the map editor and the settings.  Text frames get an
;; equivalent character grid.  The twenty stages and all art are original.
;;
;; Enemies are basic, fast, power (fast shells) and armored (four hits)
;; tanks; flashing carriers drop helmet, clock, shovel, star, grenade and
;; extra-tank bonuses.  Difficulty and the stage number raise enemy count on
;; the field, spawn rate, firing rate and armored upgrades.
;;
;; Maps are UTF-8 text files: an optional `name:' line, `enemies: B F P A'
;; (basic, fast, power and armored counts, 1-60 in total) and a `map:'
;; section of equal rows, 12-52 columns by 12-40 rows, where each character
;; is one quarter of a tank: . ground, # brick, @ steel, ~ water, * forest,
;; = ice, and 2x2 groups of H (the base), P (player start) and E (one to
;; four enemy spawns).  Lines starting with ; are comments.
;;
;; Variable: etaf-tanks-game
;; Inert game definition usable with etaf-gamekit-start. The bundled Godot
;; project is resolved from this application entry, not from GameKit. Each
;; instance owns an independent battlefield.  Its operations (begin, pause,
;; drive, fire, save, load and others) and its observation are described in
;; docs/manual.md under programmatic callers.
;;
;; Variable: etaf-tanks-appearance
;; Initial appearance of new instances: auto (default), light or dark. Auto
;; follows the opening frame's background mode. Each instance switches
;; independently with T or the settings without resetting the battle.
;;
;; Variable: etaf-tanks-difficulty
;; Initial difficulty: easy (five lives, fewer and slower enemies), normal
;; (default) or hard (more enemies on the field, faster fire, more armor).
;;
;; Variable: etaf-tanks-game-speed
;; Simulation speed factor from 0.5 to 2.0 (default 1.0) for every tank,
;; shell and timer.
;;
;; Variable: etaf-tanks-tank-speed
;; Speed factor from 0.5 to 2.0 (default 1.0) of the player's tank only.
;;
;; Variable: etaf-tanks-sensitivity
;; How long the tank keeps driving after an arrow key event: auto (default)
;; derives it from the system key repeat on macOS and otherwise uses
;; standard; sensitive stops sooner; smooth bridges slower repeats.
;;
;; Variable: etaf-tanks-drive-mode
;; hold (default) drives while an arrow is held; latch keeps driving after
;; one press, follows later arrows and stops only with X or Shift+arrow.
;;
;; Variable: etaf-tanks-frame-rate
;; Battlefield frames per second on graphic displays: 30 (default) or 60.
;; The simulation clock is unaffected, and frames answering drive, aim, fire
;; or pause keys are drawn on the next simulation step at either rate.
;;
;; Variable: etaf-tanks-board-size
;; Preferred battlefield block size on graphic displays: small, medium
;; (default) or large, 12, 16 or 20 pixels per block.  A window too small
;; for the preference uses smaller blocks, down to 10 pixels, then clips.
;;
;; Variable: etaf-tanks-map-directory
;; Directory listed under the custom tab and used to save edited maps.
;;
;; Variable: etaf-tanks-progress-file
;; File remembering cleared stages and best scores per difficulty.
;;
;; Function: etaf-tanks-create ()
;;;###autoload (autoload 'etaf-tanks-create "etaf-tanks" nil t)
;; Create and return an independent GameKit session without displaying it. The
;; caller owns display and lifecycle; pass the result to etaf-tanks-view and
;; release it with etaf-gamekit-close.
;;
;; Function: etaf-tanks-view (session)
;;;###autoload (autoload 'etaf-tanks-view "etaf-tanks" nil t)
;; Return the reactive View for SESSION, suitable for embedding in a host such
;; as an etaf-desktop window. The caller owns SESSION's display and lifecycle.
;; Leaving its focus subtree pauses a running battle without resetting it;
;; reentry does not resume. Delayed screen updates do not reclaim host focus.
;;
;; Function: etaf-tanks-doctor ()
;; Return capability facts for playing tanks.  The shape matches
;; `etaf-install-doctor': the simulation host and its rules come from
;; `etaf-gamekit', which is an ordinary package dependency, while the Godot
;; runtime must be installed before a battle can start.  The check follows
;; `etaf-gamekit-godot-program', and its remedy installs that runtime.
;;
;; Function: etaf-tanks-open ()
;;;###autoload (autoload 'etaf-tanks-open "etaf-tanks" nil t)
;; Start and display an independent instance at the stage select; return its
;; GameKit instance. Requires Godot installed by GameKit. Arrows choose a
;; stage and Return starts it; in battle arrows drive, Shift+arrows turn in
;; place, F fires and P pauses.  ? / F1 and the help button share searchable
;; modal help inside the game buffer.  Opening help pauses a running battle;
;; closing it restores focus without resuming.  Battles are saved and
;; loaded only through explicit paths (C-s and C-o); a restore validates the
;; snapshot, resumes paused and clears in-flight shells and spawns.
;;
;; Function: etaf-tanks-close (&optional instance)
;;;###autoload (autoload 'etaf-tanks-close "etaf-tanks" nil t)
;; Close INSTANCE and its buffer. Omitted uses the current tank battle buffer.
;; No automatic save is performed; campaign progress is already recorded.
;;
;;; Code:
(require 'etaf-gamekit)
(require 'etaf-ui)
(defgroup etaf-tanks nil "Tank battle in Emacs." :group 'games)
(defcustom etaf-tanks-appearance 'auto
  "Initial appearance of new tank battles."
  :type '(choice (const auto) (const light) (const dark)) :group 'etaf-tanks)
(defcustom etaf-tanks-difficulty 'normal
  "Initial difficulty of new tank battles."
  :type '(choice (const easy) (const normal) (const hard)) :group 'etaf-tanks)
(defcustom etaf-tanks-game-speed 1.0
  "Simulation speed factor, from 0.5 to 2.0."
  :type 'number :group 'etaf-tanks)
(defcustom etaf-tanks-tank-speed 1.0
  "Speed factor of the player's tank, from 0.5 to 2.0."
  :type 'number :group 'etaf-tanks)
(defcustom etaf-tanks-sensitivity 'auto
  "How long one arrow key event keeps the tank driving."
  :type '(choice (const auto) (const sensitive) (const standard) (const smooth)) :group 'etaf-tanks)
(defcustom etaf-tanks-drive-mode 'hold
  "Whether the tank drives while an arrow is held or keeps driving after a press."
  :type '(choice (const hold) (const latch)) :group 'etaf-tanks)
(defcustom etaf-tanks-frame-rate 30
  "Battlefield frames per second on graphic displays."
  :type '(choice (const 30) (const 60)) :group 'etaf-tanks)
(defcustom etaf-tanks-board-size 'medium
  "Preferred battlefield block size on graphic displays.
small, medium and large draw 12, 16 and 20 pixels per block; a window too
small for the preference uses smaller blocks, down to 10 pixels."
  :type '(choice (const small) (const medium) (const large)) :group 'etaf-tanks)
(defcustom etaf-tanks-map-directory (locate-user-emacs-file "etaf-tanks/maps/")
  "Directory of custom tank battle maps."
  :type 'directory :group 'etaf-tanks)
(defcustom etaf-tanks-progress-file (locate-user-emacs-file "etaf-tanks/progress.eld")
  "File recording cleared stages and best scores."
  :type 'file :group 'etaf-tanks)
(defun etaf-tanks-doctor ()
  "Return capability facts for playing tanks.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Nothing is installed or changed."
  (list :required
        (list (list "Godot runtime"
                    (and (stringp etaf-gamekit-godot-program)
                         (executable-find etaf-gamekit-godot-program))
                    "Install it once with: M-x etaf-gamekit-install-godot"))
        :optional nil))
(defconst etaf-tanks--directory
  (file-name-directory (or load-file-name buffer-file-name)))
;; Installed archives compile each module separately, so `lisp' must be on
;; `load-path' while the byte compiler runs, not only when this entry loads.
;; `byte-compile-current-file` names the file being compiled; `load-file-name`
;; can still name the script that started the installation.
;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or (bound-and-true-p byte-compile-current-file)
                                      load-file-name
                                      buffer-file-name)))))
(let ((load-path (cons (expand-file-name "lisp" etaf-tanks--directory) load-path)))
  (require 'etaf-tanks-theme)
  (require 'etaf-tanks-maps)
  (require 'etaf-tanks-model)
  (require 'etaf-tanks-board)
  (require 'etaf-tanks-editor)
  (require 'etaf-tanks-views)
  (require 'etaf-tanks-app))
(provide 'etaf-tanks)
;;; etaf-tanks.el ends here
