;;; etaf-ui-navigation.el --- Navigation and disclosure Components -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Tabs, Accordion and Breadcrumb compose ordinary Buttons and flow layout.
;; They keep navigation state in caller-owned refs and do not create a second
;; focus or event system.

;;; Code:

(require 'etaf-ui-basic)

(defun etaf-ui--navigation-items (items component)
  "Validate navigation ITEMS for COMPONENT and return them unchanged.
An item may carry an optional scalar `:count' shown after its label, and an
optional symbol `:ref' a caller can address the tab control by."
  (etaf-check-prop :items items (proper-list-p items)
                   "a list of item plists" component)
  (let (keys labels)
    (dolist (item items)
      (etaf-check-prop :items item
                       (and (proper-list-p item)
                            (plist-get item :key)
                            (stringp (plist-get item :label))
                            (not (string-empty-p (plist-get item :label)))
                            (let ((count (plist-get item :count)))
                              (or (null count) (numberp count) (stringp count)))
                            (let ((ref (plist-get item :ref)))
                              (or (null ref) (symbolp ref)))
                            (not (member (plist-get item :key) keys))
                            (not (member (plist-get item :label) labels)))
                       "unique non-nil :key, nonempty string :label, scalar :count and a symbol :ref"
                       component)
      (push (plist-get item :key) keys)
      (push (plist-get item :label) labels))
    items))

(etaf-define-component etaf-tabs
    (&key items active on-change (variant 'underline) (framed t))
  "Render controlled navigation TABS.
ITEMS are plists with unique scalar :key and nonempty string :label; an
optional scalar :count renders after the label in the muted token color, and
an optional symbol :ref lets a caller address the tab control by name.
ACTIVE may be a value or ref; ON-CHANGE receives the selected key.

The default strip is one segmented bar: every tab carries the same hairline
frame, the chosen tab is filled with the panel surface, and its label uses
full-strength ink while the others stay muted.  The tabs have no gap and no
outer padding, so their frames read as one control.  A caller puts its content
under the strip; the strip never draws a second panel.  FRAMED nil leaves the
outer edges to a surrounding panel: the strip then draws only its dividers.

The strip is one Tab stop, entered at the selected tab: Left and Right move
focus inside it and RET selects the focused tab.  At either end the key is
consumed instead of wrapping or ringing."
  :render
  (let* ((items (etaf-ui--navigation-items items 'etaf-tabs))
         (active (etaf-ui--reactive-value active))
         (muted (etaf-theme-token :ui-muted-fg "#687386"))
         (ink (etaf-theme-token :ui-panel-fg "#1F2328"))
         (surface (etaf-theme-token :ui-accent-soft-bg "#E8EFFD"))
         (line (etaf-theme-token :ui-panel-border "#D9DDE3")))
    (etaf-check-prop :active active (cl-some (lambda (item) (equal active (plist-get item :key))) items)
                     "a key present in :items" 'etaf-tabs)
    (etaf-check-prop :on-change on-change (functionp on-change)
                     "a function" 'etaf-tabs)
    (etaf-check-prop :framed framed (booleanp framed)
                     "a boolean" 'etaf-tabs)
    (etaf-node 'row
               (list :class (format "etaf-tabs %s" variant) :role 'tablist
                     :focus-group 'horizontal
                     :width 'stretch :item-gap '(ch 0))
      (seq-map-indexed
       (lambda (item index)
         (let* ((key (plist-get item :key))
                (label (plist-get item :label))
                (count (plist-get item :count))
                (selected (equal key active))
                (content (when count
                           (etaf-view
                            (row :item-gap '(ch 0)
                              (text (expr (concat " " label " ")))
                              (box :color muted
                                (text (expr (concat
                                             (if (numberp count)
                                                 (number-to-string count)
                                               count)
                                             " ")))))))))
           ;; A tab is a box, not a Button: the catalog's button paints a
           ;; selected fill, and a tablist marks its choice with a filled
           ;; segment inside a shared hairline frame.  Only the first tab
           ;; draws a left edge; the others share their neighbour's right
           ;; edge, so the dividers stay one pixel wide.
           (etaf-node 'column
                      (append
                       (list :role 'tab
                             :tab-index 0
                             :width 'max-content
                             :color (if selected ink muted)
                             :background-color (and selected surface)
                             :border-top (when framed
                                           (etaf-ui--style-border line))
                             :border-right
                             (when (or framed (< index (1- (length items))))
                               (etaf-ui--style-border line))
                             :border-bottom (when framed
                                              (etaf-ui--style-border line))
                             :border-left (when (and framed (zerop index))
                                            (etaf-ui--style-border line))
                             :aria-selected selected
                             :aria-label (if count
                                             (format "%s %s" label count)
                                           label)
                             :on-press (lambda () (funcall on-change key)))
                       (when (plist-get item :ref)
                         (list :ref (plist-get item :ref))))
                      ;; A tab paints its own label: the box is the control
                      ;; the pointer and the keyboard address, and the text
                      ;; inside it is what the reader sees.
                      (if count
                          (list content)
                        (list (etaf-node 'text nil
                                         (list (concat " " label " "))))))))
       items))))

(etaf-define-component etaf-accordion
    (&key items open on-toggle (multiple t))
  "Render disclosure ITEMS controlled by OPEN keys.
Each item has :key, :label and :content. Content may be a string or a
zero-argument function returning a View. MULTIPLE permits more than one open
section; ON-TOGGLE receives the next list of keys.

The headers share one bordered panel: each title is a full-width row with a
hairline under it, and an open body is indented under its title instead of
sitting in a second, separate panel."
  :validate
  (progn
    (etaf-ui--navigation-items items 'etaf-accordion)
    (etaf-check-prop :multiple multiple (booleanp multiple) "a boolean" 'etaf-accordion)
    (etaf-check-prop :on-toggle on-toggle (functionp on-toggle)
                     "a function" 'etaf-accordion))
  :render
  (let* ((items (etaf-ui--navigation-items items 'etaf-accordion))
         (open (etaf-ui--reactive-value open))
         (line (etaf-theme-token :ui-panel-border "#D9DDE3")))
    (etaf-check-prop :open open
                     (and (proper-list-p open)
                          (cl-every (lambda (key)
                                     (cl-some (lambda (item) (equal key (plist-get item :key))) items))
                                    open)
                          (or multiple (<= (length open) 1)))
                     "a list of item keys" 'etaf-accordion)
    (etaf-node 'column
               (list :class "etaf-accordion" :width 'stretch
                     :item-gap '(lh 0)
                     :border (etaf-ui--style-border line)
                     :overflow 'hidden)
      (cl-loop
       for item in items
       for index from 0
       append
       (let* ((key (plist-get item :key))
              (expanded (member key open))
              (content (plist-get item :content))
              (last (= index (1- (length items)))))
         (etaf-check-prop :content content
                          (or (stringp content) (functionp content))
                          "a string or zero-argument function"
                          'etaf-accordion)
         ;; A row that carries :ref keeps the same Host across a repaint, so a
         ;; caller that re-renders around the accordion updates the title in
         ;; place instead of leaving the previous header above the new one.
         (list
          (etaf-node 'etaf-button
                     (append
                      (list :label (etaf-ui--disclosure-label
                                    (plist-get item :label)
                                    (if expanded 'chevron-down 'chevron-right) t)
                            :aria-label (plist-get item :label)
                            :aria-expanded (if expanded t 'false)
                            :variant 'ghost
                            :width 'stretch
                            :font-weight 'bold
                            :padding '((lh 1) (ch 2))
                            :border-bottom (unless last
                                             (etaf-ui--style-border line))
                            :on-press
                            (lambda ()
                              (funcall on-toggle
                                       (if expanded
                                           (delete key (copy-sequence open))
                                         (if multiple
                                             (cons key (copy-sequence open))
                                           (list key))))))
                      (when-let* ((ref (plist-get item :ref)))
                        (list :ref ref)))
                     nil)
          (when expanded
            (etaf-node
             'box
             (append
              (list :width 'stretch
                    :padding '((lh 0) (ch 4) (lh 1) (ch 2))
                    :border-bottom (unless last (etaf-ui--style-border line)))
              (when-let* ((ref (plist-get item :ref)))
                (list :ref (intern (format "%s-body" ref)))))
             (list (if (functionp content)
                       (funcall content)
                     (etaf-node 'etaf-label (list :text content) nil)))))))))))

(etaf-define-component etaf-breadcrumb (&key items on-select)
  "Render a breadcrumb trail from string ITEMS.
ON-SELECT, when supplied, receives the zero-based item index."
  :validate
  (progn
    (etaf-check-prop :items items (and (proper-list-p items) items)
                     "a nonempty list of strings" 'etaf-breadcrumb)
    (dolist (item items)
      (etaf-check-prop :items item (stringp item) "strings" 'etaf-breadcrumb))
    (etaf-check-prop :on-select on-select (or (null on-select) (functionp on-select))
                     "a function or nil" 'etaf-breadcrumb))
  :render
  (etaf-node 'row (list :class "etaf-breadcrumb" :width 'stretch
                        :item-gap '(ch 1) :focus-group 'horizontal)
             (cl-loop for item in items for index from 0 append
                      (let ((selected-index index))
                       (list (if on-select
                                (etaf-node 'etaf-button
                                           (list :label item :variant 'ghost
                                                 :aria-current
                                                 (= index (1- (length items)))
                                                 :on-press
                                                 (lambda ()
                                                   (funcall on-select selected-index)))
                                           nil)
                              (etaf-node 'etaf-label (list :text item) nil))
                            (unless (= index (1- (length items)))
                              (etaf-node 'etaf-label
                                         (list :text "/" :variant 'muted) nil)))))))

(defun etaf-ui--navigation-neighbor (items key step)
  "Return the KEY before or after the one matching KEY in ITEMS by STEP."
  (let* ((keys (mapcar (lambda (item) (plist-get item :key)) items))
         (position (or (cl-position key keys :test #'equal) 0))
         (count (length keys)))
    (nth (mod (+ position step) count) keys)))

(defun etaf-ui--steps-marker (list-style index)
  "Return the step marker LIST-STYLE draws at INDEX."
  (pcase list-style
    ('decimal (format "%d" index))
    ('bullet "*")
    (_ "")))

(defun etaf-ui--steps-vertical-item (item index list-style)
  "Return vertical step ITEM numbered INDEX under LIST-STYLE.
The number sits in a soft badge, and the body hangs from a rail so a reader
follows the order instead of re-reading the numbers."
  (let ((label (plist-get item :label))
        (content (plist-get item :content))
        (marker (etaf-ui--steps-marker list-style index))
        (muted (etaf-theme-token :ui-muted-fg "#687386"))
        (accent (etaf-theme-token :ui-accent "#2563EB"))
        (soft (etaf-theme-token :ui-accent-soft-bg "#E8EFFD")))
    (etaf-view
     (flex :class "etaf-steps-item" :width 'stretch
           :gap '((lh 0) (ch 1)) :align-items 'start
       (box :class "etaf-steps-marker" :width '(ch 3)
            :text-align 'center :font-weight 'bold
            :color accent :background-color soft
         (expr marker))
       (column :class "etaf-steps-body" :width 'stretch :item-gap '(lh 0)
               :border-left (etaf-ui--style-border muted)
               :padding '((lh 0) (ch 2) (lh 1) (ch 2))
         (etaf-label :text label :variant 'strong)
         (expr
          (cond ((functionp content) (funcall content))
                ((stringp content)
                 (etaf-view (etaf-label :text content :variant 'default))))))))))

(defun etaf-ui--steps-vertical (items start list-style)
  "Return ITEMS laid out one row each, numbered from START."
  (etaf-view
   (column :class "etaf-steps vertical" :width 'stretch :item-gap '(lh 1)
     (expr
      (cl-loop
       for item in items
       for index from start
       collect (etaf-ui--steps-vertical-item item index list-style))))))

(defun etaf-ui--steps-horizontal (items current on-change)
  "Return the stepper strip of ITEMS with CURRENT selected."
  (etaf-check-prop :current current
                   (cl-some (lambda (item) (equal current (plist-get item :key)))
                            items)
                   "a key present in :items" 'etaf-steps)
  (etaf-view
   (flex :class "etaf-steps" :width 'stretch :column-gap '(ch 1)
         :focus-group 'horizontal
         :row-gap '(lh 1) :flex-wrap 'wrap :align-items 'center
     (expr
      (cl-loop for item in items for index from 1 append
               (let* ((key (plist-get item :key))
                      (caption (plist-get item :label))
                      (label (format "%d  %s" index caption))
                      (active (equal key current)))
                 (list (etaf-view
                        (etaf-button :label label :aria-label caption
                                     :aria-current active :aria-selected active
                                     :variant 'ghost
                                     :on-press (and on-change
                                                    (lambda () (funcall on-change key)))))
                       (when (< index (length items))
                         (etaf-view (etaf-label :text "→" :variant 'muted))))))))))

(etaf-define-component etaf-steps
    (&key items current on-change (orientation 'horizontal)
          (start 1) (list-style 'decimal))
  "Render ordered STEPS with a caller-owned CURRENT key.
HORIZONTAL (the default) is a stepper strip of buttons and needs CURRENT.
VERTICAL lays one step per row: a marker picked by LIST-STYLE (starting at
START), the label, and the step's optional :content, which may be a string or
a zero-argument function returning a View.  A vertical list is static, so
CURRENT and ON-CHANGE only decide the marker's emphasis."
  :validate
  (progn
    (etaf-ui--navigation-items items 'etaf-steps)
    (etaf-check-prop :on-change on-change (or (null on-change) (functionp on-change))
                     "a function or nil" 'etaf-steps)
    (etaf-check-prop :orientation orientation
                     (memq orientation '(horizontal vertical))
                     "horizontal or vertical" 'etaf-steps)
    (etaf-check-prop :start start (and (integerp start) (>= start 0))
                     "a non-negative integer" 'etaf-steps)
    (etaf-check-prop :list-style list-style (memq list-style '(decimal bullet none))
                     "decimal, bullet or none" 'etaf-steps))
  :render
  (let ((current (etaf-ui--reactive-value current)))
    (if (eq orientation 'vertical)
        (etaf-ui--steps-vertical items start list-style)
      (etaf-ui--steps-horizontal items current on-change))))

(provide 'etaf-ui-navigation)
;;; etaf-ui-navigation.el ends here
