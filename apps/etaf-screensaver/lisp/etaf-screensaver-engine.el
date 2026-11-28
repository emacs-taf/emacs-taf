;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-engine.el --- Scene frames and retained publication

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One owner supplies time and viewport changes.  Mosaic children have their
;; own scene states and random streams, but no Runtime, timer or input owner.
;; Only changed rows of the composed parent cross ETAF's retained Host
;; boundary, together in one publication.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-playlist)
(require 'etaf-screensaver-presentation)
(declare-function image-flush "image.c" (image &optional frame))

(cl-defstruct (etaf-screensaver--session (:constructor etaf-screensaver--session-new))
  scene state item seed random-state columns rows window-columns window-rows
  size revision params ticks elapsed dt frame publication published-frame images runtime buffer
  children layout metrics composition-context template previous-rows transition-duration)

(defun etaf-screensaver--frame-display (rows &optional canvas-background)
  "Project logical fragment ROWS into one compact publication string.
Image slices become single replacing glyphs.  Ordinary text, including blank
runs, is emitted unchanged: its own face already gives it the right pixel
width, and rescanning every changing row for blank runs costs more than the
layout it saves.  Presentation backgrounds are added only when they differ
from CANVAS-BACKGROUND, which the mounted canvas already paints."
  (save-match-data
    (let ((output-length 0) pieces paints)
      (cl-labels ((emit (text)
                    (push text pieces)
                    (cl-incf output-length (length text))))
        (dolist (row rows)
          (when pieces (emit "\n"))
          (dolist (part row)
            (let* ((fragment (etaf-screensaver--frame-fragment-p part))
                   (frame (if fragment (etaf-screensaver--frame-fragment-text part) part))
                   (background (and fragment (etaf-screensaver--frame-fragment-background part)))
                   (output-start output-length)
                   (length (length frame)))
              (if (not (text-property-not-all 0 length 'display nil frame))
                  (emit frame)
                (let ((position 0) (start 0))
                  (while (< position length)
                    (let* ((display (get-text-property position 'display frame))
                           (end (next-single-property-change position 'display frame length)))
                      (when (and display
                                 (eq (car-safe (car-safe display)) 'slice)
                                 (eq (car-safe (cadr display)) 'image))
                        (emit (substring frame start position))
                        (emit (substring frame position (1+ position)))
                        (setq start end))
                      (setq position end)))
                  (emit (if (= start 0) frame (substring frame start)))))
              (when (and background
                         (not (equal background canvas-background)))
                (push (list output-start output-length background) paints)))))
        (let ((text (apply #'concat (nreverse pieces))))
          (dolist (paint paints)
            (add-face-text-property (nth 0 paint) (nth 1 paint)
                                    (list :background (nth 2 paint)) t text))
          text)))))

(defun etaf-screensaver--frame-images (frame)
  "Return the distinct image objects FRAME displays."
  (let ((position 0) (length (length frame)) images)
    (while (< position length)
      (let ((display (get-text-property position 'display frame)))
        (when (eq (car-safe (car-safe (cdr-safe display))) 'image)
          (cl-pushnew (cadr display) images :test #'equal)))
      (setq position (next-single-property-change position 'display frame length)))
    images))

(defun etaf-screensaver--session-flush-images (session keep)
  "Flush SESSION's previously published images absent from KEEP."
  ;; A terminal frame has no decoded-image cache.  The public image-flush
  ;; operation requires a graphical frame rather than being a no-op there.
  (when (display-graphic-p)
    (dolist (image (etaf-screensaver--session-images session))
      (unless (member image keep) (image-flush image))))
  (setf (etaf-screensaver--session-images session) keep))

(defun etaf-screensaver--session-context (session)
  "Return SESSION's pure callback context, including inherited display metrics."
  (let ((random-state (etaf-screensaver--session-random-state session)))
    (list :columns (etaf-screensaver--session-columns session)
          :rows (etaf-screensaver--session-rows session)
          :seed (etaf-screensaver--session-seed session)
          :tick (etaf-screensaver--session-ticks session)
          :elapsed (etaf-screensaver--session-elapsed session)
          :dt (etaf-screensaver--session-dt session)
          :metrics (etaf-screensaver--session-metrics session)
          :background (plist-get (etaf-screensaver--session-item session) :background)
          :params (mapcar #'car (etaf-screensaver--session-params session))
          :param (lambda (key)
                   (let ((entry (assq (etaf-screensaver--parameter-key key)
                                      (etaf-screensaver--session-params session))))
                     (unless entry (etaf-screensaver--fail "Unknown parameter: %s" key))
                     (cdr entry)))
          :random (lambda (&optional limit)
                    (if limit (cl-random limit random-state)
                      (/ (float (cl-random 1000000 random-state)) 1000000.0))))))

(defun etaf-screensaver--session-scene-rows (session)
  "Render SESSION's rectangular logical rows without presentation faces.
Scene rows may be borrowed; publication owns any added background properties."
  (let* ((frame (funcall (etaf-screensaver--scene-render (etaf-screensaver--session-scene session))
                         (etaf-screensaver--session-state session)
                         (etaf-screensaver--session-context session)))
         (lines (cond ((stringp frame) (split-string frame "\n"))
                      ((proper-list-p frame) frame)
                      (t (etaf-screensaver--fail "Scene must render a string or row list"))))
         (columns (etaf-screensaver--session-columns session)))
    (cl-loop repeat (etaf-screensaver--session-rows session)
             for line = (or (pop lines) "")
             collect
             (progn
               (unless (stringp line) (etaf-screensaver--fail "Scene rows must be strings"))
               (etaf-screensaver--presentation-crop
                (string-replace "\r" "" (string-replace "\t" " " line)) columns)))))

(defun etaf-screensaver--session-render (session)
  "Project SESSION's independent works into its window rectangle."
  (let* ((runtime (etaf-screensaver--session-runtime session))
         (children (etaf-screensaver--session-children session))
         (works (or children (list session)))
         (item (etaf-screensaver--session-item session))
         (style (plist-get item :presentation)))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (setf (etaf-screensaver--session-metrics session) (etaf-display-metrics runtime)))
    (dolist (child children)
      (setf (etaf-screensaver--session-metrics child) (etaf-screensaver--session-metrics session)))
    (setf (etaf-screensaver--session-frame session)
          (if (eq style 'full)
              (mapcar #'list (etaf-screensaver--session-scene-rows session))
            (let* ((context (or (etaf-screensaver--session-composition-context session)
                                (setf (etaf-screensaver--session-composition-context session)
                                      (list :layout (etaf-screensaver--session-layout session)
                                            :columns (etaf-screensaver--session-window-columns session)
                                            :rows (etaf-screensaver--session-window-rows session)
                                            :backgrounds (mapcar (lambda (work) (plist-get (etaf-screensaver--session-item work) :background)) works)
                                            :titles (mapcar (lambda (work) (etaf-screensaver--scene-title (etaf-screensaver--session-scene work))) works)
                                            :summaries (mapcar (lambda (work) (etaf-screensaver--scene-summary (etaf-screensaver--session-scene work))) works)
                                            :pack-title (plist-get item :pack-title) :clock nil))))
                   (clock (and (eq style 'band) (format-time-string "%H:%M"))))
              (when (or (null (etaf-screensaver--session-template session))
                        (not (equal clock (plist-get context :clock))))
                (setf (plist-get context :clock) clock
                      (etaf-screensaver--session-template session)
                      (etaf-screensaver--presentation-template style context)))
              (etaf-screensaver--presentation-compose
               (mapcar #'etaf-screensaver--session-scene-rows works)
               context (etaf-screensaver--session-template session)))))
    (when (etaf-screensaver--session-previous-rows session)
      (let ((progress (/ (etaf-screensaver--session-elapsed session)
                         (etaf-screensaver--session-transition-duration session))))
        (if (>= progress 1)
            (setf (etaf-screensaver--session-previous-rows session) nil)
          ;; Reuse complete native image slices and text rows.  Smoothstep
          ;; eases both ends without recompressing images or making SVGs.
          (let* ((rows (etaf-screensaver--session-window-rows session))
                 (revealed (round (* rows progress progress (- 3 (* 2 progress))))))
            (setf (etaf-screensaver--session-frame session)
                  (append (cl-subseq (etaf-screensaver--session-frame session) 0 revealed)
                          (nthcdr revealed (etaf-screensaver--session-previous-rows session))))))))
    (let ((previous (etaf-screensaver--session-publication session)))
      (setf (etaf-screensaver--session-publication session)
            (mapcar (lambda (row)
                      (cons (or (car (pop previous)) (make-symbol "screensaver-row"))
                            (etaf-screensaver--frame-display
                     (list row) (etaf-screensaver--session-background session))))
                    (etaf-screensaver--session-frame session))))))

(defun etaf-screensaver--session-select (session item seed &optional transition)
  "Initialize SESSION for ITEM at SEED, with optional TRANSITION seconds."
  ;; A delayed tick must not carry unfinished snapshots across many pages.
  ;; Finish the prior reveal before retaining at most one outgoing page.
  (when (etaf-screensaver--session-previous-rows session)
    (setf (etaf-screensaver--session-previous-rows session) nil)
    (etaf-screensaver--session-render session))
  (let* ((previous (when (and transition (> transition 0)
                              (etaf-screensaver--session-frame session)
                              (not (equal item (etaf-screensaver--session-item session))))
                     ;; Snapshot rows before the old state is released.  The
                     ;; outgoing full canvas may have inherited its background;
                     ;; freeze it without changing any scene-owned strings.
                     (mapcar
                      (lambda (row)
                        (mapcar (lambda (part)
                                  (etaf-screensaver--frame-fragment-copy
                                   part (etaf-screensaver--session-background session)))
                                row))
                      (etaf-screensaver--session-frame session))))
         (tiles (plist-get item :tiles))
         (layout (etaf-screensaver--presentation-layout
                  (plist-get item :presentation)
                  (etaf-screensaver--session-window-columns session)
                  (etaf-screensaver--session-window-rows session)
                  (max 1 (length tiles))))
         (slot (car (plist-get layout :slots))))
    (setf (etaf-screensaver--session-layout session) layout
          (etaf-screensaver--session-previous-rows session) previous
          (etaf-screensaver--session-transition-duration session)
          (and previous (min transition (/ (plist-get item :duration) 2.0)))
          (etaf-screensaver--session-composition-context session) nil
          (etaf-screensaver--session-template session) nil
          (etaf-screensaver--session-columns session) (nth 2 slot)
          (etaf-screensaver--session-rows session) (nth 3 slot)
          (etaf-screensaver--session-item session) item
          (etaf-screensaver--session-scene session) (plist-get item :definition)
          (etaf-screensaver--session-seed session) seed
          (etaf-screensaver--session-random-state session) (cl-make-random-state seed)
          (etaf-screensaver--session-params session) (plist-get item :params)
          (etaf-screensaver--session-ticks session) 0
          (etaf-screensaver--session-elapsed session) 0.0
          (etaf-screensaver--session-dt session) 0.0
          (etaf-screensaver--session-published-frame session) nil
          (etaf-screensaver--session-children session)
          (cl-loop for tile in tiles for rect in (plist-get layout :slots) for index from 0
                   collect
                   (let ((child (plist-put (copy-sequence tile) :presentation 'full)))
                     ;; Concurrent works are an overview of their complete
                     ;; animation, not several competing magnified subjects.
                     (when (and (> (length tiles) 1)
                                (eq (plist-get child :reel-text-scale) 'auto))
                       (setf (plist-get child :reel-text-scale) 1))
                     (etaf-screensaver--session-create
                      child (+ seed index) (nth 2 rect) (nth 3 rect) nil)))
          (etaf-screensaver--session-state session)
          (unless tiles
            (let ((etaf-screensaver-reel-text-scale (plist-get item :reel-text-scale)))
              (funcall (etaf-screensaver--scene-create (etaf-screensaver--session-scene session))
                       (etaf-screensaver--session-context session))))))
  (when (etaf-screensaver--session-buffer session)
    (etaf-screensaver--session-render session))
  (cl-incf (etaf-value (etaf-screensaver--session-revision session))))

(defun etaf-screensaver--session-create (item seed columns rows buffer)
  "Create ITEM at SEED and window size COLUMNS by ROWS for BUFFER."
  (let ((session (etaf-screensaver--session-new
                  :window-columns columns :window-rows rows :buffer buffer
                  :size (etaf-ref (cons columns rows)) :revision (etaf-ref 0))))
    (etaf-screensaver--session-select session item seed)
    session))

(defun etaf-screensaver--session-publish (session)
  "Publish SESSION's changed rows together through retained Text Hosts."
  (let ((runtime (etaf-screensaver--session-runtime session))
        (publication (etaf-screensaver--session-publication session))
        (previous (etaf-screensaver--session-published-frame session))
        updates images)
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (dolist (row publication)
        ;; Compare immutable text, never a scene's mutable source strings.
        (let ((old (pop previous)))
          (unless (and (eq (car row) (car old))
                       (equal-including-properties (cdr row) (cdr old)))
            (push row updates))))
      (when updates
        (etaf-runtime-update-host-contents runtime (nreverse updates))
        (dolist (row publication)
          (dolist (image (etaf-screensaver--frame-images (cdr row)))
            (cl-pushnew image images :test #'equal)))
        (etaf-screensaver--session-flush-images session images)
        (setf (etaf-screensaver--session-published-frame session) publication)))))

(defun etaf-screensaver--session-step (session dt)
  "Advance SESSION and every independent child by DT, without publishing."
  (setf (etaf-screensaver--session-dt session) dt)
  (if (etaf-screensaver--session-children session)
      (dolist (child (etaf-screensaver--session-children session))
        (etaf-screensaver--session-step child dt))
    (funcall (etaf-screensaver--scene-step (etaf-screensaver--session-scene session))
             (etaf-screensaver--session-state session)
             (etaf-screensaver--session-context session)))
  (cl-incf (etaf-screensaver--session-ticks session))
  (cl-incf (etaf-screensaver--session-elapsed session) dt))

(defun etaf-screensaver--session-advance (session dt)
  "Advance SESSION by DT seconds, compose and publish once."
  (etaf-screensaver--session-step session dt)
  (etaf-screensaver--session-render session)
  (etaf-screensaver--session-publish session))

(defun etaf-screensaver--session-resize (session columns rows)
  "Resize SESSION and each independent work without changing playback order."
  (unless (and (= columns (etaf-screensaver--session-window-columns session))
               (= rows (etaf-screensaver--session-window-rows session)))
    (let* ((children (etaf-screensaver--session-children session))
           (layout (etaf-screensaver--presentation-layout
                    (plist-get (etaf-screensaver--session-item session) :presentation)
                    columns rows (max 1 (length children))))
           (slot (car (plist-get layout :slots)))
           (changed (or (/= (nth 2 slot) (etaf-screensaver--session-columns session))
                        (/= (nth 3 slot) (etaf-screensaver--session-rows session)))))
      ;; A snapshot belongs to its original geometry.  Finish the reveal on
      ;; resize instead of stretching or clipping an obsolete page over it.
      (setf (etaf-screensaver--session-previous-rows session) nil
            (etaf-screensaver--session-window-columns session) columns
            (etaf-screensaver--session-window-rows session) rows
            (etaf-screensaver--session-layout session) layout
            (etaf-screensaver--session-composition-context session) nil
            (etaf-screensaver--session-template session) nil
            (etaf-screensaver--session-columns session) (nth 2 slot)
            (etaf-screensaver--session-rows session) (nth 3 slot))
      (cond
       (children
        (cl-loop for child in children for rect in (plist-get layout :slots)
                 do (etaf-screensaver--session-resize child (nth 2 rect) (nth 3 rect))))
       (changed
        (let ((resize (etaf-screensaver--scene-resize (etaf-screensaver--session-scene session))))
          (if resize
              (setf (etaf-screensaver--session-state session)
                    (funcall resize (etaf-screensaver--session-state session)
                             (etaf-screensaver--session-context session)))
            (etaf-screensaver--session-select session (etaf-screensaver--session-item session)
                                              (etaf-screensaver--session-seed session))))))
      (when (etaf-screensaver--session-buffer session)
        (etaf-screensaver--session-render session))
      (setf (etaf-value (etaf-screensaver--session-size session)) (cons columns rows))
      (when-let* ((runtime (etaf-screensaver--session-runtime session)))
        ;; Resize can add row Hosts; commit their View before addressing them.
        (etaf-runtime-flush runtime)
        (etaf-screensaver--session-publish session)))))

(defun etaf-screensaver--session-background (session)
  "Return SESSION's outer canvas color, including its framing mat."
  (let* ((item (etaf-screensaver--session-item session))
         (background (plist-get item :background)))
    (if (memq (plist-get item :presentation) '(full card)) background
      (plist-get (etaf-screensaver--presentation-palette background) :mat))))

(provide 'etaf-screensaver-engine)
;;; etaf-screensaver-engine.el ends here
