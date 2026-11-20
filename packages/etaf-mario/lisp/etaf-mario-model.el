;;; -*- lexical-binding: t; -*-
;;; etaf-mario-model.el --- Deterministic platform simulation

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The world owns tiles, entities, the player and the running counters.  One
;; step advances exactly one fixed simulation interval, so a scripted input
;; sequence reproduces the same outcome on every run and in a headless test.
;; Input timing, rendering and the display loop live outside this module.

;;; Code:

(require 'cl-lib)
(require 'etaf-mario-levels)

(defconst etaf-mario-model-step (/ 1.0 60)
  "Fixed simulation interval in seconds.")

(defconst etaf-mario-model-tile 8
  "Width and height of one world block in pixels.")

(defconst etaf-mario-model-walk-speed 62.0
  "Fastest walking speed in pixels per second.")

(defconst etaf-mario-model-run-speed 108.0
  "Fastest running speed in pixels per second.")

(defconst etaf-mario-model-accel 420.0
  "Horizontal acceleration toward the intended speed.")

(defconst etaf-mario-model-friction 460.0
  "Horizontal deceleration without input.")

(defconst etaf-mario-model-gravity 1150.0
  "Downward acceleration in pixels per second squared.")

(defconst etaf-mario-model-hold-gravity 780.0
  "Gravity while a jump key is held and the player still rises.")

(defconst etaf-mario-model-jump-speed 250.0
  "Upward speed given by a jump.")

(defconst etaf-mario-model-max-fall 340.0
  "Terminal falling speed.")

(defconst etaf-mario-model-coyote 0.08
  "Seconds after leaving a ledge when a jump still starts.")

(defconst etaf-mario-model-jump-buffer 0.10
  "Seconds a jump request stays valid before landing.")

(defconst etaf-mario-model-time-tick 0.4
  "Seconds of play per unit of the level clock.")

(cl-defstruct (etaf-mario--player (:constructor etaf-mario--player-create))
  "The player state of one stage."
  x y vx vy width height facing on-ground ducking big-p fire-p
  invulnerable star jump-hold jump-buffer coyote
  dead dead-timer fire-cooldown)

(cl-defstruct (etaf-mario--entity (:constructor etaf-mario--entity-create))
  "One moving object owned by the stage."
  kind x y vx vy width height direction frame timer state)

(cl-defstruct (etaf-mario--world (:constructor etaf-mario--world-create))
  "One running stage."
  level index theme width height
  tiles items
  player entities
  score coins lives time time-acc
  status status-timer
  events jump-scale)

;;; Geometry helpers

(defun etaf-mario--clamp (value low high)
  "Return VALUE limited to LOW and HIGH."
  (max low (min high value)))

(defun etaf-mario--toward (value target amount)
  "Move VALUE toward TARGET by at most AMOUNT."
  (cond ((< value target) (min target (+ value amount)))
        ((> value target) (max target (- value amount)))
        (t value)))

(defun etaf-mario--overlap-p (a b)
  "Return non-nil when the axis-aligned bounds of A and B intersect."
  (and (< (plist-get a :x) (+ (plist-get b :x) (plist-get b :w)))
       (> (+ (plist-get a :x) (plist-get a :w)) (plist-get b :x))
       (< (plist-get a :y) (+ (plist-get b :y) (plist-get b :h)))
       (> (+ (plist-get a :y) (plist-get a :h)) (plist-get b :y))))

(defun etaf-mario--entity-bounds (entity)
  "Return ENTITY bounds as a plist."
  (list :x (etaf-mario--entity-x entity)
        :y (etaf-mario--entity-y entity)
        :w (etaf-mario--entity-width entity)
        :h (etaf-mario--entity-height entity)))

(defun etaf-mario--player-bounds (player)
  "Return PLAYER bounds as a plist."
  (list :x (etaf-mario--player-x player)
        :y (etaf-mario--player-y player)
        :w (etaf-mario--player-width player)
        :h (etaf-mario--player-height player)))

;;; World access

(defun etaf-mario-world-player (world)
  "Return WORLD's player."
  (etaf-mario--world-player world))

(defun etaf-mario-world-entities (world)
  "Return WORLD's live entities."
  (etaf-mario--world-entities world))

(defun etaf-mario-world-status (world)
  "Return WORLD status: playing, dying, cleared or gameover."
  (etaf-mario--world-status world))

(defun etaf-mario-world-level (world)
  "Return WORLD's parsed level plist."
  (etaf-mario--world-level world))

(defun etaf-mario-world-theme (world)
  "Return WORLD's artwork theme."
  (etaf-mario--world-theme world))

(defun etaf-mario-world-score (world)
  "Return WORLD's running score."
  (etaf-mario--world-score world))

(defun etaf-mario-world-coins (world)
  "Return WORLD's coin count."
  (etaf-mario--world-coins world))

(defun etaf-mario-world-lives (world)
  "Return WORLD's remaining lives."
  (etaf-mario--world-lives world))

(defun etaf-mario-world-time (world)
  "Return WORLD's remaining level time."
  (etaf-mario--world-time world))

(defun etaf-mario-world-index (world)
  "Return WORLD's campaign level index."
  (etaf-mario--world-index world))

(defun etaf-mario-world-width (world)
  "Return WORLD width in pixels."
  (etaf-mario--world-width world))

(defun etaf-mario-world-height (world)
  "Return WORLD height in pixels."
  (etaf-mario--world-height world))

(defun etaf-mario-world-event (world)
  "Pop one pending event plist from WORLD, or return nil."
  (pop (etaf-mario--world-events world)))

(defun etaf-mario-world-tile (world column row)
  "Return WORLD's tile at block COLUMN and ROW."
  (etaf-mario-level-tile (etaf-mario--world-level world) column row))

(defun etaf-mario-world-set-tile (world column row tile)
  "Set WORLD's block at COLUMN and ROW to TILE."
  (let* ((level (etaf-mario--world-level world))
         (width (plist-get level :width))
         (height (plist-get level :height)))
    (when (and (>= column 0) (< column width) (>= row 0) (< row height))
      (aset (plist-get level :tiles) (+ (* row width) column) tile))))

(defun etaf-mario-world-flag-column (world)
  "Return WORLD's flagpole block column, or nil."
  (plist-get (etaf-mario--world-level world) :flag))

(defun etaf-mario-world-snapshot (world)
  "Return WORLD's observable state as a plist.
The plist carries `:level-index', `:theme', `:status', `:score', `:coins',
`:lives', `:time', `:player' and `:entities'.  The player plist has `:x',
`:y', `:vx', `:vy', `:width', `:height', `:on-ground', `:big', `:fire',
`:star' and `:dead'; every entity plist has `:kind', `:x', `:y', `:width',
`:height', `:state' and `:direction'.  Coordinates are world pixels with
the origin at the top left of the stage."
  (let* ((player (etaf-mario--world-player world))
         (state (lambda (entity)
                  (list :kind (etaf-mario--entity-kind entity)
                        :x (etaf-mario--entity-x entity)
                        :y (etaf-mario--entity-y entity)
                        :width (etaf-mario--entity-width entity)
                        :height (etaf-mario--entity-height entity)
                        :state (etaf-mario--entity-state entity)
                        :direction (etaf-mario--entity-direction entity)))))
    (list :level-index (etaf-mario--world-index world)
          :theme (etaf-mario--world-theme world)
          :status (etaf-mario--world-status world)
          :score (etaf-mario--world-score world)
          :coins (etaf-mario--world-coins world)
          :lives (etaf-mario--world-lives world)
          :time (etaf-mario--world-time world)
          :player (list :x (etaf-mario--player-x player)
                        :y (etaf-mario--player-y player)
                        :vx (etaf-mario--player-vx player)
                        :vy (etaf-mario--player-vy player)
                        :width (etaf-mario--player-width player)
                        :height (etaf-mario--player-height player)
                        :on-ground (and (etaf-mario--player-on-ground player) t)
                        :big (and (etaf-mario--player-big-p player) t)
                        :fire (and (etaf-mario--player-fire-p player) t)
                        :star (and (> (etaf-mario--player-star player) 0.0) t)
                        :dead (and (etaf-mario--player-dead player) t))
          :entities (mapcar state (etaf-mario--world-entities world)))))

(defun etaf-mario--world-item (world column row)
  "Return the item hidden in WORLD's block at COLUMN and ROW."
  (gethash (+ (* row (plist-get (etaf-mario--world-level world) :width)) column)
           (etaf-mario--world-items world)))

;;; Creation

(defun etaf-mario--spawn-entity (world kind x y)
  "Add WORLD entity of KIND with its top left at X and Y."
  (let ((entity
         (pcase kind
           ('goomba (etaf-mario--entity-create
                     :kind 'goomba :x x :y y :vx -24.0 :vy 0.0 :width 8 :height 8
                     :direction -1 :frame 0 :timer 0.0 :state 'walking))
           ('koopa (etaf-mario--entity-create
                    :kind 'koopa :x x :y y :vx -20.0 :vy 0.0 :width 8 :height 12
                    :direction -1 :frame 0 :timer 0.0 :state 'walking))
           (_ (etaf-mario--entity-create
               :kind kind :x x :y y :vx 0.0 :vy 0.0 :width 8 :height 8
               :direction 1 :state 'walking)))))
    (push entity (etaf-mario--world-entities world))
    entity))

(defun etaf-mario--entity-top-for-cell (world column row height)
  "Return the top Y for a HEIGHT entity spawned in COLUMN and ROW."
  (let* ((cell-top (* row etaf-mario-model-tile))
         (feet (* (1+ row) etaf-mario-model-tile)))
    (if (etaf-mario-level-solid-p (etaf-mario-world-tile world column (1+ row)))
        (- feet height)
      (- cell-top height))))

(defun etaf-mario--place-player (world)
  "Place WORLD's player at the level start."
  (let* ((start (plist-get (etaf-mario--world-level world) :start))
         (player (etaf-mario--world-player world)))
    (setf (etaf-mario--player-x player) (* (car start) etaf-mario-model-tile)
          (etaf-mario--player-vx player) 0.0
          (etaf-mario--player-vy player) 0.0
          (etaf-mario--player-ducking player) nil
          (etaf-mario--player-on-ground player) nil
          (etaf-mario--player-jump-hold player) nil
          (etaf-mario--player-jump-buffer player) 0.0
          (etaf-mario--player-coyote player) 0.0
          (etaf-mario--player-invulnerable player) 0.0
          (etaf-mario--player-star player) 0.0
          (etaf-mario--player-fire-cooldown player) 0.0
          (etaf-mario--player-dead player) nil
          (etaf-mario--player-dead-timer player) 0.0)
    (unless (etaf-mario--player-big-p player)
      (setf (etaf-mario--player-height player) 8
            (etaf-mario--player-fire-p player) nil))
    (setf (etaf-mario--player-y player)
          (- (* (1+ (cdr start)) etaf-mario-model-tile)
             (etaf-mario--player-height player)))))

(defun etaf-mario--reset-entities (world)
  "Remove every entity and respawn the level's enemies in WORLD."
  (setf (etaf-mario--world-entities world) nil)
  (dolist (spawn (plist-get (etaf-mario--world-level world) :spawns))
    (let* ((column (plist-get spawn :column))
           (row (plist-get spawn :row))
           (kind (plist-get spawn :kind))
           (height (if (eq kind 'koopa) 12 8)))
      (etaf-mario--spawn-entity
       world kind (* column etaf-mario-model-tile)
       (etaf-mario--entity-top-for-cell world column row height)))))

(defun etaf-mario--reset-stage (world)
  "Restore WORLD's level tiles, player and enemies."
  (let ((level (etaf-mario-level-by-index (etaf-mario--world-index world))))
    (setf (etaf-mario--world-level world) level
          (etaf-mario--world-items world) (plist-get level :items)
          (etaf-mario--world-theme world) (plist-get level :theme)
          (etaf-mario--world-time world) (plist-get level :time)
          (etaf-mario--world-time-acc world) 0.0
          (etaf-mario--world-status world) 'playing
          (etaf-mario--world-status-timer world) 0.0
          (etaf-mario--world-events world) nil))
  (etaf-mario--reset-entities world)
  (etaf-mario--place-player world))

(defun etaf-mario-world-create (index &optional previous)
  "Create a world running level INDEX.
PREVIOUS, when given, supplies the running score, coins and lives."
  (let* ((level (etaf-mario-level-by-index index))
         (big (and previous (plist-get previous :big)))
         (world (etaf-mario--world-create
                 :level level
                 :index index
                 :theme (plist-get level :theme)
                 :width (* (plist-get level :width) etaf-mario-model-tile)
                 :height (* (plist-get level :height) etaf-mario-model-tile)
                 :items (plist-get level :items)
                 :score (or (plist-get previous :score) 0)
                 :coins (or (plist-get previous :coins) 0)
                 :lives (or (plist-get previous :lives) 3)
                 :time (or (plist-get previous :time) (plist-get level :time))
                 :time-acc 0.0
                 :entities nil
                 :events nil
                 :status 'playing
                 :status-timer 0.0
                 :jump-scale (or (plist-get previous :jump) 1.0)))
         (player (etaf-mario--player-create
                  :x 0.0 :y 0.0 :vx 0.0 :vy 0.0
                  :width 6 :height (if big 16 8)
                  :facing 1 :on-ground nil :ducking nil
                  :big-p (and big t) :fire-p nil
                  :invulnerable 0.0 :star 0.0
                  :dead nil :dead-timer 0.0
                  :jump-hold nil :jump-buffer 0.0 :coyote 0.0
                  :fire-cooldown 0.0)))
    (setf (etaf-mario--world-player world) player)
    (etaf-mario--reset-stage world)
    world))

;;; Tile queries

(defun etaf-mario--collides (world x y width height)
  "Return non-nil when a WIDTH by HEIGHT box at X and Y overlaps a solid tile."
  (let ((left (floor (/ x etaf-mario-model-tile)))
        (right (floor (/ (+ x width -0.01) etaf-mario-model-tile)))
        (top (floor (/ y etaf-mario-model-tile)))
        (bottom (floor (/ (+ y height -0.01) etaf-mario-model-tile)))
        (hit nil))
    (while (and (not hit) (<= left right))
      (let ((row top))
        (while (and (not hit) (<= row bottom))
          (when (etaf-mario-level-solid-p (etaf-mario-world-tile world left row))
            (setq hit t))
          (setq row (1+ row))))
      (setq left (1+ left)))
    hit))

;;; Movers

(defun etaf-mario--move-entity-x (world entity dx)
  "Move ENTITY horizontally by DX in WORLD.  Return non-nil on a wall."
  (let ((x (etaf-mario--entity-x entity))
        (y (etaf-mario--entity-y entity))
        (width (etaf-mario--entity-width entity))
        (height (etaf-mario--entity-height entity)))
    (if (or (zerop dx) (etaf-mario--collides world x y width height))
        nil
      (let ((target (+ x dx)))
        (if (etaf-mario--collides world target y width height)
            (progn
              (if (> dx 0)
                  (setf (etaf-mario--entity-x entity)
                        (- (* etaf-mario-model-tile
                              (floor (/ (+ target width -0.01) etaf-mario-model-tile)))
                           width))
                (setf (etaf-mario--entity-x entity)
                      (* etaf-mario-model-tile
                         (1+ (floor (/ target etaf-mario-model-tile))))))
              (setf (etaf-mario--entity-vx entity) 0.0)
              t)
          (setf (etaf-mario--entity-x entity) target)
          nil)))))

(defun etaf-mario--move-entity-y (world entity dy)
  "Move ENTITY vertically by DY in WORLD.
Return `(floor)' or `(ceiling)' when a tile stopped it."
  (let ((x (etaf-mario--entity-x entity))
        (y (etaf-mario--entity-y entity))
        (width (etaf-mario--entity-width entity))
        (height (etaf-mario--entity-height entity))
        (hits nil))
    (unless (zerop dy)
      (let ((target (+ y dy)))
        (cond
         ((etaf-mario--collides world x target width height)
          (if (> dy 0)
              (progn
                (setf (etaf-mario--entity-y entity)
                      (- (* etaf-mario-model-tile
                            (floor (/ (+ target height -0.01) etaf-mario-model-tile)))
                         height))
                (setf (etaf-mario--entity-vy entity) 0.0)
                (setq hits '(floor)))
            (setf (etaf-mario--entity-y entity)
                  (* etaf-mario-model-tile
                     (1+ (floor (/ target etaf-mario-model-tile)))))
            (setf (etaf-mario--entity-vy entity) 0.0)
            (setq hits '(ceiling))))
         (t (setf (etaf-mario--entity-y entity) target)))))
    hits))

(defun etaf-mario--move-player-x (world player dx)
  "Move PLAYER horizontally by DX in WORLD.  Return non-nil on a wall."
  (let ((x (etaf-mario--player-x player))
        (y (etaf-mario--player-y player))
        (width (etaf-mario--player-width player))
        (height (etaf-mario--player-height player)))
    (if (or (zerop dx) (etaf-mario--collides world x y width height))
        nil
      (let ((target (+ x dx)))
        (if (etaf-mario--collides world target y width height)
            (progn
              (if (> dx 0)
                  (setf (etaf-mario--player-x player)
                        (- (* etaf-mario-model-tile
                              (floor (/ (+ target width -0.01) etaf-mario-model-tile)))
                           width))
                (setf (etaf-mario--player-x player)
                      (* etaf-mario-model-tile
                         (1+ (floor (/ target etaf-mario-model-tile))))))
              (setf (etaf-mario--player-vx player) 0.0)
              t)
          (setf (etaf-mario--player-x player) target)
          nil)))))

(defun etaf-mario--move-player-y (world player dy)
  "Move PLAYER vertically by DY in WORLD.
Return `(floor)' or `(ceiling)' when a tile stopped it."
  (let ((x (etaf-mario--player-x player))
        (y (etaf-mario--player-y player))
        (width (etaf-mario--player-width player))
        (height (etaf-mario--player-height player))
        (hits nil))
    (unless (zerop dy)
      (let ((target (+ y dy)))
        (cond
         ((etaf-mario--collides world x target width height)
          (if (> dy 0)
              (progn
                (setf (etaf-mario--player-y player)
                      (- (* etaf-mario-model-tile
                            (floor (/ (+ target height -0.01) etaf-mario-model-tile)))
                         height))
                (setf (etaf-mario--player-vy player) 0.0)
                (setq hits '(floor)))
            (setf (etaf-mario--player-y player)
                  (* etaf-mario-model-tile
                     (1+ (floor (/ target etaf-mario-model-tile)))))
            (setf (etaf-mario--player-vy player) 0.0)
            (setq hits '(ceiling))))
         (t (setf (etaf-mario--player-y player) target)))))
    hits))

;;; Blocks

(defun etaf-mario--bump-enemies-at (world column row)
  "Flip enemies standing on top of block COLUMN and ROW."
  (let ((top (* row etaf-mario-model-tile)))
    (dolist (entity (etaf-mario--world-entities world))
      (when (and (memq (etaf-mario--entity-state entity) '(walking shell-still))
                 (< (abs (- (+ (etaf-mario--entity-y entity)
                               (etaf-mario--entity-height entity))
                            top))
                    2.0)
                 (< (abs (- (+ (etaf-mario--entity-x entity)
                               (/ (etaf-mario--entity-width entity) 2.0))
                           (* (+ column 0.5) etaf-mario-model-tile)))
                    8.0))
        (etaf-mario--kill-entity world entity :flip)))))

(defun etaf-mario--spawn-item (world kind x y)
  "Spawn item KIND at X and Y above a block."
  (let ((entity (etaf-mario--spawn-entity world kind x y)))
    (setf (etaf-mario--entity-state entity) 'emerging
          (etaf-mario--entity-vx entity) 0.0
          (etaf-mario--entity-vy entity) -34.0
          (etaf-mario--entity-timer entity) 0.45)
    entity))

(defun etaf-mario--hit-block (world column row)
  "Resolve a bump of the block at COLUMN and ROW from below."
  (let ((tile (etaf-mario-world-tile world column row))
        (x (* column etaf-mario-model-tile))
        (y (* row etaf-mario-model-tile)))
    (pcase tile
      ('question
       (let ((item (or (etaf-mario--world-item world column row) 'coin)))
         (etaf-mario-world-set-tile world column row 'used)
         (if (eq item 'coin)
             (progn
               (etaf-mario--award world :coin x y)
               (let ((pop (etaf-mario--spawn-entity world 'coin-pop x y)))
                 (setf (etaf-mario--entity-state pop) 'coin-pop
                       (etaf-mario--entity-vy pop) -130.0
                       (etaf-mario--entity-timer pop) 0.45)))
           (etaf-mario--spawn-item world item x (- y 8)))
         (etaf-mario--bump-enemies-at world column row)
         (push (list :type 'bump :x x :y y) (etaf-mario--world-events world))))
      ('brick
       (if (etaf-mario--player-big-p (etaf-mario--world-player world))
           (progn
             (etaf-mario-world-set-tile world column row 'empty)
             (dotimes (i 4)
               (let ((debris (etaf-mario--spawn-entity
                              world 'debris
                              (+ x (* (mod i 2) 4))
                              (+ y (* (/ i 2) 4)))))
                 (setf (etaf-mario--entity-vx debris) (if (= (% i 2) 0) -40.0 40.0)
                       (etaf-mario--entity-vy debris) (if (< i 2) -150.0 -90.0)
                       (etaf-mario--entity-timer debris) 1.2
                       (etaf-mario--entity-width debris) 4
                       (etaf-mario--entity-height debris) 4)))
             (etaf-mario--award world :brick x y))
         (etaf-mario--bump-enemies-at world column row)
         (push (list :type 'bump :x x :y y) (etaf-mario--world-events world))))
      (_ nil))))

(defun etaf-mario--award (world kind x y)
  "Award KIND's points at X and Y in WORLD."
  (pcase kind
    (:coin
     (cl-incf (etaf-mario--world-coins world))
     (when (>= (etaf-mario--world-coins world) 100)
       (cl-decf (etaf-mario--world-coins world) 100)
       (cl-incf (etaf-mario--world-lives world))
       (push (list :type 'one-up :x x :y y) (etaf-mario--world-events world)))
     (cl-incf (etaf-mario--world-score world) 200)
     (push (list :type 'coin :x x :y y) (etaf-mario--world-events world)))
    (:brick (cl-incf (etaf-mario--world-score world) 50))
    (:goomba (cl-incf (etaf-mario--world-score world) 100)
             (push (list :type 'stomp :x x :y y) (etaf-mario--world-events world)))
    (:koopa (cl-incf (etaf-mario--world-score world) 100)
            (push (list :type 'stomp :x x :y y) (etaf-mario--world-events world)))
    (:shell (cl-incf (etaf-mario--world-score world) 200)
            (push (list :type 'stomp :x x :y y) (etaf-mario--world-events world)))))

;;; Damage

(defun etaf-mario--kill-entity (_world entity how)
  "Remove ENTITY from WORLD, animating it according to HOW."
  (setf (etaf-mario--entity-state entity)
        (pcase how
          (:flip 'flipped)
          (:squash 'squashed)
          (_ 'gone)))
  (pcase how
    (:flip (setf (etaf-mario--entity-vy entity) -120.0
                 (etaf-mario--entity-timer entity) 1.0))
    (:squash (setf (etaf-mario--entity-vx entity) 0.0
                   (etaf-mario--entity-timer entity) 0.35)))
  entity)

(defun etaf-mario--damage-player (world)
  "Damage WORLD's player: shrink, or die."
  (let ((player (etaf-mario--world-player world)))
    (cond
     ((> (etaf-mario--player-star player) 0.0) nil)
     ((> (etaf-mario--player-invulnerable player) 0.0) nil)
     ((etaf-mario--player-big-p player)
      (setf (etaf-mario--player-big-p player) nil
            (etaf-mario--player-fire-p player) nil
            (etaf-mario--player-height player) 8
            (etaf-mario--player-y player) (+ (etaf-mario--player-y player) 8)
            (etaf-mario--player-invulnerable player) 1.6
            (etaf-mario--player-ducking player) nil)
      (push (list :type 'shrink) (etaf-mario--world-events world)))
     (t (etaf-mario--kill-player world)))))

(defun etaf-mario--kill-player (world)
  "Start WORLD's death sequence."
  (let ((player (etaf-mario--world-player world)))
    (unless (etaf-mario--player-dead player)
      (setf (etaf-mario--player-dead player) t
            (etaf-mario--player-dead-timer player) 1.8
            (etaf-mario--player-vy player) -190.0
            (etaf-mario--player-vx player) 0.0
            (etaf-mario--world-status world) 'dying
            (etaf-mario--world-status-timer world) 1.9)
      (push (list :type 'death) (etaf-mario--world-events world)))))

;;; Player

(defun etaf-mario--player-power (player)
  "Return PLAYER's power symbol: small, big, fire or star."
  (cond ((> (etaf-mario--player-star player) 0.0) 'star)
        ((and (etaf-mario--player-big-p player)
              (etaf-mario--player-fire-p player)) 'fire)
        ((etaf-mario--player-big-p player) 'big)
        (t 'small)))

(defun etaf-mario--player-jump (world)
  "Start a jump for WORLD's player."
  (let ((player (etaf-mario--world-player world)))
    (setf (etaf-mario--player-vy player)
          (- (* etaf-mario-model-jump-speed
                (or (etaf-mario--world-jump-scale world) 1.0)))
          (etaf-mario--player-on-ground player) nil
          (etaf-mario--player-jump-hold player) t
          (etaf-mario--player-jump-buffer player) 0.0
          (etaf-mario--player-coyote player) 0.0)
    (push (list :type 'jump) (etaf-mario--world-events world))))

(defun etaf-mario--player-fire (world)
  "Spawn a fireball from WORLD's player when the ability is ready."
  (let* ((player (etaf-mario--world-player world))
         (ready (and (etaf-mario--player-fire-p player)
                     (<= (etaf-mario--player-fire-cooldown player) 0.0)
                     (< (cl-count-if (lambda (entity)
                                       (eq (etaf-mario--entity-kind entity) 'fireball))
                                     (etaf-mario--world-entities world))
                        2))))
    (when ready
      (setf (etaf-mario--player-fire-cooldown player) 0.28)
      (let ((ball (etaf-mario--spawn-entity
                   world 'fireball
                   (+ (etaf-mario--player-x player)
                      (if (> (etaf-mario--player-facing player) 0) 6 0))
                   (+ (etaf-mario--player-y player) 3))))
        (setf (etaf-mario--entity-vx ball)
              (* 190.0 (etaf-mario--player-facing player))
              (etaf-mario--entity-vy ball) 40.0
              (etaf-mario--entity-width ball) 6
              (etaf-mario--entity-height ball) 6
              (etaf-mario--entity-state ball) 'flying
              (etaf-mario--entity-timer ball) 3.0)
        (push (list :type 'fire) (etaf-mario--world-events world))))))

(defun etaf-mario--step-player (world input dt)
  "Advance WORLD's player by DT under INPUT."
  (let* ((player (etaf-mario--world-player world))
         (dead (etaf-mario--player-dead player))
         (duck (and (not dead)
                    (etaf-mario--player-big-p player)
                    (plist-get input :duck)
                    (etaf-mario--player-on-ground player)))
         (left (and (not dead) (plist-get input :left)))
         (right (and (not dead) (plist-get input :right)))
         (direction (cond ((and left right) 0) (left -1) (right 1) (t 0)))
         (run (plist-get input :run))
         (max-speed (if run etaf-mario-model-run-speed etaf-mario-model-walk-speed))
         (accel (if run (* 1.15 etaf-mario-model-accel) etaf-mario-model-accel)))
    (when (and duck (not (etaf-mario--player-ducking player)))
      (setf (etaf-mario--player-y player) (+ (etaf-mario--player-y player) 8)
            (etaf-mario--player-height player) 8))
    (when (and (not duck) (etaf-mario--player-ducking player)
               (not (etaf-mario--collides
                     world (etaf-mario--player-x player)
                     (- (etaf-mario--player-y player) 8)
                     (etaf-mario--player-width player) 16)))
      (setf (etaf-mario--player-y player) (- (etaf-mario--player-y player) 8)
            (etaf-mario--player-height player) 16))
    (setf (etaf-mario--player-ducking player) (and duck t))
    (if (or duck (zerop direction))
        (setf (etaf-mario--player-vx player)
              (etaf-mario--toward (etaf-mario--player-vx player) 0.0
                                  (* etaf-mario-model-friction dt)))
      (let* ((current (etaf-mario--player-vx player))
             (target (* direction max-speed))
             (rate (if (= (cl-signum current) (- direction)) (* 2.0 accel) accel)))
        (setf (etaf-mario--player-facing player) direction
              (etaf-mario--player-vx player)
              (etaf-mario--toward current target (* rate dt)))))
    (when (and (not dead) (plist-get input :jump))
      (if (or (etaf-mario--player-on-ground player)
              (> (etaf-mario--player-coyote player) 0.0))
          (etaf-mario--player-jump world)
        (setf (etaf-mario--player-jump-buffer player) etaf-mario-model-jump-buffer)))
    (when (and (> (etaf-mario--player-jump-buffer player) 0.0)
               (or (etaf-mario--player-on-ground player)
                   (> (etaf-mario--player-coyote player) 0.0)))
      (etaf-mario--player-jump world))
    (when (and (etaf-mario--player-jump-hold player)
               (not (plist-get input :jump-held)))
      (setf (etaf-mario--player-jump-hold player) nil))
    (when (>= (etaf-mario--player-vy player) 0.0)
      (setf (etaf-mario--player-jump-hold player) nil))
    (let ((gravity (if (etaf-mario--player-jump-hold player)
                       etaf-mario-model-hold-gravity
                       etaf-mario-model-gravity)))
      (setf (etaf-mario--player-vy player)
            (min etaf-mario-model-max-fall
                 (+ (etaf-mario--player-vy player) (* gravity dt)))))
    (let ((hits nil))
      (etaf-mario--move-player-x world player (* (etaf-mario--player-vx player) dt))
      (setq hits (etaf-mario--move-player-y world player (* (etaf-mario--player-vy player) dt)))
      (setf (etaf-mario--player-on-ground player)
            (and (memq 'floor hits) t))
      (when (memq 'ceiling hits)
        (let ((column (floor (/ (+ (etaf-mario--player-x player)
                                   (/ (etaf-mario--player-width player) 2.0))
                               etaf-mario-model-tile)))
              (row (1- (floor (/ (etaf-mario--player-y player)
                                 etaf-mario-model-tile)))))
          (etaf-mario--hit-block world column row)))
      (when (etaf-mario--player-on-ground player)
        (setf (etaf-mario--player-coyote player) etaf-mario-model-coyote))
      (unless (etaf-mario--player-on-ground player)
        (setf (etaf-mario--player-coyote player)
              (max 0.0 (- (etaf-mario--player-coyote player) dt)))))
    (setf (etaf-mario--player-jump-buffer player)
          (max 0.0 (- (etaf-mario--player-jump-buffer player) dt)))
    (setf (etaf-mario--player-invulnerable player)
          (max 0.0 (- (etaf-mario--player-invulnerable player) dt)))
    (setf (etaf-mario--player-fire-cooldown player)
          (max 0.0 (- (etaf-mario--player-fire-cooldown player) dt)))
    (when (> (etaf-mario--player-star player) 0.0)
      (setf (etaf-mario--player-star player)
            (max 0.0 (- (etaf-mario--player-star player) dt))))
    (when (and (not dead) (plist-get input :fire))
      (etaf-mario--player-fire world))))

;;; Entities

(defun etaf-mario--apply-gravity (entity dt)
  "Add DT worth of gravity to ENTITY."
  (setf (etaf-mario--entity-vy entity)
        (min etaf-mario-model-max-fall
             (+ (etaf-mario--entity-vy entity) (* etaf-mario-model-gravity dt)))))

(defun etaf-mario--walk-entity (world entity dt)
  "Walk ENTITY forward in WORLD, turning at walls."
  (etaf-mario--apply-gravity entity dt)
  (when (etaf-mario--move-entity-x world entity (* (etaf-mario--entity-vx entity) dt))
    (setf (etaf-mario--entity-vx entity) (- (etaf-mario--entity-vx entity))
          (etaf-mario--entity-direction entity)
          (- (etaf-mario--entity-direction entity))))
  (etaf-mario--move-entity-y world entity (* (etaf-mario--entity-vy entity) dt)))

(defun etaf-mario--step-entity (world entity dt)
  "Advance one ENTITY by DT in WORLD."
  (pcase (etaf-mario--entity-state entity)
    ((or 'walking 'flying 'shell-moving)
     (pcase (etaf-mario--entity-kind entity)
       ('fireball
        (cl-decf (etaf-mario--entity-timer entity) dt)
        (setf (etaf-mario--entity-vy entity)
              (min etaf-mario-model-max-fall
                   (+ (etaf-mario--entity-vy entity) (* 900.0 dt))))
        (when (etaf-mario--move-entity-x world entity (* (etaf-mario--entity-vx entity) dt))
          (setf (etaf-mario--entity-state entity) 'gone))
        (when (memq 'floor (etaf-mario--move-entity-y
                            world entity (* (etaf-mario--entity-vy entity) dt)))
          (setf (etaf-mario--entity-vy entity) -150.0))
        (when (<= (etaf-mario--entity-timer entity) 0.0)
          (setf (etaf-mario--entity-state entity) 'gone)))
       ('shell
        (etaf-mario--apply-gravity entity dt)
        (when (etaf-mario--move-entity-x world entity (* (etaf-mario--entity-vx entity) dt))
          (setf (etaf-mario--entity-vx entity) (- (etaf-mario--entity-vx entity))))
        (etaf-mario--move-entity-y world entity (* (etaf-mario--entity-vy entity) dt)))
       ('star
        (etaf-mario--apply-gravity entity dt)
        (when (etaf-mario--move-entity-x world entity (* (etaf-mario--entity-vx entity) dt))
          (setf (etaf-mario--entity-vx entity) (- (etaf-mario--entity-vx entity))))
        (when (memq 'floor (etaf-mario--move-entity-y
                            world entity (* (etaf-mario--entity-vy entity) dt)))
          (setf (etaf-mario--entity-vy entity) -180.0)))
       (_
        (etaf-mario--walk-entity world entity dt)
        (setf (etaf-mario--entity-frame entity)
              (mod (1+ (or (etaf-mario--entity-frame entity) 0)) 2)))))
    ('shell-still
     (etaf-mario--apply-gravity entity dt)
     (etaf-mario--move-entity-y world entity (* (etaf-mario--entity-vy entity) dt)))
    ('emerging
     (cl-decf (etaf-mario--entity-timer entity) dt)
     (setf (etaf-mario--entity-y entity)
           (+ (etaf-mario--entity-y entity) (* (etaf-mario--entity-vy entity) dt)))
     (when (<= (etaf-mario--entity-timer entity) 0.0)
       (setf (etaf-mario--entity-state entity) 'walking
             (etaf-mario--entity-vy entity) 0.0
             (etaf-mario--entity-vx entity)
             (pcase (etaf-mario--entity-kind entity)
               ((or 'mushroom 'one-up) 42.0)
               ('star 58.0)
               (_ 0.0)))))
    ('flipped
     (cl-decf (etaf-mario--entity-timer entity) dt)
     (setf (etaf-mario--entity-vy entity)
           (min etaf-mario-model-max-fall
                (+ (etaf-mario--entity-vy entity) (* etaf-mario-model-gravity dt)))
           (etaf-mario--entity-y entity)
           (+ (etaf-mario--entity-y entity) (* (etaf-mario--entity-vy entity) dt)))
     (when (<= (etaf-mario--entity-timer entity) 0.0)
       (setf (etaf-mario--entity-state entity) 'gone)))
    ('squashed
     (cl-decf (etaf-mario--entity-timer entity) dt)
     (when (<= (etaf-mario--entity-timer entity) 0.0)
       (setf (etaf-mario--entity-state entity) 'gone)))
    ('debris
     (cl-decf (etaf-mario--entity-timer entity) dt)
     (etaf-mario--apply-gravity entity dt)
     (setf (etaf-mario--entity-x entity)
           (+ (etaf-mario--entity-x entity) (* (etaf-mario--entity-vx entity) dt))
           (etaf-mario--entity-y entity)
           (+ (etaf-mario--entity-y entity) (* (etaf-mario--entity-vy entity) dt)))
     (when (<= (etaf-mario--entity-timer entity) 0.0)
       (setf (etaf-mario--entity-state entity) 'gone)))
    ('coin-pop
     (cl-decf (etaf-mario--entity-timer entity) dt)
     (setf (etaf-mario--entity-y entity)
           (+ (etaf-mario--entity-y entity) (* (etaf-mario--entity-vy entity) dt)))
     (when (<= (etaf-mario--entity-timer entity) 0.0)
       (setf (etaf-mario--entity-state entity) 'gone)))
    (_ nil)))

;;; Interaction

(defun etaf-mario--transform-shell (world entity state)
  "Turn ENTITY into a shell in STATE, keeping its feet in place."
  (ignore world)
  (setf (etaf-mario--entity-kind entity) 'shell
        (etaf-mario--entity-state entity) state
        (etaf-mario--entity-height entity) 8
        (etaf-mario--entity-y entity) (+ (etaf-mario--entity-y entity) 4)
        (etaf-mario--entity-vx entity) 0.0
        (etaf-mario--entity-vy entity) 0.0))

(defun etaf-mario--stomped-p (player entity)
  "Return non-nil when PLAYER lands on top of ENTITY."
  (and (> (etaf-mario--player-vy player) 0)
       (<= (+ (etaf-mario--player-y player) (etaf-mario--player-height player))
           (+ (etaf-mario--entity-y entity) 5))))

(defun etaf-mario--interact-entity (world entity)
  "Resolve WORLD's player touching ENTITY."
  (let* ((player (etaf-mario--world-player world))
         (star (> (etaf-mario--player-star player) 0.0)))
    (when (and (not (etaf-mario--player-dead player))
               (etaf-mario--overlap-p (etaf-mario--player-bounds player)
                                      (etaf-mario--entity-bounds entity)))
      (pcase (etaf-mario--entity-kind entity)
        ((or 'mushroom 'flower 'star 'one-up)
         (when (eq (etaf-mario--entity-state entity) 'walking)
           (setf (etaf-mario--entity-state entity) 'gone)
           (pcase (etaf-mario--entity-kind entity)
             ('mushroom
              (unless (etaf-mario--player-big-p player)
                (setf (etaf-mario--player-big-p player) t
                      (etaf-mario--player-y player) (- (etaf-mario--player-y player) 8)
                      (etaf-mario--player-height player) 16))
              (cl-incf (etaf-mario--world-score world) 1000)
              (push (list :type 'grow) (etaf-mario--world-events world)))
             ('one-up
              (cl-incf (etaf-mario--world-lives world))
              (push (list :type 'one-up) (etaf-mario--world-events world)))
             ('flower
              (unless (etaf-mario--player-big-p player)
                (setf (etaf-mario--player-big-p player) t
                      (etaf-mario--player-y player) (- (etaf-mario--player-y player) 8)
                      (etaf-mario--player-height player) 16))
              (setf (etaf-mario--player-fire-p player) t)
              (cl-incf (etaf-mario--world-score world) 1000)
              (push (list :type 'fire-power) (etaf-mario--world-events world)))
             ('star
              (setf (etaf-mario--player-star player) 9.0)
              (cl-incf (etaf-mario--world-score world) 1000)
              (push (list :type 'star) (etaf-mario--world-events world))))))
        ((or 'goomba 'koopa)
         (cond
          (star
           (etaf-mario--kill-entity world entity :flip)
           (etaf-mario--award world (etaf-mario--entity-kind entity)
                              (etaf-mario--entity-x entity)
                              (etaf-mario--entity-y entity)))
          ((etaf-mario--stomped-p player entity)
           (if (eq (etaf-mario--entity-kind entity) 'koopa)
               (progn
                 (etaf-mario--transform-shell world entity 'shell-still)
                 (etaf-mario--award world :koopa
                                    (etaf-mario--entity-x entity)
                                    (etaf-mario--entity-y entity)))
             (etaf-mario--kill-entity world entity :squash)
             (etaf-mario--award world :goomba
                                (etaf-mario--entity-x entity)
                                (etaf-mario--entity-y entity)))
           (setf (etaf-mario--player-vy player) -170.0))
          (t (etaf-mario--damage-player world))))
        ('shell
         (pcase (etaf-mario--entity-state entity)
           ('shell-still
            (setf (etaf-mario--entity-state entity) 'shell-moving
                  (etaf-mario--entity-vx entity)
                  (* 200.0 (if (< (etaf-mario--player-x player)
                                  (etaf-mario--entity-x entity))
                               1 -1)))
            (push (list :type 'kick) (etaf-mario--world-events world)))
           ('shell-moving
            (if star
                (etaf-mario--kill-entity world entity :flip)
              (setf (etaf-mario--entity-state entity) 'shell-still
                    (etaf-mario--entity-vx entity) 0.0)))
           (_ nil)))
        ('fireball nil)
        (_ nil)))))

(defun etaf-mario--shell-hits (world)
  "Resolve moving shells hitting other enemies in WORLD."
  (dolist (shell (etaf-mario--world-entities world))
    (when (and (eq (etaf-mario--entity-kind shell) 'shell)
               (eq (etaf-mario--entity-state shell) 'shell-moving))
      (dolist (other (etaf-mario--world-entities world))
        (when (and (not (eq other shell))
                   (memq (etaf-mario--entity-state other) '(walking shell-still))
                   (etaf-mario--overlap-p (etaf-mario--entity-bounds shell)
                                          (etaf-mario--entity-bounds other)))
          (etaf-mario--kill-entity world other :flip)
          (etaf-mario--award world :shell
                             (etaf-mario--entity-x other)
                             (etaf-mario--entity-y other)))))))

(defun etaf-mario--fireball-hits (world)
  "Resolve fireballs hitting enemies in WORLD."
  (dolist (ball (etaf-mario--world-entities world))
    (when (and (eq (etaf-mario--entity-kind ball) 'fireball)
               (eq (etaf-mario--entity-state ball) 'flying))
      (dolist (other (etaf-mario--world-entities world))
        (when (and (not (eq ball other))
                   (memq (etaf-mario--entity-state other) '(walking shell-still))
                   (etaf-mario--overlap-p (etaf-mario--entity-bounds ball)
                                          (etaf-mario--entity-bounds other)))
          (setf (etaf-mario--entity-state ball) 'gone)
          (etaf-mario--kill-entity world other :flip)
          (etaf-mario--award world :shell
                             (etaf-mario--entity-x other)
                             (etaf-mario--entity-y other)))))))

(defun etaf-mario--collect-tiles (world)
  "Collect coin tiles and touch lava under WORLD's player."
  (let* ((player (etaf-mario--world-player world))
         (bounds (etaf-mario--player-bounds player))
         (left (floor (/ (plist-get bounds :x) etaf-mario-model-tile)))
         (right (floor (/ (+ (plist-get bounds :x) (plist-get bounds :w) -0.01)
                          etaf-mario-model-tile)))
         (top (floor (/ (plist-get bounds :y) etaf-mario-model-tile)))
         (bottom (floor (/ (+ (plist-get bounds :y) (plist-get bounds :h) -0.01)
                           etaf-mario-model-tile))))
    (cl-loop for column from left to right do
             (cl-loop for row from top to bottom do
                      (let ((tile (etaf-mario-world-tile world column row)))
                        (cond
                         ((eq tile 'coin)
                          (etaf-mario-world-set-tile world column row 'empty)
                          (etaf-mario--award world :coin
                                             (* column etaf-mario-model-tile)
                                             (* row etaf-mario-model-tile)))
                         ((eq tile 'lava)
                          (etaf-mario--kill-player world))))))))

(defun etaf-mario--check-flag (world)
  "Complete WORLD's stage when the player reaches the flagpole."
  (let ((flag (etaf-mario-world-flag-column world))
        (player (etaf-mario--world-player world)))
    (when (and flag
               (eq (etaf-mario--world-status world) 'playing)
               (>= (+ (etaf-mario--player-x player) (etaf-mario--player-width player))
                   (+ (* flag etaf-mario-model-tile) 2)))
      (setf (etaf-mario--world-status world) 'cleared
            (etaf-mario--world-status-timer world) 3.0)
      (cl-incf (etaf-mario--world-score world) (* 50 (etaf-mario--world-time world)))
      (push (list :type 'clear) (etaf-mario--world-events world)))))

;;; Step

(defun etaf-mario--step-playing (world input dt)
  "Advance a playing WORLD by DT under INPUT."
  (etaf-mario--step-player world input dt)
  (dolist (entity (etaf-mario--world-entities world))
    (etaf-mario--step-entity world entity dt))
  (dolist (entity (etaf-mario--world-entities world))
    (when (memq (etaf-mario--entity-state entity) '(walking shell-still))
      (etaf-mario--interact-entity world entity)))
  (etaf-mario--shell-hits world)
  (etaf-mario--fireball-hits world)
  (etaf-mario--collect-tiles world)
  (etaf-mario--check-flag world)
  (let ((player (etaf-mario--world-player world)))
    (when (> (etaf-mario--player-y player) (+ (etaf-mario--world-height world) 24))
      (etaf-mario--kill-player world)))
  (setf (etaf-mario--world-entities world)
        (cl-delete-if (lambda (entity)
                        (or (eq (etaf-mario--entity-state entity) 'gone)
                            (> (etaf-mario--entity-y entity)
                               (+ (etaf-mario--world-height world) 64))))
                      (etaf-mario--world-entities world)))
  (cl-incf (etaf-mario--world-time-acc world) dt)
  (while (>= (etaf-mario--world-time-acc world) etaf-mario-model-time-tick)
    (cl-decf (etaf-mario--world-time-acc world) etaf-mario-model-time-tick)
    (when (> (etaf-mario--world-time world) 0)
      (cl-decf (etaf-mario--world-time world))))
  (when (<= (etaf-mario--world-time world) 0)
    (etaf-mario--kill-player world)))

(defun etaf-mario-world-step (world input)
  "Advance WORLD by one fixed step under INPUT.
INPUT is a plist of `:left', `:right', `:run', `:jump', `:jump-held',
`:duck' and `:fire' booleans."
  (let ((dt etaf-mario-model-step))
    (pcase (etaf-mario--world-status world)
      ('playing (etaf-mario--step-playing world input dt))
      ('dying
       (let ((player (etaf-mario--world-player world)))
         (setf (etaf-mario--player-vy player)
               (min etaf-mario-model-max-fall
                    (+ (etaf-mario--player-vy player)
                       (* etaf-mario-model-gravity dt))))
         (setf (etaf-mario--player-y player)
               (+ (etaf-mario--player-y player)
                  (* (etaf-mario--player-vy player) dt))))
       (cl-decf (etaf-mario--world-status-timer world) dt)
       (when (<= (etaf-mario--world-status-timer world) 0.0)
         (if (> (etaf-mario--world-lives world) 1)
             (progn
               (cl-decf (etaf-mario--world-lives world))
               (let* ((score (etaf-mario--world-score world))
                      (coins (etaf-mario--world-coins world))
                      (lives (etaf-mario--world-lives world))
                      (index (etaf-mario--world-index world))
                      (player (etaf-mario--world-player world)))
                 (setf (etaf-mario--player-big-p player) nil
                       (etaf-mario--player-fire-p player) nil
                       (etaf-mario--player-height player) 8)
                 (etaf-mario--reset-stage world)
                 (setf (etaf-mario--world-score world) score
                       (etaf-mario--world-coins world) coins
                       (etaf-mario--world-lives world) lives
                       (etaf-mario--world-index world) index)))
           (setf (etaf-mario--world-lives world) 0
                 (etaf-mario--world-status world) 'gameover
                 (etaf-mario--world-status-timer world) 0.0
                 (etaf-mario--world-events world)
                 (cons (list :type 'gameover)
                       (etaf-mario--world-events world))))))
      ('cleared
       (cl-decf (etaf-mario--world-status-timer world) dt))
      ('gameover nil))
    world))

(provide 'etaf-mario-model)
;;; etaf-mario-model.el ends here
