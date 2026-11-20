;;; etaf-ui-reactions.el --- Reaction chip strip -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One row of controlled reaction chips with an optional picker.  Chosen and
;; unchosen chips share padding and weight, so toggling never moves a chip.

;;; Code:
(require 'cl-lib)
(require 'etaf-ui-surface)
(require 'etaf-ui-icon)

(defconst etaf-ui--reaction-picker-columns 6
  "Choices per picker row; Ebox rows do not wrap.")

(defconst etaf-ui--reaction-cell-width 4
  "Picker cell width in columns.
With one blank row between picker rows each cell is square, so a choice's
emoji sits centred in an even grid whatever its own glyph width.")

(defconst etaf-ui--reaction-add-glyph "🙂"
  "Glyph of the chip that opens the reaction picker.")

(defun etaf-ui--reaction-scalar-key-p (key)
  "Return non-nil when reaction KEY can name an ETAF View."
  (and key (or (symbolp key) (stringp key) (integerp key))))

(defun etaf-ui--reaction-items (items)
  "Validate reaction ITEMS and return them."
  (etaf-check-prop :items items (proper-list-p items)
                   "a list of reaction plists" 'etaf-reactions)
  (let (keys)
    (dolist (item items)
      (etaf-check-prop :items items
                       (and (proper-list-p item)
                            (etaf-ui--reaction-scalar-key-p (plist-get item :key))
                            (not (member (plist-get item :key) keys))
                            (stringp (plist-get item :label))
                            (not (equal (plist-get item :label) ""))
                            (let ((count (plist-get item :count)))
                              (or (null count) (natnump count))))
                       "plists with unique non-nil scalar :key, nonempty string :label and natural :count"
                       'etaf-reactions)
      (push (plist-get item :key) keys)))
  items)

(defun etaf-ui--reaction-choices (choices)
  "Validate picker CHOICES, an alist of (KEY . LABEL) with scalar keys."
  (etaf-check-prop :choices choices
                   (and (proper-list-p choices)
                        (cl-every (lambda (choice)
                                    (and (consp choice)
                                         (etaf-ui--reaction-scalar-key-p (car choice))
                                         (stringp (cdr choice))
                                         (not (equal (cdr choice) ""))))
                                  choices)
                        (= (length choices)
                           (length (cl-remove-duplicates
                                    (mapcar #'car choices) :test #'equal))))
                   "an alist of unique non-nil scalar keys and nonempty string labels"
                   'etaf-reactions)
  choices)

(defun etaf-ui--reaction-chip (key label count chosen on-toggle)
  "Return one chip for KEY showing LABEL and COUNT, marked when CHOSEN."
  (let* ((theme (etaf-ui--style-tokens :ui-accent :ui-accent-soft-bg
                                       :ui-fg :ui-picker-item-bg))
         (text (if count (format "%s %d" label count) label)))
    (etaf-node 'etaf-button
               (list :key key :label text
                     :aria-label (format "%s%s" text (if chosen " (chosen)" ""))
                     :class (if chosen "etaf-reaction chosen" "etaf-reaction")
                     :variant 'ghost
                     :padding '((lh 0) (ch 1))
                     :font-weight 'normal
                     :color (plist-get theme (if chosen :ui-accent :ui-fg))
                     :bgcolor (plist-get theme (if chosen :ui-accent-soft-bg
                                                 :ui-picker-item-bg))
                     :on-press (lambda () (funcall on-toggle key)))
               nil)))

(etaf-define-component etaf-reactions
    (&key items on-toggle choices (add-label "Add reaction"))
  "Render controlled reaction chips with an optional picker.
ITEMS, a value or ref, are plists with unique scalar :key, nonempty string
:label, optional natural :count and boolean :chosen.  Pressing a chip
calls ON-TOGGLE with its key.  CHOICES, an alist of (KEY . LABEL), adds
a trailing smile chip named ADD-LABEL that opens a Popover; picking a
choice closes it and calls ON-TOGGLE with that key."
  :bindings ((open (etaf-ref nil))
             (anchor (symbol-name (gensym "etaf-reactions-"))))
  :render
  (let ((items (etaf-ui--reaction-items (etaf-ui--reactive-value items)))
        (choices (etaf-ui--reaction-choices choices)))
    (etaf-check-prop :on-toggle on-toggle (functionp on-toggle)
                     "a function" 'etaf-reactions)
    (etaf-check-prop :add-label add-label
                     (and (stringp add-label) (not (equal add-label "")))
                     "a nonempty string" 'etaf-reactions)
    (etaf-node
     'row (list :class "etaf-reactions" :item-gap '(ch 1))
     (append
      (mapcar (lambda (item)
                (etaf-ui--reaction-chip
                 (plist-get item :key) (plist-get item :label)
                 (plist-get item :count) (plist-get item :chosen) on-toggle))
              items)
      (when choices
        (let ((theme (etaf-ui--style-tokens :ui-fg :ui-picker-item-bg)))
          (list
           (etaf-node 'etaf-button
                      (list :id anchor :label (concat etaf-ui--reaction-add-glyph " +")
                            :aria-label add-label
                            :class "etaf-reaction add" :variant 'ghost
                            :padding '((lh 0) (ch 1)) :font-weight 'normal
                            :color (plist-get theme :ui-fg)
                            :bgcolor (plist-get theme :ui-picker-item-bg)
                            :on-press (lambda ()
                                        (setf (etaf-value open)
                                              (not (etaf-value open)))))
                      nil)
           (etaf-node
            'etaf-popover
            (list :open (etaf-value open) :anchor anchor
                  :width 'max-content
                  :on-close (lambda () (setf (etaf-value open) nil)))
            (list
             (etaf-node
              'column (list :item-gap '(lh 1))
              (mapcar
               (lambda (row)
                 (etaf-node
                  'row (list :item-gap '(ch 0))
                  (mapcar
                   (lambda (choice)
                     (etaf-node 'box
                                (list :key (car choice)
                                      :class "etaf-reaction-choice"
                                      :role 'button :tab-index 0
                                      :aria-label (cdr choice) :pointer 'arrow
                                      :width (list 'ch etaf-ui--reaction-cell-width)
                                      :text-align 'center
                                      :on-press
                                      (lambda ()
                                        (setf (etaf-value open) nil)
                                        (funcall on-toggle (car choice))))
                                (list (etaf-node 'text nil (list (cdr choice))))))
                   row)))
               (seq-partition choices etaf-ui--reaction-picker-columns))))))))))))

(provide 'etaf-ui-reactions)
;;; etaf-ui-reactions.el ends here
