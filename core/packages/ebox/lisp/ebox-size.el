;;; ebox-size.el --- Explicit CSS length values for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Pure validation and pixel resolution for (UNIT NUMBER) lengths and
;; calc/min/max/clamp expressions.  Callers supply measured context and own
;; property keywords, range constraints, and final display quantization.

;;; Code:

(require 'cl-lib)

(define-error 'ebox-size-error "Invalid Ebox size")

(defconst ebox-size-axis-units
  '((inline px ch vw %)
    (block lh vh %)
    (stroke px ch lh vw vh)
    (length px ch vw lh vh %))
  "Allowed units for each Ebox size domain.
Inline and block lengths follow the renderer's horizontal and line axes.
Stroke thickness is a paint measurement independent of edge orientation.
Length is only for declarations whose parent-dependent axis is not known yet.")

(defun ebox-size--finite-number-p (value)
  "Return non-nil if VALUE is a finite real number."
  (and (numberp value)
       (or (integerp value) (= (- value value) 0.0))))

(defun ebox-size--fail (value reason)
  "Reject VALUE with a size error explaining REASON."
  (signal 'ebox-size-error (list reason value)))

(defun ebox-size--checked-number (value source)
  "Return finite VALUE, or reject SOURCE for arithmetic overflow."
  (unless (ebox-size--finite-number-p value)
    (ebox-size--fail source "Expected a finite number"))
  value)

(defun ebox-size--unit (value context)
  "Read a unit VALUE using pixel measurements in CONTEXT.
Return (DIMENSION PIXELS DEPENDENCIES), with nil PIXELS when unresolved."
  (unless (and (= (length value) 2)
               (ebox-size--finite-number-p (cadr value)))
    (ebox-size--fail value "Use (unit finite-number)"))
  (let* ((unit (car value))
         (amount (cadr value))
         (dependency (pcase unit
                       ('% 'percent)
                       ('vw 'viewport-width)
                       ('vh 'viewport-height)
                       ('ch 'ch)
                       ('lh 'lh)))
         (base (pcase unit
                 ('px 1)
                 ('% (plist-get context :percent-base))
                 ('vw (plist-get context :viewport-width))
                 ('vh (plist-get context :viewport-height))
                 ('ch (plist-get context :ch))
                 ('lh (plist-get context :lh)))))
    (when (and base
               (not (and (ebox-size--finite-number-p base) (>= base 0))))
      (ebox-size--fail value "Context measurements must be finite and nonnegative"))
    (list 'length
          (when base
            (ebox-size--checked-number
             (if (memq unit '(% vw vh))
                 (/ (* amount base) 100.0)
               (* amount base))
             value))
          (when dependency (list dependency)))))

(defun ebox-size--same-dimension (arguments source)
  "Return the shared dimension of ARGUMENTS, or reject SOURCE."
  (let ((dimension (caar arguments)))
    (unless (cl-every (lambda (argument) (eq (car argument) dimension))
                      arguments)
      (ebox-size--fail source "Cannot add or compare numbers and lengths"))
    dimension))

(defun ebox-size--math (value context)
  "Read mathematical VALUE in CONTEXT without evaluating Lisp."
  (let* ((operator (car value))
         (count (length (cdr value))))
    (unless (pcase operator
              ((or '* '/) (= count 2))
              ('clamp (= count 3))
              ('calc (= count 1))
              (_ (> count 0)))
      (ebox-size--fail value "Wrong number of size function arguments"))
    (let* ((arguments (mapcar (lambda (argument)
                               (ebox-size--read argument context t))
                             (cdr value)))
           (numbers (mapcar #'cadr arguments))
           (dimensions (mapcar #'car arguments))
           (dimension
            (pcase operator
              ('*
               (when (> (cl-count 'length dimensions) 1)
                 (ebox-size--fail value "Multiplication needs a scalar operand"))
               (if (memq 'length dimensions) 'length 'number))
              ('/
               (unless (eq (cadr dimensions) 'number)
                 (ebox-size--fail value "Division needs a scalar divisor"))
               (when (zerop (cadr numbers))
                 (ebox-size--fail value "Division by zero"))
               (car dimensions))
              (_ (ebox-size--same-dimension arguments value))))
           (dependencies (delete-dups
                          (apply #'append (mapcar #'caddr arguments)))))
      (list dimension
            (when (cl-every #'numberp numbers)
              (ebox-size--checked-number
               (pcase operator
                 ('calc (car numbers))
                 ('+ (apply #'+ numbers))
                 ('- (apply #'- numbers))
                 ('* (apply #'* numbers))
                 ('/ (/ (float (car numbers)) (cadr numbers)))
                 ('min (apply #'min numbers))
                 ('max (apply #'max numbers))
                 ('clamp (max (nth 0 numbers)
                              (min (nth 1 numbers) (nth 2 numbers)))))
               value))
            dependencies))))

(defun ebox-size--read (value context in-math)
  "Read VALUE with CONTEXT and scalar permission IN-MATH.
The result is (DIMENSION PIXELS DEPENDENCIES); nil PIXELS is unresolved."
  (cond
   ((and in-math (ebox-size--finite-number-p value))
    (list 'number value nil))
   ((not (and (consp value) (proper-list-p value)))
    (ebox-size--fail value "Use an explicit (unit number) length or size function"))
   ((memq (car value) '(px % vw vh ch lh))
    (ebox-size--unit value context))
   ((or (memq (car value) '(calc min max clamp))
        (and in-math (memq (car value) '(+ - * /))))
    (ebox-size--math value context))
   (t (ebox-size--fail value "Unknown size unit or function"))))

(defun ebox-size--parse (value context)
  "Read a length VALUE with CONTEXT, rejecting dimensionless results."
  (let ((result (ebox-size--read value context nil)))
    (unless (eq (car result) 'length)
      (ebox-size--fail value "A size expression must produce a length"))
    result))

(cl-defun ebox-size-value-p (value &optional allow-negative (allow-percent t))
  "Return non-nil when VALUE is a supported length or size expression.
Supported units are px, %, vw, vh, ch, and lh, each written (UNIT NUMBER).
Supported functions are calc, min, max, and clamp.  Inside functions,
+ and - combine like dimensions; * and / accept scalar operands.
Bare numbers, old singleton pixel lists, and keywords are not lengths.

ALLOW-NEGATIVE permits negative literal lengths; arithmetic intermediates
may always be negative.  Callers enforce the resolved property range.
ALLOW-PERCENT defaults to t; explicit nil forbids percentages anywhere
in the expression, for properties such as border widths."
  (condition-case nil
      (let ((result (ebox-size--parse value nil)))
        (and (or allow-negative
                 (not (memq (car value) '(px % vw vh ch lh)))
                 (>= (cadr value) 0))
             (or allow-percent (not (memq 'percent (caddr result))))
             t))
    (error nil)))

(defun ebox-size-validate-for-axis (value property axis)
  "Return length VALUE after validating PROPERTY's size AXIS.
AXIS is inline, block, stroke, or length as in `ebox-size-axis-units'.
Every unit inside calc, min, max, and clamp must be allowed on that axis,
including operands whose value would later cancel out.  Invalid syntax,
negative literals, and forbidden units signal `ebox-size-error' with the
property name and allowed units.  Keywords are validated by the property."
  (let ((allowed (or (cdr (assq axis ebox-size-axis-units))
                     (error "Unknown Ebox size axis: %S" axis))))
    (cl-labels ((units-valid-p (expression)
                  (or (atom expression)
                      (if (memq (car expression) '(px ch vw lh vh %))
                          (memq (car expression) allowed)
                        (cl-every #'units-valid-p (cdr expression))))))
      (unless (and (ebox-size-value-p value nil (memq '% allowed))
                   (units-valid-p value))
        (signal 'ebox-size-error
                (list (format "Invalid value for %S; allowed units: %S"
                              property allowed)
                      value)))))
  value)

(defun ebox-size-value-for-axis-p (value axis)
  "Return non-nil when length VALUE is valid for size AXIS."
  (condition-case nil
      (progn (ebox-size-validate-for-axis value 'size axis) t)
    (ebox-size-error nil)))

(defun ebox-size-resolve (value context)
  "Resolve length VALUE to pixels using CONTEXT, or nil if unresolved.
CONTEXT is a plist of pixel measurements: :percent-base is the containing
block reference, :viewport-width and :viewport-height are viewport sizes,
and :ch and :lh are the effective font's zero advance and line height.
Missing or nil measurements defer resolution; zero is a valid measurement.
Fractional and negative results are preserved.  The caller owns range
clamping and display rounding.  Invalid VALUE signals `ebox-size-error'."
  (cadr (ebox-size--parse value context)))

(defun ebox-size-dependencies (value)
  "Return the measurements required by length VALUE in first-use order.
Possible symbols are percent, viewport-width, viewport-height, ch, and lh.
Each appears at most once.  Invalid VALUE signals `ebox-size-error'."
  (caddr (ebox-size--parse value nil)))

(defun ebox-size-quantize (values)
  "Quantize nonnegative VALUES at cumulative display boundaries.
The returned whole extents preserve the floor of the combined extent instead
of losing each separate fraction.  A small tolerance absorbs floating-point
error at integer boundaries.  This is a display operation, not CSS arithmetic."
  (let ((position 0.0) (previous 0))
    (mapcar
     (lambda (value)
       (unless (and (ebox-size--finite-number-p value) (>= value 0))
         (ebox-size--fail value "Display extents must be finite and nonnegative"))
       (setq position (ebox-size--checked-number (+ position value) values))
       (let* ((boundary (floor (+ position 1e-9)))
              (extent (- boundary previous)))
         (setq previous boundary)
         extent))
     values)))

(provide 'ebox-size)
;;; ebox-size.el ends here
