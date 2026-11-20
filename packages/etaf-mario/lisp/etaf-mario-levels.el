;;; -*- lexical-binding: t; -*-
;;; etaf-mario-levels.el --- Bundled level maps and their parser

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Levels are UTF-8 block maps.  One character is one 8x8 world block:
;; `.` empty, `#` ground, `B` brick, `?` coin block, `M` mushroom block,
;; `W` fire-flower block, `S` star block, `U` used block, `o` coin,
;; `(` `)` pipe top, `[` `]` pipe body, `C` castle stone, `L` lava,
;; `=` bridge, `F` flagpole, `@` start and `g`/`k` enemy spawns.
;; The parser turns a map into tiles, item contents and spawn records.
;;
;; Floating blocks keep at least two empty rows above the surface below
;; them.  One empty row is a shelf big Mario cannot pass under or jump
;; through; a block resting on a surface (no empty row) is a step and is
;; allowed.  `etaf-mario-level-parse' rejects a map that breaks this rule, so
;; a bundled level cannot ship with an impassable shelf.

;;; Code:

(require 'cl-lib)

(defconst etaf-mario-levels
  (list
   (list :name "1-1 郁绿平原" :theme 'day :time 350
         :map
         (list
          "...................................................................................................................................................................................."
          "...............oo...ooo...............................................ooo.............................................................................ooo..........................."
          "....................................................().....................................................................B..oooo.............................B..........F........."
          "................?...B?MB?...............()..........[]........................BB?BB?..........B?BMB.............?B?.......BB.............?B?B.................BB..........F........."
          "..............................()........[]..........[]...................................................................BBB.................................BBB..........F........."
          "...@..........................[]....g...[]....gg....[]........................g.........k...................g...........BBBB.........gg..........k..........BBBB....g.....F........."
          "######################################################################...#############################################################################...###########################"
          "######################################################################...#############################################################################...###########################"))
   (list :name "1-2 地下长廊" :theme 'underground :time 400
         :map
         (list
          "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
          ".............................................................ooooo........ooooooo...................ooo......................................................................................."
          "..........oooo.................................B............................................................................().....ooooo...........B...................................F......"
          "..........B?B?....BB?B......()................BB............B?BB?BB.................BBBBB...................?B?B?...........[]....BB?B?BB.........BB......B?BB..........?B?............F......"
          "............................[]...............BBB....()......................................................................[]...................BBB...................................F......"
          "...@....................g...[]......g.......BBBB....[]................k.....................g.........................gg....[]..................BBBB...k..........g....................F......"
          "####################################################################################################...#######################################################################################"
          "####################################################################################################...#######################################################################################"))
   (list :name "1-3 云上跳台" :theme 'day :time 400
         :map
         (list
          "...................................................................................................................................................................................................."
          "...........................................og.......................oo.k........oo.............ooo.......................oo.........................ooo............................................."
          "..........................................BBBBB.....................BBBBB.....................BBBBB......g..............BBBBB......................BBBBB......g...........................F........."
          "..........................BBBB....BBBB.............BBBBB....BBBB.............BBBBB....BBBB.............BBBBB....BBBB.............BBBBB....BBBBB.............BBBBB.........................F........."
          "..........................................................................................................................................................................................F........."
          "...@..........g...........................................................................................................................................................................F........."
          "###################.................................................................................................................................................################################"
          "###################.................................................................................................................................................################################"))
   (list :name "1-4 熔岩城堡" :theme 'castle :time 400
         :map
         (list
          "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
          "..........oo...................................ooo................ooo.......................ooo.....................ooo.......................ooo..............................."
          ".........................ooo......................................................................BB?BB...................BB?BB.......................................F........."
          "..........?B?.................BB?BB.....?B?.........BB?B................?B?B?.......BBBB......................?B?.............B.....?BB?............B?B.......BB?.....F........."
          "........................................................BB............................................................................................................F........."
          "...@.............g..................k...................BB..g...................k.......................g.......................k.........................g...........F........."
          "CCCCCCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
          "CCCCCCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCCCCCLLLCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")))
  "Bundled levels in campaign order.")

(defconst etaf-mario-level--solid-tiles
  '(ground dirt brick question used pipe-tl pipe-tr pipe-l pipe-r castle bridge)
  "Tile names an entity cannot pass through.")

(defconst etaf-mario-level--block-tiles
  '(brick question used)
  "Tile names that occupy a block the player can bump.")

(defun etaf-mario-level-solid-p (tile)
  "Return non-nil when TILE stops movement."
  (memq tile etaf-mario-level--solid-tiles))

(defun etaf-mario-level---char-tile (rows row column)
  "Return the tile symbol at ROW and COLUMN of ROWS.
Ground characters below another ground character become plain dirt so only
the surface carries grass."
  (let* ((line (nth row rows))
         (char (and line (< column (length line)) (aref line column))))
    (pcase char
      (?# (if (and (> row 0)
                   (let ((above (nth (1- row) rows)))
                     (and above (< column (length above)) (eq (aref above column) ?#))))
              'dirt
            'ground))
      (?B 'brick)
      ((or ?? ?M ?W ?S) 'question)
      (?U 'used)
      (?\( 'pipe-tl)
      (?\) 'pipe-tr)
      (?\[ 'pipe-l)
      (?\] 'pipe-r)
      (?C 'castle)
      (?L 'lava)
      (?= 'bridge)
      (_ 'empty))))

(defun etaf-mario-level-parse (definition)
  "Return a level plist built from DEFINITION.
DEFINITION is a plist with `:name', `:theme', `:time' and `:map'.  Signal an
error when the map leaves a one-row shelf below a floating block."
  (let* ((rows (plist-get definition :map))
         (height (length rows))
         (width (apply #'max (cons 1 (mapcar #'length rows))))
         (tiles (make-vector (* width height) 'empty))
         (items (make-hash-table :test #'eq))
         (state (list :spawns nil :start nil :flag nil)))
    (dotimes (row height)
      (etaf-mario-level--parse-row rows row width tiles items state))
    (let ((level (list :name (plist-get definition :name)
                       :theme (or (plist-get definition :theme) 'day)
                       :time (or (plist-get definition :time) 350)
                       :width width :height height
                       :tiles tiles :items items
                       :spawns (nreverse (plist-get state :spawns))
                       :start (or (plist-get state :start)
                                  (cons 3 (max 0 (- height 3))))
                       :flag (plist-get state :flag))))
      (when-let* ((problem (car (etaf-mario-level-clearance-problems level))))
        (error "Level %s leaves a one-row shelf at column %d row %d"
               (plist-get level :name) (nth 0 problem) (nth 1 problem)))
      level)))

(defun etaf-mario-level--parse-row (rows row width tiles items state)
  "Parse ROWS's ROW into TILES, ITEMS and STATE at WIDTH columns."
  (let ((line (nth row rows)))
    (dotimes (column width)
      (let* ((char (and (< column (length line)) (aref line column)))
             (index (+ (* row width) column))
             (tile (etaf-mario-level---char-tile rows row column)))
        (aset tiles index tile)
        (etaf-mario-level--parse-char char index column row tiles items state)))))

(defun etaf-mario-level--parse-char (char index column row tiles items state)
  "Record one map CHAR at INDEX, COLUMN and ROW.
TILES, ITEMS and STATE are updated in place."
  (cond
   ((eq char ?o) (aset tiles index 'coin))
   ((memq char '(?? ?M ?W ?S))
    (aset tiles index 'question)
    (puthash index (pcase char
                     (?M 'mushroom)
                     (?W 'flower)
                     (?S 'star)
                     (_ 'coin))
             items))
   ((eq char ?\@)
    (aset tiles index 'empty)
    (unless (plist-get state :start)
      (plist-put state :start (cons column row))))
   ((eq char ?F)
    (aset tiles index 'empty)
    (unless (plist-get state :flag)
      (plist-put state :flag column)))
   ((eq char ?g)
    (push (list :kind 'goomba :column column :row row)
          (plist-get state :spawns))
    (plist-put state :spawns (plist-get state :spawns)))
   ((eq char ?k)
    (push (list :kind 'koopa :column column :row row)
          (plist-get state :spawns))
    (plist-put state :spawns (plist-get state :spawns)))))

(defun etaf-mario-level--nearest-solid-below (level column row)
  "Return the row of the nearest solid tile below ROW in COLUMN, or nil."
  (let ((height (plist-get level :height))
        (found nil)
        (current (1+ row)))
    (while (and (not found) (< current height))
      (when (etaf-mario-level-solid-p (etaf-mario-level-tile level column current))
        (setq found current))
      (setq current (1+ current)))
    found))

(defun etaf-mario-level-clearance-problems (level)
  "Return (COLUMN ROW GAP) triples for shelves that block the stage.
GAP counts the empty rows between a block and the nearest solid row below
it.  A gap of exactly one row is a shelf the player cannot pass under and
cannot jump through, so it is reported.  A gap of zero is a block resting on
a surface and is a normal step."
  (let ((width (plist-get level :width))
        (height (plist-get level :height))
        (problems nil))
    (dotimes (column width)
      (dotimes (row height)
        (when (memq (etaf-mario-level-tile level column row)
                    etaf-mario-level--block-tiles)
          (when-let* ((below (etaf-mario-level--nearest-solid-below
                              level column row))
                      (gap (- below row 1)))
            (when (= gap 1)
              (push (list column row gap) problems))))))
    (nreverse problems)))

(defun etaf-mario-level-by-index (index)
  "Return the parsed level at campaign INDEX, wrapping around."
  (etaf-mario-level-parse
   (nth (mod index (length etaf-mario-levels)) etaf-mario-levels)))

(defun etaf-mario-level-tile (level column row)
  "Return LEVEL's tile symbol at COLUMN and ROW, or `ground' outside.
Outside the left and right edges is solid so nothing walks off the map;
above the top is empty and below the bottom is empty so a fall is fatal."
  (let ((width (plist-get level :width))
        (height (plist-get level :height)))
    (cond ((or (< column 0) (>= column width)) 'ground)
          ((or (< row 0) (>= row height)) 'empty)
          (t (aref (plist-get level :tiles) (+ (* row width) column))))))

(provide 'etaf-mario-levels)
;;; etaf-mario-levels.el ends here
