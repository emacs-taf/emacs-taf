;;; -*- lexical-binding: t; -*-
;;; etaf-mario-render.el --- Element sprites composed from characters

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The stage is built from small character pictures.  One world block is four
;; cells wide and two rows tall, so a block is roughly square on screen and
;; each element -- brick, question block, pipe, coin, enemy, Mario -- is drawn
;; as its own little shape of characters and faces.  Nothing paints the scene
;; background: the frame's own theme background shows through, and a space in
;; a sprite is transparent.

;;; Code:

(require 'cl-lib)
(require 'etaf-mario-art)
(require 'etaf-mario-model)

(defconst etaf-mario-render--cell-width 4
  "Cells per world block.")

(defconst etaf-mario-render--cell-height 2
  "Text rows per world block.")

(defconst etaf-mario-render--sprites
  '((ground . ("▁▁▁▁" "▒▒▒▒"))
    (dirt . ("▒▒▒▒" "▒▒▒▒"))
    ;; Block borders join across neighbours: only the outer ends of a run
    ;; carry a vertical edge, so a row of bricks reads as one strip.
    (brick-l . ("▛▀▀▀" "▙▄▄▄"))
    (brick-m . ("▀▀▀▀" "▄▄▄▄"))
    (brick-r . ("▀▀▀▜" "▄▄▄▟"))
    (brick-s . ("▛▀▀▜" "▙▄▄▟"))
    (question-l . ("▛▀▀▀" "▙?▄▄"))
    (question-m . ("▀▀▀▀" "▄?▄▄"))
    (question-r . ("▀▀▀▜" "▄▄?▟"))
    (question-s . ("▛▀▀▜" "▙?▄▟"))
    (used-l . ("▛▀▀▀" "▙▄▄▄"))
    (used-m . ("▀▀▀▀" "▄▄▄▄"))
    (used-r . ("▀▀▀▜" "▄▄▄▟"))
    (used-s . ("▛▀▀▜" "▙▄▄▟"))
    ;; A pipe is two blocks wide: each half draws its own edge, and the
    ;; body is filled so the pipe reads solid instead of as an empty frame.
    (pipe-tl . ("╔═══" "║███"))
    (pipe-tr . ("═══╗" "███║"))
    (pipe-l . ("║███" "║███"))
    (pipe-r . ("███║" "███║"))
    (castle . ("╬╬╬╬" "╬╬╬╬"))
    (lava . ("≋≋≋≋" "≋≋≋≋"))
    (coin . ("o "))
    (bridge . ("▔▔▔▔" "    "))
    ;; Characters keep their feet on the last row of their block.
    (mario-stand . ("▄▄▄▄▄▄"
                    "▐feef▌"
                    "██████"))
    (mario-walk-a . ("▄▄▄▄▄▄"
                     "▐feef▌"
                     "███ ██"))
    (mario-walk-b . ("▄▄▄▄▄▄"
                     "▐feef▌"
                     "██ ███"))
    (mario-jump . ("▄▄▄▄▄▄"
                   "▐feef▌"
                   "██  ██"))
    (mario-big . (" ▄▄▄▄ "
                  "▄▄▄▄▄▄"
                  "▐feef▌"
                  "██████"
                  "██  ██"))
    (mario-dead . (" ▄▄▄▄ "
                   "▐▄▄▄▄▌"
                   " ▀▀▀▀ "))
    (goomba . (" ▄▄▄ "
               "▐eWe▌"
               " ▀ ▀ "))
    (koopa . (" ▄▄▄ "
              "▐jjj▌"
              "▐jjj▌"
              " ▀ ▀ "))
    (shell . (" ▄▄▄ "
              " ▀▀▀ "))
    (mushroom . (" ▄▄▄ "
                 "▐rw r▌"
                 " ▀▀▀ "))
    (one-up . (" ▄▄▄ "
               "▐gw g▌"
               " ▀▀▀ "))
    (flower . ("** "))
    (star . ("★★ "))
    (fireball . ("o  "))
    (debris . ("*  "))
    (coin-pop . ("o  ")))
  "Element sprites: name to rows of characters, all rows the same width.")

(defconst etaf-mario-render--global-paint
  '((?▁ grass-shade grass) (?▒ dirt-shade dirt)
    (?▛ brick-shade brick) (?▀ brick-shade brick) (?▜ brick-shade brick)
    (?▙ brick-shade brick) (?▄ brick-shade brick) (?▟ brick-shade brick)
    (?? ink gold) (?╔ pipe-shade pipe) (?═ pipe-shade pipe)
    (?╗ pipe-shade pipe) (?║ pipe-shade pipe)
    (?╬ castle-shade castle) (?≋ lava nil) (?o gold nil) (?* brick nil) (?▔ brick-shade nil)
    (?f skin skin) (?e ink skin) (?w white skin)
    (?█ blue brick-shade) (?▐ blue brick-shade) (?▌ blue brick-shade)
    (?j shell-shade shell) (?r red red) (?g one-up one-up)
    (?★ star nil))
  "Fallback character colours for every sprite.")

(defconst etaf-mario-render--sprite-paint
  '((mario-stand (?▄ red red) (?f skin skin) (?e ink skin)
                 (?▐ ink ink) (?▌ ink ink) (?█ blue blue))
    (mario-walk-a (?▄ red red) (?f skin skin) (?e ink skin)
                  (?▐ ink ink) (?▌ ink ink) (?█ blue blue))
    (mario-walk-b (?▄ red red) (?f skin skin) (?e ink skin)
                  (?▐ ink ink) (?▌ ink ink) (?█ blue blue))
    (mario-jump (?▄ red red) (?f skin skin) (?e ink skin)
                (?▐ ink ink) (?▌ ink ink) (?█ blue blue))
    (mario-big (?▄ red red) (?f skin skin) (?e ink skin)
               (?▐ ink ink) (?▌ ink ink) (?█ blue blue))
    (mario-dead (?▄ muted muted) (?▀ muted muted) (?▐ muted muted) (?▌ muted muted))
    (goomba (?  muted muted) (?▄ goomba goomba-shade) (?█ goomba goomba-shade)
            (?▐ goomba goomba-shade) (?▌ goomba goomba-shade)
            (?e white ink) (?W ink white) (?▀ goomba-shade goomba-shade))
    (koopa (?  muted muted) (?▄ shell shell-shade) (?█ shell shell-shade)
           (?▐ shell shell-shade) (?▌ shell shell-shade) (?▀ goomba-shade goomba-shade)
           (?j shell-shade shell))
    (shell (?  muted muted) (?▄ shell shell-shade) (?▀ shell-shade shell))
    (mushroom (?  muted muted) (?▄ red red) (?▐ red red) (?▌ red red)
              (?r white white) (?w white white) (?▀ brick-shade brick-shade))
    (one-up (?  muted muted) (?▄ one-up one-up) (?▐ one-up one-up)
            (?▌ one-up one-up) (?g white white) (?w white white)
            (?▀ brick-shade brick-shade))
    (flower (?* red nil))
    (star (?★ star nil))
    (fireball (?o lava nil))
    (debris (?* brick nil))
    (coin-pop (?o gold nil))
    (used (?▛ muted nil) (?▀ muted nil) (?▜ muted nil)
          (?▙ muted nil) (?▄ muted nil) (?▟ muted nil))
    (pipe-tl (?╔ pipe nil) (?═ pipe nil) (?║ pipe nil)
             (?█ pipe-shade pipe-shade))
    (pipe-tr (?═ pipe nil) (?╗ pipe nil) (?║ pipe nil)
             (?█ pipe-shade pipe-shade))
    (pipe-l (?║ pipe nil) (?█ pipe-shade pipe-shade))
    (pipe-r (?║ pipe nil) (?█ pipe-shade pipe-shade))
    (coin (?o gold nil)))
  "Per-sprite overrides; a character missing here uses the global table.")

