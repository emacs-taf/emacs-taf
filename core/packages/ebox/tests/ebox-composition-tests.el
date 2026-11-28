;;; -*- lexical-binding: t; -*-
;;; ebox-composition-tests.el --- Bounded paint through public node operations

(require 'ebox-test-support)

(defun ebox-composition-test--scene (left interactive &optional width)
  "Build overlapping windows with text and image rows at LEFT, with WIDTH.
INTERACTIVE adds native input ownership to the narrow window."
  (let* ((row (propertize " " 'display
                          '((slice 0 0 45 1) (image :type xpm :data "slice"))))
         (map (and interactive (ebox-keymap-create :activate #'ignore))))
    (ebox-build
     `(column :width (px 100) :height (lh 6) :background-color "#202020"
       (column :id "moving" :position absolute :left (px ,left) :top (lh 1)
         :width (px ,(or width 30)) :height (lh 3) :background-color "#404040"
         ,@(when map (list :keymap map :tab-index 0))
         (column :width (px 45) :background-color "#606060"
           (text "abcdefghijklmnopqrstuvwxyz012345678901234567890")
           (text ,row)))
       (column :id "right" :position absolute :left (px 80) :top (lh 0)
         :z-index 10 :width (px 10) :height (lh 6)
         "RIGHT" "RIGHT" "RIGHT" "RIGHT" "RIGHT" "RIGHT")))))

(defun ebox-composition-test--pixels (text)
  "Return TEXT's glyphs and display specs, without node ownership objects."
  (cl-loop for i below (length text)
           collect (list (aref text i) (get-text-property i 'display text))))

(ert-deftest ebox-composition-moving-overflow-keeps-canvas-and-neighbors ()
  "Moving an overflowing window never shifts its neighbors or widens rows.
Text and image rows remain equivalent to a fresh render at every position,
including clipping at either canvas edge and moving back to the start."
  (dolist (interactive '(nil t))
    (ebox-test-with-mounted
        (buffer root (ebox-composition-test--scene 10 interactive 50)
                :width 100 :height 6)
      (let ((moving (car (ebox-selector-query root "#moving"))))
        ;; Begin with content that fits, then narrow it before moving again.
        (dolist (box-width '(50 30 22 50 30))
          (ebox-node-put moving :width (list 'px box-width))
          (dolist (left '(10 30 55 85 -10 10 40 10))
            (ebox-node-put moving :left (list 'px left))
            (let* ((output (ebox-test-buffer-string buffer))
                   (fresh (ebox-render
                           (ebox-composition-test--scene left interactive box-width)))
                   (paint (ebox-composition-test--pixels output))
                   (expected (ebox-composition-test--pixels fresh)))
              (should (equal paint expected))
              (dolist (line (split-string output "\n"))
                (let* ((width (ebox-string-pixel-width line))
                       (position (string-match "RIGHT" line))
                       (column (and position
                                    (ebox-string-pixel-width (substring line 0 position)))))
                  (should (= width 100))
                  (should (equal column 80)))))))))))

(ert-deftest ebox-composition-narrow-stack-keeps-padding-and-border ()
  "An oversized child cannot displace its parent's padding or side border."
  (let* ((output (ebox-render
                  '(column :width (px 30) :height (lh 1)
                    :border-left ((px 1) solid "#ff0000")
                    :border-right ((px 1) solid "#ff0000")
                    :padding ((lh 0) (px 2))
                    (column :width (px 45)
                      "abcdefghijklmnopqrstuvwxyz012345678901234567890"))))
         (width (ebox-string-pixel-width output))
         (text (substring-no-properties output)))
    (should (= width 30))
    (should (string-match-p "abcdefghijklmnopqrstuvwx" text))
    (should-not (string-match-p "y" text))))

(ert-deftest ebox-composition-occlusion-keeps-native-image-fragments ()
  "Partial occlusion crops native images, including repeated cuts and raises."
  (let ((image '(image :type xpm :data "/* XPM */\nstatic char *x[] = {\"45 1 1 1\",\". c #123456\",\".............................................\"};")))
    (dolist (raised '(nil t))
      (let* ((row (if raised
                      (propertize " " 'display
                                  (list '(raise 0.1) '(slice 0 0 45 1) image))
                    ;; This is one native image display run; the 45-character
                    ;; alternate text also gives batch Emacs its pixel budget.
                    (propertize (make-string 45 ?.) 'display image)))
             (output (ebox-render
                      (ebox-node-create
                       'column '(:width (px 100) :height (lh 1))
                       (list row
                             (ebox-build '(box :position absolute :left (px 10)
                                          :width (px 5) :height (lh 1) "BLOCK"))
                             (ebox-build '(box :position absolute :left (px 25)
                                          :width (px 5) :height (lh 1) "OTHER"))))))
             fragments)
        (dotimes (i (length output))
          (let* ((display (get-text-property i 'display output))
                 (slice (and (listp display) (assq 'slice display))))
            (when slice
              (should (equal (assq 'image display) image))
              (when raised (should (equal (assq 'raise display) '(raise 0.1))))
              (push (list (nth 1 slice) (nth 3 slice) (nth 4 slice)) fragments))))
        (let ((height (if raised 1 1.0))
              (width (ebox-string-pixel-width output)))
          (should (equal (nreverse fragments)
                         (list (list 0 10 height) (list 15 10 height) (list 30 15 height))))
          (should (= width 100)))))))

(provide 'ebox-composition-tests)
;;; ebox-composition-tests.el ends here
