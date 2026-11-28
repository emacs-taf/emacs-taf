;;; etaf-ui-svg.el --- Compose SVG scenes for retained box content -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Components that paint boards, charts, gauges or sprites compose an SVG
;; scene with the element helpers here and pass `etaf-ui-svg-image' to an
;; image source or image Host, such as `etaf-tile-grid' `:cell-image'.  Ebox
;; prepares the document as a native image and slices it at text row
;; boundaries, so the scene keeps the surrounding grid: layout, keyboard
;; targets, focus, names and the terminal text fallback stay ordinary ETAF
;; behaviour instead of a second drawing system.
;;
;; Every helper returns a markup string.  Geometry is validated, unknown or
;; duplicate attribute keys are rejected, text and attribute values are XML
;; escaped, and numbers are formatted the same way in every scene.  A nil
;; attribute value omits that attribute.  Invalid input signals
;; `etaf-ui-svg-error'.
;;
;; SVG is a graphical-frame capability.  Callers keep a text fallback for
;; terminal frames.  Keep the slice granularity aligned with interaction:
;; Ebox draws one image per displayed row, so slicing per cell multiplies
;; every scroll and repaint by the row's cell count.  Use block rows for
;; passive artwork and per-cell images only where each cell owns its own
;; target.  Cache a composed scene with its state key and clear the cache at
;; a fixed bound instead of rebuilding the document on every redraw.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xml)

(define-error 'etaf-ui-svg-error "Invalid SVG scene input")

(defconst etaf-ui--svg-attributes
  '((rect :transform :fill :stroke :stroke-width :stroke-linecap
          :stroke-linejoin :stroke-dasharray :opacity :rx :ry)
    (circle :transform :fill :stroke :stroke-width :stroke-linecap
            :stroke-linejoin :stroke-dasharray :opacity)
    (line :stroke :stroke-width :stroke-linecap :stroke-linejoin
          :stroke-dasharray :opacity)
    (path :fill :stroke :stroke-width :stroke-linecap :stroke-linejoin
          :stroke-dasharray :opacity)
    (text :font-family :font-size :font-weight :text-anchor
          :dominant-baseline :fill :stroke :stroke-width :opacity)
    (group :transform :fill :stroke :stroke-width :stroke-linecap
           :stroke-linejoin :stroke-dasharray :opacity))
  "SVG attribute keys each scene element accepts, in ECSS-style keywords.")

(defconst etaf-ui--svg-value-kinds
  '((:opacity . unit) (:stroke-width . positive) (:font-size . positive)
    (:rx . nonnegative) (:ry . nonnegative)
    (:fill . string) (:stroke . string) (:transform . string)
    (:font-family . string) (:text-anchor . string)
    (:dominant-baseline . string) (:stroke-linecap . string)
    (:stroke-linejoin . string)
    (:font-weight . number-or-string) (:stroke-dasharray . number-or-string))
  "Value kind of every attribute accepted by a scene element.
Kinds are `string', `number-or-string', `positive', `nonnegative' and
`unit' (a number between 0 and 1).")

(defun etaf-ui--svg-number (value what)
  "Return VALUE formatted compactly for SVG markup.
WHAT names VALUE in the error when it is not a number.  Integers stay
integers and fractions keep at most four decimals, so equal scenes produce
equal markup."
  (unless (numberp value)
    (signal 'etaf-ui-svg-error
            (list (format "%s must be a number, got %S" what value))))
  (if (= value (truncate value))
      (number-to-string (truncate value))
    (let ((text (replace-regexp-in-string
                 "\\.?0+\\'" "" (format "%.4f" (float value)))))
      (if (string-match-p "\\`-?0\\'" text) "0" text))))

(defun etaf-ui--svg-positive (value what)
  "Return positive number VALUE, or signal `etaf-ui-svg-error' naming WHAT."
  (unless (and (numberp value) (> value 0))
    (signal 'etaf-ui-svg-error
            (list (format "%s must be a positive number, got %S" what value))))
  value)