(defvar etaf-mario-render--piece-cache (make-hash-table :test #'equal)
  "Propertized runs keyed by (TEXT FOREGROUND BACKGROUND).")

(defun etaf-mario-render--role-color (palette role)
  "Return PALETTE's colour for ROLE, a symbol or keyword."
  (when role
    (plist-get palette (if (keywordp role) role
                         (intern (concat ":" (symbol-name role)))))))

(defun etaf-mario-render--sprite-base (sprite)
  "Return SPRITE without an edge-variant suffix such as -l or -m."
  (let ((name (symbol-name sprite)))
    (if (string-match "\\(?:-[lmsr]\\)\\'" name)
        (let ((base (intern (substring name 0 (match-beginning 0)))))
          (if (assq base etaf-mario-render--sprites) base sprite))
      sprite)))

(defun etaf-mario-render--paint-of (sprite char palette)
  "Return (FOREGROUND . BACKGROUND) for CHAR in SPRITE using PALETTE."
  (let* ((base (etaf-mario-render--sprite-base sprite))
         (entry (or (assq char (cdr (assq base etaf-mario-render--sprite-paint)))
                    (assq char etaf-mario-render--global-paint))))
    (when entry
      (cons (etaf-mario-render--role-color palette (nth 1 entry))
            (etaf-mario-render--role-color palette (nth 2 entry))))))

(defun etaf-mario-render--blit (frame sprite x y palette)
  "Draw SPRITE into FRAME with its top left at X and Y using PALETTE."
  (let ((rows (cdr (assq sprite etaf-mario-render--sprites)))
        (height (length frame))
        (width (length (aref frame 0))))
    (cl-loop for line in rows
             for row from y
             when (and (>= row 0) (< row height))
             do (cl-loop for char across line
                         for column from x
                         when (and (>= column 0) (< column width) (/= char ?\s))
                         do (let ((paint (etaf-mario-render--paint-of sprite char palette)))
                              (when paint
                                (aset (aref frame row) column
                                      (list char (car paint) (cdr paint)))))))))

;;; Geometry

(defun etaf-mario-render-camera (world cols)
  "Return the first visible world cell for a view COLS cells wide.
The camera scrolls in single cells, one world pixel pair at a time, and
keeps the player about a third of the way in.  It stops at both level ends."
  (let* ((player (etaf-mario-world-player world))
         (view (max 1 cols))
         (limit (max 0 (- (/ (etaf-mario-world-width world) 2) view)))
         (anchor (/ view 3)))
    (max 0 (min limit (- (floor (/ (etaf-mario--player-x player) 2)) anchor)))))

(defun etaf-mario-render--stage-top (world rows)
  "Return the first text row of WORLD's stage in a canvas of ROWS."
  (- rows (* etaf-mario-render--cell-height
            (plist-get (etaf-mario-world-level world) :height))))

(defun etaf-mario-render--row-of-block (world rows block-row)
  "Return the first text row of BLOCK-ROW in WORLD."
  (+ (etaf-mario-render--stage-top world rows)
     (* etaf-mario-render--cell-height block-row)))

;;; Scenery

(defun etaf-mario-render--draw-scenery (world frame camera palette)
  "Draw clouds and hills into FRAME at CAMERA with PALETTE.
Outdoor stages show sky scenery; underground and castle stages keep their
interior walls plain."
  (when (eq (etaf-mario-world-theme world) 'day)
    (let ((columns (length (aref frame 0)))
          (rows (length frame))
          (top (etaf-mario-render--stage-top world (length frame)))
          (first (floor camera etaf-mario-render--cell-width))
          (cloud (plist-get palette :cloud))
          (hill (plist-get palette :hill)))
      (cl-loop for block from first
               to (+ first (1- (/ columns etaf-mario-render--cell-width)))
               for x = (- (* etaf-mario-render--cell-width block) camera)
               do (when (= 0 (mod block 14))
                    (let ((row (+ 1 (mod (* block 5) (max 1 (- top 6))))))
                      (when (and (< row (1- rows)) (>= row 0)
                                 (>= x 0) (< x columns))
                        (aset (aref frame row) x (list ?~ cloud nil))
                        (when (< (1+ x) columns)
                          (aset (aref frame row) (1+ x) (list ?~ cloud nil))))))
                  (when (= 0 (mod block 9))
                    (let ((row (1- top)))
                      (when (and (>= row 0) (>= x 0) (< x columns))
                        (aset (aref frame row) x (list ?^ hill nil)))))))))

;;; Stage

(defun etaf-mario-render--block-neighbour-p (world column row)
  "Return non-nil when COLUMN and ROW hold a block with drawable borders."
  (memq (etaf-mario-world-tile world column row)
        '(brick question used)))

(defun etaf-mario-render--tile-sprite (world column row sprite)
  "Return SPRITE's variant for the blocks beside COLUMN and ROW.
Only the ends of a continuous run keep a vertical border, so adjacent blocks
join instead of repeating a frame around every tile."
  (if (memq sprite '(brick question used))
      (let ((left (etaf-mario-render--block-neighbour-p world (1- column) row))
            (right (etaf-mario-render--block-neighbour-p world (1+ column) row)))
        (intern (format "%s-%s" sprite
                        (cond ((and left right) "m")
                              (left "r")
                              (right "l")
                              (t "s")))))
    sprite))

(defun etaf-mario-render--draw-tiles (world frame camera palette)
  "Draw WORLD's tile sprites into FRAME at CAMERA."
  (let* ((level (etaf-mario-world-level world))
         (width (plist-get level :width))
         (height (plist-get level :height))
         (columns (length (aref frame 0)))
         (first (floor camera etaf-mario-render--cell-width))
         (blocks (1+ (ceiling (/ columns (float etaf-mario-render--cell-width))))))
    (dotimes (offset blocks)
      (let ((block (+ first offset)))
        (when (and (>= block 0) (< block width))
          (dotimes (row height)
            (let* ((name (etaf-mario-world-tile world block row))
                   (sprite (etaf-mario-render--tile-sprite world block row name)))
              (when (assq sprite etaf-mario-render--sprites)
                (let* ((art (cdr (assq sprite etaf-mario-render--sprites)))
                       (sprite-width (length (car art)))
                       (x (+ (- (* etaf-mario-render--cell-width block) camera)
                             (floor (/ (- etaf-mario-render--cell-width sprite-width)
                                       2.0)))))
                  (etaf-mario-render--blit
                   frame sprite x
                   (etaf-mario-render--row-of-block world (length frame) row)
                   palette))))))))))

(defun etaf-mario-render--flag-ground-row (world column)
  "Return the first solid block row below COLUMN's flagpole."
  (let ((height (plist-get (etaf-mario-world-level world) :height))
        (row 1))
    (while (and (< row height)
                (not (memq (etaf-mario-world-tile world column row)
                           '(ground dirt castle brick))))
      (setq row (1+ row)))
    (min row (1- height))))

(defun etaf-mario-render--draw-flag (world frame camera palette)
  "Draw WORLD's flagpole into FRAME at CAMERA."
  (when-let* ((column (etaf-mario-world-flag-column world)))
    (let* ((rows (length frame))
           (x (- (* etaf-mario-render--cell-width column) camera))
           (surface (etaf-mario-render--flag-ground-row world column))
           (ground (etaf-mario-render--row-of-block world rows surface))
           (pole (plist-get palette :white)))
      (cl-loop for row from (- ground 9) below ground
               when (and (>= row 0) (< row rows) (>= x 0) (< x (length (aref frame 0))))
               do (aset (aref frame row) x (list ?│ pole nil)))
      (when (and (>= (- ground 9) 0) (>= x 0) (< x (length (aref frame 0))))
        (aset (aref frame (- ground 9)) x (list ?⚑ (plist-get palette :red) nil))))))

(defun etaf-mario-render--entity-sprite (entity)
  "Return ENTITY's sprite name."
  (pcase (etaf-mario--entity-kind entity)
    ('goomba 'goomba) ('koopa 'koopa) ('shell 'shell)
    ('mushroom 'mushroom) ('one-up 'one-up) ('flower 'flower)
    ('star 'star) ('fireball 'fireball) ('debris 'debris)
    ('coin-pop 'coin-pop) (_ nil)))

(defun etaf-mario-render--actor-origin (world rows camera x y height sprite)
  "Return the top left (X . Y) cells of SPRITE for an actor at X and Y.
HEIGHT is the actor's world height.  The horizontal position keeps its
offset inside the world block, and the feet land on the text row nearest
their pixel height, so an actor slides with the camera instead of jumping a
whole block at a time."
  (let* ((art (cdr (assq sprite etaf-mario-render--sprites)))
         (sprite-height (length art))
         (sprite-width (length (car art)))
         (block (floor (/ x etaf-mario-model-tile)))
         (sub-cell (floor (/ (- x (* block etaf-mario-model-tile)) 2.0)))
         (feet (+ y height))
         (bottom (1- (floor (/ (max 0 feet) 4.0)))))
    (cons (+ (* etaf-mario-render--cell-width block)
             sub-cell
             (floor (/ (- etaf-mario-render--cell-width sprite-width) 2.0))
             (- camera))
          (+ (- (etaf-mario-render--stage-top world rows) (1- sprite-height))
             bottom))))

(defun etaf-mario-render--draw-actors (world frame camera palette)
  "Draw WORLD's entities and player into FRAME at CAMERA."
  (let ((rows (length frame)))
    (dolist (entity (etaf-mario-world-entities world))
      (when-let* ((sprite (etaf-mario-render--entity-sprite entity)))
        (let ((origin (etaf-mario-render--actor-origin
                       world rows camera
                       (etaf-mario--entity-x entity)
                       (etaf-mario--entity-y entity)
                       (etaf-mario--entity-height entity)
                       sprite)))
          (etaf-mario-render--blit frame sprite (car origin) (cdr origin) palette))))
    (let* ((player (etaf-mario-world-player world))
           (sprite (cond ((etaf-mario--player-dead player) 'mario-dead)
                         ((etaf-mario--player-big-p player) 'mario-big)
                         ((not (etaf-mario--player-on-ground player)) 'mario-jump)
                         ((< (abs (etaf-mario--player-vx player)) 4.0) 'mario-stand)
                         ((= 0 (mod (floor (/ (etaf-mario--player-x player) 6)) 2))
                          'mario-walk-a)
                         (t 'mario-walk-b))))
      (let ((origin (etaf-mario-render--actor-origin
                     world rows camera
                     (etaf-mario--player-x player)
                     (etaf-mario--player-y player)
                     (etaf-mario--player-height player)
                     sprite)))
        (etaf-mario-render--blit frame sprite (car origin) (cdr origin) palette)))))

;;; Encoding

(defun etaf-mario-render--piece (text fg bg)
  "Return TEXT as a run painted with FG and BG."
  (let ((key (list text fg bg)))
    (or (gethash key etaf-mario-render--piece-cache)
        (puthash key
                 (if (and (null fg) (null bg))
                     text
                   (propertize text 'face
                               (append (and fg (list :foreground fg))
                                       (and bg (list :background bg)))))
                 etaf-mario-render--piece-cache))))

(defun etaf-mario-render--encode-row (cells)
  "Encode one row of CELLS into a propertized string."
  (let* ((width (length cells))
         (index 0)
         (start 0)
         (run (aref cells 0))
         (parts nil))
    (while (< index width)
      (let ((cell (aref cells index)))
        (unless (equal (cdr cell) (cdr run))
          (push (etaf-mario-render--piece
                 (apply #'string (mapcar #'car (append (cl-subseq cells start index) nil)))
                 (nth 1 run) (nth 2 run))
                parts)
          (setq start index run cell)))
      (setq index (1+ index)))
    (push (etaf-mario-render--piece
           (apply #'string (mapcar #'car (append (cl-subseq cells start width) nil)))
           (nth 1 run) (nth 2 run))
          parts)
    (apply #'concat (nreverse parts))))

(defun etaf-mario-render-check-sprites ()
  "Return (SPRITE CHARACTER) pairs whose colour mapping is missing.
Every sprite cell must resolve a foreground through the per-sprite or the
global table in every theme; a background is optional so a cell can stay
transparent.  A role that the theme does not define resolves to no
foreground at all, which would silently paint that cell in the frame's
default text colour.  The tests use this to keep the sprite and colour
tables in step."
  (let ((misses nil))
    (dolist (theme '(day underground castle night))
      (let ((palette (etaf-mario-art-palette theme)))
        (dolist (sprite etaf-mario-render--sprites)
          (dolist (line (cdr sprite))
            (dolist (char (string-to-list line))
              (unless (or (= char ?\s)
                          (car (etaf-mario-render--paint-of
                                (car sprite) char palette)))
                (cl-pushnew (list (car sprite) char) misses :test #'equal)))))))
    (nreverse misses)))

(defun etaf-mario-render-frame (world columns rows)
  "Compose WORLD into ROWS text rows of COLUMNS cells.
Return `(CAMERA . ROWS)' where ROWS is a list of propertized strings."
  (let* ((palette (etaf-mario-art-palette (etaf-mario-world-theme world)))
         (camera (etaf-mario-render-camera world columns))
         (frame (make-vector rows nil))
         (blank (list ?\s nil nil)))
    (dotimes (row rows)
      (aset frame row (make-vector columns blank)))
    (etaf-mario-render--draw-scenery world frame camera palette)
    (etaf-mario-render--draw-tiles world frame camera palette)
    (etaf-mario-render--draw-flag world frame camera palette)
    (etaf-mario-render--draw-actors world frame camera palette)
    (cons camera
          (mapcar #'etaf-mario-render--encode-row (append frame nil)))))

(provide 'etaf-mario-render)
;;; etaf-mario-render.el ends here
