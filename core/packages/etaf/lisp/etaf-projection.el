;;; etaf-projection.el --- Read painted cells back as source ranges  -*- lexical-binding: t; -*-

;;; Commentary:

;; A preview paints a document that lives elsewhere: markdown source in a
;; buffer, an org subtree, a database row.  Editing it in place needs the way
;; back from painted cells to that source.
;;
;; Only some applications have such a source, so this is a plain query rather
;; than a rendering mode.  Nothing runs unless an application asks:
;;
;;   (etaf-projection runtime '((intro . (0 . 42))
;;                              (body  . (43 . 91))))
;;
;; Each entry names a Host reference and the source range its painted cells
;; stand for.  References, not nodes, are the identity a repaint keeps.
;;
;; The result is plain data computed from the current paint, so it can never
;; describe an older frame.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-runtime)

(defun etaf--projection-text-bounds (node)
  "Return the painted bounds of NODE's text leaves, or nil without any.
A Host around its text also owns padding, borders and a trailing line break;
those cells carry no source character, so using the outer box would spread the
source range over cells that do not stand for it."
  (let ((beg nil) (end nil))
    (ebox-node-walk node
                    (lambda (child)
                      (when (eq (ebox-node-tag child) 'text)
                        (let ((bounds (ebox-node-bounds child t)))
                          (when bounds
                            (setq beg (if beg (min beg (car bounds)) (car bounds)))
                            (setq end (if end (max end (cdr bounds)) (cdr bounds))))))))
    (and beg (cons beg end))))

(defun etaf--projection-cells (buffer start end)
  "Return the painted (BEG . END) cells in BUFFER between START and END.
Each cell is one line without its break, because a break owns no character a
caret can stand on."
  (let ((cells nil))
    (with-current-buffer buffer
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (let* ((beg (point))
                 (line-end (min (line-end-position) end)))
            (when (> line-end beg)
              (push (cons beg line-end) cells))
            (goto-char (min end (1+ (line-end-position))))))))
    (nreverse cells)))

(defun etaf--projection-runs (buffer bounds source)
  "Return one run per painted line of BOUNDS, cut from SOURCE.
A Host whose text wraps spreads its source range over the lines it painted in
proportion to their cells, so a wrapped paragraph stays editable in place
without asking authors to pre-split it."
  (let* ((cells (etaf--projection-cells buffer (car bounds) (cdr bounds)))
         (total (cl-loop for cell in cells sum (- (cdr cell) (car cell))))
         (span (- (cdr source) (car source))))
    (when (> total 0)
      (let ((consumed 0) (runs nil))
        (dolist (cell cells)
          (let* ((width (- (cdr cell) (car cell)))
                 (beg (+ (car source) (/ (* consumed span) total)))
                 (end (+ (car source) (/ (* (+ consumed width) span) total))))
            (push (list (car cell) (cdr cell) beg end) runs)
            (setq consumed (+ consumed width))))
        (nreverse runs)))))

