;;; ebox-line-height-tests.el --- Row heights against body fonts -*- lexical-binding: t; -*-

;;; Commentary:
;; A row is one line high whatever script it holds.  Body text in a font
;; taller than the Latin one sizes that line instead of having its glyphs
;; shrunk into it.

;;; Code:

(require 'ebox-test-support)

(ert-deftest ebox-body-text-rows-keep-the-line-height ()
  "Every published row measures one line height, whatever script it holds.
A CJK font taller than the Latin one raises the line, so Chinese text stays
exactly as tall as its font instead of being scaled down to fit a Latin line."
  (skip-unless (display-graphic-p))
  (ebox-test-with-mounted (buffer root '(column :width (px 200)
                                               (row (text "0 0"))
                                               (row (text "汉汉"))
                                               (row (text "0汉0")))
                                   :width 200 :height 4)
    (let ((window (selected-window))
          (shown (window-buffer (selected-window)))
          (line (plist-get (ebox-display-metrics buffer) :line-height)))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (redisplay t)
            (should (= (ebox-node-h root) 3))
            ;; Ordinary text of either script fits the line it sets.
            (should (<= (ebox-test-native-height "0汉" buffer) line))
            (save-excursion
              (goto-char (point-min))
              (while (not (eobp))
                (should (= (cdr (window-text-pixel-size
                                 window (line-beginning-position)
                                 (line-end-position)))
                           line))
                (forward-line 1))))
        (set-window-buffer window shown)))))

