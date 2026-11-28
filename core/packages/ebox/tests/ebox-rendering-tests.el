;;; ebox-rendering-tests.el --- Ebox rendering behaviour tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-render-text-and-box-forms ()
  (should (equal (ebox-test-render-text "Hello") "Hello"))
  (should (equal (ebox-test-render-text '(text "Hello")) "Hello"))
  (should (equal (ebox-test-render-text '(box :width (ch 5) "Hello")) "Hello")))

(ert-deftest ebox-render-row-and-column-flow ()
  (should (equal (ebox-test-render-text
                  '(row :item-gap (ch 2)
                        (box :width (ch 3) "A")
                        (box :width (ch 3) "B")))
                 "A  B  "))
  (should (equal (ebox-test-render-text
                  '(column :width (ch 3)
                           (box :height (lh 1) "A")
                           (box :height (lh 1) "B")))
                 "A 
B ")))

(ert-deftest ebox-render-wraps-aligns-and-measures-cjk ()
  (should (equal (ebox-test-render-text '(box :width (ch 3) "abcdef"))
                 "abc
def"))
  (should (equal (ebox-test-render-text '(box :width (ch 4) :text-align right "Hi"))
                 " Hi"))
  (should (equal (ebox-test-render-text '(box :width (ch 4) :text-align center "Hi"))
                 " Hi "))
  (should (equal (ebox-test-render-text '(box :width (ch 4) "你好吗"))
                 "你好
吗 ")))

(ert-deftest ebox-render-cuts-a-picture-to-its-content-box ()
  "A picture wider than its content box is cut to the box.
A box gives a stretched image node its content width while the node keeps
painting the picture at its own pixel width.  Without the cut the surplus
paints over whatever shares the line and pushes it aside: a shelf of covers
shoved the panel beside it 10 pixels to the right, so the panel's cover came
out with a seam across it."
  (let* ((prepared (ebox-image-prepare "/tmp/ebox-test-source.png" 12 2
                                       :adapter 'placeholder))
         (picture (ebox-node-create 'image (list :image prepared)))
         (root (ebox-node-create 'box (list :width '(px 6) :height '(lh 2))
                                 (list picture)))
         (line (car (split-string (ebox-render root) "\n")))
         (display (get-text-property 0 'display line))
         (slice (and (consp display) (eq (car-safe (car display)) 'slice)
                     (car display)))
         ;; A text adapter paints one character per cell and a graphical one
         ;; paints one sliced picture per row; both must stop at the box.
         (painted (if slice (nth 3 slice) (length line))))
    (should (<= painted 6))))

(ert-deftest ebox-render-keeps-punctuation-off-line-edges ()
  (should (equal (ebox-test-render-text '(box :width (ch 4) "你好。好"))
                 "你 
好。
好 "))
  (should (equal (ebox-test-render-text '(box :width (ch 6) "你好（是"))
                 "你好 
（是 ")))

(ert-deftest ebox-render-paints-face-and-display-spaces ()
  (let* ((rendered (ebox-render
                    '(box :width (px 10) :height (lh 1)
                          :color "#112233"
                          :background-color "#ddeeff"
                          :text-decoration-line underline
                          "Hi"))))
    (should (equal (substring-no-properties rendered) "Hi "))
    (should (equal (get-text-property 0 'face rendered)
                   '((:underline (:color "#112233"))
                     (:foreground "#112233")
                     (:background "#ddeeff"))))
    (should (equal (get-text-property 2 'display rendered)
                   '(space :width (8))))))

(ert-deftest ebox-render-text-border-draws-rules-and-keeps-decorations ()
  "A text frame draws side borders as rules, not as filled cells.
The top and bottom decorations stay on the line that carries them."
  (let ((rendered (ebox-render
                   '(box :width (px 10) :height (lh 1)
                         :border ((px 1) solid "#ff0000")
                         "Hi"))))
    (should (equal (substring-no-properties rendered) "│Hi │"))
    (should (eq (aref rendered 0) ?│))
    (should (cl-some (lambda (face) (equal (plist-get face :foreground) "#ff0000"))
                     (ebox-test-face-plists (get-text-property 0 'face rendered))))
    (should (cl-some (lambda (face) (equal (plist-get face :overline) "#ff0000"))
                     (ebox-test-face-plists (get-text-property 1 'face rendered))))
    (should (cl-some (lambda (face) (plist-get face :underline))
                     (ebox-test-face-plists (get-text-property 1 'face rendered))))))

(ert-deftest ebox-render-text-display-draws-a-box-frame ()
  "A blank border row becomes a box-drawing frame on a text display.
The frame keeps the border box width, so layout does not change."
  (let* ((rendered (ebox-render
                    '(box :width (px 10)
                          :padding '((lh 1) (ch 0))
                          :border ((px 1) solid "#ff0000")
                          "Hi")))
         (lines (mapcar #'substring-no-properties (split-string rendered "\n"))))
    (should (equal (nth 0 lines) "┌────────┐"))
    (should (equal (nth 2 lines) "└────────┘"))
    (should (eq (aref (nth 1 lines) 0) ?│))
    (should (eq (aref (nth 1 lines) (1- (length (nth 1 lines)))) ?│)))
  ;; A content row keeps its decoration instead of a frame.
  (let* ((rendered (ebox-render
                    '(box :width (px 10) :border ((px 1) solid "#ff0000") "Hi")))
         (line (car (split-string rendered "\n"))))
    (should (eq (aref line 0) ?│))
    (should (cl-some (lambda (face) (equal (plist-get face :overline) "#ff0000"))
                     (ebox-test-face-plists (get-text-property 1 'face rendered))))))

(ert-deftest ebox-render-text-display-maps-a-font-size-increase-to-bold ()
  "A terminal has one face size, so a raised size becomes bold weight.
The raised node's children inherit the weight, while a root-level size change
is the application's global choice and stays unemphasized."
  (let* ((rendered (ebox-render '(column (text "body")
                                          (box :font-size 1.4 (text "head")))))
         (head (1+ (length (nth 0 (split-string rendered "\n"))))))
    (should (eq (plist-get (get-text-property head 'face rendered) :weight) 'bold))
    (should-not (plist-get (get-text-property 0 'face rendered) :weight))
    (should-not (plist-get (get-text-property 0 'face
                                              (ebox-render '(text :font-size 1.4 "root")))
                           :weight))))

(ert-deftest ebox-render-side-borders-paint-their-width ()
  (let ((rendered (ebox-render
                   '(box :width (px 10) :height (lh 1)
                         :border-left ((px 3) solid "#00ff00")
                         "Hi"))))
    (should (equal (substring-no-properties rendered) "│ Hi "))
    (should (eq (aref rendered 0) ?│))
    (should (equal (plist-get (get-text-property 0 'face rendered) :foreground)
                   "#00ff00")))
  (should-error (ebox-render '(box :border-top ((px 2) solid "#00ff00") "Hi"))
                :type 'ebox-error))

(ert-deftest ebox-render-flex-wraps-and-gaps-items ()
  (ebox-test-with-mounted (buffer root
                           '(flex :width (ch 8) :flex-flow (row wrap)
                                  :column-gap (ch 1) :row-gap (lh 1)
                                  (box :id "a" :width (ch 3) "A")
                                  (box :id "b" :width (ch 3) "B")
                                  (box :id "c" :width (ch 3) "C")))
    (let ((a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b")))
          (c (car (ebox-selector-query root "#c"))))
      (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 8 :height 3)))
      (should (equal (ebox-node-geometry a) '(:x 0 :y 0 :width 3 :height 1)))
      (should (equal (ebox-node-geometry b) '(:x 4 :y 0 :width 3 :height 1)))
      (should (equal (ebox-node-geometry c) '(:x 0 :y 2 :width 3 :height 1))))))

(ert-deftest ebox-render-flex-shrinks-whole-rows-from-the-start ()
  (let ((lines (split-string
                (ebox-test-render-text
                 '(flex :flex-direction column :width (ch 4) :height (lh 5)
                        (box :height (lh 1) :overflow hidden "a")
                        (box :height (lh 1) :overflow hidden "b")
                        (box :height (lh 1) :overflow hidden "c")
                        (box :height (lh 1) :overflow hidden "d")
                        (box :height (lh 1) :overflow hidden "e")
                        (box :height (lh 1) :overflow hidden "f")
                        (box :height (lh 1) :overflow hidden "g")))
                "\n")))
    (should (equal (mapcar #'string-trim-right (seq-take lines 5))
                   '("c" "d" "e" "f" "g")))))

(ert-deftest ebox-render-overflowing-items-keep-sibling-columns ()
  (should (equal (ebox-test-render-text
                  '(flex :width (ch 10)
                         (box :width (ch 3) :wrap-mode none "abcdef")
                         (box "Z")))
                 "abcZ "))
  (let ((lines (split-string
                (ebox-render
                 '(flex :width (ch 10)
                        (column :width (ch 4)
                                (flex :column-gap (ch 1)
                                      (box "▸")
                                      (box :flex-grow 1 :min-width (px 0) "Today")
                                      (box "6")))
                        (box "Z")))
                "\n")))
    (should (> (length lines) 1))
    (dolist (line lines)
      (should (= 10 (with-temp-buffer
                      (insert line)
                      (car (buffer-text-pixel-size))))))))

(ert-deftest ebox-render-absolute-children-start-at-content-origin ()
  (ebox-test-with-mounted (buffer root
                           '(box :width (ch 10) :height (lh 3) :padding ((lh 1) (ch 2))
                                 (box :id "over" :position absolute :left (ch 0) :top (lh 0)
                                      :width (ch 2) :height (lh 1) "AB")
                                 "flowing"))
    (let ((over (car (ebox-selector-query root "#over"))))
      (should (equal (ebox-node-geometry over) '(:x 2 :y 1 :width 2 :height 1)))
      (should (string-match-p "AB" (nth 1 (split-string (ebox-test-buffer-text) "\n")))))))

(ert-deftest ebox-render-root-layer-boxes-cover-the-root-border-box ()
  (ebox-test-with-mounted (buffer root
                           '(box :width (ch 10) :height (lh 3) :padding ((lh 1) (ch 2))
                                 (column "flowing"
                                         (box :id "scrim" :position absolute :layer root
                                              :left (px 0) :top (lh 0)
                                              :width (% 100) :height (% 100)
                                              :background-color "#101010"))))
    (let ((scrim (car (ebox-selector-query root "#scrim"))))
      (should (equal (ebox-node-geometry scrim) '(:x 0 :y 0 :width 10 :height 3)))
      (with-current-buffer buffer
        (should (equal (get-text-property (point-min) 'face) '(:background "#101010")))))))

(ert-deftest ebox-render-relative-flow-paints-above-lower-overlays ()
  (let* ((out (ebox-render
               '(box :position relative :width (ch 8) :height (lh 2)
                     (box :position absolute :z-index 0 :left (ch 0) :top (lh 0)
                          :width (ch 8) :height (lh 1) :background-color "#ff0000")
                     (column :position relative :z-index 1 :width stretch "row1" "row2"))))
         (lines (split-string (substring-no-properties out) "\n")))
    (should (string-prefix-p "row1" (nth 0 lines)))
    (should (string-prefix-p "row2" (nth 1 lines)))
    ;; The raised text keeps the lower bar's background behind it.
    (should (equal (plist-get (get-text-property 0 'face out) :background) "#ff0000"))))

(ert-deftest ebox-render-grid-places-items-in-tracks ()
  (ebox-test-with-mounted (buffer root
                           '(grid :width (ch 6)
                                  :grid-template-columns ((ch 2) (ch 4))
                                  :grid-template-rows ((lh 1) (lh 1))
                                  (box :id "g1" :grid-column 1 :grid-row 1 "A")
                                  (box :id "g2" :grid-column 2 :grid-row 2 "B")))
    (let ((g1 (car (ebox-selector-query root "#g1")))
          (g2 (car (ebox-selector-query root "#g2"))))
      (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 6 :height 2)))
      (should (equal (ebox-node-geometry g1) '(:x 0 :y 0 :width 2 :height 1)))
      (should (equal (ebox-node-geometry g2) '(:x 2 :y 1 :width 4 :height 1))))))

(ert-deftest ebox-render-grid-auto-placement-fills-earliest-free-cells ()
  "Automatic items take the earliest free area in flow order, including holes."
  (cl-flet ((origins (root ids)
              (mapcar (lambda (id)
                        (let ((g (ebox-node-geometry
                                  (car (ebox-selector-query root (concat "#" id))))))
                          (list id (plist-get g :x) (plist-get g :y))))
                      ids)))
    (ebox-test-with-mounted (buffer root
                             '(grid :grid-template-columns ((ch 2) (ch 2) (ch 2))
                                    :grid-auto-columns (ch 2) :grid-auto-rows (lh 1)
                                    (box :id "x" :grid-row 1 :grid-column 2 "x")
                                    (box :id "a" "a")
                                    (box :id "b" :grid-column (:span 2) "b")
                                    (box :id "c" "c")
                                    (box :id "r" :grid-row 1 "r")
                                    (box :id "d" "d")
                                    (box :id "e" :grid-column 1 "e")
                                    (box :id "f" "f")))
      ;; C fills the hole B left; R widens the grid, so D and F use the
      ;; new column only where earlier cells are taken.
      (should (equal (origins root '("x" "a" "b" "c" "r" "d" "e" "f"))
                     '(("x" 2 0) ("a" 0 0) ("b" 0 1) ("c" 4 0)
                       ("r" 6 0) ("d" 4 1) ("e" 0 2) ("f" 6 1)))))
    (ebox-test-with-mounted (buffer root
                             '(grid :grid-auto-flow column
                                    :grid-template-rows ((lh 1) (lh 1))
                                    :grid-auto-columns (ch 2) :grid-auto-rows (lh 1)
                                    (box :id "x" :grid-row 1 :grid-column 2 "x")
                                    (box :id "a" "a")
                                    (box :id "b" :grid-row (:span 2) "b")
                                    (box :id "c" "c")))
      (should (equal (origins root '("x" "a" "b" "c"))
                     '(("x" 2 0) ("a" 0 0) ("b" 4 0) ("c" 0 1)))))))

(ert-deftest ebox-render-stretched-heights-fill-definite-areas ()
  (ebox-test-with-mounted (buffer root
                           '(grid :width (ch 4) :height (lh 6)
                                  :grid-template-columns ((ch 4))
                                  :grid-template-rows ((lh 1) (fr 1))
                                  (box :grid-row 1 "H")
                                  (column :id "area" :grid-row 2 :height stretch
                                          (column :id "fill" :height stretch
                                                  (box :id "grow" :height stretch "x")))))
    (should (equal (ebox-node-geometry (car (ebox-selector-query root "#area")))
                   '(:x 0 :y 1 :width 4 :height 5)))
    (should (equal (ebox-node-geometry (car (ebox-selector-query root "#fill")))
                   '(:x 0 :y 1 :width 4 :height 5)))
    (should (equal (ebox-node-geometry (car (ebox-selector-query root "#grow")))
                   '(:x 0 :y 1 :width 4 :height 5)))))

(ert-deftest ebox-render-visibility-hidden-preserves-layout-space ()
  (should (equal (ebox-test-render-text
                  '(column :width (ch 3)
                           (box :height (lh 1) "A")
                           (box :height (lh 1) :visibility hidden "B")
                           (box :height (lh 1) "C")))
                 "A 
 
C ")))

(ert-deftest ebox-render-keeps-neighbours-sharing-one-display ()
  "Adjacent characters never repeat one shared display value.
Emacs paints consecutive characters showing the same `eq' display as one
element, hiding their glyphs; a line whose neighbours share a display must
alternate it with an equal twin."
  (let ((display (list 'space :width '(4))))
    (let ((rendered
           (ebox-render (list 'row
                              (list 'text (propertize "a" 'display display))
                              (list 'text (propertize "b" 'display display))
                              (list 'text (propertize "c" 'display display))))))
      (should (equal (substring-no-properties rendered) "abc "))
      (dotimes (i 2)
        (should-not (eq (get-text-property i 'display rendered)
                        (get-text-property (1+ i) 'display rendered))))
      (should (equal (get-text-property 1 'display rendered) display)))))

(ert-deftest ebox-node-constructors-build-detached-trees ()
  (let* ((text (ebox-text-create "OK" '(:color "#00aa00")))
         (root (ebox-node-create 'box '(:width (ch 3)) (list text)))
         (copy (ebox-node-copy root)))
    (should (eq (ebox-node-child root 0) text))
    (should (ebox-node-text-p text))
    (should (= (ebox-node-child-count root) 1))
    (should-not (eq copy root))
    (should (equal (ebox-test-render-text copy) "OK "))
    (ebox-node-set-text text "NO")
    (should (equal (ebox-test-render-text root) "NO "))
    (should (equal (ebox-test-render-text copy) "OK "))))

(ert-deftest ebox-build-rejects-invalid-author-forms ()
  (should-error (ebox-build '(unknown "x")) :type 'ebox-error)
  (should-error (ebox-build '(text :ecss (("&" :color "red")) "x"))
                :type 'ebox-error)
  (should-error (ebox-build '(box :height (px 1))) :type 'ebox-error)
  (should-error (ebox-node-create 'unknown) :type 'ebox-error))

;;; ebox-rendering-tests.el ends here
