;;; etaf-screensaver-scene-donut.el --- Rotating ASCII torus -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The classic rotating torus, drawn per cell with a z-buffer instead of
;; sampling pixels: the two surface angles are sampled onto the character
;; grid, and the luminous ramp "." through "@" shades the visible side.  The
;; cosine and sine tables of the inner angle are rebuilt once per frame, so
;; the inner loop stays arithmetic only.
;;
;; The scene keeps its grid and z-buffer in the state; :resize rebuilds them
;; when the canvas changes size instead of losing the rotation.

;;; Code:

(require 'cl-lib)
(require 'etaf-screensaver-model)

(defconst etaf-screensaver--donut-ramp ".,-~:;=!*#$@"
  "Luminance ramp from dark to bright.")

(defun etaf-screensaver--donut-samples (detail)
  "Return (THETA-STEPS . PHI-STEPS) for DETAIL."
  (pcase detail
    ('coarse (cons 26 44))
    ('fine (cons 52 96))
    (_ (cons 36 64))))

(defun etaf-screensaver--donut-allocate (state rows columns)
  "Give STATE a ROWS by COLUMNS grid and z-buffer."
  (setf (plist-get state :grid) (make-string (* rows columns) ?\s)
        (plist-get state :zbuf) (make-vector (* rows columns) 0.0)))

(defun etaf-screensaver--donut-create (context)
  "Return a fresh torus state for CONTEXT."
  (let* ((rows (plist-get context :rows))
         (columns (plist-get context :columns)))
    (list :a 0.0 :b 0.0
          :grid (make-string (* rows columns) ?\s)
          :zbuf (make-vector (* rows columns) 0.0))))

(defun etaf-screensaver--donut-step (state context)
  "Rotate STATE's torus one frame in CONTEXT."
  (let ((speed (funcall (plist-get context :param) :speed))
        (dt (plist-get context :dt)))
    (setf (plist-get state :a) (+ (plist-get state :a) (* dt speed 0.10))
          (plist-get state :b) (+ (plist-get state :b) (* dt speed 0.06)))))

(defun etaf-screensaver--donut-render (state context)
  "Return STATE's shaded torus in CONTEXT.
The projection samples the torus surface onto the cell grid with a z-buffer,
so nearer surface wins each cell."
  (let* ((rows (plist-get context :rows))
         (columns (plist-get context :columns))
         (detail (funcall (plist-get context :param) :detail))
         (samples (etaf-screensaver--donut-samples detail))
         (theta-steps (car samples))
         (phi-steps (cdr samples))
         (grid (plist-get state :grid))
         (zbuf (plist-get state :zbuf))
         (a (plist-get state :a))
         (b (plist-get state :b))
         (sin-a (sin a)) (cos-a (cos a))
         (sin-b (sin b)) (cos-b (cos b))
         (r1 1.0) (r2 2.0) (k2 5.0)
         (k1 (min (* 0.34 columns) (* 0.66 rows)))
         (half-columns (/ columns 2.0))
         (half-rows (/ rows 2.0))
         (pcos (make-vector phi-steps 0.0))
         (psin (make-vector phi-steps 0.0))
         (ramp etaf-screensaver--donut-ramp)
         (last (1- (length ramp))))
    (dotimes (index phi-steps)
      (let ((phi (* 2.0 float-pi (/ index (float phi-steps)))))
        (aset pcos index (cos phi))
        (aset psin index (sin phi))))
    (fillarray grid ?\s)
    (fillarray zbuf 0.0)
    (dotimes (theta-index theta-steps)
      (let* ((theta (* 2.0 float-pi (/ theta-index (float theta-steps))))
             (sin-theta (sin theta))
             (cos-theta (cos theta))
             (circle-x (+ r2 (* r1 cos-theta)))
             (circle-y (* r1 sin-theta))
             (x-base-a (* circle-x cos-b))
             (x-base-b (- (* circle-y cos-a sin-b)))
             (y-base-a (* circle-x sin-b))
             (y-base-b (* circle-y cos-a cos-b))
             (z-base (* sin-a circle-y)))
        (dotimes (phi-index phi-steps)
          (let* ((cos-phi (aref pcos phi-index))
                 (sin-phi (aref psin phi-index))
                 (x (+ (* x-base-a cos-phi) (* sin-a sin-b circle-x sin-phi) x-base-b))
                 (y (+ (* y-base-a cos-phi)
                       (- (* sin-a cos-b circle-x sin-phi))
                       y-base-b))
                 (z (+ k2 (* cos-a circle-x sin-phi) z-base))
                 (ooz (/ 1.0 z))
                 (column (round (+ half-columns (* k1 ooz x))))
                 (row (round (- half-rows (* 0.5 k1 ooz y))))
                 (luminance (+ (* cos-phi cos-theta sin-b)
                               (- (* cos-a cos-theta sin-phi))
                               (- (* sin-a sin-theta))
                               (* cos-b (- (* cos-a sin-theta) (* cos-theta sin-a sin-phi))))))
            (when (and (> luminance 0.0)
                       (>= row 0) (< row rows)
                       (>= column 0) (< column columns))
              (let ((index (+ (* row columns) column)))
                (when (> ooz (aref zbuf index))
                  (aset zbuf index ooz)
                  (aset grid index
                        (aref ramp (min last (floor (* luminance (1+ last)))))))))))))
    (cl-loop for row below rows
             collect (substring grid (* row columns) (* (1+ row) columns)))))

(etaf-screensaver-define-scene donut
  :title "旋转甜甜圈"
  :summary "经典 ASCII 甜甜圈：逐格 z-buffer 上色，明暗当墨。"
  :tags '(3d math monochrome)
  :frame-rate 15
  :background "#05070B"
  :params '((:key speed :label "旋转速度" :type number
             :min 1 :max 20 :step 1 :default 6)
            (:key detail :label "采样精度" :type choice
             :options ((coarse . "低") (normal . "中") (fine . "高"))
             :default normal))
  :create (lambda (context)
            (etaf-screensaver--donut-create context))
  :step (lambda (state context)
          (etaf-screensaver--donut-step state context))
  :render (lambda (state context)
            (etaf-screensaver--donut-render state context))
  :resize (lambda (state context)
            (etaf-screensaver--donut-allocate
             state (plist-get context :rows) (plist-get context :columns))
            state))

(provide 'etaf-screensaver-scene-donut)
;;; etaf-screensaver-scene-donut.el ends here
