;;; ebox-node.el --- Retained Ebox nodes and computed styles -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One mutable retained tree is the only rendering state.  Each node owns its
;; author facts (tag, compiled declarations, selector facts, interaction
;; properties), a shared computed style and its last layout.  Mutations mark
;; dirty bits and enqueue the owning mount; `ebox-flush' (see ebox-buffer)
;; brings the tree and buffer up to date.  Computed styles are hash-consed by
;; parent style, declarations and selector facts, so unchanged subtrees reuse
;; one object and identical rows share every derived face.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ecss)
(require 'ebox-size)
(require 'ebox-style)
(require 'ebox-measure)

(define-error 'ebox-error "Ebox error")

(defconst ebox--box-tags '(box row column flex grid)
  "Tags that own child nodes.")

(defconst ebox-interaction-properties
  '(:help-echo :pointer :hover-style :hover-content :keymap :tab-index :disabled
    :drag-lock-modifier :hover-group :swipe :scroll :focus-group :focus-scope)
  "Node capabilities accepted outside the Ebox style schema.")

(defconst ebox--meta-properties
  '(:key :class :id :attributes :states :ecss :ecss-file :ecss-scopes
    :ecss-scope-roots :defaults :data :image :source)
  "Node facts that are neither style nor interaction properties.")

;;;; Node

(defvar cl--optimize-safety)

(defmacro ebox--defstruct (&rest args)
  "Define an internal `cl-defstruct' record from ARGS.
