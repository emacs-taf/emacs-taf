;;; performance-scenarios.el --- Ebox interaction latency matrix -*- lexical-binding: t; -*-

;;; Commentary:
;; The Ebox gate matrix, run with `scripts/performance.py gate' as described
;; in the workspace manual.  Every scenario mounts a column of N rows at the
;; selected window's width, puts its subject in the middle row and repeats one
;; interaction through the public API.  Ids end with N:
;;
;;   ebox.prop.PROPERTY  toggle each style longhand between two valid values
;;   ebox.text.*         text replacement, width, wrapping and CJK
;;   ebox.state.*        selector states, classes and node rules
;;   ebox.meta.*         data and interaction facts
;;   ebox.tree.*         insertion, removal, moves, filtering and batches
;;   ebox.view.*         viewport size, window and nested scrolling, refit
;;   ebox.input.*        hit testing, focus, activation and typing
;;   ebox.layer.*        root-layer popups and stacking
;;   ebox.global.*       mount, inherited theme and stylesheet swaps
;;   ebox.app.*          interactions with a viewport-filling workbench of N
;;                       bordered flex cards in a scrolling list
;;
;; Loading signals an error unless the property table covers exactly the
;; longhands of `ebox-style-schemas'.  Paint longhands are `local', other
;; longhands `propagate'.  Verification compares the live buffer with a fresh
;; render of a copy of the tree, ignoring only the `ebox-node' reference.

