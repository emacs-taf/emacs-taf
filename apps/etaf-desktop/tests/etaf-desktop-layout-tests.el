;;; etaf-desktop-layout-tests.el --- Public layout scenarios -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'etaf-desktop)
(require 'etaf)

(ert-deftest etaf-desktop-tiling-layout-and-split-resize ()
  "Tiling assigns non-overlapping rectangles and split ratios are adjustable."
  (let ((desktop (etaf-desktop-create :canvas-width 100 :canvas-height 20)))
    (etaf-desktop-open-window desktop 'one :width 20 :height 4
                              :min-width 5 :min-height 2)
    (etaf-desktop-open-window desktop 'two :width 20 :height 4
                              :min-width 5 :min-height 2)
    (etaf-desktop-open-window desktop 'three :width 20 :height 4
                              :min-width 5 :min-height 2)
    (etaf-desktop-set-layout-mode desktop 'tiling)
    (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
    (let ((tree (etaf-desktop-layout-tree desktop)))
      (should (equal :split (car tree)))
      (should (= 3 (length (etaf-desktop--test-leaves tree)))))
    (let ((one (etaf-desktop-window-state desktop 'one))
          (two (etaf-desktop-window-state desktop 'two))
          (three (etaf-desktop-window-state desktop 'three)))
      (dolist (window (list one two three))
        (should (= (frame-char-width) (plist-get window :x)))
        (should (= (- 100 (* 2 (frame-char-width)))
                   (plist-get window :width))))
      (should (= 1 (plist-get one :y)))
      (should (< (plist-get one :y) (plist-get two :y)))
      (should (< (plist-get two :y) (plist-get three :y)))
      ;; Two outer rows and two inner rows stay outside the pane rectangles.
      (should (= 20 (+ (plist-get one :height)
                       (plist-get two :height)
                       (plist-get three :height)
                       4)))
      (should (= (1+ (+ (plist-get one :y) (plist-get one :height)))
                 (plist-get two :y)))
      (should (= (1+ (+ (plist-get two :y) (plist-get two :height)))
                 (plist-get three :y))))
    (etaf-desktop-layout-resize-split desktop nil 0.75)
    (let ((three (etaf-desktop-window-state desktop 'three)))
      ;; Third leaf keeps the second split's single divider row above it.
      (should (= 15 (plist-get three :y)))
      (should (= 19 (+ (plist-get three :y) (plist-get three :height)))))))

(ert-deftest etaf-desktop-tiling-two-workspaces-publishes-both-trees ()
  "Every tiled workspace keeps its own dividers mounted in one canvas."
  (let ((desktop (etaf-desktop-create :name " *desktop-two-tiled*"
                                      :canvas-width 100 :canvas-height 20
                                      :workspaces '(main work))))
    (unwind-protect
        (progn
          (dolist (id '(one two))
            (etaf-desktop-open-window desktop id :title (symbol-name id)
                                      :width 20 :height 4 :min-width 5 :min-height 2
                                      :workspace 'main))
          (dolist (id '(three four))
            (etaf-desktop-open-window desktop id :title (symbol-name id)
                                      :width 20 :height 4 :min-width 5 :min-height 2
                                      :workspace 'work))
          (let ((buffer (etaf-desktop-mount desktop)))
            (etaf-desktop-set-layout-mode desktop 'tiling 'main)
            (etaf-desktop-set-layout-mode desktop 'tiling 'work)
            (should (eq 'tiling (etaf-desktop-layout-mode desktop 'main)))
            (should (eq 'tiling (etaf-desktop-layout-mode desktop 'work)))
            (should (< (plist-get (etaf-desktop-window-state desktop 'one) :y)
                       (plist-get (etaf-desktop-window-state desktop 'two) :y)))
            (should (< (plist-get (etaf-desktop-window-state desktop 'three) :y)
                       (plist-get (etaf-desktop-window-state desktop 'four) :y)))
            (with-current-buffer buffer
              (should (string-match-p "one" (buffer-substring-no-properties
                                             (point-min) (point-max)))))
            (etaf-desktop-switch-workspace desktop 'work)
            (with-current-buffer buffer
              (should (string-match-p "three" (buffer-substring-no-properties
                                               (point-min) (point-max)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-divider-orientation-refreshes-rendered-input ()
  "Changing a retained split direction updates its visible input and gesture."
  (let ((desktop (etaf-desktop-create :name " *desktop-divider-orientation*"
                                     :canvas-width 400 :canvas-height 30)))
    (unwind-protect
        (progn
          (dolist (id '(one two))
            (etaf-desktop-open-window desktop id :title (symbol-name id)
                                     :width 100 :height 8
                                     :min-width 20 :min-height 2))
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (etaf-desktop-layout-set-tree
           desktop '(:split horizontal 0.5 (:leaf one) (:leaf two)))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (dolist (orientation '(vertical horizontal vertical))
              (etaf-desktop-layout-set-tree
               desktop (list :split orientation 0.5 '(:leaf one) '(:leaf two)))
              (let* ((horizontal (eq orientation 'horizontal))
                     (entries
                      (cl-loop for (ref . props)
                               in (etaf-runtime-host-props-entries runtime)
                               when (and (equal "etaf-splitter-divider"
                                                (plist-get props :class))
                                         (etaf-host-ref-position runtime ref))
                               collect (cons ref props)))
                     (entry (car entries))
                     (dimension (if horizontal :width :height))
                     (axis (if horizontal :x :y))
                     (before (etaf-desktop-window-state desktop 'one))
                     (peer (etaf-desktop-window-state desktop 'two))
                     (delta (if horizontal '(2 . 0) '(0 . 2))))
                (should (= 1 (length entries)))
                (should (equal (if horizontal "Resize columns" "Resize rows")
                               (plist-get (cdr entry) :aria-label)))
                (should (eq (if horizontal 'hdrag 'vdrag)
                            (plist-get (cdr entry) :pointer)))
                (should (equal (if horizontal '(px 3) '(lh 1))
                               (plist-get (cdr entry) dimension)))
                (etaf-dispatch-event runtime (car entry) 'drag
                                     '(:phase start :delta (0 . 0)) t)
                (etaf-dispatch-event runtime (car entry) 'drag
                                     (list :phase 'move :delta delta) t)
                (etaf-dispatch-event runtime (car entry) 'drag
                                     (list :phase 'end :delta delta) t)
                (should (= (+ 2 (plist-get before dimension))
                           (plist-get (etaf-desktop-window-state desktop 'one)
                                      dimension)))
                (should (= (+ 2 (plist-get peer axis))
                           (plist-get (etaf-desktop-window-state desktop 'two)
                                      axis)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-layout-floating-and-untile ()
  "Untiling preserves a window as a floating overlay while tree leaves reflow."
  (let ((desktop (etaf-desktop-create :canvas-width 80 :canvas-height 16)))
    (dolist (id '(one two))
      (etaf-desktop-open-window desktop id :width 20 :height 4
                                :min-width 5 :min-height 2))
    (etaf-desktop-set-layout-mode desktop 'tiling)
    (etaf-desktop-layout-untile-window desktop 'two)
    (should (member 'two (etaf-desktop-layout-floating-windows desktop)))
    (should-not (member 'two (etaf-desktop--test-leaves
                              (etaf-desktop-layout-tree desktop))))
    (should (eq 'tiling (etaf-desktop-layout-mode desktop)))
    (etaf-desktop-set-layout-mode desktop 'tiling)
    (should-not (member 'two (etaf-desktop-layout-floating-windows desktop)))
    (should (member 'two (etaf-desktop--test-leaves
                          (etaf-desktop-layout-tree desktop))))))

(ert-deftest etaf-desktop-nested-splitters-occupy-reserved-gaps ()
  "Every nested divider renders between, rather than over, tiled windows."
  (let ((desktop (etaf-desktop-create :name " *desktop-nested-dividers*"
                                      :canvas-width 360 :canvas-height 20)))
    (unwind-protect
        (progn
          (etaf-desktop-open-window desktop 'one :title "one"
                                    :width 100 :min-width 10 :max-width 120
                                    :min-height 2)
          (dolist (id '(two three))
            (etaf-desktop-open-window desktop id
                                      :title (format "%s" id)
                                      :width 100 :min-width 10 :min-height 2))
          (etaf-desktop-set-setting desktop :tile-outer-gap 2)
          (etaf-desktop-set-setting desktop :tile-inner-gap 4)
          (etaf-desktop-set-layout-mode desktop 'tiling)
          (etaf-desktop-layout-set-tree
           desktop '(:split horizontal 0.6 (:leaf one)
                            (:split vertical 0.5 (:leaf two) (:leaf three))))
          (let* ((buffer (etaf-desktop-mount desktop))
                 (runtime (etaf-runtime-for-buffer buffer))
                 (entries (etaf-runtime-host-props-entries runtime))
                 (dividers
                  (cl-loop for (ref . props) in entries
                           when (equal "etaf-splitter-divider"
                                       (plist-get props :class))
                           collect ref))
                 (columns (cl-find-if
                           (lambda (entry)
                             (equal "Resize columns"
                                    (plist-get (cdr entry) :aria-label)))
                           entries))
                 (rows (cl-find-if
                        (lambda (entry)
                          (equal "Resize rows"
                                 (plist-get (cdr entry) :aria-label)))
                        entries))
                 (one (etaf-desktop-window-state desktop 'one))
                 (two (etaf-desktop-window-state desktop 'two))
                 (three (etaf-desktop-window-state desktop 'three)))
            (should (= 2 (length dividers)))
            (should (cl-every (lambda (ref)
                                (etaf-host-ref-position runtime ref))
                              dividers))
            (should (= (* 4 (frame-char-width))
                       (- (plist-get two :x)
                          (+ (plist-get one :x) (plist-get one :width)))))
            (should (= 4 (- (plist-get three :y)
                            (+ (plist-get two :y) (plist-get two :height)))))
            ;; Handles retain their thickness and center within the wider gap.
            (should (equal (list 'px (+ (plist-get one :x)
                                       (plist-get one :width)
                                       (floor (- (* 4 (frame-char-width)) 3) 2)))
                           (plist-get (cdr columns) :left)))
            (should (equal '(px 3) (plist-get (cdr columns) :width)))
            (should (equal '(lh 2) (plist-get (cdr columns) :top)))
            (should (equal '(lh 16) (plist-get (cdr columns) :height)))
            (should rows)
            (should (equal (list 'px (plist-get two :x))
                           (plist-get (cdr rows) :left)))
            (should (equal (list 'px (plist-get two :width))
                           (plist-get (cdr rows) :width)))
            (should (equal (list 'lh (+ (plist-get two :y)
                                       (plist-get two :height) 1))
                           (plist-get (cdr rows) :top)))
            (should (equal '(lh 1) (plist-get (cdr rows) :height)))
            (let* ((before (etaf-desktop-layout-tree desktop))
                   (root-ratio (nth 2 before))
                   (nested-ratio (nth 2 (nth 4 before))))
              (etaf-dispatch-event runtime (car rows) 'drag
                                   (list :phase 'move
                                         :delta (cons 0 (* 2 (frame-char-height)))) t)
              (let ((after (etaf-desktop-layout-tree desktop)))
                (should (= root-ratio (nth 2 after)))
                (should (not (= nested-ratio (nth 2 (nth 4 after)))))))
            (with-current-buffer buffer
              (dolist (title '("one" "two" "three"))
                (should (string-match-p title (buffer-string)))))))
      (etaf-desktop-close desktop))))

(ert-deftest etaf-desktop-layout-horizontal-split-and-minimums ()
  "Horizontal splits allocate width and respect each leaf's minimum width."
  (let* ((outer (frame-char-width))
         (inner (max 3 (frame-char-width)))
         (width (+ 100 (* 2 outer) inner))
         (desktop (etaf-desktop-create :canvas-width width :canvas-height 12)))
    (etaf-desktop-open-window desktop 'left :width 30 :height 4
                              :min-width 30 :min-height 2 :max-width 60)
    (etaf-desktop-open-window desktop 'right :width 20 :height 4
                              :min-width 20 :min-height 2)
    (etaf-desktop-layout-split desktop 'left 'right 'horizontal 0.8)
    (let ((left (etaf-desktop-window-state desktop 'left))
          (right (etaf-desktop-window-state desktop 'right)))
      (should (= 60 (plist-get left :width)))
      (should (= outer (plist-get left :x)))
      (should (= 40 (plist-get right :width)))
      (should (= (+ outer 60 inner) (plist-get right :x)))
      (should (= 1 (plist-get left :y)))
      (should (= 10 (plist-get left :height))))
    (etaf-desktop-layout-resize-split desktop nil 0.2)
    (let ((left (etaf-desktop-window-state desktop 'left)))
      (should (= 30 (plist-get left :width))))))

(ert-deftest etaf-desktop-layout-vertical-split-moves-one-row-per-step ()
  "Consecutive ratio steps of one row each move the split by exactly one row.
The divider gesture adds ROWS/SPAN to the start ratio, so an odd span yields
half-row ideals on every step; the allocation must not merge step pairs."
  (let* ((outer 1) (inner 1) (span 43)
         (desktop (etaf-desktop-create :canvas-width 200
                                       :canvas-height (+ span inner (* 2 outer)))))
    (etaf-desktop-open-window desktop 'top :width 50 :height 4
                              :min-width 10 :min-height 2)
    (etaf-desktop-open-window desktop 'bottom :width 50 :height 4
                              :min-width 10 :min-height 2)
    (etaf-desktop-layout-split desktop 'top 'bottom 'vertical 0.5)
    (let ((start (plist-get (etaf-desktop-window-state desktop 'top) :height))
          (previous nil))
      (dotimes (rows 6)
        (etaf-desktop-layout-resize-split desktop nil (+ 0.5 (/ (float rows) span)))
        (let ((height (plist-get (etaf-desktop-window-state desktop 'top) :height))
              (bottom (etaf-desktop-window-state desktop 'bottom)))
          (should (= height (+ start rows)))
          (when previous (should (= 1 (- height previous))))
          (should (= (plist-get bottom :y)
                     (+ outer height inner)))
          (setq previous height))))))

(ert-deftest etaf-desktop-layout-monocle-and-close-sync ()
  "Monocle fills the inset canvas and closing a leaf removes it from the tree."
  (let ((desktop (etaf-desktop-create :canvas-width 90 :canvas-height 18)))
    (dolist (id '(one two))
      (etaf-desktop-open-window desktop id :width 20 :height 4
                                :min-width 5 :min-height 2))
    (etaf-desktop-set-layout-mode desktop 'tiling)
    (etaf-desktop-focus-window desktop 'two)
    (etaf-desktop-set-layout-mode desktop 'monocle)
    (dolist (id '(one two))
      (let ((window (etaf-desktop-window-state desktop id)))
        (should (= (frame-char-width) (plist-get window :x)))
        (should (= 1 (plist-get window :y)))
        (should (= (- 90 (* 2 (frame-char-width))) (plist-get window :width)))
        (should (= 16 (plist-get window :height)))))
    (should (> (plist-get (etaf-desktop-window-state desktop 'two) :z-index)
               (plist-get (etaf-desktop-window-state desktop 'one) :z-index)))
    (etaf-desktop-close-window desktop 'one)
    (etaf-desktop-layout-sync desktop)
    (should-not (member 'one (etaf-desktop--test-leaves
                              (etaf-desktop-layout-tree desktop))))))

(ert-deftest etaf-desktop-layout-master-stack-reflows-new-windows ()
  "Master-stack gives the first window a master region and reflows new leaves."
  (let ((desktop (etaf-desktop-create :canvas-width 100 :canvas-height 20)))
    (dolist (id '(master stack-one stack-two))
      (etaf-desktop-open-window desktop id :width 20 :height 4
                                :min-width 5 :min-height 2))
    (etaf-desktop-set-layout-mode desktop 'master-stack)
    (etaf-desktop-open-window desktop 'stack-three :width 20 :height 4
                              :min-width 5 :min-height 2)
    (let ((master (etaf-desktop-window-state desktop 'master))
          (stack-one (etaf-desktop-window-state desktop 'stack-one))
          (stack-two (etaf-desktop-window-state desktop 'stack-two))
          (stack-three (etaf-desktop-window-state desktop 'stack-three)))
      (let* ((outer (frame-char-width))
             (inner (max 3 (frame-char-width)))
             (available (- 100 (* 2 outer) inner))
             (master-width (round (* available 0.6))))
        (should (= master-width (plist-get master :width)))
        (should (= outer (plist-get master :x)))
        (dolist (window (list stack-one stack-two stack-three))
          (should (= (+ outer master-width inner) (plist-get window :x)))
          (should (= (- available master-width) (plist-get window :width)))))
      (should (= 1 (plist-get master :y)))
      (should (= 18 (plist-get master :height)))
      (should (= 1 (plist-get stack-one :y)))
      (should (= 19 (+ (plist-get stack-three :y)
                       (plist-get stack-three :height))))
      (should (= 20 (+ (plist-get stack-one :height)
                       (plist-get stack-two :height)
                       (plist-get stack-three :height)
                       4))))))

(defun etaf-desktop--test-leaves (tree)
  "Return public tree leaves for the layout assertions."
  (cond
   ((null tree) nil)
   ((eq :leaf (car tree)) (list (cadr tree)))
   (t (append (etaf-desktop--test-leaves (nth 3 tree))
              (etaf-desktop--test-leaves (nth 4 tree))))))

(provide 'etaf-desktop-layout-tests)
;;; etaf-desktop-layout-tests.el ends here
