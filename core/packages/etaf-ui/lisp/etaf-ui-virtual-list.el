;;; etaf-ui-virtual-list.el --- Windowed virtual list component -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Windowed virtual scrolling list (`etaf-virtual-list') that renders only the
;; items inside the visible viewport plus an `:overscan' cushion, using top and
;; bottom spacers so mount and scroll costs stay O(viewport) for large
;; collections (5,000+ rows).
;;
;; Supports two layout paths:
;; - Fixed row height (`:item-height N'): O(1) index/offset arithmetic.
;; - Dynamic row height (`:item-height nil'): per-key measured row height cache,
;;   cumulative prefix-sum offset vector with O(log N) binary search, post-commit
;;   measurement via `etaf-host-ref-size', and `:scroll-anchor' scroll-offset
;;   compensation when rows above the viewport change height.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui-basic)

(cl-defstruct (etaf-ui--vlist-state (:constructor etaf-ui--vlist-state-make)
                                    (:copier nil))
  "Mutable retained state for one `etaf-virtual-list' instance."
  raw-items
  (vec [])
  (keys-vec [])
  (key-to-idx (make-hash-table :test #'equal))
  (heights (make-hash-table :test #'equal))
  (offsets [0])
  (offsets-rev -1)
  (last-estimate 1)
  (viewport-rows 24)
  (scroll-offset 0)
  (window-first 0)
  (window-end 0)
  row-refs
  (row-ref-syms (make-hash-table :test #'equal))
  last-selected-key
  pending-scroll-to)

(defun etaf-ui--vlist-unwrap (value)
  "Read VALUE if it is a reactive ref or computed, else return VALUE."
  (if (or (etaf-ref-p value) (etaf-computed-p value))
      (etaf-value value)
    value))

(defun etaf-ui--vlist-height-lines (height)
  "Extract integer line count from HEIGHT when fixed, or nil."
  (cond
   ((and (integerp height) (> height 0)) height)
   ((and (consp height) (eq (car height) 'lh)
         (integerp (cadr height)) (> (cadr height) 0))
    (cadr height))
   (t nil)))

(defun etaf-ui--vlist-height-css (height)
  "Convert HEIGHT prop into an ECSS height value."
  (cond
   ((null height) 'stretch)
   ((integerp height) (list 'lh height))
   (t height)))

(defun etaf-ui--vlist-item-key (item index item-key)
  "Resolve unique key for ITEM at INDEX using optional ITEM-KEY."
  (cond
   (item-key (funcall item-key item))
   ((and (listp item) (plist-member item :key)) (plist-get item :key))
   ((and (listp item) (plist-member item :id)) (plist-get item :id))
   (t index)))

(defun etaf-ui--vlist-sync-items (state raw-items item-key)
  "Update STATE's cached vectors and key index when RAW-ITEMS changed."
  (unless (and (eq raw-items (etaf-ui--vlist-state-raw-items state))
               (vectorp (etaf-ui--vlist-state-vec state)))
    (let* ((vec (cond
                 ((null raw-items) [])
                 ((vectorp raw-items) raw-items)
                 ((listp raw-items) (vconcat raw-items))
                 (t (etaf-check-prop :items raw-items nil
                                     "a list, vector, or reactive source"
                                     'etaf-virtual-list))))
           (n (length vec))
           (keys (make-vector n nil))
           (index-map (make-hash-table :test #'equal :size (max 16 n))))
      (dotimes (i n)
        (let ((k (etaf-ui--vlist-item-key (aref vec i) i item-key)))
          (aset keys i k)
          (puthash k i index-map)))
      (setf (etaf-ui--vlist-state-raw-items state) raw-items
            (etaf-ui--vlist-state-vec state) vec
            (etaf-ui--vlist-state-keys-vec state) keys
            (etaf-ui--vlist-state-key-to-idx state) index-map
            (etaf-ui--vlist-state-offsets-rev state) -1)))
  state)

(defun etaf-ui--vlist-ensure-offsets (state estimate-height rev)
  "Ensure STATE's dynamic prefix-sum offset vector is current for REV."
  (let* ((keys (etaf-ui--vlist-state-keys-vec state))
         (n (length keys))
         (heights (etaf-ui--vlist-state-heights state)))
    (unless (and (= (etaf-ui--vlist-state-offsets-rev state) rev)
                 (= (etaf-ui--vlist-state-last-estimate state) estimate-height)
                 (= (length (etaf-ui--vlist-state-offsets state)) (1+ n)))
      (let ((offs (make-vector (1+ n) 0))
            (acc 0))
        (dotimes (i n)
          (aset offs i acc)
          (let ((h (or (gethash (aref keys i) heights) estimate-height)))
            (setq acc (+ acc (max 1 h)))))
        (aset offs n acc)
        (setf (etaf-ui--vlist-state-offsets state) offs
              (etaf-ui--vlist-state-offsets-rev state) rev
              (etaf-ui--vlist-state-last-estimate state) estimate-height))))
  (etaf-ui--vlist-state-offsets state))

(defun etaf-ui--vlist-bsearch (offsets target)
  "Return the largest index I in [0, N-1] with OFFSETS[I] <= TARGET."
  (let* ((n (1- (length offsets)))
         (lo 0)
         (hi (max 0 (1- n))))
    (if (<= n 0)
        0
      (while (< lo hi)
        (let ((mid (/ (+ lo hi 1) 2)))
          (if (<= (aref offsets mid) target)
              (setq lo mid)
            (setq hi (1- mid)))))
      lo)))

(defun etaf-ui--vlist-row-bounds (state index item-height estimate-height rev)
  "Return (TOP . BOTTOM) in lines for row INDEX in STATE."
  (if item-height
      (let ((top (* index item-height)))
        (cons top (+ top item-height)))
    (let ((offs (etaf-ui--vlist-ensure-offsets state estimate-height rev)))
      (cons (aref offs index) (aref offs (1+ index))))))

(defun etaf-ui--vlist-compute-window
    (state offset viewport-rows item-height estimate-height overscan rev)
  "Compute (FIRST END ABOVE-LINES BELOW-LINES) for STATE at scroll OFFSET."
  (let* ((n (length (etaf-ui--vlist-state-vec state)))
         (vp (max 1 viewport-rows))
         (off (max 0 offset)))
    (cond
     ((<= n 0) (list 0 0 0 0))
     (item-height
      (let* ((vis-first (min (1- n) (/ off item-height)))
             (vis-end (min n (/ (+ off vp item-height -1) item-height)))
             (first (max 0 (- vis-first overscan)))
             (end (min n (+ vis-end overscan)))
             (above (* first item-height))
             (below (* (- n end) item-height)))
        (list first end above below)))
     (t
      (let* ((offs (etaf-ui--vlist-ensure-offsets state estimate-height rev))
             (total (aref offs n))
             (clamped (min off (max 0 (1- total))))
             (vis-first (etaf-ui--vlist-bsearch offs clamped))
             (bottom-target (+ clamped vp))
             (vis-last (etaf-ui--vlist-bsearch offs (max clamped (1- bottom-target))))
             (first (max 0 (- vis-first overscan)))
             (end (min n (+ vis-last 1 overscan)))
             (above (aref offs first))
             (below (max 0 (- total (aref offs end)))))
        (list first end above below))))))

(defun etaf-ui--vlist-needs-slide-p
    (state offset viewport-rows item-height estimate-height rev)
  "Return non-nil when viewport at OFFSET exceeds STATE's rendered window."
  (let* ((n (length (etaf-ui--vlist-state-vec state)))
         (first (etaf-ui--vlist-state-window-first state))
         (end (etaf-ui--vlist-state-window-end state)))
    (and (> n 0)
         (or (>= first end)
             (let* ((first-top
                     (car (etaf-ui--vlist-row-bounds
                           state first item-height estimate-height rev)))
                    (end-bottom
                     (if (>= end n)
                         most-positive-fixnum
                       (cdr (etaf-ui--vlist-row-bounds
                             state (1- end) item-height estimate-height rev)))))
               (or (and (> first 0) (< offset first-top))
                   (and (< end n) (> (+ offset viewport-rows) end-bottom))))))))

(defun etaf-ui--vlist-reveal-index
    (state container-ref index item-height estimate-height rev scroll-ref)
  "Scroll CONTAINER-REF minimally so row INDEX is visible; update SCROLL-REF."
  (let* ((rt (etaf-current-runtime))
         (n (length (etaf-ui--vlist-state-vec state))))
    (when (and rt (etaf-runtime-mounted-p rt) (> n 0)
               (>= index 0) (< index n))
      (let* ((bounds (etaf-ui--vlist-row-bounds
                      state index item-height estimate-height rev))
             (top (car bounds))
             (bottom (cdr bounds))
             (vp (max 1 (etaf-ui--vlist-state-viewport-rows state)))
             (cur (or (ignore-errors (etaf-scroll-offset rt container-ref))
                      (etaf-ui--vlist-state-scroll-offset state)))
             (target (cond
                      ((< top cur) top)
                      ((> bottom (+ cur vp)) (max 0 (- bottom vp)))
                      (t nil))))
        (when target
          (let ((applied (or (ignore-errors
                               (etaf-scroll-to rt container-ref target))
                             target)))
            (setf (etaf-ui--vlist-state-scroll-offset state) applied)
            (when (etaf-ui--vlist-needs-slide-p
                   state applied vp item-height estimate-height rev)
              (etaf-set-value scroll-ref applied))))))))

(defun etaf-ui--vlist-measure
    (state container-ref fixed-height item-height estimate-height
           scroll-anchor measure-rev-ref scroll-ref)
  "Measure container viewport height and dynamic row heights post-commit."
  (let ((rt (etaf-current-runtime)))
    (when (and rt (etaf-runtime-mounted-p rt))
      (when-let* ((pending (etaf-ui--vlist-state-pending-scroll-to state)))
        (setf (etaf-ui--vlist-state-pending-scroll-to state) nil)
        (let ((applied (or (ignore-errors (etaf-scroll-to rt container-ref pending))
                           pending)))
          (setf (etaf-ui--vlist-state-scroll-offset state) applied)))
      (unless fixed-height
        (when-let* ((sz (ignore-errors (etaf-host-ref-size rt container-ref)))
                    (rows (cdr sz)))
          (when (and (integerp rows) (> rows 0)
                     (/= rows (etaf-ui--vlist-state-viewport-rows state)))
            (setf (etaf-ui--vlist-state-viewport-rows state) rows)
            (etaf-set-value measure-rev-ref
                            (1+ (etaf-value measure-rev-ref))))))
      (unless item-height
        (let* ((heights (etaf-ui--vlist-state-heights state))
               (key-to-idx (etaf-ui--vlist-state-key-to-idx state))
               (rev (etaf-value measure-rev-ref))
               (offs (etaf-ui--vlist-ensure-offsets state estimate-height rev))
               (cur-off (or (ignore-errors (etaf-scroll-offset rt container-ref))
                            (etaf-ui--vlist-state-scroll-offset state)))
               (changed nil)
               (anchor-delta 0))
          (dolist (entry (etaf-ui--vlist-state-row-refs state))
            (let* ((k (car entry))
                   (rref (cdr entry))
                   (sz (ignore-errors (etaf-host-ref-size rt rref)))
                   (measured (and sz (cdr sz))))
              (when (and (integerp measured) (> measured 0))
                (let ((old (or (gethash k heights) estimate-height)))
                  (unless (= measured old)
                    (when-let* ((idx (gethash k key-to-idx)))
                      (when (< (aref offs idx) cur-off)
                        (setq anchor-delta (+ anchor-delta (- measured old)))))
                    (puthash k measured heights)
                    (setq changed t))))))
          (when changed
            (let ((next-rev (1+ rev)))
              (etaf-ui--vlist-ensure-offsets state estimate-height next-rev)
              (when (and (eq scroll-anchor 'top) (/= anchor-delta 0))
                (let* ((next-off (max 0 (+ cur-off anchor-delta)))
                       (applied (or (ignore-errors
                                      (etaf-scroll-to rt container-ref next-off))
                                    next-off)))
                  (setf (etaf-ui--vlist-state-scroll-offset state) applied)
                  (etaf-set-value scroll-ref applied)))
              (etaf-set-value measure-rev-ref next-rev))))))))

(defun etaf-ui--vlist-step
    (state container-ref selected-key-prop on-select
           item-height estimate-height measure-rev-ref scroll-ref delta-or-edge)
  "Move selection in STATE by DELTA-OR-EDGE and report next key via ON-SELECT."
  (let* ((vec (etaf-ui--vlist-state-vec state))
         (keys (etaf-ui--vlist-state-keys-vec state))
         (kmap (etaf-ui--vlist-state-key-to-idx state))
         (n (length vec)))
    (when (and (> n 0) on-select)
      (let* ((cur-key (etaf-ui--vlist-unwrap
                       (etaf-value selected-key-prop)))
             (cur-idx (or (and cur-key (gethash cur-key kmap)) -1))
             (vp (max 1 (etaf-ui--vlist-state-viewport-rows state)))
             (page (max 1 (1- (/ vp (max 1 (or item-height estimate-height))))))
             (next-idx
              (pcase delta-or-edge
                ('home 0)
                ('end (1- n))
                ('page-down (min (1- n) (+ (max 0 cur-idx) page)))
                ('page-up (max 0 (- (max 0 cur-idx) page)))
                ((pred integerp)
                 (if (< cur-idx 0)
                     (if (> delta-or-edge 0) 0 (1- n))
                   (max 0 (min (1- n) (+ cur-idx delta-or-edge)))))
                (_ 0)))
             (next-key (aref keys next-idx)))
        (funcall on-select next-key)
        (etaf-ui--vlist-reveal-index
         state container-ref next-idx
         item-height estimate-height
         (etaf-value measure-rev-ref) scroll-ref)
        t))))

(defun etaf-ui--vlist-nav-keys
    (state container-ref selected-key-prop on-select on-activate
           item-height estimate-height measure-rev-ref scroll-ref extra-keys)
  "Build key bindings for `etaf-virtual-list', prepending EXTRA-KEYS.
Arrow keys are routed through `:on-direction' per ETAF's key contract."
  (let* ((step (lambda (move)
                 (etaf-ui--vlist-step
                  state container-ref selected-key-prop on-select
                  item-height estimate-height measure-rev-ref scroll-ref move)))
         (activate-fn
          (lambda ()
            (when on-activate
              (let ((cur-key (etaf-ui--vlist-unwrap
                              (etaf-value selected-key-prop))))
                (when cur-key
                  (funcall on-activate cur-key))))))
         (nav-keys
          (append
           (when on-select
             (list (list "C-n" (lambda () (funcall step 1)) "Next item")
                   (list "C-p" (lambda () (funcall step -1)) "Previous item")
                   (list "<next>" (lambda () (funcall step 'page-down)) "Next page")
                   (list "<prior>" (lambda () (funcall step 'page-up)) "Previous page")
                   (list "<home>" (lambda () (funcall step 'home)) "First item")
                   (list "<end>" (lambda () (funcall step 'end)) "Last item")))
           (when on-activate
             (list (list "RET" activate-fn "Activate item"))))))
    (append extra-keys nav-keys)))

(etaf-define-component etaf-virtual-list
    (&key items item-key render-item item-height estimate-height overscan
          height width selected-key on-select on-activate on-scroll
          scroll-anchor empty-view empty-label keys region focus-group
          ref class label)
  "Render a windowed virtual list keeping DOM size O(viewport).

ITEMS is a list, vector, or reactive source of items.  RENDER-ITEM is called as
`(RENDER-ITEM ITEM INDEX SELECTED-P)' only for items inside the visible window
plus OVERSCAN rows on each edge.  ITEM-HEIGHT enables the O(1) fixed-height
fast path; when nil, dynamic row heights are measured post-commit from
ESTIMATE-HEIGHT with optional SCROLL-ANCHOR compensation."
  :bindings ((state (etaf-ui--vlist-state-make))
             (local-ref (etaf-local-ref 'virtual-list))
             (scroll-ref (etaf-ref 0 :name 'vlist-scroll))
             (measure-rev (etaf-ref 0 :name 'vlist-measure-rev))
             (selected-prop (etaf-prop :selected-key))
             (item-height-prop (etaf-prop :item-height))
             (estimate-prop (etaf-prop :estimate-height))
             (height-prop (etaf-prop :height))
             (anchor-prop (etaf-prop :scroll-anchor))
             (ref-prop (etaf-prop :ref))
             (hooks
              (let ((run-measure
                     (lambda ()
                       (let* ((href (or (etaf-value ref-prop) local-ref))
                              (fh (etaf-ui--vlist-height-lines
                                   (etaf-value height-prop)))
                              (ih (etaf-value item-height-prop))
                              (eh (or (etaf-value estimate-prop) 1))
                              (anc (or (etaf-value anchor-prop) 'top)))
                         (etaf-ui--vlist-measure
                          state href fh ih eh anc measure-rev scroll-ref)))))
                (etaf-on-mounted run-measure)
                (etaf-on-updated run-measure)
                t)))
  :validate
  (progn
    (etaf-check-prop :items items
                     (or (null items) (listp items) (vectorp items)
                         (etaf-ref-p items) (etaf-computed-p items))
                     "a list, vector, or reactive source" 'etaf-virtual-list)
    (etaf-check-prop :item-key item-key
                     (or (null item-key) (functionp item-key))
                     "a function or nil" 'etaf-virtual-list)
    (etaf-check-prop :render-item render-item
                     (functionp render-item)
                     "a render function" 'etaf-virtual-list)
    (etaf-check-prop :item-height item-height
                     (or (null item-height)
                         (and (integerp item-height) (> item-height 0)))
                     "a positive integer or nil" 'etaf-virtual-list)
    (etaf-check-prop :estimate-height estimate-height
                     (or (null estimate-height)
                         (and (integerp estimate-height) (> estimate-height 0)))
                     "a positive integer or nil" 'etaf-virtual-list)
    (etaf-check-prop :overscan overscan
                     (or (null overscan)
                         (and (integerp overscan) (>= overscan 0)))
                     "a non-negative integer or nil" 'etaf-virtual-list)
    (etaf-check-prop :scroll-anchor scroll-anchor
                     (memq scroll-anchor '(nil top bottom))
                     "`top', `bottom', or nil" 'etaf-virtual-list)
    (etaf-check-prop :on-select on-select
                     (or (null on-select) (functionp on-select))
                     "a function or nil" 'etaf-virtual-list)
    (etaf-check-prop :on-activate on-activate
                     (or (null on-activate) (functionp on-activate))
                     "a function or nil" 'etaf-virtual-list)
    (etaf-check-prop :on-scroll on-scroll
                     (or (null on-scroll) (functionp on-scroll))
                     "a function or nil" 'etaf-virtual-list)
    (etaf-check-prop :label label
                     (or (null label) (stringp label))
                     "a string or nil" 'etaf-virtual-list))
  :render
  (let* ((_ hooks)
         (estimate-height (or estimate-height 1))
         (overscan (or overscan 4))
         (width (or width 'stretch))
         (label (or label "Virtual list"))
         (container-ref (or ref local-ref))
         (fixed-lines (etaf-ui--vlist-height-lines height))
         (_ (when fixed-lines
              (setf (etaf-ui--vlist-state-viewport-rows state) fixed-lines)))
         (raw-items (etaf-ui--vlist-unwrap items))
         (cur-selected (etaf-ui--vlist-unwrap selected-key))
         (rev (etaf-value measure-rev))
         (offset (etaf-value scroll-ref)))
    (etaf-ui--vlist-sync-items state raw-items item-key)
    (let* ((vec (etaf-ui--vlist-state-vec state))
           (keys-vec (etaf-ui--vlist-state-keys-vec state))
           (kmap (etaf-ui--vlist-state-key-to-idx state))
           (n (length vec))
           (vp (etaf-ui--vlist-state-viewport-rows state))
           (eff-offset
            (let ((off offset))
              (when (and cur-selected
                         (not (equal cur-selected
                                     (etaf-ui--vlist-state-last-selected-key state))))
                (setf (etaf-ui--vlist-state-last-selected-key state) cur-selected)
                (when-let* ((sidx (gethash cur-selected kmap)))
                  (let* ((b (etaf-ui--vlist-row-bounds
                             state sidx item-height estimate-height rev))
                         (top (car b))
                         (bot (cdr b))
                         (target (cond
                                  ((< top off) top)
                                  ((> bot (+ off vp)) (max 0 (- bot vp)))
                                  (t nil))))
                    (when target
                      (setq off target)
                      (setf (etaf-ui--vlist-state-scroll-offset state) target
                            (etaf-ui--vlist-state-pending-scroll-to state) target)))))
              off))
           (win (etaf-ui--vlist-compute-window
                 state eff-offset vp item-height estimate-height overscan rev))
           (first (nth 0 win))
           (end (nth 1 win))
           (above (nth 2 win))
           (below (nth 3 win))
           (visible-rows nil)
           (row-refs nil)
           (nav-keys (etaf-ui--vlist-nav-keys
                      state container-ref selected-prop
                      on-select on-activate
                      item-height estimate-height measure-rev scroll-ref keys))
           (scroll-handler
            (lambda (new-offset)
              (setf (etaf-ui--vlist-state-scroll-offset state) new-offset)
              (when (etaf-ui--vlist-needs-slide-p
                     state new-offset
                     (etaf-ui--vlist-state-viewport-rows state)
                     item-height estimate-height (etaf-value measure-rev))
                (etaf-set-value scroll-ref new-offset))
              (when on-scroll
                (funcall on-scroll new-offset))))
           (direction-handler
            (when on-select
              (lambda (dir)
                (pcase dir
                  ('down
                   (etaf-ui--vlist-step
                    state container-ref selected-prop on-select
                    item-height estimate-height measure-rev scroll-ref 1)
                   'handled)
                  ('up
                   (etaf-ui--vlist-step
                    state container-ref selected-prop on-select
                    item-height estimate-height measure-rev scroll-ref -1)
                   'handled)
                  (_ 'release)))))
           (container-props
            (append
             (list :class (if class
                              (format "etaf-virtual-list %s" class)
                            "etaf-virtual-list")
                   :ref container-ref
                   :width width
                   :height (etaf-ui--vlist-height-css height)
                   :min-height '(lh 0)
                   :flex-grow (when (eq height 'stretch) 1)
                   :flex-basis (when (eq height 'stretch) '(lh 0))
                   :overflow 'scroll
                   :item-gap '(lh 0)
                   :role 'listbox
                   :aria-label label
                   :tab-index 0
                   :on-scroll scroll-handler)
             (when direction-handler (list :on-direction direction-handler))
             (when focus-group (list :focus-group focus-group))
             (when region (list :region region))
             (when nav-keys (list :keys nav-keys)))))
      (setf (etaf-ui--vlist-state-window-first state) first
            (etaf-ui--vlist-state-window-end state) end)
      (when (> n 0)
        (let ((i (1- end))
              (sym-table (etaf-ui--vlist-state-row-ref-syms state)))
          (while (>= i first)
            (let* ((item (aref vec i))
                   (k (aref keys-vec i))
                   (sel-p (and cur-selected (equal k cur-selected)))
                   (rendered (funcall render-item item i sel-p)))
              (if item-height
                  (push (etaf-node 'box (list :key k :width 'stretch)
                                   (list rendered))
                        visible-rows)
                (let ((rref (or (gethash k sym-table)
                                (puthash k (make-symbol (format "etaf-vlist-row-%s" k))
                                         sym-table))))
                  (push (cons k rref) row-refs)
                  (push (etaf-node 'box (list :key k :ref rref :width 'stretch)
                                   (list rendered))
                        visible-rows))))
            (setq i (1- i)))))
      (setf (etaf-ui--vlist-state-row-refs state) row-refs)
      (if (= n 0)
          (etaf-node
           'column container-props
           (cond
            (empty-view (list empty-view))
            (empty-label
             (list (etaf-node 'box (list :width 'stretch :padding '((lh 1) (ch 2)))
                              (list (etaf-node
                                     'text
                                     (list :color (etaf-theme-token :ui-muted-fg "#6b7280"))
                                     (list empty-label))))))
            (t nil)))
        (etaf-node
         'column container-props
         (delq nil
               (append
                (when (> above 0)
                  (list (etaf-node 'box (list :key 'etaf-vlist-above
                                              :width 'stretch
                                              :height (list 'lh above))
                                   nil)))
                visible-rows
                (when (> below 0)
                  (list (etaf-node 'box (list :key 'etaf-vlist-below
                                              :width 'stretch
                                              :height (list 'lh below))
                                   nil))))))))))

(provide 'etaf-ui-virtual-list)
;;; etaf-ui-virtual-list.el ends here
