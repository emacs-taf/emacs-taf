;;; ebox-style.el --- CSS-like style model for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the Ebox property schema registered with ECSS: names, aliases,
;; initial values, inheritance, validators and shorthand expansion.  It
;; compiles author declarations and rules once and creates shared scopes.
;; Computed styles and their layout projection live in ebox-node.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ecss)
(require 'ebox-size)

(defconst ebox-style--border-styles
  '(none solid)
  "Valid CSS border-style keywords accepted by Ebox style parsing.")

(defconst ebox-style--default-foreground 'ebox/default-foreground
  "Internal paint consequence that blocks an inherited foreground.")

(defconst ebox-style--property-definitions
  '((:name :color :id ebox/color :initial nil :inherits t
     :contexts (text box) :group paint :dirty-kind paint :signature paint
     :normalizer color :validator color)
    (:name :background-color :id ebox/background-color :aliases (:bgcolor)
     :initial nil :contexts (text box) :group paint :dirty-kind paint
     :signature paint :normalizer color :validator color)
    (:name :backdrop-filter :id ebox/backdrop-filter
     :initial nil :contexts (box row column flex grid) :group paint
     :dirty-kind paint :signature paint :validator backdrop-filter)
    (:name :font-family :id ebox/font-family :initial nil :inherits t
     :contexts (text box) :group typography :dirty-kind geometry :signature layout
     :validator font-family)
    (:name :font-size :id ebox/font-size
     :initial nil :inherits t :contexts (text box) :group typography
     :dirty-kind geometry :signature layout :validator font-size)
    (:name :font-weight :id ebox/font-weight :initial normal :inherits t
     :contexts (text box) :group typography :dirty-kind geometry :signature layout
     :validator font-weight)
    (:name :font-style :id ebox/font-style :aliases (:font-slant)
     :initial normal :inherits t
     :contexts (text box) :group typography :dirty-kind geometry :signature layout
     :validator font-style)
    (:name :text-decoration-line :id ebox/text-decoration-line :initial none
     :contexts (text box) :group paint :dirty-kind paint :signature paint
     :validator text-decoration-line)
    (:name :text-decoration-color :id ebox/text-decoration-color
     :initial currentColor :contexts (text box) :group paint :dirty-kind paint
     :signature paint :normalizer color :validator color)
    (:name :text-decoration-style :id ebox/text-decoration-style :initial solid
     :contexts (text box) :group paint :dirty-kind paint :signature paint
     :validator text-decoration-style)
    (:name :box-sizing :id ebox/box-sizing :initial border-box
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout)
    (:name :position :id ebox/position :initial static
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator position
     :runtime-default t)
    (:name :left :id ebox/left :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator signed-size :runtime-default t)
    (:name :top :id ebox/top :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator signed-size :runtime-default t)
    (:name :z-index :id ebox/z-index :initial 0
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator integer
     :runtime-default t)
    (:name :layer :id ebox/layer :initial local
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator layer
     :runtime-default t)
    (:name :anchor :id ebox/anchor :initial nil
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator anchor
     :runtime-default t)
    (:name :placement :id ebox/placement :initial bottom-start
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator placement
     :runtime-default t)
    (:name :width :id ebox/width :initial auto
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator horizontal-size)
    (:name :min-width :id ebox/min-width :initial auto
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator min-horizontal-size)
    (:name :max-width :id ebox/max-width :initial none
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator max-horizontal-size)
    (:name :height :id ebox/height :initial auto
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator vertical-size)
    (:name :min-height :id ebox/min-height :initial auto
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator min-vertical-size)
    (:name :max-height :id ebox/max-height :initial none
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator max-vertical-size)
    (:name :padding-top :id ebox/padding-top :initial (lh 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :padding-right :id ebox/padding-right :initial (px 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size)
    (:name :padding-bottom :id ebox/padding-bottom :initial (lh 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :padding-left :id ebox/padding-left :initial (px 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size)
    (:name :padding-block-start :id ebox/padding-block-start :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :padding-inline-end :id ebox/padding-inline-end :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size)
    (:name :padding-block-end :id ebox/padding-block-end :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :padding-inline-start :id ebox/padding-inline-start :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size)
    (:name :margin-top :id ebox/margin-top :initial (lh 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :margin-right :id ebox/margin-right :initial (px 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size)
    (:name :margin-bottom :id ebox/margin-bottom :initial (lh 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :margin-left :id ebox/margin-left :initial (px 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size)
    (:name :margin-block-start :id ebox/margin-block-start :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :margin-inline-end :id ebox/margin-inline-end :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size)
    (:name :margin-block-end :id ebox/margin-block-end :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :margin-inline-start :id ebox/margin-inline-start :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size)
    (:name :border-top-width :id ebox/border-top-width
     :initial (px 0) :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis stroke :validator border-width)
    (:name :border-right-width :id ebox/border-right-width
     :initial (px 0) :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis stroke :validator border-width)
    (:name :border-bottom-width :id ebox/border-bottom-width
     :initial (px 0) :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis stroke :validator border-width)
    (:name :border-left-width :id ebox/border-left-width
     :initial (px 0) :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis stroke :validator border-width)
    (:name :border-top-style :id ebox/border-top-style :initial none
     :contexts (box row column flex grid) :group structure
     :dirty-kind structure :signature layout :validator border-style)
    (:name :border-right-style :id ebox/border-right-style :initial none
     :contexts (box row column flex grid) :group structure
     :dirty-kind structure :signature layout :validator border-style)
    (:name :border-bottom-style :id ebox/border-bottom-style :initial none
     :contexts (box row column flex grid) :group structure
     :dirty-kind structure :signature layout :validator border-style)
    (:name :border-left-style :id ebox/border-left-style :initial none
     :contexts (box row column flex grid) :group structure
     :dirty-kind structure :signature layout :validator border-style)
    (:name :border-top-color :id ebox/border-top-color :initial currentColor
     :contexts (box row column flex grid) :group paint
     :dirty-kind paint :signature paint
     :normalizer color :validator color)
    (:name :border-right-color :id ebox/border-right-color :initial currentColor
     :contexts (box row column flex grid) :group paint
     :dirty-kind paint :signature paint
     :normalizer color :validator color)
    (:name :border-bottom-color :id ebox/border-bottom-color
     :initial currentColor :contexts (box row column flex grid)
     :group paint :dirty-kind paint :signature paint
     :normalizer color :validator color)
    (:name :border-left-color :id ebox/border-left-color :initial currentColor
     :contexts (box row column flex grid) :group paint
     :dirty-kind paint :signature paint
     :normalizer color :validator color)
    (:name :border-radius :id ebox/border-radius :initial (px 0)
     :contexts (box row column flex grid) :group paint
     :dirty-kind paint :signature paint
     :size-axis inline :validator nonnegative-size)
    (:name :text-align :id ebox/text-align :initial left :inherits t
     :contexts (box)
     :author-contexts (box)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :overflow :id ebox/overflow :initial scroll
     :contexts (box row column flex grid) :group structure
     :dirty-kind geometry :signature layout
     :impacts (geometry paint) :projections (layout paint))
    (:name :scroll-anchor :id ebox/scroll-anchor :initial start
     :contexts (box row column flex grid) :group structure
     :dirty-kind geometry :signature layout
     :validator scroll-anchor)
    (:name :wrap-mode :id ebox/wrap-mode :initial word :inherits t
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :validator wrap-mode)
    ;; A hidden box suppresses the ink of its whole subtree at paint time
    ;; and focus checks every ancestor, so descendants never consult an
    ;; inherited value; keeping it out of the cascade lets a visibility
    ;; change publish without recomputing descendant styles.
    (:name :visibility :id ebox/visibility :initial visible
     :contexts (box row column flex grid)
     :group paint :dirty-kind paint :signature paint)
    (:name :outer :id ebox/outer :initial block
     :contexts (box row column flex grid)
     :group structure :dirty-kind structure :signature structure
     :validator outer :impacts (structure geometry)
     :projections (structure layout))
    (:name :item-gap :id ebox/item-gap :initial (px 0) :contexts (row column)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis main :validator nonnegative-size)
    (:name :cross-align :id ebox/cross-align :initial stretch
     :contexts (row column) :group geometry :dirty-kind geometry
     :signature layout :validator cross-align)
    (:name :flex-direction :id ebox/flex-direction :initial row
     :contexts (flex) :group geometry :dirty-kind geometry :signature layout
     :validator flex-direction)
    (:name :flex-wrap :id ebox/flex-wrap :initial nowrap :contexts (flex)
     :group geometry :dirty-kind geometry :signature layout
     :validator flex-wrap)
    (:name :justify-content :id ebox/justify-content :initial flex-start
     :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :validator justify-content)
    (:name :align-items :id ebox/align-items :initial stretch
     :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :validator align-items)
    (:name :align-content :id ebox/align-content :initial stretch
     :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :validator align-content)
    (:name :justify-items :id ebox/justify-items :initial stretch
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :validator justify-items)
    (:name :row-gap :id ebox/row-gap :initial (lh 0)
     :contexts (flex grid) :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :column-gap :id ebox/column-gap
     :initial (px 0) :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :size-axis inline :validator nonnegative-size)
    (:name :order :id ebox/order :initial 0 :contexts (item)
     :group geometry :dirty-kind geometry :signature layout :validator order)
    (:name :flex-grow :id ebox/flex-grow :initial 0 :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator flex-factor)
    (:name :flex-shrink :id ebox/flex-shrink :initial 1 :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator flex-factor)
    (:name :flex-basis :id ebox/flex-basis :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis length :validator preferred-size)
    (:name :align-self :id ebox/align-self :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator align-self)
    (:name :justify-self :id ebox/justify-self :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator justify-self)
    (:name :grid-template-columns :id ebox/grid-template-columns :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :size-grammar tracks :size-axis inline :validator grid-track-list)
    (:name :grid-template-rows :id ebox/grid-template-rows :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :size-grammar tracks :size-axis block :validator grid-track-list)
    (:name :grid-auto-columns :id ebox/grid-auto-columns :initial auto
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :size-grammar tracks :size-axis inline :validator grid-track)
    (:name :grid-auto-rows :id ebox/grid-auto-rows :initial auto
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :size-grammar tracks :size-axis block :validator grid-track)
    (:name :grid-auto-flow :id ebox/grid-auto-flow :initial row
     :contexts (grid) :group structure :dirty-kind structure :signature layout
     :validator grid-auto-flow)
    (:name :grid-column :id ebox/grid-column :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator grid-placement)
    (:name :grid-row :id ebox/grid-row :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator grid-placement)
    (:name :grid-column-span :id ebox/grid-column-span
     :shorthand grid-column-span :validator positive-integer
     :contexts (item) :group geometry :dirty-kind geometry :signature layout)
    (:name :grid-row-span :id ebox/grid-row-span
     :shorthand grid-row-span :validator positive-integer
     :contexts (item) :group geometry :dirty-kind geometry :signature layout)
    (:name :padding :id ebox/padding :shorthand padding
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint))
    (:name :padding-inline :id ebox/padding-inline :shorthand padding-inline
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint))
    (:name :padding-block :id ebox/padding-block :shorthand padding-block
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint))
    (:name :margin :id ebox/margin :shorthand margin
     :contexts (box row column flex grid)
     :impacts (geometry) :projections (layout))
    (:name :margin-inline :id ebox/margin-inline :shorthand margin-inline
     :contexts (box row column flex grid)
     :impacts (geometry) :projections (layout))
    (:name :margin-block :id ebox/margin-block :shorthand margin-block
     :contexts (box row column flex grid)
     :impacts (geometry) :projections (layout))
    (:name :border :id ebox/border :shorthand border
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint))
    (:name :border-top :id ebox/border-top :shorthand border-top
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint))
    (:name :border-right :id ebox/border-right :shorthand border-right
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint))
    (:name :border-bottom :id ebox/border-bottom :shorthand border-bottom
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint))
    (:name :border-left :id ebox/border-left :shorthand border-left
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint))
    (:name :border-top-p :id ebox/border-top-p
     :shorthand border-top-present :validator boolean
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :group structure :dirty-kind structure :signature layout)
    (:name :border-width :id ebox/border-width :shorthand border-width
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :border-style :id ebox/border-style :shorthand border-style
     :contexts (box row column flex grid)
     :group structure :dirty-kind structure :signature layout)
    (:name :border-color :id ebox/border-color :shorthand border-color
     :contexts (box row column flex grid)
     :group paint :dirty-kind paint :signature paint)
    (:name :gap :id ebox/gap :shorthand gap
     :contexts (flex grid)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :flex-flow :id ebox/flex-flow :shorthand flex-flow
     :contexts (flex)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :flex :id ebox/flex :shorthand flex
     :contexts (item)
     :group geometry :dirty-kind geometry :signature layout))
  "Canonical Ebox property schemas and public aliases.")