Compiled accessors skip the record type check: callers only pass records
of the type, and public entry points validate their arguments."
  (let ((cl--optimize-safety 0))
    (macroexpand-1 `(cl-defstruct ,@args))))

;;;; Chunked sequences

;; Children and stacked layout items are stored in runs of at most
;; `ebox--run-max' elements.  Each element records its run and position, so
;; insertion, deletion and index lookup cost O(run size + run count), about
;; O(sqrt N), instead of shifting every later element of a flat vector.

(ebox--defstruct (ebox-run (:constructor ebox-run--make) (:copier nil))
  "Chunk of a sequence.
VEC holds the chunk's N elements, START is the sequence index of its first
element and DY is a line offset stacked items in the chunk add to their
stored y."
  vec (n 0) (start 0) (dy 0))

(ebox--defstruct (ebox-seq (:constructor ebox-seq--make) (:copier nil))
  "Sequence of NR runs holding N elements."
  (runs (make-vector 2 nil)) (nr 0) (n 0))

(defconst ebox--run-max 64
  "Maximum number of elements in one run.")

(defconst ebox--run-fill 32
  "Number of elements per run when a sequence is built.")

(defmacro ebox--seq-do (spec &rest body)
  "Bind (VAR SEQ) to each element of SEQ, which may be nil, and run BODY."
  (declare (indent 1))
  (let ((seq (make-symbol "seq")) (runs (make-symbol "runs")) (r (make-symbol "r"))
        (vec (make-symbol "vec")) (i (make-symbol "i")) (run (make-symbol "run")))
    `(let ((,seq ,(cadr spec)))
       (when ,seq
         (let ((,runs (ebox-seq-runs ,seq)))
           (dotimes (,r (ebox-seq-nr ,seq))
             (let* ((,run (aref ,runs ,r)) (,vec (ebox-run-vec ,run)))
               (dotimes (,i (ebox-run-n ,run))
                 (let ((,(car spec) (aref ,vec ,i)))
                   ,@body)))))))))

(defun ebox--seq-build (elements ref)
  "Return a sequence of the list ELEMENTS.
REF is called with each element, its run, its position in the run and nil."
  (let* ((n (length elements))
         (nr (/ (+ n ebox--run-fill -1) ebox--run-fill))
         (runs (make-vector (max 2 nr) nil))
         (start 0))
    (dotimes (r nr)
      (let* ((count (min ebox--run-fill (- n start)))
             (vec (make-vector (if (< r (1- nr)) ebox--run-max (max 2 count)) nil))
             (run (ebox-run--make :vec vec :n count :start start)))
        (dotimes (i count)
          (let ((element (pop elements)))
            (aset vec i element)
            (funcall ref element run i nil)))
        (aset runs r run)
        (setq start (+ start count))))
    (ebox-seq--make :runs runs :nr nr :n n)))

(defun ebox--seq-run-index (seq index)
  "Return the position in SEQ's runs of the run holding INDEX.
INDEX equal to the length selects the last run; an empty SEQ returns nil."
  (let ((runs (ebox-seq-runs seq)) (lo 0) (hi (1- (ebox-seq-nr seq))))
    (when (>= hi 0)
      (while (< lo hi)
        (let ((mid (/ (+ lo hi 1) 2)))
          (if (<= (ebox-run-start (aref runs mid)) index)
              (setq lo mid)
            (setq hi (1- mid)))))
      lo)))

(defun ebox--seq-ref (seq index)
  "Return SEQ's element at INDEX, or nil when out of range."
  (when (and seq (>= index 0) (< index (ebox-seq-n seq)))
    (let ((run (aref (ebox-seq-runs seq) (ebox--seq-run-index seq index))))
      (aref (ebox-run-vec run) (- index (ebox-run-start run))))))

(defun ebox--seq-find-run (seq run)
  "Return RUN's position in SEQ's runs, or nil."
  (when (> (ebox-seq-nr seq) 0)
    (let ((r (ebox--seq-run-index seq (ebox-run-start run))) (runs (ebox-seq-runs seq)))
      ;; A run emptied by a deletion shares its start with its successor.
      (while (and (> r 0) (not (eq (aref runs r) run))) (setq r (1- r)))
      (unless (eq (aref runs r) run)
        (setq r (cl-position run runs)))
      r)))

(defun ebox--seq-open-run (seq r run)
  "Insert RUN at position R of SEQ's runs."
  (let* ((runs (ebox-seq-runs seq)) (nr (ebox-seq-nr seq)))
    (when (= nr (length runs))
      (let ((grown (make-vector (* 2 nr) nil)))
        (dotimes (i nr) (aset grown i (aref runs i)))
        (setf (ebox-seq-runs seq) grown runs grown)))
    (let ((i nr))
      (while (> i r) (aset runs i (aref runs (1- i))) (setq i (1- i))))
    (aset runs r run)
    (setf (ebox-seq-nr seq) (1+ nr))))

(defun ebox--seq-close-run (seq r)
  "Remove the run at position R of SEQ's runs."
  (let* ((runs (ebox-seq-runs seq)) (nr (1- (ebox-seq-nr seq))) (i r))
    (while (< i nr) (aset runs i (aref runs (1+ i))) (setq i (1+ i)))
    (aset runs nr nil)
    (setf (ebox-seq-nr seq) nr)))

(defun ebox--seq-shift-starts (seq r delta)
  "Add DELTA to the start of SEQ's runs from position R on."
  (let ((runs (ebox-seq-runs seq)) (nr (ebox-seq-nr seq)))
    (while (< r nr)
      (let ((run (aref runs r)))
        (setf (ebox-run-start run) (+ (ebox-run-start run) delta)))
      (setq r (1+ r)))))

(defun ebox--seq-insert (seq index element ref)
  "Insert ELEMENT at INDEX of SEQ and return its run.
REF is called with every element whose run or position changes, its new
run and position and its previous run, which is nil for ELEMENT."
  (let ((r (ebox--seq-run-index seq index)) run pos)
    (if (null r)
        (progn (setq run (ebox-run--make :vec (make-vector 2 nil)) r 0 pos 0)
               (ebox--seq-open-run seq 0 run))
      (setq run (aref (ebox-seq-runs seq) r)
            pos (- index (ebox-run-start run))))
    (let ((n (ebox-run-n run)) (vec (ebox-run-vec run)))
      (when (= n (length vec))
        (if (< n ebox--run-max)
            (let ((grown (make-vector (min ebox--run-max (* 2 n)) nil)))
              (dotimes (i n) (aset grown i (aref vec i)))
              (setf (ebox-run-vec run) grown vec grown))
          (let* ((half (/ n 2))
                 (next (ebox-run--make :vec (make-vector ebox--run-max nil) :n (- n half)
                                       :start (+ (ebox-run-start run) half)
                                       :dy (ebox-run-dy run)))
                 (nvec (ebox-run-vec next)))
            (dotimes (i (- n half))
              (let ((moved (aref vec (+ half i))))
                (aset nvec i moved)
                (aset vec (+ half i) nil)
                (funcall ref moved next i run)))
            (setf (ebox-run-n run) half)
            (ebox--seq-open-run seq (1+ r) next)
            (when (> pos half)
              (setq run next pos (- pos half) vec nvec r (1+ r)))
            (setq n (ebox-run-n run)))))
      (let ((i n))
        (while (> i pos)
          (let ((moved (aref vec (1- i))))
            (aset vec i moved)
            (funcall ref moved run i run))
          (setq i (1- i))))
      (aset vec pos element)
      (setf (ebox-run-n run) (1+ n))
      (funcall ref element run pos nil)
      (ebox--seq-shift-starts seq (1+ r) 1)
      (setf (ebox-seq-n seq) (1+ (ebox-seq-n seq)))
      run)))

(defun ebox--seq-delete (seq run pos ref)
  "Delete the element at POS of RUN in SEQ.
REF is called as in `ebox--seq-insert' for every remaining element whose
run or position changes."
  (let* ((r (ebox--seq-find-run seq run))
         (vec (ebox-run-vec run))
         (n (1- (ebox-run-n run)))
         (i pos))
    (while (< i n)
      (let ((moved (aref vec (1+ i))))
        (aset vec i moved)
        (funcall ref moved run i run))
      (setq i (1+ i)))
    (aset vec n nil)
    (setf (ebox-run-n run) n
          (ebox-seq-n seq) (1- (ebox-seq-n seq)))
    (ebox--seq-shift-starts seq (1+ r) -1)
    (cond
     ((zerop n) (ebox--seq-close-run seq r))
     ((< n (/ ebox--run-max 4))
      ;; Merge a sparse run into its successor's free space, bounding the
      ;; run count by the element count.
      (let ((next (and (< (1+ r) (ebox-seq-nr seq)) (aref (ebox-seq-runs seq) (1+ r)))))
        (when (and next (<= (+ n (ebox-run-n next)) (/ ebox--run-max 2)))
          (let* ((m (ebox-run-n next)) (total (+ n m))
                 (merged (make-vector ebox--run-max nil)))
            (dotimes (j n) (aset merged j (aref vec j)))
            (dotimes (j m)
              (let ((moved (aref (ebox-run-vec next) j)))
                (aset merged (+ n j) moved)
                (funcall ref moved run (+ n j) next)))
            (setf (ebox-run-vec run) merged (ebox-run-n run) total)
            (ebox--seq-close-run seq (1+ r)))))))))

(ebox--defstruct (ebox-node (:constructor ebox-node--make) (:copier nil))
  "One retained Ebox node.
KIDS is a sequence of children; KRUN and KPOS locate the node in its
parent's KIDS.  IRUN and IPOS locate it among stacked layout items.
LINES caches composed margin-box lines: a vector, t when lines were
composed without caching, or nil when none are composed."
  tag parent kids krun (kpos 0) irun (ipos 0)
  text image props decls defaults
  id classes attributes states key data
  inter ecss scopes roots env
  cs (dirty 15)
  (w 0) (h 0) (x 0) (y 0)
  meas intr contrib seen avail layout lines
  dkids ops overlays host placed (scroll 0) (pinned t)
  mount inter-cache hover)

;; Dirty bits.
(defconst ebox--d-style 1)
(defconst ebox--d-layout 2)
(defconst ebox--d-paint 4)
(defconst ebox--d-desc 8)
(defconst ebox--d-queued 16
  "Set while a node is listed in its parent's dirty children.")

(defun ebox-node-children (node)
  "Return NODE's children as a fresh list."
  (let (result)
    (ebox--seq-do (kid (ebox-node-kids node)) (push kid result))
    (nreverse result)))

(defun ebox-node-child (node index)
  "Return NODE's child at INDEX, or nil when INDEX is out of range."
  (ebox--seq-ref (ebox-node-kids node) index))

(defun ebox-node-child-count (node)
  "Return the number of NODE's children."
  (let ((kids (ebox-node-kids node))) (if kids (ebox-seq-n kids) 0)))

(defun ebox-node-index (node)
  "Return NODE's position among its parent's children, 0 for a root."
  (let ((run (ebox-node-krun node)))
    (if (and run (ebox-node-parent node)) (+ (ebox-run-start run) (ebox-node-kpos node)) 0)))

(defun ebox--kid-ref (node run pos _old)
  "Record that child NODE sits at POS of RUN."
  (setf (ebox-node-krun node) run (ebox-node-kpos node) pos))

(defun ebox--prev-kid (node)
  "Return NODE's previous sibling, or nil."
  (let ((pos (ebox-node-kpos node)))
    (if (> pos 0)
        (aref (ebox-run-vec (ebox-node-krun node)) (1- pos))
      (let ((index (ebox-node-index node)))
        (and (> index 0) (ebox-node-child (ebox-node-parent node) (1- index)))))))

(defmacro ebox--do-kids (spec &rest body)
  "Bind (VAR NODE) to each child of NODE in order and run BODY."
  (declare (indent 1))
  `(ebox--seq-do (,(car spec) (ebox-node-kids ,(cadr spec))) ,@body))

(defun ebox-node-text-p (node)
  "Return non-nil when NODE is a text node."
  (eq (ebox-node-tag node) 'text))

(defun ebox-node-root (node)
  "Return the root of NODE's tree."
  (while (ebox-node-parent node) (setq node (ebox-node-parent node)))
  node)

(defun ebox-node-ancestor-p (ancestor node)
  "Return non-nil when ANCESTOR is NODE or one of its ancestors."
  (while (and node (not (eq node ancestor)))
    (setq node (ebox-node-parent node)))
  (and node t))

(defun ebox-node-walk (node function)
  "Call FUNCTION on NODE and its descendants in document order."
  (funcall function node)
  (ebox--do-kids (child node) (ebox-node-walk child function)))

;;;; Property parsing

(defun ebox--class-list (value)
  "Normalize class VALUE to a list of strings."
  (cond ((null value) nil)
        ((stringp value) (split-string value "[ \t\n]+" t))
        ((symbolp value) (list (symbol-name value)))
        ((proper-list-p value) (mapcan #'ebox--class-list value))
        (t (signal 'ebox-error (list "Invalid :class value" value)))))

(defun ebox--token (value)
  "Return selector token VALUE as a string."
  (cond ((null value) nil)
        ((stringp value) value)
        ((symbolp value) (symbol-name value))
        ((numberp value) (number-to-string value))
        (t (format "%s" value))))

(defvar ebox--decl-cache (make-hash-table :test 'equal)
  "Compiled declarations keyed by (TAG . STYLE-PLIST).")

(defun ebox--compile-decls (tag plist)
  "Return compiled canonical declarations for TAG's style PLIST."
  (if (null plist) nil
    (let ((key (cons tag plist)))
      (or (gethash key ebox--decl-cache)
          (let ((decls (condition-case err
                           (ebox-style-compile-form tag plist)
                         (error (signal 'ebox-error
                                        (list (format "Ebox %S rejected properties: %s"
                                                      tag (error-message-string err))))))))
            (when (> (hash-table-count ebox--decl-cache) 4096)
              (clrhash ebox--decl-cache))
            (puthash (copy-tree key) decls ebox--decl-cache)
            decls)))))

(defvar ebox--scope-cache (make-hash-table :test 'equal)
  "Shared scopes created from inline :ecss rules or :defaults plists.")

(defun ebox--rules-scope (rules origin)
  "Return a shared scope for RULES at ORIGIN."
  (let ((key (cons origin rules)))
    (or (gethash key ebox--scope-cache)
        (progn
          (when (> (hash-table-count ebox--scope-cache) 1024)
            (clrhash ebox--scope-cache))
          (puthash (copy-tree key)
                   (ebox-style-scope-create rules :origin origin)
                   ebox--scope-cache)))))

(defun ebox--split-props (props)
  "Split PROPS into (STYLE META INTER) plists."
  (let (style meta inter)
    (while props
      (let ((key (pop props)) (value (pop props)))
        (cond ((memq key ebox--meta-properties)
               (push key meta) (push value meta))
              ((memq key ebox-interaction-properties)
               (push key inter) (push value inter))
              ((memq key '(:content :layout :display :ebox-type))
               (signal 'ebox-error (list "Private Ebox property" key)))
              (t (push key style) (push value style)))))
    (list (nreverse style) (nreverse meta) (nreverse inter))))

(defun ebox--author-states (value)
  "Validate author selector state VALUE and return its tokens."
  (let ((states (mapcar (lambda (state)
                          (unless (or (symbolp state) (stringp state))
                            (signal 'ebox-error (list "Ebox box rejected :states value" value)))
                          (ebox--token state))
                        (if (listp value) value (list value)))))
    (when (cl-intersection states '("disabled" "focus" "active") :test #'equal)
      (signal 'ebox-error
              (list "Ebox disabled, focus and active selector states cannot be authored")))
    states))

(defun ebox--check-inter (inter)
  "Validate interaction plist INTER."
  (let ((tab (plist-get inter :tab-index))
        (disabled (plist-get inter :disabled)))
    (unless (or (null tab) (integerp tab))
      (signal 'ebox-error (list "Ebox :tab-index requires nil or an integer" tab)))
    (unless (memq disabled '(nil t))
      (signal 'ebox-error (list "Ebox :disabled requires nil or t" disabled)))
    (unless (memq (plist-get inter :focus-group) '(nil vertical horizontal grid))
      (signal 'ebox-error (list "Ebox :focus-group requires vertical, horizontal, grid or nil"
                                (plist-get inter :focus-group))))
    (unless (memq (plist-get inter :focus-scope) '(nil modal))
      (signal 'ebox-error (list "Ebox :focus-scope requires modal or nil"
                                (plist-get inter :focus-scope))))
    (dolist (key '(:swipe :scroll))
      (unless (or (null (plist-get inter key)) (functionp (plist-get inter key)))
        (signal 'ebox-error (list (format "Ebox %s requires a one-argument function" key)
                                  (plist-get inter key)))))))

(defun ebox--node-set-props (node props)
  "Install author PROPS on NODE without invalidation."
  (unless (and (proper-list-p props) (zerop (% (length props) 2)))
    (signal 'ebox-error (list "Properties must be an even plist" props)))
  (pcase-let* ((tag (ebox-node-tag node))
               (`(,style ,meta ,inter) (ebox--split-props props)))
    (when inter (ebox--check-inter inter))
    (setf (ebox-node-props node) props
          (ebox-node-decls node) (ebox--compile-decls tag style)
          (ebox-node-inter node) inter
          (ebox-node-inter-cache node) nil
          (ebox-node-key node) (plist-get meta :key)
          (ebox-node-id node) (ebox--token (plist-get meta :id))
          (ebox-node-classes node) (ebox--class-list (plist-get meta :class))
          (ebox-node-attributes node)
          (mapcar (lambda (entry) (cons (ebox--token (car entry))
                                        (if (stringp (cdr entry)) (cdr entry)
                                          (ebox--token (cdr entry)))))
                  (plist-get meta :attributes))
          (ebox-node-states node) (ebox--author-states (plist-get meta :states))
          (ebox-node-data node) (plist-get meta :data))
    (when (plist-member meta :image)
      (setf (ebox-node-image node) (plist-get meta :image)))
    (let ((defaults (plist-get meta :defaults))
          (rules (append (and (plist-get meta :ecss-file)
                              (ecss-file-read (plist-get meta :ecss-file)))
                         (plist-get meta :ecss))))
      (setf (ebox-node-defaults node)
            (and defaults (ebox--rules-scope (list (cons "&" defaults)) 'ua)))
      (setf (ebox-node-ecss node) (and rules (ebox--rules-scope rules 'author)))
      (setf (ebox-node-scopes node)
            (mapcar #'ebox-style-scope-identity (plist-get meta :ecss-scopes)))
      (setf (ebox-node-roots node) (plist-get meta :ecss-scope-roots)))
    node))

;;;; Construction

(defun ebox-node-create (tag &optional props children)
  "Create a detached node of TAG with author PROPS and CHILDREN.
TAG is box, row, column, flex, grid, text or image.  CHILDREN are nodes or
strings; strings become text nodes."
  (unless (memq tag '(box row column flex grid text image))
    (signal 'ebox-error (list "Unknown Ebox tag" tag)))
  (let ((node (ebox-node--make :tag tag)))
    (ebox--node-set-props node props)
    (dolist (child children)
      (ebox--attach node (if (stringp child) (ebox-text-create child) child)
                    (ebox-node-child-count node)))
    node))

(defun ebox-text-create (string &optional props)
  "Create a detached text node showing STRING with author PROPS."
  (unless (stringp string)
    (signal 'ebox-error (list "Ebox text payload must be a string" string)))
  (let ((node (ebox-node--make :tag 'text :text string)))
    (ebox--node-set-props node props)
    node))

(defun ebox-node-copy (node)
  "Return a detached deep copy of NODE built from its current inputs.
The copy shares no structure that later mutations of NODE can change, so it
can be rendered with `ebox-render' as a snapshot."
  (let ((props (ebox-node-props node)))
    (if (ebox-node-text-p node)
        (ebox-text-create (ebox-node-text node) props)
      (when (ebox-node-image node)
        (setq props (plist-put (copy-sequence props) :image
                               (ebox-node-image node))))
      (ebox-node-create (ebox-node-tag node) props
                        (mapcar #'ebox-node-copy (ebox-node-children node))))))

(defun ebox--attach (parent child index)
  "Insert detached CHILD among PARENT's children at INDEX."
  (when (ebox-node-parent child)
    (signal 'ebox-error (list "Ebox node already has a parent")))
  (when (eq (ebox-node-tag parent) 'text)
    (signal 'ebox-error (list "Ebox text nodes cannot contain children")))
  (let ((kids (or (ebox-node-kids parent)
                  (setf (ebox-node-kids parent) (ebox-seq--make)))))
    (ebox--seq-insert kids (max 0 (min index (ebox-seq-n kids))) child #'ebox--kid-ref)
    (setf (ebox-node-parent child) parent)
    child))

(defun ebox--detach (child)
  "Remove CHILD from its parent's children."
  (when-let* ((parent (ebox-node-parent child)))
    (ebox--seq-delete (ebox-node-kids parent) (ebox-node-krun child) (ebox-node-kpos child)
                      #'ebox--kid-ref)
    (setf (ebox-node-parent child) nil (ebox-node-krun child) nil)))

(defun ebox--set-kids (parent children)
  "Make the list CHILDREN, already parented to PARENT, its children."
  (setf (ebox-node-kids parent) (and children (ebox--seq-build children #'ebox--kid-ref))))

;;;; Author DSL

(defun ebox--dsl-unquote (value)
  "Unquote one static DSL property VALUE."
  (if (and (eq (car-safe value) 'quote) (consp (cdr value)) (null (cddr value)))
      (cadr value)
    value))

(defun ebox--dsl-split (items)
  "Split DSL ITEMS into (PROPS . CHILDREN)."
  (let (props children)
    (while items
      (let ((item (pop items)))
        (if (or (keywordp item) (ebox-style--custom-property-p item))
            (progn
              (unless items (signal 'ebox-error (list "Missing value for" item)))
              (push item props)
              (push (ebox--dsl-unquote (pop items)) props))
          (push item children))))
    (cons (nreverse props) (nreverse children))))

(defun ebox-build (form)
  "Build a detached node tree from author FORM.
FORM is a string or (TAG PROPERTY VALUE ... CHILD ...) with TAG among text,
box, row, column, flex and grid."
  (cond
   ((stringp form) (ebox-text-create form))
   ((ebox-node-p form) form)
   ((and (consp form) (symbolp (car form)))
    (let* ((tag (car form))
           (split (ebox--dsl-split (cdr form))))
      (pcase tag
        ('text
         (unless (and (= (length (cdr split)) 1) (stringp (cadr split)))
           (signal 'ebox-error (list "Ebox text requires exactly one string payload")))
         (when (or (plist-member (car split) :ecss) (plist-member (car split) :ecss-file))
           (signal 'ebox-error (list "Ebox :ecss requires a Box form")))
         (ebox-text-create (cadr split) (car split)))
        ((or 'box 'row 'column 'flex 'grid)
         (ebox-node-create tag (car split) (mapcar #'ebox-build (cdr split))))
        (_ (signal 'ebox-error (list "Unknown Ebox author tag" tag))))))
   (t (signal 'ebox-error (list "Invalid Ebox form" form)))))

;;;; Selector adapter

(defvar ebox--derived-states-function nil
  "Function of NODE returning interaction-derived selector states.")

(defun ebox--node-all-states (node)
  "Return NODE's author and derived selector states."
  (let ((derived (and ebox--derived-states-function
                      (funcall ebox--derived-states-function node))))
    (if derived (append (ebox-node-states node) derived) (ebox-node-states node))))

(defun ebox--node-selector-attributes (node)
  "Return NODE's selector attributes, including its id and key.
As in CSS, `[id=...]' and `[key=...]' match the node's :id and :key, which
also serves ids that are not valid `#' selector identifiers."
  (let ((attributes (ebox-node-attributes node))
        (key (ebox--token (ebox-node-key node))))
    (when key (push (cons "key" key) attributes))
    (when (ebox-node-id node) (push (cons "id" (ebox-node-id node)) attributes))
    attributes))

(defconst ebox--ecss-adapter
  (ecss-subject-adapter-create
   :type (lambda (node) (symbol-name (ebox-node-tag node)))
   :id #'ebox-node-id
   :classes #'ebox-node-classes
   :attributes #'ebox--node-selector-attributes
   :states #'ebox--node-all-states
   :parent #'ebox-node-parent
   :children #'ebox-node-children)
  "ECSS adapter exposing retained nodes.")

(defun ebox-selector-match-node-p (node selector)
  "Return non-nil when NODE matches structured or string SELECTOR."
  (ecss-selector-match-p selector node ebox--ecss-adapter))

;;;; Computed style

(ebox--defstruct (ebox-cs (:constructor ebox-cs--make) (:copier nil))
  "Hash-consed computed style of one node."
  vals ikey tag hidden bg face padface fontface deco
  width min-width max-width height min-height max-height
  pt pr pb pl mt mr mb ml bl br btop bbot btc bbc blc brc
  box-sizing position outer overflow wrap align gap cross
  z abs vcbh vunits lkey)

(defun ebox--viewport-units (value &optional units)
  "Return UNITS plus the viewport units, vw and vh, that VALUE refers to."
  (cond ((and (memq value '(vw vh)) (not (memq value units))) (cons value units))
        ((consp value) (ebox--viewport-units (cdr value)
                                             (ebox--viewport-units (car value) units)))
        (t units)))

(defun ebox--cbh-relative-p (value)
  "Return non-nil when block-size VALUE depends on the containing height."
  (cond ((memq value '(% stretch)) t)
        ((consp value) (or (ebox--cbh-relative-p (car value))
                           (ebox--cbh-relative-p (cdr value))))))

(defsubst ebox--cv (cs id)
  "Return computed value ID from CS."
  (plist-get (ebox-cs-vals cs) id))

(defvar ebox--cs-cache (make-hash-table :test 'eq :weakness 'key)
  "Computed-style tables keyed by what children inherit from their parent.
Keys are inheritance keys, or parent styles themselves once an explicit
`inherit' value makes a child read non-inherited parent values.")

(defconst ebox--inherited-ids
  (cl-loop for property in ebox-style--property-definitions
           when (plist-get property :inherits)
           collect (plist-get property :id))
  "Computed value ids that ECSS copies from a parent style.")

(defvar ebox--ikey-table (make-hash-table :test 'equal :weakness 'value)
  "Shared inheritance keys, so equal inherited inputs compare with `eq'.")

(defun ebox--inheritance-key (vals bg deco hidden)
  "Return the shared key of everything a child inherits from VALS.
BG, DECO and HIDDEN are the derived paint state children inherit too."
  (let ((key (cons (list bg deco hidden (plist-get vals 'ebox--css-weight))
                   (mapcar (lambda (id) (plist-get vals id))
                           ebox--inherited-ids))))
    (or (gethash key ebox--ikey-table)
        (puthash key key ebox--ikey-table))))

(defvar ebox--root-cs-table (make-hash-table :test 'equal)
  "Computed styles of nodes without a parent style.")

(defvar ebox--subject-local-cache (make-hash-table :test 'eq :weakness 'key)
  "Stylesheet identity to non-nil when every selector is subject-local.")

(defun ebox--stylesheet-local-p (sheet)
  "Return non-nil when every rule selector of SHEET is subject-local."
  (let ((cached (gethash sheet ebox--subject-local-cache 'none)))
    (if (not (eq cached 'none)) cached
      (puthash sheet
               (cl-every (lambda (rule)
                           (ecss-selector-subject-local-p (ecss-rule-selector rule) t))
                         (ecss-stylesheet-rules sheet))
               ebox--subject-local-cache))))

(defun ebox--node-env (node)
  "Return NODE's active scope environment: a list of (SCOPE ROOT ALL)."
  (let ((env (let ((parent (ebox-node-parent node)))
               (and parent (ebox-node-env parent)))))
    (dolist (scope (ebox-node-roots node))
      (push (list scope node nil) env))
    (when (ebox-node-ecss node)
      (push (list (ebox-node-ecss node) node t) env))
    (when (ebox-node-defaults node)
      (push (list (ebox-node-defaults node) node 'self) env))
    env))

(defun ebox--env-equal (a b)
  "Return non-nil when scope environments A and B hold the same entries."
  (while (and a b (let ((x (car a)) (y (car b)))
                    (and (eq (car x) (car y)) (eq (nth 1 x) (nth 1 y))
                         (eq (nth 2 x) (nth 2 y)))))
    (setq a (cdr a) b (cdr b)))
  (and (null a) (null b)))

(defun ebox--applicable-scopes (node env)
  "Return the (SCOPE ROOT) entries of ENV applying to NODE."
  (let (result (members (ebox-node-scopes node)))
    (dolist (entry env)
      (let ((scope (car entry)) (mode (nth 2 entry)))
        (when (pcase mode
                ('self (eq (nth 1 entry) node))
                ('t t)
                (_ (memq (ebox-style-scope-identity scope) members)))
          (push entry result))))
    (nreverse result)))

(defun ebox--style-key (node scopes)
  "Return the style cache key of NODE with applicable SCOPES, or nil."
  (if (null scopes)
      (list (ebox-node-tag node) (ebox-node-decls node))
    (when (cl-every (lambda (entry)
                      (ebox--stylesheet-local-p
                       (ebox-style-scope-stylesheet (car entry))))
                    scopes)
      (list (ebox-node-tag node) (ebox-node-decls node)
            (mapcar (lambda (entry)
                      (cons (ebox-style-scope-stylesheet (car entry))
                            (eq (nth 1 entry) node)))
                    scopes)
            (ebox-node-id node) (ebox-node-classes node)
            (ebox-node-attributes node) (ebox--node-all-states node)))))

(defun ebox--compute-values (node parent-cs scopes)
  "Run the ECSS cascade for NODE with PARENT-CS and SCOPES."
  (ecss-computed-style-values
   (ecss-compute-style
    ebox-style-schemas node
    :declarations (ebox-node-decls node)
    :parent-style (and parent-cs (ebox-cs-vals parent-cs))
    :adapter ebox--ecss-adapter
    :scopes (mapcar (lambda (entry)
                      (ecss-scope-create (nth 1 entry)
                                         (ebox-style-scope-stylesheet (car entry))
                                         :subjects t))
                    scopes))))

(defconst ebox--hover-properties
  '(:color :background-color :font-weight :font-style :text-decoration-line
    :text-decoration-style :text-decoration-color)
  "Paint properties accepted by :hover-style.
They override the node's computed paint in the native hover face, which restates
that paint first; a declaration left out keeps the node's own value.")

(defun ebox--hover-declarations (value)
  "Return :hover-style VALUE as canonical Ebox paint declarations.
VALUE is an even plist of `ebox--hover-properties'; an odd plist or an
unsupported property signals `ebox-error'."
  (unless (and (proper-list-p value) (zerop (% (length value) 2)))
    (signal 'ebox-error (list "Ebox :hover-style must be an even plist" value)))
  (cl-loop for (key _value) on value by #'cddr
           unless (memq key ebox--hover-properties)
           do (signal 'ebox-error (list "Ebox :hover-style does not support" key)))
  (ebox-style-compile-declarations value))

(defun ebox--hover-values (node vals)
  "Return VALS with NODE's :hover-style declarations overriding its paint."
  (cl-loop for (id value) on (ebox--hover-declarations
                              (plist-get (ebox-node-inter node) :hover-style))
           by #'cddr
           do (setq vals (plist-put vals id value)))
  vals)

(defun ebox--node-style (node parent-cs)
  "Return the shared computed style of NODE under PARENT-CS.
A node painting transient pointer hover bypasses the shared style cache and
merges its :hover-style declarations into the computed paint."
  (let* ((env (let ((env (ebox--node-env node)) (old (ebox-node-env node)))
                (if (ebox--env-equal env old) old env)))
         (_ (setf (ebox-node-env node) env))
         (scopes (and env (ebox--applicable-scopes node env)))
         (hover (ebox-node-hover node))
         (key (ebox--style-key node scopes))
         (pkey (and parent-cs
                    (if ebox-style--explicit-inherit parent-cs
                      (ebox-cs-ikey parent-cs))))
         (table (if pkey
                    (or (gethash pkey ebox--cs-cache)
                        (puthash pkey (make-hash-table :test 'equal)
                                 ebox--cs-cache))
                  ebox--root-cs-table)))
    (or (and (not hover) key (gethash key table))
        (let* ((vals (ebox--compute-values node parent-cs scopes))
               (vals (if hover (ebox--hover-values node vals) vals))
               (cs (ebox--make-cs vals parent-cs (ebox-node-tag node))))
          (when (and key (not hover))
            (when (> (hash-table-count table) 2048) (clrhash table))
            (puthash key cs table))
          cs))))

(defun ebox--inspect-rule-matches-p (node root selector decls origin)
  "Return non-nil when SELECTOR with DECLS at ORIGIN matches NODE under ROOT."
  (let ((sheet (ecss-stylesheet-create)))
    (ecss-stylesheet-declare-layers sheet nil origin)
    (ecss-stylesheet-add-rule sheet ebox-style-schemas selector decls :origin origin)
    (let ((probe (ecss-compute-style
                  ebox-style-schemas node
                  :adapter ebox--ecss-adapter
                  :scopes (list (ecss-scope-create root sheet :subjects t)))))
      (or (ecss-computed-style-specified-properties probe)
          (ecss-computed-style-custom-properties probe)))))

(defun ebox--inspect-declarations-list (compiled-decls prov-plist inline-p origin norm-sel)
  "Return declaration inspection plists for COMPILED-DECLS against PROV-PLIST."
  (let (out)
    (cl-loop for (id val) on compiled-decls by #'cddr do
             (let* ((key (ebox-style--public-property-name id))
                    (prov (plist-get prov-plist id))
                    (winner
                     (and prov
                          (eq (plist-get prov :source) 'declaration)
                          (if inline-p
                              (plist-get prov :inline)
                            (and (not (plist-get prov :inline))
                                 (eq (plist-get prov :origin) origin)
                                 (equal (plist-get prov :selector) norm-sel))))))
               (push (list :property key
                           :value (copy-tree val)
                           :winner (and winner t))
                     out)))
    (nreverse out)))

(defun ebox-node-inspect-style (node)
  "Return on-demand style cascade and provenance details for styled NODE, or nil.
Computes ECSS provenance only for NODE without mutating caches or buffers.
Return nil when NODE has not been styled yet.  Otherwise return a detached
plist containing `:values', `:specified', `:custom-properties', `:provenance',
`:matched-rules', `:states' and `:diagnostics'."
  (unless (ebox-node-p node)
    (signal 'wrong-type-argument (list 'ebox-node-p node)))
  (when (ebox-node-cs node)
    (let* ((parent (ebox-node-parent node))
           (parent-cs (and parent (ebox-node-cs parent)))
           (env (ebox--node-env node))
           (scopes (and env (ebox--applicable-scopes node env)))
           (ecss-scopes
            (mapcar (lambda (entry)
                      (ecss-scope-create (nth 1 entry)
                                         (ebox-style-scope-stylesheet (car entry))
                                         :subjects t))
                    scopes))
           (style (ecss-compute-style
                   ebox-style-schemas node
                   :declarations (ebox-node-decls node)
                   :parent-style (and parent-cs (ebox-cs-vals parent-cs))
                   :adapter ebox--ecss-adapter
                   :provenance t
                   :scopes ecss-scopes))
           (raw-prov (ecss-computed-style-provenance style))
           (spec-ids (ecss-computed-style-specified-properties style))
           (pub-prov nil)
           (matched nil))
      (cl-loop for (id fact) on raw-prov by #'cddr do
               (unless (eq (plist-get fact :source) 'initial)
                 (push (cons (ebox-style--public-property-name id)
                             (copy-tree fact))
                       pub-prov)))
      (when-let* ((decls (ebox-node-decls node)))
        (push (list :origin 'inline
                    :inline t
                    :selector nil
                    :specificity nil
                    :layer nil
                    :scope-root nil
                    :declarations (ebox--inspect-declarations-list
                                   decls raw-prov t 'author :inline))
              matched))
      (dolist (entry scopes)
        (let* ((scope (car entry))
               (root (nth 1 entry))
               (origin (or (ebox-style-scope-origin scope) 'author))
               (raw-rules (ebox-style-scope-rules scope)))
          (dolist (rule raw-rules)
            (let* ((sel-str (car rule))
                   (parsed (ecss-selector-parse sel-str))
                   (norm (ecss-selector-normalize parsed))
                   (compiled (ebox-style-compile-declarations (cdr rule) t)))
              (when (and compiled
                         (ebox--inspect-rule-matches-p node root parsed compiled origin))
                (push (list :origin origin
                            :inline nil
                            :selector (copy-sequence sel-str)
                            :specificity (ecss-selector-specificity parsed)
                            :layer nil
                            :scope-root root
                            :declarations (ebox--inspect-declarations-list
                                           compiled raw-prov nil origin norm))
                      matched))))))
      (list :values (ebox-style--public-computed-values style)
            :specified (mapcar #'ebox-style--public-property-name spec-ids)
            :custom-properties (ecss-computed-style-custom-properties style)
            :provenance (nreverse pub-prov)
            :matched-rules (nreverse matched)
            :states (copy-sequence (ebox--node-all-states node))
            :diagnostics (ecss-computed-style-diagnostics style)))))

;;;; Faces and lengths

(defvar ebox-viewport-width nil
  "Viewport width in pixels for rendering outside a mount, or nil.")

(defvar ebox-viewport-height nil
  "Viewport height in lines for rendering outside a mount, or nil.")

(defun ebox--default-viewport-width ()
  "Return the fallback viewport width in pixels."
  (or ebox-viewport-width
      (if noninteractive 80
        (window-body-width nil t))))

(defun ebox--default-viewport-height ()
  "Return the fallback viewport height in lines, or nil when indefinite.
Batch sessions have no display, so viewport-height units stay indefinite
unless `ebox-viewport-height' supplies one."
  (or ebox-viewport-height
      (unless noninteractive (window-body-height))))

(defvar ebox--vw nil "Viewport width in pixels during layout.")
(defvar ebox--vh nil "Viewport height in lines during layout.")

(defun ebox--css-weight (weight parent)
  "Resolve CSS WEIGHT against PARENT numeric weight."
  (pcase weight
    ((or 'nil 'normal) 400)
    ('bold 700)
    ('bolder (cond ((<= parent 300) 400) ((<= parent 500) 700) (t 900)))
    ('lighter (cond ((<= parent 500) 100) ((<= parent 700) 400) (t 700)))
    ((pred numberp) weight)
    (_ 400)))

(defun ebox--emacs-weight (css)
  "Map numeric CSS weight to an Emacs face weight."
  (cond ((<= css 100) 'ultra-light) ((<= css 200) 'extra-light)
        ((<= css 300) 'light) ((<= css 500) 'normal) ((<= css 600) 'semi-bold)
        ((<= css 700) 'bold) ((<= css 800) 'extra-bold) (t 'ultra-bold)))

(defvar ebox--face-intern (make-hash-table :test 'equal)
  "Interned face values shared by computed styles.")

(defun ebox--intern-face (face)
  "Return a shared object `equal' to FACE."
  (if (null face) nil
    (or (gethash face ebox--face-intern)
        (puthash face face ebox--face-intern))))

(defun ebox--font-group (vals parent)
  "Return (FACE-PLIST . CSS-WEIGHT) for font VALS under PARENT style.
`ebox/font-size' is a ratio of the body size, so `ebox--font-height' turns
it into the 1/10 pt height Emacs paints with."
  (let* ((family (plist-get vals 'ebox/font-family))
         (size (plist-get vals 'ebox/font-size))
         (weight (plist-get vals 'ebox/font-weight))
         (slant (plist-get vals 'ebox/font-style))
         (pweight (if parent (or (ebox--cv parent 'ebox--css-weight) 400) 400))
         (css (ebox--css-weight weight pweight))
         face)
    (when family
      (setq face (plist-put face :family (if (symbolp family) (symbol-name family) family))))
    (when size (setq face (plist-put face :height (ebox--font-height size))))
    (unless (memq weight '(nil normal))
      (setq face (plist-put face :weight (ebox--emacs-weight css))))
    (unless (memq slant '(nil normal))
      (setq face (plist-put face :slant slant)))
    (cons face css)))

(defun ebox--deco-group (vals color)
  "Return the decoration face plist of VALS with current COLOR."
  (let ((line (plist-get vals 'ebox/text-decoration-line)))
    (unless (memq line '(nil none))
      (let* ((lines (if (listp line) line (list line)))
             (dcolor (plist-get vals 'ebox/text-decoration-color))
             (dcolor (if (memq dcolor '(nil currentColor)) color dcolor))
             (style (plist-get vals 'ebox/text-decoration-style))
             (spec (if (or dcolor (not (memq style '(nil solid))))
                       (append (and dcolor (list :color dcolor))
                               (and (eq style 'wavy) (list :style 'wave)))
                     t))
             face)
        (when (memq 'underline lines) (setq face (plist-put face :underline spec)))
        (when (memq 'overline lines)
          (setq face (plist-put face :overline (if (eq spec t) t (or dcolor t)))))
        (when (memq 'line-through lines)
          (setq face (plist-put face :strike-through (if (eq spec t) t (or dcolor t)))))
        face))))

(defun ebox--face-from-groups (groups)
  "Combine non-nil face GROUPS into one face value."
  (let ((groups (delq nil groups)))
    (ebox--intern-face (if (cdr groups) groups (car groups)))))

(defconst ebox--layout-ids
  (cons 'ebox--css-weight
        (delq nil (mapcar (lambda (def)
                            (and (not (eq (plist-get def :signature) 'paint))
                                 (plist-get def :id)))
                          ebox-style--property-definitions)))
  "Computed value ids that can change geometry.")

(defconst ebox--weight-key-positions
  (let ((i 0) positions)
    (dolist (id ebox--layout-ids (nreverse positions))
      (when (memq id '(ebox--css-weight ebox/font-weight)) (push i positions))
      (setq i (1+ i))))
  "Positions of the font weight values in a layout key.")

(defvar ebox--weight-change-cache (make-hash-table :test 'eq :weakness 'key)
  "Map of computed style to ((STYLE EPOCH . SAME) ...) weight comparisons.")

(defun ebox--weight-only-change-p (old new)
  "Return non-nil when computed styles OLD and NEW keep their geometry.
Their layout keys may differ only in font weight, and the two fonts must
measure text alike."
  (let* ((known (gethash old ebox--weight-change-cache))
         (entry (assq new known)))
    (if (and entry (eq (cadr entry) ebox--width-epoch))
        (cddr entry)
      (let ((a (ebox-cs-lkey old)) (b (ebox-cs-lkey new)) (i 0) (same t))
        (while (and same a)
          (unless (or (equal (car a) (car b)) (memq i ebox--weight-key-positions))
            (setq same nil))
          (setq a (cdr a) b (cdr b) i (1+ i)))
        (setq same (and same (ebox--same-widths-p (ebox-cs-fontface old)
                                                  (ebox-cs-fontface new))))
        (puthash old (cons (cons new (cons ebox--width-epoch same))
                           (if entry (delq entry known) known))
                 ebox--weight-change-cache)
        same))))

(defvar ebox--lkey-table (make-hash-table :test 'equal :weakness 'value)
  "Shared layout keys, so equal geometry inputs compare with `eq'.")

(defun ebox--layout-key (vals)
  "Return the shared list of VALS' geometry-relevant values."
  (let ((key (mapcar (lambda (id) (plist-get vals id)) ebox--layout-ids)))
    (or (gethash key ebox--lkey-table)
        (puthash key key ebox--lkey-table))))

(defconst ebox--hot-ids
  '(ebox/flex-direction ebox/flex-wrap ebox/align-items ebox/align-self
    ebox/flex-basis ebox/flex-grow ebox/flex-shrink ebox/order
    ebox/justify-content ebox/align-content ebox/column-gap ebox/row-gap)
  "Computed value ids that layout reads per node, stored first in `vals'.")

(defun ebox--hot-first (vals)
  "Return VALS with `ebox--hot-ids' first, so layout lookups stay short."
  (let (head)
    (dolist (id ebox--hot-ids)
      (let ((cell (plist-member vals id)))
        (when cell (setq head (cons (cadr cell) (cons id head))))))
    (let ((rest nil) (tail vals))
      (while tail
        (unless (memq (car tail) ebox--hot-ids)
          (setq rest (cons (cadr tail) (cons (car tail) rest))))
        (setq tail (cddr tail)))
      (nconc (nreverse head) (nreverse rest)))))

(defun ebox--text-size-emphasis (vals parent)
  "Return VALS, made bold when a text display raises the font size.
A terminal has one face size, so a larger size cannot render.  The node that
raises the size takes bold weight instead, and children inherit it through
the normal font-weight cascade.  Graphical frames return VALS unchanged."
  (let ((size (plist-get vals 'ebox/font-size))
        (base (and parent (or (ebox--cv parent 'ebox/font-size) 1)))
        (weight (plist-get vals 'ebox/font-weight)))
    (if (and (ebox--text-display-p)
             (numberp size) (numberp base) (> size (* base 1.15))
             (memq weight '(nil normal)))
        (plist-put (copy-sequence vals) 'ebox/font-weight 'bold)
      vals)))

(defun ebox--make-cs (vals parent tag)
  "Build a computed style from ECSS VALS under PARENT for TAG."
  (let* ((vals (ebox--text-size-emphasis vals parent))
         (font (ebox--font-group vals parent))
         (vals (ebox--hot-first (plist-put vals 'ebox--css-weight (cdr font))))
         (color (plist-get vals 'ebox/color))
         (color (if (eq color 'currentColor) nil color))
         (own-bg (plist-get vals 'ebox/background-color))
         (bg (or own-bg (and parent (ebox-cs-bg parent))))
         (deco (or (ebox--deco-group vals color) (and parent (ebox-cs-deco parent))))
         (hidden (or (eq (plist-get vals 'ebox/visibility) 'hidden)
                     (and parent (ebox-cs-hidden parent))))
         (fontface (ebox--intern-face (car font)))
         (lkey (ebox--layout-key vals))
         (cs (ebox-cs--make
              :vals vals :tag tag :hidden hidden :bg bg :deco deco
              :ikey (ebox--inheritance-key vals bg deco hidden)
              :fontface fontface
              :face (ebox--face-from-groups
                     (list (car font) deco (and color (list :foreground color))
                           (and bg (list :background bg))))
              :padface (and bg (ebox--intern-face (list :background bg)))
              :width (plist-get vals 'ebox/width)
              :min-width (plist-get vals 'ebox/min-width)
              :max-width (plist-get vals 'ebox/max-width)
              :height (plist-get vals 'ebox/height)
              :min-height (plist-get vals 'ebox/min-height)
              :max-height (plist-get vals 'ebox/max-height)
              :box-sizing (plist-get vals 'ebox/box-sizing)
              :position (plist-get vals 'ebox/position)
              :outer (plist-get vals 'ebox/outer)
              :overflow (plist-get vals 'ebox/overflow)
              :wrap (plist-get vals 'ebox/wrap-mode)
              :align (plist-get vals 'ebox/text-align)
              :gap (plist-get vals 'ebox/item-gap)
              :cross (plist-get vals 'ebox/cross-align)
              :z (or (plist-get vals 'ebox/z-index) 0)
              :abs (eq (plist-get vals 'ebox/position) 'absolute)
              :lkey lkey
              :vunits (ebox--viewport-units lkey)
              :vcbh (cl-some #'ebox--cbh-relative-p
                             (list (plist-get vals 'ebox/height)
                                   (plist-get vals 'ebox/min-height)
                                   (plist-get vals 'ebox/max-height))))))
    (cl-flet ((edge (physical logical)
                (let ((p (plist-get vals physical)) (l (plist-get vals logical)))
                  ;; The later declaration wins; computed values keep both, so
                  ;; prefer a non-initial logical value.
                  (if (and l (not (member l '((px 0) (lh 0))))) l p)))
              (border-px (side)
                (let ((style (plist-get vals (intern (format "ebox/border-%s-style" side))))
                      (width (plist-get vals (intern (format "ebox/border-%s-width" side)))))
                  (if (or (memq style '(nil none hidden)) (null width))
                      0
                    (max 0 (or (ebox--px width cs nil) 1)))))
              (border (side px)
                (and (> px 0)
                     (or (plist-get vals (intern (format "ebox/border-%s-color" side)))
                         color 'default))))
      (setf (ebox-cs-pt cs) (edge 'ebox/padding-top 'ebox/padding-block-start)
            (ebox-cs-pr cs) (edge 'ebox/padding-right 'ebox/padding-inline-end)
            (ebox-cs-pb cs) (edge 'ebox/padding-bottom 'ebox/padding-block-end)
            (ebox-cs-pl cs) (edge 'ebox/padding-left 'ebox/padding-inline-start)
            (ebox-cs-mt cs) (edge 'ebox/margin-top 'ebox/margin-block-start)
            (ebox-cs-mr cs) (edge 'ebox/margin-right 'ebox/margin-inline-end)
            (ebox-cs-mb cs) (edge 'ebox/margin-bottom 'ebox/margin-block-end)
            (ebox-cs-ml cs) (edge 'ebox/margin-left 'ebox/margin-inline-start)
            (ebox-cs-bl cs) (border-px "left")
            (ebox-cs-br cs) (border-px "right"))
      ;; Side borders paint as pixel-wide spaces; top and bottom borders are
      ;; the line's overline or underline, so they are at most 1px.
      (dolist (side '("top" "bottom"))
        (when (> (border-px side) 1)
          (signal 'ebox-error
                  (list "Ebox top and bottom borders support only 1px width" side
                        (plist-get vals (intern (format "ebox/border-%s-width" side)))))))
      (setf (ebox-cs-btc cs) (border "top" (border-px "top"))
            (ebox-cs-bbc cs) (border "bottom" (border-px "bottom"))
            (ebox-cs-blc cs) (border "left" (ebox-cs-bl cs))
            (ebox-cs-brc cs) (border "right" (ebox-cs-br cs))
            (ebox-cs-btop cs) (and (ebox-cs-btc cs) t)
            (ebox-cs-bbot cs) (and (ebox-cs-bbc cs) t)))
    (dolist (side '("top" "right" "bottom" "left"))
      (let ((style (plist-get vals (intern (format "ebox/border-%s-style" side)))))
        (when (memq style '(dashed dotted double))
          (signal 'ebox-error (list "Unsupported Ebox border style" style)))))
    cs))

(defun ebox--ch (cs)
  "Return the pixel width of one ch in CS's measuring context.
Computed styles are shared between buffers; only the contextual glyph cache
may retain this value."
  (ebox--char-width ?0 (ebox-cs-fontface cs)))

(defun ebox--line-px ()
  "Return the effective pixel height of one layout line."
  (plist-get (or ebox--active-metrics
                 (ebox--display-metrics ebox--measure-buffer)) :line-height))

(defun ebox--px (value cs base)
  "Resolve inline-axis VALUE in pixels for CS against percent BASE.
Return nil for keywords and unresolvable percentages."
  (cond
   ((null value) nil)
   ((symbolp value) nil)
   ((numberp value) (floor value))
   ((and (eq (car value) 'px) (numberp (cadr value))) (floor (cadr value)))
   ((and (eq (car value) 'ch) (null (cddr value)) (ebox-size--finite-number-p (cadr value)))
    (floor (+ (* (cadr value) (ebox--ch cs)) 1e-9)))
   ((and (eq (car value) '%) (null (cddr value)) (ebox-size--finite-number-p (cadr value))
         (or (null base) (and (integerp base) (>= base 0))))
    (and base (floor (+ (/ (* (cadr value) base) 100.0) 1e-9))))
   (t
    (let ((px (ebox-size-resolve
               value (list :percent-base base :viewport-width ebox--vw
                           :viewport-height (and ebox--vh (* ebox--vh (ebox--line-px)))
                           :ch (ebox--ch cs) :lh (ebox--line-px)))))
      (and px (floor (+ px 1e-9)))))))

(defun ebox--lines (value _cs base)
  "Resolve block-axis VALUE to lines against percent BASE lines."
  (cond
   ((null value) nil)
   ((symbolp value) nil)
   ((numberp value) (floor value))
   ((and (eq (car value) 'lh) (numberp (cadr value))) (floor (+ (cadr value) 1e-9)))
   (t
    (let ((lines (ebox-size-resolve
                  value (list :percent-base base :viewport-height ebox--vh
                              :viewport-width ebox--vw :lh 1 :ch 1))))
      (and lines (floor (+ lines 1e-9)))))))

(defun ebox--pad-lines (value)
  "Return the whole lines block padding VALUE takes, rounding fractions up."
  (let ((lines (cond ((null value) nil)
                     ((symbolp value) nil)
                     ((numberp value) value)
                     ((and (eq (car value) 'lh) (numberp (cadr value))) (cadr value))
                     (t (ebox-size-resolve
                         value (list :viewport-height ebox--vh
                                     :viewport-width ebox--vw :lh 1 :ch 1))))))
    (and lines (max 0 (ceiling (- lines 1e-9))))))

(defun ebox--pad-inset (value lines)
  "Return the pixels of LINES padding lines that fractional VALUE leaves unpainted."
  (let ((exact (cond ((numberp value) value)
                     ((eq (car-safe value) 'lh) (cadr value))
                     ((consp value)
                      (ebox-size-resolve
                       value (list :viewport-height ebox--vh
                                   :viewport-width ebox--vw :lh 1 :ch 1))))))
    (if (and (numberp exact) (< exact lines))
        (let ((lh (ebox--line-px)))
          (- (* lines lh) (round (* exact lh))))
      0)))

(provide 'ebox-node)

;;; ebox-node.el ends here
