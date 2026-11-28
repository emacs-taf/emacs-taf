;;; etaf-screensaver-builtins.el --- Built-in pure-Elisp screensavers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Built-in screensavers registered through the same public APIs available to
;; user configurations: matrix, snow, plasma, donut, equalizer, sand, poems
;; and clock.  All run purely in Emacs Lisp with zero external dependencies.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver-canvas)
(require 'etaf-screensaver-scene)

;;; 1. matrix -- digital rain with glowing head and fading tail.

(defconst etaf-screensaver--matrix-glyphs "0123456789ABCDEF<>*+=-"
  "Characters used in digital rain drops.")

(defun etaf-screensaver--matrix-drop (rows random)
  "Create one rain drop vector [Y SPEED GLYPH] using RANDOM for ROWS."
  (vector (float (- (funcall random (+ rows 24)) 24))
          (+ 0.45 (/ (funcall random 150) 100.0))
          (aref etaf-screensaver--matrix-glyphs
                (funcall random (length etaf-screensaver--matrix-glyphs)))))

(etaf-screensaver-define-scene matrix
  :title "数字雨"
  :summary "经典数字雨：亮白雨头与渐隐绿尾逐列滑落"
  :frame-rate 20
  :background "#05070B"
  :params '((speed . 8) (tail . 10) (color . "#3BF07A"))
  :create
  (lambda (ctx)
    (let* ((cols (plist-get ctx :columns))
           (rows (plist-get ctx :rows))
           (rng (plist-get ctx :random))
           (drops (make-vector cols nil)))
      (dotimes (c cols)
        (aset drops c (etaf-screensaver--matrix-drop rows rng)))
      (list :drops drops)))
  :resize
  (lambda (state ctx)
    (let* ((cols (plist-get ctx :columns))
           (rows (plist-get ctx :rows))
           (rng (plist-get ctx :random))
           (old (plist-get state :drops))
           (drops (make-vector cols nil)))
      (dotimes (c cols)
        (aset drops c (if (< c (length old)) (aref old c)
                        (etaf-screensaver--matrix-drop rows rng))))
      (setf (plist-get state :drops) drops)
      state))
  :step
  (lambda (state ctx)
    (let* ((rows (plist-get ctx :rows))
           (dt (plist-get ctx :dt))
           (rng (plist-get ctx :random))
           (param (plist-get ctx :param))
           (speed (float (funcall param 'speed)))
           (tail (max 1 (round (funcall param 'tail))))
           (drops (plist-get state :drops)))
      (dotimes (c (length drops))
        (let* ((drop (aref drops c))
               (next (+ (aref drop 0) (* dt speed (aref drop 1) 1.8))))
          (if (> (- next tail) rows)
              (aset drops c
                    (vector -4.0
                            (+ 0.45 (/ (funcall rng 150) 100.0))
                            (aref etaf-screensaver--matrix-glyphs
                                  (funcall rng (length etaf-screensaver--matrix-glyphs)))))
            (aset drop 0 next))))))
  :render
  (lambda (state ctx)
    (let* ((canvas (plist-get ctx :canvas))
           (cols (plist-get ctx :columns))
           (bg (or (plist-get ctx :background) "#05070B"))
           (param (plist-get ctx :param))
           (color (funcall param 'color))
           (head-color (if (etaf-screensaver--hex-rgb color)
                           (etaf-screensaver-color-mix color "#FFFFFF" 0.72)
                         color))
           (tail (max 1 (round (funcall param 'tail))))
           (shades (when (etaf-screensaver--hex-rgb color)
                     (let ((bg-hex (if (etaf-screensaver--hex-rgb bg) bg "#05070B")))
                       (vconcat
                        (cl-loop for i from 0 below 4
                                 collect (etaf-screensaver-color-mix
                                          color bg-hex (* i 0.24)))))))
           (drops (plist-get state :drops)))
      (dotimes (c (min cols (length drops)))
        (let* ((drop (aref drops c))
               (pos (round (aref drop 0)))
               (glyph (aref drop 2)))
          (dotimes (offset tail)
            (let* ((r (- pos offset))
                   (ch (if (zerop offset) ?▓ glyph))
                   (col (cond ((zerop offset) head-color)
                              (shades (etaf-screensaver-ramp shades (/ (float offset) tail)))
                              (t color))))
              (etaf-screensaver-canvas-put canvas r c ch col)))))
      canvas)))

;;; 2. snow -- gentle drifting flakes built with define-particle-scene.

(etaf-screensaver-define-particle-scene snow
  :title "雪夜"
  :summary "雪花左右轻摆地飘落，出界后从另一侧绕回"
  :frame-rate 20
  :background "#070B14"
  :params '((speed . 4) (count . 120) (sway . 4))
  :spawn
  (lambda (_i ctx)
    (let ((rng (plist-get ctx :random)))
      ;; [X Y PHASE DEPTH-SPEED]
      (vector (* (funcall rng) (plist-get ctx :columns))
              (* (funcall rng) (plist-get ctx :rows))
              (* (funcall rng) 6.2831853)
              (+ 0.65 (* (funcall rng) 0.7)))))
  :update
  (lambda (p ctx)
    (let* ((dt (plist-get ctx :dt))
           (w (float (plist-get ctx :columns)))
           (h (float (plist-get ctx :rows)))
           (param (plist-get ctx :param))
           (speed (float (funcall param 'speed)))
           (sway (float (funcall param 'sway)))
           (phase (+ (aref p 2) (* dt 1.5)))
           (x (+ (aref p 0) (* dt sway (sin phase))))
           (y (+ (aref p 1) (* dt speed 2.0 (aref p 3)))))
      (cond ((< y -2.0) (setq y (+ h 2.0)))
            ((> y (+ h 2.0)) (setq y -2.0)))
      (cond ((< x -2.0) (setq x (+ w 2.0)))
            ((> x (+ w 2.0)) (setq x -2.0)))
      (aset p 0 x)
      (aset p 1 y)
      (aset p 2 phase)))
  :draw
  (lambda (p canvas _ctx)
    (let ((bright (> (sin (aref p 2)) 0.35)))
      (etaf-screensaver-canvas-put
       canvas (round (aref p 1)) (round (aref p 0))
       (if bright ?* ?·)
       (if bright "#EAF4FF" "#93A7C4")))))

;;; 3. plasma -- interference wave field built with define-field-scene.

(etaf-screensaver-define-field-scene plasma
  :title "等离子"
  :summary "四重正弦波叠加色场，按调色板量化并合并绘制"
  :frame-rate 12
  :background "#05070B"
  :params '((speed . 3))
  :range '(-4.0 4.0)
  :ramp " .:-=+*#%@"
  :palette '("#06070B" "#101A3A" "#1B3A6E" "#1F6A9B" "#2E9E9B"
             "#67C89A" "#B3E3A0" "#F2F7C8" "#FFFFFF")
  :value
  (lambda (x y ctx)
    (let* ((tm (plist-get ctx :elapsed))
           (spd (float (funcall (plist-get ctx :param) 'speed)))
           (dx (- x (* 0.5 (plist-get ctx :columns))))
           (dy (- y (* 0.5 (plist-get ctx :rows)))))
      (+ (sin (+ (* 0.09 x) (* 0.4 spd tm)))
         (sin (+ (* 0.06 y) (* 0.3 spd tm)))
         (sin (+ (* 0.05 (+ x y)) (* 0.5 spd tm)))
         (cos (* 0.08 (sqrt (+ (* dx dx) (* dy dy)))))))))

;;; 4. donut -- classic rotating 3D ASCII torus with z-buffer.

(defconst etaf-screensaver--donut-ramp ".,-~:;=!*#$@"
  "Luminance ramp for torus surface shading.")

(defun etaf-screensaver--donut-samples (detail)
  "Return (THETA-STEPS . PHI-STEPS) for DETAIL."
  (pcase detail
    ('coarse '(26 . 44))
    ('fine '(52 . 96))
    (_ '(36 . 64))))

(etaf-screensaver-define-scene donut
  :title "旋转甜甜圈"
  :summary "经典 3D ASCII 甜甜圈，逐格 z-buffer 投影与明暗着色"
  :frame-rate 18
  :background "#05070B"
  :params '((speed . 6) (detail . normal) (color . "#CBD5E1"))
  :create
  (lambda (ctx)
    (let ((size (* (plist-get ctx :rows) (plist-get ctx :columns))))
      (list :a 0.0 :b 0.0 :zbuf (make-vector size 0.0))))
  :resize
  (lambda (state ctx)
    (setf (plist-get state :zbuf)
          (make-vector (* (plist-get ctx :rows) (plist-get ctx :columns)) 0.0))
    state)
  :step
  (lambda (state ctx)
    (let ((speed (float (funcall (plist-get ctx :param) 'speed)))
          (dt (plist-get ctx :dt)))
      (setf (plist-get state :a) (+ (plist-get state :a) (* dt speed 0.14))
            (plist-get state :b) (+ (plist-get state :b) (* dt speed 0.08)))))
  :render
  (lambda (state ctx)
    (let* ((canvas (plist-get ctx :canvas))
           (rows (plist-get ctx :rows))
           (cols (plist-get ctx :columns))
           (param (plist-get ctx :param))
           (samples (etaf-screensaver--donut-samples (funcall param 'detail)))
           (theta-steps (car samples))
           (phi-steps (cdr samples))
           (color (funcall param 'color))
           (zbuf (plist-get state :zbuf))
           (a (plist-get state :a)) (b (plist-get state :b))
           (sin-a (sin a)) (cos-a (cos a))
           (sin-b (sin b)) (cos-b (cos b))
           (r1 1.0) (r2 2.0) (k2 5.0)
           (k1 (min (* 0.34 cols) (* 0.66 rows)))
           (half-c (* 0.5 cols))
           (half-r (* 0.5 rows))
           (pcos (make-vector phi-steps 0.0))
           (psin (make-vector phi-steps 0.0))
           (ramp etaf-screensaver--donut-ramp)
           (last (1- (length ramp))))
      (dotimes (i phi-steps)
        (let ((phi (* 2.0 float-pi (/ i (float phi-steps)))))
          (aset pcos i (cos phi))
          (aset psin i (sin phi))))
      (fillarray zbuf 0.0)
      (dotimes (ti theta-steps)
        (let* ((theta (* 2.0 float-pi (/ ti (float theta-steps))))
               (st (sin theta)) (ct (cos theta))
               (cx (+ r2 (* r1 ct)))
               (cy (* r1 st))
               (x-a (* cx cos-b))
               (x-b (- (* cy cos-a sin-b)))
               (y-a (* cx sin-b))
               (y-b (* cy cos-a cos-b))
               (z-b (* sin-a cy)))
          (dotimes (pi-idx phi-steps)
            (let* ((cp (aref pcos pi-idx)) (sp (aref psin pi-idx))
                   (x (+ (* x-a cp) (* sin-a sin-b cx sp) x-b))
                   (y (+ (* y-a cp) (- (* sin-a cos-b cx sp)) y-b))
                   (z (+ k2 (* cos-a cx sp) z-b))
                   (ooz (/ 1.0 z))
                   (col (round (+ half-c (* k1 ooz x))))
                   (row (round (- half-r (* 0.5 k1 ooz y))))
                   (lum (+ (* cp ct sin-b) (- (* cos-a ct sp)) (- (* sin-a st))
                           (* cos-b (- (* cos-a st) (* ct sin-a sp))))))
              (when (and (> lum 0.0) (>= row 0) (< row rows) (>= col 0) (< col cols))
                (let ((idx (+ (* row cols) col)))
                  (when (> ooz (aref zbuf idx))
                    (aset zbuf idx ooz)
                    (etaf-screensaver-canvas-put
                     canvas row col
                     (aref ramp (min last (floor (* lum (1+ last)))))
                     color))))))))
      canvas)))

;;; 5. equalizer -- colorful level bars with vertical shades and reflection.

(defconst etaf-screensaver--eq-palette
  '("#22D3EE" "#38BDF8" "#818CF8" "#A78BFA"
    "#F472B6" "#FB7185" "#FBBF24" "#34D399")
  "Bar colors repeated across columns.")

(defconst etaf-screensaver--eq-bars 40
  "Maximum number of spectrum bars.")

(etaf-screensaver-define-scene equalizer
  :title "彩色律动"
  :summary "彩色频谱柱随节拍起伏，带峰值帽与基线倒影"
  :frame-rate 30
  :background "#05070E"
  :params '((speed . 1.0))
  :create
  (lambda (ctx)
    (let* ((rng (plist-get ctx :random))
           (bg (or (plist-get ctx :background) "#05070E"))
           (bg-hex (if (etaf-screensaver--hex-rgb bg) bg "#05070E"))
           (shades
            (vconcat
             (mapcar (lambda (color)
                       (cons (etaf-screensaver-color-mix bg-hex color 0.22)
                             (vconcat
                              (cl-loop for k in '(0.58 0.72 0.86 1.0)
                                       collect (etaf-screensaver-color-mix bg-hex color k)))))
                     etaf-screensaver--eq-palette))))
      (list :phases (vconcat (cl-loop repeat etaf-screensaver--eq-bars
                                      collect (* (funcall rng) 6.2831853)))
            :rates (vconcat (cl-loop repeat etaf-screensaver--eq-bars
                                     collect (+ 0.7 (* (funcall rng) 1.5))))
            :levels (make-vector etaf-screensaver--eq-bars 0.12)
            :peaks (make-vector etaf-screensaver--eq-bars 0.12)
            :clock 0.0
            :shades shades)))
  :resize (lambda (state _ctx) state)
  :step
  (lambda (state ctx)
    (let* ((speed (max 0.1 (float (funcall (plist-get ctx :param) 'speed))))
           (dt (* speed (max 0.001 (plist-get ctx :dt))))
           (clock (+ (plist-get state :clock) dt))
           (phases (plist-get state :phases))
           (rates (plist-get state :rates))
           (levels (plist-get state :levels))
           (peaks (plist-get state :peaks))
           (pulse (+ 0.86 (* 0.14 (sin (* clock 2.0))))))
      (dotimes (i etaf-screensaver--eq-bars)
        (let* ((rate (aref rates i))
               (phase (aref phases i))
               (target (* pulse
                          (+ 0.50
                             (* 0.30 (sin (+ (* clock rate) phase)))
                             (* 0.15 (sin (+ (* clock rate 2.35) (* phase 1.7))))
                             (* 0.09 (sin (+ (* clock rate 0.55) (* phase 0.4)))))))
               (target (min 1.0 (max 0.06 target)))
               (cur (aref levels i))
               (next (+ cur (* (- target cur) (min 1.0 (* dt (if (> target cur) 17.0 7.0)))))))
          (aset levels i next)
          (aset peaks i (max next (- (aref peaks i) (* dt 0.45))))))
      (setf (plist-get state :clock) clock)))
  :render
  (lambda (state ctx)
    (let* ((canvas (plist-get ctx :canvas))
           (cols (plist-get ctx :columns))
           (rows (plist-get ctx :rows))
           (count (max 4 (min etaf-screensaver--eq-bars (/ (max 1 (- cols 4)) 3))))
           (gap 1)
           (bar (max 1 (min 2 (/ (max 1 (- cols 4 (* gap (1- count)))) count))))
           (width (+ (* count bar) (* gap (1- count))))
           (left (max 0 (/ (- cols width) 2)))
           (baseline (max 3 (min (1- rows) (round (* rows 0.72)))))
           (height (max 1 (round (* (max 1 (- baseline 3)) 0.84))))
           (levels (plist-get state :levels))
           (peaks (plist-get state :peaks))
           (shades (plist-get state :shades)))
      ;; Baseline
      (etaf-screensaver-canvas-fill canvas baseline left width 1 ?─ "#334155")
      ;; Bars, peak caps and reflections
      (dotimes (i count)
        (let* ((x (+ left (* i (+ bar gap))))
               (cells (max 1 (round (* height (aref levels i)))))
               (peak-cells (max cells (round (* height (aref peaks i)))))
               (refl (max 0 (min 5 (round (* cells 0.22)))))
               (entry (aref shades (mod i (length shades))))
               (refl-color (car entry))
               (ramp (cdr entry)))
          (dotimes (step cells)
            (let ((row (- baseline 1 step))
                  (col (etaf-screensaver-ramp ramp (/ (float step) (max 1 (1- cells))))))
              (etaf-screensaver-canvas-fill canvas row x bar 1 ?█ col)))
          (etaf-screensaver-canvas-fill
           canvas (- baseline peak-cells) x bar 1 ?▀ "#F8FAFC")
          (when (> refl 0)
            (etaf-screensaver-canvas-fill
             canvas (1+ baseline) x bar refl ?█ refl-color))))
      canvas)))

;;; 6. sand -- falling grains with natural piling and gentle reset.

(etaf-screensaver-define-scene sand
  :title "落沙"
  :summary "沙粒从顶部自然坠落并沿坡面堆积"
  :frame-rate 20
  :background "#0A0705"
  :params '((grains . 3) (color . "#D9C08A"))
  :create
  (lambda (ctx)
    (let ((rows (plist-get ctx :rows))
          (cols (plist-get ctx :columns)))
      (list :rows rows :cols cols :cells (make-vector (* rows cols) 0))))
  :resize
  (lambda (state ctx)
    (let* ((rows (plist-get ctx :rows))
           (cols (plist-get ctx :columns))
           (old-r (plist-get state :rows))
           (old-c (plist-get state :cols))
           (old (plist-get state :cells))
           (cells (make-vector (* rows cols) 0)))
      (dotimes (r (min rows old-r))
        (dotimes (c (min cols old-c))
          (aset cells (+ (* r cols) c) (aref old (+ (* r old-c) c)))))
      (setf (plist-get state :rows) rows
            (plist-get state :cols) cols
            (plist-get state :cells) cells)
      state))
  :step
  (lambda (state ctx)
    (let* ((rows (plist-get state :rows))
           (cols (plist-get state :cols))
           (cells (plist-get state :cells))
           (rng (plist-get ctx :random))
           (grains (max 1 (round (funcall (plist-get ctx :param) 'grains)))))
      ;; Advance falling grains bottom-to-top.
      (cl-loop for r from (- rows 2) downto 0 do
               (dotimes (c cols)
                 (let* ((idx (+ (* r cols) c))
                        (val (aref cells idx)))
                   (when (> val 0)
                     (let* ((below (+ (* (1+ r) cols) c))
                            (dir (if (zerop (funcall rng 2)) -1 1))
                            (c1 (+ c dir))
                            (c2 (- c dir)))
                       (cond
                        ((zerop (aref cells below))
                         (aset cells below val) (aset cells idx 0))
                        ((and (>= c1 0) (< c1 cols)
                              (zerop (aref cells (+ (* (1+ r) cols) c1))))
                         (aset cells (+ (* (1+ r) cols) c1) val) (aset cells idx 0))
                        ((and (>= c2 0) (< c2 cols)
                              (zerop (aref cells (+ (* (1+ r) cols) c2))))
                         (aset cells (+ (* (1+ r) cols) c2) val) (aset cells idx 0))))))))
      ;; Emit fresh grains at top; clear gracefully when top fills.
      (let ((top-filled 0))
        (dotimes (c cols) (when (> (aref cells c) 0) (cl-incf top-filled)))
        (if (>= top-filled (max 1 (/ cols 3)))
            (fillarray cells 0)
          (dotimes (_ grains)
            (let ((c (funcall rng cols)))
              (when (zerop (aref cells c))
                (aset cells c (1+ (funcall rng 3))))))))))
  :render
  (lambda (state ctx)
    (let* ((canvas (plist-get ctx :canvas))
           (rows (plist-get state :rows))
           (cols (plist-get state :cols))
           (cells (plist-get state :cells))
           (base (funcall (plist-get ctx :param) 'color))
           (tones (if (etaf-screensaver--hex-rgb base)
                      (vector base
                              (etaf-screensaver-color-mix base "#FFFFFF" 0.18)
                              (etaf-screensaver-color-mix base "#000000" 0.18))
                    (vector base base base))))
      (dotimes (r rows)
        (dotimes (c cols)
          (let ((val (aref cells (+ (* r cols) c))))
            (when (> val 0)
              (etaf-screensaver-canvas-put canvas r c ?▓ (aref tones (1- val)))))))
      canvas)))

;;; 7. poems -- warm paper typography built with define-text-scene.

(etaf-screensaver-define-text-scene poems
  :title "宣纸诗句"
  :summary "宣纸墨字逐字浮现、停驻与淡出，可通过 :items 自定义句库"
  :frame-rate 20
  :background "#F4F1EA"
  :frame 'card
  :style 'typewriter
  :letter-spacing t
  :order 'shuffle
  :color "#2B3036"
  :hold 3.2
  :fade 0.8
  :speed 6.0
  :items
  '((:text "一蓑烟雨任平生" :caption "苏轼 · 《定风波》")
    (:text "小舟从此逝，江海寄余生" :caption "苏轼 · 《临江仙》")
    (:text "应似飞鸿踏雪泥" :caption "苏轼 · 《和子由渑池怀旧》")
    (:text "轻舟已过万重山" :caption "李白 · 《早发白帝城》")
    (:text "天生我材必有用" :caption "李白 · 《将进酒》")
    (:text "会当凌绝顶，一览众山小" :caption "杜甫 · 《望岳》")
    (:text "明月松间照，清泉石上流" :caption "王维 · 《山居秋暝》")
    (:text "欲穷千里目，更上一层楼" :caption "王之涣 · 《登鹳雀楼》")
    (:text "晴空一鹤排云上" :caption "刘禹锡 · 《秋词》")
    (:text "但愿人长久，千里共婵娟" :caption "苏轼 · 《水调歌头》")
    (:text "采菊东篱下，悠然见南山" :caption "陶渊明 · 《饮酒》")
    (:text "落霞与孤鹜齐飞" :caption "王勃 · 《滕王阁序》")))

;;; 8. clock -- crisp 5-row Unicode block-element digital clock.

(defconst etaf-screensaver--clock-digits
  '((?0 . ("███" "█ █" "█ █" "█ █" "███"))
    (?1 . (" ▀█" "  █" "  █" "  █" "▀▀█"))
    (?2 . ("▀▀█" "  █" "███" "█  " "███"))
    (?3 . ("▀▀█" "  █" "▀▀█" "  █" "▀▀█"))
    (?4 . ("█ █" "█ █" "▀▀█" "  █" "  █"))
    (?5 . ("███" "█  " "▀▀█" "  █" "▀▀█"))
    (?6 . ("███" "█  " "███" "█ █" "███"))
    (?7 . ("▀▀█" "  █" "  █" "  █" "  █"))
    (?8 . ("███" "█ █" "███" "█ █" "███"))
    (?9 . ("███" "█ █" "▀▀█" "  █" "▀▀█"))
    (?: . ("   " " █ " "   " " █ " "   ")))
  "5-row, 3-column block-element glyph bitmaps for digital clock display.")

(defun etaf-screensaver--clock-render-big (time-str)
  "Render TIME-STR into a list of 5 big block-character strings."
  (cl-loop for row below 5
           collect
           (mapconcat
            (lambda (ch)
              (nth row (or (cdr (assq ch etaf-screensaver--clock-digits))
                           '("   " "   " "   " "   " "   "))))
            time-str "  ")))

(etaf-screensaver-define-scene clock
  :title "极简时钟"
  :summary "大字块状数字时钟与日期，缓慢漂移以防烧屏"
  :frame-rate 2
  :background "#05070B"
  :params '((color . "#93C5FD") (seconds . t) (drift . t))
  :render
  (lambda (_state ctx)
    (let* ((canvas (plist-get ctx :canvas))
           (cols (plist-get ctx :columns))
           (rows (plist-get ctx :rows))
           (param (plist-get ctx :param))
           (color (funcall param 'color))
           (bg (or (plist-get ctx :background) "#05070B"))
           (date-color (if (and (etaf-screensaver--hex-rgb color)
                                (etaf-screensaver--hex-rgb bg))
                           (etaf-screensaver-color-mix color bg 0.45)
                         color))
           (time-str (format-time-string (if (funcall param 'seconds) "%H:%M:%S" "%H:%M")))
           (date-str (format-time-string "%Y-%m-%d  %A"))
           (big (etaf-screensaver--clock-render-big time-str))
           (big-w (string-width (car big)))
           (use-big (and (>= cols (+ big-w 2)) (>= rows 9)))
           (tm (plist-get ctx :elapsed))
           (drift (funcall param 'drift))
           (dx (if drift (round (* (min 8 (max 0 (/ (- cols (if use-big big-w (string-width time-str))) 4)))
                                   (sin (* tm 0.17))))
                 0))
           (dy (if drift (round (* (min 4 (max 0 (/ (- rows (if use-big 7 3)) 4)))
                                   (cos (* tm 0.11))))
                 0)))
      (if use-big
          (let ((top (max 0 (+ (/ (- rows 7) 2) dy)))
                (left (max 0 (+ (/ (- cols big-w) 2) dx))))
            (cl-loop for line in big for i from 0 do
                     (etaf-screensaver-canvas-text canvas (+ top i) left line color))
            (etaf-screensaver-canvas-text
             canvas (+ top 6)
             (max 0 (+ (/ (- cols (string-width date-str)) 2) dx))
             date-str date-color))
        (let ((mid (max 0 (+ (/ (- rows 3) 2) dy))))
          (etaf-screensaver-canvas-text canvas mid 'center time-str color)
          (etaf-screensaver-canvas-text canvas (+ mid 2) 'center date-str date-color)))
      canvas)))

(provide 'etaf-screensaver-builtins)
;;; etaf-screensaver-builtins.el ends here
