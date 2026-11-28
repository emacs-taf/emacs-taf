;;; -*- lexical-binding: t; -*-
;;; etaf-xiangqi-model.el --- Decode public xiangqi observations for presentation

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-gamekit)

(defconst etaf-xiangqi--glyphs
  '((?R . "俥") (?H . "傌") (?E . "相") (?A . "仕") (?G . "帥") (?C . "炮") (?S . "兵")
    (?r . "車") (?h . "馬") (?e . "象") (?a . "士") (?g . "將") (?c . "砲") (?s . "卒"))
  "Display glyphs for the OpenSpiel xiangqi piece letters.")

(defun etaf-xiangqi--glyph (char)
  "Return the display glyph for piece CHAR, or nil."
  (cdr (assq char etaf-xiangqi--glyphs)))

(defun etaf-xiangqi--side (char)
  "Return the side of piece CHAR: `red' or `black'."
  (when char (if (eq (downcase char) char) 'black 'red)))

(defun etaf-xiangqi--name (char)
  "Return an accessible name for piece CHAR."
  (when char
    (concat (pcase (etaf-xiangqi--side char) ('red "红") ('black "黑"))
            (or (etaf-xiangqi--glyph char) (char-to-string char)))))

(defun etaf-xiangqi--coord (row column)
  "Return the coordinate cons for ROW and COLUMN."
  (cons row column))

(defun etaf-xiangqi--parse-move (label)
  "Parse a public move LABEL such as S(6,0)-(5,0) into a move plist."
  (when (and (stringp label)
             (string-match "\\`[A-Za-z](\\([0-9]+\\),\\([0-9]+\\))-(\\([0-9]+\\),\\([0-9]+\\))" label))
    (list :from (etaf-xiangqi--coord (string-to-number (match-string 1 label))
                                     (string-to-number (match-string 2 label)))
          :to (etaf-xiangqi--coord (string-to-number (match-string 3 label))
                                   (string-to-number (match-string 4 label))))))