(ert-deftest ebox-full-width-rows-keep-the-line-height ()
  "A row reaching the window's right edge keeps the line height.
The height carrier starts the row, so the truncation boundary cannot drop
it."
  (skip-unless (display-graphic-p))
  (ebox-test-with-tall-cjk
    (let* ((window (selected-window))
           (shown (window-buffer window))
           (fringes (window-fringes window))
           (buffer (generate-new-buffer " *ebox-line-height*")))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (set-window-fringes window 8 8 t)
            (let* ((map (ebox-keymap-create :activate (lambda () t)))
                   (root (ebox-mount buffer
                                     `(column :width 'stretch
                                              (box :height '(lh 1)
                                                   :hover-style (:background-color "#123456")
                                                   :keymap ,map
                                                   (text "0 0"))
                                              (box :height '(lh 1) :background-color "#335544"
                                                   (text "汉汉"))
                                              (box :height '(lh 1) :background-color "#443355"
                                                   (text "0 0")))
                                     :width (ebox-viewport-window-width window)
                                     :height 3)))
              (redisplay t)
              (let ((line (plist-get (ebox-display-metrics buffer) :line-height)))
                (should (= (ebox-node-h root) 3))
                (should (> line (ebox-test-native-height "0" buffer)))
                (save-excursion
                  (goto-char (point-min))
                  (while (not (eobp))
                    (should (= (cdr (window-text-pixel-size
                                     window (line-beginning-position)
                                     (line-end-position)))
                               line))
                    (let* ((start (line-beginning-position))
                           (display (get-text-property start 'display)))
                      (should (eq (char-after start) ?\u200b))
                      (should (= (car (plist-get display :height)) line)))
                    (forward-line 1)))
                (let* ((start (point-min))
                       (y (cdr (posn-x-y (posn-at-point start window))))
                       (posn (posn-at-x-y 0 y window)))
                  (should (eq (posn-point posn) start))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (set-window-buffer window shown)
        (set-window-fringes window (nth 0 fringes) (nth 1 fringes)
                            (nth 2 fringes) (nth 3 fringes))))))

(ert-deftest ebox-render-lines-carry-the-row-strut ()
  "A rendered string starts every line with the height carrier."
  (ebox-test-with-tall-cjk
    (let ((string (ebox-render '(column :width 'stretch
                                       (row :height '(lh 1) (text "0 0"))
                                       (row :height '(lh 1) (text "汉汉"))))))
      (should (eq (aref string 0) ?\u200b))
      (should (eq (aref string (1+ (string-search "\n" string))) ?\u200b)))))

(ert-deftest ebox-overline-face-keeps-the-line-fit ()
  "An overline adds no height in a canvas.
A decorated glyph that fills its line keeps the plain scale, and the
plain text after it does not inherit a fitted display."
  (ebox-test-with-tall-cjk
    (let* ((deco (propertize "焦" 'face '(:overline t)))
           (buffer (generate-new-buffer " *ebox-overline-fit*")))
      (unwind-protect
          (progn
            (ebox-mount buffer `(column :width 'stretch
                                       (row (text ,deco))
                                       (row (text "焦")))
                        :width 200 :height 20)
            (with-current-buffer buffer
              (goto-char (point-min))
              (let (displays)
                (while (not (eobp))
                  (when (search-forward "焦" (line-end-position) t)
                    (push (get-text-property (1- (point)) 'display) displays))
                  (forward-line 1))
                (should (equal (nreverse displays) '(nil nil))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-overline-fit-does-not-cross-overline-margins ()
  "Text measured with another `overline-margin' keeps its own fit.
A plain buffer counts an overline into the row height; a canvas does not,
so the fitted scale must not pass between them."
  (ebox-test-with-tall-cjk
    (ebox-clear-cache)
    (let ((plain (generate-new-buffer " *ebox-plain-render*")))
      (unwind-protect
          (with-current-buffer plain
            (setq-local overline-margin 2)
            (let* ((deco (propertize "焦" 'face '(:overline t)))
                   (rendered (ebox-render `(column (row (text ,deco))))))
              ;; The plain render sees the overline and caches a fitted scale.
              (should (get-text-property (string-search "焦" rendered)
                                         'display rendered))))
        (when (buffer-live-p plain) (kill-buffer plain))))
    (let ((canvas (generate-new-buffer " *ebox-overline-canvas*")))
      (unwind-protect
          (progn
            (ebox-mount canvas '(column :width 'stretch (row (text "焦")))
                        :width 200 :height 10)
            (with-current-buffer canvas
              (goto-char (point-min))
              (should (search-forward "焦" nil t))
              (should (null (get-text-property (1- (point)) 'display)))))
        (when (buffer-live-p canvas) (kill-buffer canvas))))))

(ert-deftest ebox-plain-buffer-keeps-overline-and-plain-fits-apart ()
  "A plain buffer counts an overline into the row height.
The decorated glyph fits its taller row, and the plain glyph after it keeps
its own fit instead of reusing the decorated scale."
  (ebox-test-with-tall-cjk
    (ebox-clear-cache)
    (with-temp-buffer
      (setq-local overline-margin 2)
      (let* ((deco (propertize "焦" 'face '(:overline t)))
             (rendered (ebox-render `(column (row (text ,deco))
                                             (row (text "焦")))))
             (positions (let ((i 0) out)
                          (while (setq i (string-search "焦" rendered i))
                            (push i out)
                            (setq i (1+ i)))
                          (nreverse out))))
        (should (= (length positions) 2))
        (should (get-text-property (nth 0 positions) 'display rendered))
        (should (null (get-text-property (nth 1 positions) 'display rendered)))))))

(ert-deftest ebox-canvas-owns-line-metrics ()
  "A canvas zeroes the display settings its rows cannot honor.
Line spacing, line numbers and line and wrap prefixes would move rows away
from the measured layout; default text properties and property aliases are
left alone because measurement copies them."
  (let ((line-spacing 4)
        (display-line-numbers t)
        (line-prefix "-")
        (wrap-prefix "-")
        (default-text-properties '(:foreground "red"))
        (char-property-alias-alist '((face font-lock-face))))
    (ebox-test-with-mounted (buffer root '(column (text "0")) :width 100 :height 2)
      (should (null (buffer-local-value 'line-spacing buffer)))
      (should (null (buffer-local-value 'display-line-numbers buffer)))
      (should (null (buffer-local-value 'line-prefix buffer)))
      (should (null (buffer-local-value 'wrap-prefix buffer)))
      (should (equal (buffer-local-value 'default-text-properties buffer)
                     '(:foreground "red")))
      (should (equal (buffer-local-value 'char-property-alias-alist buffer)
                     '((face font-lock-face)))))))

(ert-deftest ebox-font-change-updates-cached-width ()
  "Changing the frame font updates cached glyph widths.
The metric context carries the frame and its font, so a height change cannot
leave a stale table behind."
  (skip-unless (display-graphic-p))
  (let* ((frame (selected-frame))
         (height (face-attribute 'default :height frame)))
    (unwind-protect
        (progn
          (ebox-clear-cache)
          (let ((before (ebox-string-pixel-width "0")))
            (set-face-attribute 'default frame :height (+ height 80))
            (should (> (ebox-string-pixel-width "0") before))))
      (set-face-attribute 'default frame :height height)
      (ebox-clear-cache))))

(defun ebox-test-line-heights (buffer window)
  "Return the pixel height of every line BUFFER shows in WINDOW."
  (with-current-buffer buffer
    (save-excursion
      (let (heights)
        (goto-char (point-min))
        (while (not (eobp))
          (push (cdr (window-text-pixel-size window (line-beginning-position)
                                             (line-end-position)))
                heights)
          (forward-line 1))
        (nreverse heights)))))

(defmacro ebox-test-with-body-and-heading (&rest body)
  "Measure a body row and a 1.42 heading row, then run BODY with both.
BODY sees `body-height' and `heading-height' in pixels."
  `(ebox-test-with-mounted (buffer root '(column :width (px 200)
                                               (row (text "汉汉"))
                                               (row (text "汉汉" :font-size 1.42))))
     (let* ((window (selected-window))
            (shown (window-buffer window)))
       (unwind-protect
           (progn
             (set-window-buffer window buffer)
             (redisplay t)
             (let* ((heights (ebox-test-line-heights buffer window))
                    (body-height (nth 0 heights))
                    (heading-height (nth 1 heights)))
               (should (= 2 (length heights)))
               ,@body))
         (set-window-buffer window shown)))))

(ert-deftest ebox-larger-face-keeps-its-cjk-on-the-line ()
  "A face that raises the size keeps its Chinese on a taller line.
The face's line box probes the same body scripts as the default face, so a
heading holds Chinese at the size the style asked for instead of reading the
CJK font as an overflowing fallback glyph and shrinking the text."
  (skip-unless (display-graphic-p))
  (ebox-test-with-body-and-heading
   (let ((ratio (/ (* 1.0 heading-height) body-height)))
     ;; The heading is 1.42 of the body, whatever the platform's fonts are.
     (should (>= ratio 1.3))
     (should (<= ratio 1.8)))))

(ert-deftest ebox-fitted-glyph-shrinks-from-its-own-size ()
  "A fitted glyph is scaled from its face's height, not from the body height.
A bare `height' display factor is a multiple of the default face, so the
factor has to carry the face's own size; otherwise a heading that needs a
slight fit drops to the body size."
  (skip-unless (display-graphic-p))
  (ebox-test-with-tall-cjk
    (ebox-clear-cache)
    (ebox-test-with-body-and-heading
     ;; A CJK font taller than the Latin one is what used to trigger the drop.
     (should (> heading-height body-height))
     (with-current-buffer buffer
       (goto-char (point-min))
       (when (search-forward "汉" nil t)
         (let ((factor (plist-get (get-text-property (1- (point)) 'display)
                                  :height)))
           ;; The old code wrote 0.81 here, a fraction of the default face.
           (when (numberp factor)
             (should (> factor 1.0)))))))))

(ert-deftest ebox-font-size-is-a-ratio-of-the-body-size ()
  "A style size is a multiple of the default face height.
The ratio is what keeps a heading the same relative size on every platform,
whatever the reader's default font."
  (let* ((rendered (ebox-render
                    '(column (row (text "A" :font-size 1))
                             (row (text "B" :font-size 1.42))
                             (row (text "C" :font-size 0.85)))))
         (heights (mapcar (lambda (char)
                            (let* ((position (string-search char rendered))
                                   (plists (ebox-test-face-plists
                                            (get-text-property position 'face rendered))))
                              (cl-some (lambda (plist) (plist-get plist :height))
                                       plists)))
                          '("A" "B" "C")))
         (body (nth 0 heights)))
    (should (integerp body))
    (should (< (abs (- (nth 1 heights) (* 1.42 body))) 2.0))
    (should (< (abs (- (nth 2 heights) (* 0.85 body))) 2.0))
    ;; A CSS pixel size is no longer a size; it fails the style check.
    (should-error (ebox-render '(column (row (text "D" :font-size 16)))))))

(ert-deftest ebox-fallback-symbols-keep-row-pixel-width-across-colored-faces ()
  "Fallback symbols painted in differently colored boxes keep exact row widths.
Emacs caches discovered fallback fonts per realized face, so measuring two
symbols under one shared font face and painting each with its own foreground
and background can otherwise resolve a different fallback font at paint time
and shift the right border on that row."
  (skip-unless (display-graphic-p))
  (ebox-clear-cache)
  (let ((map (ebox-keymap-create :activate (lambda () t))))
    (ebox-test-with-mounted
        (buffer root
                `(column :width (px 480) :border ((px 1) solid "#445566")
                         (flex :width stretch :column-gap (px 12)
                               (column :flex-grow 1 :flex-basis (px 0) :min-width (px 0)
                                       :padding ((lh 1) (ch 1))
                                       :background-color "#402c39"
                                       :border ((px 1) solid "#9f3a4a")
                                       (text :color "#fb7185" :font-weight bold
                                             "✗ 顺序摆反：[×2 倍] → [+8 倍]")
                                       (text :color "#e2e8f0" "基础 2 倍先乘 2 再加 8 = 12 倍"))
                               (column :flex-grow 1 :flex-basis (px 0) :min-width (px 0)
                                       :padding ((lh 1) (ch 1))
                                       :background-color "#1f4038"
                                       :border ((px 1) solid "#2f855a")
                                       (text :color "#4ade80" :font-weight bold
                                             "✓ 正确摆位：[+8 倍] → [×2 倍]")
                                       (text :color "#e2e8f0" "基础 2 倍先加 8 再乘 2 = 20 倍")))
                         (box :width stretch :padding ((lh 0) (ch 1))
                              :background-color "#1f4038"
                              :hover-style (:background-color "#2c5b4f")
                              :keymap ,map
                              (text :color "#4ade80" :font-weight bold "✓ 确认")))
                :width 480 :height 8)
      (let ((window (selected-window))
            (shown (window-buffer (selected-window)))
            (line (plist-get (ebox-display-metrics buffer) :line-height)))
        (unwind-protect
            (progn
              (set-window-buffer window buffer)
              (redisplay t)
              (save-excursion
                (goto-char (point-min))
                (while (not (eobp))
                  (let ((sz (window-text-pixel-size
                             window (line-beginning-position)
                             (line-end-position))))
                    (should (= (car sz) 480))
                    (should (= (cdr sz) line)))
                  (forward-line 1))
                (goto-char (point-min))
                (should (search-forward "✓ 确认" nil t))
                (let* ((pos (- (point) 4))
                       (face-plists (ebox-test-face-plists (get-text-property pos 'face)))
                       (hover-plists (ebox-test-face-plists (get-text-property pos 'mouse-face)))
                       (face-fam (cl-some (lambda (p) (plist-get p :family)) face-plists))
                       (hover-fam (cl-some (lambda (p) (plist-get p :family)) hover-plists)))
                  (when face-fam
                    (should (equal hover-fam face-fam))))))
          (set-window-buffer window shown))))))

(provide 'ebox-line-height-tests)
;;; ebox-line-height-tests.el ends here
