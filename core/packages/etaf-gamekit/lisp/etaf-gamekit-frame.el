;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-frame.el --- Published native frames as image strips

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A native renderer publishes a frame canvas as image strips, one per text
;; line, each changed strip as a new numbered file.  `etaf-gamekit-frame-canvas'
;; shows every strip as the image of one line of a Text Host and replaces only
;; the images whose strip changed, so a moving scene decodes a few lines
;; instead of the whole canvas.  Text displays, and graphic displays before a
;; matching frame arrives, show the caller's fallback text.
;;
;; The producer owns its transport and its artwork.  This module owns the
;; client side of the frame contract documented in the package manual.

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'image)
(declare-function image-flush "image" (image &optional))

(defconst etaf-gamekit--frame-canvas-flush-batch 10
  "Frames shown before replaced strip images leave Emacs's image cache.
Evicting an image garbages the whole frame for one full redisplay, so the
replaced images of several frames are released together.")

(cl-defstruct (etaf-gamekit--frame-canvas (:constructor etaf-gamekit--frame-canvas-create)
                                          (:copier nil))
  "Mutable presentation state of one mounted frame canvas.
RUNTIME and REF address the mounted Host and CELL holds its content.  FRAME is
the latest frame description; SHOWN is the (BLOCK LINE WIDTH ASCENT)
presentation of IMAGES and SERIALS, one per strip row.  DIRECTORY holds the
strip files and ASCENT the image baseline percentage.  RETIRED images wait for
the next batched cache flush after PRESENTED frames."
  runtime ref cell geometry directory ascent frame shown images serials cells retired (presented 0))

(defun etaf-gamekit--frame-canvas-matches-p (canvas frame)
  "Whether FRAME was drawn for CANVAS's current geometry.
A renderer needs one frame to adopt a new block or strip size; until then the
canvas keeps showing the strips it has."
  (let ((geometry (etaf-gamekit--frame-canvas-geometry canvas)))
    (and frame (plist-get geometry :graphic)
         (eql (plist-get frame :block) (plist-get geometry :device-block))
         (eql (plist-get frame :line) (plist-get geometry :device-line))
         (eql (plist-get frame :width) (* (plist-get geometry :pixel-width)
                                          (plist-get geometry :density))))))

(defun etaf-gamekit--frame-canvas-adopt (canvas)
  "Load the strips of CANVAS's frame that changed; return non-nil if any did.
A strip whose file is gone keeps its previous image: a producer retires a file
only after writing newer versions, which a later frame then names."
  (let ((frame (etaf-gamekit--frame-canvas-frame canvas)))
    (when (etaf-gamekit--frame-canvas-matches-p canvas frame)
      (let* ((strips (append (plist-get frame :strips) nil)) (count (length strips))
             (shape (list (plist-get frame :block) (plist-get frame :line)
                          (plist-get frame :width) (etaf-gamekit--frame-canvas-ascent canvas)))
             (scale (/ 1.0 (plist-get (etaf-gamekit--frame-canvas-geometry canvas) :density)))
             (directory (etaf-gamekit--frame-canvas-directory canvas))
             (changed nil))
        (unless (and (equal shape (etaf-gamekit--frame-canvas-shown canvas))
                     (= count (length (etaf-gamekit--frame-canvas-images canvas))))
          (etaf-gamekit--frame-canvas-retire canvas)
          (setf (etaf-gamekit--frame-canvas-shown canvas) shape
                (etaf-gamekit--frame-canvas-images canvas) (make-vector count nil)
                (etaf-gamekit--frame-canvas-serials canvas) (make-vector count nil)
                (etaf-gamekit--frame-canvas-cells canvas) (make-vector count " ")))
        (let ((images (etaf-gamekit--frame-canvas-images canvas))
              (serials (etaf-gamekit--frame-canvas-serials canvas))
              (cells (etaf-gamekit--frame-canvas-cells canvas)))
          (cl-loop for serial in strips for row from 0 do
                   (unless (eql serial (aref serials row))
                     (let ((file (expand-file-name (format "%d-%d.png" row serial) directory)))
                       (when (file-exists-p file)
                         (when (aref images row)
                           (push (aref images row) (etaf-gamekit--frame-canvas-retired canvas)))
                         (let ((image (create-image file 'png nil :scale scale
                                                    :ascent (etaf-gamekit--frame-canvas-ascent canvas))))
                           (aset images row image)
                           (aset serials row serial)
                           (aset cells row (propertize " " 'display image))
                           (setq changed t)))))))
        changed))))

(defun etaf-gamekit--frame-canvas-retire (canvas)
  "Schedule every strip image CANVAS shows for eviction."
  (let ((images (etaf-gamekit--frame-canvas-images canvas)))
    (when images
      (cl-loop for image across images
               when image do (push image (etaf-gamekit--frame-canvas-retired canvas))))
    (setf (etaf-gamekit--frame-canvas-images canvas) nil
          (etaf-gamekit--frame-canvas-serials canvas) nil
          (etaf-gamekit--frame-canvas-cells canvas) nil
          (etaf-gamekit--frame-canvas-shown canvas) nil)))

(defun etaf-gamekit--frame-canvas-release (canvas)
  "Evict CANVAS's retired strip images from Emacs's image cache."
  (dolist (image (etaf-gamekit--frame-canvas-retired canvas))
    (image-flush image))
  (setf (etaf-gamekit--frame-canvas-retired canvas) nil))

(defun etaf-gamekit--frame-canvas-content (canvas)
  "Return CANVAS's text: one strip image per line, or blank lines."
  (let ((cells (etaf-gamekit--frame-canvas-cells canvas)))
    (if (and cells (> (length cells) 0))
        (mapconcat #'identity cells "\n")
      (mapconcat #'identity
                 (make-list (max 1 (plist-get (etaf-gamekit--frame-canvas-geometry canvas) :rows))
                            " ")
                 "\n"))))

(defun etaf-gamekit--frame-canvas-present (canvas)
  "Replace CANVAS's mounted content with its current strips."
  (let ((runtime (etaf-gamekit--frame-canvas-runtime canvas)))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (let ((content (etaf-gamekit--frame-canvas-content canvas)))
        (setcar (etaf-gamekit--frame-canvas-cell canvas) content)
        (etaf-runtime-update-host-content runtime (etaf-gamekit--frame-canvas-ref canvas) content)
        (when (>= (cl-incf (etaf-gamekit--frame-canvas-presented canvas))
                  etaf-gamekit--frame-canvas-flush-batch)
          (setf (etaf-gamekit--frame-canvas-presented canvas) 0)
          (etaf-gamekit--frame-canvas-release canvas))))))

(defvar etaf-gamekit--frame-canvas-counter 0
  "Counter giving each mounted frame canvas a session-unique Host id.")

(etaf-define-component etaf-gamekit-frame-canvas
    (&key frame text geometry directory background ref label)
  "Show the native canvas published as FRAME, or TEXT when no frame matches.
FRAME is a reactive frame description; GEOMETRY is the reactive geometry
plist; DIRECTORY holds the strip files named ROW-SERIAL.png.  TEXT is the
reactive fallback shown on text displays or until a matching frame arrives.
LABEL is the region's accessible name; REF is the canvas Host reference."
  :bindings ((content-ref (etaf-local-ref 'content))
             (content-id (format "etaf-gamekit-frame-canvas-%d" (cl-incf etaf-gamekit--frame-canvas-counter)))
             (canvas (etaf-gamekit--frame-canvas-create
                      :ref content-ref :cell (cons " " nil) :directory directory
                      :ascent (plist-get (etaf-value geometry) :ascent))))
  :setup
  (let ((graphic (plist-get (etaf-value geometry) :graphic)))
    ;; A remounted canvas starts from the latest frame: producers publish only
    ;; on change, so a static scene may never send another one.
    (setf (etaf-gamekit--frame-canvas-geometry canvas) (etaf-value geometry))
    (if graphic
        (progn (setf (etaf-gamekit--frame-canvas-frame canvas) (etaf-value frame))
               (etaf-gamekit--frame-canvas-adopt canvas)
               (setcar (etaf-gamekit--frame-canvas-cell canvas) (etaf-gamekit--frame-canvas-content canvas)))
      (setcar (etaf-gamekit--frame-canvas-cell canvas) (or (etaf-value text) " ")))
    (etaf-on-mounted (lambda ()
                       (setf (etaf-gamekit--frame-canvas-runtime canvas) (etaf-current-runtime))
                       (when graphic (etaf-gamekit--frame-canvas-present canvas))))
    (etaf-on-unmounted (lambda ()
                         (etaf-gamekit--frame-canvas-retire canvas)
                         (etaf-gamekit--frame-canvas-release canvas)
                         (setf (etaf-gamekit--frame-canvas-runtime canvas) nil)))
    (if graphic
        (progn
          ;; Resizing renders the box first; the strips follow once the
          ;; renderer has drawn a frame for the new geometry.
          (etaf-watch geometry (lambda (next _old)
                                 (setf (etaf-gamekit--frame-canvas-geometry canvas) next
                                       (etaf-gamekit--frame-canvas-ascent canvas) (plist-get next :ascent))
                                 (etaf-gamekit--frame-canvas-adopt canvas)
                                 (etaf-gamekit--frame-canvas-present canvas))
                      :flush 'post :test #'equal)
          (etaf-watch frame (lambda (next _old)
                              (setf (etaf-gamekit--frame-canvas-frame canvas) next)
                              (when (etaf-gamekit--frame-canvas-adopt canvas)
                                (etaf-gamekit--frame-canvas-present canvas)))
                      :flush 'post :test #'equal))
      (etaf-watch text (lambda (next _old)
                         (let ((runtime (etaf-gamekit--frame-canvas-runtime canvas)))
                           (setcar (etaf-gamekit--frame-canvas-cell canvas) (or next " "))
                           (when (and runtime (etaf-runtime-mounted-p runtime))
                             (etaf-runtime-update-host-content runtime content-ref (or next " ")))))
                  :flush 'post :test #'equal)))
  :view
  (box :ref ref :width (let ((g (etaf-value geometry)))
                         (if (plist-get g :graphic)
                             (list 'px (plist-get g :pixel-width))
                           (list 'ch (plist-get g :columns))))
       :height (list 'lh (plist-get (etaf-value geometry) :rows))
       :position 'static :left '(px 0) :top '(lh 0) :z-index 0
       :wrap-mode 'none :overflow 'hidden :background-color background
       :tab-index 0 :role 'region :aria-label (or label "Frame canvas")
    (text :ref content-ref :id content-id (expr (car (etaf-gamekit--frame-canvas-cell canvas))))))

(provide 'etaf-gamekit-frame)
;;; etaf-gamekit-frame.el ends here
