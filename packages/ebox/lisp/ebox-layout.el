;;; ebox-layout.el --- Retained layout and line composition -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Layout assigns each node a margin box measured in pixels horizontally and
;; lines vertically, positioned in its parent's content box.  Containers keep
;; their flow items (child nodes or anonymous paragraphs) sorted by line, so
;; a vertical stack absorbs a child's height change by shifting later items
;; and reports only that child's lines as damage.  Horizontal containers,
;; definite heights and absolutely positioned overlays relayout their own
;; children, which are cached, and damage only their own line range.
;;
;; `ebox--node-parts' composes one line of a margin box on demand as a flat
;; list of its descendants' strings and caches it on the node; paragraphs
;; cache their wrapped lines.  A root line is concatenated once by
;; `ebox--join', and every line is exactly the box width in pixels.

;;; Code:

(require 'cl-lib)
(require 'ebox-node)
(require 'ebox-image)

(declare-function ebox--layout-flex "ebox-flex" (node geo cbh))
(declare-function ebox--layout-grid "ebox-flex" (node geo cbh))
(declare-function ebox--grid-intrinsic "ebox-flex" (node))
(declare-function ebox--flex-natural "ebox-flex" (node geo))

;;;; Layout records

(ebox--defstruct (ebox-geo (:constructor ebox-geo--make) (:copier nil))
  "Resolved box metrics and content items of one laid-out node."
  (ml 0) (mr 0) (mt 0) (mb 0) (bl 0) (br 0) (pl 0) (pr 0) (pt 0) (pb 0)
  (bw 0) (bh 0) (cw 0) (vh 0) (ch 0) (scroll 0)
  items (n 0) stack kind gap iused nat)

(defmacro ebox--do-items (spec &rest body)
  "Bind (VAR GEO) to each of GEO's N items in order and run BODY.
Stacked items are a chunked sequence; other layouts keep a vector."
  (declare (indent 1))
  (let ((items (make-symbol "items")) (i (make-symbol "i")))
    `(let ((,items (ebox-geo-items ,(cadr spec))))
       (if (recordp ,items)
           (ebox--seq-do (,(car spec) ,items) ,@body)
         (dotimes (,i (ebox-geo-n ,(cadr spec)))
           (let ((,(car spec) (aref ,items ,i)))
             ,@body))))))

(defsubst ebox--set-items (geo items)
  "Store vector ITEMS as GEO's unstacked items."
  (dotimes (i (length items))
    (let ((item (aref items i)))
      (when (ebox-node-p item) (setf (ebox-node-irun item) nil))))
  (setf (ebox-geo-items geo) items
        (ebox-geo-n geo) (length items)))

(ebox--defstruct (ebox-para (:constructor ebox-para--make) (:copier nil))
  "Anonymous paragraph of inline nodes inside one block owner."
  owner nodes (x 0) (y 0) (w 0) (h 0) lines run (pos 0) pieces key)

(defvar ebox--vacated (make-hash-table :test 'eq :weakness 'key)
  "Host border-box line spans, (Y . H), that departed overlays covered.")

(defvar ebox--damage nil
  "Damage records (ITEM FROM OLD NEW) collected by the current layout.")

(defvar ebox--record t
  "Non-nil when layout should record damage for relaid nodes.")

(defvar ebox--decorate-function nil
  "Function of NODE, LINE and FRESH returning LINE with interaction properties.
FRESH non-nil means LINE is a new string the function may modify.")

(defsubst ebox--hidden-p (node)
  "Return non-nil when NODE does not paint."
  (ebox-cs-hidden (ebox-node-cs node)))

(defsubst ebox--abs-p (node)
  "Return non-nil when NODE is absolutely positioned below a parent."
  (and (ebox-cs-abs (ebox-node-cs node)) (ebox-node-parent node) t))

(defun ebox--inline-p (node)
  "Return non-nil when NODE participates in inline formatting."
  (or (eq (ebox-node-tag node) 'text)
      (and (eq (ebox-node-tag node) 'box)
           (eq (ebox-cs-outer (ebox-node-cs node)) 'inline)
           (let ((ok t))
             (ebox--do-kids (child node)
               (unless (or (ebox--abs-p child) (ebox--inline-p child))
                 (setq ok nil)))
             ok))))

;;;; Text units

;; A text node caches its measurement in a vector
;; [FONTFACE TEXT EPOCH WRAP MAXW MINW NEWLINE UNITS].  UNITS is computed
;; only when a paragraph must break: a flat vector [END WIDTH KIND ...]
;; of display units, each starting where the previous one ends.

(defun ebox--text-meas (node)
  "Return text NODE's measurement vector under its font and wrap mode."
  (let* ((cs (ebox-node-cs node))
         (fontface (ebox-cs-fontface cs))
         (wrap (ebox-cs-wrap cs))
         (text (ebox-node-text node))
         (m (ebox-node-meas node)))
    (if (and m (eq (aref m 0) fontface) (eq (aref m 1) text)
             (eq (aref m 2) ebox--width-epoch) (eq (aref m 3) wrap))
        m
      (unless m
        (setq m (make-vector 8 nil))
        (setf (ebox-node-meas node) m))
      (aset m 0 fontface) (aset m 1 text) (aset m 2 ebox--width-epoch) (aset m 3 wrap)
      (aset m 7 nil)
      (if (ebox--display-free-p text)
          (ebox--measure-runs m text fontface wrap)
        (ebox--measure-units m text (ebox--unit-vector text fontface) wrap))
      m)))

(defsubst ebox--word-step (word w ch wrap)
  "Return the unbreakable run width after a unit of width W starting with CH."
  (cond ((memq wrap '(none nowrap)) (+ word w))
        ((eq wrap 'char) w)
        ((memq ch '(?\s ?\t)) 0)
        ((ebox--cjk-char-p ch) w)
        (t (+ word w))))

(defun ebox--measure-runs (m text face wrap)
  "Store MAXW, MINW and NEWLINE of display-free TEXT under FACE in M.
Each run of TEXT's own `face' property is measured with that face painted
over FACE, without building per-cluster units: lines that need breaking
build them on demand."
  (let* ((len (length text)) (pos 0) (run-end 0)
         run-face ascii wide
         (maxw 0) (minw 0) (line 0) (word 0) (newline nil))
    (while (< pos len)
      (when (>= pos run-end)
        (let* ((own (get-text-property pos 'face text))
               (table (ebox--face-table
                       (setq run-face (if own (ebox--merge-face own face) face)))))
          (setq run-end (or (next-single-property-change pos 'face text len) len)
                ascii (car table) wide (cdr table))))
      (let* ((ch (aref text pos))
             (next (if (and (< ch 128)
                            (or (= (1+ pos) len) (< (aref text (1+ pos)) 128)))
                       (1+ pos)
                     (ebox--cluster-end text pos len)))
             (w (if (= next (1+ pos))
                    (or (if (< ch 128) (aref ascii ch) (gethash ch wide))
                        (ebox--char-width ch run-face))
                  (ebox--cluster-width text pos next run-face))))
        (if (eq ch ?\n)
            (setq maxw (max maxw line) line 0 word 0 newline t)
          (setq line (+ line w)
                word (ebox--word-step word w ch wrap)
                minw (max minw word)))
        (setq pos next)))
    (aset m 4 (max maxw line))
    (aset m 5 minw)
    (aset m 6 newline)))

(defun ebox--measure-units (m text units wrap)
  "Store TEXT's widths from its unit vector UNITS under WRAP in M."
  (let ((maxw 0) (minw 0) (line 0) (word 0) (newline nil)
        (i 0) (n (length units)) (start 0))
    (while (< i n)
      (let ((ch (aref text start)) (w (aref units (1+ i))))
        (if (eq ch ?\n)
            (setq maxw (max maxw line) line 0 word 0 newline t)
          (setq line (+ line w)
                word (ebox--word-step word w ch wrap)
                minw (max minw word))))
      (setq start (aref units i) i (+ i 3)))
    (aset m 4 (max maxw line))
    (aset m 5 minw)
    (aset m 6 newline)
    (aset m 7 units)))

(defun ebox--unit-vector (text face)
  "Return TEXT's display units under FACE as a flat [END WIDTH KIND ...]."
  (let* ((units (ebox--units text face))
         (v (make-vector (* 3 (length units)) nil))
         (i 0))
    (dolist (u units)
      (aset v i (nth 1 u))
      (aset v (+ i 1) (nth 2 u))
      (aset v (+ i 2) (ebox--unit-kind text u))
      (setq i (+ i 3)))
    v))

(defun ebox--text-unit-vector (node)
  "Return text NODE's cached unit vector."
  (let ((m (ebox--text-meas node)))
    (or (aref m 7)
        (aset m 7 (ebox--unit-vector (ebox-node-text node) (aref m 0))))))

;;;; Inline pieces

(defun ebox--run-face (node)
  "Return the face painted on NODE's text."
  (ebox-cs-face (ebox-node-cs node)))

(defun ebox--fit-glyphs (string text fontface)
  "Display STRING's clusters taller than the line in their fitted form.
TEXT is STRING's undecorated source and FONTFACE the face it was measured
with; clusters carrying their own display property are left alone.  Every
occurrence of one cluster shares one fitted display, which Emacs would
paint as a single glyph, so a run of the same cluster alternates between
the display and its twin."
  (let ((len (length text)) (pos 0) last)
    (while (and (< pos len)
                (setq pos (ebox--next-fit-candidate text pos)))
      (let* ((start (if (and (> pos 0) (ebox--extension-char-p (aref text pos)))
                        (1- pos)
                      pos))
             (end (ebox--cluster-end text start len))
             (own (get-text-property start 'display text)))
        (if own
            (setq last own)
          (let* ((face (get-text-property start 'face text))
                 (cluster (substring-no-properties text start end))
                 (fit (ebox--fit cluster (if face (ebox--merge-face face fontface)
                                           fontface))))
            (when fit
              (let ((display (cdr fit)))
                (when (eq display last)
                  (setq display (ebox--display-twin display)))
                (put-text-property start end 'display display string)
                (setq last display)))))
        (setq pos (max end (1+ pos)))))
    string))

(defvar ebox--editing nil
  "Alist of text nodes under input sessions to their preedit span or nil.
Their pieces carry each character's value offset as `ebox-offset'.")

(defun ebox--stamp-offsets (string span)
  "Put each character's index on STRING as `ebox-offset'; underline SPAN."
  (dotimes (i (length string))
    (put-text-property i (1+ i) 'ebox-offset i string))
  (when span
    (add-face-text-property (car span) (cdr span) '(:underline t) nil string))
  string)

(defun ebox--decorate-text (text face node)
  "Return TEXT carrying FACE (after its own faces) and NODE ownership."
  (let ((string (copy-sequence text)) (len (length text)))
    (when (> len 0)
      (if (and face (ebox--plain-string-p text))
          (put-text-property 0 len 'face face string)
        (when face (add-face-text-property 0 len face t string)))
      (put-text-property 0 len 'ebox-node node string)
      (when (and (not noninteractive) (ebox--fit-candidate-string-p text))
        (ebox--fit-glyphs string text (ebox-cs-fontface (ebox-node-cs node)))))
    string))

(defun ebox--hidden-text (node)
  "Return hidden text NODE's characters displayed as blank space.
The characters stay, so hidden text breaks exactly like visible text."
  (let* ((text (ebox-node-text node))
         (units (ebox--text-unit-vector node))
         (blank (substring-no-properties text))
         (i 0) (n (length units)) (start 0))
    (while (< i n)
      (let ((end (aref units i)))
        (unless (eq (aref text start) ?\n)
          (put-text-property start end 'display
                             (list 'space :width (list (aref units (1+ i))))
                             blank))
        (setq start end i (+ i 3))))
    blank))

(defun ebox--push-pad (pieces width face)
  "Push a pad piece WIDTH pixels wide painted with FACE onto PIECES."
  (if (> width 0) (cons (cons (ebox--space width face) width) pieces) pieces))

(defun ebox--node-pieces (node pieces)
  "Push NODE's inline pieces onto PIECES in reverse order and return them."
  (let ((mark pieces))
    (cond
     ((ebox--abs-p node) nil)
     ((eq (ebox-node-tag node) 'text)
      (push (cons (if (ebox--hidden-p node)
                      (ebox--hidden-text node)
                    (let ((string (ebox--decorate-text (ebox-node-text node)
                                                       (ebox--run-face node) node))
                          (editing (and ebox--editing (assq node ebox--editing))))
                      (if editing (ebox--stamp-offsets string (cdr editing)) string)))
                  node)
            pieces))
     (t
      (let* ((cs (ebox-node-cs node))
             (parent (ebox-node-parent node))
             (parent-face (and parent (ebox-cs-padface (ebox-node-cs parent))))
             (padface (ebox-cs-padface cs)))
        (setq pieces (ebox--push-pad pieces (ebox--hpx (ebox-cs-ml cs) cs 0) parent-face))
        (when (ebox-cs-blc cs)
          (setq pieces (ebox--push-pad pieces (ebox-cs-bl cs)
                                       (ebox--border-face (ebox-cs-blc cs)))))
        (setq pieces (ebox--push-pad pieces (ebox--hpx (ebox-cs-pl cs) cs 0) padface))
        (ebox--do-kids (child node) (setq pieces (ebox--node-pieces child pieces)))
        (setq pieces (ebox--push-pad pieces (ebox--hpx (ebox-cs-pr cs) cs 0) padface))
        (when (ebox-cs-brc cs)
          (setq pieces (ebox--push-pad pieces (ebox-cs-br cs)
                                       (ebox--border-face (ebox-cs-brc cs)))))
        (setq pieces (ebox--push-pad pieces (ebox--hpx (ebox-cs-mr cs) cs 0) parent-face)))))
    (when (and (ebox-node-inter node) ebox--decorate-function)
      (let ((cell pieces))
        (while (and cell (not (eq cell mark)))
          (setcar (car cell) (funcall ebox--decorate-function node (caar cell)))
          (setq cell (cdr cell)))))
    pieces))

(defun ebox--inline-key (node key)
  "Push the values NODE's inline pieces depend on onto KEY and return it."
  (setq key (cons (ebox-node-cs node)
                  (cons (ebox-node-text node) (cons (ebox-node-inter node) key))))
  (ebox--do-kids (kid node) (setq key (ebox--inline-key kid key)))
  key)

(defun ebox--para-cached-pieces (para)
  "Return PARA's inline pieces, rebuilding them when an inline node changed."
  (let ((key (list ebox--width-epoch (ebox-node-cs (ebox-para-owner para)))))
    (dolist (node (ebox-para-nodes para)) (setq key (ebox--inline-key node key)))
    (let ((old (ebox-para-key para)) (new key))
      (while (and old new (eq (car old) (car new))) (setq old (cdr old) new (cdr new)))
      (if (and (null old) (null new) (ebox-para-pieces para))
          (ebox-para-pieces para)
        (setf (ebox-para-key para) key
              (ebox-para-pieces para) (ebox--para-pieces (ebox-para-nodes para)))))))

(defun ebox--para-pieces (nodes)
  "Return inline pieces for NODES as (STRING . SOURCE) in order.
SOURCE is the text node a string displays, or a pad's pixel width."
  (let (pieces)
    (dolist (node nodes) (setq pieces (ebox--node-pieces node pieces)))
    (nreverse pieces)))

(defun ebox--piece-units (piece)
  "Return PIECE's unit vector."
  (let ((source (cdr piece)))
    (if (integerp source) (vector 1 source 'glue) (ebox--text-unit-vector source))))

(defun ebox--pieces-line-width (pieces)
  "Return the width of PIECES on one line, or nil when one has a newline."
  (let ((total 0))
    (catch 'newline
      (dolist (piece pieces total)
        (let ((source (cdr piece)))
          (setq total
                (+ total
                   (if (integerp source) source
                     (let ((m (ebox--text-meas source)))
                       (when (aref m 6) (throw 'newline nil))
                       (aref m 4))))))))))

(defun ebox--border-face (color)
  "Return the side border face for COLOR."
  (ebox--intern-face (list :background (if (eq color 'default) "gray50" color))))

(defvar ebox--text-border-rules 'unknown
  "Cached answer to whether a terminal draws box rules one cell wide.")

(defun ebox--text-border-rules-p ()
  "Return non-nil when a terminal frame draws box rules one cell wide.
Box-drawing characters are East Asian ambiguous: terminals draw them one
cell wide, so use them only where the width table agrees."
  (if (eq ebox--text-border-rules 'unknown)
      (setq ebox--text-border-rules
            (and (ebox--text-display-p) (= 1 (string-width "─"))))
    ebox--text-border-rules))

(defun ebox--text-border-face (color bg)
  "Return a face painting COLOR as text on background BG."
  (let ((fg (if (eq color 'default) (face-foreground 'default nil t) color)))
    (if bg (list :foreground fg :background bg) (list :foreground fg))))

(defun ebox--border-side (width color side bgface)
  "Return a WIDTH-cell vertical border on SIDE painted with COLOR.
A graphical frame fills the cells; a text frame draws one rule on the outer
edge over the background of BGFACE.  Side border cells carry `ebox-border' so
hover decoration preserves their border paint instead of erasing it."
  (let ((cell
         (if (not (ebox--text-border-rules-p))
             (ebox--space width (ebox--border-face color))
           (let* ((bg (ebox--face-background bgface))
                  (rule (propertize "│" 'face (ebox--text-border-face color bg)))
                  (pad (ebox--space (max 0 (1- width))
                                    (and bg (ebox--intern-face (list :background bg))))))
             (if (eq side 'left) (concat rule pad) (concat pad rule))))))
    (when (> (length cell) 0)
      (setq cell (copy-sequence cell))
      (put-text-property 0 (length cell) 'ebox-border t cell)
      (puthash cell width ebox--part-widths))
    cell))

(defun ebox--merge-face-attr (face key value)
  "Return FACE carrying border attribute KEY VALUE without mutating FACE.
Keeps a flat plist face as a single interned plist so callers reading
`mouse-face' attributes with `plist-get' and row-sharing `eq' checks both hold."
  (ebox--intern-face
   (cond
    ((null face) (list key value))
    ((keywordp (car-safe face))
     (plist-put (copy-sequence face) key value))
    ((listp face)
     (cons (list key value) face))
    (t (list (list key value) face)))))

(defun ebox--add-border-face (string key value)
  "Apply border attribute KEY VALUE to STRING's `face' and any `mouse-face' runs.
Emacs renders `mouse-face' instead of `face' while the pointer hovers a run, so
a child control's hover face on an ancestor's top or bottom edge would otherwise
erase the border rule on hover."
  (let ((len (length string)))
    (when (> len 0)
      (add-face-text-property 0 len (list key value) t string)
      (let ((pos 0))
        (while (< pos len)
          (let* ((next (or (next-single-property-change pos 'mouse-face string len) len))
                 (mf (get-text-property pos 'mouse-face string)))
            (when mf
              (put-text-property pos next 'mouse-face
                                 (ebox--merge-face-attr mf key value)
                                 string))
            (setq pos next)))))))

(defun ebox--text-frame-ink-p (line)
  "Return non-nil when LINE holds only blanks and vertical border rules."
  (not (string-match-p "[^│ \t]" (substring-no-properties line))))

(defun ebox--text-frame-row (node geo top)
  "Return box-drawing text for NODE's blank top or bottom border row.
The row gets a corner where a side border exists and a one-cell rule across
the content width.  Return nil when the row cannot be drawn one cell per
glyph."
  (let* ((cs (ebox-node-cs node))
         (bw (ebox-geo-bw geo))
         (bl (ebox-geo-bl geo))
         (br (ebox-geo-br geo))
         (inner (- bw bl br))
         (color (if top (ebox-cs-btc cs) (ebox-cs-bbc cs)))
         (bg (or (ebox--face-background (ebox-cs-padface cs))
                 (ebox--face-background (ebox--parent-padface node))))
         (face (ebox--text-border-face color bg))
         parts)
    (when (>= inner 0)
      (when (> bl 0)
        (setq parts (append parts
                            (list (propertize (if top "┌" "└") 'face
                                              (ebox--text-border-face
                                               (ebox-cs-blc cs) bg)))))
        (when (> bl 1)
          (setq parts (append parts
                              (list (propertize (make-string (1- bl) ?─)
                                                'face face))))))
      (when (> inner 0)
        (setq parts (append parts
                            (list (propertize (make-string inner ?─) 'face face)))))
      (when (> br 0)
        (when (> br 1)
          (setq parts (append parts
                              (list (propertize (make-string (1- br) ?─)
                                                'face face)))))
        (setq parts (append parts
                            (list (propertize (if top "┐" "┘") 'face
                                              (ebox--text-border-face
                                               (ebox-cs-brc cs) bg))))))
      (let ((line (apply #'concat parts)))
        (puthash line bw ebox--part-widths)
        line))))

;;;; Line breaking

(defun ebox--unit-kind (string unit)
  "Classify UNIT of STRING for line breaking."
  (or (nth 3 unit)
      (let ((ch (aref string (car unit))))
        (cond ((eq ch ?\n) 'newline)
              ((memq ch '(?\s ?\t)) 'space)
              ((ebox--cjk-char-p ch) 'cjk)
              (t 'word)))))

(defconst ebox--no-line-start
  "!%),.:;?]}¢°’”‰′″℃、。〉》」』】〕〗〙〛〜〞ゝゞ・ヽヾ！％），．：；？］｝｡｣､･…‥ー—"
  "Characters that must not begin a wrapped line.")

(defconst ebox--no-line-end
  "$([{£¥‘“〈《「『【〔〖〘〚〝（［｛｢"
  "Characters that must not end a wrapped line.")

(defun ebox--break-lines (pieces width wrap clip)
  "Break PIECES into lines no wider than WIDTH under WRAP mode.
Return a list of (STRING . PIXELS).  Words wrap as a whole, CJK and `char'
mode wrap per cluster, a word wider than WIDTH splits per cluster and a
space that does not fit ends its line and is dropped.  A soft break never
puts closing punctuation at a line start or opening punctuation at a line
end: the preceding cluster or word moves down instead, unless that would
empty the line.  Under `none' or `nowrap' only newlines break; CLIP then
drops units beyond WIDTH."
  (let* ((np (length pieces))
         (pstr (make-vector np nil))
         (pbase (make-vector (1+ np) 0))
         (n 0) (k 0) uvecs)
    (dolist (piece pieces)
      (let ((uvec (ebox--piece-units piece)))
        (aset pstr k (car piece))
        (aset pbase k n)
        (setq n (+ n (/ (length uvec) 3)) k (1+ k))
        (push uvec uvecs)))
    (aset pbase np n)
    (let ((uv (if (cdr uvecs) (apply #'vconcat (nreverse uvecs)) (or (car uvecs) [])))
          (nowrap (memq wrap '(none nowrap)))
          (char-mode (eq wrap 'char))
          (lines nil) (ls 0) (cur 0) (i 0) (newline-last t) (stop nil))
      (cl-labels ((emit (from to w)
                  (let ((p 0) parts)
                    (while (< from to)
                      (while (>= from (aref pbase (1+ p))) (setq p (1+ p)))
                      (let* ((base (aref pbase p))
                             (end (min to (aref pbase (1+ p))))
                             (s (aref pstr p))
                             (cs (if (= from base) 0 (aref uv (* 3 (1- from)))))
                             (ce (aref uv (* 3 (1- end)))))
                        (push (if (and (= cs 0) (= ce (length s))) s (substring s cs ce))
                              parts)
                        (setq from end)))
                    (push (cons (ebox--join (nreverse parts)) w) lines)))
                (char-at (j)
                  (let ((p 0))
                    (while (>= j (aref pbase (1+ p))) (setq p (1+ p)))
                    (aref (aref pstr p)
                          (if (= j (aref pbase p)) 0 (aref uv (* 3 (1- j)))))))
                (kind-at (j) (aref uv (+ (* 3 j) 2)))
                (soft-break (b)
                  ;; Return the break index at or before B obeying the
                  ;; line-start and line-end punctuation rules.
                  (let ((tries 3) (orig b))
                    (while (and (> tries 0) (> b ls) (< b n)
                                (or (seq-contains-p ebox--no-line-start (char-at b))
                                    (seq-contains-p ebox--no-line-end (char-at (1- b)))))
                      (setq b (1- b) tries (1- tries))
                      (while (and (> b ls) (eq (kind-at b) 'word)
                                  (eq (kind-at (1- b)) 'word))
                        (setq b (1- b))))
                    (if (and (> b ls)
                             (not (memq (kind-at (1- b)) '(newline))))
                        b
                      orig)))
                (span (from to)
                  (let ((sum 0))
                    (while (< from to)
                      (setq sum (+ sum (aref uv (1+ (* 3 from)))) from (1+ from)))
                    sum)))
        (while (< i n)
          (let ((kind (aref uv (+ (* 3 i) 2))) (w (aref uv (1+ (* 3 i)))))
            (setq newline-last nil)
            (cond
             ((eq kind 'newline)
              (emit ls (or stop i) cur)
              (setq i (1+ i) ls i cur 0 newline-last t stop nil))
             (nowrap
              (when (and clip (not stop) (> (+ cur w) width))
                (setq stop i))
              (unless stop (setq cur (+ cur w)))
              (setq i (1+ i)))
             ((or char-mode (memq kind '(cjk glue space)))
              (cond
               ((and (eq kind 'space) (not char-mode) (> (+ cur w) width))
                (when (< ls i) (emit ls i cur))
                (setq i (1+ i) ls i cur 0))
               (t
                (when (> (+ cur w) width)
                  (let* ((b (if char-mode i (soft-break i)))
                         (moved (span b i)))
                    (when (< ls b) (emit ls b (- cur moved)))
                    (setq ls b cur moved)))
                (setq cur (+ cur w) i (1+ i)))))
             (t
              (let ((j i) (run 0))
                (while (and (< j n) (eq (aref uv (+ (* 3 j) 2)) 'word))
                  (setq run (+ run (aref uv (1+ (* 3 j)))) j (1+ j)))
                (cond
                 ((> run width)
                  (while (< i j)
                    (let ((cw (aref uv (1+ (* 3 i)))))
                      (when (> (+ cur cw) width)
                        (when (< ls i) (emit ls i cur))
                        (setq ls i cur 0))
                      (setq cur (+ cur cw) i (1+ i)))))
                 ((<= (+ cur run) width)
                  (setq cur (+ cur run) i j))
                 (t
                  (let* ((b (soft-break i))
                         (moved (span b i)))
                    (when (< ls b) (emit ls b (- cur moved)))
                    (setq ls b cur (+ moved run) i j)))))))))
        (cond
         (stop (emit ls stop cur))
         ((or (< ls n) newline-last (null lines)) (emit ls n cur))))
      (nreverse lines))))

(defun ebox--reset-geo (geo)
  "Return GEO with every field restored to its initial value."
  (setf (ebox-geo-ml geo) 0 (ebox-geo-mr geo) 0 (ebox-geo-mt geo) 0 (ebox-geo-mb geo) 0
        (ebox-geo-bl geo) 0 (ebox-geo-br geo) 0 (ebox-geo-pl geo) 0 (ebox-geo-pr geo) 0
        (ebox-geo-pt geo) 0 (ebox-geo-pb geo) 0 (ebox-geo-bw geo) 0 (ebox-geo-bh geo) 0
        (ebox-geo-cw geo) 0 (ebox-geo-vh geo) 0 (ebox-geo-ch geo) 0 (ebox-geo-scroll geo) 0
        (ebox-geo-items geo) nil (ebox-geo-n geo) 0 (ebox-geo-stack geo) nil
        (ebox-geo-kind geo) nil (ebox-geo-gap geo) nil (ebox-geo-iused geo) nil
        (ebox-geo-nat geo) nil)
  geo)

(defun ebox--box-metrics (node cbw &optional reuse)
  "Return a geometry record of NODE's edges against CBW pixels.
The record is fresh unless REUSE, a geometry record, is given to reset."
  (let* ((cs (ebox-node-cs node))
         (geo (if reuse (ebox--reset-geo reuse) (ebox-geo--make))))
    (if (eq (ebox-node-tag node) 'text)
        geo
      (setf (ebox-geo-ml geo) (max 0 (or (ebox--px (ebox-cs-ml cs) cs cbw) 0))
            (ebox-geo-mr geo) (max 0 (or (ebox--px (ebox-cs-mr cs) cs cbw) 0))
            (ebox-geo-pl geo) (max 0 (or (ebox--px (ebox-cs-pl cs) cs cbw) 0))
            (ebox-geo-pr geo) (max 0 (or (ebox--px (ebox-cs-pr cs) cs cbw) 0))
            (ebox-geo-mt geo) (max 0 (or (ebox--lines (ebox-cs-mt cs) cs nil) 0))
            (ebox-geo-mb geo) (max 0 (or (ebox--lines (ebox-cs-mb cs) cs nil) 0))
            (ebox-geo-pt geo) (or (ebox--pad-lines (ebox-cs-pt cs)) 0)
            (ebox-geo-pb geo) (or (ebox--pad-lines (ebox-cs-pb cs)) 0)
            (ebox-geo-bl geo) (ebox-cs-bl cs)
            (ebox-geo-br geo) (ebox-cs-br cs))
      geo)))

(defsubst ebox--h-extras (geo)
  "Return horizontal border and padding pixels of GEO."
  (+ (ebox-geo-bl geo) (ebox-geo-br geo) (ebox-geo-pl geo) (ebox-geo-pr geo)))

(defsubst ebox--h-margins (geo)
  "Return horizontal margin pixels of GEO."
  (+ (ebox-geo-ml geo) (ebox-geo-mr geo)))

(defsubst ebox--hpx (spec cs cbw)
  "Return horizontal edge SPEC of CS in pixels against CBW, at least 0."
  (max 0 (or (ebox--px spec cs cbw) 0)))

(defun ebox--node-h-extras (node cbw)
  "Return NODE's horizontal border and padding pixels against CBW."
  (if (eq (ebox-node-tag node) 'text) 0
    (let ((cs (ebox-node-cs node)))
      (+ (ebox-cs-bl cs) (ebox-cs-br cs)
         (ebox--hpx (ebox-cs-pl cs) cs cbw) (ebox--hpx (ebox-cs-pr cs) cs cbw)))))

(defun ebox--node-h-margins (node cbw)
  "Return NODE's horizontal margin pixels against CBW."
  (if (eq (ebox-node-tag node) 'text) 0
    (let ((cs (ebox-node-cs node)))
      (+ (ebox--hpx (ebox-cs-ml cs) cs cbw) (ebox--hpx (ebox-cs-mr cs) cs cbw)))))

;;;; Intrinsic sizes

(defun ebox--intrinsic (node)
  "Return (MIN . MAX) content-box intrinsic widths of NODE."
  (or (ebox-node-intr node)
      (setf (ebox-node-intr node) (ebox--compute-intrinsic node))))

(defun ebox--outer-intrinsic (node cbw &optional record)
  "Return (MIN . MAX) margin-box widths of NODE against CBW.
RECORD notes the result as the widths NODE's container laid it out from.
A fixed width does not read NODE's content."
  (let* ((cs (ebox-node-cs node))
         (extras (ebox--node-h-extras node cbw))
         (margins (ebox--node-h-margins node cbw))
         (width (ebox-cs-width cs))
         (fixed (and (not (eq (ebox-node-tag node) 'text)) (ebox--px width cs cbw)))
         minc maxc)
    (if fixed
        (setq minc (if (eq (ebox-cs-box-sizing cs) 'content-box) (+ fixed extras) fixed)
              maxc minc)
      (let ((content (ebox--intrinsic node)))
        (setq minc (+ (car content) extras)
              maxc (+ (cdr content) extras))
        (pcase width
          ('min-content (setq maxc minc))
          ('max-content (setq minc maxc)))))
    (let ((lo (ebox--px (ebox-cs-min-width cs) cs cbw))
          (hi (ebox--px (ebox-cs-max-width cs) cs cbw)))
      (when hi (setq minc (min minc hi) maxc (min maxc hi)))
      (when lo (setq minc (max minc lo) maxc (max maxc lo))))
    (let ((result (cons (+ minc margins) (+ maxc margins))))
      (when record (setf (ebox-node-seen node) result))
      result)))

(defun ebox--contribution (node)
  "Return NODE's margin-box intrinsic widths without a containing width.
The result is cached until NODE's computed style or intrinsic widths change."
  (let ((cache (ebox-node-contrib node))
        (cs (ebox-node-cs node)))
    (if (and cache (eq (car cache) cs) (eq (cadr cache) (ebox-node-intr node)))
        (cddr cache)
      (let ((size (ebox--outer-intrinsic node nil)))
        (unless (ebox-cs-vunits cs)
          (setf (ebox-node-contrib node) (cons cs (cons (ebox-node-intr node) size))))
        size))))

(defun ebox--para-intrinsic (nodes)
  "Return (MIN . MAX) widths of an inline paragraph of NODES."
  (let ((minw 0) (maxw 0) (line 0))
    (cl-labels
        ((visit (node)
           (cond
            ((ebox--abs-p node) nil)
            ((eq (ebox-node-tag node) 'text)
             (let ((m (ebox--text-meas node)))
               (setq minw (max minw (aref m 5)))
               (if (aref m 6)
                   (let* ((units (ebox--text-unit-vector node))
                          (i 0) (n (length units)))
                     (while (< i n)
                       (if (eq (aref units (+ i 2)) 'newline)
                           (setq maxw (max maxw line) line 0)
                         (setq line (+ line (aref units (1+ i)))))
                       (setq i (+ i 3))))
                 (setq line (+ line (aref m 4))))))
            (t
             (progn
               (setq line (+ line (ebox--node-h-margins node 0) (ebox--node-h-extras node 0)))
               (ebox--do-kids (child node) (visit child)))))))
      (mapc #'visit nodes))
    (cons minw (max maxw line))))

(defun ebox--flow-groups (node)
  "Return NODE's in-flow children grouped as nodes and inline lists."
  (let (groups run)
    (ebox--do-kids (child node)
      (cond ((ebox--abs-p child) nil)
            ((ebox--inline-p child) (push child run))
            (t (when run (push (nreverse run) groups) (setq run nil))
               (push child groups))))
    (when run (push (nreverse run) groups))
    (nreverse groups)))

(defun ebox--compute-intrinsic (node)
  "Compute (MIN . MAX) content intrinsic widths of NODE."
  (pcase (ebox-node-tag node)
    ('text (ebox--para-intrinsic (list node)))
    ('image (let ((w (ebox--image-width node))) (cons w w)))
    (tag
     (let* ((cs (ebox-node-cs node))
            (horizontal (or (eq tag 'row)
                            (and (eq tag 'flex)
                                 (memq (ebox--cv cs 'ebox/flex-direction)
                                       '(row row-reverse)))))
            (gap (if (eq tag 'row) (or (ebox--px (ebox-cs-gap cs) cs nil) 0)
                   (or (ebox--px (ebox--cv cs 'ebox/column-gap) cs nil) 0)))
            (minw 0) (maxw 0) (count 0))
       (cond
        ((eq tag 'grid) (ebox--grid-intrinsic node))
        (t
         (cl-flet ((add (size)
                     (setq count (1+ count))
                     (if horizontal
                         (setq minw (if (and (eq tag 'flex)
                                             (not (eq (ebox--cv cs 'ebox/flex-wrap) 'nowrap)))
                                        (max minw (car size))
                                      (+ minw (car size)))
                               maxw (+ maxw (cdr size)))
                       (setq minw (max minw (car size)) maxw (max maxw (cdr size))))))
           (if (eq tag 'box)
               (dolist (group (ebox--flow-groups node))
                 (add (if (consp group) (ebox--para-intrinsic group)
                        (ebox--contribution group))))
             (ebox--do-kids (kid node)
               (unless (ebox--abs-p kid) (add (ebox--contribution kid))))))
         (when (and horizontal (> count 1))
           (setq maxw (+ maxw (* gap (1- count))))
           (unless (and (eq tag 'flex) (not (eq (ebox--cv cs 'ebox/flex-wrap) 'nowrap)))
             (setq minw (+ minw (* gap (1- count))))))
         (cons minw maxw)))))))

;;;; Layout entry

(defsubst ebox--constraint (node)
  "Return NODE's last layout constraint vector, or nil."
  (ebox-node-avail node))

(defun ebox--paint-only-desc (node dirty)
  "Return non-nil when repainting NODE also covers its dirty children.
DIRTY is NODE's dirty mask.  A paint-dirty NODE rebuilds the lines of its
whole subtree, so dirty children that need nothing more than repainting are
forgotten here instead of being laid out again."
  (and (/= 0 (logand dirty ebox--d-paint))
       (null (ebox-node-ops node))
       (let ((kids (ebox-node-dkids node)) (mask (logior ebox--d-style ebox--d-layout
                                                         ebox--d-desc)))
         (while (and kids (zerop (logand (ebox-node-dirty (car kids)) mask)))
           (setq kids (cdr kids)))
         (when (null kids)
           (dolist (kid (ebox-node-dkids node))
             (setf (ebox-node-dirty kid)
                   (logand (ebox-node-dirty kid) (lognot ebox--d-queued))))
           (setf (ebox-node-dkids node) nil
                 (ebox-node-dirty node) (logand (ebox-node-dirty node)
                                                (lognot ebox--d-desc)))
           t))))

(defun ebox--layout (node avail mode cbh &optional fh)
  "Lay out NODE's margin box within AVAIL pixels.
MODE is stretch, shrink or exact; CBH is the containing height in lines or
nil; FH forces the border-box height in lines.  Return non-nil when NODE's
geometry or its children's sizes may have changed."
  (let ((key (ebox--constraint node))
        (dirty (ebox-node-dirty node)))
    ;; Only percentage and stretch block sizes read CBH; dropping it otherwise
    ;; keeps cached layouts valid when an ancestor's definite height changes.
    (unless (ebox-cs-vcbh (ebox-node-cs node)) (setq cbh nil))
    (if (and key (zerop (logand dirty 3))
             (eql (aref key 0) avail) (eq (aref key 1) mode)
             (eql (aref key 2) cbh) (eql (aref key 3) fh))
        (let ((old-h (ebox-node-h node))
              (moved
               (when (and (/= 0 (logand dirty ebox--d-desc))
                          (not (ebox--paint-only-desc node dirty)))
                 (let ((used (ebox-geo-iused (ebox-node-layout node))))
                   (if (and used (not (equal used (ebox--intrinsic node))))
                       ;; NODE's own width follows its content, which changed.
                       (progn (ebox--layout-full node avail mode cbh fh) t)
                     (ebox--relayout-partial node))))))
          (when (/= 0 (logand (ebox-node-dirty node) ebox--d-paint))
            ;; A paint-only restyle keeps geometry and repaints NODE's lines.
            (ebox--repaint node)
            (when ebox--record (ebox--damage-whole node old-h)))
          moved)
      (ebox--layout-full node avail mode cbh fh)
      t)))

(defun ebox--repaint (node)
  "Rebuild the cached paragraph lines below NODE and clear its paint dirt."
  (setf (ebox-node-dirty node) (logand (ebox-node-dirty node) (lognot ebox--d-paint)))
  (ebox--uncache node)
  (let ((geo (ebox-node-layout node)))
    (when geo
      (ebox--do-items (item geo)
        (when (ebox-para-p item)
          (ebox--layout-para item (ebox-para-w item))))))
  (ebox--do-kids (kid node) (ebox--repaint kid)))

(defun ebox--natural-h (node avail mode cbh)
  "Return NODE's margin-box height laid out without a forced height.
A NODE stretched under the same constraints reports the natural height
recorded when it was stretched, keeping its stretched layout; dirty
descendants settle at the stretched constraints first and the natural height
is measured again from the children's recorded sizes."
  (let ((key (ebox--constraint node))
        (geo (ebox-node-layout node))
        (dirty (ebox-node-dirty node)))
    (unless (ebox-cs-vcbh (ebox-node-cs node)) (setq cbh nil))
    (if (and key (aref key 3) (ebox-geo-nat geo)
             (zerop (logand dirty 3))
             (eql (aref key 0) avail) (eq (aref key 1) mode) (eql (aref key 2) cbh)
             (or (zerop (logand dirty ebox--d-desc))
                 (progn
                   (ebox--layout node avail mode cbh (aref key 3))
                   (let ((natural (ebox--stretched-natural node)))
                     (when natural
                       (setf (ebox-geo-nat (ebox-node-layout node)) natural))))))
        (ebox-geo-nat (ebox-node-layout node))
      (ebox--layout node avail mode cbh)
      (ebox-node-h node))))

(defun ebox--place-h (node avail mode cbh natural lines)
  "Lay out NODE stretched to LINES margin-box lines unless NATURAL fits.
NATURAL is NODE's height from `ebox--natural-h'."
  (if (or (null lines) (= natural lines))
      (ebox--layout node avail mode cbh)
    (let ((geo (ebox-node-layout node)))
      (ebox--layout node avail mode cbh
                    (max 0 (- lines (ebox-geo-mt geo) (ebox-geo-mb geo))))
      (setf (ebox-geo-nat (ebox-node-layout node)) natural))))

(defun ebox--stretched-natural (node)
  "Return NODE's natural margin-box height after a stretched relayout.
Return nil when NODE's content depends on its forced height."
  (let* ((key (ebox--constraint node))
         (geo (ebox-node-layout node))
         (tag (ebox-node-tag node))
         (content
          (and (memq tag '(box column row text image flex))
               (not (catch 'found
                      (ebox--do-kids (kid node)
                        (when (ebox-cs-vcbh (ebox-node-cs kid)) (throw 'found t)))
                      nil))
               (if (eq tag 'flex) (ebox--flex-natural node geo) (ebox-geo-ch geo)))))
    (when content
      (+ (ebox-geo-mt geo) (ebox-geo-mb geo)
         (if (eq tag 'text) content
           (ebox--resolve-height node geo content (aref key 2) nil))))))

(defun ebox--recorded-natural (node)
  "Return NODE's natural margin-box height recorded by its last layout."
  (let ((key (ebox--constraint node)))
    (or (and key (aref key 3) (ebox-geo-nat (ebox-node-layout node)))
        (ebox-node-h node))))

(defun ebox--drop-dkids (node)
  "Forget NODE's pending dirty children and structural operations."
  (dolist (kid (ebox-node-dkids node))
    (setf (ebox-node-dirty kid) (logand (ebox-node-dirty kid) (lognot ebox--d-queued))))
  (setf (ebox-node-dkids node) nil
        (ebox-node-ops node) nil))

(defun ebox--layout-places (node)
  "Return NODE's own geometry and its children's places, for damage checks."
  (let* ((geo (ebox-node-layout node))
         (places (list (ebox-node-w node) (ebox-node-h node) (ebox-geo-bw geo)
                       (ebox-geo-bh geo) (ebox-geo-scroll geo))))
    (ebox--do-kids (kid node)
      ;; A detached child retains its numeric size but has no painted layout
      ;; or overlay placement.  Reattaching it is new paint even at the same
      ;; coordinates, not an unchanged place whose damage can be discarded.
      (setq places (cons (and (ebox-node-layout kid) t)
                         (cons (ebox-node-placed kid)
                               (cons (ebox-node-h kid)
                                     (cons (ebox-node-w kid)
                                           (cons (ebox-node-y kid)
                                                 (cons (ebox-node-x kid)
                                                       (cons kid places)))))))))
    places))

(defun ebox--layout-full (node avail mode cbh fh)
  "Lay out NODE completely and record its damage.
A container whose own style is unchanged and whose relayout leaves its size
and every child's place unchanged records only its children's damage."
  (let* ((old-h (ebox-node-h node))
         (fresh (null (ebox-node-layout node)))
         (precise (and ebox--record (not fresh)
                       (zerop (logand (ebox-node-dirty node) 7))
                       (memq (ebox-node-tag node) '(column row flex grid))))
         (before (and precise (ebox--layout-places node)))
         (inner nil))
    (unless (zerop (logand (ebox-node-dirty node) 3))
      (setf (ebox-node-intr node) nil))
    (ebox--uncache node)
    (let ((ebox--record precise) (ebox--damage nil))
      (ebox--do-layout node avail mode cbh fh)
      (setq inner ebox--damage))
    (ebox--drop-dkids node)
    (remhash node ebox--vacated)
    (setf (ebox-node-avail node) (vector avail mode cbh fh)
          (ebox-node-dirty node) (logand (ebox-node-dirty node) ebox--d-queued))
    (when (and ebox--record (not fresh))
      (if (and precise (equal before (ebox--layout-places node)))
          (setq ebox--damage (nconc inner ebox--damage))
        (ebox--damage-whole node old-h)))))

(defun ebox--damage-owner (item)
  "Return the node whose lines damage ITEM concerns."
  (cond ((ebox-para-p item) (ebox-para-owner item))
        ((consp item) (nth 1 item))
        (t item)))

(defun ebox--damage-whole (node old-h)
  "Record that every line of NODE changed; it had OLD-H lines.
The entry supersedes earlier damage inside NODE; `ebox--damage-prune' drops
that damage once, when the pass ends."
  (push (list node 0 old-h (ebox-node-h node)) ebox--damage))

(defun ebox--damage-prune (damages)
  "Return DAMAGES without entries superseded by a later whole-node entry.
DAMAGES is newest first; a whole-node entry, whose item is a node, covers
earlier damage owned by that node or its descendants.  A node laid out more
than once in a pass keeps its first old height, the one the buffer shows."
  (let ((whole nil) (kept nil))
    (dolist (damage damages)
      (let ((owner (ebox--damage-owner (car damage))) (covered nil))
        (when whole
          (let ((node owner))
            (while (and node (not covered))
              (let ((entry (gethash node whole)))
                (if (not entry)
                    (setq node (ebox-node-parent node))
                  (setq covered t)
                  (when (eq (car damage) node)
                    (setf (nth 2 entry) (nth 2 damage))))))))
        (unless covered
          (push damage kept)
          (when (ebox-node-p (car damage))
            (unless whole (setq whole (make-hash-table :test 'eq)))
            (puthash (car damage) damage whole)))))
    (nreverse kept)))

(defsubst ebox--item-h (item)
  "Return ITEM's height in lines."
  (if (ebox-para-p item) (ebox-para-h item) (ebox-node-h item)))

(defsubst ebox--item-w (item)
  "Return ITEM's width in pixels."
  (if (ebox-para-p item) (ebox-para-w item) (ebox-node-w item)))

(defsubst ebox--item-y (item)
  "Return ITEM's top line in its container's content box.
A stacked item stores its line relative to its run's offset."
  (if (ebox-para-p item)
      (let ((run (ebox-para-run item)))
        (if run (+ (ebox-para-y item) (ebox-run-dy run)) (ebox-para-y item)))
    (let ((run (ebox-node-irun item)))
      (if run (+ (ebox-node-y item) (ebox-run-dy run)) (ebox-node-y item)))))

(defun ebox--item-ref (item run pos old)
  "Record that stacked ITEM sits at POS of RUN.
An item arriving from OLD, another run, keeps its line."
  (if (ebox-para-p item)
      (progn
        (when (and old (not (eq old run)))
          (setf (ebox-para-y item)
                (+ (ebox-para-y item) (- (ebox-run-dy old) (ebox-run-dy run)))))
        (setf (ebox-para-run item) run (ebox-para-pos item) pos))
    (when (and old (not (eq old run)))
      (setf (ebox-node-y item)
            (+ (ebox-node-y item) (- (ebox-run-dy old) (ebox-run-dy run)))))
    (setf (ebox-node-irun item) run (ebox-node-ipos item) pos)))

(defun ebox--item-run (item)
  "Return the run holding stacked ITEM, or nil."
  (if (ebox-para-p item) (ebox-para-run item) (ebox-node-irun item)))

(defun ebox--item-pos (item)
  "Return stacked ITEM's position in its run."
  (if (ebox-para-p item) (ebox-para-pos item) (ebox-node-ipos item)))

(defun ebox--release-items (items)
  "Detach the stacked ITEMS sequence's items from their runs."
  (when (recordp items)
    (ebox--seq-do (item items)
      (if (ebox-para-p item) (setf (ebox-para-run item) nil) (setf (ebox-node-irun item) nil)))))

(defsubst ebox--item-x (item)
  "Return ITEM's left pixel in its container's content box."
  (if (ebox-para-p item) (ebox-para-x item) (ebox-node-x item)))

;;;; Full layout of one node

(defun ebox--resolve-width (node geo avail mode)
  "Return NODE's border-box width for AVAIL margin-box pixels under MODE."
  (let* ((cs (ebox-node-cs node))
         (extras (ebox--h-extras geo))
         (space (max 0 (- avail (ebox--h-margins geo))))
         (width (ebox-cs-width cs))
         (fixed (ebox--px width cs avail))
         (bw
          (cond
           ((eq mode 'exact) space)
           (fixed (if (eq (ebox-cs-box-sizing cs) 'content-box) (+ fixed extras) fixed))
           ((eq width 'stretch) space)
           ((eq width 'min-content)
            (+ (car (setf (ebox-geo-iused geo) (ebox--intrinsic node))) extras))
           ((eq width 'max-content)
            (+ (cdr (setf (ebox-geo-iused geo) (ebox--intrinsic node))) extras))
           ((or (eq width 'fit-content) (eq mode 'shrink)
                (and (consp width) (eq (car width) 'fit-content)))
            (let ((size (setf (ebox-geo-iused geo) (ebox--intrinsic node))))
              (min (+ (cdr size) extras) (max (+ (car size) extras) space))))
           (t space)))
         (lo (ebox--px (ebox-cs-min-width cs) cs avail))
         (hi (ebox--px (ebox-cs-max-width cs) cs avail)))
    (unless (eq mode 'exact)
      (when hi (setq bw (min bw (if (eq (ebox-cs-box-sizing cs) 'content-box)
                                    (+ hi extras) hi))))
      (when lo (setq bw (max bw (if (eq (ebox-cs-box-sizing cs) 'content-box)
                                    (+ lo extras) lo)))))
    (max bw extras)))

(defun ebox--resolve-height (node geo content cbh fh)
  "Return NODE's border-box height for CONTENT lines.
CBH is the containing height or nil; FH forces the result."
  (let* ((cs (ebox-node-cs node))
         (extras (+ (ebox-geo-pt geo) (ebox-geo-pb geo)))
         (natural (+ content extras))
         (fixed (ebox--lines (ebox-cs-height cs) cs cbh))
         (bh (cond (fh fh)
                   (fixed (if (eq (ebox-cs-box-sizing cs) 'content-box) (+ fixed extras) fixed))
                   ((and (eq (ebox-cs-height cs) 'stretch) cbh)
                    (max 0 (- cbh (ebox-geo-mt geo) (ebox-geo-mb geo))))
                   (t natural)))
         (lo (ebox--lines (ebox-cs-min-height cs) cs cbh))
         (hi (ebox--lines (ebox-cs-max-height cs) cs cbh)))
    (unless fh
      (when hi (setq bh (min bh hi)))
      (when lo (setq bh (max bh lo))))
    (when (and (eq (ebox-cs-overflow cs) 'visible) (> natural bh))
      (setq bh natural))
    (max bh extras)))

(defun ebox--definite-height (node geo cbh fh)
  "Return NODE's definite content height in lines, or nil.
A stretched height is definite when its containing height CBH is."
  (let* ((cs (ebox-node-cs node))
         (fixed (or fh (ebox--lines (ebox-cs-height cs) cs cbh))))
    (cond
     (fixed
      (max 0 (- fixed (if (and (not fh) (eq (ebox-cs-box-sizing cs) 'content-box)) 0
                        (+ (ebox-geo-pt geo) (ebox-geo-pb geo))))))
     ((and cbh (eq (ebox-cs-height cs) 'stretch))
      (max 0 (- (ebox--resolve-height node geo 0 cbh nil)
                (ebox-geo-pt geo) (ebox-geo-pb geo)))))))

(defun ebox--pos-extent (geo content)
  "Return CONTENT lines extended to the bottom of GEO's positioned items.
Items overflowing their container make it a clipping or growing box."
  (ebox--do-items (item geo)
    (setq content (max content (+ (ebox--item-y item) (ebox-node-h item)))))
  content)

(defvar ebox--old-items nil
  "Items of the layout `ebox--do-layout' is replacing, for reuse.")

(defun ebox--do-layout (node avail mode cbh fh)
  "Compute NODE's geometry and items for the given constraints."
  (let* ((old (ebox-node-layout node))
         (ebox--old-items (and old (ebox-geo-items old)))
         (geo (ebox--box-metrics node avail old))
         (tag (ebox-node-tag node))
         (bw (if (eq tag 'text)
                 (if (eq mode 'shrink)
                     (let ((size (setf (ebox-geo-iused geo) (ebox--intrinsic node))))
                       (min (cdr size) (max (car size) avail)))
                   avail)
               (ebox--resolve-width node geo avail mode)))
         (cw (max 0 (- bw (ebox--h-extras geo))))
         (inner-cbh (ebox--definite-height node geo cbh fh))
         (content
          (progn
            (setf (ebox-geo-cw geo) cw (ebox-geo-bw geo) bw
                  (ebox-node-layout node) geo)
            (pcase tag
              ('text (ebox--layout-para-items node geo (list node)))
              ('image (ebox--layout-image node geo))
              ('box (ebox--layout-flow node geo inner-cbh))
              ('column (ebox--layout-column node geo inner-cbh))
              ('row (ebox--layout-row node geo inner-cbh))
              ('flex (ebox--layout-flex node geo inner-cbh))
              ('grid (ebox--layout-grid node geo inner-cbh)))))
         (content (if (eq (ebox-geo-kind geo) 'pos)
                      (ebox--pos-extent geo content)
                    content))
         (bh (if (eq tag 'text) content
               (ebox--resolve-height node geo content cbh fh))))
    (setf (ebox-geo-ch geo) content
          (ebox-geo-bh geo) bh
          (ebox-geo-vh geo) (max 0 (- bh (ebox-geo-pt geo) (ebox-geo-pb geo)))
          (ebox-geo-scroll geo)
          (ebox--resolved-scroll
           node content (max 0 (- bh (ebox-geo-pt geo) (ebox-geo-pb geo))))
          (ebox-node-w node) (+ bw (ebox--h-margins geo))
          (ebox-node-h node) (+ bh (ebox-geo-mt geo) (ebox-geo-mb geo)))
    (ebox--layout-overlays node)
    node))

;;;; Paragraph and flow layout

(defun ebox--resolved-scroll (node content viewport)
  "Return NODE's scroll offset for CONTENT lines shown in VIEWPORT lines.
An end-anchored node pinned to its last line keeps following that line as
the content changes."
  (let ((limit (max 0 (- content viewport))))
    (if (and (ebox-node-pinned node)
             (eq (plist-get (ebox-cs-vals (ebox-node-cs node)) 'ebox/scroll-anchor)
                 'end))
        (setf (ebox-node-scroll node) limit)
      (max 0 (min (ebox-node-scroll node) limit)))))

(defsubst ebox--align-left (align free)
  "Return the left offset of a line with FREE pixels under ALIGN."
  (pcase align
    ('center (/ (max 0 free) 2))
    ((or 'right 'end) (max 0 free))
    (_ 0)))

(defun ebox--layout-para (para width)
  "Wrap PARA's inline nodes to WIDTH pixels and cache its lines."
  (let* ((owner (ebox-para-owner para))
         (cs (ebox-node-cs owner))
         (wrap (ebox-cs-wrap cs))
         (clip (eq (ebox-cs-overflow cs) 'hidden))
         (pieces (ebox--para-cached-pieces para))
         (padface (ebox-cs-padface cs))
         (align (ebox-cs-align cs))
         (one (ebox--pieces-line-width pieces))
         (old (ebox-para-lines para))
         lines)
    (if (and one (or (<= one width) (and (memq wrap '(none nowrap)) (not clip))))
        ;; Everything fits on one line: no breaking is needed.
        (let* ((free (- width one))
               (left (ebox--align-left align free))
               (strings (mapcar #'car pieces)))
          (unless (and (zerop left) (<= free 0))
            (setq strings (cons (ebox--space left padface)
                                (nconc strings (list (ebox--space (- free left) padface))))))
          (setq lines (if (and old (= (length old) 1)) old (make-vector 1 nil)))
          (aset lines 0 (if (> one width)
                            (car (ebox--split-at (ebox--join strings) width))
                          (ebox--join strings))))
      (let* ((broken (ebox--break-lines pieces width wrap clip))
             (i 0))
        (setq lines (make-vector (length broken) nil))
        (dolist (line broken)
          (let* ((free (- width (cdr line)))
                 (left (ebox--align-left align free)))
            (aset lines i
                  (if (and (zerop left) (<= free 0))
                      (if (< free 0) (car (ebox--split-at (car line) width)) (car line))
                    (ebox--join (list (ebox--space left padface) (car line)
                                      (ebox--space (- free left) padface)))))
            (setq i (1+ i))))))
    (setf (ebox-para-lines para) lines
          (ebox-para-w para) width
          (ebox-para-h para) (length lines))
    ;; Inline nodes never pass through `ebox--layout'; the paragraph owns them.
    (dolist (node (ebox-para-nodes para)) (ebox--clean-subtree node))
    para))


(defun ebox--layout-para-items (node geo nodes)
  "Lay out NODES as NODE's single paragraph; return its height.
The paragraph NODE's previous layout held for the same NODES is reused."
  (let* ((old ebox--old-items)
         (prev (and (recordp old) (= (ebox-seq-n old) 1) (ebox--seq-ref old 0)))
         (para (and prev (ebox-para-p prev) (eq (ebox-para-owner prev) node)
                    (let ((a (ebox-para-nodes prev)) (b nodes))
                      (while (and a b (eq (car a) (car b))) (setq a (cdr a) b (cdr b)))
                      (and (null a) (null b)))
                    prev)))
    (if para
        (setf (ebox-para-x para) 0 (ebox-para-y para) 0)
      (setq para (ebox-para--make :owner node :nodes nodes)))
    (ebox--layout-para para (ebox-geo-cw geo))
    (if (eq para prev)
        (setf (ebox-run-dy (ebox-para-run para)) 0
              (ebox-geo-items geo) old (ebox-geo-n geo) 1)
      (ebox--release-items old)
      (setf (ebox-geo-items geo) (ebox--seq-build (list para) #'ebox--item-ref)
            (ebox-geo-n geo) 1))
    (setf (ebox-geo-stack geo) t
          (ebox-geo-kind geo) 'stack)
    (ebox-para-h para)))

(defun ebox--stack-items (geo items gap)
  "Stack the list ITEMS with GAP lines between them in GEO; return the height."
  (let ((y 0) (first t))
    (ebox--release-items ebox--old-items)
    (dolist (item items)
      (unless first (setq y (+ y gap)))
      (setq first nil)
      (if (ebox-para-p item) (setf (ebox-para-y item) y) (setf (ebox-node-y item) y))
      (setq y (+ y (ebox--item-h item))))
    (setf (ebox-geo-items geo) (ebox--seq-build items #'ebox--item-ref)
          (ebox-geo-n geo) (length items))
    (setf (ebox-geo-stack geo) t
          (ebox-geo-kind geo) 'stack
          (ebox-geo-gap geo) gap)
    y))

(defun ebox--cross-x (node cw align)
  "Return NODE's x in CW content pixels for cross ALIGN."
  (let ((free (- cw (ebox-node-w node))))
    (pcase align
      ('center (max 0 (/ free 2)))
      ('end (max 0 free))
      (_ 0))))

(defun ebox--layout-flow (node geo cbh)
  "Lay out box NODE's block and inline children; return content height."
  (let* ((cw (ebox-geo-cw geo))
         (groups (ebox--flow-groups node))
         items)
    (if (and groups (null (cdr groups)) (consp (car groups)))
        (ebox--layout-para-items node geo (car groups))
      (dolist (group groups)
        (if (consp group)
            (push (ebox--layout-para (ebox-para--make :owner node :nodes group) cw) items)
          (ebox--layout group cw 'stretch cbh)
          (setf (ebox-node-x group) 0)
          (push group items)))
      (ebox--stack-items geo (nreverse items) 0))))

(defun ebox--layout-column (node geo cbh)
  "Lay out column NODE; return content height."
  (let* ((cs (ebox-node-cs node))
         (cw (ebox-geo-cw geo))
         (cross (ebox-cs-cross cs))
         (gap (or (ebox--lines (ebox-cs-gap cs) cs cbh) 0))
         items)
    (ebox--do-kids (child node)
      (unless (ebox--abs-p child)
        (ebox--layout child cw (if (eq cross 'stretch) 'stretch 'shrink) cbh)
        (setf (ebox-node-x child) (ebox--cross-x child cw cross))
        (push child items)))
    (ebox--stack-items geo (nreverse items) gap)))

(defun ebox--layout-row (node geo cbh)
  "Lay out row NODE; return content height."
  (let* ((cs (ebox-node-cs node))
         (cw (ebox-geo-cw geo))
         (cross (ebox-cs-cross cs))
         (gap (or (ebox--px (ebox-cs-gap cs) cs cw) 0))
         (x 0) (height 0) items)
    (ebox--do-kids (child node)
      (unless (ebox--abs-p child)
        (when items (setq x (+ x gap)))
        (let* ((avail (max 0 (- cw x)))
               (natural (ebox--natural-h child avail 'shrink cbh)))
          (setf (ebox-node-x child) x (ebox-node-y child) 0)
          (setq x (+ x (ebox-node-w child))
                height (max height natural))
          (push (list child avail natural) items))))
    (setq items (nreverse items))
    (pcase-dolist (`(,child ,avail ,natural) items)
      (ebox--place-h child avail 'shrink cbh natural
                     (and (eq cross 'stretch) (< natural height)
                          (memq (ebox-cs-height (ebox-node-cs child)) '(auto nil))
                          (not (eq (ebox-node-tag child) 'text))
                          height)))
    (setq items (mapcar #'car items))
    (dolist (child items)
      (setf (ebox-node-y child)
            (pcase cross
              ('center (/ (- height (ebox-node-h child)) 2))
              ('end (- height (ebox-node-h child)))
              (_ 0))))
    (ebox--set-items geo (vconcat items))
    (setf (ebox-geo-stack geo) nil
          (ebox-geo-kind geo) 'pos)
    height))

;;;; Partial relayout

(defvar ebox--shift nil
  "Cons (UP . DOWN) of line shifts applied by the current partial relayout.")

(defun ebox--note-shift (delta)
  "Accumulate a stack shift of DELTA lines into `ebox--shift'."
  (when (and ebox--shift (/= delta 0))
    (if (< delta 0)
        (setcar ebox--shift (+ (car ebox--shift) delta))
      (setcdr ebox--shift (+ (cdr ebox--shift) delta)))))

(defun ebox--stack-capable-p (_node geo)
  "Return non-nil when GEO's node can absorb child height changes by shifting."
  (ebox-geo-stack geo))

(defun ebox--stack-resize (node geo delta)
  "Grow stack NODE's content by DELTA lines; return nil when it must relayout.
A box whose height does not follow its content repaints its own lines."
  (or (zerop delta)
      (let* ((key (ebox--constraint node))
             (ch (+ (ebox-geo-ch geo) delta))
             (bh (ebox--resolve-height node geo ch (aref key 2) (aref key 3)))
             (vh (max 0 (- bh (ebox-geo-pt geo) (ebox-geo-pb geo))))
             (old-h (ebox-node-h node)))
        (when (= (ebox-geo-scroll geo) (ebox--resolved-scroll node ch vh))
          (setf (ebox-geo-ch geo) ch
                (ebox-geo-bh geo) bh
                (ebox-geo-vh geo) vh
                (ebox-node-h node) (+ bh (ebox-geo-mt geo) (ebox-geo-mb geo)))
          (when (and ebox--record (/= (- (ebox-node-h node) old-h) delta))
            (ebox--damage-whole node old-h))
          t))))

(defun ebox--shift-after (geo item delta)
  "Shift GEO's stacked items after ITEM, or all when ITEM is nil, by DELTA lines.
Items in ITEM's run move one by one; later runs move by their offset."
  (let* ((seq (ebox-geo-items geo))
         (runs (ebox-seq-runs seq))
         (nr (ebox-seq-nr seq))
         (run (and item (ebox--item-run item)))
         (r (if run (ebox--seq-find-run seq run) -1)))
    (when run
      (let ((vec (ebox-run-vec run)) (i (1+ (ebox--item-pos item))) (n (ebox-run-n run)))
        (while (< i n)
          (let ((moved (aref vec i)))
            (if (ebox-para-p moved)
                (setf (ebox-para-y moved) (+ (ebox-para-y moved) delta))
              (setf (ebox-node-y moved) (+ (ebox-node-y moved) delta))))
          (setq i (1+ i)))))
    (setq r (1+ r))
    (while (< r nr)
      (let ((later (aref runs r)))
        (setf (ebox-run-dy later) (+ (ebox-run-dy later) delta)))
      (setq r (1+ r)))))

(defun ebox--stacked-p (geo item)
  "Return non-nil when ITEM is one of GEO's stacked items."
  (let ((run (ebox--item-run item)) (seq (ebox-geo-items geo)))
    (and run (recordp seq)
         (eq (aref (ebox-run-vec run) (ebox--item-pos item)) item)
         (let ((r (ebox--seq-find-run seq run)))
           (and r (eq (aref (ebox-seq-runs seq) r) run))))))

(defun ebox--absorb (node geo changed &optional recorded)
  "Absorb CHANGED (ITEM OLD-W OLD-H) height changes in stack NODE.
RECORDED, when non-nil, holds earlier structural line damages of NODE whose
start lines must follow each absorbed height shift.  Return non-nil on success."
  (when (ebox--stack-capable-p node geo)
    (let ((cs (ebox-node-cs node)) (delta-total 0))
      (catch 'fail
        (dolist (entry changed)
          (let ((item (car entry)))
            (unless (ebox--stacked-p geo item) (throw 'fail nil))
            (when (and (not (ebox-para-p item))
                       (/= (nth 1 entry) (ebox-node-w item)))
              ;; Width changes only move the item inside the content box.
              (if (and (eq (ebox-node-tag node) 'column)
                       (not (memq (ebox-cs-width cs) '(min-content max-content fit-content)))
                       (not (eq (aref (ebox--constraint node) 1) 'shrink)))
                  (setf (ebox-node-x item)
                        (ebox--cross-x item (ebox-geo-cw geo) (ebox-cs-cross cs)))
                (throw 'fail nil)))
            (let ((delta (- (ebox--item-h item) (nth 2 entry))))
              (unless (zerop delta)
                (when recorded
                  (setq recorded
                        (ebox--shift-recorded recorded
                                              (ebox--item-y item)
                                              (nth 2 entry)
                                              (ebox--item-h item))))
                (ebox--shift-after geo item delta)
                (ebox--note-shift delta)
                (setq delta-total (+ delta-total delta))))))
        ;; Child nodes recorded their own damage; paragraphs do not.
        (dolist (entry changed)
          (when (and ebox--record (ebox-para-p (car entry)))
            (setq ebox--damage
                  (cons (list (car entry) 0 (nth 2 entry) (ebox--item-h (car entry)))
                        ebox--damage))))
        (ebox--stack-resize node geo delta-total)))))

(defun ebox--para-of (geo node)
  "Return the paragraph of GEO containing inline NODE, or nil."
  (catch 'found
    (ebox--do-items (item geo)
      (when (and (ebox-para-p item)
                 (cl-some (lambda (n) (ebox-node-ancestor-p n node))
                          (ebox-para-nodes item)))
        (throw 'found item)))
    nil))

(defun ebox--clean-subtree (node)
  "Clear layout dirt below inline NODE after its paragraph relayout.
Absolutely positioned descendants stay dirty; their host lays them out."
  (ebox--drop-dkids node)
  (setf (ebox-node-dirty node) (logand (ebox-node-dirty node) ebox--d-queued))
  (ebox--do-kids (child node)
    (unless (ebox--abs-p child) (ebox--clean-subtree child))))

(defun ebox--content-stable-p (geo kid)
  "Return non-nil when KID's relayout cannot move its siblings in GEO's node.
Flex and grid containers size children from the intrinsic widths recorded
in their seen slot, so a kid whose margin-box intrinsic widths changed,
including through a dirty descendant, requires relaying out NODE."
  (or (not (eq (ebox-geo-kind geo) 'pos))
      (let ((seen (ebox-node-seen kid)))
        (or (null seen) (equal seen (ebox--outer-intrinsic kid (ebox-geo-cw geo)))))))

(defun ebox--border-damage (node geo old-bh)
  "Repaint NODE's border lines whose position moved since OLD-BH lines.
Top and bottom borders and rounded corners decorate the first and last
border-box lines, so a height change moves them without changing the
lines it inserted or deleted."
  (let* ((cs (ebox-node-cs node))
         (bh (ebox-geo-bh geo))
         (delta (- bh old-bh))
         (mt (ebox-geo-mt geo))
         (rounded (> (or (ebox--px (ebox--cv cs 'ebox/border-radius) cs nil) 0) 1)))
    (when (and ebox--record (/= delta 0) (> bh 0))
      (when (or (ebox-cs-bbot cs) rounded)
        (push (list (list 'lines node (+ mt (1- bh)) 'border) 0 1 1) ebox--damage)
        (when (and (> delta 0) (> old-bh 0))
          (push (list (list 'lines node (+ mt (1- old-bh)) 'border) 0 1 1) ebox--damage)))
      (when (or (ebox-cs-btop cs) rounded)
        (push (list (list 'lines node mt 'border) 0 1 1) ebox--damage)
        (when (and (> delta 0) (< delta bh))
          (push (list (list 'lines node (+ mt delta) 'border) 0 1 1) ebox--damage))))))

(defun ebox--relayout-partial (node)
  "Relayout NODE's dirty descendants while its constraints are unchanged."
  (let* ((geo (ebox-node-layout node))
         (old-bh (ebox-geo-bh geo))
         (kids (ebox-node-dkids node))
         (ops (reverse (ebox-node-ops node)))
         (ebox--shift (cons 0 0))
         changed full)
    (setf (ebox-node-dkids node) nil
          (ebox-node-ops node) nil)
    (ebox--uncache node)
    (dolist (kid kids)
      (setf (ebox-node-dirty kid) (logand (ebox-node-dirty kid) (lognot ebox--d-queued))))
    (setf (ebox-node-dirty node) (logand (ebox-node-dirty node) (lognot ebox--d-desc)))
    (let ((ops-recorded nil))
      (when ops
        (let ((res (ebox--apply-ops node geo ops)))
          (if res
              (setq ops-recorded (and (consp res) res))
            (setq full t))))
      (unless full
        (dolist (kid kids)
          (when (and (not full)
                     (eq (ebox-node-parent kid) node)
                     (not (zerop (logand (ebox-node-dirty kid) 15)))
                     (not (ebox--abs-p kid))
                     (or (ebox--content-stable-p geo kid) (progn (setq full t) nil)))
            (let* ((flow (eq (ebox-node-tag node) 'box))
                   (para (and flow (ebox--inline-p kid) (ebox--para-of geo kid))))
              (cond
               (para
                (let ((oh (ebox-para-h para)))
                  (ebox--layout-para para (ebox-para-w para))
                  (if (= oh (ebox-para-h para))
                      (when ebox--record
                        (setq ebox--damage (cons (list para 0 oh oh) ebox--damage)))
                    (push (list para (ebox-para-w para) oh) changed))))
               ((and flow (ebox--inline-p kid)) (setq full t))
               (t
                (let* ((ow (ebox-node-w kid)) (oh (ebox-node-h kid))
                       (key (ebox--constraint kid))
                       (nat (and key (aref key 3) (ebox-geo-nat (ebox-node-layout kid)))))
                  (if (null key)
                      (setq full t)
                    (when (and (ebox--layout kid (aref key 0) (aref key 1) (aref key 2)
                                             (aref key 3))
                               (aref key 3))
                      ;; NODE derived KID's forced height from KID's natural
                      ;; height; measure again when that may have changed.
                      (let ((new (ebox--stretched-natural kid)))
                        (setf (ebox-geo-nat (ebox-node-layout kid)) new)
                        (unless (and new nat (= new nat))
                          (setq full t))))
                    (unless (and (= ow (ebox-node-w kid)) (= oh (ebox-node-h kid)))
                      (push (list kid ow oh) changed))))))))))
      (when (and changed (not full))
        (unless (ebox--absorb node geo (nreverse changed) ops-recorded)
          (setq full t))))
    (if full
        (let ((key (ebox--constraint node)))
          (setf (ebox-node-intr node) nil)
          ;; Partial layout has already replaced CHANGED children's sizes.
          ;; A fresh place snapshot would compare their new sizes with
          ;; themselves and wrongly forward a child insertion/deletion through
          ;; a fixed-size parent.  Repaint this boundary instead; its old
          ;; outer height is still intact and siblings outside it cannot move.
          (when changed
            (setf (ebox-node-dirty node)
                  (logior (ebox-node-dirty node) ebox--d-layout)))
          (ebox--layout-full node (aref key 0) (aref key 1) (aref key 2) (aref key 3))
          t)
      (ebox--border-damage node geo old-bh)
      (ebox--relayout-overlays node ebox--shift)
      (and (or changed ops) t))))

(defun ebox--apply-ops (node geo ops)
  "Apply structural OPS to stack NODE incrementally; nil requests full layout."
  (when (and (memq (ebox-node-tag node) '(column))
             (ebox--stack-capable-p node geo)
             (< (length ops) 64)
             (cl-every (lambda (op) (memq (car op) '(insert remove))) ops))
    (let* ((cs (ebox-node-cs node))
           (cw (ebox-geo-cw geo))
           (cross (ebox-cs-cross cs))
           (gap (or (ebox-geo-gap geo) 0))
           (key (ebox--constraint node))
           (cbh (and key (ebox--definite-height node geo (aref key 2) (aref key 3))))
           (total 0)
           recorded)
      (catch 'fail
        (dolist (op ops)
          (let ((items (ebox-geo-items geo)) (n (ebox-geo-n geo)))
            (pcase op
              (`(insert ,child)
               ;; A moved child keeps its layout but has left the items.
               (when (or (not (eq (ebox-node-parent child) node)) (ebox--abs-p child)
                         (ebox--inline-p child) (ebox--stacked-p geo child))
                 (throw 'fail nil))
               (let* ((prev (ebox--prev-stacked node geo child))
                      (index (if (eq prev 'none) (throw 'fail nil)
                               (if prev (+ (ebox-run-start (ebox-node-irun prev))
                                           (ebox-node-ipos prev) 1)
                                 0)))
                      (prev (and (ebox-node-p prev) prev))
                      (y (if prev (+ (ebox--item-y prev) (ebox--item-h prev) gap) 0)))
                 (ebox--layout child cw (if (eq cross 'stretch) 'stretch 'shrink) cbh)
                 (setf (ebox-node-irun child) nil
                       (ebox-node-x child) (ebox--cross-x child cw cross))
                 (let* ((h (ebox-node-h child))
                        (extra (if (> n 0) gap 0))
                        (delta (+ h extra))
                        (run (ebox--seq-insert items index child #'ebox--item-ref)))
                   (setf (ebox-node-y child) (- y (ebox-run-dy run))
                         (ebox-geo-n geo) (1+ n))
                   (ebox--shift-after geo child delta)
                   (ebox--note-shift delta)
                   (setq total (+ total delta))
                   (when ebox--record
                     (let ((start (if prev (- y extra) y)))
                       (setq recorded (ebox--shift-recorded recorded start 0 delta))
                       (push (list (list 'lines node start) 0 0 delta) recorded)
                       (push (car recorded) ebox--damage))))))
              (`(remove ,child ,_old-y ,old-h)
               (unless (ebox--stacked-p geo child) (throw 'fail nil))
               (let* ((run (ebox-node-irun child))
                      (index (+ (ebox-run-start run) (ebox-node-ipos child)))
                      (old-y (ebox--item-y child))
                      (prev (and (> index 0) (ebox--seq-ref items (1- index)))))
                 (let* ((last (= index (1- n)))
                        (extra (if (> n 1) gap 0))
                        (delta (+ old-h extra))
                        (start (if (and last (> index 0)) (- old-y extra) old-y)))
                   (ebox--seq-delete items run (ebox-node-ipos child) #'ebox--item-ref)
                   (setf (ebox-node-irun child) nil
                         (ebox-geo-n geo) (1- n))
                   (if prev
                       (ebox--shift-after geo prev (- delta))
                     (ebox--shift-after geo nil (- delta)))
                   (ebox--note-shift (- delta))
                   (setq total (- total delta))
                   (when ebox--record
                     (setq recorded (ebox--shift-recorded recorded start delta 0))
                     (push (list (list 'lines node start) 0 delta 0) recorded)
                     (push (car recorded) ebox--damage))))))))
        (and (ebox--stack-resize node geo total) (or recorded t))))))

(defun ebox--shift-recorded (recorded start old new)
  "Move RECORDED line damages past an edit of OLD lines to NEW at START.
Each damage is stated in the lines that exist after it, so a later edit
before it moves it.  Throw `fail' when the edit overlaps a recorded range."
  (let ((delta (- new old)) (end (+ start old)))
    (dolist (damage recorded recorded)
      (let* ((item (car damage)) (at (nth 2 item)) (lines (nth 3 damage)))
        (cond ((>= at end) (setf (nth 2 item) (+ at delta)))
              ((and (zerop lines) (>= at start)) (setf (nth 2 item) start))
              ((<= (+ at lines) start))
              (t (throw 'fail nil)))))))

(defun ebox--prev-stacked (node geo child)
  "Return the stacked item of GEO that CHILD follows, nil when it comes first.
The items are NODE's laid-out in-flow children, so CHILD follows the
nearest such sibling before it.  Return the symbol none when that sibling
is not one of GEO's items."
  (let ((prev (ebox--prev-kid child)) found)
    (while (and prev (not found))
      (if (and (ebox-node-layout prev) (not (ebox--abs-p prev)))
          (setq found prev)
        (setq prev (ebox--prev-kid prev))))
    (cond ((null found) nil)
          ((and (eq (ebox-node-parent found) node) (ebox--stacked-p geo found)) found)
          (t 'none))))

;;;; Images

(declare-function ebox-image--lines "ebox-image" (image))
(declare-function ebox-image--width "ebox-image" (image))

(defun ebox--image-width (node)
  "Return image NODE's content width in pixels."
  (ebox-image--width (ebox-node-image node)))

(defun ebox--layout-image (node geo)
  "Lay out image NODE; return its content height."
  (let ((lines (ebox-image--lines (ebox-node-image node))))
    (setf (ebox-geo-kind geo) 'image)
    (ebox--set-items geo (vconcat lines))
    (length lines)))

;;;; Overlays (absolutely positioned descendants)

(defun ebox--host-cs-p (cs)
  "Return non-nil when a node styled CS hosts absolutely positioned children.
Every box hosts its absolute children; inline boxes lack box geometry of
their own, so their absolute children belong to the nearest enclosing box."
  (not (eq (ebox-cs-outer cs) 'inline)))

(defun ebox--host-of (node)
  "Return the positioning host of absolutely positioned NODE.
That is the nearest non-inline parent, or the root for `:layer root'."
  (if (eq (ebox--cv (ebox-node-cs node) 'ebox/layer) 'root)
      (ebox-node-root node)
    (let ((parent (ebox-node-parent node)))
      (while (and (ebox-node-parent parent)
                  (not (ebox--host-cs-p (ebox-node-cs parent))))
        (setq parent (ebox-node-parent parent)))
      parent)))

(defun ebox--register-overlay (node)
  "Register absolutely positioned NODE with its host."
  (let* ((host (ebox--host-of node))
         (list (ebox-node-overlays host)))
    (unless (memq node list)
      (setf (ebox-node-overlays host) (append list (list node))))
    (setf (ebox-node-host node) host)
    host))

(defun ebox--live-overlays (host)
  "Return HOST's overlays that are still attached under it."
  (let ((list (ebox-node-overlays host)) live)
    (dolist (node list)
      (when (and (ebox-node-cs node) (ebox--abs-p node)
                 (eq (ebox-node-host node) host)
                 (ebox-node-ancestor-p host node))
        (push node live)))
    (setq live (nreverse live))
    (unless (= (length live) (length list))
      (setf (ebox-node-overlays host) live))
    live))

(defun ebox--doc-path (node)
  "Return NODE's child-index path from its root."
  (let (path)
    (while (ebox-node-parent node)
      (push (ebox-node-index node) path)
      (setq node (ebox-node-parent node)))
    path))

(defun ebox--doc-before-p (a b)
  "Return non-nil when node A precedes node B in document order."
  (let ((pa (ebox--doc-path a)) (pb (ebox--doc-path b)))
    (while (and pa pb (= (car pa) (car pb)))
      (setq pa (cdr pa) pb (cdr pb)))
    (if (and pa pb) (< (car pa) (car pb)) (and pb t))))

(defun ebox--ordered-overlays (host)
  "Return HOST's live overlays, kept in document order for equal z-index."
  (let ((live (ebox--live-overlays host)))
    (when (cdr live)
      (setq live (sort (copy-sequence live) #'ebox--doc-before-p))
      (setf (ebox-node-overlays host) live))
    live))

(defun ebox--root-xy (node)
  "Return (X . Y) of NODE's margin box in root margin-box coordinates."
  (let ((parent (ebox-node-parent node)))
    (cond
     ((null parent) (cons 0 0))
     ((null (ebox-node-layout node)) (ebox--root-xy parent))
     ((ebox--abs-p node)
      (let* ((host (ebox-node-host node))
             (hgeo (ebox-node-layout host))
             (origin (ebox--root-xy host)))
        (cons (+ (car origin) (ebox-geo-ml hgeo) (ebox-node-x node))
              (+ (cdr origin) (ebox-geo-mt hgeo) (ebox-node-y node)))))
     (t
      (let* ((geo (ebox-node-layout parent))
             (origin (ebox--root-xy parent)))
        (cons (+ (car origin) (ebox-geo-ml geo) (ebox-geo-bl geo) (ebox-geo-pl geo)
                 (ebox-node-x node))
              (+ (cdr origin) (ebox-geo-mt geo) (ebox-geo-pt geo)
                 (- (ebox-geo-scroll geo)) (ebox--item-y node))))))))

(defun ebox--find-anchor (host id)
  "Find the node with ID under HOST's root tree."
  (let ((name (ebox--token id)) found)
    (catch 'done
      (ebox-node-walk (ebox-node-root host)
                      (lambda (node)
                        (when (equal (ebox-node-id node) name)
                          (setq found node) (throw 'done nil)))))
    found))

(defvar ebox--anchor-targets (make-hash-table :test 'eq :weakness 'key)
  "The resolved anchor target of each anchored overlay.")

(defun ebox--anchor-target (host node id)
  "Return the node with ID that overlay NODE in HOST is anchored to."
  (let ((cached (gethash node ebox--anchor-targets)))
    (if (and cached (equal (ebox-node-id cached) (ebox--token id))
             (eq (ebox-node-root cached) (ebox-node-root host)))
        cached
      (let ((found (ebox--find-anchor host id)))
        (if found
            (puthash node found ebox--anchor-targets)
          (remhash node ebox--anchor-targets))
        found))))

(defun ebox--place-overlay (host node)
  "Resolve absolutely positioned NODE's origin in HOST's border box."
  (let* ((cs (ebox-node-cs node))
         (hgeo (ebox-node-layout host))
         (width (ebox-geo-bw hgeo))
         (height (ebox-geo-bh hgeo))
         (x (+ (ebox-geo-bl hgeo)
               (or (ebox--px (ebox--cv cs 'ebox/left) cs
                             (- width (ebox-geo-bl hgeo) (ebox-geo-br hgeo)))
                   0)))
         (y (or (ebox--lines (ebox--cv cs 'ebox/top) cs height) 0))
         (anchor (ebox--cv cs 'ebox/anchor)))
    (cond
     ((and (not anchor) (eq (ebox--cv cs 'ebox/layer) 'root))
      ;; A root-layer box covers the page: offsets start at the root's
      ;; border-box origin, which its percentages also measure.
      (cons (or (ebox--px (ebox--cv cs 'ebox/left) cs width) 0) y))
     ((not anchor)
      ;; Offsets start at the host's content origin.
      (cons (+ x (ebox-geo-pl hgeo)) (+ y (ebox-geo-pt hgeo))))
     (t
      (let ((target (ebox--anchor-target host node anchor)))
        ;; An anchor inside the overlay itself would follow its own placement.
        (when (and target (ebox-node-layout target) (not (ebox--hidden-p target))
                   (not (ebox-node-ancestor-p node target)))
          (let* ((target-xy (ebox--root-xy target))
                 (host-xy (ebox--root-xy host))
                 (hgeo* (ebox-node-layout host))
                 (tgeo (ebox-node-layout target))
                 (tx (- (+ (car target-xy) (ebox-geo-ml tgeo))
                        (car host-xy) (ebox-geo-ml hgeo*)))
                 (ty (- (+ (cdr target-xy) (ebox-geo-mt tgeo))
                        (cdr host-xy) (ebox-geo-mt hgeo*)))
                 (tw (ebox-geo-bw tgeo)) (th (ebox-geo-bh tgeo))
                 (lw (ebox-node-w node)) (lh (ebox-node-h node))
                 (placement (or (ebox--cv cs 'ebox/placement) 'bottom-start))
                 (above (memq placement '(top-start top-end)))
                 (left (+ tx x (if (memq placement '(bottom-end top-end)) (- tw lw) 0)))
                 (top (+ y ty (if above (- lh) th)))
                 (other (+ y ty (if above th (- lh)))))
            (when (and (or (< top 0) (> (+ top lh) height))
                       (>= other 0) (<= (+ other lh) height))
              (setq top other))
            (cons (max 0 (min left (max 0 (- width lw))))
                  (max 0 (min top (max 0 (- height lh))))))))))))

(defun ebox--layout-overlay (host node &optional record)
  "Lay out and place overlay NODE in HOST; return non-nil when it changed.
RECORD keeps inner damage for a caller that can reuse stable overlay rows."
  (let* ((hgeo (ebox-node-layout host))
         (old (list (ebox-node-x node) (ebox-node-y node) (ebox-node-w node) (ebox-node-h node)
                    (ebox-node-placed node)))
         (ebox--record record))
    (ebox--layout node (ebox-geo-bw hgeo) 'shrink (ebox-geo-bh hgeo))
    (let ((origin (ebox--place-overlay host node)))
      (setf (ebox-node-x node) (if origin (car origin) 0)
            (ebox-node-y node) (if origin (cdr origin) 0))
      (setf (ebox-node-placed node) (and origin t))
      (not (equal old (list (ebox-node-x node) (ebox-node-y node) (ebox-node-w node)
                            (ebox-node-h node) (and origin t)))))))

(defun ebox--layout-overlays (host)
  "Lay out every overlay registered on HOST after its flow layout."
  (dolist (node (ebox--ordered-overlays host))
    (setf (ebox-node-dirty node) (logior (ebox-node-dirty node) ebox--d-layout))
    (ebox--layout-overlay host node)))

(defun ebox--relayout-overlays (host &optional shift)
  "Relayout HOST's overlays and record damage for those that changed.
SHIFT is (UP . DOWN), the extreme line shifts HOST's flow content received;
lines that showed an overlay before the shift must be repainted as well."
  (let* ((moved (and shift (or (/= 0 (car shift)) (/= 0 (cdr shift)))))
         (before (ebox--live-overlays host))
         (after (ebox--ordered-overlays host))
         ;; Overlays repaint in their new stacking order.
         (reordered (not (cl-every #'eq before after)))
         (up (if moved (car shift) 0))
         (down (if moved (cdr shift) 0)))
    (when ebox--record
      (dolist (span (gethash host ebox--vacated))
        (ebox--overlay-damage host (+ (car span) up) (+ (cdr span) (- down up)))))
    (remhash host ebox--vacated)
    (dolist (node after)
      (let* ((oy (ebox-node-y node)) (oh (ebox-node-h node))
             (was-placed (ebox-node-placed node))
             (dirty (or reordered (/= 0 (ebox-node-dirty node))))
             inner
             (changed (let ((ebox--damage nil))
                        (prog1 (ebox--layout-overlay host node ebox--record)
                          (setq inner ebox--damage)))))
        (when (and ebox--record (or changed dirty (and moved (or was-placed (ebox-node-placed node)))))
          (if (and was-placed (not changed) (not reordered) (not moved)
                   ;; An overlay is not in flow: an inner insertion/deletion
                   ;; must never insert/delete the host's physical rows. Keep
                   ;; clipped or escaping ranges on the bounded whole path.
                   (let* ((top (ebox--item-top-in-root node))
                          (bottom (+ top (ebox-node-h node)))
                          (limit (ebox-node-h (ebox-node-root host))))
                     (cl-every
                      (lambda (damage)
                        (and (= (nth 2 damage) (nth 3 damage))
                             (cl-every
                              (lambda (range)
                                (and (>= (car range) (max 0 top))
                                     (<= (+ (car range) (nth 2 range))
                                         (min limit bottom))))
                              (ebox--damage-range damage))))
                      inner)))
              ;; No inner damage also means no repaint: a logical descendant
              ;; can be a root-layer overlay laid out by a different host.
              (setq ebox--damage (nconc inner ebox--damage))
            (let* ((hgeo (ebox-node-layout host))
                   (up (if moved (car shift) 0)) (down (if moved (cdr shift) 0))
                   (top (+ (ebox-geo-mt hgeo) (min (+ oy up) (ebox-node-y node))))
                   (bottom (+ (ebox-geo-mt hgeo)
                              (max (+ oy oh down) (+ (ebox-node-y node) (ebox-node-h node)))))
                   (top (max 0 (min top (ebox-node-h host))))
                   (bottom (max top (min bottom (ebox-node-h host)))))
              (when (> bottom top)
                (push (list (list 'lines host top 'border) 0 (- bottom top) (- bottom top))
                      ebox--damage)))))))))

(defun ebox--overlay-damage (host y h)
  "Record damage for HOST's border-box lines Y to Y+H under an overlay."
  (let* ((hgeo (ebox-node-layout host))
         (top (max 0 (min (+ (ebox-geo-mt hgeo) y) (ebox-node-h host))))
         (bottom (max top (min (+ top h) (ebox-node-h host)))))
    (when (> bottom top)
      (push (list (list 'lines host top 'border) 0 (- bottom top) (- bottom top))
            ebox--damage))))

(defun ebox--anchored-p (node)
  "Return non-nil when NODE is an anchored overlay."
  (let ((cs (ebox-node-cs node)))
    (and cs (ebox-cs-abs cs) (ebox-node-parent node) (ebox--cv cs 'ebox/anchor) t)))

(defun ebox--collect-anchored (root)
  "Return the anchored overlays under ROOT."
  (let (found)
    (ebox-node-walk root (lambda (node) (when (ebox--anchored-p node) (push node found))))
    found))

(defun ebox--place-anchored (root overlays)
  "Place anchored OVERLAYS of ROOT after layout and return the live ones.
Anchor targets may move without relaying out an overlay's host, and a target
may sit inside another overlay, so placement repeats until it settles."
  (let* ((live (cl-remove-if-not
                (lambda (node)
                  (let ((host (ebox-node-host node)))
                    (and (ebox--anchored-p node) host
                         (ebox-node-layout host) (ebox-node-layout node)
                         (ebox-node-ancestor-p host node)
                         (eq (ebox-node-root node) root))))
                overlays))
         (rounds (1+ (length live)))
         (moved t))
    (while (and moved (> rounds 0))
      (setq moved nil rounds (1- rounds))
      (dolist (node live)
        (let* ((host (ebox-node-host node))
               (origin (ebox--place-overlay host node))
               (x (if origin (car origin) 0))
               (y (if origin (cdr origin) 0)))
          (unless (and (= x (ebox-node-x node)) (= y (ebox-node-y node))
                       (eq (and origin t) (ebox-node-placed node)))
            (when (and ebox--record (ebox-node-placed node))
              (ebox--overlay-damage host (ebox-node-y node) (ebox-node-h node)))
            (setf (ebox-node-x node) x (ebox-node-y node) y
                  (ebox-node-placed node) (and origin t))
            (when (and ebox--record origin)
              (ebox--overlay-damage host y (ebox-node-h node)))
            (setq moved t)))))
    live))

;;;; Composition

(defsubst ebox--parent-padface (node)
  "Return the face of the area around NODE's border box."
  (let ((parent (ebox-node-parent node)))
    (and parent (ebox-cs-padface (ebox-node-cs parent)))))

(defun ebox--item-parts (item i tail)
  "Return the strings of line I of ITEM's margin box followed by TAIL."
  (if (ebox-para-p item)
      (let ((lines (ebox-para-lines item)))
        (cons (if (< i (length lines)) (aref lines i)
                (ebox--space (ebox-para-w item)
                             (ebox-cs-padface (ebox-node-cs (ebox-para-owner item)))))
              tail))
    (cons (ebox--node-parts item i) tail)))

(defun ebox--find-item (geo ci)
  "Return the stacked item in GEO covering content line CI, or nil."
  (let* ((seq (ebox-geo-items geo))
         (runs (ebox-seq-runs seq))
         (nr (ebox-seq-nr seq)))
    (when (> nr 0)
      ;; O(1) sequential cursor check for forward line composition scans.
      (let* ((cr (ebox-seq-cr seq))
             (cidx (ebox-seq-ci seq))
             (hit 'miss))
        (when (and (>= cr 0) (< cr nr))
          (let* ((run (aref runs cr))
                 (rn (ebox-run-n run)))
            (when (and (>= cidx 0) (< cidx rn))
              (let* ((vec (ebox-run-vec run))
                     (dy (ebox-run-dy run))
                     (item (aref vec cidx))
                     (y (+ dy (if (ebox-para-p item) (ebox-para-y item) (ebox-node-y item))))
                     (end (+ y (ebox--item-h item))))
                (cond
                 ((and (>= ci y) (< ci end))
                  (setq hit item))
                 ((>= ci end)
                  (let* ((nr2 (if (< (1+ cidx) rn) cr (1+ cr)))
                         (ni2 (if (< (1+ cidx) rn) (1+ cidx) 0)))
                    (if (>= nr2 nr)
                        (setq hit nil)
                      (let* ((run2 (aref runs nr2))
                             (rn2 (ebox-run-n run2)))
                        (when (< ni2 rn2)
                          (let* ((item2 (aref (ebox-run-vec run2) ni2))
                                 (y2 (+ (ebox-run-dy run2)
                                        (if (ebox-para-p item2)
                                            (ebox-para-y item2)
                                          (ebox-node-y item2)))))
                            (cond
                             ((< ci y2) (setq hit nil))
                             ((< ci (+ y2 (ebox--item-h item2)))
                              (setf (ebox-seq-cr seq) nr2
                                    (ebox-seq-ci seq) ni2)
                              (setq hit item2))))))))))))))
        (if (not (eq hit 'miss))
            hit
          (let ((lo 0) (hi (1- nr)))
            ;; The last run whose first item starts at or before CI.
            (while (< lo hi)
              (let ((mid (/ (+ lo hi 1) 2)))
                (if (<= (ebox--item-y (aref (ebox-run-vec (aref runs mid)) 0)) ci)
                    (setq lo mid)
                  (setq hi (1- mid)))))
            (when (>= hi 0)
              (let* ((r lo)
                     (run (aref runs r)) (vec (ebox-run-vec run)) (dy (ebox-run-dy run))
                     (lo 0) (hi (1- (ebox-run-n run))) found)
                (while (and (<= lo hi) (not found))
                  (let* ((mid (/ (+ lo hi) 2))
                         (item (aref vec mid))
                         (y (+ dy (if (ebox-para-p item) (ebox-para-y item) (ebox-node-y item)))))
                    (cond ((< ci y) (setq hi (1- mid)))
                          ((>= ci (+ y (ebox--item-h item))) (setq lo (1+ mid)))
                          (t (setf (ebox-seq-cr seq) r
                                   (ebox-seq-ci seq) mid)
                             (setq found item)))))
                found))))))))

;; Emacs composites an image's transparent pixels over the frame
;; background unless the descriptor names one, so a round avatar on a tinted
;; row would show frame-colored corners.  Each slice is painted over the
;; nearest background of its box or ancestors instead.  Preparation already
;; decodes for the most recent such background, so the common case of images
;; over one background displays the prepared descriptor and decodes once.

(defvar ebox--image-backgrounds (make-hash-table :test 'eq :weakness 'key)
  "Image descriptors and slice strings to alists of (BACKGROUND . VARIANT).
Slices of one image share one descriptor variant, so it decodes once.")

(defun ebox--background-variant (object bg make)
  "Return OBJECT's variant for BG, building it with MAKE once."
  (let ((variants (gethash object ebox--image-backgrounds)))
    (or (cdr (assoc bg variants))
        (let ((variant (funcall make)))
          (puthash object (cons (cons bg variant) variants) ebox--image-backgrounds)
          variant))))

(defun ebox--image-on-background (line node)
  "Return image slice LINE composited over NODE's background.
A descriptor prepared for this background is shown as is; any other
background gets one shared variant."
  (let* ((bg (and (not noninteractive) (ebox-cs-bg (ebox-node-cs node))))
         (bg (and (stringp bg) bg))
         (display (and (> (length line) 0) (get-text-property 0 'display line)))
         (image (and (consp display) (eq (car-safe (car (last display))) 'image)
                     (car (last display)))))
    (when (and image bg) (setq ebox-image--background bg))
    (if (or (not image) (equal bg (plist-get (cdr image) :background)))
        line
      (ebox--background-variant
       line bg
       (lambda ()
         (let ((copy (copy-sequence line))
               (variant (ebox--background-variant
                         image bg
                         (lambda ()
                           (cons 'image
                                 (if bg
                                     (plist-put (copy-sequence (cdr image))
                                                :background bg)
                                   (cl-loop for (key value) on (cdr image) by #'cddr
                                            unless (eq key :background)
                                            append (list key value))))))))
           (put-text-property 0 1 'display (append (butlast display) (list variant))
                              copy)
           copy))))))

(defun ebox--content-parts (node geo ci tail)
  "Return the strings of content line CI of NODE followed by TAIL.
The strings span the content width CW in pixels."
  (let* ((cw (ebox-geo-cw geo))
         (padface (ebox-cs-padface (ebox-node-cs node)))
         (items (ebox-geo-items geo)))
    (pcase (ebox-geo-kind geo)
      ;; A stretched image box paints its background beyond the image.
      ('image (if (< ci (ebox-geo-n geo))
                  (let* ((width (ebox--image-width node))
                         (line (ebox--image-on-background (aref items ci) node))
                         (fill (- cw width)))
                    (cond
                     ;; The content box is narrower than the picture: a
                     ;; stretched image node still paints at its own width,
                     ;; and the surplus would overrun the box into whatever
                     ;; shares the line.  Cut the slice to the content box.
                     ((< fill 0)
                      (cons (car (ebox--split-parts (list line) cw)) tail))
                     ((and padface (> fill 0))
                      (cons line (cons (ebox--space fill padface) tail)))
                     (t (cons line tail))))
                (cons (ebox--space cw padface) tail)))
      ('stack
       (let ((item (ebox--find-item geo ci)))
         (if (null item)
             (cons (ebox--space cw padface) tail)
           (let ((x (ebox--item-x item)) (w (ebox--item-w item)))
             ;; A stacked child can retain an intrinsic/minimum width larger
             ;; than this content box.  Clip its paint, not its geometry: an
             ;; overlay splice must receive exactly the advertised width or
             ;; the surplus shifts every later window on the same row.
             (if (> (+ x w) cw)
                 (nconc (when (> (min x cw) 0)
                          (list (ebox--space (min x cw) padface)))
                        (when (< x cw)
                          (car (ebox--split-parts
                                (ebox--join-parts
                                 (ebox--item-parts item (- ci (ebox--item-y item)) nil))
                                (- cw x))))
                        tail)
               (let* ((right (- cw x w))
                      (parts (ebox--item-parts
                              item (- ci (ebox--item-y item))
                              (if (> right 0)
                                  (cons (ebox--space right padface) tail)
                                tail))))
                 (if (> x 0)
                     (cons (ebox--space x padface) parts)
                   parts)))))))
      (_
       (let ((cursor 0) (hits nil) (sorted t) (last -1) (shown nil))
         (dotimes (i (ebox-geo-n geo))
           (let* ((item (aref items i))
                  (y (ebox--item-y item)))
             (when (and (>= ci y) (< ci (+ y (ebox--item-h item))))
               (when (< (ebox--item-x item) last) (setq sorted nil))
               (setq last (ebox--item-x item))
               (push item hits))))
         (setq hits (nreverse hits))
         (unless sorted
           (setq hits (sort hits (lambda (a b) (< (ebox--item-x a) (ebox--item-x b))))))
         ;; Items overlapping an earlier one are not shown; SHOWN holds the
         ;; rest with the gap before each, last first.
         (dolist (item hits)
           (let ((x (ebox--item-x item)))
             (when (>= x cursor)
               (push (cons (- x cursor) item) shown)
               (setq cursor (+ x (ebox--item-w item))))))
         (setq tail (cons (ebox--space (- cw cursor) padface) tail))
         ;; Text cannot overlap, so an item overflowing the content box is
         ;; cut at its edge instead of pushing later siblings to the right.
         (dolist (entry shown tail)
           (let* ((item (cdr entry))
                  (x (ebox--item-x item))
                  (parts (ebox--item-parts item (- ci (ebox--item-y item)) nil)))
             (when (> (+ x (ebox--item-w item)) cw)
               (setq parts (and (< x cw)
                                (list (car (ebox--split-at (ebox--join parts)
                                                           (- cw x)))))))
             (setq tail (cons (ebox--space (car entry) padface)
                              (nconc parts tail))))))))))

;;;; Background shape
;; On graphical frames a box with a background paints it as a rectangle that
;; may be rounded by `:border-radius' and inset by fractional block padding:
;; padding of (lh 0.4) takes a whole line but paints the background only
;; over 0.4 of it, the rest showing the color around the box.  Lines the
;; shape leaves partly uncovered become one image of the background drawn
;; over the surrounding color; on lines holding content, only the ends of
;; the side padding become images of the rounded corners.  Rows keep their
;; width and line height, and text is never replaced.  Without SVG, or in
;; terminals, the background fills the whole border box.

(defvar ebox--shape-cache (make-hash-table :test 'equal)
  "Background shape image strings keyed by their drawing parameters.")

(defun ebox--shape-image (width x0 x1 top bottom radius inside outside)
  "Return a one-glyph string WIDTH pixels wide and one line tall.
It paints OUTSIDE and over it an INSIDE rectangle from X0 to X1 and TOP to
BOTTOM pixels, with corners of RADIUS pixels."
  (let* ((metrics (ebox-image--metrics nil))
         (key (list width x0 x1 top bottom radius inside outside metrics)))
    (or (gethash key ebox--shape-cache)
        (puthash
         key
         (let* ((height (nth 1 metrics))
                (r (max 0 (min radius (/ (- bottom top) 2) (/ (- x1 x0) 2))))
                (svg (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><rect width='%d' height='%d' fill='%s'/><rect x='%d' y='%d' width='%d' height='%d' rx='%d' fill='%s'/></svg>"
                             width height width height outside
                             x0 top (- x1 x0) (- bottom top) r inside))
                (image (create-image svg 'svg t :ascent (nth 2 metrics)
                                     :scale 1 :margin 0)))
           (propertize " " 'display (list (list 'slice 0 0 width height) image)))
         ebox--shape-cache))))

(defun ebox--shape (node geo bi)
  "Return NODE's background shape on border-box line BI, or nil.
The value is (TOP BOTTOM RADIUS INSIDE OUTSIDE) in pixels relative to the
line's top when the shape does not simply fill the line."
  (let ((cs (ebox-node-cs node)))
    (when (and (ebox-cs-padface cs) (not noninteractive) (display-graphic-p))
      (let* ((radius (min (or (ebox--px (ebox--cv cs 'ebox/border-radius) cs nil) 0)
                          (ebox--line-px)))
             (it (ebox--pad-inset (ebox-cs-pt cs) (ebox-geo-pt geo)))
             (ib (ebox--pad-inset (ebox-cs-pb cs) (ebox-geo-pb geo)))
             (lh (ebox--line-px))
             (top (- it (* bi lh)))
             (bottom (- (* (ebox-geo-bh geo) lh) ib (* bi lh))))
        (when (and (or (> radius 1) (> it 0) (> ib 0))
                   (or (> top (- radius)) (< bottom (+ lh radius)))
                   (ebox-image--metrics nil)
                   (image-type-available-p 'svg))
          (let* ((parent (ebox-node-parent node))
                 (inside (ebox-cs-bg cs))
                 (outside (or (and parent (ebox-cs-bg (ebox-node-cs parent)))
                              (face-background 'default nil t))))
            (unless (equal inside outside)
              (list top bottom (if (> radius 1) radius 0) inside outside))))))))

(defun ebox--shape-end (shape left width padface)
  "Return the strings of WIDTH pixels of side padding under SHAPE.
LEFT selects the left side, whose outer end comes first."
  (pcase-let* ((`(,top ,bottom ,radius ,inside ,outside) shape)
               (r (min radius width)))
    (if (or (< r 2) (and (<= top (- radius)) (>= bottom (+ (ebox--line-px) radius))))
        (list (ebox--space width padface))
      (let ((corner (if left
                        (ebox--shape-image r 0 (* 4 radius) top bottom radius inside outside)
                      (ebox--shape-image r (- r (* 4 radius)) r top bottom radius
                                         inside outside)))
            (rest (ebox--space (- width r) padface)))
        (if left (list corner rest) (list rest corner))))))

(defun ebox--outline-slice (width offset box-width box-height y radius inside outside stroke)
  "Paint a rounded one-pixel outline in a WIDTH-pixel line slice.
OFFSET and Y locate the slice within the box.  Only background cells are
replaced; content and interaction still belong to the retained node tree."
  (let* ((metrics (ebox-image--metrics nil))
         (key (list 'outline width offset box-width box-height y radius
                    inside outside stroke metrics)))
    (or (gethash key ebox--shape-cache)
        (puthash
         key
         (let* ((height (nth 1 metrics))
                (svg (format
                      (concat "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'>"
                              "<rect width='%d' height='%d' fill='%s'/>"
                              "<rect x='%.3f' y='%.3f' width='%.3f' height='%.3f' rx='%.3f'"
                              " fill='%s' stroke='%s' stroke-width='1'/></svg>")
                      width height width height outside
                      (- 0.5 offset) (- 0.5 y) (1- box-width) (1- box-height)
                      (max 0 (- radius 0.5)) inside stroke))
                (image (create-image svg 'svg t :ascent (nth 2 metrics)
                                     :scale 1 :margin 0)))
           (propertize " " 'display (list (list 'slice 0 0 width height) image)))
         ebox--shape-cache))))

(defun ebox--background-cells-p (text)
  "Whether TEXT contains only padding cells, not text or media ink."
  (and (string-match-p "\\`[ \t]*\\'" text)
       (let ((position 0) (plain t))
         (while (and plain (< position (length text)))
           (let ((display (get-text-property position 'display text)))
             (setq plain (or (null display) (eq (car-safe display) 'space))))
           (setq position (next-single-property-change position 'display text (length text))))
         plain)))

(defun ebox--rounded-outline-parts (node geo bi parts)
  "Round a complete 1px solid frame on its first or last line.
Return replacement parts or nil when the frame is not uniform, SVG is not
available, or a corner contains ink.  Never cover a label or an image to
make room for decoration.  Ordinary middle rows keep the existing fast path."
  (let* ((cs (ebox-node-cs node))
         (color (ebox-cs-blc cs))
         (radius (or (ebox--px (ebox--cv cs 'ebox/border-radius) cs nil) 0)))
    (when (and (> radius 1) color (ebox-cs-btop cs) (ebox-cs-bbot cs)
               (= (ebox-geo-bl geo) 1) (= (ebox-geo-br geo) 1)
               (equal color (ebox-cs-brc cs)) (equal color (ebox-cs-btc cs))
               (equal color (ebox-cs-bbc cs))
               (not noninteractive) (display-graphic-p)
               (image-type-available-p 'svg) (ebox-image--metrics nil))
      (let* ((line (ebox--join-fresh parts))
             (width (ebox-geo-bw geo))
             (lh (ebox--line-px))
             (height (* (ebox-geo-bh geo) lh))
             (r (max 1 (floor (min radius lh (/ width 2) (/ height 2)))))
             (left-cut (ebox--px-cut line r 0 0))
             (right-cut (ebox--px-cut line (- width r) 0 0)))
        ;; Inspect original units before splitting: a cut through a glyph
        ;; turns its fragments into spaces and would hide that ink.
        (when (and (> r 1)
                   (ebox--background-cells-p
                    (substring line 0 (or (nth 2 left-cut) (car left-cut))))
                   (ebox--background-cells-p (substring line (car right-cut))))
          (let* ((middle (copy-sequence
                          (car (ebox--split-at (ebox--cut-right line r left-cut)
                                               (- width (* 2 r))))))
                 (base (or (ebox-cs-bg cs) (face-background 'default nil t)))
                 (outside (or (ebox--face-background (ebox--parent-padface node))
                              (face-background 'default nil t)))
                 (left-bg (or (and (> (length middle) 0)
                                   (ebox--face-background (get-text-property 0 'face middle))) base))
                 (right-bg (or (and (> (length middle) 0)
                                    (ebox--face-background
                                     (get-text-property (1- (length middle)) 'face middle))) base))
                 (stroke (if (eq color 'default) (face-foreground 'default nil t) color)))
            (when (= bi 0)
              (ebox--add-border-face middle :overline stroke))
            (when (= bi (1- (ebox-geo-bh geo)))
              (ebox--add-border-face middle :underline (list :position t :color stroke)))
            (puthash middle (- width (* 2 r)) ebox--part-widths)
            (list (ebox--outline-slice r 0 width height (* bi lh) r left-bg outside stroke)
                  middle
                  (ebox--outline-slice r (- width r) width height (* bi lh) r
                                       right-bg outside stroke))))))))

(defun ebox--border-parts (node geo bi tail)
  "Return the strings of border-box line BI of NODE followed by TAIL.
Overlays and top or bottom borders decorate the whole border-box line, which
is then joined into one string."
  (let* ((cs (ebox-node-cs node))
         (padface (ebox-cs-padface cs))
         (pt (ebox-geo-pt geo))
         (top (and (ebox-cs-btop cs) (= bi 0)))
         (bottom (and (ebox-cs-bbot cs) (= bi (1- (ebox-geo-bh geo)))))
         (whole (or top bottom (ebox-node-overlays node)))
         (parts (if whole nil tail)))
    (when (ebox-cs-brc cs)
      (push (ebox--border-side (ebox-geo-br geo) (ebox-cs-brc cs) 'right
                               (or padface (ebox--parent-padface node)))
            parts))
    (let* ((shape (and (ebox-cs-shaped cs) (ebox--shape node geo bi)))
           (lshape (and (not (ebox-cs-blc cs)) shape))
           (rshape (and (not (ebox-cs-brc cs)) shape))
           (inner (- (ebox-geo-bw geo) (ebox-geo-bl geo) (ebox-geo-br geo)))
           (lh (and shape (ebox--line-px))))
      (setq parts
            (cond
             ((and shape (or (>= (car shape) lh) (<= (cadr shape) 0)))
              (cons (ebox--space inner (ebox--parent-padface node)) parts))
             ((and shape (or (> (car shape) 0) (< (cadr shape) lh)))
              (pcase-let ((`(,top ,bottom ,radius ,inside ,outside) shape))
                (cons (ebox--shape-image inner 0 inner (max top -1000) (min bottom 1000)
                                         radius inside outside)
                      parts)))
             ((or (< bi pt) (>= bi (+ pt (ebox-geo-vh geo))))
              (if (or lshape rshape)
                  (let ((half (/ inner 2)))
                    (append (if lshape (ebox--shape-end lshape t half padface)
                              (list (ebox--space half padface)))
                            (if rshape (ebox--shape-end rshape nil (- inner half) padface)
                              (list (ebox--space (- inner half) padface)))
                            parts))
                (if (> inner 0)
                    (cons (ebox--space inner padface) parts)
                  parts)))
             (t
              (let* ((pl (ebox-geo-pl geo))
                     (pr (ebox-geo-pr geo))
                     (rtail (cond (rshape (append (ebox--shape-end rshape nil pr padface) parts))
                                  ((> pr 0) (cons (ebox--space pr padface) parts))
                                  (t parts)))
                     (mid (ebox--content-parts
                           node geo (+ (- bi pt) (ebox-geo-scroll geo)) rtail)))
                (cond (lshape (append (ebox--shape-end lshape t pl padface) mid))
                      ((> pl 0) (cons (ebox--space pl padface) mid))
                      (t mid)))))))
    (when (ebox-cs-blc cs)
      (push (ebox--border-side (ebox-geo-bl geo) (ebox-cs-blc cs) 'left
                               (or padface (ebox--parent-padface node)))
            parts))
    (if (not whole)
        parts
      (let ((line (if (ebox-node-overlays node)
                      (ebox--apply-overlays node geo bi (ebox--join-parts parts))
                    parts)))
        (let ((rounded (and (or top bottom) (not noninteractive)
                            (display-graphic-p)
                            (ebox--rounded-outline-parts node geo bi line))))
          (cond
           (rounded (cons rounded tail))
           ((not (or top bottom))
            ;; Overlays only splice strings: the line stays a list.
            (cons line tail))
           (t
            (setq line (ebox--join-fresh line))
            (puthash line (ebox-geo-bw geo) ebox--part-widths)
            (let ((framed (and (or top bottom)
                               (or (and top (< bi pt))
                                   (and bottom (>= bi (+ pt (ebox-geo-vh geo)))))
                               (ebox--text-border-rules-p)
                               (ebox--text-frame-ink-p line)
                               (ebox--text-frame-row node geo top))))
              (if framed
                  (cons framed tail)
                (when top
                  ;; A terminal has no overline face attribute, so this only
                  ;; decorates displays that can draw it.
                  (let ((c (ebox-cs-btc cs)))
                    (ebox--add-border-face line :overline (if (eq c 'default) t c))))
                (when bottom
                  (ebox--add-border-face
                   line :underline
                   (list :position t
                         :color (let ((c (ebox-cs-bbc cs)))
                                  (if (eq c 'default) 'foreground-color c)))))
                (cons line tail))))))))))

(defvar ebox--part-widths (make-hash-table :test 'eq :weakness 'key)
  "Pixel widths of composed part strings, which are shared and immutable.")

(defconst ebox--line-cache-max 256
  "Largest margin-box height whose composed lines a node caches.")

(defun ebox--uncache (node)
  "Forget the composed lines of NODE and of every box composing them.
A box composes a child's line only through `ebox--node-parts', which leaves
the child's LINES non-nil, so a box whose LINES is nil has no composed line
on any ancestor and the walk stops there."
  (while (and node (ebox-node-lines node))
    (setf (ebox-node-lines node) nil)
    (when (ebox--abs-p node) (ebox--uncache (ebox-node-host node)))
    (setq node (ebox-node-parent node))))

(defun ebox--node-parts (node i)
  "Return the strings composing line I of NODE's margin box.
The list is cached on NODE and shared; callers copy it before changing it."
  (let* ((cache (ebox-node-lines node))
         (hit (and (vectorp cache) (< i (length cache)) (aref cache i))))
    (or hit
        (let ((parts (or (ebox--compose-parts node i) (list ""))))
          (cond
           ((vectorp cache) (when (< i (length cache)) (aset cache i parts)))
           ((<= (ebox-node-h node) ebox--line-cache-max)
            (let ((vec (make-vector (ebox-node-h node) nil)))
              (when (< i (length vec)) (aset vec i parts))
              (setf (ebox-node-lines node) vec)))
           ((not (eq cache t)) (setf (ebox-node-lines node) t)))
          parts))))

(defun ebox--node-line (node i)
  "Return line I of NODE's margin box as one string."
  (ebox--join (ebox--node-parts node i)))

(defun ebox--compose-parts (node i)
  "Compose the strings of line I of NODE's margin box.
A node composes its margins, borders, padding and items into one flat list of
its descendants' strings, so a line is concatenated once when it is written.
An interactive node joins its line to carry its interaction properties."
  (let* ((geo (ebox-node-layout node))
         (cs (ebox-node-cs node))
         (mt (ebox-geo-mt geo)))
    (if (and (eq (ebox-geo-kind geo) 'stack)
             (zerop mt) (zerop (ebox-geo-ml geo)) (zerop (ebox-geo-mr geo))
             (zerop (ebox-geo-pt geo)) (zerop (ebox-geo-pl geo)) (zerop (ebox-geo-pr geo))
             (zerop (ebox-geo-bl geo)) (zerop (ebox-geo-br geo))
             (zerop (ebox-geo-scroll geo))
             (not (ebox-cs-btop cs)) (not (ebox-cs-bbot cs))
             (not (ebox-cs-shaped cs)) (not (ebox-cs-hidden cs))
             (not (ebox-node-overlays node)) (not (ebox-node-inter node))
             (>= i 0) (< i (ebox-geo-vh geo)))
        (let ((cw (ebox-geo-cw geo))
              (padface (ebox-cs-padface cs))
              (item (ebox--find-item geo i)))
          (if (null item)
              (list (ebox--space cw padface))
            (let ((x (ebox--item-x item)) (w (ebox--item-w item)))
              (if (> (+ x w) cw)
                  (nconc (when (> (min x cw) 0)
                           (list (ebox--space (min x cw) padface)))
                         (when (< x cw)
                           (car (ebox--split-parts
                                 (ebox--join-parts
                                  (ebox--item-parts item (- i (ebox--item-y item)) nil))
                                 (- cw x)))))
                (let* ((right (- cw x w))
                       (parts (ebox--item-parts
                               item (- i (ebox--item-y item))
                               (when (> right 0)
                                 (list (ebox--space right padface))))))
                  (if (> x 0)
                      (cons (ebox--space x padface) parts)
                    parts))))))
      (let ((parts
             (if (or (< i mt) (>= i (+ mt (ebox-geo-bh geo))) (ebox--hidden-p node))
                 (list (ebox--space (ebox-node-w node) (ebox--parent-padface node)))
               (let* ((ml (ebox-geo-ml geo)) (mr (ebox-geo-mr geo))
                      (face (and (or (> ml 0) (> mr 0)) (ebox--parent-padface node)))
                      (inner (ebox--border-parts
                              node geo (- i mt)
                              (when (> mr 0) (list (ebox--space mr face))))))
                 (if (> ml 0) (cons (ebox--space ml face) inner) inner)))))
        (if (and (ebox-node-inter node) ebox--decorate-function)
            (let ((line (funcall ebox--decorate-function node (ebox--join-fresh parts) t)))
              (puthash line (ebox-node-w node) ebox--part-widths)
              (list line))
          parts)))))

(defun ebox--px-cut (string x pos px)
  "Find the display unit of STRING holding pixel X, walking from POS at PX.
Return (POS PX) when a unit starts at or after X, (POS PX NEXT W) when the
unit from POS to NEXT, W pixels wide, straddles X, or (LEN PX) when STRING
ends first.  Runs without a display property are measured per character
through the face width table, without consing per unit."
  (let ((len (length string)) result)
    (while (and (not result) (< pos len))
      (if (>= px x)
          (setq result (list pos px))
        (let ((display (get-text-property pos 'display string)))
          (if display
              (let* ((space (ebox--fixed-space-width display))
                     (next (if space (1+ pos)
                             (or (next-single-property-change pos 'display string)
                                 len)))
                     (w (or space (ebox--display-width string pos next))))
                (if (> (+ px w) x)
                    (setq result (list pos px next w))
                  (setq px (+ px w) pos next)))
            (let ((face (get-text-property pos 'face string))
                  (run-end (next-property-change pos string len)))
              (while (and (not result) (< pos run-end))
                (if (>= px x)
                    (setq result (list pos px))
                  (let* ((next (ebox--cluster-end string pos len))
                         (w (if (= next (1+ pos))
                                (ebox--char-width (aref string pos) face)
                              (ebox--measure-raw (substring string pos next)))))
                    (if (> (+ px w) x)
                        (setq result (list pos px next w))
                      (setq px (+ px w) pos next))))))))))
    (or result (list len px))))

(defun ebox--unit-space (width string pos &optional offset)
  "Return WIDTH pixels of STRING's unit at POS, starting OFFSET pixels in.
An image unit keeps the visible part as a slice, preserving display modifiers.
Any other unit becomes a space that keeps its text properties other than
`display', so a
cut interactive or faced unit keeps its keymap, pointer and face."
  (let* ((props (and (< pos (length string)) (text-properties-at pos string)))
         (display (plist-get props 'display))
         (image (cond ((eq (car-safe display) 'image) display)
                      ((consp (car-safe display))
                       (if (eq (car-safe (cadr display)) 'image) (cadr display)
                         (assq 'image display)))))
         (slice (and image (not (eq image display))
                     (if (eq (car-safe (car display)) 'slice) (car display)
                       (assq 'slice display)))))
    (if (and image (> width 0)
             (or (null slice) (natnump (nth 1 slice))))
        (let* ((part (substring string pos (1+ pos)))
               ;; Native producers can provide a complete image row rather
               ;; than an existing slice.  Crop that glyph too; height 1.0
               ;; means its complete displayed height, without decoding it.
               (crop (list 'slice (+ (if slice (nth 1 slice) 0) (or offset 0))
                           (if slice (nth 2 slice) 0) width
                           (if slice (nth 4 slice) 1.0))))
          (put-text-property
           0 1 'display
           (cond ((eq image display) (list crop image))
                 (slice (mapcar (lambda (item) (if (eq item slice) crop item)) display))
                 (t (cons crop display)))
           part)
          part)
      (if (null (cl-loop for (key) on props by #'cddr
                         thereis (not (memq key '(display face)))))
          (ebox--space width (plist-get props 'face))
        (let ((space (copy-sequence (ebox--space width))))
          (unless (equal space "")
            (cl-loop for (key value) on props by #'cddr
                     unless (eq key 'display)
                     do (put-text-property 0 1 key value space)))
          space)))))

(defun ebox--cut-left (string x cut)
  "Return the part of STRING left of pixel X given its CUT at X."
  (pcase-let ((`(,pos ,px) cut))
    (if (< px x)
        (ebox--join (list (substring string 0 pos)
                          (ebox--unit-space (- x px) string pos)))
      (substring string 0 pos))))

(defun ebox--cut-right (string x cut)
  "Return the part of STRING right of pixel X given its CUT at X."
  (pcase-let ((`(,pos ,px ,next ,w) cut))
    (cond ((>= pos (length string)) "")
          (next (ebox--join (list (ebox--unit-space (- (+ px w) x) string pos
                                                    (- x px))
                                  (substring string next))))
          (t (substring string pos)))))

(defun ebox--split-at (string x)
  "Split composed STRING at pixel X; return (LEFT . RIGHT).
A unit straddling X is replaced by spaces of the two partial widths."
  (let ((cut (ebox--px-cut string x 0 0)))
    (cons (ebox--cut-left string x cut) (ebox--cut-right string x cut))))

(defun ebox--part-width (string)
  "Return the pixel width of composed part STRING."
  (or (gethash string ebox--part-widths)
      (puthash string (nth 1 (ebox--px-cut string most-positive-fixnum 0 0))
               ebox--part-widths)))

(defun ebox--sized-substring (string from to width)
  "Return STRING from FROM to TO, recording its WIDTH pixels."
  (let ((part (substring string from to)))
    (puthash part width ebox--part-widths)
    part))

(defun ebox--split-parts (parts x)
  "Split the composed strings PARTS at pixel X; return (LEFT . RIGHT).
Only a string straddling X is cut, into its whole units on each side and
spaces for the two partial widths of a unit straddling X; the others are
shared.  LEFT is padded with a space when PARTS end before X."
  (let ((px 0) (left nil) (rest parts) (done nil))
    (while (and rest (not done))
      (let* ((string (car rest)) (w (ebox--part-width string)))
        (cond ((>= px x) (setq done t))
              ((<= (+ px w) x) (push string left) (setq px (+ px w) rest (cdr rest)))
              (t
               (pcase-let* ((at (- x px))
                            (`(,pos ,upx ,next ,uw) (ebox--px-cut string at 0 0))
                            (len (length string))
                            (right (cdr rest)))
                 (when (> pos 0)
                   (push (ebox--sized-substring string 0 pos upx) left))
                 (when (< upx at)
                   (push (ebox--unit-space (- at upx) string pos) left))
                 (cond ((>= pos len))
                       (next
                        (when (< next len)
                          (push (ebox--sized-substring string next len (- w upx uw)) right))
                        (push (ebox--unit-space (- (+ upx uw) at) string pos (- at upx))
                              right))
                       (t (push (ebox--sized-substring string pos len (- w upx)) right)))
                 (setq rest right done t))))))
    (when (and (not done) (< px x))
      (push (ebox--space (- x px) nil) left))
    (cons (nreverse left) rest)))

(defun ebox--splice-parts (parts x segment width)
  "Replace pixels X..X+WIDTH of the composed strings PARTS with SEGMENT.
SEGMENT is a list of composed strings; return the new list."
  (let* ((head (ebox--split-parts parts x))
         (tail (ebox--split-parts (cdr head) width)))
    (nconc (car head) (append segment (cdr tail)))))

(defun ebox--raised-kids (host overlays)
  "Return HOST's relatively positioned flow children above some of OVERLAYS.
Such a child paints over every overlay with a lower `:z-index'."
  (let ((low (ebox-cs-z (ebox-node-cs (car overlays)))) raised)
    (ebox--do-kids (kid host)
      (let ((cs (ebox-node-cs kid)))
        (when (and (eq (ebox-cs-position cs) 'relative) (not (ebox-cs-abs cs))
                   (> (ebox-cs-z cs) low))
          (push kid raised))))
    raised))

(defun ebox--face-attribute (face key)
  "Return the value of KEY that FACE, a face plist or a list of them, sets.
The first plist that sets KEY wins, as in Emacs face merging."
  (cond ((keywordp (car-safe face)) (plist-get face key))
        ((consp face) (let (value) (while (and face (not value))
                                     (setq value (ebox--face-attribute (pop face) key)))
                           value))))

(defun ebox--face-background (face)
  "Return the background color that FACE, a face plist or a list of them, sets."
  (cond ((keywordp (car-safe face)) (plist-get face :background))
        ((consp face) (let (bg) (while (and face (not bg))
                                  (setq bg (ebox--face-background (pop face))))
                           bg))))

(defun ebox--over-backgrounds (segment under)
  "Return SEGMENT with UNDER's backgrounds behind its transparent pixels.
SEGMENT and UNDER are composed strings covering the same pixels; SEGMENT's
own backgrounds take precedence, and its shared strings are not modified."
  (let ((out nil))
    (dolist (string under)
      (let* ((split (ebox--split-parts segment (ebox--part-width string)))
             (bg (and (> (length string) 0)
                      (ebox--face-background (get-text-property 0 'face string)))))
        (setq segment (cdr split))
        (dolist (piece (car split))
          (if (not bg)
              (push piece out)
            (let ((piece (copy-sequence piece)))
              (add-face-text-property 0 (length piece) (list :background bg) t piece)
              (push piece out))))))
    (nreverse (nconc (nreverse segment) out))))

(defconst ebox--backdrop-filter-cache-limit 2048
  "Most dimmed faces a session remembers.")

(defvar ebox--backdrop-filter-faces (make-hash-table :test 'equal)
  "Dimmed faces keyed by (FACE FILTER).")

(defun ebox--backdrop-filter-default (attribute)
  "Return the frame default color for ATTRIBUTE, or nil when unspecified.
Batch and terminal frames report `unspecified-fg' and `unspecified-bg', so
these pixels keep their original colors there."
  (let* ((buffer (or ebox--measure-buffer (current-buffer)))
         (remap (buffer-local-value 'face-remapping-alist buffer))
         (value (or (ebox--face-attribute (cdr (assq 'default remap)) attribute)
                    (face-attribute 'default attribute ebox--measure-frame t))))
    (and (stringp value)
         (not (string-empty-p value))
         (not (member value '("unspecified-fg" "unspecified-bg")))
         value)))

(defun ebox--backdrop-filter-components (color)
  "Return COLOR's 16-bit RGB components, or nil when it has no value.
Hex colors are parsed here instead of through `color-values', which
approximates them to the terminal palette on a non-graphical frame."
  (cond
   ((and (stringp color)
         (string-match-p "\\`#[[:xdigit:]]+\\'" color))
    (let* ((digits (substring color 1))
           (width (/ (length digits) 3)))
      (when (and (memq width '(1 2 3 4))
                 (= (* width 3) (length digits)))
        (cl-loop for part from 0 below 3
                 for start = (* part width)
                 for value = (string-to-number (substring digits start (+ start width)) 16)
                 collect (round (* value (/ 65535.0 (1- (ash 1 (* 4 width))))))))))
   ((stringp color)
    (let ((rgb (color-values color)))
      (and (proper-list-p rgb) (= 3 (length rgb)) rgb)))
   (t nil)))

(defun ebox--backdrop-filter-color (color brightness)
  "Return COLOR with each channel multiplied by BRIGHTNESS, or nil.
An unparsable color keeps the pixel unchanged; brightness 1 keeps the
original color string so an identity filter does not restyle a face."
  (if (= brightness 1)
      color
    (when-let* ((rgb (ebox--backdrop-filter-components color)))
      (apply #'format "#%04X%04X%04X"
             (mapcar (lambda (value)
                       (min 65535 (round (* value brightness))))
                     rgb)))))

(defun ebox--backdrop-filter-plain-face-p (face)
  "Return non-nil for nil, a face plist or nested lists of face plists."
  (or (null face) (keywordp (car-safe face))
      (and (consp face) (cl-every #'ebox--backdrop-filter-plain-face-p face))))

(defun ebox--backdrop-filter-plist (face)
  "Flatten Ebox FACE, preserving the first value of each attribute.
Inherited image/icon faces can contain nested lists of face plists."
  (cond
   ((null face) nil)
   ((keywordp (car-safe face)) (copy-sequence face))
   ((consp face)
    (let (plist)
      (dolist (part face)
        (cl-loop for (key value) on (ebox--backdrop-filter-plist part) by #'cddr
                 unless (plist-member plist key)
                 do (setq plist (plist-put plist key value))))
      plist))
   (t nil)))

(defun ebox--backdrop-filter-face (face filter)
  "Return FACE with foreground and background dimmed by FILTER.
A face that is not an Ebox-composed plist, such as a symbol or a named face
list, is returned unchanged.  Missing colors fall back to the frame default,
so a face with no explicit color still dims on a graphical frame."
  (if (not (ebox--backdrop-filter-plain-face-p face)) face
    (let* ((brightness (cadr filter))
           (foreground (or (ebox--face-attribute face :foreground)
                           (ebox--backdrop-filter-default :foreground)))
           (background (or (ebox--face-attribute face :background)
                           (ebox--backdrop-filter-default :background)))
           (key (list face filter foreground background))
           (cached (gethash key ebox--backdrop-filter-faces)))
      (or cached
          (let* ((plist (ebox--backdrop-filter-plist face))
                 (dimmed (or (and foreground
                                  (ebox--backdrop-filter-color foreground brightness))
                             foreground))
                 (behind (or (and background
                                  (ebox--backdrop-filter-color background brightness))
                             background)))
            (if (and (equal dimmed foreground) (equal behind background))
                (setq plist face)
              (when dimmed (setq plist (plist-put plist :foreground dimmed)))
              (when behind (setq plist (plist-put plist :background behind))))
            (when (> (hash-table-count ebox--backdrop-filter-faces)
                     ebox--backdrop-filter-cache-limit)
              (clrhash ebox--backdrop-filter-faces))
            (puthash key plist ebox--backdrop-filter-faces)
            plist)))))

(defun ebox--backdrop-filter-owned-string (string filter)
  "Dim the text and image runs of owned STRING by FILTER and return it.
The caller must copy shared source parts before calling this function.
Immutable image composites remain shared.  Paint performs no source I/O."
  (unless (= (cadr filter) 1)
    (let ((length (length string))
          (position 0))
      (while (< position length)
        (let* ((next (min (next-single-property-change position 'face string length)
                          (next-single-property-change position 'display string length)))
               (face (get-text-property position 'face string))
               (dimmed (ebox--backdrop-filter-face face filter))
               (display (get-text-property position 'display string))
               (image (ebox-image--display-image display)))
          (when dimmed
            (put-text-property position next 'face dimmed string))
          (when image
            (let* ((own-bg (plist-get (cdr image) :background))
                   (foreground (or (plist-get (cdr image) :foreground)
                                   (ebox--face-attribute face :foreground)
                                   (ebox--backdrop-filter-default :foreground)))
                   (background (if own-bg
                                   (ebox--backdrop-filter-color own-bg (cadr filter))
                                 (ebox--face-attribute dimmed :background)))
                   (variant (ebox-image--brightness-display
                             display (cadr filter) foreground background)))
              (put-text-property position next 'display variant string)))
          (setq position next)))))
  string)

(defun ebox--backdrop-filter-blank-at-p (string position)
  "Return non-nil when the cell at POSITION of STRING paints no content."
  (let ((display (get-text-property position 'display string)))
    (and (eq (aref string position) ?\s)
         (or (null display) (eq (car-safe display) 'space)))))

(defun ebox--backdrop-filter-blank-p (string)
  "Return non-nil when STRING paints only blank cells."
  (let ((blank t)
        (position 0)
        (length (length string)))
    (while (and blank (< position length))
      (unless (ebox--backdrop-filter-blank-at-p string position)
        (setq blank nil))
      (cl-incf position))
    blank))

(defun ebox--backdrop-input-at (string position)
  "Return the native input properties at POSITION in STRING."
  (cl-loop for property in '(ebox-node keymap help-echo pointer mouse-face)
           append (list property (get-text-property position property string))))

(defun ebox--backdrop-uniform-blank (parts)
  "Return a blank cell of PARTS when they have one uniform input owner.
Return nil for painted content or differing native input properties."
  (let (cell props (uniform t))
    (dolist (string parts)
      (unless (ebox--backdrop-filter-blank-p string) (setq uniform nil))
      (let ((position 0) (length (length string)))
        (while (and uniform (< position length))
          (let ((input (ebox--backdrop-input-at string position)))
            (if cell
                (unless (cl-loop for (key value) on input by #'cddr
                                 always (if (memq key '(ebox-node keymap))
                                            (eq value (plist-get props key))
                                          (equal value (plist-get props key))))
                  (setq uniform nil))
              (setq cell (substring string position (1+ position)) props input)))
          (setq position (next-property-change position string length)))))
    (and uniform cell)))

(defun ebox--backdrop-text-boundary (parts x end)
  "Keep pixel X unless it cuts an unsliceable display unit in PARTS.
For such a unit return its start, or its end when END is non-nil.  Native
images and display spaces remain pixel-sliceable.  Text hit ownership has
Emacs's whole-glyph granularity, but an identity filter must not erase it."
  (let ((px 0) (rest parts) (boundary x))
    (while (and rest (< px x))
      (let* ((string (pop rest)) (width (ebox--part-width string)))
        (if (< x (+ px width))
            (progn
              (pcase-let ((`(,pos ,offset ,next ,unit-width)
                           (ebox--px-cut string (- x px) 0 0)))
                (let ((display (and next (get-text-property pos 'display string))))
                  (when (and next
                             (not (ebox--fixed-space-width display))
                             (not (ebox-image--display-image display)))
                    (setq boundary (+ px offset (if end unit-width 0))))))
              (setq rest nil))
          (setq px (+ px width)))))
    boundary))

(defun ebox--backdrop-cover-parts (parts cover filter)
  "Dim PARTS by FILTER and replace their native input properties with COVER's.
A filtered overlay borrows paint, never the covered text's hit owner,
keymap, help or hover.  Preserve COVER's property runs so even blank child
controls keep their own input identity.  Cached source strings are not mutated."
  (let ((position 0) (length (length cover)) (rest parts) out)
    (while (< position length)
      (let* ((next (next-property-change position cover length))
             (width (ebox--part-width (substring cover position next)))
             (split (ebox--split-parts rest width))
             (props (ebox--backdrop-input-at cover position)))
        (dolist (part (car split))
          (let ((copy (copy-sequence part)))
            (ebox--backdrop-filter-owned-string copy filter)
            (add-text-properties 0 (length copy) props copy)
            (push copy out)))
        (setq position next rest (cdr split))))
    (nreverse out)))

(defun ebox--backdrop-filter-merge-part (string behind filter)
  "Return STRING with blank cells replaced by BEHIND pixels dimmed by FILTER.
BEHIND is an unfiltered parts list covering at least STRING's width.  Return
(MERGED . REST): MERGED is a list of strings covering STRING's width and
REST is the unused tail of BEHIND."
  (cond
   ((zerop (length string)) (cons (list string) behind))
   ((ebox--backdrop-filter-blank-p string)
    (let ((split (ebox--split-parts behind (ebox--part-width string))))
      (cons (if (car split)
                (ebox--backdrop-cover-parts (car split) string filter)
              (list string))
            (cdr split))))
   ((not (string-match-p " " string))
    (let ((split (ebox--split-parts behind (ebox--part-width string))))
      (cons (list string) (cdr split))))
   (t
    (let ((out nil)
          (rest behind)
          (position 0)
          (length (length string)))
      (while (< position length)
        (if (ebox--backdrop-filter-blank-at-p string position)
            (let* ((width (ebox--part-width
                           (substring string position (1+ position))))
                   (split (ebox--split-parts rest width)))
              (setq rest (cdr split))
              (dolist (piece (ebox--backdrop-cover-parts
                              (car split) (substring string position (1+ position)) filter))
                (push piece out))
              (cl-incf position))
          (let ((start position))
            (cl-incf position)
            (while (and (< position length)
                        (not (ebox--backdrop-filter-blank-at-p string position)))
              (cl-incf position))
            (let* ((run (substring string start position))
                   (split (ebox--split-parts rest (ebox--part-width run))))
              (setq rest (cdr split))
              (push run out)))))  
      (cons (nreverse out) rest)))))

(defun ebox--backdrop-filter-under (segment under filter)
  "Return SEGMENT showing UNDER, dimmed by FILTER, through its blank cells.
SEGMENT and UNDER cover the same pixels.  A blank cell of SEGMENT keeps the
dimmed pixel behind it, and a cell with its own content hides it."
  (let ((behind under)
        (out nil))
    (dolist (string segment)
      (pcase-let ((`(,merged . ,rest)
                   (ebox--backdrop-filter-merge-part string behind filter)))
        (setq behind rest)
        (dolist (piece merged) (push piece out))))
    (nreverse out)))

(defun ebox--splice-node (parts node x y bi bw &optional transparent)
  "Splice NODE's margin-box line at border-box line BI into PARTS.
NODE's margin box starts at X and Y in its host's border box of BW pixels.
TRANSPARENT non-nil keeps the backgrounds of PARTS behind NODE's pixels
that have none.  A `:backdrop-filter' on NODE keeps the cells it covers and
dims their colors instead of replacing them."
  (let ((row (- bi y)))
    (if (or (< row 0) (>= row (ebox-node-h node)) (ebox--hidden-p node))
        parts
      (let* ((skip (max 0 (- x)))
             (x (max 0 x))
             (w (min (- (ebox-node-w node) skip) (max 0 (- bw x)))))
        (if (<= w 0)
            parts
          (let ((segment (ebox--join-parts (ebox--node-parts node row))))
            (when (> skip 0)
              (setq segment (cdr (ebox--split-parts segment skip))))
            (when (< w (- (ebox-node-w node) skip))
              (setq segment (car (ebox--split-parts segment w))))
            (when transparent
              (setq segment
                    (ebox--over-backgrounds
                     segment (car (ebox--split-parts (cdr (ebox--split-parts parts x)) w)))))
            (when-let* ((filter (ebox--cv (ebox-node-cs node) 'ebox/backdrop-filter)))
              ;; A transparent, uniform hit surface does not erase partial
              ;; text glyphs.  Expand only unsliceable text units to their
              ;; native cell boundaries; image/space slices remain exact.
              (when-let* (((= (cadr filter) 1))
                          (cell (ebox--backdrop-uniform-blank segment)))
                (let ((start (ebox--backdrop-text-boundary parts x nil))
                      (end (ebox--backdrop-text-boundary parts (+ x w) t)))
                  (setq x start w (- end start)
                        segment (list (ebox--unit-space w cell 0)))))
              (setq segment
                    (ebox--backdrop-filter-under
                     segment
                     (car (ebox--split-parts (cdr (ebox--split-parts parts x)) w))
                     filter)))
            (ebox--splice-parts parts x segment w)))))))

(defun ebox--apply-overlays (host geo bi parts)
  "Splice HOST's overlays intersecting border-box line BI into PARTS.
PARTS and the result are flat lists of composed strings, so the line is
concatenated once after every overlay is placed.  Overlays paint in
`:z-index' order; a relatively positioned flow child of HOST paints again
above the overlays whose `:z-index' is lower than its own.  Border
decorations are applied afterwards, so they continue across overlays."
  (let ((overlays (ebox--live-overlays host))
        (bw (ebox-geo-bw geo)))
    (when overlays
      (setq overlays
            (sort (copy-sequence overlays)
                  (lambda (a b) (< (ebox-cs-z (ebox-node-cs a)) (ebox-cs-z (ebox-node-cs b))))))
      (let* ((raised (ebox--raised-kids host overlays))
             (top (+ (ebox-geo-pt geo) (- (ebox-geo-scroll geo))))
             (left (+ (ebox-geo-bl geo) (ebox-geo-pl geo)))
             (shown (and raised (>= bi (ebox-geo-pt geo))
                         (< bi (+ (ebox-geo-pt geo) (ebox-geo-vh geo))))))
        (when shown
          (setq raised (sort raised (lambda (a b) (< (ebox-cs-z (ebox-node-cs a))
                                                     (ebox-cs-z (ebox-node-cs b)))))))
        (dolist (node overlays)
          (when shown
            (let ((z (ebox-cs-z (ebox-node-cs node))))
              (while (and raised (< (ebox-cs-z (ebox-node-cs (car raised))) z))
                (let ((kid (pop raised)))
                  (setq parts (ebox--splice-node parts kid (+ left (ebox--item-x kid))
                                                 (+ top (ebox--item-y kid)) bi bw t))))))
          (when (ebox-node-placed node)
            (setq parts (ebox--splice-node parts node (ebox-node-x node) (ebox-node-y node)
                                           bi bw))))
        (when shown
          (dolist (kid raised)
            (setq parts (ebox--splice-node parts kid (+ left (ebox--item-x kid))
                                           (+ top (ebox--item-y kid)) bi bw t))))))
    parts))

(defun ebox--root-line (root i)
  "Return line I of ROOT as written to a buffer."
  (ebox--node-line root i))

(defun ebox--root-parts (root i)
  "Return the strings that line I of ROOT writes to a buffer, in order.
The line starts with its strut when its glyphs are shorter than the line
height.  A leading strut is inside the visible area, so the truncation
boundary cannot drop it the way it drops a trailing one."
  (let ((parts (ebox--join-parts (ebox--node-parts root i))))
    (if-let* ((strut (ebox--row-strut))
              (head (car parts)))
        (cons (ebox--row-strut-part strut head) parts)
      parts)))

(defvar ebox--strut-part-cache nil
  "Last (STRUT HEAD-PROPS . PART) built by `ebox--row-strut-part'.")

(defun ebox--row-strut-part (strut head)
  "Return STRUT carrying HEAD's first cell's text properties.
The strut starts a row, so that cell keeps the line's first column: its face,
hover, help, pointer and key bindings.  HEAD's own display property is not
copied, so the strut keeps its zero-width height display."
  (let ((props (text-properties-at 0 head)))
    (if (and ebox--strut-part-cache
             (eq (car ebox--strut-part-cache) strut)
             (equal (cadr ebox--strut-part-cache) props))
        (cddr ebox--strut-part-cache)
      (let ((part (substring strut 0))
            (rest props))
        (while rest
          (unless (eq (car rest) 'display)
            (put-text-property 0 (length part) (car rest) (cadr rest) part))
          (setq rest (cddr rest)))
        (setq ebox--strut-part-cache (cons strut (cons props part)))
        part))))

(defun ebox--node-lines (node from to)
  "Return NODE's margin-box lines FROM (inclusive) TO (exclusive)."
  (let (lines)
    (cl-loop for i from from below to
             do (push (ebox--node-line node i) lines))
    (nreverse lines)))

;;;; Damage to root lines

(defun ebox--item-top-in-root (item)
  "Return ITEM's first line in root margin-box coordinates."
  (cond
   ((ebox-para-p item)
    (let* ((owner (ebox-para-owner item))
           (geo (ebox-node-layout owner)))
      (+ (ebox--item-y item) (ebox-geo-mt geo) (ebox-geo-pt geo) (- (ebox-geo-scroll geo))
         (ebox--item-top-in-root owner))))
   ((null (ebox-node-parent item)) 0)
   ((ebox--abs-p item)
    (let ((host (ebox-node-host item)))
      (+ (ebox-node-y item) (ebox-geo-mt (ebox-node-layout host))
         (ebox--item-top-in-root host))))
   (t
    (let* ((owner (ebox-node-parent item))
           (geo (ebox-node-layout owner)))
      (+ (ebox--item-y item) (ebox-geo-mt geo) (ebox-geo-pt geo) (- (ebox-geo-scroll geo))
         (ebox--item-top-in-root owner))))))

(defun ebox--clip-parent (node)
  "Return the node whose content box positions NODE: its host or parent."
  (if (and (ebox-node-cs node) (ebox--abs-p node))
      (ebox-node-host node)
    (ebox-node-parent node)))

(defun ebox--clip-same-height (ranges top end)
  "Return same-height RANGES clipped to visible span [TOP, END)."
  (let (out)
    (dolist (r ranges (nreverse out))
      (let* ((from (max (car r) top))
             (to (min (+ (car r) (nth 2 r)) end)))
        (when (< from to)
          (let ((n (- to from)))
            (push (list from n n nil) out)))))))

(defun ebox--clip-range (range node &optional child)
  "Restrict root-line RANGE (START OLD NEW WHOLE) through NODE and its ancestors.
NODE is the innermost node whose content box holds RANGE; CHILD, when
non-nil, is the immediate child of NODE that RANGE ascended from.  Every
clipping node keeps only its visible content lines.  A height-changing
range (OLD /= NEW) cannot shift root buffer lines across a non-stack
container (whose siblings may share lines) or across a node hosting
placed overlays, so it becomes a same-height rewrite before any enclosing
clip applies; pure insertions or deletions at a bordered or rounded
ancestor's first or last border-box line emit an accompanying 1-line
same-height border repaint instead of mutating the pure edit, so adjacent
edits merge without spurious overlap.  Return a list of ranges, or nil when
no shown line changes."
  (pcase-let ((`(,start ,old ,new ,whole) range)
              (extras nil))
    (while (and node (or start extras))
      (let ((geo (ebox-node-layout node)))
        (when geo
          (when (and start (/= old new))
            (let ((non-stack (not (ebox-geo-stack geo)))
                  (overlays (cl-some #'ebox-node-placed (ebox-node-overlays node))))
              (when (or non-stack overlays)
                (let* ((box-top (if (and non-stack child)
                                    (ebox--item-top-in-root child)
                                  (+ (ebox--item-top-in-root node)
                                     (ebox-geo-mt geo) (ebox-geo-pt geo))))
                       (box-end (if (and non-stack child)
                                    (+ box-top (ebox-node-h child))
                                  (+ box-top (ebox-geo-vh geo))))
                       (from (max start box-top))
                       (to box-end))
                  (if (< from to)
                      (setq start from old (- to from) new (- to from) whole nil)
                    (setq start nil))))))
          (when (or (> (ebox-geo-ch geo) (ebox-geo-vh geo))
                    (> (ebox-geo-scroll geo) 0))
            (let* ((top (+ (ebox--item-top-in-root node) (ebox-geo-mt geo) (ebox-geo-pt geo)))
                   (end (+ top (ebox-geo-vh geo))))
              (when start
                (let ((from (max start top))
                      (to (if (= old new) (min (+ start new) end) end)))
                  (if (< from to)
                      (setq start from old (- to from) new (- to from) whole nil)
                    (setq start nil))))
              (when extras
                (setq extras (ebox--clip-same-height extras top end)))))
          (when (and start (/= old new) (or (zerop old) (zerop new)))
            (let* ((cs (ebox-node-cs node))
                   (bh (ebox-geo-bh geo))
                   (rounded (> (or (ebox--px (ebox--cv cs 'ebox/border-radius) cs nil) 0) 1))
                   (btop (+ (ebox--item-top-in-root node) (ebox-geo-mt geo)))
                   (bend (+ btop bh)))
              (when (> bh 0)
                (when (and (or (ebox-cs-btop cs) rounded)
                           (<= start btop) (< (+ start new) bend))
                  (push (list (+ start new) 1 1 nil) extras))
                (when (and (or (ebox-cs-bbot cs) rounded)
                           (>= (+ start new) bend) (> start btop))
                  (push (list (1- start) 1 1 nil) extras)))))))
      (setq child node
            node (ebox--clip-parent node)))
    (if start
        (cons (list start old new whole) extras)
      extras)))

(defun ebox--damage-range (damage)
  "Return a list of (START OLD NEW WHOLE) root ranges for DAMAGE, or nil.
WHOLE is non-nil when the range covers a whole node's margin box.  Ranges
inside scrolling or clipped containers keep only their shown lines; nil
means the damage is not shown."
  (pcase-let ((`(,item ,from ,old ,new) damage))
    (cond
     ((and (consp item) (eq (car item) 'lines))
      (let* ((node (nth 1 item))
             (geo (ebox-node-layout node))
             (border (eq (nth 3 item) 'border))
             (start (if border
                        (nth 2 item)
                      (+ (nth 2 item) (ebox-geo-mt geo) (ebox-geo-pt geo)
                         (- (ebox-geo-scroll geo))))))
        (ebox--clip-range (list (+ (ebox--item-top-in-root node) start from) old new nil)
                          (if border (ebox--clip-parent node) node)
                          (and border node))))
     ((ebox-para-p item)
      (ebox--clip-range (list (+ (ebox--item-top-in-root item) from) old new nil)
                        (ebox-para-owner item)))
     (t
      (ebox--clip-range (list (+ (ebox--item-top-in-root item) from) old new (= from 0))
                        (ebox--clip-parent item)
                        item)))))

(defun ebox--damage-live-p (damage root)
  "Return non-nil when DAMAGE's owner is laid out under ROOT."
  (let ((node (ebox--damage-owner (car damage))))
    (and (ebox-node-layout node) (eq (ebox-node-root node) root))))

(defun ebox--root-edits (root damages &optional old-lines)
  "Convert DAMAGES under ROOT to sorted, merged (START OLD NEW) edits.
START is in post-layout lines; applying edits in order transforms the old
lines into the new ones.  OLD-LINES is the line count the buffer holds now,
which the edits must turn into ROOT's own height.  Return the symbol `full'
when ranges overlap in a way that cannot be expressed as ordered line
replacements, or when the reported damages do not account for every line the
new layout has: a page written from an edit list that does not add up keeps
rows the layout no longer has, and the buffer would then disagree with what
the next pass believes it painted."
  (let ((height (ebox-node-h root))
        ranges merged)
    (dolist (damage damages)
      (when (ebox--damage-live-p damage root)
        (dolist (r (ebox--damage-range damage))
          ;; Overlays may extend past the root; only its lines exist.
          (cond ((null r))
                ((/= (nth 1 r) (nth 2 r)) (push r ranges))
                ((>= (car r) height))
                ((> (+ (car r) (nth 2 r)) height)
                 (let ((n (- height (car r))))
                   (push (list (car r) n n (nth 3 r)) ranges)))
                (t (push r ranges))))))
    (setq ranges (nreverse ranges))
    (when (cdr ranges)
      (setq ranges
            (sort ranges
                  (lambda (a b)
                    (or (< (car a) (car b))
                        (and (= (car a) (car b))
                             ;; Put pure deletions (new = 0) before positive
                             ;; ranges at the same start so touching merge
                             ;; folds them instead of dropping them as nested;
                             ;; among positive ranges, wider comes first so
                             ;; containers precede nested same-height damage.
                             (or (and (zerop (nth 2 a)) (> (nth 2 b) 0))
                                 (and (> (nth 2 a) 0) (> (nth 2 b) 0)
                                      (> (nth 2 a) (nth 2 b))))))))))
    (catch 'full
      ;; Every range is a fresh list, so merging edits it in place.
      (dolist (range ranges)
        (let* ((prev (car merged))
               (prev-end (and prev (+ (car prev) (nth 2 prev))))
               (end (+ (car range) (nth 2 range))))
          (cond
           ((or (null prev) (> (car range) prev-end))
            (push range merged))
           ((= (car range) prev-end)
            ;; Touching ranges in post-layout order combine into one contiguous
            ;; replacement covering both old and new spans.
            (setf (nth 1 prev) (+ (nth 1 prev) (nth 1 range))
                  (nth 2 prev) (+ (nth 2 prev) (nth 2 range))
                  (nth 3 prev) nil))
           ((and (<= end prev-end)
                 (or (= (nth 1 range) (nth 2 range))
                     (and (nth 3 prev) (/= (nth 1 prev) (nth 2 prev)))))
            ;; Nested in lines the previous edit already rewrites.
            nil)
           ((or (= (nth 1 prev) (nth 2 prev)) (= (nth 1 range) (nth 2 range)))
            (let ((delta (+ (- (nth 2 prev) (nth 1 prev)) (- (nth 2 range) (nth 1 range))))
                  (span (- (max prev-end end) (car prev))))
              (setf (nth 1 prev) (- span delta)
                    (nth 2 prev) span
                    (nth 3 prev) nil)))
           (t (throw 'full 'full)))))
      (dolist (edit merged)
        (setcdr (nthcdr 2 edit) nil))
      ;; Ordered post-layout edits apply sequentially top to bottom: each edit
      ;; shifts later lines by its net growth so the next edit's post-layout
      ;; start lands on its exact old lines.  Verify every edit stays in bounds
      ;; and the total delta accounts for ROOT's new height.
      (let ((edits (nreverse merged))
            (delta 0)
            (valid t))
        (dolist (edit edits)
          (let ((start (car edit))
                (old (nth 1 edit))
                (new (nth 2 edit)))
            (when (or (< start 0) (< old 0) (< new 0)
                      (> (+ start new) height)
                      (and old-lines (> (+ start old) (+ old-lines delta))))
              (setq valid nil))
            (setq delta (+ delta (- new old)))))
        (if (or (not valid)
                (and old-lines (/= (+ old-lines delta) height)))
            'full
          edits)))))

(provide 'ebox-layout)

;;; ebox-layout.el ends here