(defun etaf--projection-aligned-runs (buffer node source source-start source-end)
  "Return runs for NODE's text leaves, aligned to the source they came from.
Each leaf paints a string, and the source holds that same string somewhere
between SOURCE-START and SOURCE-END; searching for it in paint order locates it
exactly.  This is what makes the mapping general: a heading that dropped its
hashes, a bullet that became a round dot, a table cell, a wrapped paragraph all
resolve the same way, with no rule per block kind."
  (let ((cursor source-start)
        (runs nil))
    (with-current-buffer buffer
      (ebox-node-walk
       node
       (lambda (child)
         (when (eq (ebox-node-tag child) 'text)
           (let ((bounds (ebox-node-bounds child t)))
             (when (and bounds (< (car bounds) (cdr bounds)))
               (let ((painted (buffer-substring-no-properties
                               (car bounds) (cdr bounds))))
                 ;; A cell is painted padded to its column, and the padding is
                 ;; not in the source: align the text it holds, not the spaces
                 ;; that fill the column.
                 (let* ((text (string-trim painted))
                        (lead (- (length painted)
                                 (length (string-trim-left painted)))))
                   (unless (string-empty-p text)
                     ;; A literal search is only what it costs to compare; a
                     ;; regexp built per leaf is what made a page of 193 blocks
                     ;; take 50 ms to map.
                     (let ((found (string-search text source cursor)))
                       (when (and found (<= (+ found (length text)) source-end))
                         (push (list (+ (car bounds) lead)
                                     (+ (car bounds) lead (length text))
                                     found
                                     (+ found (length text)))
                               runs)
                         (setq cursor (+ found (length text))))))))))))))
    (nreverse runs)))

(defun etaf--projection-trim (runs)
  "Return RUNS ordered by painted position with overlapping tails trimmed.
An inner Host wins the cells it shares with the Host around it."
  (let ((sorted (sort runs (lambda (a b) (< (car a) (car b)))))
        (result nil)
        (reached 0))
    (dolist (run sorted)
      (when (> (nth 1 run) reached)
        (when (< (car run) reached)
          (setcar run reached))
        (push run result)
        (setq reached (nth 1 run))))
    (vconcat (nreverse result))))

;;;###autoload
(defun etaf--projection-declared-runs (node)
  "Return the runs NODE and its descendants declare through `:source'.
A renderer that writes a text node knows which part of the document that text
came from; declaring it here is what lets a projection read the mapping instead
of inferring it from block kinds and text lengths."
  (let ((runs nil))
    (ebox-node-walk
     node
     (lambda (child)
       (let ((declared (plist-get (ebox-node-props child) :source)))
         (when (and (consp declared)
                    (integerp (car declared)) (integerp (cdr declared))
                    (< (car declared) (cdr declared)))
           (let ((bounds (and (eq (ebox-node-tag child) 'text)
                              (ebox-node-bounds child t))))
             (when (and bounds (< (car bounds) (cdr bounds)))
               (push (list (car bounds) (cdr bounds)
                           (car declared) (cdr declared))
                     runs)))))))
    (nreverse runs)))

(defun etaf-projection (runtime entries &optional source)
  "Return the projection of RUNTIME described by ENTRIES.
ENTRIES is an alist of (REF . (SOURCE-START . SOURCE-END)), one per Host whose
painted cells stand for a source range.  Return a vector of runs
\(DISPLAY-BEG DISPLAY-END SOURCE-BEG SOURCE-END) ordered by display position;
entries that paint nothing, or name a range of zero length, are skipped."
  (let ((buffer (etaf-runtime-buffer runtime))
        (runs nil))
    (dolist (entry entries)
      (let* ((range (cdr entry))
             (node (etaf-runtime-host-node runtime (car entry)))
             ;; A renderer that declared its own source ranges is exact; only a
             ;; Host that declared nothing falls back to spreading its range
             ;; over its painted text.
             (declared (and node (etaf--projection-declared-runs node)))
         (aligned (and (not declared) source node
                       (integerp (car range)) (integerp (cdr range))
                       (< (car range) (cdr range) (length source))
                       (etaf--projection-aligned-runs
                        buffer node source (car range) (cdr range))))
             (bounds (and node
                          (or (etaf--projection-text-bounds node)
                              (ebox-node-bounds node t)))))
        (cond
         (declared (setq runs (nconc declared runs)))
         (aligned (setq runs (nconc aligned runs)))
         ((and bounds (integerp (car range)) (integerp (cdr range))
               (< (car range) (cdr range)))
          (setq runs (nconc (etaf--projection-runs buffer bounds range) runs))))))
    (etaf--projection-trim runs)))

(defun etaf--projection-find (projection start-slot end-slot position)
  "Return the run of PROJECTION whose START-SLOT..END-SLOT holds POSITION."
  (let ((low 0) (high (1- (length projection))) (found nil))
    (while (<= low high)
      (let* ((middle (/ (+ low high) 2))
             (run (aref projection middle)))
        (cond ((< position (nth start-slot run)) (setq high (1- middle)))
              ((>= position (nth end-slot run)) (setq low (1+ middle)))
              (t (setq found run low (1+ high))))))
    found))

;;;###autoload
(defun etaf-projection-source-offset (projection position)
  "Return the source offset that painted POSITION stands for.
A position just after a run is the end of that run's source, which is where a
caret sits when it is on the line's break.  Any other position outside a run
reports the nearest run's edge, and a position before the first run names the
start of the source."
  (let ((run (etaf--projection-find projection 0 1 position)))
    (cond
     (run (min (nth 3 run) (+ (nth 2 run) (- position (car run)))))
     (t
      (let ((edge nil) (nearest nil) (first nil) (next nil))
        (dotimes (index (length projection))
          (let ((candidate (aref projection index)))
            ;; The cell after a run belongs to it: that is the line's break,
            ;; where the caret stands at the end of the text it paints.
            (when (= position (nth 1 candidate))
              (setq edge candidate))
            (when (and (<= (car candidate) position)
                       (or (null nearest) (> (car candidate) (car nearest))))
              (setq nearest candidate))
            (when (and (> (car candidate) position)
                       (or (null next) (< (car candidate) (car next))))
              (setq next candidate))
            (when (or (null first) (< (car candidate) (car first)))
              (setq first candidate))))
        (cond
         ;; A position naming a run's end is that run's last character.
         (edge (nth 3 edge))
         ;; A position in the gap between two runs sits on the blank line that
         ;; separates them, so it names the start of the block that follows:
         ;; typing there begins that block instead of appending to the one above.
         ((and next (> (nth 2 next) (if nearest (nth 3 nearest) 0)))
          (nth 2 next))
         (nearest (nth 3 nearest))
         (first (nth 2 first))))))))

;;;###autoload
(defun etaf-projection-position (projection offset)
  "Return the painted position where source OFFSET lives, or nil.
An offset inside a run maps to its cell; an offset the paint skipped, such as
a marker the render folded away, maps to the start of the next run."
  (let ((run (etaf--projection-find projection 2 3 offset)))
    (if run
        (min (nth 1 run) (+ (car run) (- offset (nth 2 run))))
      (let ((next nil) (edge nil) (previous nil))
        (dotimes (index (length projection))
          (let ((candidate (aref projection index)))
            ;; An offset exactly at a run's end is the cell after its text,
            ;; which is where the caret stands at the end of that line.  It
            ;; belongs to that run, not to the one that starts below.
            (when (= offset (nth 3 candidate))
              (setq edge candidate))
            (when (and (>= (nth 2 candidate) offset)
                       (or (null next) (< (nth 2 candidate) (nth 2 next))))
              (setq next candidate))
            (when (<= (nth 3 candidate) offset)
              (setq previous candidate))))
        (cond (edge (nth 1 edge))
              ;; An offset one past a run is that line's break: the caret at the
              ;; end of the text sits there, not at the start of the block below.
              ((and previous (= offset (1+ (nth 3 previous))))
               (nth 1 previous))
              (next (car next))
              ;; An offset past the end of the last run names the end of the
              ;; source, so its caret sits after the final painted cell.
              (previous (nth 1 previous)))))))

(provide 'etaf-projection)

;;; etaf-projection.el ends here
