;;; ebox-flex.el --- Flex and grid container layout -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Flex and grid containers position their children inside their own content
;; box.  Main and cross sizes follow CSS: flex items grow and shrink from their
;; base sizes with min/max freezing, grid tracks resolve fixed, intrinsic and
;; fractional sizes.  Horizontal sizes are pixels and vertical sizes lines.
;; Both containers relayout their children completely when any child changes;
;; children cache their own layout, so unchanged items return immediately.

;;; Code:

(require 'cl-lib)
(require 'ebox-size)
(require 'ebox-node)
(require 'ebox-layout)

;;;; Shared helpers

(defun ebox--flow-kids (node)
  "Return NODE's in-flow children sorted by their `order'."
  (let (kids ordered)
    (ebox--do-kids (child node)
      (unless (ebox--abs-p child)
        (push child kids)
        (unless (memq (ebox--cv (ebox-node-cs child) 'ebox/order) '(nil 0))
          (setq ordered t))))
    (setq kids (nreverse kids))
    (if ordered
        (cl-stable-sort kids #'< :key (lambda (kid)
                                       (or (ebox--cv (ebox-node-cs kid) 'ebox/order) 0)))
      kids)))

(defun ebox--spacing (mode leftover count gap)
  "Return (LEADING BETWEEN) for content distribution MODE."
  (setq leftover (max 0 leftover))
  (pcase mode
    ((or 'flex-end 'end 'right 'bottom) (list leftover gap))
    ('center (list (/ leftover 2) gap))
    ('space-between
     (if (> count 1) (list 0 (+ gap (/ leftover (1- count)))) (list 0 gap)))
    ('space-around
     (let ((unit (if (> count 0) (/ leftover count) 0)))
       (list (/ unit 2) (+ gap unit))))
    ('space-evenly
     (let ((unit (if (> count 0) (/ leftover (1+ count)) 0)))
       (list unit (+ gap unit))))
    (_ (list 0 gap))))

(defun ebox--spread (amount count)
  "Return COUNT whole shares summing to AMOUNT, earlier shares larger."
  (let ((base (if (> count 0) (/ amount count) 0))
        (rest (if (> count 0) (% amount count) 0)))
    (cl-loop for i below count collect (+ base (if (< i rest) 1 0)))))

(defun ebox--align-offset (align extra)
  "Return the cross offset of ALIGN in EXTRA free space."
  (pcase align
    ((or 'flex-end 'end 'self-end 'right 'bottom) (max 0 extra))
    ('center (max 0 (/ extra 2)))
    (_ 0)))

(defun ebox--item-align (child container-align)
  "Return CHILD's cross alignment under CONTAINER-ALIGN."
  (let ((self (ebox--cv (ebox-node-cs child) 'ebox/align-self)))
    (if (memq self '(nil auto)) (or container-align 'stretch) self)))

(defun ebox--auto-height-p (child)
  "Return non-nil when CHILD's height is automatic."
  (and (not (eq (ebox-node-tag child) 'text))
       (memq (ebox-cs-height (ebox-node-cs child)) '(nil auto))))

(defun ebox--stretch-height-p (child)
  "Return non-nil when CHILD's height stretches to its containing block."
  (eq (ebox-cs-height (ebox-node-cs child)) 'stretch))

(defun ebox--bb-width (cs value cbw extras)
  "Return border-box pixels for width VALUE of CS against CBW, or nil."
  (let ((px (ebox--px value cs cbw)))
    (and px (if (eq (ebox-cs-box-sizing cs) 'content-box) (+ px extras) (max px extras)))))

(defun ebox--bb-height (cs value cbh extras)
  "Return border-box lines for height VALUE of CS against CBH, or nil."
  (let ((lines (ebox--lines value cs cbh)))
    (and lines (if (eq (ebox-cs-box-sizing cs) 'content-box) (+ lines extras)
                 (max lines extras)))))

;;;; Flexible length resolution

(ebox--defstruct (ebox-flexi (:constructor ebox-flexi--make) (:copier nil))
  "One flex item during main-size resolution."
  node (base 0) (hyp 0) (lo 0) hi (grow 0) (shrink 1) (target 0) frozen (nat 0) mode)

(defun ebox--flex-clamp (item size)
  "Clamp SIZE between ITEM's minimum and maximum main sizes."
  (max (ebox-flexi-lo item) (if (ebox-flexi-hi item) (min size (ebox-flexi-hi item)) size)))

(defun ebox--flex-resolve (line avail gap)
  "Resolve target main sizes of LINE items in AVAIL with GAP."
  (let* ((count (length line))
         (space (- avail (* gap (max 0 (1- count)))))
         (hyps 0))
    (dolist (item line) (setq hyps (+ hyps (ebox-flexi-hyp item))))
    (let ((grow (< hyps space))
          (initial space)
          (guard 0)
          (unfrozen nil))
      (dolist (item line)
        (let ((factor (if grow (ebox-flexi-grow item) (ebox-flexi-shrink item)))
              (base (ebox-flexi-base item))
              (hyp (ebox-flexi-hyp item)))
          (setf (ebox-flexi-target item) hyp)
          (if (or (<= factor 0)
                  (if grow (> base hyp) (< base hyp)))
              (progn (setf (ebox-flexi-frozen item) t)
                     (setq initial (- initial hyp)))
            (setf (ebox-flexi-frozen item) nil)
            (setq initial (- initial base) unfrozen t))))
      (while (and unfrozen (< (setq guard (1+ guard)) 64))
        (let ((free space) (factors 0) (total 0) (violation 0) mins maxs active shares)
          (dolist (item line)
            (if (ebox-flexi-frozen item)
                (setq free (- free (ebox-flexi-target item)))
              (let ((base (ebox-flexi-base item)))
                (setq free (- free base)
                      factors (+ factors (if grow (ebox-flexi-grow item)
                                           (ebox-flexi-shrink item)))
                      total (+ total (if grow (ebox-flexi-grow item)
                                       (* (ebox-flexi-shrink item) base))))
                (push item active))))
          (setq active (nreverse active))
          (when (and (> factors 0) (< factors 1)
                     (< (abs (* initial factors)) (abs free)))
            (setq free (* initial factors)))
          ;; Whole free space is shared in whole units: each item takes the
          ;; floor of its share and the earliest items take the remainder, so
          ;; overflowing one-line rows drop from the start, not in between.
          (when (and (> total 0) (/= free 0) (= free (floor free)))
            (let* ((amount (abs (truncate free)))
                   (sign (if (< free 0) -1 1))
                   (cells (mapcar (lambda (item)
                                    (let ((weight (if grow (ebox-flexi-grow item)
                                                    (* (ebox-flexi-shrink item)
                                                       (ebox-flexi-base item)))))
                                      (cons weight (if (> weight 0)
                                                       (floor (* amount (float weight)) total)
                                                     0))))
                                  active))
                   (left (- amount (apply #'+ (mapcar #'cdr cells)))))
              (dolist (cell cells)
                (when (and (> left 0) (> (car cell) 0))
                  (setcdr cell (1+ (cdr cell)))
                  (setq left (1- left))))
              (setq shares (mapcar (lambda (cell) (* sign (cdr cell))) cells))))
          (if (or (<= total 0) (and grow (< free 0)) (and (not grow) (> free 0)))
              (dolist (item active)
                (setf (ebox-flexi-target item) (ebox--flex-clamp item (ebox-flexi-base item))
                      (ebox-flexi-frozen item) t))
            (dolist (item active)
              (let* ((weight (if grow (ebox-flexi-grow item)
                               (* (ebox-flexi-shrink item) (ebox-flexi-base item))))
                     (raw (+ (ebox-flexi-base item)
                             (if shares (pop shares) (* free (/ (float weight) total)))))
                     (clamped (ebox--flex-clamp item raw)))
                (setf (ebox-flexi-target item) clamped)
                (cond ((> clamped raw) (push item mins))
                      ((< clamped raw) (push item maxs)))
                (setq violation (+ violation (- clamped raw)))))
            (dolist (item (cond ((< (abs violation) 1e-9) active)
                                ((> violation 0) mins)
                                (t maxs)))
              (setf (ebox-flexi-frozen item) t)))
          (setq unfrozen nil)
          (dolist (item line)
            (unless (ebox-flexi-frozen item) (setq unfrozen t))))))
    ;; Quantize at cumulative display boundaries, as `ebox-size-quantize'.
    (let ((position 0.0) (previous 0))
      (dolist (item line)
        (let ((target (max 0 (ebox-flexi-target item))))
          (if (and (fixnump target) (= position previous))
              (setq previous (+ previous target) position previous)
            (setq position (+ position target))
            (let ((boundary (floor (+ position 1e-9))))
              (setf (ebox-flexi-target item) (- boundary previous))
              (setq previous boundary))
            (setq target nil))
          (when target (setf (ebox-flexi-target item) target)))))
    line))

(defun ebox--flex-break (items limit gap wrap)
  "Break flex ITEMS into lines within LIMIT using GAP when WRAP."
  (if (or (memq wrap '(nil nowrap)) (null limit))
      (list items)
    (let (lines current (size 0))
      (dolist (item items)
        (let ((next (+ size (if current gap 0) (ebox-flexi-hyp item))))
          (if (and current (> next limit))
              (progn (push (nreverse current) lines)
                     (setq current (list item) size (ebox-flexi-hyp item)))
            (push item current)
            (setq size next))))
      (when current (push (nreverse current) lines))
      (nreverse lines))))

;;;; Flex containers

(defun ebox--flex-row-item (child cw)
  "Return CHILD's flex item for a horizontal main axis of CW pixels.
CHILD's intrinsic widths are read, and recorded for change detection, only
when its basis or automatic minimum depends on them."
  (let* ((cs (ebox-node-cs child))
         (text (eq (ebox-node-tag child) 'text))
         (margins (ebox--node-h-margins child cw))
         (extras (ebox--node-h-extras child cw))
         (basis (ebox--cv cs 'ebox/flex-basis))
         (sized (and (not text) (not (memq basis '(nil auto content)))
                     (ebox--bb-width cs basis cw extras)))
         (explicit (and (not text) (ebox--bb-width cs (ebox-cs-min-width cs) cw extras)))
         (outer (if (or text (not sized)
                        (and (not explicit) (eq (ebox-cs-overflow cs) 'visible)))
                    (ebox--outer-intrinsic child cw t)
                  (setf (ebox-node-seen child) nil)))
         (base (cond
                (text (cdr outer))
                ((eq basis 'content) (+ (cdr (ebox--intrinsic child)) extras margins))
                (sized (+ sized margins))
                (t (cdr outer))))
         (hi (and (not text) (ebox--bb-width cs (ebox-cs-max-width cs) cw extras)))
         (lo (cond
              (text (cdr outer))
              (explicit (+ explicit margins))
              ((eq (ebox-cs-overflow cs) 'visible)
               (let ((fixed (ebox--bb-width cs (ebox-cs-width cs) cw extras)))
                 (min (car outer)
                      (if fixed (+ fixed margins) most-positive-fixnum)
                      (if hi (+ hi margins) most-positive-fixnum))))
              (t (+ extras margins))))
         (item (ebox-flexi--make :node child :base (max 0 base) :lo lo
                                 :hi (and hi (+ hi margins))
                                 :grow (if text 0 (or (ebox--cv cs 'ebox/flex-grow) 0))
                                 :shrink (if text 0 (or (ebox--cv cs 'ebox/flex-shrink) 1)))))
    (setf (ebox-flexi-hyp item) (ebox--flex-clamp item (ebox-flexi-base item)))
    item))

(defun ebox--flex-column-item (child cw cbh align)
  "Return CHILD's flex item for a vertical main axis.
CHILD is laid out at its cross size within CW; CBH is the container's
definite content height; ALIGN is the container's cross alignment."
  (let* ((cs (ebox-node-cs child))
         (text (eq (ebox-node-tag child) 'text))
         (stretch (memq (ebox--item-align child align) '(stretch normal)))
         (mode (if stretch 'stretch 'shrink))
         (natural (ebox--natural-h child cw mode cbh))
         (geo (ebox-node-layout child))
         (margins (+ (ebox-geo-mt geo) (ebox-geo-mb geo)))
         (extras (+ (ebox-geo-pt geo) (ebox-geo-pb geo)))
         (basis (ebox--cv cs 'ebox/flex-basis))
         (base (cond
                (text natural)
                ((memq basis '(nil auto content)) natural)
                (t (let ((bb (ebox--bb-height cs basis cbh extras)))
                     (if bb (+ bb margins) natural)))))
         (explicit (and (not text) (ebox--bb-height cs (ebox-cs-min-height cs) cbh extras)))
         (hi (and (not text) (ebox--bb-height cs (ebox-cs-max-height cs) cbh extras)))
         (lo (cond
              (text natural)
              (explicit (+ explicit margins))
              ((eq (ebox-cs-overflow cs) 'visible) natural)
              (t (+ extras margins))))
         (item (ebox-flexi--make :node child :base (max 0 base) :lo lo
                                 :hi (and hi (+ hi margins))
                                 :grow (if text 0 (or (ebox--cv cs 'ebox/flex-grow) 0))
                                 :shrink (if text 0 (or (ebox--cv cs 'ebox/flex-shrink) 1))
                                 :nat natural :mode mode)))
    (setf (ebox-flexi-hyp item) (ebox--flex-clamp item (ebox-flexi-base item)))
    item))

(defun ebox--flex-natural (node geo)
  "Return flex NODE's natural content height from its children's recorded sizes.
GEO is NODE's stretched layout.  Return nil for a wrapping container, whose
line breaks follow its stretched size."
  (let ((cs (ebox-node-cs node)))
    (when (memq (ebox--cv cs 'ebox/flex-wrap) '(nil nowrap))
      (let ((kids (ebox--flow-kids node)))
        (if (memq (or (ebox--cv cs 'ebox/flex-direction) 'row) '(row row-reverse))
            (let ((cross 0))
              (dolist (kid kids cross)
                (setq cross (max cross (ebox--recorded-natural kid)))))
          (let ((cw (ebox-geo-cw geo))
                (align (or (ebox--cv cs 'ebox/align-items) 'stretch))
                (sum (* (or (ebox--lines (ebox--cv cs 'ebox/row-gap) cs nil) 0)
                        (max 0 (1- (length kids))))))
            (dolist (kid kids sum)
              (setq sum (+ sum (ebox-flexi-hyp (ebox--flex-column-item kid cw nil align)))))))))))

(defun ebox--layout-flex (node geo cbh)
  "Lay out flex NODE; return its content height."
  (let* ((cs (ebox-node-cs node))
         (direction (or (ebox--cv cs 'ebox/flex-direction) 'row))
         (horizontal (memq direction '(row row-reverse)))
         (reverse (memq direction '(row-reverse column-reverse)))
         (wrap (or (ebox--cv cs 'ebox/flex-wrap) 'nowrap))
         (justify (ebox--cv cs 'ebox/justify-content))
         (align (or (ebox--cv cs 'ebox/align-items) 'stretch))
         (align-content (or (ebox--cv cs 'ebox/align-content) 'stretch))
         (cw (ebox-geo-cw geo))
         (column-gap (or (ebox--px (ebox--cv cs 'ebox/column-gap) cs cw) 0))
         (row-gap (or (ebox--lines (ebox--cv cs 'ebox/row-gap) cs cbh) 0))
         (kids (ebox--flow-kids node))
         (height
          (if horizontal
              (ebox--layout-flex-row node kids cw cbh column-gap row-gap
                                     wrap justify align align-content)
            (ebox--layout-flex-column node kids cw cbh row-gap column-gap
                                      wrap justify align align-content))))
    (when reverse
      (dolist (kid kids)
        (if horizontal
            (setf (ebox-node-x kid) (- cw (ebox-node-x kid) (ebox-node-w kid)))
          (setf (ebox-node-y kid) (- height (ebox-node-y kid) (ebox-node-h kid))))))
    (when (eq wrap 'wrap-reverse)
      (dolist (kid kids)
        (if horizontal
            (setf (ebox-node-y kid) (- height (ebox-node-y kid) (ebox-node-h kid)))
          (setf (ebox-node-x kid) (- cw (ebox-node-x kid) (ebox-node-w kid))))))
    ;; `ebox--flow-kids' returns a fresh list, so sorting may reuse it.
    (ebox--set-items geo (vconcat (sort kids (lambda (a b) (< (ebox-node-y a) (ebox-node-y b))))))
    (setf (ebox-geo-stack geo) nil
          (ebox-geo-kind geo) 'pos)
    height))

(defun ebox--cross-lines (crosses container gap align-content single)
  "Return (CROSSES LEADING BETWEEN) placing flex line CROSSES in CONTAINER."
  (let* ((count (length crosses))
         (natural (+ (apply #'+ crosses) (* gap (max 0 (1- count)))))
         (leftover (if container (- container natural) 0)))
    (cond
     ((and container single (= count 1)) (list (list container) 0 gap))
     ((and container (> leftover 0) (memq align-content '(stretch normal)))
      (list (cl-mapcar #'+ crosses (ebox--spread leftover count)) 0 gap))
     (t (let ((spacing (ebox--spacing align-content leftover count gap)))
          (list crosses (car spacing) (cadr spacing)))))))

(defun ebox--layout-flex-row (_node kids cw cbh gap cross-gap wrap justify align
                                    align-content)
  "Lay out KIDS of a horizontal flex container; return content height.
CW is the main size, CBH the definite content height, GAP the main gap and
CROSS-GAP the gap between lines."
  (let ((items nil) (single (memq wrap '(nil nowrap))) (crosses nil))
    (dolist (kid kids) (push (ebox--flex-row-item kid cw) items))
    (let ((lines (ebox--flex-break (nreverse items) cw gap wrap)))
      (dolist (line lines)
        (ebox--flex-resolve line cw gap)
        (let ((cross 0))
          (dolist (item line)
            (let ((nat (ebox--natural-h (ebox-flexi-node item) (ebox-flexi-target item)
                                        'exact cbh)))
              (setf (ebox-flexi-nat item) nat)
              (setq cross (max cross nat))))
          (push cross crosses)))
      (let* ((placed (ebox--cross-lines (nreverse crosses) cbh cross-gap align-content
                                        single))
             (sizes (car placed))
             (between (nth 2 placed))
             (y (nth 1 placed)))
        (dolist (line lines)
          (let ((cross (car sizes)) (used (* gap (max 0 (1- (length line))))))
            (setq sizes (cdr sizes))
            (dolist (item line) (setq used (+ used (ebox-flexi-target item))))
            (let* ((spacing (ebox--spacing justify (- cw used) (length line) gap))
                   (x (car spacing))
                   (step (cadr spacing)))
              (dolist (item line)
                (let* ((kid (ebox-flexi-node item))
                       (self (ebox--item-align kid align)))
                  (ebox--place-h kid (ebox-flexi-target item) 'exact cbh (ebox-flexi-nat item)
                                 (and (memq self '(stretch normal)) (ebox--auto-height-p kid)
                                      cross))
                  (setf (ebox-node-x kid) x
                        (ebox-node-y kid)
                        (+ y (ebox--align-offset self (- cross (ebox-node-h kid)))))
                  (setq x (+ x (ebox-flexi-target item) step)))))
            (setq y (+ y cross between))))
        (max 0 (- y between))))))

(defun ebox--layout-flex-column (_node kids cw cbh gap cross-gap wrap justify align
                                       align-content)
  "Lay out KIDS of a vertical flex container; return content height.
CW is the cross size, CBH the definite main size or nil, GAP the main gap
and CROSS-GAP the gap between lines."
  (let* ((items (let (acc)
                  (dolist (kid kids (nreverse acc))
                    (push (ebox--flex-column-item kid cw cbh align) acc))))
         (lines (ebox--flex-break items cbh gap wrap))
         (single (or (memq wrap '(nil nowrap)) (null (cdr lines))))
         crosses (main 0))
    (dolist (line lines)
      (if cbh
          (ebox--flex-resolve line cbh gap)
        (dolist (item line) (setf (ebox-flexi-target item) (ebox-flexi-hyp item))))
      (let ((cross 0))
        (dolist (item line)
          (let ((kid (ebox-flexi-node item)))
            (ebox--place-h kid cw (ebox-flexi-mode item) cbh (ebox-flexi-nat item)
                           (ebox-flexi-target item))
            (setq cross (max cross (ebox-node-w kid)))))
        (setq main (max main (+ (apply #'+ (mapcar #'ebox-flexi-target line))
                                (* gap (max 0 (1- (length line)))))))
        (push cross crosses)))
    (let ((height (or cbh main)))
      (pcase-let* ((`(,sizes ,leading ,between)
                    (ebox--cross-lines (nreverse crosses) cw
                                       cross-gap align-content single))
                   (x leading))
        (cl-mapc
         (lambda (line cross)
           (let* ((used (+ (apply #'+ (mapcar #'ebox-flexi-target line))
                           (* gap (max 0 (1- (length line))))))
                  (spacing (ebox--spacing justify (- height used) (length line) gap))
                  (y (car spacing)))
             (dolist (item line)
               (let* ((kid (ebox-flexi-node item))
                      (self (ebox--item-align kid align)))
                 (when (and (memq self '(stretch normal))
                            (not (eq (ebox-node-tag kid) 'text))
                            (/= (ebox-node-w kid) cross)
                            (not single))
                   (ebox--layout kid cross 'stretch cbh (ebox-geo-bh (ebox-node-layout kid))))
                 (setf (ebox-node-x kid)
                       (+ x (ebox--align-offset self (- cross (ebox-node-w kid))))
                       (ebox-node-y kid) y)
                 (setq y (+ y (ebox-flexi-target item) (cadr spacing)))))
             (setq x (+ x cross between))))
         lines sizes))
      (max height main))))

;;;; Grid tracks

(defun ebox--grid-expand (tracks)
  "Expand `repeat' forms in TRACKS."
  (cl-mapcan (lambda (track)
               (if (and (consp track) (eq (car track) 'repeat))
                   (let ((body (nth 2 track)))
                     (setq body (if (and (consp body)
                                         (not (memq (car body) '(fr minmax px ch lh % vw vh
                                                                 calc min max clamp))))
                                    body (list body)))
                     (cl-loop repeat (nth 1 track) append (ebox--grid-expand body)))
                 (list track)))
             (if (and (consp tracks) (memq (car tracks) '(fr minmax repeat px ch lh %)))
                 (list tracks)
               tracks)))

(defun ebox--grid-track (track cs base horizontal)
  "Normalize TRACK to (KIND . DATA) resolving fixed sizes against BASE."
  (cond
   ((or (null track) (eq track 'auto)) '(auto))
   ((memq track '(min-content max-content)) (list track))
   ((and (consp track) (eq (car track) 'fr)) (cons 'fr (cadr track)))
   ((and (consp track) (eq (car track) 'minmax))
    (let ((lo (ebox--grid-track (nth 1 track) cs base horizontal))
          (hi (ebox--grid-track (nth 2 track) cs base horizontal)))
      (when (and (eq (car lo) 'fixed) (eq (car hi) 'fixed) (< (cdr hi) (cdr lo)))
        (setq hi lo))
      (list 'minmax lo hi)))
   (t (let ((size (if horizontal (ebox--px track cs base) (ebox--lines track cs base))))
        (if size (cons 'fixed (max 0 size)) '(auto))))))

(defun ebox--grid-tracks (cs id auto-id count base horizontal)
  "Return COUNT normalized tracks of CS from template ID and AUTO-ID."
  (let* ((explicit (mapcar (lambda (track) (ebox--grid-track track cs base horizontal))
                           (ebox--grid-expand (ebox--cv cs id))))
         (auto-value (ebox--cv cs auto-id))
         (auto (ebox--grid-track (if (and (consp auto-value) (null (cdr auto-value))
                                          (not (memq (car auto-value) '(fr minmax px ch lh %))))
                                     (car auto-value) auto-value)
                                 cs base horizontal)))
    (append explicit (make-list (max 0 (- count (length explicit))) auto))))

(defun ebox--grid-span-part (value)
  "Return (START . SPAN) of grid placement VALUE; START 0 means automatic."
  (pcase value
    ((or 'nil 'auto) (cons 0 1))
    ((pred integerp) (cons value 1))
    (`(:span ,span) (cons 0 span))
    (`(,start) (cons start 1))
    (`(,start :span ,span) (cons start span))
    (`(,start ,end) (cons start (- end start)))
    (_ (cons 0 1))))

(ebox--defstruct (ebox-gridi (:constructor ebox-gridi--make) (:copier nil))
  "One placed grid item."
  node (row 0) (col 0) (rspan 1) (cspan 1) (nat 0) width mode)

(defun ebox--grid-place (kids columns rows flow)
  "Place KIDS on a grid of at least COLUMNS by ROWS cells using FLOW.
Return (ITEMS ROW-COUNT COLUMN-COUNT) with zero-based cells."
  (let ((cells (make-hash-table :test 'equal))
        (ncols (max 1 columns)) (nrows (max 1 rows)) items
        ;; Every search scans in a fixed order and cells are never freed,
        ;; so each one resumes after the occupied cells that start its
        ;; order instead of rescanning them: placement stays linear in the
        ;; number of items.  FIRST is the first unoccupied cell in FLOW
        ;; order, valid while the grid keeps FIRST-EXTENT cells across
        ;; that order; ROW-FIRST and COLUMN-FIRST hold the first
        ;; unoccupied column of a row and row of a column.
        (first (cons 0 0)) (first-extent nil)
        (row-first (make-hash-table)) (column-first (make-hash-table)))
    (cl-labels
        ((occupied-p (r c) (gethash (cons r c) cells))
         (free-p (r c rs cs)
           (cl-loop for i from r below (+ r rs)
                    always (cl-loop for j from c below (+ c cs)
                                    never (occupied-p i j))))
         (mark (r c rs cs)
           (cl-loop for i from r below (+ r rs)
                    do (cl-loop for j from c below (+ c cs)
                                do (puthash (cons i j) t cells)))
           (setq nrows (max nrows (+ r rs)) ncols (max ncols (+ c cs))))
         (first-in-row (r)
           (let ((c (gethash r row-first 0)))
             (while (occupied-p r c) (setq c (1+ c)))
             (puthash r c row-first)))
         (first-in-column (c)
           (let ((r (gethash c column-first 0)))
             (while (occupied-p r c) (setq r (1+ r)))
             (puthash c r column-first)))
         (first-free (major across)
           ;; FIRST as (MAJOR-INDEX . MINOR-INDEX) below MAJOR major lines
           ;; of ACROSS cells each.
           (unless (eql first-extent across)
             (setq first (cons 0 0) first-extent across))
           (let ((i (car first)) (j (cdr first)))
             (while (and (< i major)
                         (if (eq flow 'column) (occupied-p j i) (occupied-p i j)))
               (setq j (1+ j))
               (when (>= j across) (setq i (1+ i) j 0)))
             (setq first (cons i j)))))
      (dolist (kid kids)
        (let* ((cs (ebox-node-cs kid))
               (rp (ebox--grid-span-part (ebox--cv cs 'ebox/grid-row)))
               (cp (ebox--grid-span-part (ebox--cv cs 'ebox/grid-column)))
               (rs (max 1 (or (ebox--cv cs 'ebox/grid-row-span) (cdr rp))))
               (cs* (max 1 (or (ebox--cv cs 'ebox/grid-column-span) (cdr cp))))
               (r (1- (car rp))) (c (1- (car cp)))
               position)
          (cond
           ((and (>= r 0) (>= c 0)) (setq position (cons r c)))
           ((>= r 0)
            (setq position
                  (or (cl-loop for j from (first-in-row r) to (max 0 (- ncols cs*))
                               when (free-p r j rs cs*) return (cons r j))
                      (cons r ncols))))
           ((>= c 0)
            (setq position
                  (or (cl-loop for i from (first-in-column c) to nrows
                               when (free-p i c rs cs*) return (cons i c)))))
           ((eq flow 'column)
            (let ((start (first-free ncols nrows)))
              (setq position
                    (or (cl-loop for j from (car start) below ncols
                                 thereis (cl-loop for i from (if (= j (car start)) (cdr start) 0)
                                                  to (max 0 (- nrows rs))
                                                  when (free-p i j rs cs*)
                                                  return (cons i j)))
                        (cons 0 ncols)))))
           (t
            (let ((start (first-free nrows ncols)))
              (setq position
                    (or (cl-loop for i from (car start) below nrows
                                 thereis (cl-loop for j from (if (= i (car start)) (cdr start) 0)
                                                  to (max 0 (- ncols cs*))
                                                  when (free-p i j rs cs*)
                                                  return (cons i j)))
                        (cons nrows 0))))))
          (mark (car position) (cdr position) rs cs*)
          (push (ebox-gridi--make :node kid :row (car position) :col (cdr position)
                                  :rspan rs :cspan cs*)
                items))))
    (list (nreverse items) nrows ncols)))

(defun ebox--grid-contribution (item kind horizontal cbw)
  "Return ITEM's KIND size contribution on the HORIZONTAL axis."
  (let* ((kid (ebox-gridi-node item))
         (span (if horizontal (ebox-gridi-cspan item) (ebox-gridi-rspan item))))
    (if horizontal
        (let ((outer (ebox--outer-intrinsic kid cbw t)))
          (pcase kind
            ('min-content (car outer))
            ('max-content (cdr outer))
            (_ (let ((cs (ebox-node-cs kid)))
                 (cond
                  ((eq (ebox-node-tag kid) 'text) (car outer))
                  ((and (> span 1) (null (ebox--px (ebox-cs-min-width cs) cs cbw))) 0)
                  ((ebox--px (ebox-cs-min-width cs) cs cbw)
                   (+ (ebox--node-h-margins kid cbw)
                      (ebox--bb-width cs (ebox-cs-min-width cs) cbw (ebox--node-h-extras kid cbw))))
                  ((eq (ebox-cs-overflow cs) 'visible) (car outer))
                  (t (+ (ebox--node-h-margins kid cbw) (ebox--node-h-extras kid cbw))))))))
      (ebox-gridi-nat item))))

(defun ebox--grid-sizes (tracks items horizontal avail gap cbw)
  "Resolve TRACKS for ITEMS on the HORIZONTAL axis within AVAIL with GAP."
  (let* ((count (length tracks))
         (sizes (make-vector count 0))
         flexible)
    (cl-labels
        ((track-min (track)
           (pcase (car track)
             ('fixed (cdr track))
             ('minmax (track-min (nth 1 track)))
             (_ nil)))
         (track-max (track)
           (pcase (car track)
             ('fixed (cdr track))
             ('minmax (track-max (nth 2 track)))
             (_ nil)))
         (factor (track)
           (pcase (car track)
             ('fr (cdr track))
             ('minmax (factor (nth 2 track)))
             (_ 0)))
         (intrinsic (track index)
           (pcase (car track)
             ('fixed (cdr track))
             ('minmax (intrinsic (nth 1 track) index))
             (kind
              (let ((mode (if (eq kind 'fr) 'auto-min kind)) (best 0))
                (dolist (item items best)
                  (let ((start (if horizontal (ebox-gridi-col item) (ebox-gridi-row item)))
                        (span (if horizontal (ebox-gridi-cspan item) (ebox-gridi-rspan item))))
                    (when (and (<= start index) (< index (+ start span))
                               (or (= span 1) (not horizontal)
                                   (eq mode 'auto-min)))
                      (setq best (max best (if (and (> span 1) (not horizontal))
                                               (/ (ebox--grid-contribution item mode nil cbw)
                                                  span)
                                             (if (> span 1)
                                                 (/ (ebox--grid-contribution item mode t cbw)
                                                    span)
                                               (ebox--grid-contribution
                                                item mode horizontal cbw)))))))))))))
      (dotimes (i count)
        (let* ((track (nth i tracks))
               (size (intrinsic track i))
               (hi (track-max track)))
          (when (and hi (not (eq (car track) 'fixed))) (setq size (min size hi)))
          (when (track-min track) (setq size (max size (track-min track))))
          (aset sizes i size)
          (when (> (factor track) 0) (push i flexible))))
      (setq flexible (nreverse flexible))
      (cond
       ((and flexible avail)
        (let ((remaining (- avail (* gap (max 0 (1- count)))
                            (cl-loop for i below count
                                     unless (memq i flexible) sum (aref sizes i)))))
          (while flexible
            (let* ((total (cl-loop for i in flexible sum (factor (nth i tracks))))
                   (unit (/ (float (max 0 remaining)) (max 1 total)))
                   (frozen (cl-remove-if-not
                            (lambda (i) (> (aref sizes i) (* unit (factor (nth i tracks)))))
                            flexible)))
              (if frozen
                  (dolist (i frozen)
                    (setq remaining (- remaining (aref sizes i))
                          flexible (delq i flexible)))
                (dolist (i flexible)
                  (aset sizes i (* unit (factor (nth i tracks)))))
                (setq flexible nil))))))
       (flexible
        (let ((unit (cl-loop for i in flexible
                             maximize (/ (float (max (aref sizes i)
                                                     (intrinsic '(max-content) i)))
                                         (max 1 (factor (nth i tracks)))))))
          (dolist (i flexible)
            (aset sizes i (* unit (factor (nth i tracks)))))))))
    (vconcat (ebox-size-quantize (append sizes nil)))))

(defun ebox--grid-layout-tracks (sizes gap avail align)
  "Return (SIZES OFFSETS) for track SIZES distributed in AVAIL by ALIGN."
  (let* ((count (length sizes))
         (natural (+ (apply #'+ (append sizes nil)) (* gap (max 0 (1- count)))))
         (leftover (if avail (- avail natural) 0)))
    (when (and (> leftover 0) (memq align '(stretch normal)) (> count 0))
      (setq sizes (vconcat (cl-mapcar #'+ sizes (ebox--spread leftover count)))
            leftover 0))
    (let* ((spacing (ebox--spacing (if (memq align '(stretch normal)) 'start align)
                                   leftover count gap))
           (offsets (make-vector (1+ count) 0))
           (pos (car spacing)))
      (dotimes (i count)
        (aset offsets i pos)
        (setq pos (+ pos (aref sizes i) (if (< i (1- count)) (cadr spacing) 0))))
      (aset offsets count pos)
      (list sizes offsets (cadr spacing)))))

(defun ebox--grid-extent (sizes offsets start span gap)
  "Return the extent of SPAN tracks from START in SIZES with GAP."
  (ignore offsets)
  (+ (cl-loop for i from start below (min (length sizes) (+ start span))
              sum (aref sizes i))
     (* gap (max 0 (1- span)))))

(defun ebox--layout-grid (node geo cbh)
  "Lay out grid NODE; return its content height."
  (let* ((cs (ebox-node-cs node))
         (cw (ebox-geo-cw geo))
         (column-gap (or (ebox--px (ebox--cv cs 'ebox/column-gap) cs cw) 0))
         (row-gap (or (ebox--lines (ebox--cv cs 'ebox/row-gap) cs cbh) 0))
         (kids (ebox--flow-kids node))
         (explicit-cols (length (ebox--grid-expand (ebox--cv cs 'ebox/grid-template-columns))))
         (explicit-rows (length (ebox--grid-expand (ebox--cv cs 'ebox/grid-template-rows))))
         (placed (ebox--grid-place kids explicit-cols explicit-rows
                                   (or (ebox--cv cs 'ebox/grid-auto-flow) 'row)))
         (items (car placed))
         (justify-items (or (ebox--cv cs 'ebox/justify-items) 'stretch))
         (align-items (or (ebox--cv cs 'ebox/align-items) 'stretch))
         (col-tracks (ebox--grid-tracks cs 'ebox/grid-template-columns
                                        'ebox/grid-auto-columns (nth 2 placed) cw t))
         (col-layout (ebox--grid-layout-tracks
                      (ebox--grid-sizes col-tracks items t cw column-gap cw)
                      column-gap cw
                      (or (ebox--cv cs 'ebox/justify-content) 'start)))
         (widths (car col-layout)) (xs (nth 1 col-layout)) (cgap (nth 2 col-layout)))
    ;; Lay out every item at its column extent to learn its height.
    (dolist (item items)
      (let* ((kid (ebox-gridi-node item))
             (width (ebox--grid-extent widths xs (ebox-gridi-col item)
                                       (ebox-gridi-cspan item) cgap))
             (justify (let ((self (ebox--cv (ebox-node-cs kid) 'ebox/justify-self)))
                        (if (memq self '(nil auto)) justify-items self))))
        ;; A stretched height fills the grid area, which track sizing has
        ;; not resolved yet, so its contribution is its content height.
        (setf (ebox-gridi-width item) width
              (ebox-gridi-mode item) (if (memq justify '(stretch normal)) 'stretch 'shrink)
              (ebox-gridi-nat item)
              (ebox--natural-h kid width (ebox-gridi-mode item)
                               (unless (ebox--stretch-height-p kid) cbh)))
        (setf (ebox-node-x kid)
              (+ (aref xs (ebox-gridi-col item))
                 (ebox--align-offset justify (- width (ebox-node-w kid)))))))
    (let* ((row-tracks (ebox--grid-tracks cs 'ebox/grid-template-rows
                                          'ebox/grid-auto-rows (nth 1 placed) cbh nil))
           (row-layout (ebox--grid-layout-tracks
                        (ebox--grid-sizes row-tracks items nil cbh row-gap cw)
                        row-gap cbh
                        (or (ebox--cv cs 'ebox/align-content) 'start)))
           (heights (car row-layout)) (ys (nth 1 row-layout)) (rgap (nth 2 row-layout)))
      (dolist (item items)
        (let* ((kid (ebox-gridi-node item))
               (height (ebox--grid-extent heights ys (ebox-gridi-row item)
                                          (ebox-gridi-rspan item) rgap))
               (align (ebox--item-align kid align-items)))
          (ebox--place-h kid (ebox-gridi-width item) (ebox-gridi-mode item)
                         (unless (ebox--stretch-height-p kid) cbh)
                         (ebox-gridi-nat item)
                         (and (or (ebox--stretch-height-p kid)
                                  (and (memq align '(stretch normal)) (ebox--auto-height-p kid)))
                              height))
          (setf (ebox-node-y kid)
                (+ (aref ys (ebox-gridi-row item))
                   (ebox--align-offset align (- height (ebox-node-h kid)))))))
      (ebox--set-items geo (vconcat (sort (copy-sequence kids)
                                          (lambda (a b) (< (ebox-node-y a) (ebox-node-y b))))))
      (setf (ebox-geo-stack geo) nil
            (ebox-geo-kind geo) 'pos)
      (let ((count (length heights)))
        (if (zerop count) 0
          (+ (aref ys (1- count)) (aref heights (1- count))))))))

(defun ebox--grid-intrinsic (node)
  "Return (MIN . MAX) content widths of grid NODE."
  (let* ((cs (ebox-node-cs node))
         (gap (or (ebox--px (ebox--cv cs 'ebox/column-gap) cs nil) 0))
         (kids (ebox--flow-kids node))
         (placed (ebox--grid-place
                  kids (length (ebox--grid-expand (ebox--cv cs 'ebox/grid-template-columns)))
                  (length (ebox--grid-expand (ebox--cv cs 'ebox/grid-template-rows)))
                  (or (ebox--cv cs 'ebox/grid-auto-flow) 'row)))
         (tracks (ebox--grid-tracks cs 'ebox/grid-template-columns
                                    'ebox/grid-auto-columns (nth 2 placed) nil t))
         (count (length tracks))
         (gaps (* gap (max 0 (1- count))))
         (minw 0) (maxw 0))
    (dotimes (i count)
      (let ((track (nth i tracks)) (lo 0) (hi 0))
        (pcase (car track)
          ('fixed (setq lo (cdr track) hi (cdr track)))
          (_ (dolist (item (car placed))
               (when (and (= (ebox-gridi-col item) i) (= (ebox-gridi-cspan item) 1))
                 (let ((outer (ebox--outer-intrinsic (ebox-gridi-node item) nil)))
                   (setq lo (max lo (car outer)) hi (max hi (cdr outer))))))))
        (setq minw (+ minw lo) maxw (+ maxw hi))))
    (cons (+ minw gaps) (+ maxw gaps))))

(provide 'ebox-flex)

;;; ebox-flex.el ends here