(defun etaf-ui--svg-value (element key value)
  "Return validated VALUE of ELEMENT attribute KEY as markup text.
String values are XML escaped and numbers are formatted compactly; a value
of the wrong kind signals `etaf-ui-svg-error' instead of producing a
silently wrong scene."
  (let ((kind (or (cdr (assq key etaf-ui--svg-value-kinds)) 'string)))
    (pcase kind
      ('string
       (unless (stringp value)
         (signal 'etaf-ui-svg-error
                 (list (format "%s attribute %S must be a string, got %S"
                               element key value))))
       (xml-escape-string value))
      ('number-or-string
       (cond ((stringp value) (xml-escape-string value))
             ((numberp value) (etaf-ui--svg-number
                               value (format "%s attribute %S" element key)))
             (t
              (signal 'etaf-ui-svg-error
                      (list (format "%s attribute %S must be a string or number, got %S"
                                    element key value))))))
      (_
       (let ((valid (and (numberp value)
                         (pcase kind
                           ('positive (> value 0))
                           ('nonnegative (>= value 0))
                           ('unit (and (>= value 0) (<= value 1)))))))
         (unless valid
           (signal 'etaf-ui-svg-error
                   (list (format "%s attribute %S must be %s, got %S"
                                 element key
                                 (pcase kind
                                   ('positive "a positive number")
                                   ('nonnegative "a nonnegative number")
                                   ('unit "a number between 0 and 1"))
                                 value))))
         (etaf-ui--svg-number value (format "%s attribute %S" element key)))))))

(defun etaf-ui--svg-attributes (element attributes)
  "Return validated ATTRIBUTES of scene ELEMENT as markup text.
ATTRIBUTES is a keyword/value plist; a nil value omits its attribute.
Values are validated by their attribute kind and escaped or formatted by
`etaf-ui--svg-value'.  Unknown or duplicate keys, malformed plists and
wrong value kinds signal `etaf-ui-svg-error'."
  (let ((allowed (alist-get element etaf-ui--svg-attributes))
        (seen nil) (parts nil))
    (while attributes
      (let ((key (pop attributes)))
        (unless (keywordp key)
          (signal 'etaf-ui-svg-error
                  (list (format "%s attributes must be keyword/value pairs, got %S"
                                element key))))
        (when (null attributes)
          (signal 'etaf-ui-svg-error
                  (list (format "%s attribute %S has no value" element key))))
        (let ((value (pop attributes)))
          (unless (memq key allowed)
            (signal 'etaf-ui-svg-error
                    (list (format "%s does not accept attribute %S; accepted: %S"
                                  element key (mapcar #'symbol-name allowed)))))
          (when (memq key seen)
            (signal 'etaf-ui-svg-error
                    (list (format "%s attribute %S is repeated" element key))))
          (push key seen)
          (when value
            (push (format " %s='%s'" (substring (symbol-name key) 1)
                          (etaf-ui--svg-value element key value))
                  parts)))))
    (apply #'concat (nreverse parts))))

(defun etaf-ui-svg-rect (x y width height &rest attributes)
  "Return SVG markup for a rectangle at X and Y with WIDTH and HEIGHT.
X and Y may be any numbers; WIDTH and HEIGHT must be positive.  ATTRIBUTES
accept :rx, :ry, :transform and the shared stroke family :fill, :stroke,
:stroke-width, :stroke-linecap, :stroke-linejoin, :stroke-dasharray and
:opacity.  Invalid input signals `etaf-ui-svg-error'."
  (etaf-ui--svg-positive width "Rectangle width")
  (etaf-ui--svg-positive height "Rectangle height")
  (format "<rect x='%s' y='%s' width='%s' height='%s'%s/>"
          (etaf-ui--svg-number x "Rectangle x")
          (etaf-ui--svg-number y "Rectangle y")
          (etaf-ui--svg-number width "Rectangle width")
          (etaf-ui--svg-number height "Rectangle height")
          (etaf-ui--svg-attributes 'rect attributes)))

(defun etaf-ui-svg-circle (cx cy radius &rest attributes)
  "Return SVG markup for a circle centred at CX and CY with RADIUS.
CX and CY may be any numbers; RADIUS must be positive.  ATTRIBUTES accept
:transform and the shared stroke family :fill, :stroke, :stroke-width,
:stroke-linecap, :stroke-linejoin, :stroke-dasharray and :opacity.  Invalid
input signals `etaf-ui-svg-error'."
  (etaf-ui--svg-positive radius "Circle radius")
  (format "<circle cx='%s' cy='%s' r='%s'%s/>"
          (etaf-ui--svg-number cx "Circle cx")
          (etaf-ui--svg-number cy "Circle cy")
          (etaf-ui--svg-number radius "Circle radius")
          (etaf-ui--svg-attributes 'circle attributes)))

(defun etaf-ui-svg-line (x1 y1 x2 y2 &rest attributes)
  "Return SVG markup for a straight line from X1,Y1 to X2,Y2.
ATTRIBUTES accept :stroke, :stroke-width, :stroke-linecap, :stroke-linejoin,
:stroke-dasharray and :opacity.  Invalid input signals `etaf-ui-svg-error'."
  (format "<line x1='%s' y1='%s' x2='%s' y2='%s'%s/>"
          (etaf-ui--svg-number x1 "Line x1")
          (etaf-ui--svg-number y1 "Line y1")
          (etaf-ui--svg-number x2 "Line x2")
          (etaf-ui--svg-number y2 "Line y2")
          (etaf-ui--svg-attributes 'line attributes)))

(defun etaf-ui-svg-path (d &rest attributes)
  "Return SVG markup for path data D.
D is the SVG path mini-language as a nonempty string.  ATTRIBUTES accept
:fill, :stroke, :stroke-width, :stroke-linecap, :stroke-linejoin,
:stroke-dasharray and :opacity.  Invalid input signals `etaf-ui-svg-error'."
  (unless (and (stringp d) (not (string-empty-p d)))
    (signal 'etaf-ui-svg-error
            (list (format "Path data must be a nonempty string, got %S" d))))
  (format "<path d='%s'%s/>"
          (xml-escape-string d)
          (etaf-ui--svg-attributes 'path attributes)))

(defun etaf-ui-svg-text (x y text &rest attributes)
  "Return SVG markup for TEXT anchored at X and Y.
X and Y may be any numbers; TEXT is a single-line string and its content is
XML escaped.  ATTRIBUTES accept :font-family, :font-size, :font-weight,
:text-anchor, :dominant-baseline, :fill, :stroke, :stroke-width and
:opacity.  Invalid input signals `etaf-ui-svg-error'."
  (when (or (not (stringp text)) (string-match-p "[\n\r]" text))
    (signal 'etaf-ui-svg-error
            (list (format "Text content must be a single-line string, got %S" text))))
  (format "<text x='%s' y='%s'%s>%s</text>"
          (etaf-ui--svg-number x "Text x")
          (etaf-ui--svg-number y "Text y")
          (etaf-ui--svg-attributes 'text attributes)
          (xml-escape-string text)))

(defun etaf-ui-svg-group (children &rest attributes)
  "Return SVG markup for group CHILDREN sharing attributes.
CHILDREN is the concatenated markup of nested scene elements.  ATTRIBUTES
accept :transform, :fill, :stroke, :stroke-width, :stroke-linecap,
:stroke-linejoin, :stroke-dasharray and :opacity.  Invalid input signals
`etaf-ui-svg-error'."
  (unless (stringp children)
    (signal 'etaf-ui-svg-error
            (list (format "Group children must be markup string, got %S" children))))
  (format "<g%s>%s</g>"
          (etaf-ui--svg-attributes 'group attributes)
          children))

(defun etaf-ui-svg-image (body width height viewbox &optional preserve-aspect-ratio)
  "Return an ETAF image descriptor showing scene BODY in a WIDTH by HEIGHT box.
BODY is markup composed from the `etaf-ui-svg' element helpers.  WIDTH and
HEIGHT are the pixel box the prepared image fills; VIEWBOX is the scene
coordinate window (X Y WIDTH HEIGHT) mapped onto that box.  WIDTH, HEIGHT and
the viewbox size must be positive; X and Y may be any numbers.
PRESERVE-ASPECT-RATIO is nil for the SVG default centring, `none' to scale
the complete scene to the box, or an error otherwise.
The result is an (image :type svg :data STRING) descriptor accepted by image
sources and image Hosts such as `etaf-tile-grid' `:cell-image'.  Invalid
input signals `etaf-ui-svg-error'."
  (unless (stringp body)
    (signal 'etaf-ui-svg-error
            (list (format "Scene body must be a markup string, got %S" body))))
  (unless (and (listp viewbox) (= 4 (length viewbox)))
    (signal 'etaf-ui-svg-error
            (list (format "Viewbox must be (X Y WIDTH HEIGHT), got %S" viewbox))))
  (etaf-ui--svg-positive width "Image width")
  (etaf-ui--svg-positive height "Image height")
  (let ((x (nth 0 viewbox)) (y (nth 1 viewbox))
        (view-width (nth 2 viewbox)) (view-height (nth 3 viewbox)))
    (dolist (entry (list (cons x "Viewbox x") (cons y "Viewbox y")))
      (etaf-ui--svg-number (car entry) (cdr entry)))
    (etaf-ui--svg-positive view-width "Viewbox width")
    (etaf-ui--svg-positive view-height "Viewbox height")
    (unless (or (null preserve-aspect-ratio)
                (member preserve-aspect-ratio '(none "none")))
      (signal 'etaf-ui-svg-error
              (list (format "Preserve aspect ratio must be nil or none, got %S"
                            preserve-aspect-ratio))))
    (list 'image :type 'svg
          :data (format "<svg xmlns='http://www.w3.org/2000/svg' width='%s' height='%s' viewBox='%s %s %s %s'%s>%s</svg>"
                        (etaf-ui--svg-number width "Image width")
                        (etaf-ui--svg-number height "Image height")
                        (etaf-ui--svg-number x "Viewbox x")
                        (etaf-ui--svg-number y "Viewbox y")
                        (etaf-ui--svg-number view-width "Viewbox width")
                        (etaf-ui--svg-number view-height "Viewbox height")
                        (if preserve-aspect-ratio " preserveAspectRatio='none'" "")
                        body))))

(provide 'etaf-ui-svg)
;;; etaf-ui-svg.el ends here
