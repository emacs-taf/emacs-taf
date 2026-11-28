;;; etaf-ui-input.el --- Controlled native inputs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Native Emacs owns editing; Button owns activation; the caller owns the value.

;;; Code:
(require 'etaf-ui-basic)

;;;###autoload
(defun etaf-confirm-dialog (prompt)
  "Ask PROMPT from a Host callback; return non-nil only for native confirmation.
Use in an event callback before changing application data.  Emacs owns the
yes/no minibuffer; Ebox restores the entry's focus and validates its lifetime.
No returns nil; user quit and target invalidation abort the callback."
  (etaf-check-prop :prompt prompt
                   (and (stringp prompt) (not (string-empty-p prompt)))
                   "a nonempty string" 'etaf-confirm-dialog)
  (etaf-call-with-input
   (lambda ()
     (let ((use-dialog-box nil))
       (yes-or-no-p (concat prompt " "))))))

(defun etaf-ui--check-menu-items (items component)
  "Validate menu ITEMS for COMPONENT and return the same items."
  (let (keys labels)
    (etaf-check-prop :items items (proper-list-p items)
                     "a list of menu items" component)
    (dolist (item items)
      (etaf-check-prop :items item
                       (and (proper-list-p item) (zerop (% (length item) 2)))
                       "item plists with :key, :label and optional :disabled"
                       component)
      (let ((key (plist-get item :key)) (caption (plist-get item :label)))
        (etaf-check-prop :items item
                         (and key
                              (or (symbolp key) (numberp key) (stringp key))
                              (stringp caption) (not (string-empty-p caption))
                              (not (member key keys))
                              (not (member caption labels)))
                         "unique non-nil scalar keys and unique nonempty string labels"
                         component)
        (push key keys)
        (push caption labels)))
    items))

(etaf-define-component etaf-menu (&key (label "Actions") items on-select disabled)
  "Choose an action from ITEMS and pass its key to ON-SELECT.
Each item has a unique scalar :key, nonempty string :label and optional
:disabled.  Disabled items cannot be selected; an empty menu is disabled."
  :render
  (let ((choices
         (cl-loop for item in (etaf-ui--check-menu-items items 'etaf-menu)
                  unless (plist-get item :disabled)
                  collect (cons (plist-get item :label) (plist-get item :key)))))
    (etaf-check-prop :label label (stringp label) "a string" 'etaf-menu)
    (etaf-check-prop :on-select on-select
                     (or (null on-select) (functionp on-select))
                     "a function or nil" 'etaf-menu)
    (etaf-node
     'etaf-button
     (list :label (etaf-ui--disclosure-label label 'chevron-down)
           :aria-label label :variant 'ghost
           :disabled (or disabled (null choices) (null on-select))
           :on-press
           (unless (or disabled (null choices) (null on-select))
             (lambda ()
               (let* ((selection
                       (etaf-call-with-input
                        (lambda ()
                          (completing-read (concat label ": ")
                                           (mapcar #'car choices) nil t))))
                      (choice (assoc selection choices)))
                 (unless choice (signal 'quit nil))
                 (funcall on-select (cdr choice))))))
     nil)))

(defun etaf-ui--input-date-p (value)
  "Return non-nil when VALUE is an ISO date string."
  (and (stringp value)
       (string-match-p "\\`[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\\'" value)))

(defun etaf-ui--input-field (label hide-label controls &optional ref row-props)
  "Return one field row holding LABEL and CONTROLS.
A field is a single row: a muted caption unless HIDE-LABEL, then the
controls separated by one column.  Grid forms pass HIDE-LABEL and render
the caption in their own column so every control aligns.  REF, when
non-nil, names the row itself.  ROW-PROPS, when non-nil, is appended to the
row frame; a field nested inside another wrapping row passes an explicit
size here, because Ebox measures a stretching flex child at the whole row
and would then break the parent into one item per line."
  (etaf-node
   'flex
   (append
    (list :class "etaf-field" :flex-direction 'row :align-items 'center
          :flex-wrap 'wrap :gap '((lh 0) (ch 1)))
    row-props
    (unless (plist-member row-props :width)
      (list :width 'stretch))
    (when ref (list :ref ref)))
   (append
    (unless hide-label
      (list (etaf-node 'etaf-label
                       (list :text label :variant 'muted :class "etaf-field-label")
                       nil)))
    controls)))

(defconst etaf-ui--select-chip-limit 4
  "Largest option count that `etaf-select' presents as inline chips.")

(etaf-define-component etaf-select
    (&key (value etaf-ui--unsupplied) options (label "Select") (placeholder "—")
          (on-change etaf-ui--unsupplied) disabled bind (presentation 'auto)
          hide-label (width '(ch 28)) ref)
  "Choose a controlled VALUE from an alist of (VALUE . LABEL) OPTIONS.
Values and nonempty string labels must be unique.  Use VALUE/ON-CHANGE or BIND.

PRESENTATION is `chips', `dropdown' or `auto': chips render every option as
an inline pill and the current one filled; a dropdown renders one anchor pill
reading the current caption and lists the options in a Popover of WIDTH.
`auto' uses chips for up to four options.  REF names the dropdown anchor, or
the whole field when chips are shown.  HIDE-LABEL omits the caption for grid
forms.  Selection never opens the minibuffer."
  :bindings ((open (etaf-ref nil))
             (anchor (symbol-name (gensym "etaf-select-"))))
  :validate
  (etaf-check-prop :presentation presentation
                   (memq presentation '(auto chips dropdown))
                   "auto, chips or dropdown" 'etaf-select)
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-select :value bind value on-change))
         (current (etaf-ui--reactive-value (car input)))
         (callback (cdr input))
         choices
         values labels)
    (etaf-check-prop :options options (proper-list-p options)
                     "an alist of unique values and labels" 'etaf-select)
    (setq choices (copy-tree options))
    (dolist (option choices)
      (etaf-check-prop :options options
                       (and (consp option)
                            (or (symbolp (car option))
                                (numberp (car option))
                                (stringp (car option)))
                            (stringp (cdr option))
                            (not (equal (cdr option) ""))
                            (not (member (car option) values))
                            (not (member (cdr option) labels)))
                       "an alist of unique scalar values and unique nonempty string labels"
                       'etaf-select)
      (push (car option) values)
      (push (cdr option) labels))
    (etaf-check-prop :value current
                     (or (null current) (assoc current choices))
                     "nil or a value in :options" 'etaf-select)
    (etaf-check-prop :label label (stringp label) "a string" 'etaf-select)
    (etaf-check-prop :placeholder placeholder (stringp placeholder)
                     "a string" 'etaf-select)
    (let* ((caption (cdr (assoc current choices)))
           (inactive (or disabled (null choices)))
           (chips (or (eq presentation 'chips)
                      (and (eq presentation 'auto)
                           (<= (length choices) etaf-ui--select-chip-limit))))
           (choose (lambda (option)
                     (setf (etaf-value open) nil)
                     (when callback (funcall callback (car option))))))
      (etaf-ui--input-field
       label hide-label
       (if chips
           (mapcar
            (lambda (option)
              (let ((selected (equal (car option) current)))
                (etaf-node
                 'etaf-button
                 (list :key (cdr option) :label (cdr option)
                       :aria-label (cdr option)
                       :class (etaf-ui--class-value
                               "etaf-select-chip" (if selected "selected" "unselected") nil)
                       :variant 'ghost :aria-selected selected
                       :disabled inactive
                       :on-press (unless inactive
                                   (lambda () (funcall choose option))))
                 nil)))
            choices)
         (list
          (etaf-node
           'etaf-button
           (list :id anchor :ref ref
                 :label (etaf-ui--disclosure-label (or caption placeholder) 'chevron-down)
                 :aria-label label :variant 'secondary
                 :class "etaf-select-anchor"
                 :disabled inactive
                 :on-press (unless inactive
                             (lambda ()
                               (setf (etaf-value open) (not (etaf-value open))))))
           nil)
          (etaf-node
           'etaf-popover
           (list :open (and (not inactive) (etaf-value open))
                 :anchor anchor :width width
                 :on-close (lambda () (setf (etaf-value open) nil)))
           (mapcar
            (lambda (option)
              (let ((selected (equal (car option) current)))
                (etaf-node
                 'etaf-button
                 (list :key (cdr option)
                       :label (cdr option)
                       :aria-label (cdr option)
                       :class (etaf-ui--class-value
                               "etaf-select-option" (if selected "selected" "unselected") nil)
                       :variant 'ghost :width 'stretch :aria-selected selected
                       :on-press (lambda () (funcall choose option)))
                 nil)))
            choices))))
       (and chips ref)))))

(etaf-define-component etaf-number-input
    (&key (value etaf-ui--unsupplied) label
          (on-change etaf-ui--unsupplied) disabled min max bind hide-label ref)
  "Render a stepper NumberInput using VALUE/ON-CHANGE or writable ref BIND.
Non-nil BIND cannot be combined with explicit VALUE or ON-CHANGE, even nil.
The current value is an integer or nil; LABEL is a string or nil. MIN and
MAX are numbers or nil with MIN <= MAX.  The ± steppers change the value by
one within the bounds.  The value itself is edited in place by the catalog's
text field, so REF names that field: typing accepts only a complete in-range
integer or an empty value, and submitting anything else reports a readable
error without changing the value.  HIDE-LABEL omits the caption.  Invalid
inputs signal `etaf-component-call-error' identifying the Component and
property."
  :validate
  (progn
    (etaf-check-prop :label label (or (null label) (stringp label)) "a string or nil")
    (etaf-check-prop :min min (or (null min) (numberp min)) "a number or nil")
    (etaf-check-prop :max max (or (null max) (numberp max)) "a number or nil")
    (etaf-check-prop :max max (or (null min) (null max) (<= min max))
                     "nil or a bound greater than or equal to :min"))
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-number-input :value bind value on-change))
         (label (or label "Value"))
         (callback (cdr input))
         (current-value (etaf-ui--reactive-value (car input)))
         (minimum min)
         (maximum max)
         (integer-text-p (lambda (text)
                           (and (string-match-p "\\`-?[0-9]+\\'" text)
                                (string-to-number text))))
         (in-bounds-p (lambda (number)
                        (and (or (null minimum) (>= number minimum))
                             (or (null maximum) (<= number maximum)))))
         (accept (lambda (next)
                   (unless (and (integerp next) (funcall in-bounds-p next))
                     (user-error "%s must be an integer from %s to %s"
                                 label (or minimum "—") (or maximum "—")))
                   (when callback (funcall callback next))))
         (step (lambda (delta)
                 (lambda ()
                   (funcall accept (+ (or current-value 0) delta))))))
    (etaf-check-prop :value current-value (or (null current-value) (integerp current-value))
                     "an integer or nil" 'etaf-number-input)
    (etaf-ui--input-field
     label hide-label
     (list
      (etaf-node
       'etaf-button
       (list :label "−" :aria-label (format "Decrease %s" label)
             :class "etaf-number-input-step" :variant 'ghost
             :disabled (or disabled
                           (and minimum current-value
                                (< (1- current-value) minimum)))
             :on-press (unless disabled (funcall step -1)))
       nil)
      (etaf-node
       'etaf-text-input
       (list :ref ref :value (if (null current-value) "" (format "%s" current-value))
             :label label :hide-label t :placeholder "—"
             :width '(ch 6) :submit-on-return t
             :disabled disabled
             ;; Intermediate text stays a draft: only a complete in-range
             ;; integer updates the controlled value.  Clearing the text does
             ;; not clear the value; submitting an empty field does.
             :on-change
             (lambda (text)
               (when (funcall integer-text-p text)
                 (let ((number (string-to-number text)))
                   (when (funcall in-bounds-p number)
                     (when callback (funcall callback number))))))
             :on-submit
             (lambda (text)
               (cond ((equal text "") (when callback (funcall callback nil)))
                     ((funcall integer-text-p text) (funcall accept (string-to-number text)))
                     (t (funcall accept nil)))))
       nil)
      (etaf-node
       'etaf-button
       (list :label "+" :aria-label (format "Increase %s" label)
             :class "etaf-number-input-step" :variant 'ghost
             :disabled (or disabled
                           (and maximum current-value
                                (> (1+ current-value) maximum)))
             :on-press (unless disabled (funcall step 1)))
       nil)))))

(provide 'etaf-ui-input)
;;; etaf-ui-input.el ends here
