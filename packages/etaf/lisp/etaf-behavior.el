;;; etaf-behavior.el --- Non-visual :use Behaviors -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Behavior is a reusable bundle of semantic attributes and optional setup
;; cleanup.  It is data attached through `:use', never a View node.  Local
;; `:on-*' callbacks remain the simpler choice for one-off interaction.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)

(declare-function etaf--keys-move-bindings "etaf-keys" (axis))
(declare-function etaf--keys-resize-bindings "etaf-keys" (edges))

(define-error 'etaf-behavior-error "Invalid ETAF Behavior")

(cl-defstruct (etaf-behavior-spec
               (:constructor etaf--behavior-spec-create))
  "A name-plus-attributes non-visual Behavior specification."
  name
  attributes
  install)

(cl-defstruct (etaf-behavior-context
               (:constructor etaf--behavior-context-create))
  "Runtime context supplied to an optional Behavior installer."
  runtime
  host-props)

(defvar etaf--current-behavior-context nil
  "Behavior context active while one Behavior installs.")

;;;###autoload
(defun etaf-current-behavior-context ()
  "Return the Behavior context active during an installer, or nil."
  etaf--current-behavior-context)

;;;###autoload
(defun etaf-behavior-context-info (context)
  "Return CONTEXT's installation facts as a fresh plist.
CONTEXT comes from `etaf-current-behavior-context' during an installer.
Keys are :runtime (the owning Runtime), :host-ref (the effective Host reference)
and :properties (installation-time semantic Host properties).
The plist and property container are fresh; contained values retain identity
and must be treated as read-only.  These facts remain readable after cleanup,
but do not certify that the candidate published or the Host is still mounted.
Use Runtime public queries for committed state, and return installer cleanup
to release resources on replacement, rollback or unmount.
Invalid CONTEXT signals `etaf-behavior-error'."
  (unless (etaf-behavior-context-p context)
    (signal 'etaf-behavior-error (list "Expected a Behavior installation context")))
  (let ((props (etaf-behavior-context-host-props context)))
    (list :runtime (etaf-behavior-context-runtime context)
          :host-ref (plist-get props :ref)
          :properties (copy-sequence props))))

(defun etaf-behavior-create (name &rest attributes)
  "Create a Behavior spec named NAME from keyword ATTRIBUTES.

The reserved `:install' attribute is an optional zero-argument installer that
returns nil or a cleanup function; it is not merged into Host properties."
  (unless (and (symbolp name) (not (keywordp name)))
    (signal 'etaf-behavior-error
            (list (format "Behavior name must be a symbol: %S" name))))
  (unless (and (proper-list-p attributes)
               (zerop (% (length attributes) 2)))
    (signal 'etaf-behavior-error
            (list "Behavior attributes must be keyword/value pairs")))
  (let ((tail attributes)
        (semantic nil)
        install
        seen)
    (while tail
      (let ((key (pop tail)))
        (unless (keywordp key)
          (signal 'etaf-behavior-error
                  (list (format "Behavior attribute must be a keyword: %S"
                                key))))
        (when (memq key seen)
          (signal 'etaf-behavior-error
                  (list (format "Duplicate Behavior attribute: %S" key))))
        (push key seen)
        (let ((value (pop tail)))
          (if (eq key :install)
              (setq install value)
            (setq semantic (append semantic (list key value)))))))
    (when (and install (not (functionp install)))
      (signal 'etaf-behavior-error
              (list ":install must be a function or nil")))
    (etaf--behavior-spec-create :name name
                                :attributes semantic
                                :install install)))

(defmacro etaf-define-behavior (name arguments &rest body)
  "Define ordinary Behavior constructor NAME with ARGUMENTS and BODY.

The constructor must return `etaf-behavior-create' data.  This is a function
definition convenience, not a second runtime or visual node model."
  (declare (indent 2) (debug defun))
  (unless (symbolp name)
    (signal 'etaf-behavior-error (list "Behavior name must be a symbol")))
  `(defun ,name ,arguments
     ,(if (stringp (car body)) (pop body)
        (format "Construct the `%s' ETAF Behavior." name))
     ,@body))

;;;###autoload
(defun etaf-focusable (&rest attributes)
  "Return a focusable Behavior from ATTRIBUTES.

When ATTRIBUTES does not specify `:tab-index', the Behavior supplies the
standard first tab stop, zero.  An explicit nil excludes it from tab navigation."
  (unless (plist-member attributes :tab-index)
    (setq attributes (append attributes (list :tab-index 0))))
  (apply #'etaf-behavior-create 'focusable attributes))

;;;###autoload
(defun etaf-toggleable (&rest attributes)
  "Return a Behavior converting ATTRIBUTES into a toggleable press action.

`:value' and `:on-change' configure the action; all other attributes remain
part of the returned Behavior."
  (let ((value (plist-get attributes :value))
        (on-change (plist-get attributes :on-change)))
    (unless (functionp on-change)
      (signal 'etaf-behavior-error
              (list "toggleable requires a function-valued :on-change")))
    (let (remaining)
      (while attributes
        (let ((key (pop attributes))
              (item (pop attributes)))
          (unless (memq key '(:value :on-change))
            (setq remaining (append remaining (list key item))))))
      (apply #'etaf-behavior-create
             'toggleable
             (append remaining
                     (list :on-press
                           (lambda ()
                             (funcall
                              on-change
                              (not
                               (if (or (etaf-ref-p value)
                                       (etaf-computed-p value))
                                   (etaf-value value)
                                 value))))))))))

(defun etaf--geometry-ref (name value required-p)
  "Validate geometry reactive VALUE for NAME.
When REQUIRED-P is nil, VALUE may be nil.  Return VALUE unchanged."
  (when (or required-p value)
    (unless (etaf-ref-p value)
      (signal 'etaf-behavior-error
              (list (format "%s must be a writable `etaf-ref': %S"
                            name value)))))
  value)

(defun etaf--geometry-callback (name value)
  "Validate optional geometry callback VALUE for NAME and return it."
  (when (and value (not (functionp value)))
    (signal 'etaf-behavior-error
            (list (format "%s must be a function or nil: %S" name value))))
  value)

(defun etaf--geometry-number (name value)
  "Return numeric VALUE for NAME, or signal an ETAF Behavior error."
  (unless (numberp value)
    (signal 'etaf-behavior-error
            (list (format "%s must contain a number, got %S" name value))))
  value)

(defun etaf--geometry-delta (gesture transform)
  "Return numeric `(DX . DY)' from Ebox GESTURE and TRANSFORM."
  (let ((delta (if transform (funcall transform gesture)
                (plist-get gesture :delta))))
    (unless (and (consp delta) (numberp (car delta)) (numberp (cdr delta)))
      (signal 'etaf-behavior-error
              (list (format "Invalid Ebox gesture delta: %S" delta))))
    delta))

(defun etaf--geometry-clamp (value minimum maximum)
  "Clamp numeric VALUE to optional MINIMUM and MAXIMUM bounds."
  (max (or minimum value) (min (or maximum value) value)))

;;;###autoload
(cl-defun etaf-draggable
    (&key x y axis delta on-start on-move on-end on-cancel)
  "Return a reusable Behavior that moves caller-owned coordinate refs.

X and Y are writable `etaf-ref' objects containing numeric logical
coordinates.  The caller maps these values to Ebox geometry, for example by
wrapping each value in an Ebox px size form.  AXIS is nil (infer from supplied
refs), with symbols x, y, or both.  The Behavior consumes Ebox's `:on-drag'
gesture but owns no window, pointer, or layout state; each accepted motion
writes the supplied
refs and ETAF's normal reactive publication updates the Host incrementally.

DELTA is an optional function receiving the gesture and returning a numeric
DX/DY cons; use it when caller coordinates use units other than Ebox pixels.
ON-START, ON-MOVE, ON-END and ON-CANCEL are optional callbacks receiving the
original gesture plist.  Move and end callbacks run after the coordinate refs
are updated.  Cancellation does not change coordinates.  A missing coordinate
ref for the selected axis is an error."
  (let* ((axis (or axis
                   (cond ((and x y) 'both)
                         (x 'x)
                         (y 'y)
                         (t (signal 'etaf-behavior-error
                                   (list "etaf-draggable requires :x or :y"))))))
         (axis (if (eq axis 'both) 'both axis)))
    (unless (memq axis '(x y both))
      (signal 'etaf-behavior-error
              (list (format "Invalid draggable axis: %S" axis))))
    (etaf--geometry-ref ":x" x (memq axis '(x both)))
    (etaf--geometry-ref ":y" y (memq axis '(y both)))
    (when (and x y (eq x y))
      (signal 'etaf-behavior-error
              (list "etaf-draggable :x and :y must be distinct refs")))
    (mapc (lambda (entry)
            (etaf--geometry-callback (car entry) (cdr entry)))
          (list (cons ":on-start" on-start)
                (cons ":on-move" on-move)
                (cons ":on-end" on-end)
                (cons ":on-cancel" on-cancel)))
    (etaf--geometry-callback ":delta" delta)
    (let (origin)
      (apply #'etaf-behavior-create
             'draggable
             (list :keys (etaf--keys-move-bindings axis)
                   :on-drag
                   (lambda (gesture)
                     (pcase (plist-get gesture :phase)
                       ('start
                        (setq origin
                              (list :x (and x (etaf--geometry-number
                                              ":x" (etaf-value x)))
                                    :y (and y (etaf--geometry-number
                                              ":y" (etaf-value y)))))
                        (when on-start (funcall on-start gesture)))
                       ((or 'move 'end)
                        (when origin
                          (let ((delta (etaf--geometry-delta gesture delta)))
                            (when (memq axis '(x both))
                              (setf (etaf-value x)
                                    (+ (plist-get origin :x) (car delta))))
                            (when (memq axis '(y both))
                              (setf (etaf-value y)
                                    (+ (plist-get origin :y) (cdr delta))))))
                        (when (and (eq (plist-get gesture :phase) 'move)
                                   on-move)
                          (funcall on-move gesture))
                        (when (and (eq (plist-get gesture :phase) 'end)
                                   on-end)
                          (funcall on-end gesture)
                          (setq origin nil)))
                       ('cancel
                        (setq origin nil)
                        (when on-cancel (funcall on-cancel gesture)))))))))
      )

;;;###autoload
(cl-defun etaf-resizable
    (&key x y width height edges min-width max-width min-height max-height
          delta on-start on-resize on-end on-cancel)
  "Return a reusable Behavior that resizes caller-owned geometry refs.

WIDTH and HEIGHT are writable `etaf-ref' objects containing numeric logical
sizes.  X and Y are optional writable coordinate refs required by left and top
edges.  EDGES is one symbol or a list containing left, right, top and bottom;
it defaults to right and bottom.  A left/top resize keeps
the opposite edge fixed by moving X/Y as the size changes.  Optional minimum
and maximum bounds are numeric and are applied before refs are published.

The caller maps the logical refs to Ebox size properties.  DELTA optionally
converts the Ebox gesture to the caller's units and receives the gesture plist.
Ebox owns the gesture loop and ETAF's normal reactive publication performs the
incremental render.  ON-START, ON-RESIZE,
ON-END and ON-CANCEL receive the original gesture plist; resize and end run
after the refs are updated.  Cancellation leaves the last accepted geometry
unchanged."
  (let* ((edges (cond ((null edges) (list 'right 'bottom))
                           ((symbolp edges) (list edges))
                           (t edges)))
         (edges (copy-sequence edges)))
    (unless (and (proper-list-p edges) edges
                 (cl-every (lambda (edge) (memq edge '(left right top bottom)))
                           edges)
                 (= (length edges) (length (delete-dups (copy-sequence edges)))))
      (signal 'etaf-behavior-error
              (list (format "Invalid resizable edges: %S" edges))))
    (etaf--geometry-ref ":x" x (memq 'left edges))
    (etaf--geometry-ref ":y" y (memq 'top edges))
    (etaf--geometry-ref ":width" width (cl-some (lambda (edge)
                                                   (memq edge '(left right)))
                                                 edges))
    (etaf--geometry-ref ":height" height (cl-some (lambda (edge)
                                                    (memq edge '(top bottom)))
                                                  edges))
    (dolist (entry `((:min-width . ,min-width) (:max-width . ,max-width)
                     (:min-height . ,min-height) (:max-height . ,max-height)))
      (when (and (cdr entry) (not (numberp (cdr entry))))
        (signal 'etaf-behavior-error
                (list (format "%s must be numeric or nil: %S"
                              (car entry) (cdr entry))))))
    (when (and min-width max-width (> min-width max-width))
      (signal 'etaf-behavior-error
              (list "etaf-resizable :min-width exceeds :max-width")))
    (when (and min-height max-height (> min-height max-height))
      (signal 'etaf-behavior-error
              (list "etaf-resizable :min-height exceeds :max-height")))
    (mapc (lambda (entry)
            (etaf--geometry-callback (car entry) (cdr entry)))
          (list (cons ":on-start" on-start)
                (cons ":on-resize" on-resize)
                (cons ":on-end" on-end)
                (cons ":on-cancel" on-cancel)))
    (etaf--geometry-callback ":delta" delta)
    (let (origin)
      (apply #'etaf-behavior-create
             'resizable
             (list :keys (etaf--keys-resize-bindings edges)
                   :on-drag
                   (lambda (gesture)
                     (pcase (plist-get gesture :phase)
                       ('start
                        (setq origin
                              (list :x (and x (etaf--geometry-number
                                              ":x" (etaf-value x)))
                                    :y (and y (etaf--geometry-number
                                              ":y" (etaf-value y)))
                                    :width (and width
                                                (etaf--geometry-number
                                                 ":width" (etaf-value width)))
                                    :height (and height
                                                 (etaf--geometry-number
                                                  ":height" (etaf-value height)))))
                        (when on-start (funcall on-start gesture)))
                       ((or 'move 'end)
                        (when origin
                          (let* ((delta (etaf--geometry-delta gesture delta))
                                 (dx (car delta))
                                 (dy (cdr delta))
                                 (left-p (memq 'left edges))
                                 (right-p (memq 'right edges))
                                 (top-p (memq 'top edges))
                                 (bottom-p (memq 'bottom edges))
                                 (new-width
                                  (and width
                                       (etaf--geometry-clamp
                                        (+ (plist-get origin :width)
                                           (if left-p (- dx) (if right-p dx 0)))
                                        min-width max-width)))
                                 (new-height
                                  (and height
                                       (etaf--geometry-clamp
                                        (+ (plist-get origin :height)
                                           (if top-p (- dy) (if bottom-p dy 0)))
                                        min-height max-height)))
                                 (new-x (and x
                                              (if left-p
                                                  (+ (plist-get origin :x)
                                                     (- (plist-get origin :width)
                                                        new-width))
                                                (plist-get origin :x))))
                                 (new-y (and y
                                              (if top-p
                                                  (+ (plist-get origin :y)
                                                     (- (plist-get origin :height)
                                                        new-height))
                                                (plist-get origin :y)))))
                            (when x (setf (etaf-value x) new-x))
                            (when y (setf (etaf-value y) new-y))
                            (when width (setf (etaf-value width) new-width))
                            (when height (setf (etaf-value height) new-height))))
                        (when (and (eq (plist-get gesture :phase) 'move)
                                   on-resize)
                          (funcall on-resize gesture))
                        (when (and (eq (plist-get gesture :phase) 'end)
                                   on-end)
                          (funcall on-end gesture)
                          (setq origin nil)))
                       ('cancel
                        (setq origin nil)
                        (when on-cancel (funcall on-cancel gesture)))))))))
      )

(provide 'etaf-behavior)

;;; etaf-behavior.el ends here
