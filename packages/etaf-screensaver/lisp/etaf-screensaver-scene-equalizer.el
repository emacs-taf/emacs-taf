;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-scene-equalizer.el --- Colorful level bars

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A music-player equalizer for the dark page: solid bars rise and fall like
;; a level meter, each in its own bright colour, with a white peak cap and a
;; dim reflection under the baseline.  Bar count, width and height follow the
;; canvas, so a wide window shows wider bars rather than a stretched image.
;; No recording, no image, no per-frame SVG.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver-model)

(defconst etaf-screensaver--equalizer-background "#05070E"
  "Background the bars and their reflection are blended against.")

(defconst etaf-screensaver--equalizer-palette
  '("#22D3EE" "#38BDF8" "#818CF8" "#A78BFA"
    "#F472B6" "#FB7185" "#FBBF24" "#34D399")
  "Bar colours, repeated from left to right.")

(defconst etaf-screensaver--equalizer-peak "#F8FAFC"
  "Colour of the falling peak cap above each bar.")

(defconst etaf-screensaver--equalizer-baseline "#334155"
  "Colour of the horizontal baseline.")

(defconst etaf-screensaver--equalizer-bars 40
  "Maximum number of bars; narrow canvases use fewer.")

(defun etaf-screensaver--equalizer-rgb (color)
  "Return COLOR as a list of red, green and blue integers."
  (list (string-to-number (substring color 1 3) 16)
        (string-to-number (substring color 3 5) 16)
        (string-to-number (substring color 5 7) 16)))

(defun etaf-screensaver--equalizer-blend (color amount)
  "Blend COLOR toward the page background by AMOUNT and return #RRGGBB.
AMOUNT 1 keeps COLOR, 0 gives the background."
  (let ((foreground (etaf-screensaver--equalizer-rgb color))
        (background (etaf-screensaver--equalizer-rgb
                     etaf-screensaver--equalizer-background)))
    (apply #'format "#%02X%02X%02X"
           (cl-mapcar (lambda (front back)
                        (round (+ back (* (- front back) amount))))
                      foreground background))))

(defun etaf-screensaver--equalizer-faces ()
  "Return the six-step colour ramp and reflection face for each bar."
  (vconcat
   (mapcar (lambda (color)
             (list :reflection (list :foreground
                                     (etaf-screensaver--equalizer-blend color .18))
                   :shades (vconcat
                            (cl-loop for amount in '(.55 .64 .73 .82 .91 1.0)
                                     collect (list :foreground
                                                   (etaf-screensaver--equalizer-blend
                                                    color amount))))))
           etaf-screensaver--equalizer-palette)))

(etaf-screensaver-define-scene equalizer
  :title "彩色律动"
  :summary "彩色竖条随节拍起伏，带峰值与倒影"
  :tags '(bars color music)
  :frame-rate 30
  :background etaf-screensaver--equalizer-background
  :create
  (lambda (context)
    (let ((random (plist-get context :random)))
      (list :phases (vconcat
                     (cl-loop repeat etaf-screensaver--equalizer-bars
                              collect (* (funcall random) 6.283)))
            :rates (vconcat
                    (cl-loop repeat etaf-screensaver--equalizer-bars
                             collect (+ .7 (* (funcall random) 1.5))))
            :levels (make-vector etaf-screensaver--equalizer-bars .12)
            :peaks (make-vector etaf-screensaver--equalizer-bars .12)
            :clock 0.0
            :faces (etaf-screensaver--equalizer-faces)
            :peak-face (list :foreground etaf-screensaver--equalizer-peak)
            :baseline-face (list :foreground etaf-screensaver--equalizer-baseline))))
  :step
  (lambda (state context)
    (let* ((dt (max .001 (plist-get context :dt)))
          (clock (+ (plist-get state :clock) dt))
          (phases (plist-get state :phases))
          (rates (plist-get state :rates))
          (levels (plist-get state :levels))
          (peaks (plist-get state :peaks))
          (pulse (+ .86 (* .14 (sin (* clock 2.0))))))
      (dotimes (index etaf-screensaver--equalizer-bars)
        (let* ((rate (aref rates index))
               (phase (aref phases index))
               (target (* pulse
                          (+ .50
                             (* .30 (sin (+ (* clock rate) phase)))
                             (* .15 (sin (+ (* clock rate 2.35) (* phase 1.7))))
                             (* .09 (sin (+ (* clock rate .55) (* phase .4)))))))
               (target (min 1 (max .06 target)))
               (current (aref levels index))
               (next (+ current (* (- target current)
                                   (min 1 (* dt (if (> target current) 17 7)))))))
          (aset levels index next)
          (aset peaks index
                (max next (- (aref peaks index) (* dt .45))))))
      (setf (plist-get state :clock) clock))
    state)
  :render
  (lambda (state context)
    (let* ((columns (plist-get context :columns))
           (rows (plist-get context :rows))
           (count (max 10 (min etaf-screensaver--equalizer-bars
                                 (/ (- columns 4) 3))))
           (gap 1)
           (bar (max 1 (min 2 (/ (- columns 4 (* gap (1- count))) count))))
           (width (+ (* count bar) (* gap (1- count))))
           (left (max 1 (/ (- columns width) 2)))
           (right (+ left width))
           (baseline (max 6 (round (* rows .70))))
           (height (max 1 (round (* (- baseline 4) .82))))
           (levels (plist-get state :levels))
           (peaks (plist-get state :peaks))
           (faces (plist-get state :faces))
           (peak-face (plist-get state :peak-face))
           (baseline-face (plist-get state :baseline-face)))
      (cl-loop for row below rows
               collect
               (cond
                ((= row baseline)
                 (concat (make-string left ?\s)
                         (propertize (make-string (- right left) ?─)
                                     'face baseline-face)
                         (make-string (- columns right) ?\s)))
                (t
                 (let ((parts nil) (cursor 0))
                   (dotimes (index count)
                     (let* ((x (+ left (* index (+ bar gap))))
                            (level (aref levels index))
                            (peak (aref peaks index))
                            (cells (max 1 (round (* height level))))
                            (peak-cells (max cells (round (* height peak))))
                            (reflection (max 0 (min 6 (round (* cells .18)))))
                            (face (aref faces (mod index (length faces))))
                            (cell
                             (cond
                              ((= row (- baseline peak-cells))
                               (cons ?▀ peak-face))
                              ((and (< row baseline) (>= row (- baseline cells)))
                               (cons ?█ (aref (plist-get face :shades) 5)))
                              ((and (> row baseline) (<= row (+ baseline reflection)))
                               (cons ?█ (plist-get face :reflection))))))
                       (when (> x cursor)
                         (push (make-string (- x cursor) ?\s) parts)
                         (setq cursor x))
                       (if cell
                           (progn
                             (push (propertize (make-string bar (car cell))
                                               'face (cdr cell))
                                   parts)
                             (setq cursor (+ x bar)))
                         (push (make-string bar ?\s) parts)
                         (setq cursor (+ x bar)))))
                   (if (< cursor columns)
                       (concat (apply #'concat (nreverse parts))
                               (make-string (- columns cursor) ?\s))
                     (apply #'concat (nreverse parts))))))))))

(provide 'etaf-screensaver-scene-equalizer)
;;; etaf-screensaver-scene-equalizer.el ends here