(defun etaf-xiangqi--result (returns)
  "Return the winning side in public terminal RETURNS: red, black or draw."
  (when (and (consp returns) (numberp (car returns)))
    (cond ((> (car returns) 0) 'red) ((< (car returns) 0) 'black) (t 'draw))))

(defconst etaf-xiangqi--levels
  '((easy :depth 2 :seconds 1.0)
    (normal :depth 4 :seconds 2.0)
    (hard :depth 8 :seconds 4.0))
  "Search budget per computer level: maximum plies and seconds per move.")

(defun etaf-xiangqi--table (view)
  "Project the public OpenSpiel xiangqi VIEW without re-implementing rules."
  (when-let* ((text (plist-get view :observation))
              (rows (and (stringp text) (split-string text "\n")))
              ((= (length rows) 10))
              ((cl-every (lambda (row) (= (length row) 9)) rows)))
    (list :rows rows
          :moves (delq nil
                       (mapcar (lambda (action)
                                 (when-let* ((move (etaf-xiangqi--parse-move (plist-get action :label))))
                                   (append move (list :id (plist-get action :id)
                                                      :label (plist-get action :label)))))
                               (plist-get view :legal_actions)))
          :side (if (= (or (plist-get view :current_player) 0) 0) 'red 'black)
          :player (plist-get view :player)
          :count (or (plist-get view :action_count) 0)
          :can-undo (eq t (plist-get view :can_undo))
          :can-redo (eq t (plist-get view :can_redo))
          :terminal (eq t (plist-get view :terminal))
          :result (and (eq t (plist-get view :terminal))
                       (etaf-xiangqi--result (plist-get view :returns))))))

(defun etaf-xiangqi--computer (opponent)
  "Return the side played by the computer in OPPONENT, or nil for hot-seat."
  (pcase opponent ('computer-black 'black) ('computer-red 'red) (_ nil)))

(defun etaf-xiangqi--bot-arguments (level)
  "Return the public bot request arguments selecting LEVEL's search budget."
  (append (list :policy "search")
          (cdr (or (assq level etaf-xiangqi--levels)
                   (assq 'normal etaf-xiangqi--levels)))))

(defun etaf-xiangqi--step-count (computer count)
  "Return history steps from COUNT plies with COMPUTER playing one side.
Use a full round at a human decision point, one ply otherwise or hot-seat."
  (if (and computer (= (% count 2) (if (eq computer 'red) 1 0))) 2 1))

(defun etaf-xiangqi--cell (table row column)
  "Return the piece char at ROW/COLUMN in TABLE, or nil for an empty point."
  (when-let* ((rows (plist-get table :rows)))
    (let ((line (nth row rows)))
      (when (and line (< column (length line)) (not (= (aref line column) ?.)))
        (aref line column)))))

(defconst etaf-xiangqi--straight-directions '((1 . 0) (-1 . 0) (0 . 1) (0 . -1))
  "Orthogonal unit steps of rooks, cannons and the facing generals.")

(defconst etaf-xiangqi--horse-jumps
  '((2 . 1) (2 . -1) (-2 . 1) (-2 . -1) (1 . 2) (1 . -2) (-1 . 2) (-1 . -2))
  "Row and column offsets of a horse's eight destinations.")

(defun etaf-xiangqi--on-board-p (row column)
  "Return non-nil when ROW and COLUMN name an intersection."
  (and (<= 0 row 9) (<= 0 column 8)))

(defun etaf-xiangqi--general-coord (table side)
  "Return the coordinate of SIDE's general in TABLE, or nil."
  (let ((general (if (eq side 'red) ?G ?g)))
    (cl-loop for row from 0 below 10
             thereis (cl-loop for column from 0 below 9
                              when (equal general (etaf-xiangqi--cell table row column))
                              return (etaf-xiangqi--coord row column)))))

(defun etaf-xiangqi--sight (table coord row-step column-step)
  "Return occupied squares from COORD along ROW-STEP/COLUMN-STEP, nearest first.
Each element is (COORD . PIECE); empty intersections are skipped."
  (let ((row (+ (car coord) row-step))
        (column (+ (cdr coord) column-step)) seen)
    (while (etaf-xiangqi--on-board-p row column)
      (when-let* ((piece (etaf-xiangqi--cell table row column)))
        (push (cons (etaf-xiangqi--coord row column) piece) seen))
      (setq row (+ row row-step) column (+ column column-step)))
    (nreverse seen)))

(defun etaf-xiangqi--horse-leg (coord delta)
  "Return the leg square of a horse at COORD jumping by DELTA."
  (if (= 2 (abs (car delta)))
      (etaf-xiangqi--coord (+ (car coord) (/ (car delta) 2)) (cdr coord))
    (etaf-xiangqi--coord (car coord) (+ (cdr coord) (/ (cdr delta) 2)))))

(defun etaf-xiangqi--checkers (table)
  "Return the opponent pieces attacking TABLE's side-to-move general.
Each element is (COORD . PIECE).  Every other coordinate in this hint comes
from the public observation; the engine still owns legality and the match."
  (when-let* ((side (plist-get table :side))
              (square (etaf-xiangqi--general-coord table side)))
    (let ((enemy (if (eq side 'red) 'black 'red)) found)
      (cl-flet ((note (coord piece)
                  (when (eq enemy (etaf-xiangqi--side piece))
                    (push (cons coord piece) found))))
        ;; Rooks and the facing enemy general see along open lines; a cannon
        ;; attacks over exactly one screen.
        (dolist (direction etaf-xiangqi--straight-directions)
          (let* ((sight (etaf-xiangqi--sight table square (car direction) (cdr direction)))
                 (near (car sight)) (far (car (cdr sight))))
            (when near
              (when (memq (downcase (cdr near)) '(?r ?g))
                (note (car near) (cdr near)))
              (when (and far (= ?c (downcase (cdr far))))
                (note (car far) (cdr far))))))
        ;; Horses reach one-and-two away unless a piece hobbles their leg.
        (dolist (delta etaf-xiangqi--horse-jumps)
          (let* ((horse (etaf-xiangqi--coord (- (car square) (car delta))
                                             (- (cdr square) (cdr delta))))
                 (piece (and (etaf-xiangqi--on-board-p (car horse) (cdr horse))
                             (etaf-xiangqi--cell table (car horse) (cdr horse))))
                 (leg (etaf-xiangqi--horse-leg horse delta)))
            (when (and piece (= ?h (downcase piece))
                       (null (etaf-xiangqi--cell table (car leg) (cdr leg))))
              (note horse piece))))
        ;; Soldiers attack forward, and sideways once they cross the river.
        (let* ((front (etaf-xiangqi--coord (if (eq side 'red) (1- (car square))
                                            (1+ (car square)))
                                           (cdr square)))
               (flanks (list (etaf-xiangqi--coord (car square) (1- (cdr square)))
                             (etaf-xiangqi--coord (car square) (1+ (cdr square)))))
               (crossed (if (eq side 'red)
                            (lambda (row) (>= row 5))
                          (lambda (row) (<= row 4)))))
          (dolist (probe (cons front flanks))
            (when (etaf-xiangqi--on-board-p (car probe) (cdr probe))
              (let ((piece (etaf-xiangqi--cell table (car probe) (cdr probe))))
                (when (and piece (= ?s (downcase piece))
                           (or (equal probe front) (funcall crossed (car probe))))
                  (note probe piece)))))))
      (nreverse found))))

(defun etaf-xiangqi--check (table)
  "Return the coordinate of TABLE's checked general, or nil."
  (when (etaf-xiangqi--checkers table)
    (etaf-xiangqi--general-coord table (plist-get table :side))))

(defun etaf-xiangqi--froms (table)
  "Return every source coordinate that has a native legal move in TABLE."
  (delete-dups (mapcar (lambda (move) (plist-get move :from)) (plist-get table :moves))))

(defun etaf-xiangqi--targets (table coord)
  "Return every legal target coordinate from COORD in TABLE."
  (delq nil (mapcar (lambda (move) (when (equal coord (plist-get move :from))
                                     (plist-get move :to)))
                    (plist-get table :moves))))

(defun etaf-xiangqi--move (table from to)
  "Return the native move in TABLE going from FROM to TO, or nil."
  (cl-find-if (lambda (move) (and (equal from (plist-get move :from))
                                  (equal to (plist-get move :to))))
              (plist-get table :moves)))

(defun etaf-xiangqi--row-label (row)
  "Return the Chinese file label for ROW, red at the bottom."
  (format "%s%d" (if (< row 5) "黑" "红") (- 10 row)))

(defun etaf-xiangqi--send (session selected operation &optional arguments)
  "Send OPERATION and clear caller-owned SELECTED when the instance is ready."
  (when (eq (etaf-gamekit-status session) 'ready)
    (etaf-gamekit-action session operation arguments)
    (setf (etaf-value selected) nil)))

(defun etaf-xiangqi--press (session selected table coord &optional hint)
  "Choose the piece at COORD or submit the native move from the current selection.
Report in HINT why a pressed piece has no legal move this turn."
  (let ((move (etaf-xiangqi--move table (etaf-value selected) coord))
        (piece (etaf-xiangqi--cell table (car coord) (cdr coord))))
    (when hint (setf (etaf-value hint) nil))
    (cond
     (move (etaf-xiangqi--send session selected "act" (list :action (plist-get move :id))))
     ((equal (etaf-value selected) coord) (setf (etaf-value selected) nil))
     ((cl-find coord (etaf-xiangqi--froms table) :test #'equal) (setf (etaf-value selected) coord))
     (t
      (setf (etaf-value selected) nil)
      (when (and hint piece)
        (setf (etaf-value hint)
              (format "%s %s"
                      (etaf-xiangqi--name piece)
                      (if (etaf-xiangqi--checkers table)
                          "解不了将"
                        "本回合没有合法走法"))))))))

(defun etaf-xiangqi--snapshot (session selected operation)
  "Choose an explicit snapshot file for OPERATION."
  (when (eq (etaf-gamekit-status session) 'ready)
    (let ((file (etaf-call-with-input
                 (lambda () (read-file-name (concat (capitalize operation) " match: ")
                                            nil nil (equal operation "load") "xiangqi.json")))))
      (when file (etaf-xiangqi--send session selected operation (list :path (expand-file-name file)))))))

(provide 'etaf-xiangqi-model)
;;; etaf-xiangqi-model.el ends here
