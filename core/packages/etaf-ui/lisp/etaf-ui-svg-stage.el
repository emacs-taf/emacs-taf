;;; etaf-ui-svg-stage.el --- Dirty-tile SVG sprite stage over tile grids -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Compose a static per-tile SVG scene with smoothly moving 2D pixel sprites
;; on top of `etaf-tile-grid'.  Each cell clips the shared stage coordinate
;; space through its own SVG viewBox; only tiles overlapped by a sprite's
;; bounding box rebuild their image descriptor when that sprite moves, while
;; untouched tiles reuse cached image descriptors.  On text terminals (or when
;; `:graphic' is nil) the stage falls back cleanly to `:cell-text' and cell
;; colors without changing layout or keyboard navigation.

;;; Code:
(require 'cl-lib)
(require 'etaf-ui-basic)
(require 'etaf-ui-svg)
(require 'etaf-ui-tile-grid)

(defconst etaf-ui--svg-stage-cache-limit 512
  "Maximum cached tile image descriptors per `etaf-svg-stage' instance.")

(defun etaf-ui--svg-stage-graphic-p (mode)
  "Return non-nil when MODE should paint SVG tiles on the current frame."
  (pcase mode
    ('t t)
    ('nil nil)
    ('auto (and (display-graphic-p)
                (fboundp 'image-type-available-p)
                (image-type-available-p 'svg)))))

(defun etaf-ui--svg-stage-sprites (source)
  "Read sprite list from SOURCE (list, reactive source, function or nil)."
  (let ((list (cond
               ((null source) nil)
               ((functionp source) (funcall source))
               (t (etaf-ui--reactive-value source)))))
    (etaf-check-prop :sprites list (proper-list-p list)
                     "nil, a sprite list, a reactive source or a zero-argument function"
                     'etaf-svg-stage)
    list))

(defun etaf-ui--svg-stage-sprite-overlap-p (sprite tx ty tw th)
  "Return non-nil when SPRITE's bounding box overlaps tile [TX,TY,TW,TH]."
  (let ((sx (plist-get sprite :x))
        (sy (plist-get sprite :y))
        (sw (plist-get sprite :width))
        (sh (plist-get sprite :height)))
    (etaf-check-prop :sprites sprite
                     (and (proper-list-p sprite)
                          (numberp sx) (numberp sy)
                          (numberp sw) (> sw 0)
                          (numberp sh) (> sh 0)
                          (let ((markup (plist-get sprite :markup)))
                            (or (stringp markup) (functionp markup))))
                     "plists with numeric :x/:y, positive :width/:height and string/function :markup"
                     'etaf-svg-stage)
    (and (< sx (+ tx tw))
         (> (+ sx sw) tx)
         (< sy (+ ty th))
         (> (+ sy sh) ty))))

(defun etaf-ui--svg-stage-sprite-markup (sprite)
  "Return SVG markup string for SPRITE."
  (let* ((raw (plist-get sprite :markup))
         (markup (if (functionp raw) (funcall raw) raw)))
    (etaf-check-prop :sprites markup (stringp markup)
                     "SVG markup string from :markup" 'etaf-svg-stage)
    markup))

(defun etaf-ui--svg-stage-cache-get (cache key)
  "Look up KEY in stage tile CACHE."
  (gethash key cache))

(defun etaf-ui--svg-stage-cache-put (cache key value)
  "Store KEY -> VALUE in stage tile CACHE, clearing at the fixed bound."
  (when (>= (hash-table-count cache) etaf-ui--svg-stage-cache-limit)
    (clrhash cache))
  (puthash key value cache))

(etaf-define-component etaf-svg-stage
    (&key rows columns (cell-width 2) (cell-height 1) tile-width tile-height
          cell-svg sprites cell-text cell-background cell-color cell-label
          cell-ref on-cell-press on-cell-focus (graphic 'auto))
  "Render a tiled SVG stage with dirty-tile sprite compositing."
  :bindings ((cache (make-hash-table :test #'equal)))
  :validate
  (progn
    (dolist (entry (list (cons :rows rows) (cons :columns columns)
                         (cons :cell-width cell-width)
                         (cons :cell-height cell-height)))
      (etaf-check-prop (car entry) (cdr entry)
                       (and (integerp (cdr entry)) (> (cdr entry) 0))
                       "a positive integer" 'etaf-svg-stage))
    (dolist (entry (list (cons :tile-width tile-width)
                         (cons :tile-height tile-height)))
      (etaf-check-prop (car entry) (cdr entry)
                       (or (null (cdr entry))
                           (and (integerp (cdr entry)) (> (cdr entry) 0)))
                       "nil or a positive integer" 'etaf-svg-stage))
    (etaf-check-prop :cell-svg cell-svg (functionp cell-svg)
                     "a function (row column tile-width tile-height)"
                     'etaf-svg-stage)
    (etaf-check-prop :graphic graphic (memq graphic '(auto t nil))
                     "auto, t or nil" 'etaf-svg-stage)
    (dolist (entry (list (cons :cell-text cell-text)
                         (cons :cell-background cell-background)
                         (cons :cell-color cell-color)
                         (cons :cell-label cell-label)
                         (cons :cell-ref cell-ref)
                         (cons :on-cell-press on-cell-press)
                         (cons :on-cell-focus on-cell-focus)))
      (etaf-check-prop (car entry) (cdr entry)
                       (or (null (cdr entry)) (functionp (cdr entry)))
                       "a coordinate callback or nil" 'etaf-svg-stage)))
  :render
  (let* ((tw (or tile-width (* cell-width 8)))
         (th (or tile-height (* cell-height 16)))
         (use-svg (etaf-ui--svg-stage-graphic-p graphic))
         (cell-image
          (when use-svg
            (lambda (row column)
              (let* ((tx (* column tw))
                     (ty (* row th))
                     (base (funcall cell-svg row column tw th))
                     (active-sprites (etaf-ui--svg-stage-sprites sprites))
                     (overlays nil))
                (etaf-check-prop :cell-svg base (stringp base)
                                 "an SVG markup string" 'etaf-svg-stage)
                (dolist (sprite active-sprites)
                  (when (etaf-ui--svg-stage-sprite-overlap-p
                         sprite tx ty tw th)
                    (push (etaf-ui--svg-stage-sprite-markup sprite) overlays)))
                (setq overlays (nreverse overlays))
                (let* ((key (list row column tw th base overlays))
                       (cached (etaf-ui--svg-stage-cache-get cache key)))
                  (or cached
                      (let ((image (etaf-ui-svg-image
                                    (if overlays
                                        (apply #'concat base overlays)
                                      base)
                                    tw th (list tx ty tw th))))
                        (etaf-ui--svg-stage-cache-put cache key image)))))))))
    (etaf-view
     (etaf-tile-grid
      :rows rows :columns columns
      :cell-width cell-width :cell-height cell-height
      :cell-image cell-image
      :cell-text cell-text :cell-background cell-background
      :cell-color cell-color :cell-label cell-label
      :cell-ref cell-ref :on-cell-press on-cell-press
      :on-cell-focus on-cell-focus))))

(provide 'etaf-ui-svg-stage)
;;; etaf-ui-svg-stage.el ends here
