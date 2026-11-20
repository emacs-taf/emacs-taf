;;; etaf-controlled-behavior.el --- Aggregate geometry Behaviors -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Controlled variants keep an application's aggregate geometry as the only
;; persistent authority.  They are used by application managers whose state is
;; not naturally represented by four independent refs.

;;; Code:

(require 'cl-lib)
(require 'etaf-behavior)

(declare-function etaf--keys-move-bindings "etaf-keys" (axis))
(declare-function etaf--keys-resize-bindings "etaf-keys" (edges))

(defun etaf--controlled-geometry-values (read required)
  "Read and validate geometry plist from READ for REQUIRED keys."
  (unless (functionp read)
    (signal 'etaf-behavior-error
            (list "Controlled geometry READ must be a function")))
  (let ((values (funcall read)))
    (unless (and (listp values) (cl-evenp (length values)))
      (signal 'etaf-behavior-error
              (list "Controlled geometry READ must return a plist")))
    (dolist (key required)
      (etaf--geometry-number (format "%s" key) (plist-get values key)))
    (copy-tree values)))

(defun etaf--controlled-geometry-callbacks (callbacks)
  "Validate CALLBACKS, an alist of names and optional functions."
  (dolist (entry callbacks)
    (etaf--geometry-callback (car entry) (cdr entry))))

;;;###autoload
(cl-defun etaf-draggable-controlled
    (read on-change &key axis delta on-start on-move on-end on-cancel)
  "Return a controlled draggable Behavior for aggregate geometry.
READ returns a geometry plist; ON-CHANGE receives a detached next plist.
AXIS is x, y, both, or nil to infer from READ.  DELTA converts the Ebox
pixel gesture to application units.  The Behavior keeps only a transient
origin while a gesture is active and does not retain application state."
  (unless (functionp on-change)
    (signal 'etaf-behavior-error
            (list "Controlled draggable ON-CHANGE must be a function")))
  (etaf--geometry-callback ":delta" delta)
  (etaf--controlled-geometry-callbacks
   (list (cons ":on-start" on-start) (cons ":on-move" on-move)
         (cons ":on-end" on-end) (cons ":on-cancel" on-cancel)))
  (let (origin effective-axis)
    (etaf-behavior-create
     'draggable-controlled
     :keys (etaf--keys-move-bindings axis)
     :on-drag
     (lambda (gesture)
       (let ((phase (plist-get gesture :phase)))
         (cond
          ((eq phase 'start)
           (let* ((values (etaf--controlled-geometry-values read nil))
                  (inferred (cond ((and (plist-member values :x)
                                        (plist-member values :y)) 'both)
                                  ((plist-member values :x) 'x)
                                  ((plist-member values :y) 'y)
                                  (t nil))))
             (setq effective-axis (or axis inferred))
             (unless (memq effective-axis '(x y both))
               (signal 'etaf-behavior-error
                       (list "Controlled draggable READ must expose :x or :y")))
             (dolist (key (cond ((eq effective-axis 'x) '(:x))
                                ((eq effective-axis 'y) '(:y))
                                (t '(:x :y))))
               (etaf--geometry-number (format "%s" key) (plist-get values key)))
             (setq origin values)
             (when on-start (funcall on-start gesture))))
          ((memq phase '(move end))
           (unwind-protect
               (when origin
                 (let* ((delta (etaf--geometry-delta gesture delta))
                        (next (copy-tree origin)))
                   (when (memq effective-axis '(x both))
                     (plist-put next :x (+ (plist-get origin :x) (car delta))))
                   (when (memq effective-axis '(y both))
                     (plist-put next :y (+ (plist-get origin :y) (cdr delta))))
                   (funcall on-change next)
                   (when (and (eq phase 'move) on-move)
                     (funcall on-move gesture))
                   (when (and (eq phase 'end) on-end)
                     (funcall on-end gesture))))
             (when (eq phase 'end) (setq origin nil))))
          ((eq phase 'cancel)
           (setq origin nil)
           (when on-cancel (funcall on-cancel gesture)))))))))

;;;###autoload
(cl-defun etaf-resizable-controlled
    (read on-change &key edges min-width max-width min-height max-height delta
          on-start on-resize on-end on-cancel)
  "Return a controlled resizable Behavior for aggregate geometry.
READ must return numeric :x, :y, :width and :height values.  ON-CHANGE
receives a detached next plist.  EDGES defaults to right and bottom; DELTA
converts Ebox pixels to application units.  The Behavior retains no persistent
geometry state."
  (unless (functionp on-change)
    (signal 'etaf-behavior-error
            (list "Controlled resizable ON-CHANGE must be a function")))
  (let* ((edges (cond ((null edges) (list 'right 'bottom))
                           ((symbolp edges) (list edges))
                           (t edges)))
         (edges (copy-sequence edges)))
    (unless (and (proper-list-p edges) edges
                 (cl-every (lambda (edge) (memq edge '(left right top bottom))) edges)
                 (= (length edges) (length (delete-dups (copy-sequence edges)))))
      (signal 'etaf-behavior-error
              (list (format "Invalid controlled resize edges: %S" edges))))
    (dolist (entry `((:min-width . ,min-width) (:max-width . ,max-width)
                     (:min-height . ,min-height) (:max-height . ,max-height)))
      (when (and (cdr entry) (not (numberp (cdr entry))))
        (signal 'etaf-behavior-error
                (list (format "%s must be numeric or nil: %S"
                              (car entry) (cdr entry))))))
    (when (and min-width max-width (> min-width max-width))
      (signal 'etaf-behavior-error
              (list "Controlled resize min-width exceeds max-width")))
    (when (and min-height max-height (> min-height max-height))
      (signal 'etaf-behavior-error
              (list "Controlled resize min-height exceeds max-height")))
    (etaf--geometry-callback ":delta" delta)
    (etaf--controlled-geometry-callbacks
     (list (cons ":on-start" on-start) (cons ":on-resize" on-resize)
           (cons ":on-end" on-end) (cons ":on-cancel" on-cancel)))
    (let (origin)
      (etaf-behavior-create
       'resizable-controlled
       :keys (etaf--keys-resize-bindings edges)
       :on-drag
       (lambda (gesture)
         (let ((phase (plist-get gesture :phase)))
           (cond
            ((eq phase 'start)
             (setq origin
                   (etaf--controlled-geometry-values
                    read '(:x :y :width :height)))
             (when on-start (funcall on-start gesture)))
            ((memq phase '(move end))
             (unwind-protect
                 (when origin
                   (let* ((delta (etaf--geometry-delta gesture delta))
                          (dx (car delta)) (dy (cdr delta))
                          (left-p (memq 'left edges))
                          (right-p (memq 'right edges))
                          (top-p (memq 'top edges))
                          (bottom-p (memq 'bottom edges))
                          (next (copy-tree origin))
                          (width (etaf--geometry-clamp
                                  (+ (plist-get origin :width)
                                     (if left-p (- dx) (if right-p dx 0)))
                                  (or min-width 0) max-width))
                          (height (etaf--geometry-clamp
                                   (+ (plist-get origin :height)
                                      (if top-p (- dy) (if bottom-p dy 0)))
                                   (or min-height 0) max-height)))
                     (when left-p
                       (plist-put next :x (+ (plist-get origin :x)
                                             (- (plist-get origin :width) width))))
                     (when top-p
                       (plist-put next :y (+ (plist-get origin :y)
                                             (- (plist-get origin :height) height))))
                     (plist-put next :width width)
                     (plist-put next :height height)
                     (funcall on-change next)
                     (when (and (eq phase 'move) on-resize)
                       (funcall on-resize gesture))
                     (when (and (eq phase 'end) on-end)
                       (funcall on-end gesture))))
               (when (eq phase 'end) (setq origin nil))))
            ((eq phase 'cancel)
             (setq origin nil)
             (when on-cancel (funcall on-cancel gesture))))))))))

(provide 'etaf-controlled-behavior)
;;; etaf-controlled-behavior.el ends here