(define-error 'ebox-style-schema-error "Invalid Ebox style schema")

(defun ebox-style--definition-for-name (name &optional definitions)
  "Return NAME's canonical entry from DEFINITIONS or the package definitions."
  (cl-find-if
   (lambda (property)
     (or (eq name (plist-get property :name))
         (eq name (plist-get property :id))
         (memq name (plist-get property :aliases))))
   (or definitions ebox-style--property-definitions)))

(defvar ebox-style-schemas)
(defvar ebox-style--property-index)

(defconst ebox-style--declaration-cache-max-entries 512
  "Maximum canonical declaration compilations retained by Ebox.")

(defvar ebox-style--declaration-cache
  (make-hash-table :test 'equal)
  "Bounded memo table for canonical Ebox declaration compilation.")

(defun ebox-style--property (name)
  "Return registry-owned style metadata for internal NAME lookup."
  (gethash name ebox-style--property-index))

(defun ebox-style-property (name)
  "Return detached style metadata for canonical property or alias NAME."
  (ecss-schema-set-property-metadata ebox-style-schemas name))

(defun ebox-style-canonical-name (name)
  "Return canonical CSS-like longhand property name for NAME."
  (when-let* ((property (ebox-style--property name)))
    (plist-get property :name)))

(defun ebox-style-property-accepted-p (tag name)
  "Return non-nil when author form TAG accepts property NAME."
  (when-let* ((property (ebox-style--property name)))
    (ebox-style--form-property-allowed-p tag property)))

(defun ebox-style-schema-id (name)
  "Return namespaced ECSS schema id for Ebox property NAME."
  (when-let* ((property (ebox-style--property name)))
    (plist-get property :id)))

(defun ebox-style--put (plist key value)
  "Return PLIST with KEY set to VALUE."
  (plist-put plist key value))

(defun ebox-style--atomic-size-form-p (value)
  "Return non-nil when VALUE denotes one size expression before validation.
Keep malformed unit and function forms intact so their target property reports
the invalid value and its allowed units instead of a shorthand arity error."
  (and (consp value)
       (memq (car value) '(px ch vw lh vh % calc min max clamp))))

(defun ebox-style--split-trbl (value)
  "Split VALUE using CSS TRBL rules into top, right, bottom, left."
  (cond
   ((null value) (list nil nil nil nil))
   ((ebox-style--atomic-size-form-p value) (make-list 4 value))
   ((atom value) (list value value value value))
   ((and (listp value) (keywordp (car value)))
    (list (plist-get value :top) (plist-get value :right)
          (plist-get value :bottom) (plist-get value :left)))
   ((listp value)
    (pcase (length value)
      (1 (list (nth 0 value) (nth 0 value) (nth 0 value) (nth 0 value)))
      (2 (list (nth 0 value) (nth 1 value) (nth 0 value) (nth 1 value)))
      (3 (list (nth 0 value) (nth 1 value) (nth 2 value) (nth 1 value)))
      (4 (list (nth 0 value) (nth 1 value) (nth 2 value) (nth 3 value)))
      (_ (error "Ebox four-side shorthand requires one to four values: %S"
                value))))
   (t (list value value value value))))

(defun ebox-style--split-pair (value)
  "Split VALUE into a start/end pair."
  (cond
   ((null value) (list nil nil))
   ((ebox-style--atomic-size-form-p value) (list value value))
   ((atom value) (list value value))
   ((listp value)
    (pcase (length value)
      (1 (list (nth 0 value) (nth 0 value)))
      (2 (list (nth 0 value) (nth 1 value)))
      (_ (error "Ebox pair shorthand requires one or two values: %S" value))))
   (t (list value value))))

(defun ebox-style--wsc-classify (item)
  "Classify border shorthand ITEM as width, style, or color."
  (cond
   ((ebox-style--atomic-size-form-p item) (cons 'width item))
   ((memq item ebox-style--border-styles) (cons 'style item))
   ((stringp item) (cons 'color item))
   (t (error "Invalid Ebox border component: %S" item))))

(defun ebox-style--split-wsc (value)
  "Split VALUE into border width, style, and color."
  (cond
   ((null value) (list nil nil nil))
   ((ebox-style--atomic-size-form-p value) (list value 'solid nil))
   ((atom value)
    (let ((classified (ebox-style--wsc-classify value)))
      (pcase (car classified)
        ('width (list (cdr classified) nil nil))
        ('style (list '(px 1) (cdr classified) nil))
        ('color (list '(px 1) 'solid (cdr classified))))))
   ((proper-list-p value)
    (let (width style color width-p style-p color-p)
      (dolist (item value)
        (let ((classified (ebox-style--wsc-classify item)))
          (pcase (car classified)
            ('width
             (when width-p (error "Duplicate Ebox border width in %S" value))
             (setq width-p t width (cdr classified)))
            ('style
             (when style-p (error "Duplicate Ebox border style in %S" value))
             (setq style-p t style (cdr classified)))
            ('color
             (when color-p (error "Duplicate Ebox border color in %S" value))
             (setq color-p t color (cdr classified))))))
      (list (or width '(px 1)) (or style 'solid) color)))
   (t (error "Ebox border must be a color or proper component list: %S"
             value))))

(defun ebox-style--atom-consp (list)
  "Return non-nil when LIST is a strict dotted pair of atoms."
  (and (consp list)
       (atom (car list))
       (cdr list)
       (atom (cdr list))))

(defun ebox-style--parse-color (color)
  "Return a detached canonical COLOR value without consulting a frame."
  (if (stringp color) (copy-sequence color) color))

(defun ebox-style--trbl-declarations (properties value)
  "Expand VALUE across four namespaced PROPERTIES."
  (cl-loop for property in properties
           for part in (ebox-style--split-trbl value)
           append (list property part)))

(defun ebox-style--pair-declarations (properties value)
  "Expand VALUE across two namespaced PROPERTIES."
  (cl-loop for property in properties
           for part in (ebox-style--split-pair value)
           append (list property part)))

(defun ebox-style--padding-shorthand (value)
  "Expand padding VALUE to namespaced logical longhands."
  (ebox-style--trbl-declarations
   '(ebox/padding-block-start ebox/padding-inline-end
     ebox/padding-block-end ebox/padding-inline-start)
   value))

(defun ebox-style--padding-inline-shorthand (value)
  "Expand inline padding VALUE to namespaced longhands."
  (ebox-style--pair-declarations
   '(ebox/padding-inline-start ebox/padding-inline-end) value))

(defun ebox-style--padding-block-shorthand (value)
  "Expand block padding VALUE to namespaced longhands."
  (ebox-style--pair-declarations
   '(ebox/padding-block-start ebox/padding-block-end) value))

(defun ebox-style--margin-shorthand (value)
  "Expand margin VALUE to namespaced logical longhands."
  (ebox-style--trbl-declarations
   '(ebox/margin-block-start ebox/margin-inline-end
     ebox/margin-block-end ebox/margin-inline-start)
   value))

(defun ebox-style--margin-inline-shorthand (value)
  "Expand inline margin VALUE to namespaced longhands."
  (ebox-style--pair-declarations
   '(ebox/margin-inline-start ebox/margin-inline-end) value))

(defun ebox-style--margin-block-shorthand (value)
  "Expand block margin VALUE to namespaced longhands."
  (ebox-style--pair-declarations
   '(ebox/margin-block-start ebox/margin-block-end) value))

(defconst ebox-style--border-sides '(top right bottom left)
  "Physical border sides in CSS shorthand order.")

(defun ebox-style--border-side-declarations (side value)
  "Expand border VALUE for SIDE to three namespaced longhands."
  (pcase-let ((`(,width ,style ,color) (ebox-style--split-wsc value)))
    (list (intern (format "ebox/border-%s-width" side)) width
          (intern (format "ebox/border-%s-style" side)) style
          (intern (format "ebox/border-%s-color" side)) color)))

(defun ebox-style--border-shorthand (value)
  "Expand border VALUE directly to all namespaced side longhands."
  (cl-mapcan (lambda (side)
               (ebox-style--border-side-declarations side value))
             ebox-style--border-sides))

(defun ebox-style--border-top-shorthand (value)
  "Expand top border VALUE to namespaced longhands."
  (ebox-style--border-side-declarations 'top value))

(defun ebox-style--border-right-shorthand (value)
  "Expand right border VALUE to namespaced longhands."
  (ebox-style--border-side-declarations 'right value))

(defun ebox-style--border-bottom-shorthand (value)
  "Expand bottom border VALUE to namespaced longhands."
  (ebox-style--border-side-declarations 'bottom value))

(defun ebox-style--border-left-shorthand (value)
  "Expand left border VALUE to namespaced longhands."
  (ebox-style--border-side-declarations 'left value))

(defun ebox-style--border-present-declarations (side value)
  "Return canonical boolean border declarations for SIDE and VALUE."
  (unless (memq value '(nil t))
    (error "Ebox border-%s-p must be boolean: %S" side value))
  (list (intern (format "ebox/border-%s-width" side))
        (list 'px (if value 1 0))
        (intern (format "ebox/border-%s-style" side))
        (if value 'solid 'none)))

(defun ebox-style--border-top-present-shorthand (value)
  "Expand boolean top-border VALUE to canonical width and style."
  (ebox-style--border-present-declarations 'top value))

(defun ebox-style--border-component-shorthand (component value)
  "Expand border COMPONENT VALUE across all physical sides."
  (ebox-style--trbl-declarations
   (mapcar (lambda (side)
             (intern (format "ebox/border-%s-%s" side component)))
           ebox-style--border-sides)
   value))

(defun ebox-style--border-width-shorthand (value)
  "Expand border width VALUE across all physical sides."
  (ebox-style--border-component-shorthand 'width value))

(defun ebox-style--border-style-shorthand (value)
  "Expand border style VALUE across all physical sides."
  (ebox-style--border-component-shorthand 'style value))

(defun ebox-style--border-color-shorthand (value)
  "Expand border color VALUE across all physical sides."
  (ebox-style--border-component-shorthand 'color value))

(defun ebox-style--gap-shorthand (value)
  "Expand gap VALUE to row and column gaps."
  (ebox-style--pair-declarations '(ebox/row-gap ebox/column-gap) value))

(defun ebox-style--grid-column-span-shorthand (value)
  "Expand Grid column span VALUE into canonical auto placement."
  (unless (and (integerp value) (> value 0))
    (error "Ebox grid-column-span must be a positive integer: %S" value))
  (list 'ebox/grid-column (list :span value)))

(defun ebox-style--grid-row-span-shorthand (value)
  "Expand Grid row span VALUE into canonical auto placement."
  (unless (and (integerp value) (> value 0))
    (error "Ebox grid-row-span must be a positive integer: %S" value))
  (list 'ebox/grid-row (list :span value)))

(defun ebox-style--flex-flow-shorthand (value)
  "Expand flex-flow VALUE to direction and wrapping longhands."
  (unless (and (proper-list-p value) (= (length value) 2))
    (error "Ebox flex-flow requires one direction and one wrap value: %S"
           value))
  (let ((values value) direction wrap)
    (setq direction
          (cl-find-if (lambda (item)
                        (memq item '(row row-reverse column column-reverse)))
                      values)
          wrap (cl-find-if (lambda (item)
                             (memq item '(nowrap wrap wrap-reverse)))
                           values))
    (unless (and direction wrap)
      (error "Ebox flex-flow requires one direction and one wrap value: %S"
             value))
    (list 'ebox/flex-direction direction 'ebox/flex-wrap wrap)))

(defun ebox-style--flex-shorthand (value)
  "Expand flex item VALUE to grow, shrink, and basis longhands."
  (pcase value
    ((and (pred numberp) (guard (>= value 0)))
     (list 'ebox/flex-grow value 'ebox/flex-shrink 1
           'ebox/flex-basis '(% 0)))
    ('none '(ebox/flex-grow 0 ebox/flex-shrink 0 ebox/flex-basis auto))
    ('auto '(ebox/flex-grow 1 ebox/flex-shrink 1 ebox/flex-basis auto))
    ('initial '(ebox/flex-grow 0 ebox/flex-shrink 1 ebox/flex-basis auto))
    ((and (pred proper-list-p) (guard (= (length value) 3)))
     (list 'ebox/flex-grow (nth 0 value)
           'ebox/flex-shrink (nth 1 value)
           'ebox/flex-basis (nth 2 value)))
    (_ (error "Ebox flex requires none, auto, initial, a factor, or (grow shrink basis): %S"
              value))))

(defun ebox-style--normalizer (name)
  "Return schema normalizer named NAME."
  (pcase name
    ('color #'ebox-style--parse-color)
    (_ #'identity)))

(defun ebox-style--negative-numeric-size-p (value)
  "Return non-nil when VALUE is or starts with a negative number."
  (or (and (numberp value) (< value 0))
      (and (consp value)
           (numberp (car value))
           (< (car value) 0))))

(defun ebox-style--nonnegative-size-p (value)
  "Return non-nil when VALUE is a canonical nonnegative length-percentage."
  (ebox-size-value-p value nil t))

(defconst ebox-style--preferred-size-keywords
  '(auto min-content max-content fit-content stretch)
  "CSS preferred and minimum size keywords in the supported subset.")

(defconst ebox-style--maximum-size-keywords
  '(none min-content max-content fit-content stretch)
  "CSS maximum size keywords in the supported subset.")

(defun ebox-style--horizontal-size-p (value)
  "Return non-nil when VALUE is a canonical horizontal size."
  (or (memq value ebox-style--preferred-size-keywords)
      (ebox-size-value-for-axis-p value 'inline)))

(defun ebox-style--preferred-size-p (value)
  "Return non-nil when VALUE is a size whose parent axis is not known yet."
  (or (memq value ebox-style--preferred-size-keywords)
      (ebox-style--nonnegative-size-p value)))

(defun ebox-style--min-horizontal-size-p (value)
  "Return non-nil when VALUE is a canonical minimum horizontal size."
  (ebox-style--horizontal-size-p value))

(defun ebox-style--max-horizontal-size-p (value)
  "Return non-nil when VALUE is a canonical maximum horizontal size."
  (or (memq value ebox-style--maximum-size-keywords)
      (ebox-size-value-for-axis-p value 'inline)))

(defun ebox-style--vertical-size-p (value)
  "Return non-nil when VALUE is a canonical vertical size."
  (or (memq value ebox-style--preferred-size-keywords)
      (ebox-size-value-for-axis-p value 'block)))

(defun ebox-style--min-vertical-size-p (value)
  "Return non-nil when VALUE is a canonical minimum vertical size."
  (ebox-style--vertical-size-p value))

(defun ebox-style--max-vertical-size-p (value)
  "Return non-nil when VALUE is a canonical maximum vertical size."
  (or (memq value ebox-style--maximum-size-keywords)
      (ebox-size-value-for-axis-p value 'block)))

(defun ebox-style--nonnegative-number-p (value)
  "Return non-nil when VALUE is nil or a non-negative number."
  (or (null value) (and (numberp value) (>= value 0))))

(defun ebox-style--positive-integer-p (value)
  "Return non-nil when VALUE is nil or a positive integer."
  (or (null value) (and (integerp value) (> value 0))))

(defun ebox-style--grid-placement-p (value)
  "Return non-nil when VALUE is a valid public Grid placement."
  (or (null value)
      (eq value 'auto)
      (and (integerp value) (> value 0))
      (and (proper-list-p value)
           (pcase value
             (`(,start)
              (and (integerp start) (> start 0)))
             (`(,start :span ,span)
              (and (integerp start) (> start 0)
                   (integerp span) (> span 0)))
             (`(:span ,span)
              (and (integerp span) (> span 0)))
             (`(,start ,end)
              (and (integerp start) (> start 0)
                   (integerp end) (> end start)))))))

(defun ebox-style--outer-p (value)
  "Return non-nil when VALUE is an Ebox outer participation value."
  (memq value '(inline block)))

(defun ebox-style--signed-size-p (value &optional axis)
  "Return non-nil when VALUE is a signed typed length in size AXIS.
Leave fractional and contextual lengths unresolved until used placement."
  (and (ebox-size-value-p value t)
       (let ((units (cdr (assq (or axis 'length) ebox-size-axis-units))))
         (cl-labels ((valid-p (expression)
                       (or (atom expression)
                           (if (memq (car expression) '(px ch vw lh vh %))
                               (memq (car expression) units)
                             (cl-every #'valid-p (cdr expression))))))
           (valid-p value)))))

(defun ebox-style--position-p (value)
  "Return non-nil when VALUE is a supported positioning mode."
  (memq value '(static relative absolute)))

(defun ebox-style--layer-p (value)
  "Return non-nil when VALUE is a supported layer paint target."
  (memq value '(local root)))

(defun ebox-style--anchor-p (value)
  "Return non-nil when VALUE is nil or a semantic symbol or string id."
  (or (symbolp value) (stringp value)))

(defun ebox-style--placement-p (value)
  "Return non-nil when VALUE is a supported overlay placement."
  (memq value '(bottom-start bottom-end top-start top-end center)))

(defun ebox-style--font-family-p (value)
  "Return non-nil when VALUE is an Ebox font family."
  (or (null value)
      (and (stringp value) (not (string-empty-p value)))
      (symbolp value)))

(defun ebox-style--color-p (value)
  "Return non-nil when VALUE is a canonical color fact."
  (or (null value) (stringp value) (eq value 'currentColor)))

(defun ebox-style--backdrop-filter-p (value)
  "Return non-nil when VALUE is a supported backdrop filter list.
The supported subset is one `(brightness AMOUNT)' filter, where AMOUNT is a
non-negative number; values below 1 dim the cells behind the overlay."
  (or (null value)
      (and (proper-list-p value)
           (eq (car value) 'brightness)
           (numberp (cadr value))
           (>= (cadr value) 0)
           (null (cddr value)))))

(defun ebox-style--font-size-p (value)
  "Return non-nil when VALUE is a body-relative size ratio.
The ratio is what makes every size follow the reader's default font: 1 is the
body size, 1.42 a heading, 0.85 a caption.  A value outside 0.3 to 4 is a
pixel size left over from the older absolute API, which would multiply the
whole interface."
  (or (null value)
      (and (numberp value) (<= 0.3 value) (<= value 4))))

(defun ebox-style--font-weight-p (value)
  "Return non-nil when VALUE is a canonical CSS font weight."
  (or (null value)
      (memq value '(normal bold bolder lighter
                    100 200 300 400 500 600 700 800 900))))

(defun ebox-style--font-style-p (value)
  "Return non-nil when VALUE is a canonical CSS font style."
  (or (null value) (memq value '(normal italic oblique))))

(defun ebox-style--border-width-p (value)
  "Return non-nil when VALUE is a nonnegative length without percentages."
  (ebox-size-value-p value nil nil))

(defun ebox-style--border-style-p (value)
  "Return non-nil when VALUE is a supported canonical border style."
  (memq value '(none solid)))

(defun ebox-style--text-decoration-line-p (value)
  "Return non-nil when VALUE is a canonical text-decoration line set."
  (let ((values (if (listp value) value (list value))))
    (or (equal values '(none))
        (and values
             (cl-every (lambda (item)
                         (memq item '(underline overline line-through)))
                       values)
             (= (length values)
                (length (delete-dups (copy-sequence values))))))))

(defun ebox-style--text-decoration-style-p (value)
  "Return non-nil when VALUE is a canonical text-decoration style."
  (memq value '(solid double dotted dashed wavy)))

(defun ebox-style--nonnegative-integer-p (value)
  "Return non-nil when VALUE is a nonnegative integer."
  (and (integerp value) (>= value 0)))

(defun ebox-style--cross-align-p (value)
  "Return non-nil when VALUE is a Row/Column cross alignment."
  (memq value '(start center end stretch)))

(defun ebox-style--flex-direction-p (value)
  "Return non-nil when VALUE is a canonical Flex direction."
  (memq value '(row row-reverse column column-reverse)))

(defun ebox-style--flex-wrap-p (value)
  "Return non-nil when VALUE is a canonical Flex wrapping mode."
  (memq value '(nowrap wrap wrap-reverse)))

(defun ebox-style--justify-content-p (value)
  "Return non-nil when VALUE is a canonical content justification."
  (memq value '(normal start end flex-start flex-end center stretch
                space-between space-around space-evenly)))

(defun ebox-style--align-items-p (value)
  "Return non-nil when VALUE is a canonical item alignment."
  (memq value '(normal start end stretch flex-start flex-end center baseline)))

(defun ebox-style--align-content-p (value)
  "Return non-nil when VALUE is a canonical multi-line alignment."
  (memq value '(normal start end stretch flex-start flex-end center
                space-between space-around space-evenly)))

(defun ebox-style--justify-items-p (value)
  "Return non-nil when VALUE is a canonical Grid item justification."
  (memq value '(stretch start end center)))

(defun ebox-style--align-self-p (value)
  "Return non-nil when VALUE is a canonical parent-relative alignment."
  (memq value '(auto normal start end stretch flex-start flex-end
                center baseline)))

(defun ebox-style--grid-auto-flow-p (value)
  "Return non-nil when VALUE is a canonical Grid auto-flow axis."
  (memq value '(row column)))

(defun ebox-style--grid-fixed-track-p (value)
  "Return non-nil when VALUE is a nonnegative Grid track size expression."
  (ebox-style--nonnegative-size-p value))

(defun ebox-style--grid-fr-track-p (value)
  "Return non-nil when VALUE is one positive fractional Grid track."
  (and (proper-list-p value) (= (length value) 2)
       (eq (car value) 'fr)
       (numberp (cadr value)) (> (cadr value) 0)))

(defun ebox-style--grid-track-p (value &optional allow-repeat)
  "Return non-nil when VALUE is one Grid track.
ALLOW-REPEAT permits a top-level repeat expression."
  (cond
   ((memq value '(auto min-content max-content)) t)
   ((ebox-style--grid-fixed-track-p value) t)
   ((ebox-style--grid-fr-track-p value) t)
   ((and (proper-list-p value) (= (length value) 3)
         (eq (car value) 'minmax))
    (let ((minimum (cadr value)) (maximum (caddr value)))
      (and (not (and (consp minimum)
                     (memq (car minimum) '(minmax repeat))))
           (not (and (consp maximum)
                     (memq (car maximum) '(minmax repeat))))
           (ebox-style--grid-track-p minimum nil)
           (not (ebox-style--grid-fr-track-p minimum))
           (ebox-style--grid-track-p maximum nil))))
   ((and allow-repeat (proper-list-p value) (= (length value) 3)
         (eq (car value) 'repeat)
         (integerp (cadr value)) (> (cadr value) 0))
    (let ((body (caddr value)))
      (or (ebox-style--grid-track-p body nil)
          (and (proper-list-p body) body
               (cl-every (lambda (track)
                           (ebox-style--grid-track-p track nil))
                         body)))))
   (t nil)))

(defun ebox-style--grid-track-list-p (value)
  "Return non-nil when VALUE is a valid Grid track list."
  (or (null value)
      (and (proper-list-p value) value
           (cl-every (lambda (track)
                       (ebox-style--grid-track-p track t))
                     value))))

(defun ebox-style--grid-auto-track-p (value)
  "Return non-nil when VALUE denotes at most one implicit Grid track."
  (or (null value)
      (ebox-style--grid-track-p value nil)
      (and (proper-list-p value) (= (length value) 1)
           (ebox-style--grid-track-p (car value) nil))))

(defun ebox-style--order-p (value)
  "Return non-nil when VALUE is an integer parent ordering key."
  (integerp value))

(defun ebox-style--justify-self-p (value)
  "Return non-nil when VALUE is a canonical Grid self alignment."
  (memq value '(auto stretch start end center)))

(defun ebox-style--scroll-anchor-p (value)
  "Return non-nil when VALUE is a public scroll anchor."
  (memq value '(start end)))

(defun ebox-style--wrap-mode-p (value)
  "Return non-nil when VALUE is a public Box wrapping mode."
  (memq value '(word char kp none)))

(defun ebox-style-no-soft-wrap-p (value)
  "Return non-nil when wrap VALUE disables soft line breaking.
`none' is the canonical author value; nil is retained only for private
generated wrappers that already contain exact line breaks."
  (memq value '(nil none)))

(defun ebox-style-soft-wrap-p (value)
  "Return non-nil when wrap VALUE performs soft line breaking."
  (memq value '(word char kp)))

(defun ebox-style--validator (name)
  "Return schema validator named NAME."
  (pcase name
    ('preferred-size #'ebox-style--preferred-size-p)
    ('horizontal-size #'ebox-style--horizontal-size-p)
    ('min-horizontal-size #'ebox-style--min-horizontal-size-p)
    ('max-horizontal-size #'ebox-style--max-horizontal-size-p)
    ('vertical-size #'ebox-style--vertical-size-p)
    ('min-vertical-size #'ebox-style--min-vertical-size-p)
    ('max-vertical-size #'ebox-style--max-vertical-size-p)
    ('nonnegative-size #'ebox-style--nonnegative-size-p)
    ('nonnegative-number #'ebox-style--nonnegative-number-p)
    ('positive-integer #'ebox-style--positive-integer-p)
    ('grid-placement #'ebox-style--grid-placement-p)
    ('outer #'ebox-style--outer-p)
    ('signed-size #'ebox-style--signed-size-p)
    ('position #'ebox-style--position-p)
    ('integer #'integerp)
    ('layer #'ebox-style--layer-p)
    ('anchor #'ebox-style--anchor-p)
    ('placement #'ebox-style--placement-p)
    ('font-family #'ebox-style--font-family-p)
    ('color #'ebox-style--color-p)
    ('backdrop-filter #'ebox-style--backdrop-filter-p)
    ('font-size #'ebox-style--font-size-p)
    ('font-weight #'ebox-style--font-weight-p)
    ('font-style #'ebox-style--font-style-p)
    ('border-width #'ebox-style--border-width-p)
    ('border-style #'ebox-style--border-style-p)
    ('text-decoration-line #'ebox-style--text-decoration-line-p)
    ('text-decoration-style #'ebox-style--text-decoration-style-p)
    ('nonnegative-integer #'ebox-style--nonnegative-integer-p)
    ('cross-align #'ebox-style--cross-align-p)
    ('flex-direction #'ebox-style--flex-direction-p)
    ('flex-wrap #'ebox-style--flex-wrap-p)
    ('justify-content #'ebox-style--justify-content-p)
    ('align-items #'ebox-style--align-items-p)
    ('align-content #'ebox-style--align-content-p)
    ('justify-items #'ebox-style--justify-items-p)
    ('align-self #'ebox-style--align-self-p)
    ('grid-auto-flow #'ebox-style--grid-auto-flow-p)
    ('grid-track-list #'ebox-style--grid-track-list-p)
    ('grid-track #'ebox-style--grid-auto-track-p)
    ('order #'ebox-style--order-p)
    ('flex-factor #'ebox-style--nonnegative-number-p)
    ('justify-self #'ebox-style--justify-self-p)
    ('wrap-mode #'ebox-style--wrap-mode-p)
    ('scroll-anchor #'ebox-style--scroll-anchor-p)
    ('boolean (lambda (value) (memq value '(nil t))))
    (_ (lambda (_value) t))))

(defun ebox-style--shorthand (name)
  "Return shorthand expander named NAME."
  (alist-get
   name
   '((padding . ebox-style--padding-shorthand)
     (padding-inline . ebox-style--padding-inline-shorthand)
     (padding-block . ebox-style--padding-block-shorthand)
     (margin . ebox-style--margin-shorthand)
     (margin-inline . ebox-style--margin-inline-shorthand)
     (margin-block . ebox-style--margin-block-shorthand)
     (border . ebox-style--border-shorthand)
     (border-top . ebox-style--border-top-shorthand)
     (border-right . ebox-style--border-right-shorthand)
     (border-bottom . ebox-style--border-bottom-shorthand)
     (border-left . ebox-style--border-left-shorthand)
     (border-top-present . ebox-style--border-top-present-shorthand)
     (border-width . ebox-style--border-width-shorthand)
     (border-style . ebox-style--border-style-shorthand)
     (border-color . ebox-style--border-color-shorthand)
     (gap . ebox-style--gap-shorthand)
     (grid-column-span . ebox-style--grid-column-span-shorthand)
     (grid-row-span . ebox-style--grid-row-span-shorthand)
     (flex-flow . ebox-style--flex-flow-shorthand)
     (flex . ebox-style--flex-shorthand))))

(defun ebox-style--size-axis (property &optional tag)
  "Return PROPERTY's size domain for author TAG when known."
  (let ((axis (plist-get property :size-axis)))
    (if (eq axis 'main)
        (pcase tag ('row 'inline) ('column 'block) (_ 'length))
      axis)))

(defun ebox-style--size-value-valid-p (property value &optional tag)
  "Return non-nil when PROPERTY's VALUE respects TAG's size domain.
Grid track wrappers are traversed after their structural validator succeeds."
  (let ((axis (ebox-style--size-axis property tag)))
    (or (null axis)
        (if (eq (plist-get property :size-grammar) 'tracks)
            (cl-labels
                ((valid-p (entry)
                   (cond
                    ((atom entry) t)
                    ((eq (car entry) 'fr) t)
                    ((memq (car entry) '(minmax repeat))
                     (cl-every #'valid-p (cdr entry)))
                    ((ebox-size-value-p entry)
                     (ebox-size-value-for-axis-p entry axis))
                    (t (cl-every #'valid-p entry)))))
              (valid-p value))
          (if (eq (plist-get property :validator) 'signed-size)
              (ebox-style--signed-size-p value axis)
            (or (symbolp value)
                (ebox-size-value-for-axis-p value axis)))))))

(defun ebox-style--schema-validator (property)
  "Return PROPERTY's grammar and unit-domain validator."
  (let ((validator (ebox-style--validator (plist-get property :validator))))
    (if (plist-get property :size-axis)
        (lambda (value)
          (and (funcall validator value)
               (ebox-style--size-value-valid-p property value)))
      validator)))

(defun ebox-style--schema-options (property)
  "Return ECSS registration options for PROPERTY metadata."
  (let ((options (list :initial (plist-get property :initial)
                       :inherits (plist-get property :inherits)
                       :normalizer (ebox-style--normalizer
                                    (plist-get property :normalizer))
                       :validator (ebox-style--schema-validator property)
                       :equality #'equal)))
    (when-let* ((shorthand (ebox-style--shorthand
                           (plist-get property :shorthand))))
      (setq options (plist-put options :shorthand shorthand)))
    options))

(defun ebox-style--schema-impacts (property)
  "Return immutable impact classes for PROPERTY metadata."
  (let ((name (plist-get property :name))
        (group (plist-get property :group)))
    (or (plist-get property :impacts)
        (and (eq group 'typography) '(geometry paint))
        (and (or (string-prefix-p ":padding" (symbol-name name))
                 (and (string-prefix-p ":border" (symbol-name name))
                      (not (string-suffix-p "-color" (symbol-name name)))
                      (not (eq name :border-color))))
             '(geometry paint))
        (list (plist-get property :dirty-kind)))))

(defun ebox-style--schema-projections (property)
  "Return immutable projection owners for PROPERTY metadata."
  (let ((name (plist-get property :name))
        (group (plist-get property :group))
        (contexts (plist-get property :contexts)))
    (or (plist-get property :projections)
        (cond
         ((eq group 'typography) '(measurement paint))
         ((memq 'item contexts) '(parent-participation))
         ((or (string-prefix-p ":padding" (symbol-name name))
              (and (string-prefix-p ":border" (symbol-name name))
                   (not (string-suffix-p "-color" (symbol-name name)))
                   (not (eq name :border-color))))
          '(layout paint))
         ((eq group 'paint) '(paint))
         ((eq group 'structure) '(structure layout))
         (t '(layout))))))

(defun ebox-style--schema-metadata (property)
  "Return detached, complete registry metadata for PROPERTY."
  (let ((metadata (copy-tree property)))
    (setq metadata
          (plist-put metadata :namespace
                     (if (memq (plist-get property :name)
                               '(:wrap-mode :item-gap :cross-align
                                 :border-top-p :grid-column-span
                                 :grid-row-span :layer :anchor :placement
                                 :backdrop-filter))
                         'ebox
                       'css)))
    (setq metadata
          (plist-put metadata :impacts
                     (ebox-style--schema-impacts property)))
    (plist-put metadata :projections
               (ebox-style--schema-projections property))))

(defun ebox-style--schema-definition (property)
  "Return one ECSS package definition for Ebox PROPERTY metadata."
  (append
   (list :id (plist-get property :id)
         :aliases
         (cons (plist-get property :name)
               (copy-sequence (plist-get property :aliases)))
         :impacts (ebox-style--schema-impacts property)
         :projections (ebox-style--schema-projections property)
         :metadata (ebox-style--schema-metadata property))
   (ebox-style--schema-options property)))

(defconst ebox-style--schema-package
  (ecss-schema-package-create
   'ebox
   (mapcar #'ebox-style--schema-definition
           ebox-style--property-definitions))
  "Immutable Ebox property package registered with ECSS.")

(defconst ebox-style--property-index
  (let ((table (make-hash-table :test #'eq)))
    (dolist (source ebox-style--property-definitions table)
      (let ((property (ebox-style--schema-metadata source)))
        (puthash (plist-get property :id) property table)
        (puthash (plist-get property :name) property table)
        (dolist (alias (plist-get property :aliases))
          (puthash alias property table)))))
  "Ebox-owned immutable lookup index over property definitions.")

(defconst ebox-style-schemas
  (ecss-schema-set-compose ebox-style--schema-package)
  "Immutable Ebox-only surface schema set.")

(cl-defstruct (ebox-style-scope (:constructor ebox-style--make-scope)
                                (:copier nil))
  "Shared author scope: a stable membership identity and one rule snapshot."
  identity stylesheet rules origin)

(cl-defun ebox-style-scope-create (rules &key (origin 'author))
  "Create an immutable shared scope from ordered RULES at ORIGIN.
RULES use the same syntax and Ebox schema as `ebox-style-compile-rules'.
Attach the returned object to source bindings through `:ecss-scopes' for
membership and `:ecss-scope-roots' for roots.  Each root mounts independently;
only members within that root can receive rules.  No roots means no rules."
  (ebox-style--make-scope :identity (make-symbol "ebox-style-scope")
                          :stylesheet (ebox-style--shared-stylesheet
                                       rules origin)
                          :rules rules
                          :origin origin))

(defvar ebox-style--stylesheets (make-hash-table :test 'equal)
  "Compiled stylesheets keyed by (ORIGIN . RULES).")

(defun ebox-style--shared-stylesheet (rules origin)
  "Return the compiled stylesheet of RULES at ORIGIN, shared across scopes.
Stylesheets are immutable once built, so equal rules reuse one object and
the computed-style cache hits by identity."
  (let ((key (cons origin rules)))
    (or (gethash key ebox-style--stylesheets)
        (let ((sheet (ecss-stylesheet-create)))
          (ecss-stylesheet-declare-layers sheet nil origin)
          (dolist (rule (ebox-style-compile-rules rules))
            (ecss-stylesheet-add-rule sheet ebox-style-schemas (car rule)
                                      (cdr rule) :origin origin))
          (when (> (hash-table-count ebox-style--stylesheets) 512)
            (clrhash ebox-style--stylesheets))
          (puthash (copy-tree key) sheet ebox-style--stylesheets)))))

(cl-defun ebox-style-scope-with-rules (scope rules &key (origin 'author))
  "Return a new RULES snapshot preserving SCOPE's membership identity.
ORIGIN follows `ebox-style-scope-create'.  Install the returned description
on roots; existing members need no rebinding.  Each root uses its own rule
snapshot.  Neither SCOPE nor previously constructed inputs are modified."
  (unless (ebox-style-scope-p scope)
    (error "Expected an Ebox shared style scope"))
  (let ((next (ebox-style-scope-create rules :origin origin)))
    (setf (ebox-style-scope-identity next) (ebox-style-scope-identity scope))
    next))

(defun ebox-style--custom-property-p (property)
  "Return non-nil when PROPERTY names an ECSS custom property."
  (and (symbolp property)
       (string-prefix-p "--" (symbol-name property))))


(defconst ebox-style--inherited-properties
  (cl-loop for property in ebox-style--property-definitions
           when (plist-get property :inherits)
           collect (plist-get property :id))
  "Canonical ECSS properties inherited according to the shared schema.")

(defun ebox-style--valid-plist-p (plist)
  "Return non-nil when PLIST is a proper even-length list."
  (and (proper-list-p plist) (zerop (% (length plist) 2))))

(defun ebox-style--validate-no-duplicate-properties (plist)
  "Reject duplicate canonical properties in author PLIST."
  (let ((seen (make-hash-table :test 'eq)))
    (cl-loop for (name _value) on plist by #'cddr
             for property = (ebox-style--property name)
             for id = (and property (plist-get property :id))
             when id
             do (when-let* ((previous (gethash id seen)))
                  (error
                   "Duplicate Ebox property %S via %S and %S"
                   (plist-get property :name) previous name))
             and do (puthash id name seen)))
  plist)

(defun ebox-style--declaration-cache-key (plist strict)
  "Return a stable style-only cache key for PLIST and STRICT.
Non-style node properties such as content, Host references, and callbacks do
not affect declaration compilation and are intentionally excluded."
  (let (canonical)
    (cl-loop for (property value) on plist by #'cddr
             for schema = (ebox-style-schema-id property)
             if schema
             do (setq canonical
                      (append canonical (list schema value)))
             else if (ebox-style--custom-property-p property)
             do (setq canonical
                      (append canonical (list property value)))
             else if strict
             do (setq canonical
                      (append canonical
                              (list 'ebox-style/unknown-property
                                    property value))))
    (list strict canonical)))

(defun ebox-style--static-invalid-declaration-p (validator value)
  "Return non-nil when VALIDATOR rejects static VALUE."
  (pcase validator
    ('preferred-size (not (ebox-style--preferred-size-p value)))
    ('nonnegative-number
     (and (numberp value) (< value 0)))
    ('horizontal-size (not (ebox-style--horizontal-size-p value)))
    ('min-horizontal-size (not (ebox-style--min-horizontal-size-p value)))
    ('max-horizontal-size (not (ebox-style--max-horizontal-size-p value)))
    ('vertical-size (not (ebox-style--vertical-size-p value)))
    ('min-vertical-size (not (ebox-style--min-vertical-size-p value)))
    ('max-vertical-size (not (ebox-style--max-vertical-size-p value)))
    ('nonnegative-size (not (ebox-style--nonnegative-size-p value)))
    ('signed-size (not (ebox-style--signed-size-p value)))
    ('position (not (ebox-style--position-p value)))
    ('integer (not (integerp value)))
    ('layer (not (ebox-style--layer-p value)))
    ('anchor (not (ebox-style--anchor-p value)))
    ('placement (not (ebox-style--placement-p value)))
    ('positive-integer
     (and (numberp value) (not (ebox-style--positive-integer-p value))))
    ('grid-placement
     (and (or (numberp value) (proper-list-p value))
          (not (ebox-style--grid-placement-p value))))
    ('font-family (not (ebox-style--font-family-p value)))
    ('color (not (ebox-style--color-p value)))
    ('font-size (not (ebox-style--font-size-p value)))
    ('font-weight (not (ebox-style--font-weight-p value)))
    ('font-style (not (ebox-style--font-style-p value)))
    ('border-width (not (ebox-style--border-width-p value)))
    ('border-style (not (ebox-style--border-style-p value)))
    ('text-decoration-line
     (not (ebox-style--text-decoration-line-p value)))
    ('text-decoration-style
     (not (ebox-style--text-decoration-style-p value)))
    ('nonnegative-integer
     (not (ebox-style--nonnegative-integer-p value)))
    ('cross-align (not (ebox-style--cross-align-p value)))
    ('flex-direction (not (ebox-style--flex-direction-p value)))
    ('flex-wrap (not (ebox-style--flex-wrap-p value)))
    ('justify-content (not (ebox-style--justify-content-p value)))
    ('align-items (not (ebox-style--align-items-p value)))
    ('align-content (not (ebox-style--align-content-p value)))
    ('justify-items (not (ebox-style--justify-items-p value)))
    ('align-self (not (ebox-style--align-self-p value)))
    ('grid-auto-flow (not (ebox-style--grid-auto-flow-p value)))
    ('grid-track-list (not (ebox-style--grid-track-list-p value)))
    ('grid-track (not (ebox-style--grid-auto-track-p value)))
    ('order (not (ebox-style--order-p value)))
    ('flex-factor
     (and (numberp value) (not (ebox-style--nonnegative-number-p value))))
    ('justify-self (not (ebox-style--justify-self-p value)))
    ('wrap-mode
     (not (ebox-style--wrap-mode-p value)))
    ('scroll-anchor
     (not (ebox-style--scroll-anchor-p value)))))

(defconst ebox-style--declaration-predicate-limit 512
  "Maximum schemas retained by the declaration-value predicate cache.")

(defvar ebox-style--declaration-predicate-cache (make-hash-table :test #'eq)
  "Reusable declaration-value predicates keyed by (SCHEMA . TAG).
Schema objects are registry-owned and tags are symbols, so one predicate per
pair reproduces the per-declaration closure without allocating it again.")

(defun ebox-style--declaration-value-predicate (schema tag)
  "Return a reusable value predicate for SCHEMA and author TAG."
  (let ((by-tag (gethash schema ebox-style--declaration-predicate-cache)))
    (unless by-tag
      (when (> (hash-table-count ebox-style--declaration-predicate-cache)
               ebox-style--declaration-predicate-limit)
        (clrhash ebox-style--declaration-predicate-cache))
      (setq by-tag (make-hash-table :test #'eq))
      (puthash schema by-tag ebox-style--declaration-predicate-cache))
    (or (gethash tag by-tag)
        (puthash tag
                 (lambda (concrete)
                   (and (not (ebox-style--static-invalid-declaration-p
                              (plist-get schema :validator) concrete))
                        (ebox-style--size-value-valid-p schema concrete tag)))
                 by-tag))))

(defun ebox-style--validate-declaration-values (declarations &optional tag)
  "Return DECLARATIONS after static value and author TAG axis validation."
  (cl-loop for (property value) on declarations by #'cddr
           for schema = (ebox-style--property property)
           for axis = (ebox-style--size-axis schema tag)
           unless (ecss-declaration-value-valid-p
                   value
                   (ebox-style--declaration-value-predicate schema tag))
           do (if axis
                  (signal 'ebox-size-error
                          (list
                           (format "Invalid value for %S; allowed units: %S"
                                   (plist-get schema :name)
                                   (cdr (assq axis ebox-size-axis-units)))
                           value))
                (error "ebox: invalid value for %S: %S"
                       (plist-get schema :name) value)))
  declarations)

(defconst ebox-style--edge-projection-groups
  '((:padding-top ebox/padding-top ebox/padding-block-start)
    (:padding-right ebox/padding-right ebox/padding-inline-end)
    (:padding-bottom ebox/padding-bottom ebox/padding-block-end)
    (:padding-left ebox/padding-left ebox/padding-inline-start)
    (:margin-top ebox/margin-top ebox/margin-block-start)
    (:margin-right ebox/margin-right ebox/margin-inline-end)
    (:margin-bottom ebox/margin-bottom ebox/margin-block-end)
    (:margin-left ebox/margin-left ebox/margin-inline-start))
  "Canonical facts sharing one fixed horizontal-tb/ltr physical edge.")

(defconst ebox-style--edge-projection-targets
  (cl-loop for (target . properties) in ebox-style--edge-projection-groups
           append (mapcar (lambda (property) (cons property target))
                          properties))
  "Canonical edge property to fixed physical projection target.")

(defun ebox-style--validate-edge-projection-conflicts (declarations)
  "Reject canonical DECLARATIONS that target one physical edge twice."
  (let ((seen (make-hash-table :test #'eq)))
    (cl-loop for (property _value) on declarations by #'cddr
             for target = (alist-get property
                                    ebox-style--edge-projection-targets)
             when target
             do (when-let* ((previous (gethash target seen)))
                  (signal 'ecss-invalid-declaration
                          (list :duplicate-edge-target target
                                :first-property previous
                                :second-property property)))
             and do (puthash target property seen)))
  declarations)

(defvar ebox-style--explicit-inherit nil
  "Non-nil once compiled declarations contained an explicit `inherit'.
Such a value can copy a non-inherited parent value, so computed styles then
depend on the whole parent style rather than only its inherited values.")

(defconst ebox-style--inherit-values
  (list (ecss-wide-value 'inherit) (ecss-important (ecss-wide-value 'inherit)))
  "Declaration values that copy a parent value explicitly.")

(defun ebox-style--note-explicit-inherit (declarations)
  "Record whether compiled DECLARATIONS contain an explicit `inherit'."
  (unless ebox-style--explicit-inherit
    (cl-loop for (_property value) on declarations by #'cddr
             when (and (ecss-declaration-value-tagged-p value)
                       (member value ebox-style--inherit-values))
             do (setq ebox-style--explicit-inherit t))))

(defun ebox-style-compile-declarations (plist &optional strict)
  "Compile Ebox PLIST aliases to ECSS schema declarations.
When STRICT is non-nil, reject properties outside the Ebox style domain."
  (unless (ebox-style--valid-plist-p plist)
    (user-error "Ebox style declarations must be an even property list"))
  (ebox-style--validate-no-duplicate-properties plist)
  (let* ((cache-key (ebox-style--declaration-cache-key plist strict))
         (missing (make-symbol "ebox-style-declaration-cache-missing"))
         (cached (gethash cache-key ebox-style--declaration-cache missing)))
    (if (not (eq cached missing))
        ;; Canonical declaration plists are immutable after compilation;
        ;; return a fresh top-level plist so callers own their list spine
        ;; without re-running ECSS's recursive boundary copier.
        (copy-sequence cached)
      (let ((canonical (cadr cache-key)))
        (when strict
          (cl-loop for (property _value) on plist by #'cddr
                   unless (or (ebox-style-schema-id property)
                              (ebox-style--custom-property-p property))
                   do (user-error "Unknown Ebox style property: %S"
                                  property)))
        (let ((compiled
               (ebox-style--validate-declaration-values
                (ebox-style--validate-edge-projection-conflicts
                 (ecss-expand-declarations ebox-style-schemas canonical)))))
          (when (>= (hash-table-count ebox-style--declaration-cache)
                    ebox-style--declaration-cache-max-entries)
            (clrhash ebox-style--declaration-cache))
          (ebox-style--note-explicit-inherit compiled)
          (puthash cache-key compiled ebox-style--declaration-cache)
          (copy-sequence compiled))))))

(defun ebox-style--form-property-allowed-p (tag property)
  "Return non-nil when author TAG accepts PROPERTY metadata."
  (let ((contexts (plist-get property :contexts))
        (author-contexts (plist-get property :author-contexts)))
    (if author-contexts
        (memq tag author-contexts)
      (or (memq tag contexts)
          (and (not (eq tag 'text))
               (or (memq 'box contexts) (memq 'item contexts)))))))

(defun ebox-style-validate-form-declarations (tag declarations)
  "Validate canonical DECLARATIONS for Text/Box author TAG."
  (unless (memq tag '(text box row column flex grid))
    (error "Unknown Ebox author form: %S" tag))
  (unless (ebox-style--valid-plist-p declarations)
    (error "Ebox canonical declarations must be an even plist: %S"
           declarations))
  (let ((seen (make-hash-table :test #'eq)))
    (cl-loop for (id _value) on declarations by #'cddr
             for property = (ebox-style--property id)
             unless (or (ebox-style--custom-property-p id)
                        (and property (eq id (plist-get property :id))))
             do (error "Ebox declaration is not a canonical property ID: %S"
                       id)
             do (when (gethash id seen)
                  (error "Duplicate canonical Ebox declaration: %S" id))
             do (puthash id t seen)
             unless (or (ebox-style--custom-property-p id)
                        (ebox-style--form-property-allowed-p tag property))
             do (error "Ebox %S does not accept %S"
                       tag (plist-get property :name))))
  (ebox-style--validate-declaration-values declarations tag)
  declarations)

(defun ebox-style--validate-author-values (plist)
  "Reject values in author PLIST outside the public property grammars.
An ECSS schema may use nil as an internal initial value, but nil is not an
author value unless the public grammar is boolean or an optional anchor."
  (unless (ebox-style--valid-plist-p plist)
    (user-error "Ebox style declarations must be an even property list"))
  (cl-loop for (name value) on plist by #'cddr
           for property = (ebox-style--property name)
           when (and property
                     (null value)
                     (not (memq (plist-get property :validator)
                                '(boolean anchor))))
           do (error "ebox: invalid value for %S: nil"
                     (plist-get property :name)))
  plist)

(defun ebox-style-compile-form (tag plist)
  "Compile evaluated author PLIST once and validate it for TAG."
  (ebox-style-validate-form-declarations
   tag
   (ebox-style-compile-declarations
    (ebox-style--validate-author-values plist) t)))

(defun ebox-style-merge-declarations (base overrides)
  "Merge canonical BASE and OVERRIDES through ECSS property schemas."
  (ecss-merge-declarations ebox-style-schemas base overrides))

(defun ebox-style-compile-rules (rules)
  "Compile ordered RULES through ECSS syntax and the strict Ebox schema.
Return detached (SELECTOR-AST . DECLARATIONS) rules suitable for the :ecss
field of `ebox-source-builder-bind'.  RULES uses (SELECTOR PROPERTY VALUE ...)
entries, with string selectors and inert declaration values.  This function
mutates no input or stylesheet and evaluates no declaration values."
  (mapcar (lambda (rule)
            (cons (ecss-selector-parse (car rule))
                  (ebox-style-compile-declarations (cdr rule) t)))
          (ecss-validate-rules rules)))

(defconst ebox-style--id-to-name-table
  (let ((table (make-hash-table :test 'eq)))
    (dolist (property ebox-style--property-definitions table)
      (unless (plist-get property :shorthand)
        (puthash (plist-get property :id) (plist-get property :name) table))))
  "Map from canonical ECSS property schema ids to public Ebox keywords.")

(defun ebox-style--public-property-name (id)
  "Return canonical public Ebox keyword for schema ID, or ID when custom."
  (or (gethash id ebox-style--id-to-name-table) id))

(defun ebox-style--public-computed-values (style)
  "Return STYLE values using canonical public Ebox property names."
  (let ((values (ecss-computed-style-values style)) result)
    (dolist (property ebox-style--property-definitions)
      (unless (plist-get property :shorthand)
        (setq result
              (plist-put result (plist-get property :name)
                         (plist-get values (plist-get property :id))))))
    result))

(defun ebox-style--common-border-value (style component)
  "Return common border COMPONENT in STYLE, or nil when sides differ."
  (let ((values
         (mapcar (lambda (side)
                   (plist-get style
                              (intern (format ":border-%s-%s" side component))))
                 ebox-style--border-sides)))
    (when (cl-every (lambda (value) (equal value (car values))) (cdr values))
      (car values))))

(defun ebox-style--add-border-aggregates (style)
  "Add uniform border shorthand facts to public computed STYLE."
  (dolist (component '(width style color) style)
    (when-let* ((value (ebox-style--common-border-value style component)))
      (setq style
            (plist-put style (intern (format ":border-%s" component)) value)))))

(defun ebox-style-compute (plist)
  "Return canonical public computed style for inline PLIST through ECSS."
  (let ((style
         (ecss-compute-style
          ebox-style-schemas (ecss-subject-create :type "box")
          :declarations (ebox-style-compile-declarations plist)
          :rules nil)))
    (ebox-style--add-border-aggregates
     (ebox-style--public-computed-values style))))

(defun ebox-style-expand-shorthands (plist)
  "Expand PLIST to canonical public longhands through ECSS schemas."
  (ebox-style-compute plist))

(defun ebox-style-dirty-kind (name)
  "Return dirty kind for canonical property or alias NAME."
  (when-let* ((property (ebox-style--property name)))
    (plist-get property :dirty-kind)))

(provide 'ebox-style)

;;; ebox-style.el ends here