;;; Code:
(require 'cl-lib)
(require 'ebox)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst ebox-benchmark--sizes '(30 400 10000)
  "Row counts of the matrix.")

(defconst ebox-benchmark--property-sizes '(30 10000)
  "Row counts of property scenarios, which only need the size extremes.")

;;;; Fixture

(defun ebox-benchmark--filler (index)
  "Return the author form of filler row INDEX, a bordered flex card.
Its title text is at path (1 0); every fifth row opens a group with a top
border, so each update passes through borders, backgrounds and flex items."
  `(flex :border-left-style solid :border-left-width (px 1) :border-left-color "#5a6b80"
         :border-right-style solid :border-right-width (px 1) :border-right-color "#5a6b80"
         ,@(and (zerop (% index 5))
                '(:border-top-style solid :border-top-width (px 1) :border-top-color "#5a6b80"))
         (box :width (ch 7) :padding-left (ch 1) :background-color "#2a3340"
              ,(format "%05d" index))
         (box :flex-grow 1 :min-width (px 0) :padding-left (ch 1)
              ,(format "row %05d 汉字 ABC abcdefghijklmnopqrstuvwxyz" index))
         (box :padding-left (ch 1) :padding-right (ch 1) :background-color "#334455"
              ,(nth (% index 3) '("todo" "done" "doing")))))

(defun ebox-benchmark--descend (node path)
  "Return NODE's descendant at child index PATH."
  (dolist (index path node)
    (setq node (ebox-node-child node index))))

(defun ebox-benchmark--plist-equal (a b)
  "Return non-nil when property lists A and B match, except `ebox-node' values."
  (and (= (length a) (length b))
       (cl-loop for (key value) on a by #'cddr
                always (and (plist-member b key)
                            (or (eq key 'ebox-node) (equal value (plist-get b key)))))))

(defun ebox-benchmark--render-difference (buffer root fixup)
  "Return nil when BUFFER shows a fresh render of ROOT, else a description.
FIXUP, when non-nil, is called with the copy before rendering."
  (pcase-let* ((`(,width . ,height) (ebox-mount-viewport buffer))
               (copy (ebox-node-copy root))
               (_ (when fixup (funcall fixup copy)))
               (fresh (let ((reference (generate-new-buffer " *Ebox reference*")))
                        (unwind-protect
                            (progn
                              (ebox-mount reference copy :width width :height height)
                              (with-current-buffer reference (buffer-string)))
                          (kill-buffer reference))))
               (live (with-current-buffer buffer (buffer-string)))
               (limit (min (length live) (length fresh)))
               (i 0) (difference nil))
    (if (not (string= live fresh))
        (progn
          (while (and (< i limit) (eq (aref live i) (aref fresh i))) (cl-incf i))
          (format "Line %d differs from a fresh render: %S, expected %S"
                  (1+ (cl-count ?\n live :end i))
                  (substring-no-properties live i (min (length live) (+ i 24)))
                  (substring-no-properties fresh i (min (length fresh) (+ i 24)))))
      (while (and (< i limit) (not difference))
        (if (ebox-benchmark--plist-equal (text-properties-at i live) (text-properties-at i fresh))
            (setq i (min (next-property-change i live limit) (next-property-change i fresh limit)))
          (setq difference
                (let ((print-length 6) (print-level 3))
                  (format "Line %d differs from a fresh render in properties: face %S, expected %S"
                          (1+ (cl-count ?\n live :end i))
                          (get-text-property i 'face live) (get-text-property i 'face fresh))))))
      difference)))

(cl-defun ebox-benchmark--fixture (rows &key subject path root-props invoke check
                                        (fresh t) fixup prepare cleanup)
  "Mount ROWS rows with SUBJECT in the middle and return a gate fixture.
PATH selects the target below the subject row.  ROOT-PROPS extend the root
column.  INVOKE receives the target, the sample index and the root.  CHECK
receives the target and the root and returns t or a failure string; the
fresh-render comparison runs too unless FRESH is nil.  FIXUP receives the
copy's target before the comparison renders it.  PREPARE and CLEANUP receive
the target and the root."
  (let* ((buffer (generate-new-buffer " *Ebox gate*"))
         (middle (/ rows 2))
         (form `(column :width stretch ,@root-props
                        ,@(cl-loop for i below rows
                                   collect (if (and subject (= i middle)) subject
                                             (ebox-benchmark--filler i)))))
         (root (ebox-mount buffer form :width (window-body-width nil t)))
         (target (ebox-benchmark--descend (ebox-node-child root middle) path)))
    (append
     (and prepare (list :prepare (lambda () (funcall prepare target root))))
     (list :buffer buffer
           :invoke (lambda (sample) (funcall invoke target sample root))
           :observe (lambda (sink)
                      (ebox-buffer-set-observer buffer sink)
                      (lambda ()
                        (when (buffer-live-p buffer) (ebox-buffer-set-observer buffer nil))))
           :verify (lambda ()
                     (let ((own (and check (funcall check target root))))
                       (cond ((stringp own) own)
                             ((and fresh
                                   (ebox-benchmark--render-difference
                                    buffer root
                                    (and fixup
                                         (lambda (copy)
                                           (funcall fixup (ebox-benchmark--descend
                                                           (ebox-node-child copy middle) path)))))))
                             (t t))))
           :cleanup (lambda ()
                      (when cleanup (funcall cleanup target root))
                      (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun ebox-benchmark--register (id sizes class description setup &optional twin)
  "Register ID.N for each of SIZES with gate CLASS and TWIN (default diff).
DESCRIPTION is a format string taking N; SETUP is called with N."
  (dolist (size sizes)
    (let ((rows size))
      (taf-benchmark-register
       (format "%s.%d" id rows)
       :version 1 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 16
       :description (format description rows)
       :gate (list :class class :twin (if (eq twin 'none) nil (or twin 'diff)))
       :setup (lambda (_mode) (funcall setup rows))))))

(defun ebox-benchmark--toggle (values)
  "Return an invoke function alternating the target between VALUES via setters.
VALUES is (SETTER A B); even samples apply B and odd samples A."
  (pcase-let ((`(,setter ,a ,b) values))
    (lambda (target sample _root) (funcall setter target (if (cl-evenp sample) b a)))))

;;;; Properties

(defun ebox-benchmark--merge (props defaults)
  "Return PROPS followed by the DEFAULTS whose keys PROPS lacks."
  (append props (cl-loop for (key value) on defaults by #'cddr
                         unless (plist-member props key) append (list key value))))

(defun ebox-benchmark--subject (context props)
  "Return (FORM . PATH) of a CONTEXT subject whose target has PROPS."
  (pcase context
    ('text (cons `(box (text ,@props "subject 汉字 text")) '(0)))
    ('box (cons `(box (box ,@(ebox-benchmark--merge props '(:background-color "#334455"))
                           (text "subject 汉字 box content")))
                '(0)))
    ('row (cons `(row ,@props (box :background-color "#334455" "alpha")
                      (box :height (lh 2) "beta 汉字") (box :background-color "#553344" "gamma"))
                nil))
    ('flex (cons `(flex ,@props (box :background-color "#334455" "alpha")
                        (box :height (lh 2) "beta 汉字") (box :background-color "#553344" "gamma"))
                 nil))
    ('grid (cons `(grid ,@(ebox-benchmark--merge props '(:grid-template-columns ((ch 12) (ch 12))))
                        (box :background-color "#334455" "a") (box "b 汉字") (box "c")
                        (box :background-color "#553344" "d"))
                 nil))
    ('grid-flow (cons `(grid ,@props (box :background-color "#334455" "a") (box "b 汉字") (box "c")
                             (box :background-color "#553344" "d"))
                      nil))
    ('flex-item (cons `(flex (box :background-color "#334455" "alpha")
                             (box ,@(ebox-benchmark--merge props '(:background-color "#445566"))
                                  "beta 汉字")
                             (box :height (lh 2) "gamma"))
                      '(1)))
    ('grid-item (cons `(grid :grid-template-columns ((ch 12) (ch 12) (ch 12))
                             (box "a")
                             (box ,@(ebox-benchmark--merge props '(:background-color "#445566"))
                                  "b 汉字")
                             (box "c") (box "d"))
                      '(1)))
    ('backdrop
     (cons `(box :height (lh 2)
                  (text :color "#ddeeff" :background-color "#445566"
                        "Content behind the modal")
                  (box ,@props :position absolute :layer root
                       :left (px 0) :top (lh 0) :width (ch 30) :height (lh 2)))
           '(1)))
    ('anchored (cons `(box (box :id "anchor-a" :width (ch 10) "ANCHOR A")
                           (box :id "anchor-b" :width (ch 10) "ANCHOR B")
                           (box ,@(ebox-benchmark--merge
                                   props '(:position absolute :layer root :anchor "anchor-a"
                                           :width (ch 8) :height (lh 1) :background-color "#664422"))
                                "POPUP"))
                     '(2)))
    (_ (error "Unknown property context %S" context))))

(defconst ebox-benchmark--properties
  '((:color text "#ff8800" "#00aaff")
    (:background-color text "#223344" "#443322")
    (:backdrop-filter backdrop none (brightness 0.55))
    (:font-family text "Menlo" "Monaco")
    (:font-size text 13 16)
    (:font-weight text normal bold)
    (:font-style text normal italic)
    (:text-decoration-line text none underline)
    (:text-decoration-color text "#ff0000" "#00ff00" :text-decoration-line underline)
    (:text-decoration-style text solid wavy :text-decoration-line underline)
    (:box-sizing box border-box content-box :width (ch 24) :padding-left (ch 2))
    (:position box static relative :left (ch 2))
    (:left box (ch 1) (ch 3) :position relative)
    (:top box (lh 0) (lh 1) :position relative)
    (:z-index box 0 1 :position relative)
    (:layer anchored local root)
    (:anchor anchored "anchor-a" "anchor-b")
    (:placement anchored bottom-start top-end)
    (:width box (ch 24) (ch 32))
    (:min-width box (ch 10) (ch 36) :width fit-content)
    (:max-width box (ch 40) (ch 20))
    (:height box (lh 1) (lh 2))
    (:min-height box (lh 1) (lh 2))
    (:max-height box (lh 3) (lh 1) :height (lh 2))
    (:padding-top box (lh 0) (lh 1))
    (:padding-right box (ch 0) (ch 2) :width fit-content)
    (:padding-bottom box (lh 0) (lh 1))
    (:padding-left box (ch 0) (ch 2))
    (:padding-block-start box (lh 0) (lh 1))
    (:padding-inline-end box (ch 0) (ch 2) :width fit-content)
    (:padding-block-end box (lh 0) (lh 1))
    (:padding-inline-start box (ch 0) (ch 2))
    (:margin-top box (lh 0) (lh 1))
    (:margin-right box (ch 0) (ch 2) :width fit-content)
    (:margin-bottom box (lh 0) (lh 1))
    (:margin-left box (ch 0) (ch 2))
    (:margin-block-start box (lh 0) (lh 1))
    (:margin-inline-end box (ch 0) (ch 2) :width fit-content)
    (:margin-block-end box (lh 0) (lh 1))
    (:margin-inline-start box (ch 0) (ch 2))
    (:border-top-width box (px 0) (px 1) :border-top-style solid)
    (:border-right-width box (px 0) (px 1) :border-right-style solid)
    (:border-bottom-width box (px 0) (px 1) :border-bottom-style solid)
    (:border-left-width box (px 0) (px 1) :border-left-style solid)
    (:border-top-style box none solid)
    (:border-right-style box none solid)
    (:border-bottom-style box none solid)
    (:border-left-style box none solid)
    (:border-top-color box "#ff0000" "#00ff00" :border-top-style solid)
    (:border-right-color box "#ff0000" "#00ff00" :border-right-style solid)
    (:border-bottom-color box "#ff0000" "#00ff00" :border-bottom-style solid)
    (:border-left-color box "#ff0000" "#00ff00" :border-left-style solid)
    (:border-radius box (px 0) (px 4) :border ((px 1) solid "#8899aa"))
    (:text-align box left right :width (ch 40))
    (:overflow box hidden visible :height (lh 1) :width (ch 10))
    (:scroll-anchor box start end :overflow scroll :height (lh 1))
    (:wrap-mode box word none :width (ch 12))
    (:visibility box visible hidden)
    (:outer box block inline)
    (:item-gap row (ch 0) (ch 2))
    (:cross-align row stretch center)
    (:flex-direction flex row column)
    (:flex-wrap flex nowrap wrap :width (ch 12))
    (:justify-content flex flex-start center)
    (:align-items flex stretch center)
    (:align-content flex stretch center :flex-wrap wrap :width (ch 12) :height (lh 5))
    (:justify-items grid stretch center)
    (:row-gap flex (lh 0) (lh 1) :flex-wrap wrap :width (ch 12))
    (:column-gap flex (ch 0) (ch 2))
    (:order flex-item 0 5)
    (:flex-grow flex-item 0 1)
    (:flex-shrink flex-item 1 0 :flex-basis (ch 200))
    (:flex-basis flex-item auto (ch 20))
    (:align-self flex-item auto center)
    (:justify-self grid-item auto center)
    (:grid-template-columns grid ((ch 12) (ch 12)) ((ch 16) (fr 1)))
    (:grid-template-rows grid ((lh 1)) ((lh 1) (lh 2)))
    (:grid-auto-columns grid-flow auto (ch 10)
                        :grid-auto-flow column :grid-template-rows ((lh 1) (lh 1)))
    (:grid-auto-rows grid auto (lh 2))
    (:grid-auto-flow grid row column :grid-template-rows ((lh 1) (lh 1)))
    (:grid-column grid-item auto 3)
    (:grid-row grid-item auto 2))
  "Style longhands as (NAME CONTEXT A B . BASE-PROPS).
The target starts with NAME A plus BASE-PROPS; samples alternate B and A.")

(defun ebox-benchmark--longhands ()
  "Return the style longhand names of `ebox-style-schemas'."
  (cl-loop for id in (ecss-schema-set-property-ids ebox-style-schemas)
           for metadata = (ebox-style-property id)
           unless (plist-get metadata :shorthand) collect (plist-get metadata :name)))

(let* ((covered (mapcar #'car ebox-benchmark--properties))
       (longhands (ebox-benchmark--longhands))
       (missing (cl-set-difference longhands covered))
       (unknown (cl-set-difference covered longhands)))
  (when (or missing unknown (/= (length covered) (length (delete-dups (copy-sequence covered)))))
    (error "Ebox property matrix mismatch: missing %S, unknown %S" missing unknown)))

(dolist (property ebox-benchmark--properties)
  (pcase-let* ((`(,name ,context ,a ,b . ,base) property)
               (class (if (eq (plist-get (ebox-style-property name) :dirty-kind) 'paint)
                          'local 'propagate)))
    (ebox-benchmark--register
     (format "ebox.prop.%s" (substring (symbol-name name) 1))
     ebox-benchmark--property-sizes class
     (format "Toggle %s between %S and %S in a %s among %%d rows" name a b context)
     (lambda (rows)
       (pcase-let ((`(,subject . ,path)
                    (ebox-benchmark--subject context (append (list name a) base))))
         (ebox-benchmark--fixture
          rows :subject subject :path path
          :invoke (ebox-benchmark--toggle
                   (list (lambda (target value) (ebox-node-put target name value)) a b))))))))

;;;; Text

(defun ebox-benchmark--text-fixture (rows subject path texts)
  "Alternate the text at PATH of SUBJECT among ROWS rows through TEXTS.
TEXTS is a function from the sample index to the next string."
  (let ((expected nil))
    (ebox-benchmark--fixture
     rows :subject subject :path path
     :invoke (lambda (target sample _root)
               (setq expected (funcall texts sample))
               (ebox-node-set-text target expected))
     :check (lambda (target _root)
              (if (equal (ebox-benchmark--painted-words target) (split-string expected))
                  t
                (format "Painted text is not %S" expected))))))

(defun ebox-benchmark--painted-words (node)
  "Return the words NODE paints across its parent's lines, which may wrap."
  (let ((bounds (ebox-node-bounds node))
        (height (plist-get (ebox-node-geometry (ebox-node-parent node)) :height))
        chars)
    (when bounds
      (with-current-buffer (ebox-node-buffer node)
        (let ((pos (car bounds))
              (end (save-excursion (goto-char (car bounds)) (forward-line height) (point))))
          (while (< pos end)
            (push (if (eq (ebox-node-at pos) node) (char-after pos) ?\s) chars)
            (setq pos (1+ pos))))))
    (split-string (apply #'string (nreverse chars)))))

(ebox-benchmark--register
 "ebox.text.same" ebox-benchmark--sizes 'local
 "Replace a same-width text in a fixed-width box among %d rows"
 (lambda (rows)
   (ebox-benchmark--text-fixture
    rows '(box :width (ch 40) (text "subject 汉字 text 0000")) '(0)
    (lambda (sample) (format "subject 汉字 text %04d" sample)))))

(ebox-benchmark--register
 "ebox.text.fixed" ebox-benchmark--sizes 'local
 "Replace a variable-width text in a fixed-width box among %d rows"
 (lambda (rows)
   (ebox-benchmark--text-fixture
    rows '(box :width (ch 40) :wrap-mode none :overflow hidden (text "0000")) '(0)
    (lambda (sample) (format "%04d%s" sample (make-string (% (* 7 sample) 30) ?x))))))

(ebox-benchmark--register
 "ebox.text.flex" ebox-benchmark--sizes 'propagate
 "Replace a variable-width text in an auto flex item among %d rows"
 (lambda (rows)
   (ebox-benchmark--text-fixture
    rows '(flex :column-gap (ch 1) (box (text "0000")) (box :flex-grow 1 :background-color "#334455" "rest")
                (box :width (ch 8) "fixed"))
    '(0 0)
    (lambda (sample) (format "%04d%s" sample (make-string (% (* 7 sample) 30) ?x))))))

(ebox-benchmark--register
 "ebox.text.wrap" ebox-benchmark--sizes 'propagate
 "Change a wrapping text between one and three lines among %d rows"
 (lambda (rows)
   (ebox-benchmark--text-fixture
    rows '(box :width (ch 20) (text "short")) '(0)
    (lambda (sample)
      (if (cl-evenp sample) "a longer text that wraps onto three lines here" "short")))))

(ebox-benchmark--register
 "ebox.text.cjk" ebox-benchmark--sizes 'local
 "Replace a same-width CJK text among %d rows"
 (lambda (rows)
   (ebox-benchmark--text-fixture
    rows '(box :width (ch 20) (text "汉字测试一")) '(0)
    (lambda (sample) (if (cl-evenp sample) "中文显示二" "汉字测试一")))))

;;;; States and metadata

(defun ebox-benchmark--state-fixture (rows root-rules setter a b)
  "Toggle the subject through SETTER between A and B with ROOT-RULES."
  (let ((current a))
    (ebox-benchmark--fixture
     rows :subject '(box :id subject :background-color "#334455" (text "subject 汉字 state"))
     :root-props (list :ecss root-rules)
     :invoke (lambda (target sample _root)
               (setq current (if (cl-evenp sample) b a))
               (funcall setter target current))
     :fixup (lambda (copy) (funcall setter copy current)))))

(ebox-benchmark--register
 "ebox.state.hover" ebox-benchmark--sizes 'local
 "Toggle a hover selector state among %d rows"
 (lambda (rows)
   (ebox-benchmark--state-fixture
    rows '(("#subject:hover" :background-color "#556677")) #'ebox-node-set-states nil '(hover))))

(ebox-benchmark--register
 "ebox.state.class" ebox-benchmark--sizes 'local
 "Toggle a class matched by a root rule among %d rows"
 (lambda (rows)
   (ebox-benchmark--state-fixture
    rows '((".on" :color "#ff8800"))
    (lambda (node value) (ebox-node-put node :class value)) nil 'on)))

(ebox-benchmark--register
 "ebox.state.ecss" ebox-benchmark--sizes 'local
 "Swap a node's own rules among %d rows"
 (lambda (rows)
   (ebox-benchmark--state-fixture
    rows nil (lambda (node value) (ebox-node-put node :ecss value))
    '(("&" :color "#ff0000")) '(("&" :color "#00ff00")))))

(dolist (entry '(("data" :data 1 2) ("help-echo" :help-echo "first tip" "second tip")))
  (pcase-let ((`(,name ,key ,a ,b) entry))
    (ebox-benchmark--register
     (concat "ebox.meta." name) ebox-benchmark--sizes 'local
     (format "Change a node's %s among %%d rows" key)
     (lambda (rows)
       (ebox-benchmark--fixture
        rows :subject `(box ,key ,a (text "subject 汉字 meta")) :path nil
        :invoke (ebox-benchmark--toggle
                 (list (lambda (target value) (ebox-node-put target key value)) a b)))))))

(ebox-benchmark--register
 "ebox.meta.keymap" ebox-benchmark--sizes 'local
 "Swap a node's keymap among %d rows"
 (lambda (rows)
   (let ((a (make-sparse-keymap)) (b (make-sparse-keymap)))
     (define-key a (kbd "RET") #'ignore)
     (define-key b (kbd "SPC") #'ignore)
     (ebox-benchmark--fixture
      rows :subject `(box :keymap ,a (text "subject 汉字 keymap"))
      :invoke (ebox-benchmark--toggle
               (list (lambda (target value) (ebox-node-put target :keymap value)) a b))))))

;;;; Tree

(defun ebox-benchmark--row-node (index)
  "Return a detached filler row INDEX."
  (ebox-build (ebox-benchmark--filler index)))

(defun ebox-benchmark--count-check (expected)
  "Return a check that the root has EXPECTED children, a function of no arguments."
  (lambda (_target root)
    (let ((count (ebox-node-child-count root)) (wanted (funcall expected)))
      (if (= count wanted) t (format "Root has %d children; expected %d" count wanted)))))

(dolist (entry '(("head" . 0) ("middle" . middle) ("end" . end)))
  (pcase-let ((`(,name . ,where) entry))
    (ebox-benchmark--register
     (concat "ebox.tree.toggle-" name) ebox-benchmark--sizes 'structure
     (format "Insert or remove one row at the %s of %%d rows" name)
     (lambda (rows)
       (let ((row (ebox-benchmark--row-node 99999)) (count rows))
         (ebox-benchmark--fixture
          rows
          :invoke (lambda (_target sample root)
                    (if (cl-evenp sample)
                        (ebox-node-insert root row (pcase where
                                                     ('middle (/ rows 2))
                                                     ('end nil)
                                                     (_ where)))
                      (ebox-node-remove row))
                    (setq count (ebox-node-child-count root)))
          :check (ebox-benchmark--count-check (lambda () count))))))))

(ebox-benchmark--register
 "ebox.tree.move" ebox-benchmark--sizes 'structure
 "Move one row five places and back among %d rows"
 (lambda (rows)
   (ebox-benchmark--fixture
    rows :subject '(box :background-color "#334455" (text "moving row 汉字")) :path nil
    :invoke (lambda (target sample _root)
              (ebox-node-move target (+ (/ rows 2) (if (cl-evenp sample) 5 0)))))))

(ebox-benchmark--register
 "ebox.tree.filter" ebox-benchmark--sizes 'rows
 "Filter %d rows to the even ones and back"
 (lambda (rows)
   (let (all even (count rows))
     (ebox-benchmark--fixture
      rows
      :prepare (lambda (_target root)
                 (unless all
                   (setq all (ebox-node-children root)
                         even (cl-loop for node in all for i from 0 when (cl-evenp i) collect node))))
      :invoke (lambda (_target sample root)
                (ebox-node-replace-children root (if (cl-evenp sample) even all))
                (setq count (ebox-node-child-count root)))
      :check (ebox-benchmark--count-check (lambda () count))))))

(ebox-benchmark--register
 "ebox.tree.block" ebox-benchmark--sizes 'structure
 "Insert or remove a 20-row block in the middle of %d rows"
 (lambda (rows)
   (let ((block (ebox-build `(column ,@(cl-loop for i below 20 collect (ebox-benchmark--filler (+ 90000 i)))))))
     (ebox-benchmark--fixture
      rows
      :invoke (lambda (_target sample root)
                (if (cl-evenp sample) (ebox-node-insert root block (/ rows 2)) (ebox-node-remove block)))))))

(ebox-benchmark--register
 "ebox.tree.batch" ebox-benchmark--sizes 'structure
 "Update ten scattered row texts in one batch among %d rows"
 (lambda (rows)
   (let (texts)
     (ebox-benchmark--fixture
      rows
      :prepare (lambda (_target root)
                 (setq texts (cl-loop for i below 10
                                      collect (ebox-benchmark--descend
                                               (ebox-node-child root (/ (* i rows) 10)) '(1 0)))))
      :invoke (lambda (_target sample _root)
                (ebox-with-batch
                  (cl-loop for text in texts for i from 0
                           do (ebox-node-set-text
                               text (format "row %05d 汉字 ABC batch %06d........" i sample)))))))))

;;;; Viewport

(defun ebox-benchmark--resize-rows (rows)
  "Return ROWS wrapping flex rows."
  (cl-loop for row below rows
           collect `(flex :column-gap (ch 1)
                          (box :width (ch 8) ,(format "%05d" row))
                          (box :flex-grow 1 :min-width (px 0)
                               ,(concat "汉字 wrapping body text " (make-string (% (* 13 row) 60) ?w))))))

(ebox-benchmark--register
 "ebox.view.width" ebox-benchmark--sizes 'rows
 "Relayout %d wrapping rows for another viewport width"
 (lambda (rows)
   (let* ((buffer (generate-new-buffer " *Ebox gate resize*"))
          (full (window-body-width nil t)) (width full)
          (root (ebox-mount buffer `(column :width stretch ,@(ebox-benchmark--resize-rows rows))
                            :width full)))
     (list :buffer buffer
           :invoke (lambda (sample)
                     (setq width (if (cl-evenp sample) (/ (* full 3) 5) full))
                     (ebox-mount-set-viewport buffer width nil))
           :observe (lambda (sink)
                      (ebox-buffer-set-observer buffer sink)
                      (lambda () (when (buffer-live-p buffer) (ebox-buffer-set-observer buffer nil))))
           :verify (lambda ()
                     (cond ((not (eql (car (ebox-mount-viewport buffer)) width))
                            (format "Viewport is %S; expected width %S" (ebox-mount-viewport buffer) width))
                           ((ebox-benchmark--render-difference buffer root nil))
                           (t t)))
           :cleanup (lambda () (kill-buffer buffer))))))

(ebox-benchmark--register
 "ebox.view.height" ebox-benchmark--sizes 'propagate
 "Change the viewport height under a nested viewport-relative box among %d rows"
 (lambda (rows)
   (let ((height nil))
     (ebox-benchmark--fixture
      rows :subject '(box :width (ch 30)
                          (box :height (vh 20) :background-color "#334455" "viewport box"))
      :path nil
      :invoke (lambda (target sample _root)
                (let* ((buffer (ebox-node-buffer target))
                       (full (window-body-height (get-buffer-window buffer))))
                  (setq height (if (cl-evenp sample) (/ full 2) full))
                  (ebox-mount-set-viewport buffer (car (ebox-mount-viewport buffer)) height)))
      :check (lambda (target _root)
               (let ((viewport (ebox-mount-viewport (ebox-node-buffer target))))
                 (if (eql (cdr viewport) height) t
                   (format "Viewport is %S; expected height %S" viewport height))))))))

(ebox-benchmark--register
 "ebox.view.scroll" '(400 10000) 'local
 "Scroll the window three lines and back over %d rows"
 (lambda (rows)
   (ebox-benchmark--fixture
    rows
    :invoke (lambda (_target _sample _root)
              (if (= (window-start) (point-min)) (scroll-up 3) (scroll-down 3)))
    :check (lambda (_target _root) t)))
 'replay)

(ebox-benchmark--register
 "ebox.view.nested" ebox-benchmark--sizes 'local
 "Scroll a nested container three lines and back among %d rows"
 (lambda (rows)
   (let ((offset 0))
     (ebox-benchmark--fixture
      rows :subject `(box :height (lh 5) :overflow scroll :background-color "#334455"
                          ,@(cl-loop for i below 20 collect `(box ,(format "nested line %02d" i))))
      :path nil :fresh nil
      :invoke (lambda (target sample _root)
                (setq offset (ebox-node-set-scroll target (if (cl-evenp sample) 3 0))))
      :check (lambda (target _root)
               (let ((line (with-current-buffer (ebox-node-buffer target)
                             (save-excursion
                               (goto-char (car (ebox-node-bounds target)))
                               (buffer-substring-no-properties (point) (line-end-position)))))
                     (wanted (format "nested line %02d" offset)))
                 (if (and (= (ebox-node-scroll-offset target) offset) (string-search wanted line)) t
                   (format "Nested offset %d shows %S" (ebox-node-scroll-offset target) line))))))))

(ebox-benchmark--register
 "ebox.view.refit" ebox-benchmark--sizes 'local
 "Refit an unchanged viewport over %d rows"
 (lambda (rows)
   (ebox-benchmark--fixture
    rows
    :invoke (lambda (target _sample _root) (ebox-refit (ebox-node-buffer target)))))
 'none)

;;;; Input

(ebox-benchmark--register
 "ebox.input.hit" ebox-benchmark--sizes 'local
 "Resolve the node at two positions of a row among %d rows"
 (lambda (rows)
   (let (positions found)
     (ebox-benchmark--fixture
      rows :subject '(row (box :width (ch 10) "left") (box :width (ch 10) (text "right"))) :path nil
      :prepare (lambda (target _root)
                 (setq positions (list (car (ebox-node-bounds (ebox-node-child target 0)))
                                       (car (ebox-node-bounds (ebox-node-child target 1))))))
      :invoke (lambda (target sample _root)
                (setq found (ebox-node-at (nth (% sample 2) positions) (ebox-node-buffer target))))
      :check (lambda (target _root)
               (if (and found (ebox-node-ancestor-p target found)) t
                 "Hit test did not resolve inside the subject")))))
 'none)

(ebox-benchmark--register
 "ebox.input.focus" ebox-benchmark--sizes 'local
 "Move focus among three styled controls among %d rows"
 (lambda (rows)
   (ebox-benchmark--fixture
    rows :subject '(row :item-gap (ch 1) (box :tab-index 0 "one") (box :tab-index 0 "two")
                        (box :tab-index 0 "three"))
    :path nil :fresh nil
    :root-props '(:ecss (("box:focus" :background-color "#aa5500")))
    :prepare (lambda (target _root) (ebox-focus (ebox-node-child target 0) (ebox-node-buffer target)))
    :invoke (lambda (target _sample _root) (ebox-focus-next 1 t (ebox-node-buffer target)))
    :check (lambda (target _root)
             (let ((focused (ebox-focused-node (ebox-node-buffer target))))
               (if (and focused (ebox-node-ancestor-p target focused)) t
                 "Focus left the subject controls"))))))

(ebox-benchmark--register
 "ebox.input.activate" ebox-benchmark--sizes 'local
 "Activate a control's RET binding among %d rows"
 (lambda (rows)
   (let ((map (make-sparse-keymap)) (count 0) (position nil) (calls 0))
     (define-key map (kbd "RET") (lambda () (interactive) (cl-incf count)))
     (ebox-benchmark--fixture
      rows :subject `(box :keymap ,map :background-color "#334455" (text "activate 汉字")) :path nil
      :prepare (lambda (target _root) (setq position (car (ebox-node-bounds target))))
      :invoke (lambda (target _sample _root)
                (cl-incf calls)
                (with-current-buffer (ebox-node-buffer target) (ebox-activate position)))
      :check (lambda (_target _root)
               (if (= count calls) t (format "%d activations ran %d commands" calls count))))))
 'none)

(ebox-benchmark--register
 "ebox.input.type" ebox-benchmark--sizes 'local
 "Type and erase a character in an input session among %d rows"
 (lambda (rows)
   (let (session position)
     (ebox-benchmark--fixture
      rows :subject '(box :width (ch 30) (text "editable 汉字")) :path '(0) :fresh nil
      :prepare (lambda (target _root)
                 (unless session
                   (setq session (ebox-input-begin (ebox-node-buffer target) target)))
                 (setq position (cdr (ebox-node-bounds target))))
      :invoke (lambda (_target sample _root)
                (if (cl-evenp sample)
                    (save-excursion (goto-char position) (insert "x"))
                  (delete-region position (1+ position))))
      :check (lambda (_target _root)
               (let ((text (ebox-input-text session)))
                 (if (member text '("editable 汉字" "editable 汉字x")) t
                   (format "Session text is %S" text))))
      :cleanup (lambda (_target _root)
                 (when session (ebox-input-end session))))))
 'replay)

;;;; Layers

(ebox-benchmark--register
 "ebox.layer.popup" ebox-benchmark--sizes 'local
 "Show or hide an anchored root-layer popup among %d rows"
 (lambda (rows)
   (pcase-let ((`(,subject . ,path) (ebox-benchmark--subject 'anchored '(:visibility hidden))))
     (ebox-benchmark--fixture
      rows :subject subject :path path
      :invoke (ebox-benchmark--toggle
               (list (lambda (target value) (ebox-node-put target :visibility value))
                     'hidden 'visible))))))

(ebox-benchmark--register
 "ebox.layer.stack" ebox-benchmark--sizes 'local
 "Raise one of two overlapping popups among %d rows"
 (lambda (rows)
   (ebox-benchmark--fixture
    rows :subject '(box (box :id "anchor-a" :width (ch 10) "ANCHOR")
                        (box :position absolute :layer root :anchor "anchor-a" :width (ch 8)
                             :height (lh 1) :z-index 1 :background-color "#664422" "FIRST")
                        (box :position absolute :layer root :anchor "anchor-a" :width (ch 8)
                             :height (lh 1) :z-index 0 :background-color "#226644" "SECOND"))
    :path '(2)
    :invoke (ebox-benchmark--toggle
             (list (lambda (target value) (ebox-node-put target :z-index value)) 0 2)))))

;;;; Global

(ebox-benchmark--register
 "ebox.global.mount" ebox-benchmark--sizes 'rows
 "Mount %d rows into the displayed buffer"
 (lambda (rows)
   (let ((buffer (generate-new-buffer " *Ebox gate mount*"))
         (form `(column :width stretch ,@(cl-loop for i below rows collect (ebox-benchmark--filler i))))
         (root nil))
     (list :buffer buffer
           :invoke (lambda (_sample) (setq root (ebox-mount buffer form :width (window-body-width nil t))))
           :verify (lambda () (or (ebox-benchmark--render-difference buffer root nil) t))
           :cleanup (lambda () (kill-buffer buffer)))))
 'none)

(ebox-benchmark--register
 "ebox.global.theme" ebox-benchmark--sizes 'rows
 "Change the inherited root color of %d rows"
 (lambda (rows)
   (ebox-benchmark--fixture
    rows :root-props '(:color "#dddddd")
    :invoke (lambda (_target sample root)
              (ebox-node-put root :color (if (cl-evenp sample) "#88ccff" "#dddddd"))))))

(ebox-benchmark--register
 "ebox.global.stylesheet" ebox-benchmark--sizes 'rows
 "Swap the root stylesheet of %d rows"
 (lambda (rows)
   (ebox-benchmark--fixture
    rows :root-props '(:ecss (("box" :background-color "#223344")))
    :invoke (lambda (_target sample root)
              (ebox-node-put root :ecss (if (cl-evenp sample)
                                            '(("box" :background-color "#332244"))
                                          '(("box" :background-color "#223344"))))))))

;;;; Application

(defconst ebox-benchmark--app-line "#4a5a70"
  "Border color of the workbench application.")

(defun ebox-benchmark--card (index)
  "Return the author form of workbench card INDEX.
The title text is at path (1 0 0 0) below the card and the detail column at
path (1)."
  `(flex :class "card" :id ,(format "card-%d" index)
         :border-left-style solid :border-left-width (px 1) :border-left-color ,ebox-benchmark--app-line
         :border-right-style solid :border-right-width (px 1) :border-right-color ,ebox-benchmark--app-line
         :border-top-style solid :border-top-width (px 1) :border-top-color ,ebox-benchmark--app-line
         :column-gap (ch 1) :padding-right (ch 1)
         (box :width (ch 4) :text-align center
              :background-color ,(nth (% index 4) '("#3b5b7a" "#6a4a7a" "#4a7a5a" "#7a6a3a"))
              ,(string (+ ?A (% index 26))))
         (column :flex-grow 1 :min-width (px 0)
                 (flex :column-gap (ch 1)
                       (box :font-weight bold :flex-grow 1 :min-width (px 0)
                            ,(format "Task %05d 汉字 review layout" index))
                       (box :color "#8899aa" ,(format "%02d:%02d" (% index 24) (% (* index 7) 60))))
                 (flex :column-gap (ch 1)
                       (box :background-color "#2d4a3a" :padding-left (ch 1) :padding-right (ch 1)
                            ,(nth (% index 3) '("todo" "doing" "done")))
                       (box :color "#8899aa" :flex-grow 1 :min-width (px 0)
                            ,(format "owner %s · %d comments"
                                     (nth (% index 5) '("alice" "bob" "carol" "dave" "erin"))
                                     (% index 13)))))))

(defun ebox-benchmark--workbench (cards)
  "Return a viewport-filling workbench application with CARDS list cards.
A header with tabs, a badge and a menu popup sits above a sidebar, a main
column holding a toolbar and a scrolling card list, and a detail grid; a
status bar closes the column.  Fixed bars do not shrink because the initial
overflow is `scroll'."
  (let ((line ebox-benchmark--app-line))
    `(flex :id "app" :flex-direction column :width stretch :height (vh 100)
           :ecss ((".card:selected" :background-color "#24364a"))
           (flex :id "header" :flex-shrink 0 :background-color "#1f2630" :column-gap (ch 2)
                 :padding-left (ch 1) :padding-right (ch 1)
                 :border-bottom-style solid :border-bottom-width (px 1) :border-bottom-color ,line
                 (box :font-weight bold "Ebox Workbench")
                 (flex :id "tabs" :column-gap (ch 1)
                       (box :id "tab-0" :background-color "#3b5b7a" :padding-left (ch 1)
                            :padding-right (ch 1) "Inbox")
                       (box :id "tab-1" :padding-left (ch 1) :padding-right (ch 1) "Projects")
                       (box :id "tab-2" :padding-left (ch 1) :padding-right (ch 1) "Archive"))
                 (box :flex-grow 1)
                 (box :id "badge" :background-color "#aa3333" :padding-left (ch 1)
                      :padding-right (ch 1) "3")
                 (box :id "menu-button" "≡ Menu")
                 (column :id "menu" :position absolute :layer root :anchor "menu-button"
                         :placement bottom-end :visibility hidden :width (ch 16)
                         :background-color "#26303c"
                         :border-left-style solid :border-left-width (px 1) :border-left-color ,line
                         :border-right-style solid :border-right-width (px 1) :border-right-color ,line
                         :border-bottom-style solid :border-bottom-width (px 1) :border-bottom-color ,line
                         (box :padding-left (ch 1) "New task")
                         (box :padding-left (ch 1) "Import…")
                         (box :padding-left (ch 1) "Settings")
                         (box :padding-left (ch 1) "Quit")))
           (flex :id "body" :flex 1 :min-height (lh 0)
                 (column :id "sidebar" :width (ch 22) :padding-left (ch 1)
                         :border-right-style solid :border-right-width (px 1) :border-right-color ,line
                         (box :font-weight bold "Folders")
                         ,@(cl-loop for folder below 6 collect
                                    `(flex :id ,(format "folder-%d" folder) :column-gap (ch 1)
                                           (box ,(if (= folder 0) "▾" "▸"))
                                           (box :flex-grow 1 :min-width (px 0)
                                                ,(nth folder '("Inbox" "Today" "Upcoming"
                                                               "Projects" "Notes" "Trash")))
                                           (box :color "#8899aa" ,(format "%d" (* 3 (1+ folder)))))))
                 (flex :id "main" :flex-direction column :flex 1 :min-width (px 0)
                       (flex :id "toolbar" :flex-shrink 0 :column-gap (ch 1) :padding-left (ch 1)
                             (box :id "search" :width (ch 24) :background-color "#26303c" "search…")
                             (box "Sort ▾")
                             (box :flex-grow 1)
                             (box :id "count" ,(format "%d items" cards)))
                       (column :id "list" :flex 1 :min-height (lh 0) :overflow scroll
                               ,@(cl-loop for index below cards collect (ebox-benchmark--card index))))
                 (column :id "detail" :width (ch 30) :padding-left (ch 1)
                         :border-left-style solid :border-left-width (px 1) :border-left-color ,line
                         (box :font-weight bold "Details")
                         (grid :grid-template-columns ((ch 10) (fr 1))
                               (box "Owner") (box :id "owner" "alice")
                               (box "Status") (box :id "status" "doing")
                               (box "Due") (box :id "due" "2025-10-08")
                               (box "Progress")
                               (box :background-color "#26303c"
                                    (box :id "progress" :width (% 40) :background-color "#2d7d46"
                                         "40%")))))
           (flex :id "status-bar" :flex-shrink 0 :background-color "#1f2630"
                 :padding-left (ch 1) :padding-right (ch 1)
                 :border-top-style solid :border-top-width (px 1) :border-top-color ,line
                 (box :id "status-text" "Ready")
                 (box :flex-grow 1)
                 (box :id "clock" "12:00:00")))))

(defun ebox-benchmark--finder (root)
  "Return a memoizing function from an id string to ROOT's node with that id."
  (let ((found (make-hash-table :test #'equal)))
    (lambda (id)
      (or (gethash id found)
          (puthash id (or (car (ebox-selector-query root (concat "#" id)))
                          (error "No node #%s" id))
                   found)))))

(cl-defun ebox-benchmark--app (cards &key invoke check prepare cleanup (fresh t) fixup)
  "Mount the workbench with CARDS cards in `ebox-buffer-mode'; return a fixture.
INVOKE receives an id finder, the sample index and the root.  CHECK receives
the finder and returns t or a failure string; the fresh-render comparison
runs too unless FRESH is nil.  FIXUP receives the finder of the rendered copy.
PREPARE and CLEANUP receive the finder."
  (let* ((buffer (generate-new-buffer " *Ebox gate app*"))
         (root (ebox-mount buffer (ebox-benchmark--workbench cards)
                           :width (window-body-width nil t) :height (window-body-height)))
         (find (ebox-benchmark--finder root)))
    (with-current-buffer buffer (ebox-buffer-mode 1))
    (append
     (and prepare (list :prepare (lambda () (funcall prepare find))))
     (list :buffer buffer
           :invoke (lambda (sample) (funcall invoke find sample root))
           :observe (lambda (sink)
                      (ebox-buffer-set-observer buffer sink)
                      (lambda ()
                        (when (buffer-live-p buffer) (ebox-buffer-set-observer buffer nil))))
           :verify (lambda ()
                     (let ((own (and check (funcall check find))))
                       (cond ((stringp own) own)
                             ((and fresh
                                   (ebox-benchmark--render-difference
                                    buffer root
                                    (and fixup
                                         (lambda (copy)
                                           (funcall fixup (ebox-benchmark--finder copy)))))))
                             (t t))))
           :cleanup (lambda ()
                      (when cleanup (funcall cleanup find))
                      (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun ebox-benchmark--app-toggle (id setter a b)
  "Return an invoke function applying SETTER to node ID with B, then A."
  (lambda (find sample _root) (funcall setter (funcall find id) (if (cl-evenp sample) b a))))

(defun ebox-benchmark--app-text (id path)
  "Return a setter replacing the text below node ID at child index PATH."
  (lambda (find text) (ebox-node-set-text (ebox-benchmark--descend (funcall find id) path) text)))

(defun ebox-benchmark--register-app (name class description setup &optional twin)
  "Register ebox.app.NAME over `ebox-benchmark--sizes' cards.
CLASS, DESCRIPTION, SETUP and TWIN are as in `ebox-benchmark--register'."
  (ebox-benchmark--register (concat "ebox.app." name) ebox-benchmark--sizes class
                            description setup twin))

(defun ebox-benchmark--register-app-text (name class description id path a b)
  "Register ebox.app.NAME replacing the text below ID at PATH between A and B."
  (ebox-benchmark--register-app
   name class description
   (lambda (cards)
     (let ((set (ebox-benchmark--app-text id path)))
       (ebox-benchmark--app
        cards :invoke (lambda (find sample _root) (funcall set find (if (cl-evenp sample) b a))))))))

(ebox-benchmark--register-app-text
 "clock" 'local "Tick the status bar clock of a workbench with %d cards"
 "clock" '(0) "12:00:00" "12:00:01")

(ebox-benchmark--register-app-text
 "search" 'local "Type into the fixed-width search box of a workbench with %d cards"
 "search" '(0) "search…" "query 汉字")

(ebox-benchmark--register-app-text
 "badge" 'propagate "Grow the header badge count of a workbench with %d cards"
 "badge" '(0) "3" "128")

(ebox-benchmark--register-app-text
 "title" 'propagate "Rename a visible card title in a workbench with %d cards"
 "card-2" '(1 0 0 0) "Task 00002 汉字 review layout" "Task 00002 汉字 renamed by the editor")

(ebox-benchmark--register-app-text
 "wrap" 'structure "Wrap a visible card title onto a second line in a workbench with %d cards"
 "card-2" '(1 0 0 0) "Task 00002 汉字 review layout"
 (concat "Task 00002 汉字 " (mapconcat #'identity (make-list 14 "wrapping") " ")))

(ebox-benchmark--register-app
 "select" 'local "Select a visible card of a workbench with %d cards"
 (lambda (cards)
   (let ((states nil))
     (ebox-benchmark--app
      cards
      :invoke (lambda (find sample _root)
                (setq states (and (cl-evenp sample) '(selected)))
                (ebox-node-set-states (funcall find "card-3") states))
      :fixup (lambda (find) (ebox-node-set-states (funcall find "card-3") states))))))

(ebox-benchmark--register-app
 "tab" 'local "Switch the active header tab of a workbench with %d cards"
 (lambda (cards)
   (ebox-benchmark--app
    cards
    :invoke (lambda (find sample _root)
              (let ((on (if (cl-evenp sample) "tab-1" "tab-0"))
                    (off (if (cl-evenp sample) "tab-0" "tab-1")))
                (ebox-with-batch
                  (ebox-node-put (funcall find off) :background-color "#1f2630")
                  (ebox-node-put (funcall find on) :background-color "#3b5b7a")))))))

(ebox-benchmark--register-app
 "menu" 'local "Open or close the anchored header menu of a workbench with %d cards"
 (lambda (cards)
   (ebox-benchmark--app
    cards :invoke (ebox-benchmark--app-toggle
                   "menu" (lambda (node value) (ebox-node-put node :visibility value))
                   'hidden 'visible))))

(ebox-benchmark--register-app
 "progress" 'propagate "Advance the detail progress bar of a workbench with %d cards"
 (lambda (cards)
   (ebox-benchmark--app
    cards
    :invoke (lambda (find sample _root)
              (let ((percent (if (cl-evenp sample) 75 40))
                    (bar (funcall find "progress")))
                (ebox-with-batch
                  (ebox-node-put bar :width (list '% percent))
                  (ebox-node-set-text (ebox-node-child bar 0) (format "%d%%" percent))))))))

(ebox-benchmark--register-app
 "detail" 'propagate "Show another card in the detail grid of a workbench with %d cards"
 (lambda (cards)
   (ebox-benchmark--app
    cards
    :invoke (lambda (find sample _root)
              (ebox-with-batch
                (cl-loop for id in '("owner" "status" "due")
                         for value in (if (cl-evenp sample)
                                          '("carol 汉字" "done" "2025-12-24")
                                        '("alice" "doing" "2025-10-08"))
                         do (ebox-node-set-text (ebox-node-child (funcall find id) 0) value)))))))

(ebox-benchmark--register-app
 "expand" 'structure "Expand or collapse a visible card's notes in a workbench with %d cards"
 (lambda (cards)
   (let ((notes (ebox-build '(column :background-color "#202a35" :padding-left (ch 1)
                                     (box "First note: check the border joins")
                                     (box "Second note 汉字: confirm the nested layout")))))
     (ebox-benchmark--app
      cards
      :invoke (lambda (find sample _root)
                (if (cl-evenp sample)
                    (ebox-node-insert (ebox-node-child (funcall find "card-1") 1) notes)
                  (ebox-node-remove notes)))))))

(dolist (entry '(("prepend" "the head" 0) ("append" "the end" nil)))
  (pcase-let ((`(,name ,where ,index) entry))
    (ebox-benchmark--register-app
     name 'structure (format "Insert or remove a card at %s of a workbench with %%d cards" where)
     (lambda (cards)
       (let ((card (ebox-build (ebox-benchmark--card 99999))))
         (ebox-benchmark--app
          cards
          :invoke (lambda (find sample _root)
                    (if (cl-evenp sample)
                        (ebox-node-insert (funcall find "list") card index)
                      (ebox-node-remove card)))))))))

(ebox-benchmark--register-app
 "reorder" 'structure "Move the first visible card three places and back in a workbench with %d cards"
 (lambda (cards)
   (ebox-benchmark--app
    cards :invoke (lambda (find sample _root)
                    (ebox-node-move (funcall find "card-0") (if (cl-evenp sample) 3 0))))))

(ebox-benchmark--register-app
 "folder" 'structure "Expand or collapse a sidebar folder of a workbench with %d cards"
 (lambda (cards)
   (let ((children (cl-loop for name in '("Work" "Home 汉字" "Later")
                            collect (ebox-build `(flex :padding-left (ch 2) :column-gap (ch 1)
                                                       (box "·") (box ,name))))))
     (ebox-benchmark--app
      cards
      :invoke (lambda (find sample _root)
                (let ((sidebar (funcall find "sidebar")))
                  (ebox-with-batch
                    (ebox-node-set-text (ebox-node-child (ebox-node-child (funcall find "folder-1") 0) 0)
                                        (if (cl-evenp sample) "▾" "▸"))
                    (if (cl-evenp sample)
                        (cl-loop for child in children for index from 3
                                 do (ebox-node-insert sidebar child index))
                      (mapc #'ebox-node-remove children)))))))))

(ebox-benchmark--register-app
 "scroll" 'local "Scroll the card list three cards and back in a workbench with %d cards"
 (lambda (cards)
   (let ((offset 0))
     (ebox-benchmark--app
      cards :fresh nil
      :invoke (lambda (find sample _root)
                (setq offset (ebox-node-set-scroll (funcall find "list") (if (cl-evenp sample) 9 0))))
      :check (lambda (find)
               (let* ((card (funcall find (if (zerop offset) "card-0" "card-3")))
                      (shown (ebox-node-bounds (ebox-node-child card 0))))
                 (cond ((/= (ebox-node-scroll-offset (funcall find "list")) offset)
                        (format "List offset is %d; expected %d"
                                (ebox-node-scroll-offset (funcall find "list")) offset))
                       ((null shown) (format "Card at offset %d is not painted" offset))
                       (t t))))))))

(ebox-benchmark--register-app
 "filter" 'rows "Filter a workbench of %d cards to every other card and back"
 (lambda (cards)
   (let (all even)
     (ebox-benchmark--app
      cards
      :prepare (lambda (find)
                 (unless all
                   (setq all (ebox-node-children (funcall find "list"))
                         even (cl-loop for node in all for i from 0 when (cl-evenp i) collect node))))
      :invoke (lambda (find sample _root)
                (ebox-node-replace-children (funcall find "list") (if (cl-evenp sample) even all)))))))

(ebox-benchmark--register-app
 "sidebar" 'rows "Collapse or expand the sidebar of a workbench with %d cards"
 (lambda (cards)
   (ebox-benchmark--app
    cards :invoke (ebox-benchmark--app-toggle
                   "sidebar" (lambda (node value) (ebox-node-put node :width value))
                   '(ch 22) '(ch 6)))))

(ebox-benchmark--register-app
 "resize" 'rows "Resize the viewport of a workbench with %d cards"
 (lambda (cards)
   (let ((width nil))
     (ebox-benchmark--app
      cards
      :invoke (lambda (find sample _root)
                (let* ((buffer (ebox-node-buffer (funcall find "app")))
                       (full (window-body-width (get-buffer-window buffer) t)))
                  (setq width (if (cl-evenp sample) (/ (* full 3) 4) full))
                  (ebox-mount-set-viewport buffer width (cdr (ebox-mount-viewport buffer)))))
      :check (lambda (find)
               (let ((viewport (ebox-mount-viewport (ebox-node-buffer (funcall find "app")))))
                 (if (eql (car viewport) width) t
                   (format "Viewport is %S; expected width %S" viewport width))))))))

(ebox-benchmark--register-app
 "theme" 'rows "Change the inherited text color of a workbench with %d cards"
 (lambda (cards)
   (ebox-benchmark--app
    cards :invoke (ebox-benchmark--app-toggle
                   "app" (lambda (node value) (ebox-node-put node :color value))
                   "#dddddd" "#cfe3ff"))))

;;; performance-scenarios.el ends here
