;;; ebox-buffer.el --- Mounting retained trees in buffers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A mount binds one retained root to a buffer.  Mutations mark dirty bits and
;; queue the mount; the outermost batch flushes it once.  A flush restyles dirty
;; paths, relayouts the dirty subtree inside its structural boundaries, turns
;; the recorded damage into ordered line replacements and writes only those
;; lines.  Sparse markers anchor line starts so a write locates its first line
;; in O(lines per anchor) without per-line markers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'face-remap)
(require 'ebox-node)
(require 'ebox-layout)
(require 'ebox-flex)

;;;; Mounts

(ebox--defstruct (ebox-mount (:constructor ebox-mount--make) (:copier nil))
  "A retained root painted into a buffer."
  root buffer (anchors []) (lines 0) vw vh fixed-vw fixed-vh
  queued observer (flushes 0) report last-report anchored
  focus active hover hover-saved hover-p session display-saved
  focus-anchor (focus-memory (make-hash-table :test #'eq :weakness 'key))
  (written (make-hash-table)) tick canvas canvas-cookie)

(defvar ebox--current-mount nil
  "The mount being flushed, which supplies interaction-derived states.")

(defvar-local ebox--buffer-mount nil
  "The mount painted into the current buffer, or nil.")

(defvar ebox--queue nil
  "Mounts with pending changes.")

(defvar ebox--batch-depth 0
  "Nesting depth of active update batches.")

(defvar ebox--flushing nil
  "Non-nil while a flush is writing a buffer.")

(defconst ebox--display-locals
  '((bidi-paragraph-direction . left-to-right)
    (truncate-lines . t)
    (long-line-threshold . nil)
    (line-spacing . nil)
    (display-line-numbers . nil)
    (line-prefix . nil)
    (wrap-prefix . nil))
  "Display settings of a mounted buffer and the values Ebox gives them.
Ebox lays rows out left to right, so a paragraph detected as right-to-left
would mirror whole rows.  Native continuation must not wrap the assembled
rows again or reserve a continuation column at their right edge.
Row length is bounded by the layout width, so
the long-line scan Emacs repeats over the whole buffer after text changes
cannot find anything.  Line spacing, line numbers and line and wrap
prefixes would make the display disagree with the measured rows, so the
canvas owns them as well.")

(defun ebox--own-display ()
  "Apply `ebox--display-locals' to the current buffer; return the old state."
  (mapcar (lambda (entry)
            (let ((variable (car entry)))
              (prog1 (list variable (local-variable-p variable) (symbol-value variable))
                (set (make-local-variable variable) (cdr entry)))))
          ebox--display-locals))

(defun ebox--restore-display (saved)
  "Restore display settings SAVED by `ebox--own-display' in the current buffer."
  (pcase-dolist (`(,variable ,local ,value) saved)
    (if local
        (set (make-local-variable variable) value)
      (kill-local-variable variable))))

(defun ebox--sync-canvas (mount)
  "Paint MOUNT's buffer background with its root's background color.
Window areas beyond the laid-out text, such as the partial line below the
last row, show the buffer's default face; remapping its background to the
root's color keeps them the same as the application surface."
  (let ((bg (ebox-cs-bg (ebox-node-cs (ebox-mount-root mount)))))
    (unless (stringp bg) (setq bg nil))
    (unless (equal bg (ebox-mount-canvas mount))
      (when-let* ((cookie (ebox-mount-canvas-cookie mount)))
        (face-remap-remove-relative cookie))
      (setf (ebox-mount-canvas mount) bg
            (ebox-mount-canvas-cookie mount)
            (and bg (face-remap-add-relative 'default :background bg)))
      ;; Record Ebox's paint-only remap at its mutation boundary, not on the
      ;; next unrelated measurement or input event.
      (ebox--compute-metric-key))))

(defun ebox--release-canvas (mount)
  "Remove the background remapping of MOUNT's buffer."
  (when-let* ((cookie (ebox-mount-canvas-cookie mount)))
    (face-remap-remove-relative cookie))
  (setf (ebox-mount-canvas mount) nil
        (ebox-mount-canvas-cookie mount) nil))

(defconst ebox--anchor-span 128
  "Target number of lines between two line anchors.")

(defun ebox-buffer-mount (&optional buffer-or-name)
  "Return the mount of BUFFER-OR-NAME (default current buffer), or nil."
  (let ((buffer (if buffer-or-name (get-buffer buffer-or-name) (current-buffer))))
    (and (buffer-live-p buffer)
         (buffer-local-value 'ebox--buffer-mount buffer))))

(defun ebox-buffer-root (&optional buffer-or-name)
  "Return the root node mounted in BUFFER-OR-NAME, or nil."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (and mount (ebox-mount-root mount))))

(defun ebox--mount-of (node)
  "Return the live mount showing NODE's tree, or nil."
  (let ((mount (ebox-node-mount (ebox-node-root node))))
    (and (ebox-mount-p mount) (buffer-live-p (ebox-mount-buffer mount)) mount)))

(defun ebox-node-buffer (node)
  "Return the buffer showing NODE, or nil."
  (let ((mount (ebox--mount-of node)))
    (and mount (ebox-mount-buffer mount))))

;;;; Invalidation

(defun ebox--enqueue (node)
  "Queue the mount owning NODE for the next flush."
  (let ((mount (ebox-node-mount (ebox-node-root node))))
    (when (and (ebox-mount-p mount) (not (ebox-mount-queued mount)))
      (setf (ebox-mount-queued mount) t)
      (push mount ebox--queue))))

(defun ebox--settle ()
  "Flush queued mounts unless a batch or flush is active."
  (when (and ebox--queue (zerop ebox--batch-depth) (not ebox--flushing))
    (ebox-flush)))

(defmacro ebox--mutation (&rest body)
  "Run BODY, then flush queued mounts outside batches; return BODY's value."
  (declare (indent 0) (debug t))
  `(prog1 (progn ,@body) (ebox--settle)))

(defun ebox--mark (node bits)
  "Set dirty BITS on NODE, record the dirty path and queue its mount."
  (setf (ebox-node-dirty node) (logior (ebox-node-dirty node) bits))
  (ebox--mark-path node)
  (ebox--enqueue node))

(defun ebox--mark-path (node)
  "Record the dirty path from NODE's parent up to the root.
Every ancestor forgets its intrinsic size and lists the child below it among
its dirty children."
  (setf (ebox-node-intr node) nil)
  (let ((child node) (parent (ebox-node-parent node)) (stop nil))
    (while (and parent (not stop))
      (unless (/= 0 (logand (ebox-node-dirty child) ebox--d-queued))
        (setf (ebox-node-dirty child) (logior (ebox-node-dirty child) ebox--d-queued))
        (push child (ebox-node-dkids parent)))
      (setf (ebox-node-intr parent) nil)
      (if (/= 0 (logand (ebox-node-dirty parent) ebox--d-desc))
          (setq stop t)
        (setf (ebox-node-dirty parent) (logior (ebox-node-dirty parent) ebox--d-desc))
        (setq child parent parent (ebox-node-parent parent))))))

(defun ebox--mark-structure (parent op)
  "Record structural OP on PARENT and queue its mount."
  (push op (ebox-node-ops parent))
  (setf (ebox-node-intr parent) nil)
  (ebox--mark parent ebox--d-desc))

(defun ebox--mark-metrics-stale (node)
  "Mark NODE and every descendant stale in style, layout and paint.
A glyph metric change invalidates intrinsic sizes before any parent asks
for a child's contribution, not just when the child is laid out."
  (setf (ebox-node-intr node) nil
        (ebox-node-dirty node) (logior (ebox-node-dirty node) 15))
  (ebox--do-kids (kid node)
    (ebox--mark-metrics-stale kid)))

(defun ebox--refresh-metrics (&optional buffer-or-name)
  "Lay BUFFER-OR-NAME's mounted tree out again after a glyph metric change.
The caller clears the glyph caches.  Preserve the retained tree and state,
re-measure its viewport, then publish the settled display to subscribers."
  (when-let* ((mount (ebox-buffer-mount buffer-or-name)))
    (with-current-buffer (ebox-mount-buffer mount)
      (let* ((root (ebox-mount-root mount))
             (before (cons (ebox-mount-vw mount) (ebox-mount-vh mount)))
             (viewport (ebox--measure-viewport mount)))
        (setf (ebox-mount-vw mount) (car viewport)
              (ebox-mount-vh mount) (cdr viewport))
        (ebox--mark-metrics-stale root)
        (ebox--enqueue root)
        (ebox--settle)
        (run-hook-with-args 'ebox-display-change-functions (current-buffer))
        (unless (equal before viewport)
          (run-hook-with-args 'ebox-viewport-change-functions (current-buffer)))))))

(defvar ebox-display-change-functions nil
  "Abnormal hook run with a mounted buffer after its display metrics settle.
Read `ebox-display-metrics' in the callback.  Retained state is not remounted.")

(defmacro ebox-with-batch (&rest body)
  "Run BODY as one update batch; flush queued mounts when it ends."
  (declare (indent 0) (debug t))
  `(ebox-call-with-batch (lambda () ,@body)))

(defun ebox-call-with-batch (function)
  "Call FUNCTION as one update batch and return its value.
Mutations inside the batch are flushed once after the outermost batch
returns or exits nonlocally."
  (let ((ebox--batch-depth (1+ ebox--batch-depth)) result)
    (unwind-protect
        (setq result (funcall function))
      (when (= ebox--batch-depth 1)
        (let ((ebox--batch-depth 0))
          (ebox-flush))))
    result))

;;;; Public mutations

(defun ebox--check-node (node)
  "Signal unless NODE is an Ebox node."
  (unless (ebox-node-p node)
    (signal 'wrong-type-argument (list 'ebox-node-p node))))

(defun ebox-node-insert (parent child &optional index)
  "Insert detached CHILD into PARENT at INDEX (default last) and return CHILD.
CHILD may be a string, which becomes a text node."
  (ebox--mutation
    (ebox--check-node parent)
    (when (stringp child) (setq child (ebox-text-create child)))
    (ebox--check-node child)
    (ebox--attach parent child (or index (ebox-node-child-count parent)))
    (setf (ebox-node-dirty child) 15)
    (ebox--mark-structure parent (list 'insert child))
    (ebox--mark child ebox--d-style)
    child))

(defun ebox--forget-subtree (node)
  "Clear mounted style and layout facts of detached NODE for reinsertion.
Overlays in NODE's subtree hosted outside it vacate their host's lines.
Computed styles must be revisited after their overlay registrations and
recorded dirty paths are cleared, even when inherited values stay equal."
  (ebox-node-walk node (lambda (n)
                         (let ((host (ebox-node-host n)))
                           (when (and host (not (ebox-node-ancestor-p node host)))
                             (when (ebox-node-placed n) (ebox--overlay-vacated n))
                             (setf (ebox-node-overlays host)
                                   (delq n (ebox-node-overlays host)))))
                         (remhash n ebox--viewport-nodes)
                         (setf (ebox-node-cs n) nil
                               (ebox-node-layout n) nil (ebox-node-avail n) nil
                               (ebox-node-dkids n) nil (ebox-node-ops n) nil
                               (ebox-node-placed n) nil (ebox-node-host n) nil
                               (ebox-node-overlays n) nil
                               (ebox-node-dirty n) 15))))

(defun ebox-node-remove (node)
  "Detach NODE from its parent and return it."
  (ebox--mutation
    (ebox--check-node node)
    (let ((parent (ebox-node-parent node)))
      (when parent
        (let ((laid (and (ebox-node-layout node) (ebox-node-layout parent)
                         (ebox-node-cs node)))
              (abs (and (ebox-node-cs node) (ebox--abs-p node))))
          (setf (ebox-node-dkids parent) (delq node (ebox-node-dkids parent)))
          (ebox--detach node)
          (ebox--forget-subtree node)
          (if (and laid (not abs))
              (ebox--mark-structure parent (list 'remove node (ebox--item-y node)
                                                 (ebox-node-h node)))
            (setf (ebox-node-intr parent) nil)
            (ebox--mark parent (if abs ebox--d-desc ebox--d-layout)))))
      node)))

(defun ebox--overlay-vacated (node)
  "Repaint the lines overlay NODE covered when its host next lays out."
  (let ((host (ebox-node-host node)))
    (when (and (ebox-node-layout host) (> (ebox-node-h node) 0))
      (push (cons (ebox-node-y node) (ebox-node-h node))
            (gethash host ebox--vacated))
      (ebox--mark host ebox--d-desc))))

(defun ebox--unhost (node)
  "Detach overlay NODE from its host, repainting the lines it covered."
  (let ((host (ebox-node-host node)))
    (when host
      (when (ebox-node-placed node) (ebox--overlay-vacated node))
      (setf (ebox-node-overlays host) (delq node (ebox-node-overlays host))
            (ebox-node-host node) nil
            (ebox-node-placed node) nil))))

(defun ebox--rehost (node)
  "Register overlay NODE with its current host; return non-nil on a change."
  (unless (eq (ebox-node-host node) (ebox--host-of node))
    (ebox--unhost node)
    (ebox--register-overlay node)
    t))

(defun ebox--rehost-below (node)
  "Move overlays below NODE whose positioning host changed."
  (ebox--do-kids (kid node)
    (ebox-node-walk kid (lambda (n)
                          (when (and (ebox-node-cs n) (ebox-cs-abs (ebox-node-cs n))
                                     (ebox--rehost n))
                            (ebox--mark n ebox--d-layout))))))

(defun ebox-node-move (node index)
  "Move NODE to INDEX among its siblings."
  (ebox--mutation
    (ebox--check-node node)
    (let ((parent (ebox-node-parent node)))
      (unless parent (signal 'ebox-error (list "Cannot move a root node")))
      (unless (= index (ebox-node-index node))
        (let ((laid (and (ebox-node-layout node) (ebox-node-layout parent)
                         (ebox-node-cs node) (not (ebox--abs-p node)))))
          (when laid
            (ebox--mark-structure parent (list 'remove node (ebox--item-y node)
                                               (ebox-node-h node))))
          (ebox--detach node)
          (ebox--attach parent node index)
          (if laid
              (ebox--mark-structure parent (list 'insert node))
            (setf (ebox-node-intr parent) nil)
            (ebox--mark parent ebox--d-layout))))
      node)))

(defun ebox-node-replace-children (parent children)
  "Replace PARENT's children with CHILDREN, reusing nodes already present."
  (ebox--mutation
    (ebox--check-node parent)
    (when (eq (ebox-node-tag parent) 'text)
      (signal 'ebox-error (list "Ebox text nodes cannot contain children")))
    (let* ((children (mapcar (lambda (c) (if (stringp c) (ebox-text-create c) c)) children))
           (keep (make-hash-table :test 'eq)))
      (dolist (child children)
        (ebox--check-node child)
        (when (or (gethash child keep)
                  (and (ebox-node-parent child) (not (eq (ebox-node-parent child) parent))))
          (signal 'ebox-error (list "Ebox node already has a parent")))
        (puthash child t keep))
      (dolist (old (ebox-node-children parent))
        (unless (gethash old keep)
          (setf (ebox-node-parent old) nil)
          (ebox--forget-subtree old)))
      (setf (ebox-node-dkids parent)
            (cl-remove-if-not (lambda (kid) (gethash kid keep)) (ebox-node-dkids parent)))
      (let (fresh)
        (dolist (child children)
          (unless (ebox-node-parent child) (push child fresh))
          (setf (ebox-node-parent child) parent))
        (ebox--set-kids parent children)
        (dolist (child fresh)
          (setf (ebox-node-dirty child) 15)
          (ebox--mark child ebox--d-style)))
      (setf (ebox-node-intr parent) nil)
      (ebox--mark parent (logior ebox--d-layout ebox--d-style))
      parent)))

(defvar ebox--input-text-function nil
  "Function handling (NODE STRING) for a text node under an input session.")

(defun ebox-node-set-text (node string)
  "Set text NODE's content to STRING."
  (ebox--mutation
    (ebox--check-node node)
    (unless (stringp string) (signal 'wrong-type-argument (list 'stringp string)))
    (unless (eq (ebox-node-tag node) 'text)
      (signal 'ebox-error (list "Not a text node" node)))
    (unless (or (and ebox--editing (assq node ebox--editing)
                     (funcall ebox--input-text-function node string))
                (equal-including-properties string (ebox-node-text node)))
      (setf (ebox-node-text node) string)
      (ebox--mark node ebox--d-layout))
    node))

(defun ebox-node-set-props (node props)
  "Replace NODE's author properties with PROPS."
  (ebox--mutation
    (ebox--check-node node)
    (unless (equal props (ebox-node-props node))
      (let ((old-scroll (ebox-node-scroll node))
            (style-only (ebox--style-change-p (ebox-node-props node) props)))
        (ebox--node-set-props node props)
        (setf (ebox-node-scroll node) old-scroll)
        ;; The style pass relays out a node whose geometry inputs changed and
        ;; only repaints one whose new style keeps them.
        (ebox--mark node (if style-only ebox--d-style
                           (logior ebox--d-style ebox--d-layout)))))
    node))

(defsubst ebox--style-property-p (key)
  "Return non-nil when author property KEY is a style declaration."
  (not (or (memq key ebox--meta-properties)
           (memq key ebox-interaction-properties))))

(defun ebox--style-change-p (old new)
  "Return non-nil when plists OLD and NEW differ only in style properties."
  (let ((ok t) (rest new))
    (while (and ok rest)
      (unless (or (ebox--style-property-p (car rest))
                  (let ((cell (plist-member old (car rest))))
                    (and cell (equal (cadr rest) (cadr cell)))))
        (setq ok nil))
      (setq rest (cddr rest)))
    (setq rest old)
    (while (and ok rest)
      (unless (or (ebox--style-property-p (car rest)) (plist-member new (car rest)))
        (setq ok nil))
      (setq rest (cddr rest)))
    ok))

(defun ebox-node-put (node key value)
  "Set NODE's author property KEY to VALUE."
  (ebox--check-node node)
  (let ((props (copy-sequence (ebox-node-props node))))
    (if (plist-member props key)
        (setq props (plist-put props key value))
      (setq props (append props (list key value))))
    (ebox-node-set-props node props)))

(defun ebox-node-set-states (node states)
  "Set NODE's author selector STATES, a list of symbols or strings."
  (ebox--mutation
    (ebox--check-node node)
    (let ((tokens (mapcar #'ebox--token states)))
      (unless (equal tokens (ebox-node-states node))
        (setf (ebox-node-states node) tokens)
        (ebox--mark node ebox--d-style)))
    node))

(defun ebox-node-restyle (node)
  "Recompute NODE's style after derived selector state changed."
  (ebox--mutation
    (ebox--check-node node)
    (ebox--mark node ebox--d-style)
    node))

(defun ebox-node-set-image (node image)
  "Set image NODE's prepared IMAGE."
  (ebox--mutation
    (ebox--check-node node)
    (setf (ebox-node-image node) image)
    (ebox--mark node ebox--d-layout)
    node))

;;;; Flush: style pass

(defvar ebox--viewport-nodes (make-hash-table :test 'eq :weakness 'key)
  "Nodes whose geometry reads viewport units, mapped to the units they use.
A viewport change relayouts only these nodes, plus the root when its size
follows the viewport.")

(defun ebox--style-pass (node parent-cs force)
  "Restyle NODE's dirty path under PARENT-CS; FORCE recomputes NODE.
A node whose inherited values changed restyles all of its children; otherwise
only the recorded dirty children are visited.  A change that keeps NODE's
geometry inputs only marks it for repainting."
  (let ((changed nil) (old-cs (ebox-node-cs node)) (old-env (ebox-node-env node)))
    (when (or force (/= 0 (logand (ebox-node-dirty node) ebox--d-style))
              (null (ebox-node-cs node)))
      (let ((old (ebox-node-cs node))
            (new (ebox--node-style node parent-cs)))
        (setf (ebox-node-dirty node) (logand (ebox-node-dirty node) (lognot ebox--d-style)))
        (unless (eq old new)
          (setq changed t)
          ;; The hover face restates this paint, so a restyled node must rebuild it.
          (setf (ebox-node-cs node) new
                (ebox-node-inter-cache node) nil)
          ;; A restyled node can sit below unchanged ancestors, so layout and
          ;; painting must find it through the dirty path.
          (when old (ebox--mark-path node))
          (if (ebox-cs-vunits new)
              (puthash node (ebox-cs-vunits new) ebox--viewport-nodes)
            (when (and old (ebox-cs-vunits old)) (remhash node ebox--viewport-nodes)))
          (cond
           ((and old (or (eq (ebox-cs-lkey old) (ebox-cs-lkey new))
                         (ebox--weight-only-change-p old new)))
            (setf (ebox-node-dirty node) (logior (ebox-node-dirty node) ebox--d-paint)))
           (t
            (setf (ebox-node-intr node) nil
                  (ebox-node-dirty node) (logior (ebox-node-dirty node) ebox--d-layout))
            (let* ((parent (ebox-node-parent node))
                   (pgeo (and old parent (ebox-node-layout parent))))
              ;; Flex and grid containers read their items' styles.
              (when (and pgeo (or (eq (ebox-geo-kind pgeo) 'pos)
                                  (not (eq (ebox-cs-outer old) (ebox-cs-outer new)))
                                  (not (eq (ebox-cs-abs old) (ebox-cs-abs new)))))
                (setf (ebox-node-intr parent) nil
                      (ebox-node-dirty parent)
                      (logior (ebox-node-dirty parent) ebox--d-layout))))))
          (when old
            (when (and (ebox-cs-abs old) (not (ebox-cs-abs new)))
              (ebox--unhost node))
            (unless (eq (ebox--host-cs-p old) (ebox--host-cs-p new))
              (ebox--rehost-below node)))
          (when (and (ebox-cs-abs new) (ebox-node-parent node))
            (ebox--rehost node)
            (when (and ebox--current-mount (ebox--anchored-p node))
              (cl-pushnew node (ebox-mount-anchored ebox--current-mount)))))))
    (let ((cs (ebox-node-cs node)))
      (cond
       ;; Children read their parent's scope environment and, unless an
       ;; explicit `inherit' exists, only its inherited values; when neither
       ;; changed their styles stay valid.
       ((or (and changed (not (and old-cs (not ebox-style--explicit-inherit)
                                   (eq (ebox-cs-ikey old-cs) (ebox-cs-ikey cs)))))
            (not (eq old-env (ebox-node-env node))))
        (ebox--do-kids (child node) (ebox--style-pass child cs t)))
       ((/= 0 (logand (ebox-node-dirty node) ebox--d-desc))
        (dolist (kid (ebox-node-dkids node))
          (when (eq (ebox-node-parent kid) node)
            (ebox--style-pass kid cs nil))))))))

;;;; Line anchors

(defun ebox--goto-line (mount line)
  "Move point to the start of LINE in MOUNT's buffer."
  (let* ((anchors (ebox-mount-anchors mount))
         (lo 0) (hi (1- (length anchors))) best)
    (while (<= lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (<= (car (aref anchors mid)) line)
            (setq best mid lo (1+ mid))
          (setq hi (1- mid)))))
    (if best
        (let ((anchor (aref anchors best)))
          (goto-char (cdr anchor))
          (forward-line (- line (car anchor)))
          (when (> (- line (car anchor)) (* 2 ebox--anchor-span))
            (ebox--add-anchor mount line (point))))
      (goto-char (point-min))
      (forward-line line)
      (when (> line (* 2 ebox--anchor-span))
        (ebox--add-anchor mount line (point))))))

(defun ebox--add-anchor (mount line pos)
  "Record an anchor for LINE at POS in MOUNT."
  (let* ((anchors (ebox-mount-anchors mount))
         (i (or (cl-position-if (lambda (a) (> (car a) line)) anchors) (length anchors)))
         (marker (copy-marker pos)))
    (setf (ebox-mount-anchors mount)
          (vconcat (substring anchors 0 i) (vector (cons line marker)) (substring anchors i)))))

(defun ebox--rebuild-anchors (mount)
  "Recreate MOUNT's anchors after its buffer was rewritten."
  (mapc (lambda (a) (set-marker (cdr a) nil)) (ebox-mount-anchors mount))
  (let (anchors (line 0))
    (save-excursion
      (goto-char (point-min))
      (while (and (< line (ebox-mount-lines mount)) (not (eobp)))
        (when (zerop (% line ebox--anchor-span))
          (push (cons line (copy-marker (point))) anchors))
        (forward-line 1)
        (setq line (1+ line))))
    (setf (ebox-mount-anchors mount) (vconcat (nreverse anchors)))))

(defun ebox--shift-anchors (mount start old new total)
  "Adjust MOUNT's anchors after replacing OLD lines at START with NEW.
TOTAL is the line count before the edit.  Anchors before the edit keep
their lines, so only the sorted tail from START is visited."
  (unless (= old new)
    (let* ((delta (- new old))
           (end (+ start old))
           (dead-from (if (and (= new 0) (< end total)) (1+ start) (+ start new)))
           (anchors (ebox-mount-anchors mount))
           (n (length anchors))
           (lo 0) (hi n) (dead nil))
      (while (< lo hi)
        (let ((mid (/ (+ lo hi) 2)))
          (if (< (car (aref anchors mid)) start) (setq lo (1+ mid)) (setq hi mid))))
      (while (< lo n)
        (let* ((anchor (aref anchors lo)) (line (car anchor)))
          (cond
           ((and (>= line dead-from) (< line end))
            (set-marker (cdr anchor) nil)
            (aset anchors lo nil)
            (setq dead t))
           ((and (= old 0) (= line start)) nil)
           ((>= line end) (setcar anchor (+ line delta)))))
        (setq lo (1+ lo)))
      (when dead
        (setf (ebox-mount-anchors mount) (vconcat (delq nil (append anchors nil))))))))

(defun ebox--line-of (mount pos)
  "Return MOUNT line containing buffer POS."
  (let* ((anchors (ebox-mount-anchors mount))
         (n (length anchors))
         (lo 0) (hi (1- n)) best)
    (while (<= lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (<= (marker-position (cdr (aref anchors mid))) pos)
            (setq best mid lo (1+ mid))
          (setq hi (1- mid)))))
    (let ((line (if best (car (aref anchors best)) 0))
          (limit (if (and best (< (1+ best) n))
                     (car (aref anchors (1+ best)))
                   (ebox-mount-lines mount))))
      ;; `count-lines' narrows the buffer, and a narrowing change makes the
      ;; next redisplay redraw every window showing it, so bisect the line
      ;; whose start is the last one at or before POS.
      (save-excursion
        (let ((from (if best (marker-position (cdr (aref anchors best))) (point-min)))
              (lo 0) (hi (max 0 (- limit line))))
          (while (< lo hi)
            (let ((mid (/ (+ lo hi 1) 2)))
              (goto-char from)
              (if (and (zerop (forward-line mid)) (<= (point) pos))
                  (setq lo mid)
                (setq hi (1- mid)))))
          (+ line lo))))))

(defun ebox--track-positions (mount edits)
  "Return point and window positions of MOUNT's buffer that EDITS rewrite.
EDITS are ordered (START OLD NEW) line replacements, or nil when the whole
buffer is rewritten.  Each result holds the position's line and column.
Positions in untouched lines move with their text, so only positions in
replaced lines, or at a line start where lines are inserted, are tracked.
An empty buffer has no line to follow, so its positions stay at the top."
  (when (> (ebox-mount-lines mount) 0)
    (let* ((first (and edits
                       (save-excursion (ebox--goto-line mount (caar edits)) (point))))
           (last (and edits
                      (if (and (null (cdr edits)) (zerop (nth 1 (car edits))))
                          first
                        (ebox--edits-end mount edits))))
           tracked entry)
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (when (setq entry (ebox--tracked-position mount 'start window (window-start window)
                                                  first last edits))
          (push entry tracked))
        (unless (eq window (selected-window))
          (when (setq entry (ebox--tracked-position mount 'point window (window-point window)
                                                    first last edits))
            (push entry tracked))))
      (when (setq entry (ebox--tracked-position mount 'buffer nil (point) first last edits))
        (push entry tracked))
      tracked)))

(defun ebox--edits-end (mount edits)
  "Return the old buffer position where MOUNT's ordered EDITS end.
It is the start of the first old line after the last replaced line."
  (let ((delta 0) (rest edits))
    (while (cdr rest)
      (setq delta (+ delta (- (nth 2 (car rest)) (nth 1 (car rest))))
            rest (cdr rest)))
    (save-excursion
      (ebox--goto-line mount (+ (- (caar rest) delta) (nth 1 (car rest))))
      (point))))

(defun ebox--tracked-position (mount kind window pos first last edits)
  "Return (KIND WINDOW LINE COLUMN) for POS when EDITS of MOUNT rewrite it.
FIRST and LAST are the buffer positions where the edits start and end."
  ;; The first edit starts at the same line before and after, and positions
  ;; after the last replaced line move with their text.
  (unless (or (and first (< pos first)) (and last (> pos last)))
    (let* ((line (if (eql pos first) (caar edits) (ebox--line-of mount pos)))
           (column (if (eql pos first) 0
                     (- pos (save-excursion (goto-char pos) (line-beginning-position))))))
      (when (or (null edits) (ebox--line-rewritten-p line (zerop column) edits))
        (list kind window line column)))))

(defun ebox--line-rewritten-p (line bol edits)
  "Return non-nil when ordered EDITS replace old LINE.
BOL non-nil means the position is at the line start, which an insertion
before LINE would otherwise leave on the inserted text."
  (let ((delta 0) (result 'unknown))
    (while (and edits (eq result 'unknown))
      (let* ((edit (car edits)) (old (nth 1 edit))
             (old-start (- (car edit) delta)))
        (cond ((< line old-start) (setq result nil))
              ((< line (+ old-start old)) (setq result t))
              ((and bol (= old 0) (= line old-start)) (setq result t))
              (t (setq delta (+ delta (- (nth 2 edit) old)))))
        (setq edits (cdr edits))))
    (eq result t)))

(defun ebox--map-line (line edits)
  "Map old LINE through ordered EDITS; return (NEW-LINE . INSIDE)."
  (let ((delta 0) (result nil))
    (dolist (edit edits)
      (unless result
        (let* ((start (car edit)) (old (nth 1 edit)) (new (nth 2 edit))
               (old-start (- start delta)))
          (cond
           ((< line old-start) (setq result (cons (+ line delta) nil)))
           ((< line (+ old-start old))
            (setq result (cons (+ start (min (- line old-start) (max 0 (1- new)))) t)))
           (t (setq delta (+ delta (- new old))))))))
    (or result (cons (+ line delta) nil))))

(defun ebox--restore-positions (mount tracked edits)
  "Restore TRACKED positions of MOUNT after EDITS.
A canvas no taller than its window has nothing to scroll, so its window
starts at the first line: restoring a line that the rewrite moved there
would leave the window showing the blank tail of a short canvas.
Window starts always align to column 0 because mounted buffers truncate
engine rows, so a mid-line start would clip the leading cells of the
first visible row."
  (let ((last (max 0 (1- (ebox-mount-lines mount)))))
    (dolist (entry tracked)
      (pcase-let* ((`(,kind ,window ,line ,column) entry)
                   (new-line (min last (car (ebox--map-line line edits))))
                   (pos (save-excursion
                          (ebox--goto-line mount new-line)
                          (if (eq kind 'start)
                              (point)
                            (min (+ (point) column) (line-end-position)))))
                   (fits (and (window-live-p window)
                              (<= (ebox-mount-lines mount)
                                  (window-body-height window)))))
        (pcase kind
          ('buffer (goto-char pos))
          ('point (when (and (window-live-p window) (/= pos (window-point window)))
                    (set-window-point window pos)))
          ('start (when (window-live-p window)
                    (let ((start (if fits (point-min) pos)))
                      (unless (= start (window-start window))
                        (set-window-start window start t))))))))))

(defun ebox--rewrite-span (line eol &optional old)
  "Make the span from point to EOL read LINE, a string, and end there.
OLD, when supplied, is the string known to occupy that span.
Only the characters between the common prefix and suffix are replaced and
only differing property runs are set, so an update that keeps the text
leaves the characters, and the redisplay work they would cause, alone."
  (let* ((bol (point))
         (len (length line))
         (old (or old (buffer-substring-no-properties bol eol)))
         (olen (length old))
         (same (compare-strings line 0 nil old 0 nil)))
    (unless (eq same t)
      (let* ((prefix (1- (abs same)))
             (limit (- (min len olen) prefix))
             (suffix 0))
        (while (and (< suffix limit)
                    (eq (aref line (- len suffix 1)) (aref old (- olen suffix 1))))
          (setq suffix (1+ suffix)))
        (goto-char (+ bol prefix))
        (delete-region (point) (- eol suffix))
        (insert (substring line prefix (- len suffix)))))
    (let ((i 0))
      (while (< i len)
        (let ((next (or (next-property-change i line) len))
              (props (text-properties-at i line))
              (pos (+ bol i)))
          (unless (and (ebox--props-same-p props (text-properties-at pos))
                       (>= (next-property-change pos nil (+ bol next)) (+ bol next)))
            (set-text-properties pos (+ bol next) props))
          (setq i next))))
    (goto-char (+ bol len))))

(defconst ebox--written-max 512
  "Most root lines whose written strings a mount remembers.")

(defun ebox--rewrite-parts (old parts)
  "Make the buffer line at point, written from strings OLD, show PARTS.
Both are lists of strings in line order.  Strings shared by the two lists at
either end are already in the buffer.  Diff only the middle span's characters
and properties, keeping its unchanged text.  Leave point at the line end."
  (let ((bol (point)) (prefix 0))
    (while (and old parts (eq (car old) (car parts)))
      (setq prefix (+ prefix (length (car old))) old (cdr old) parts (cdr parts)))
    (let* ((lo (length old)) (lp (length parts)) (n (min lo lp))
           (a (nthcdr (- lo n) old)) (b (nthcdr (- lp n) parts))
           (same 0) (suffix 0))
      ;; SAME counts the trailing strings the two lists share.
      (while a
        (if (eq (car a) (car b))
            (setq same (1+ same) suffix (+ suffix (length (car a))))
          (setq same 0 suffix 0))
        (setq a (cdr a) b (cdr b)))
      (let* ((old-count (- lo same)) (count (- lp same))
             (aligned (= old-count count))
             (remaining count) (a old) (b parts))
        ;; Aligned part boundaries let property-only paint reuse both strings
        ;; directly. Do not create a concatenated copy of all their intervals.
        (while (and aligned (> remaining 0))
          (setq aligned (= (length (car a)) (length (car b)))
                remaining (1- remaining) a (cdr a) b (cdr b)))
        (goto-char (+ bol prefix))
        (cond
         ((or aligned (and (= old-count 1) (= count 1)))
          (dotimes (_ count)
            (let ((end (+ (point) (length (car old)))))
              (if (eq (car old) (car parts))
                  (goto-char end)
                (ebox--rewrite-span (car parts) end (car old))))
            (setq old (cdr old) parts (cdr parts))))
         ((or (> old-count 0) (> count 0))
          (ebox--rewrite-span
           (pcase count
             (0 "")
             (1 (car parts))
             (_ (apply #'concat (cl-subseq parts 0 count))))
           (- (line-end-position) suffix))))))
    (end-of-line)))

(defun ebox--write-line (mount line parts)
  "Make buffer LINE of MOUNT, at point, show the strings PARTS."
  (let* ((written (ebox-mount-written mount))
         (old (gethash line written)))
    (if old
        (ebox--rewrite-parts old parts)
      (ebox--rewrite-span (apply #'concat parts) (line-end-position)))
    (when (or old (< (hash-table-count written) ebox--written-max))
      (puthash line parts written))))

(defun ebox--forget-written (mount from)
  "Forget the strings MOUNT wrote to root lines FROM and later."
  (let ((written (ebox-mount-written mount)) stale)
    (maphash (lambda (line _) (when (>= line from) (push line stale))) written)
    (dolist (line stale) (remhash line written))))

(defun ebox--insert-lines (lines)
  "Insert LINES, lists of strings, at point separated by newlines."
  (let ((first t))
    (dolist (parts lines)
      (if first (setq first nil) (insert "\n"))
      (apply #'insert parts))))

(defun ebox--replace-lines (mount start old lines)
  "Replace OLD buffer lines from START with LINES.
Each line is a list of strings.  Lines are joined by newlines without a
trailing newline."
  (let* ((new (length lines))
         (total (ebox-mount-lines mount))
         (common (min old new)))
    (if (and (>= old 128) (>= new 128) (>= (* old 2) total))
        ;; Bulk reflow fast path: when most of a large buffer shifts (such as
        ;; width changes), one delete + sequential insert avoids O(N) per-line
        ;; diffing, concatenation and gap movement.
        (progn
          (ebox--goto-line mount start)
          (let ((from (point)))
            (forward-line (1- old))
            (delete-region from (line-end-position)))
          (ebox--insert-lines lines)
          (ebox--forget-written mount start)
          (setf (ebox-mount-lines mount) (+ total (- new old)))
          (ebox--rebuild-anchors mount))
      (when (> common 0)
        (ebox--goto-line mount start)
        ;; Rewrite shared lines in place so line-start markers stay put.
        (dotimes (i common)
          (when (> i 0) (forward-line 1))
          (ebox--write-line mount (+ start i) (pop lines))))
      (unless (= new old) (ebox--forget-written mount (+ start common)))
      (cond
       ((> new old)
        (cond
         ((> common 0) (insert "\n") (ebox--insert-lines lines))
         ((< start total)
          (ebox--goto-line mount start) (ebox--insert-lines lines) (insert "\n"))
         ((> total 0) (goto-char (point-max)) (insert "\n") (ebox--insert-lines lines))
         (t (goto-char (point-min)) (ebox--insert-lines lines))))
       ((< new old)
        (cond
         ((> common 0)
          (let ((from (point)))
            (forward-line (- old new))
            (delete-region from (line-end-position))))
         ((< (+ start old) total)
          (ebox--goto-line mount start)
          (let ((from (point)))
            (forward-line old)
            (delete-region from (point))))
         ((> start 0)
          (ebox--goto-line mount (1- start))
          (delete-region (line-end-position) (point-max)))
         (t (delete-region (point-min) (point-max))))))
      (ebox--shift-anchors mount start old new total)
      (setf (ebox-mount-lines mount) (+ total (- new old))))))

(defmacro ebox--writing (&rest body)
  "Run BODY with buffer writes that bypass read-only, undo and hooks."
  (declare (indent 0) (debug t))
  (let ((modified (make-symbol "modified")))
    `(let ((inhibit-read-only t)
           (inhibit-modification-hooks t)
           (buffer-undo-list t)
           (,modified (buffer-modified-p)))
       (unwind-protect (progn ,@body)
         (restore-buffer-modified-p ,modified)))))

(defun ebox--carry-mouse-face (position value next-value &optional object)
  "Make the newline at POSITION bridge a hover run in OBJECT.
VALUE is the last cell's mouse face on the preceding line and NEXT-VALUE the
first cell's face on the following line.  The newline bridges the two rows
only when both carry the same face, joining a multirow element into one
native mouse-face run without extending its last row to the window edge."
  (let ((bridge (and value (eq value next-value) value)))
    (if (eq bridge (get-text-property position 'mouse-face object))
        nil
      (if bridge
          (put-text-property position (1+ position) 'mouse-face bridge object)
        (remove-text-properties position (1+ position) '(mouse-face nil) object)))))

(defun ebox--carry-string-mouse-face (string)
  "Make STRING's newlines join the rows of one interactive element.
Rendered output then carries hover feedback across rows exactly like a
mounted buffer does."
  (let ((position 0))
    (while (setq position (string-search "\n" string position))
      (ebox--carry-mouse-face position
                              (and (> position 0)
                                   (get-text-property (1- position) 'mouse-face string))
                              (and (< (1+ position) (length string))
                                   (get-text-property (1+ position) 'mouse-face string))
                              string)
      (cl-incf position)))
  string)

(defun ebox--extend-line-ends (mount from count)
  "Carry COUNT lines of MOUNT from FROM to the window's right edge.
Emacs keeps the last text column free for the truncation glyph when a
window has no right fringe, and lines shorter than the window leave the
rest of the screen row to the default face.  Giving each newline the
background and border lines of its line's last cell with `:extend' paints
that remainder like the box that reaches the line's right edge.  The same
newline carries the cell's `mouse-face', so native hover feedback covers
every row an interactive element spans."
  (let ((last (min (+ from count) (1- (ebox-mount-lines mount)))))
    (when (and (>= from 0) (< from last))
      (ebox--goto-line mount from)
      (let ((line from))
        (while (< line last)
          (let* ((bol (point))
                 (eol (line-end-position))
                 (tail (and (> eol bol) (get-text-property (1- eol) 'face)))
                 (hover (and (> eol bol) (get-text-property (1- eol) 'mouse-face)))
                 (face nil))
            (dolist (key '(:overline :underline :background))
              (when-let* ((value (ebox--face-attribute tail key)))
                (setq face (cl-list* key value face))))
            (when face (setq face (cl-list* :extend t face)))
            (unless (equal face (get-text-property eol 'face))
              (put-text-property eol (1+ eol) 'face face))
            (ebox--carry-mouse-face eol hover (get-text-property (1+ eol) 'mouse-face))
            (goto-char (1+ eol))
            (setq line (1+ line))))))))

(defun ebox--paint-all (mount)
  "Rewrite MOUNT's whole buffer from its root."
  (let* ((root (ebox-mount-root mount))
         (height (ebox-node-h root))
         (tracked (and (> (ebox-mount-lines mount) 0) (ebox--track-positions mount nil))))
    (ebox--writing
      (erase-buffer)
      (clrhash (ebox-mount-written mount))
      (let ((i 0))
        (while (< i height)
          (when (> i 0) (insert "\n"))
          (let ((parts (ebox--root-parts root i)))
            (apply #'insert parts)
            ;; Do not let the first rows of a large mount occupy every slot:
            ;; its remembered lines should follow subsequent local damage.
            (when (<= height ebox--written-max)
              (puthash i parts (ebox-mount-written mount))))
          (setq i (1+ i)))))
    (setf (ebox-mount-lines mount) height)
    (ebox--rebuild-anchors mount)
    (ebox--writing (save-excursion (ebox--extend-line-ends mount 0 height)))
    (setf (ebox-mount-tick mount) (buffer-modified-tick))
    (if tracked
        (ebox--restore-positions mount tracked nil)
      (goto-char (point-min)))))

(defun ebox--apply-edits (mount edits)
  "Write ordered line EDITS of MOUNT's root to its buffer."
  (let* ((root (ebox-mount-root mount))
         (tracked (ebox--track-positions mount edits)))
    ;; Remembered strings describe the buffer only while nothing else wrote it.
    (unless (eql (ebox-mount-tick mount) (buffer-modified-tick))
      (clrhash (ebox-mount-written mount)))
    (ebox--writing
      (save-excursion
        (dolist (edit edits)
          (let ((start (car edit)) (new (nth 2 edit)) lines)
            (dotimes (i new)
              (push (ebox--root-parts root (+ start i)) lines))
            (setq lines (nreverse lines))
            (ebox--replace-lines mount start (nth 1 edit) lines)
            ;; The newline before START may be new, and each rewritten
            ;; line may now end over another background.
            (ebox--extend-line-ends mount (max 0 (1- start)) (1+ new))))))
    (setf (ebox-mount-tick mount) (buffer-modified-tick))
    (ebox--restore-positions mount tracked edits)))

;;;; Flush

(defvar ebox-after-flush-functions nil
  "Abnormal hook run with each mount's buffer after a flush wrote it.")

(defun ebox-flush ()
  "Bring every queued mount's buffer up to date."
  (unless ebox--flushing
    (when ebox--queue (ebox--settle-measuring-frame))
    (let ((ebox--flushing t))
      (while ebox--queue
        (let ((mount (pop ebox--queue)))
          (setf (ebox-mount-queued mount) nil)
          (when (buffer-live-p (ebox-mount-buffer mount))
            (with-current-buffer (ebox-mount-buffer mount)
              (ebox--flush-mount mount))))))))

(defun ebox--flush-mount (mount)
  "Restyle, relayout and repaint MOUNT's dirty subtree."
  (let* ((root (ebox-mount-root mount))
         (ebox--current-mount mount)
         ;; Glyphs are measured under the mounting buffer's faces, so its
         ;; text scale and remappings select the sizes being laid out.
         (ebox--measure-buffer (ebox-mount-buffer mount))
         (ebox--active-metric-key (ebox--compute-metric-key))
         (ebox--active-metrics (ebox--display-metrics ebox--measure-buffer))
         (ebox--active-row-strut (let ((ebox--active-row-strut 'unset))
                                   (ebox--row-strut)))
         (ebox--vw (ebox-mount-vw mount))
         (ebox--vh (ebox-mount-vh mount))
         (ebox--damage (ebox-mount-report mount))
         (ebox--record t)
         ;; A reused tree may already have layout, but a new mount owns no
         ;; previous buffer generation or line coordinates to apply edits to.
         (fresh (or (zerop (ebox-mount-flushes mount))
                    (null (ebox-node-layout root))))
         (observer (ebox-mount-observer mount))
         (start (and observer (float-time))))
    (setf (ebox-mount-report mount) nil)
    (when (or ebox--damage (/= 0 (logand (ebox-node-dirty root) 15)))
      (ebox--style-pass root nil nil)
      (ebox--layout root ebox--vw (if (eq (ebox-node-tag root) 'text) 'shrink 'stretch) ebox--vh)
      (when (ebox-mount-anchored mount)
        (setf (ebox-mount-anchored mount)
              (ebox--place-anchored root (ebox-mount-anchored mount))))
      (setq ebox--damage (ebox--damage-prune ebox--damage))
      (dolist (damage ebox--damage)
        (ebox--uncache (ebox--damage-owner (car damage))))
      (let ((old-lines (ebox-mount-lines mount))
            (edits (if fresh 'full
                     (ebox--root-edits root ebox--damage
                                       (ebox-mount-lines mount)))))
        (cond
         ((eq edits 'full) (ebox--paint-all mount))
         (edits (ebox--apply-edits mount edits)))
        (cl-incf (ebox-mount-flushes mount))
        ;; Keep the raw ranges; `ebox--flush-report' builds the plist only
        ;; when an observer or `ebox-buffer-update-report' asks for it.
        (let ((last (if (eq edits 'full)
                        (cl-list* (ebox-mount-flushes mount) 'full
                               (list (list 0 old-lines (ebox-mount-lines mount))))
                      (cl-list* (ebox-mount-flushes mount) 'lines edits))))
          (if (not observer)
              (setf (ebox-mount-last-report mount) last)
            (let ((report (append (ebox--flush-report last)
                                  (list :duration-ms
                                        (* 1000.0 (- (float-time) start))))))
              (setf (ebox-mount-last-report mount) report)
              (funcall observer (ebox-mount-buffer mount) (copy-tree report))))))
      (ebox--sync-canvas mount)
      (run-hook-with-args 'ebox-after-flush-functions (ebox-mount-buffer mount)))))

(defun ebox-buffer-set-observer (buffer-or-name observer)
  "Call OBSERVER with the buffer and a report plist after each flush.
The report contains :provider (always ebox), :strategy (lines or full),
:edits, :lines, :ranges, :flush and :duration-ms.
:ranges lists the written (START OLD NEW) line replacements in
application order: START counts lines after the preceding replacements,
OLD lines there were replaced by NEW lines.  Nil OBSERVER removes
observation."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (unless mount (user-error "No mounted Ebox tree in %s" buffer-or-name))
    (setf (ebox-mount-observer mount) observer)))

(defun ebox--flush-report (last)
  "Return the report plist for LAST, a (FLUSH STRATEGY . RANGES) record."
  (let ((ranges (cddr last)))
    (list :provider 'ebox
          :strategy (cadr last)
          :edits (length ranges)
          :lines (let ((n 0)) (dolist (e ranges n) (setq n (+ n (nth 2 e)))))
          :ranges (copy-tree ranges)
          :flush (car last))))

(defun ebox-buffer-update-report (&optional buffer-or-name)
  "Return a copy of the report of BUFFER-OR-NAME's latest flush, or nil."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (unless mount (user-error "No mounted Ebox tree in %s" buffer-or-name))
    (let ((last (ebox-mount-last-report mount)))
      (if (keywordp (car-safe last))
          (copy-tree last)
        (and last (ebox--flush-report last))))))

;;;; Rendering and mounting

(defun ebox--input-root (input)
  "Return a root node for INPUT, a node or author form."
  (if (ebox-node-p input) input (ebox-build input)))

(defun ebox-render (input)
  "Render INPUT, a node or author form, and return its lines as a string.
The viewport is `ebox-viewport-width' by `ebox-viewport-height'.  Glyphs
are measured under the current buffer's faces, so its text scale applies."
  (let* ((root (ebox--input-root input))
         (ebox--vw (ebox--default-viewport-width))
         (ebox--vh (ebox--default-viewport-height))
         (ebox--measure-buffer (current-buffer))
         (ebox--active-metric-key (ebox--compute-metric-key))
         (ebox--active-metrics (ebox--display-metrics ebox--measure-buffer))
         (ebox--record nil)
         (ebox--damage nil))
    (when (ebox-node-parent root)
      (signal 'ebox-error (list "Cannot render a non-root node")))
    (ebox--settle-measuring-frame)
    (ebox--style-pass root nil nil)
    (ebox--layout root ebox--vw (if (eq (ebox-node-tag root) 'text) 'shrink 'stretch) ebox--vh)
    (ebox--place-anchored root (ebox--collect-anchored root))
    (ebox--carry-string-mouse-face
     (mapconcat (lambda (i) (apply #'concat (ebox--root-parts root i)))
                (number-sequence 0 (1- (ebox-node-h root))) "\n"))))

(defun ebox-viewport-window-width (window)
  "Return the pixel width WINDOW offers to a mounted tree."
  (when (window-live-p window)
    (let* ((outer (window-pixel-width window))
           (body (window-body-width window t))
           (fringes (window-fringes window))
           (margins (window-margins window))
           (decoration (+ (or (nth 0 fringes) 0) (or (nth 1 fringes) 0)
                          (or (window-scroll-bar-width window) 0)
                          (* (+ (or (car margins) 0) (or (cdr margins) 0))
                             (frame-char-width (window-frame window)))))
           (expected (max 0 (- outer decoration)))
           (tolerance (max 1 (* 2 (frame-char-width (window-frame window)))))
           (width (if (<= (abs (- body expected)) tolerance) body expected)))
      ;; Without a right fringe, Emacs reserves the last text column for the
      ;; truncation glyph.  A graphical line whose pixels reach that column is
      ;; truncated too, so content must end strictly before it or the line
      ;; displays as `$'.
      (if (zerop (or (nth 1 fringes) 0))
          (let ((frame (window-frame window)))
            (max 0 (- width (frame-char-width frame)
                      (if (display-graphic-p frame) 1 0))))
        width))))

(defun ebox--display-window (buffer)
  "Return the window whose size defines BUFFER's viewport."
  (or (and (eq (window-buffer (selected-window)) buffer) (selected-window))
      (get-buffer-window buffer (selected-frame))
      (get-buffer-window buffer t)))

(defun ebox-viewport-measure (buffer-or-name &optional width height)
  "Return the (WIDTH . HEIGHT) viewport BUFFER-OR-NAME's display offers.
Non-nil WIDTH or HEIGHT fixes that dimension, as for a fixed mount."
  (let ((window (ebox--display-window (get-buffer buffer-or-name))))
    (cons (or width
              ebox-viewport-width
              (and window (ebox-viewport-window-width window))
              (ebox--default-viewport-width))
          (or height
              ebox-viewport-height
              (and window
                   (floor (window-body-height window t)
                          (plist-get (ebox--display-metrics buffer-or-name) :line-height)))
              (ebox--default-viewport-height)))))

(defun ebox--measure-viewport (mount)
  "Return (WIDTH . HEIGHT) for MOUNT's current display."
  (ebox-viewport-measure (ebox-mount-buffer mount)
                         (ebox-mount-fixed-vw mount) (ebox-mount-fixed-vh mount)))

(declare-function ebox-buffer-mode "ebox-interaction" (&optional arg))

(defun ebox-mount (buffer-or-name input &rest options)
  "Mount INPUT, a root node or author form, in BUFFER-OR-NAME and return the root.
The buffer's text is replaced and then owned by Ebox, and its default
background follows the root's background color.  OPTIONS may contain
:width and :height to fix the viewport instead of following the window.
:observer is a function of buffer and report, installed before the first
flush; nil disables observation, as with `ebox-buffer-set-observer'."
  (let ((observer (plist-get options :observer)))
    (unless (or (null observer) (functionp observer))
      (signal 'wrong-type-argument (list 'functionp observer))))
  (let* ((buffer (get-buffer-create buffer-or-name))
         (root (ebox--input-root input)))
    (when (ebox-node-parent root)
      (signal 'ebox-error (list "Cannot mount a non-root node")))
    (with-current-buffer buffer
      (when ebox--buffer-mount (ebox-unmount-buffer buffer))
      (let ((mount (ebox-mount--make :root root :buffer buffer
                                     :fixed-vw (plist-get options :width)
                                     :fixed-vh (plist-get options :height)
                                     :observer (plist-get options :observer)
                                     :display-saved (ebox--own-display))))
        (pcase-let ((`(,w . ,h) (ebox--measure-viewport mount)))
          (setf (ebox-mount-vw mount) w (ebox-mount-vh mount) h))
        (setf (ebox-node-mount root) mount
              (ebox-mount-anchored mount) (ebox--collect-anchored root))
        (setq ebox--buffer-mount mount)
        (add-hook 'kill-buffer-hook #'ebox--buffer-killed nil t)
        (ebox-buffer-mode 1)
        (setf (ebox-node-dirty root) (logior (ebox-node-dirty root) 15))
        (let ((ebox--batch-depth 0))
          (setf (ebox-mount-queued mount) t)
          (push mount ebox--queue)
          (ebox-flush))))
    root))

(defun ebox-render-to-buffer (buffer-or-name input &rest options)
  "Mount INPUT in BUFFER-OR-NAME with OPTIONS and return the buffer.
See `ebox-mount'."
  (apply #'ebox-mount buffer-or-name input options)
  (get-buffer buffer-or-name))

(defun ebox--release-buffer-mount (buffer)
  "Run BUFFER's unmount hooks and release its mount state.
Return non-nil when the buffer had a mount."
  (when ebox--buffer-mount
    (let ((mount ebox--buffer-mount))
      (run-hook-with-args 'ebox-unmount-functions buffer)
      (ebox--restore-display (ebox-mount-display-saved mount))
      (ebox--release-canvas mount)
      (ebox--release-mount mount)
      (setq ebox--buffer-mount nil)
      (remove-hook 'kill-buffer-hook #'ebox--buffer-killed t)
      t)))

(defun ebox--buffer-killed ()
  "Release the mount of the buffer being killed."
  (ebox--release-buffer-mount (current-buffer)))

(declare-function ebox--input-release "ebox-interaction" (session))

(defun ebox--release-mount (mount)
  "Detach MOUNT from its root and anchors."
  (when (ebox-mount-session mount)
    (ebox--input-release (ebox-mount-session mount)))
  (mapc (lambda (a) (set-marker (cdr a) nil)) (ebox-mount-anchors mount))
  (setf (ebox-mount-anchors mount) [])
  (setq ebox--queue (delq mount ebox--queue))
  (let ((root (ebox-mount-root mount)))
    (when (eq (ebox-node-mount root) mount)
      (setf (ebox-node-mount root) nil))))

(defvar ebox-unmount-functions nil
  "Abnormal hook run with a buffer whose mount is being released.")

(defun ebox-unmount-buffer (&optional buffer-or-name)
  "Release the mount of BUFFER-OR-NAME, keeping its text.  Return non-nil if any."
  (let ((buffer (if buffer-or-name (get-buffer buffer-or-name) (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (ebox--release-buffer-mount buffer)
          (ebox-buffer-mode -1)
          t)))))

(defvar ebox-viewport-prepare-functions nil
  "Abnormal hook run with a mounted buffer after its viewport size updated.
It runs before the relayout flushes so reactive layers can apply
viewport-dependent tree changes in the same flush.")

(defvar ebox-viewport-change-functions nil
  "Abnormal hook run with a mounted buffer after its viewport size changed.
It runs once the relayout for the new size has settled.")

(defun ebox-mount-set-viewport (buffer-or-name width height)
  "Lay out BUFFER-OR-NAME's mount for a WIDTH by HEIGHT viewport.
Nil WIDTH or HEIGHT follows the display window."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (when mount
      (setf (ebox-mount-fixed-vw mount) width
            (ebox-mount-fixed-vh mount) height)
      (ebox-refit buffer-or-name))))

(defun ebox--fit-window-start (window)
  "Start WINDOW at its buffer start when the whole buffer fits its body.
A window that was shorter for a while (the echo area or a popup borrowed
its lines) may have scrolled a window-sized tree; it returns to the top
once the tree fits again.  Y-LIMIT includes the window's header-line and
tab-line heights because `window-text-pixel-size' stops against window-top
Y coordinates."
  (when (> (window-start window) (point-min))
    (let* ((body (window-body-height window t))
           (limit (+ body
                     (window-header-line-height window)
                     (window-tab-line-height window)
                     1)))
      (when (<= (cdr (window-text-pixel-size window (point-min) (point-max)
                                             nil limit))
                body)
        (set-window-start window (point-min) t)))))

(defun ebox-refit (&optional buffer-or-name)
  "Relayout BUFFER-OR-NAME's mount when its viewport size changed.
A window showing the whole buffer starts at its top again.  Return non-nil
when the layout changed."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (when mount
      (with-current-buffer (ebox-mount-buffer mount)
        (prog1
            (pcase-let ((`(,w . ,h) (ebox--measure-viewport mount)))
              (unless (and (eql w (ebox-mount-vw mount)) (eql h (ebox-mount-vh mount)))
		(let ((root (ebox-mount-root mount))
                      (width (not (eql w (ebox-mount-vw mount))))
                      (height (not (eql h (ebox-mount-vh mount)))))
		  (setf (ebox-mount-vw mount) w (ebox-mount-vh mount) h)
		  ;; The root's available width is the viewport; its height only
		  ;; matters when the root's own block size follows it.
		  (when (or width (null (ebox-node-cs root)) (ebox-cs-vcbh (ebox-node-cs root)))
                    (ebox--mark root ebox--d-layout))
		  (maphash (lambda (node units)
                             (when (and (eq (ebox-node-root node) root)
					(or (and width (memq 'vw units))
                                            (and height (memq 'vh units))))
                               (ebox--mark node ebox--d-layout)))
			   ebox--viewport-nodes)
		  (ebox-with-batch
		    (run-hook-with-args 'ebox-viewport-prepare-functions (ebox-mount-buffer mount)))
		  (ebox--settle))
		(run-hook-with-args 'ebox-viewport-change-functions (ebox-mount-buffer mount))
		t))
          (dolist (window (get-buffer-window-list nil nil t))
            (ebox--fit-window-start window)))))))

(defun ebox-mount-viewport (&optional buffer-or-name)
  "Return (WIDTH . HEIGHT) of BUFFER-OR-NAME's mounted viewport, or nil."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (and mount (cons (ebox-mount-vw mount) (ebox-mount-vh mount)))))

(defun ebox-mount-flush-count (&optional buffer-or-name)
  "Return the number of flushes that wrote BUFFER-OR-NAME's mount."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (if mount (ebox-mount-flushes mount) 0)))

;;;; Geometry queries

(defun ebox-node-root-line (node)
  "Return the root line of NODE's border-box top, or nil when not laid out."
  (when (and (ebox-node-layout node) (ebox-node-cs node))
    (+ (ebox--item-top-in-root node) (ebox-geo-mt (ebox-node-layout node)))))

(defun ebox-node-geometry (node)
  "Return NODE's border box as a plist (:x :y :width :height).
X and WIDTH are pixels, Y and HEIGHT root lines; nil when NODE is not laid out."
  (let ((geo (ebox-node-layout node)))
    (when (and geo (ebox-node-cs node))
      (let ((xy (ebox--root-xy node)))
        (list :x (+ (car xy) (ebox-geo-ml geo))
              :y (+ (ebox--item-top-in-root node) (ebox-geo-mt geo))
              :width (ebox-geo-bw geo)
              :height (ebox-geo-bh geo))))))

(defun ebox-node-box-metrics (node)
  "Return resolved box-model metrics for laid-out NODE, or nil.
Return a detached plist with `:x', `:y', `:margin', `:border', `:padding',
`:border-box', `:content-box', `:viewport-height', `:scroll', `:layout-kind',
`:gap' and `:natural-width'.  Horizontal sizes are pixels and vertical sizes
are root lines."
  (ebox--check-node node)
  (let ((geo (ebox-node-layout node))
        (cs (ebox-node-cs node))
        (rect (ebox-node-geometry node)))
    (when (and geo cs rect)
      (list :x (plist-get rect :x)
            :y (plist-get rect :y)
            :margin (list :top (ebox-geo-mt geo)
                          :right (ebox-geo-mr geo)
                          :bottom (ebox-geo-mb geo)
                          :left (ebox-geo-ml geo))
            :border (list :top (if (ebox-cs-btop cs) 1 0)
                          :right (ebox-geo-br geo)
                          :bottom (if (ebox-cs-bbot cs) 1 0)
                          :left (ebox-geo-bl geo))
            :padding (list :top (ebox-geo-pt geo)
                           :right (ebox-geo-pr geo)
                           :bottom (ebox-geo-pb geo)
                           :left (ebox-geo-pl geo))
            :border-box (list :width (ebox-geo-bw geo)
                              :height (ebox-geo-bh geo))
            :content-box (list :width (ebox-geo-cw geo)
                               :height (ebox-geo-ch geo))
            :viewport-height (ebox-geo-vh geo)
            :scroll (ebox-geo-scroll geo)
            :layout-kind (ebox-geo-kind geo)
            :gap (ebox-geo-gap geo)
            :natural-width (ebox-geo-nat geo)))))

(defun ebox--clip-vertical-band (node mount)
  "Return (TOP . BOTTOM) 0-based visible line band for NODE inside MOUNT."
  (let ((top 0)
        (bot (ebox-mount-lines mount))
        (cur (ebox-node-parent node)))
    (while cur
      (when-let* ((cs (ebox-node-cs cur))
                  ((memq (ebox-cs-overflow cs) '(scroll auto hidden)))
                  (rect (ebox-node-geometry cur)))
        (let ((ct (plist-get rect :y))
              (cb (+ (plist-get rect :y) (max 0 (plist-get rect :height)))))
          (setq top (max top ct)
                bot (min bot cb))))
      (setq cur (ebox-node-parent cur)))
    (cons top bot)))

(defun ebox--text-row-spans (node mount)
  "Return per-line (LINE BEG . END) spans for text NODE in MOUNT."
  (let* ((parent (ebox-node-parent node))
         (geometry (and parent (ebox-node-geometry parent))))
    (when (and geometry (> (plist-get geometry :height) 0))
      (pcase-let* ((`(,clip-top . ,clip-bot) (ebox--clip-vertical-band parent mount))
                   (y (plist-get geometry :y))
                   (top (max y clip-top))
                   (bot (min (+ y (plist-get geometry :height)) clip-bot))
                   (spans nil))
        (when (< top bot)
          (with-current-buffer (ebox-mount-buffer mount)
            (save-excursion
              (ebox--goto-line mount top)
              (let ((row top))
                (while (< row bot)
                  (let* ((bol (line-beginning-position))
                         (eol (line-end-position))
                         (run (text-property-any bol eol 'ebox-node node)))
                    (when run
                      (let ((stop eol))
                        (while (and (> stop run)
                                    (not (eq (get-text-property (1- stop) 'ebox-node) node)))
                          (setq stop (1- stop)))
                        (while (and (> stop run)
                                    (eq (car-safe (get-text-property (1- stop) 'display)) 'space))
                          (setq stop (1- stop)))
                        (when (> stop run)
                          (push (cons row (cons run stop)) spans)))))
                  (setq row (1+ row))
                  (when (< row bot)
                    (forward-line 1)))))))
        (nreverse spans)))))

(defun ebox-node-row-spans (node)
  "Return exact painted (LINE BEG . END) buffer spans for each visible row of NODE.
LINE is 0-based.  For multi-column Flex or Grid layouts, each row's (BEG . END)
covers only NODE's horizontal pixel extent on that line and respects enclosing
clipping ancestors.  Return nil when NODE is unmounted, hidden or clipped out."
  (ebox--check-node node)
  (let ((mount (ebox--mount-of node)))
    (when mount
      (if (ebox-node-text-p node)
          (ebox--text-row-spans node mount)
        (let ((geometry (ebox-node-geometry node)))
          (when (and geometry (> (plist-get geometry :height) 0)
                     (> (plist-get geometry :width) 0)
                     (ebox--node-slotted-p node))
            (pcase-let* ((`(,clip-top . ,clip-bot) (ebox--clip-vertical-band node mount))
                         (y (plist-get geometry :y))
                         (top (max y clip-top))
                         (bot (min (+ y (plist-get geometry :height)) clip-bot))
                         (x (plist-get geometry :x))
                         (right (+ x (plist-get geometry :width)))
                         (spans nil))
              (when (< top bot)
                (with-current-buffer (ebox-mount-buffer mount)
                  (save-excursion
                    (ebox--goto-line mount top)
                    (let ((row top))
                      (while (< row bot)
                        (let* ((bol (line-beginning-position))
                               (eol (line-end-position))
                               (beg (min eol (max bol (ebox--pos-at-x bol x))))
                               (end (min eol (max beg (ebox--pos-at-x bol right)))))
                          (when (< beg end)
                            (push (cons row (cons beg end)) spans)))
                        (setq row (1+ row))
                        (when (< row bot)
                          (forward-line 1)))))))
              (nreverse spans))))))))

(defun ebox--pos-at-x (bol x)
  "Return the buffer position at pixel X of the line starting at BOL."
  (let* ((eol (save-excursion (goto-char bol) (line-end-position)))
         (string (buffer-substring bol eol)))
    (+ bol (car (ebox--px-cut string x 0 0)))))

(defun ebox--text-bounds (node mount &optional all-lines)
  "Return (START . END) of text NODE's first painted run in MOUNT, or nil.
With ALL-LINES, END is the end of NODE's last painted run."
  (let ((geometry (and (ebox-node-parent node) (ebox-node-geometry (ebox-node-parent node)))))
    (when (and geometry (> (plist-get geometry :height) 0)
               (< (plist-get geometry :y) (ebox-mount-lines mount)))
      (with-current-buffer (ebox-mount-buffer mount)
        (save-excursion
          (ebox--goto-line mount (plist-get geometry :y))
          (let* ((start (point))
                 (end (progn (forward-line (plist-get geometry :height)) (point)))
                 (run (text-property-any start end 'ebox-node node)))
            (when run
              (let ((stop (if all-lines
                              (let ((last end))
                                (while (not (eq (get-text-property (1- last) 'ebox-node) node))
                                  (setq last (1- last)))
                                last)
                            (or (text-property-not-all run end 'ebox-node node) end))))
                ;; An interactive text node also owns the alignment fill
                ;; after its glyphs; that fill is not part of its text.
                (while (and (> stop run)
                            (eq (car-safe (get-text-property (1- stop) 'display)) 'space))
                  (setq stop (1- stop)))
                (and (> stop run) (cons run stop))))))))))

(defun ebox--node-visible-p (node)
  "Return non-nil when NODE and its ancestors paint.
An overlay whose anchor is unavailable is laid out but never placed."
  (let ((ok t))
    (while (and ok node)
      (when (or (null (ebox-node-cs node)) (ebox--hidden-p node)
                (and (ebox--abs-p node) (not (ebox-node-placed node))))
        (setq ok nil))
      (setq node (ebox-node-parent node)))
    ok))

(defun ebox--node-slotted-p (node)
  "Return non-nil when NODE owns cells in its mount's buffer.
A hidden box in flow keeps its blank slot; a hidden or unplaced overlay, or
anything inside one, owns no cells."
  (let ((ok t))
    (while (and ok node)
      (when (or (null (ebox-node-cs node))
                (and (ebox--abs-p node)
                     (or (ebox--hidden-p node) (not (ebox-node-placed node)))))
        (setq ok nil))
      (setq node (ebox-node-parent node)))
    ok))

(defun ebox-node-bounds (node &optional all-lines)
  "Return (START . END) buffer positions of NODE's first painted line.
For a box this spans its first border-box line from its first visible cell;
for a text node, its first painted run.  With ALL-LINES, END instead ends
NODE's last painted line, so the span covers every painted row.  A hidden
box in flow reports its blank slot.  Return nil when NODE owns no cells in a
live mount, including when overlays cover its whole first line."
  (let ((mount (ebox--mount-of node))
        (geometry (ebox-node-geometry node)))
    (if (and mount (ebox-node-text-p node))
        (ebox--text-bounds node mount all-lines)
      (when (and mount geometry (> (plist-get geometry :height) 0)
                 (< (plist-get geometry :y) (ebox-mount-lines mount))
                 (ebox--node-slotted-p node))
        (let ((x (ebox--uncovered-x node mount geometry))
              (y (plist-get geometry :y))
              (right (+ (plist-get geometry :x) (plist-get geometry :width))))
          (when x
            (with-current-buffer (ebox-mount-buffer mount)
              (save-excursion
                (ebox--goto-line mount y)
                (let ((start (ebox--pos-at-x (point) x)))
                  (when all-lines
                    (forward-line (1- (min (plist-get geometry :height)
                                           (- (ebox-mount-lines mount) y)))))
                  (cons start (ebox--pos-at-x (line-beginning-position) right)))))))))))

(defun ebox--uncovered-x (node mount geometry)
  "Return the first pixel X on NODE's first line not covered by an overlay.
GEOMETRY is NODE's border box.  A cell is covered when the hit test resolves
it inside an overlay that NODE does not belong to; return nil when every cell
of the first line is covered."
  (let* ((line (plist-get geometry :y))
         (x (plist-get geometry :x))
         (end (+ x (plist-get geometry :width)))
         (step (max 1 (ebox--ch (ebox-node-cs node))))
         (root (ebox-mount-root mount))
         found)
    (while (and (not found) (< x end))
      (let ((hit (ebox--hit root line x)) covered)
        ;; NODE's own overlays and descendants paint NODE, not a cover.
        (when (and hit (ebox-node-ancestor-p node hit)) (setq hit nil))
        (while (and hit (not (ebox-node-ancestor-p hit node)))
          (when (and (ebox-node-cs hit) (ebox--abs-p hit)) (setq covered t))
          (setq hit (ebox-node-parent hit)))
        (if covered (setq x (+ x step)) (setq found x))))
    found))

(defun ebox-node-position (node)
  "Return the buffer position of NODE's first painted character, or nil."
  (car (ebox-node-bounds node)))

(defun ebox-node-at (&optional position buffer-or-name)
  "Return the innermost node painted at POSITION in BUFFER-OR-NAME.
POSITION defaults to point; the buffer defaults to the current buffer.
Interactive inline nodes are found through their painted properties; other
positions resolve to the innermost box covering the cell."
  (let ((buffer (if buffer-or-name (get-buffer buffer-or-name) (current-buffer))))
    (with-current-buffer buffer
      (let* ((pos (or position (point)))
             (node (and (< pos (point-max)) (get-text-property pos 'ebox-node))))
        (if (and node (ebox-node-text-p node))
            node
          ;; A box's property also covers the blank cells of its descendants,
          ;; so a box inside it that covers the cell is the innermost node.
          (let* ((mount ebox--buffer-mount)
                 (hit (when (and mount (ebox-node-layout (ebox-mount-root mount)))
                        (let* ((bol (save-excursion (goto-char pos)
                                                    (line-beginning-position)))
                               (line (ebox--line-of mount pos))
                               (x (if (= bol pos) 0
                                    (ebox--measure-raw (buffer-substring bol pos)))))
                          (ebox--hit (ebox-mount-root mount) line x)))))
            (if (and node hit (not (ebox-node-ancestor-p node hit)))
                node
              (or hit node))))))))

(defun ebox--hit (node line x)
  "Return the innermost node of NODE's margin box covering LINE and pixel X."
  (let* ((geo (ebox-node-layout node))
         (mt (ebox-geo-mt geo)) (ml (ebox-geo-ml geo))
         (hit nil))
    ;; Hit the reverse of paint order: higher z first, and among equal z the
    ;; later overlay, which paints on top.
    (dolist (overlay (nreverse
                      (sort (copy-sequence (ebox-node-overlays node))
                            (lambda (a b) (< (ebox-cs-z (ebox-node-cs a))
                                             (ebox-cs-z (ebox-node-cs b)))))))
      (when (and (not hit) (ebox-node-placed overlay) (ebox-node-layout overlay)
                 (eq (ebox-node-host overlay) node)
                 (not (ebox--hidden-p overlay)))
        (let ((oy (- line mt (ebox-node-y overlay)))
              (ox (- x ml (ebox-node-x overlay))))
          (when (and (>= oy 0) (< oy (ebox-node-h overlay))
                     (>= ox 0) (< ox (ebox-node-w overlay)))
            (setq hit (ebox--hit overlay oy ox))))))
    (or hit
        (let* ((bi (- line mt))
               (ci (- bi (ebox-geo-pt geo)))
               (cx (- x ml (ebox-geo-bl geo) (ebox-geo-pl geo)))
               (items (ebox-geo-items geo)))
          (when (and (>= ci 0) (< ci (ebox-geo-vh geo)) (>= cx 0) (< cx (ebox-geo-cw geo))
                     (memq (ebox-geo-kind geo) '(stack pos)))
            (setq ci (+ ci (ebox-geo-scroll geo)))
            (let ((candidates
                   (if (eq (ebox-geo-kind geo) 'stack)
                       (let ((item (ebox--find-item geo ci))) (and item (list item)))
                     (append (substring items 0 (ebox-geo-n geo)) nil))))
              (dolist (item candidates)
                (when (and (not hit) (ebox-node-p item))
                  (let ((iy (- ci (ebox--item-y item))) (ix (- cx (ebox-node-x item))))
                    (when (and (>= iy 0) (< iy (ebox-node-h item))
                               (>= ix 0) (< ix (ebox-node-w item)))
                      (setq hit (ebox--hit item iy ix))))))))
          hit)
        node)))

(provide 'ebox-buffer)

;;; ebox-buffer.el ends here
