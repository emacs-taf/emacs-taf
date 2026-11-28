;;; etaf-screensaver-layers.el --- Built-in scene layer kinds -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The generic layer kinds a spec can stack: rain, sand, particles, field
;; and text.  Each kind registers a VALIDATE, CREATE, STEP, DRAW and
;; optional RESIZE function with the DSL registry and receives
;; the layer plist, its own state, the engine context and the frame canvas.
;; Adding a new kind is one `etaf-screensaver--define-layer-kind' call; no
;; part of the engine or the workspace changes.

;;; Code:

(require 'cl-lib)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-dsl)

;;; rain -- column drops with tails.

(defun etaf-screensaver--rain-glyph (layer context)
  "Return a random glyph for LAYER in CONTEXT."
  (let ((glyphs (or (plist-get layer :glyphs) "01")))
    (aref glyphs (funcall (plist-get context :random) (length glyphs)))))

(etaf-screensaver--define-layer-kind 'rain
  :validate (lambda (layer)
              (when-let* ((glyphs (plist-get layer :glyphs)))
                (unless (and (stringp glyphs) (> (length glyphs) 0))
                  (etaf-screensaver--fail "rain :glyphs must be a nonempty string"))))
  :create (lambda (layer context)
            (let* ((rows (plist-get context :rows))
                   (columns (plist-get context :columns))
                   (random (plist-get context :random))
                   (drops (make-vector columns nil))
                   (glyphs (make-vector columns nil)))
              (dotimes (column columns)
                (aset drops column
                      (cons (- (funcall random (+ rows 24)) 24)
                            (+ 0.4 (/ (funcall random 160) 100.0))))
                (aset glyphs column (etaf-screensaver--rain-glyph layer context)))
              (list :drops drops :glyphs glyphs)))
  :step (lambda (layer state context)
          (let* ((etaf-screensaver--dsl-random (plist-get context :random))
                 (rows (plist-get context :rows))
                 (env (etaf-screensaver--dsl-env context))
                 (speed (etaf-screensaver--layer-number
                         (etaf-screensaver--layer-property layer :speed 8) env 8))
                 (direction (if (eq (plist-get layer :direction) 'up) -1 1))
                 (tail (or (etaf-screensaver--layer-number
                            (etaf-screensaver--layer-property layer :tail 8) env 8)
                           8))
                 (dt (plist-get context :dt))
                 (drops (plist-get state :drops))
                 (glyphs (plist-get state :glyphs)))
            (dotimes (column (length drops))
              (let* ((drop (aref drops column))
                     (next (+ (car drop)
                              (* direction dt speed (* (cdr drop) 14.0)))))
                (if (or (> (- next tail) rows) (< (+ next tail) 0))
                    (progn
                      (aset drops column
                            (cons (if (> direction 0) (- 0 4) (+ rows 4))
                                  (+ 0.4 (/ (funcall (plist-get context :random) 160) 100.0))))
                      (aset glyphs column (etaf-screensaver--rain-glyph layer context)))
                  (setcar drop next))))))
  :draw (lambda (layer state context canvas)
          (let* ((columns (plist-get context :columns))
                 (env (etaf-screensaver--dsl-env context))
                 (direction (if (eq (plist-get layer :direction) 'up) -1 1))
                 (tail (or (etaf-screensaver--layer-number
                            (etaf-screensaver--layer-property layer :tail 8) env 8)
                           8))
                 (head (etaf-screensaver--layer-char
                        (etaf-screensaver--layer-property layer :head "▓") env ?▓))
                 (color (etaf-screensaver--dsl-value
                         (etaf-screensaver--layer-property layer :color nil) env))
                 (drops (plist-get state :drops))
                 (glyphs (plist-get state :glyphs)))
            (dotimes (column (min columns (length drops)))
              (let ((position (car (aref drops column))))
                (dotimes (offset (max 1 (round tail)))
                  (let ((row (- position (* direction offset))))
                    (etaf-screensaver--canvas-draw
                     canvas (round row) column
                     (if (zerop offset) head (aref glyphs column))
                     color))))))))

;;; sand -- falling materials with declarative movement.

(defconst etaf-screensaver--sand-offsets
  '((down . (0 . 1)) (down-left . (-1 . 1)) (down-right . (1 . 1))
    (left . (-1 . 0)) (right . (1 . 0))
    (up . (0 . -1)) (up-left . (-1 . -1)) (up-right . (1 . -1)))
  "Movement names to (COLUMN-OFFSET . ROW-OFFSET) pairs.")

(defun etaf-screensaver--sand-materials (layer)
  "Return LAYER's validated material table."
  (let ((materials (plist-get layer :materials)))
    (unless (and (proper-list-p materials) materials)
      (etaf-screensaver--fail "sand layer needs a nonempty :materials list"))
    (dolist (material materials)
      (unless (and (proper-list-p material)
                   (plist-get material :key)
                   (plist-get material :char))
        (etaf-screensaver--fail "each sand material needs :key and :char: %S" material))
      (dolist (move (plist-get material :moves))
        (unless (assq move etaf-screensaver--sand-offsets)
          (etaf-screensaver--fail "unknown sand move %S in %S" move material))))
    materials))

(defun etaf-screensaver--sand-index (materials key)
  "Return MATERIALS' one-based index for KEY, or nil."
  (let ((position (cl-position key materials
                               :key (lambda (material) (plist-get material :key)))))
    (and position (1+ position))))

(defun etaf-screensaver--sand-order (moves random)
  "Return MOVES with each opposite pair in random order."
  (let ((copy (copy-sequence moves)))
    (cl-labels ((swap (left right)
                  (let ((li (cl-position left copy))
                        (ri (cl-position right copy)))
                    (when (and li ri (zerop (funcall random 2)))
                      (let ((left-value (nth li copy)))
                        (setcar (nthcdr li copy) (nth ri copy))
                        (setcar (nthcdr ri copy) left-value))))))
      (swap 'left 'right)
      (swap 'down-left 'down-right)
      (swap 'up-left 'up-right))
    copy))

(defun etaf-screensaver--sand-can-enter (target material materials)
  "Return whether MATERIAL can move into TARGET given MATERIALS.
An empty cell accepts everything; a material accepts a value whose key is
listed in its own :flows-through."
  (if (zerop target)
      t
    (let ((occupant (nth (1- target) materials)))
      (memq (plist-get material :key) (plist-get occupant :flows-through)))))

(defun etaf-screensaver--sand-rain (layer state context materials)
  "Drop LAYER's rain grains into STATE for CONTEXT."
  (let* ((env (etaf-screensaver--dsl-env context))
         (count (max 0 (round (etaf-screensaver--layer-number
                               (etaf-screensaver--layer-property layer :rain 0)
                               env 0))))
         (key (or (plist-get layer :rain-material)
                  (plist-get (car materials) :key)))
         (index (etaf-screensaver--sand-index materials key))
         (random (plist-get context :random))
         (cells (plist-get state :cells))
         (columns (plist-get state :columns)))
    (when index
      (dotimes (_ count)
        (let ((column (funcall random columns)))
          (when (zerop (aref cells column))
            (aset cells column index)))))))

(defun etaf-screensaver--sand-physics (_layer state context materials)
  "Advance STATE's materials one physics step for CONTEXT."
  (let* ((cells (plist-get state :cells))
         (rows (plist-get state :rows))
         (columns (plist-get state :columns))
         (random (plist-get context :random)))
    (cl-loop for row from (1- rows) downto 0 do
             (dotimes (column columns)
               (let ((value (aref cells (+ (* row columns) column))))
                 (when (> value 0)
                   (let* ((material (nth (1- value) materials))
                          (moves (etaf-screensaver--sand-order
                                  (or (plist-get material :moves) '()) random)))
                     (cl-loop for move in moves
                              for offset = (cdr (assq move etaf-screensaver--sand-offsets))
                              for target-row = (+ row (cdr offset))
                              for target-column = (+ column (car offset))
                              when (and (>= target-row 0) (< target-row rows)
                                        (>= target-column 0) (< target-column columns))
                              do (let* ((target (+ (* target-row columns) target-column))
                                        (occupant (aref cells target)))
                                   (when (etaf-screensaver--sand-can-enter
                                          occupant material materials)
                                     (aset cells target value)
                                     (aset cells (+ (* row columns) column) occupant)
                                     (cl-return)))))))))))

(etaf-screensaver--define-layer-kind 'sand
  :validate (lambda (layer)
              (etaf-screensaver--sand-materials layer))
  :create (lambda (layer context)
            (let* ((rows (plist-get context :rows))
                   (columns (plist-get context :columns))
                   (state (list :rows rows :columns columns
                                :cells (make-vector (* rows columns) 0))))
              (etaf-screensaver--sand-rain layer state context
                                           (etaf-screensaver--sand-materials layer))
              state))
  :step (lambda (layer state context)
          (let ((materials (etaf-screensaver--sand-materials layer)))
            (etaf-screensaver--sand-physics layer state context materials)
            (etaf-screensaver--sand-rain layer state context materials)))
  :resize (lambda (_layer state context)
            (let* ((rows (plist-get context :rows))
                   (columns (plist-get context :columns))
                   (old-rows (plist-get state :rows))
                   (old-columns (plist-get state :columns))
                   (old (plist-get state :cells))
                   (cells (make-vector (* rows columns) 0))
                   (copy-rows (min rows old-rows))
                   (copy-columns (min columns old-columns)))
              (dotimes (row copy-rows)
                (dotimes (column copy-columns)
                  (aset cells (+ (* row columns) column)
                        (aref old (+ (* row old-columns) column)))))
              (setf (plist-get state :rows) rows
                    (plist-get state :columns) columns
                    (plist-get state :cells) cells)
              state))
  :draw (lambda (layer state _context canvas)
          (let* ((cells (plist-get state :cells))
                 (rows (plist-get state :rows))
                 (columns (plist-get state :columns))
                 (materials (etaf-screensaver--sand-materials layer)))
            (dotimes (row rows)
              (dotimes (column columns)
                (let ((value (aref cells (+ (* row columns) column))))
                  (when (> value 0)
                    (let ((material (nth (1- value) materials)))
                      (etaf-screensaver--canvas-draw
                       canvas row column
                       (or (plist-get material :char) ?#)
                       (plist-get material :color))))))))))

;;; particles -- numeric particles driven by expressions.

(defun etaf-screensaver--particle-fields (value name)
  "Validate VALUE as a field expression alist and return it.
NAME names the property for the error message."
  (unless (proper-list-p value)
    (etaf-screensaver--fail "particles %s must be an alist of (field expression)" name))
  (dolist (entry value)
    (unless (and (proper-list-p entry) (= 2 (length entry)) (symbolp (car entry)))
      (etaf-screensaver--fail "particles %s entries must be (field expression): %S"
                              name entry)))
  value)

(defun etaf-screensaver--particle-init (layer context index)
  "Return a fresh field alist for particle INDEX of LAYER in CONTEXT."
  (let* ((base (etaf-screensaver--dsl-env context (list (cons 'i index))))
         (env base)
         (fields nil))
    (dolist (entry (etaf-screensaver--particle-fields
                    (etaf-screensaver--layer-property layer :init nil) :init))
      (let ((value (etaf-screensaver--dsl-value (cadr entry) env)))
        (push (cons (car entry) value) fields)
        (setq env (cons (cons (car entry) value) env))))
    (nreverse fields)))

(defun etaf-screensaver--particle-update (layer fields base)
  "Apply LAYER's :update expressions to FIELDS in BASE environment."
  (dolist (entry (etaf-screensaver--particle-fields
                  (etaf-screensaver--layer-property layer :update nil) :update))
    (let ((value (etaf-screensaver--dsl-value (cadr entry) (append fields base))))
      (if (assq (car entry) fields)
          (setcdr (assq (car entry) fields) value)
        (push (cons (car entry) value) fields))))
  fields)

(defun etaf-screensaver--particle-wrap (layer fields base)
  "Apply LAYER's :wrap rules to FIELDS in BASE environment."
  (dolist (rule (etaf-screensaver--layer-property layer :wrap nil))
    (let* ((field (car rule))
           (low (etaf-screensaver--dsl-value (nth 1 rule) (append fields base)))
           (high (etaf-screensaver--dsl-value (nth 2 rule) (append fields base)))
           (cell (assq field fields)))
      (when cell
        (cond ((< (cdr cell) low) (setcdr cell high))
              ((> (cdr cell) high) (setcdr cell low))))))
  fields)

(defun etaf-screensaver--particle-recycle (layer fields base)
  "Apply LAYER's :recycle rule to FIELDS in BASE environment."
  (let ((recycle (plist-get layer :recycle)))
    (when (and recycle
               (etaf-screensaver--dsl-value (plist-get recycle :when)
                                            (append fields base)))
      (dolist (entry (etaf-screensaver--particle-fields
                      (plist-get recycle :fields) :recycle))
        (let ((value (etaf-screensaver--dsl-value (cadr entry)
                                                  (append fields base))))
          (if (assq (car entry) fields)
              (setcdr (assq (car entry) fields) value)
            (push (cons (car entry) value) fields))))))
  fields)

(etaf-screensaver--define-layer-kind 'particles
  :validate (lambda (layer)
              (etaf-screensaver--particle-fields
               (etaf-screensaver--layer-property layer :init nil) :init)
              (etaf-screensaver--particle-fields
               (etaf-screensaver--layer-property layer :update nil) :update))
  :create (lambda (layer context)
            (let* ((env (etaf-screensaver--dsl-env context))
                   (count (max 1 (round (etaf-screensaver--layer-number
                                         (etaf-screensaver--layer-property layer :count 50)
                                         env 50))))
                   (particles (make-vector count nil)))
              (dotimes (index count)
                (aset particles index (etaf-screensaver--particle-init layer context index)))
              (list :particles particles)))
  :step (lambda (layer state context)
          (let ((particles (plist-get state :particles)))
            (dotimes (index (length particles))
              (let* ((fields (aref particles index))
                     (base (etaf-screensaver--dsl-env context (list (cons 'i index)))))
                (etaf-screensaver--particle-update layer fields base)
                (etaf-screensaver--particle-wrap layer fields base)
                (etaf-screensaver--particle-recycle layer fields base)))))
  :draw (lambda (layer state context canvas)
          (let* ((etaf-screensaver--dsl-random (plist-get context :random))
                 (draw (plist-get layer :draw))
                 (fallback-color (etaf-screensaver--dsl-value
                                  (etaf-screensaver--layer-property layer :color nil)
                                  (etaf-screensaver--dsl-env context)))
                 (particles (plist-get state :particles)))
            (dotimes (index (length particles))
              (let* ((fields (aref particles index))
                     (base (etaf-screensaver--dsl-env context (list (cons 'i index))))
                     (env (append fields base))
                     (row (etaf-screensaver--layer-number
                           (plist-get draw :y) env (or (cdr (assq 'y fields)) 0)))
                     (column (etaf-screensaver--layer-number
                              (plist-get draw :x) env (or (cdr (assq 'x fields)) 0)))
                     (character (etaf-screensaver--layer-char
                                 (plist-get draw :char) env ?*))
                     (color (if (plist-member draw :color)
                                (etaf-screensaver--dsl-value (plist-get draw :color) env)
                              fallback-color)))
                (etaf-screensaver--canvas-draw canvas (round row) (round column)
                                               character color))))))

;;; field -- one expression per cell.

(etaf-screensaver--define-layer-kind 'field
  :validate (lambda (layer)
              (unless (plist-get layer :value)
                (etaf-screensaver--fail "field layer needs a :value expression"))
              (when-let* ((palette (plist-get layer :palette)))
                (unless (and (proper-list-p palette)
                             (cl-every #'stringp palette))
                  (etaf-screensaver--fail "field :palette must be a list of colors")))
              (when-let* ((range (plist-get layer :range)))
                (unless (and (proper-list-p range) (= 2 (length range)))
                  (etaf-screensaver--fail "field :range must be (LOW HIGH)"))))
  :create (lambda (layer context)
            (let* ((globals (etaf-screensaver--dsl-globals context))
                   (env (append (list (cons 'x 0.0) (cons 'y 0.0))
                                (etaf-screensaver--dsl-params context) globals))
                   (coordinates (vector 0 0 0)))
              (list :environment env :globals globals :coordinates coordinates
                    :value (cdr (etaf-screensaver--field-expression
                                 (plist-get layer :value) env coordinates
                                 (plist-get context :columns) (plist-get context :rows))))))
  :step (lambda (_layer _state _context) nil)
  :draw (lambda (layer state context canvas)
          (let* ((etaf-screensaver--dsl-random (plist-get context :random))
                 (rows (plist-get context :rows))
                 (columns (plist-get context :columns))
                 (env (plist-get state :environment))
                 (base (cddr env))
                 (x-cell (car env))
                 (y-cell (cadr env))
                 (coordinates (plist-get state :coordinates))
                 (value-function (plist-get state :value))
                 (_refresh
                  (dolist (binding (etaf-screensaver--dsl-globals context))
                    (setcdr (assq (car binding) (plist-get state :globals)) (cdr binding))))
                 (ramp (or (plist-get layer :ramp) " .:-=+*#%@"))
                 (palette (plist-get layer :palette))
                 (range (plist-get layer :range))
                 (block (plist-get layer :block))
                 (block-width (max 1 (or (nth 0 block) 1)))
                 (block-height (max 1 (or (nth 1 block) 1)))
                 (low (if range (etaf-screensaver--layer-number (car range) base 0) 0.0))
                 (high (if range (etaf-screensaver--layer-number (cadr range) base 1) 1.0))
                 (span (if (= low high) 1.0 (- high low))))
            (cl-incf (aref coordinates 2))
            (cl-loop for row from 0 below rows by block-height do
                     (setcdr y-cell (float row))
                     (aset coordinates 1 row)
                     (cl-loop for column from 0 below columns by block-width do
                              (setcdr x-cell (float column))
                              (aset coordinates 0 column)
                              (let* ((value (funcall value-function))
                                     (intensity (etaf-screensaver--layer-clamp
                                                 (/ (- (float value) low) span) 0.0 1.0))
                                     (character (etaf-screensaver--layer-ramp-char ramp intensity))
                                     (color (and palette
                                                 (etaf-screensaver--layer-palette-color
                                                  palette intensity))))
                                (dotimes (dy block-height)
                                  (dotimes (dx block-width)
                                    (etaf-screensaver--canvas-draw
                                     canvas (+ row dy) (+ column dx)
                                     character color)))))))))

;;; text -- scrolling or centered text.

(etaf-screensaver--define-layer-kind 'text
  :validate (lambda (layer)
              (let ((lines (plist-get layer :lines)))
                (unless (or (stringp lines)
                            (and (proper-list-p lines) (cl-every #'stringp lines)))
                  (etaf-screensaver--fail "text layer needs :lines as a string or list of strings")))
              (when-let* ((align (plist-get layer :align)))
                (unless (memq align '(left center right))
                  (etaf-screensaver--fail "text :align must be left, center or right"))))
  :create (lambda (_layer _context) (list :offset 0.0))
  :step (lambda (layer state context)
          (let* ((etaf-screensaver--dsl-random (plist-get context :random))
                 (env (etaf-screensaver--dsl-env context))
                 (scroll (etaf-screensaver--dsl-value
                          (etaf-screensaver--layer-property layer :scroll t) env))
                 (speed (etaf-screensaver--layer-number
                         (etaf-screensaver--layer-property layer :speed 1) env 1)))
            (when scroll
              (cl-incf (plist-get state :offset) (* speed (plist-get context :dt))))))
  :draw (lambda (layer state context canvas)
          (let* ((rows (plist-get context :rows))
                 (columns (plist-get context :columns))
                 (env (etaf-screensaver--dsl-env context))
                 (lines (let ((value (plist-get layer :lines)))
                          (if (stringp value) (list value) value)))
                 (count (length lines))
                 (color (etaf-screensaver--dsl-value
                         (etaf-screensaver--layer-property layer :color nil) env))
                 (align (or (plist-get layer :align) 'center))
                 (scroll (etaf-screensaver--dsl-value
                          (etaf-screensaver--layer-property layer :scroll t) env))
                 (offset (if scroll (plist-get state :offset)
                           (- (/ (- rows count) 2.0)))))
            (dotimes (row rows)
              (let* ((index (if scroll
                                (mod (+ row (floor offset)) count)
                              (+ row (floor offset))))
                     (line (nth index lines)))
                (when (and line (>= index 0) (< index count))
                  (let* ((width (string-width line))
                         (column (pcase align
                                   ('left 0)
                                   ('right (max 0 (- columns width)))
                                   (_ (max 0 (/ (- columns width) 2))))))
                    (etaf-screensaver--canvas-draw-text canvas row column line color))))))))

(provide 'etaf-screensaver-layers)
;;; etaf-screensaver-layers.el ends here
