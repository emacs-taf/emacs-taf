;;; etaf-ui-advanced.el --- Advanced composed ETAF UI Components -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Date, tree, calendar, command-palette and sign-in Components compose the
;; catalog's controlled inputs, disclosure and floating surface contracts.

;;; Code:
(require 'calendar)
(require 'cl-lib)
(require 'etaf-ui-input)
(require 'etaf-ui-navigation)
(require 'etaf-ui-surface)
(require 'etaf-ui-table)

(etaf-define-component etaf-date-picker
    (&key (value etaf-ui--unsupplied) (label "Date") (placeholder "YYYY-MM-DD")
          (on-change etaf-ui--unsupplied) disabled bind)
  "Render a semantic DATE-PICKER on the catalog's native text field.
The controlled value is an ISO `YYYY-MM-DD' string or nil.  Editing is native
and in place: typing a partial date keeps the last accepted value, and
submitting rejects an invalid date with a readable error instead of writing
it."
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-date-picker :value bind value on-change))
         (current (etaf-ui--reactive-value (car input)))
         (callback (cdr input)))
    (etaf-check-prop :value current
                     (or (null current)
                         (and (stringp current) (etaf-ui--input-date-p current)))
                     "nil or an ISO YYYY-MM-DD string" 'etaf-date-picker)
    (etaf-node
     'etaf-text-input
     (list :value (or current "") :label label :placeholder placeholder
           :disabled disabled
           :on-change
           (lambda (text)
             (when (or (equal text "") (etaf-ui--input-date-p text))
               (when callback (funcall callback (if (equal text "") nil text)))))
           :on-submit
           (lambda (text)
             (unless (or (equal text "") (etaf-ui--input-date-p text))
               (user-error "%s must use YYYY-MM-DD" label))))
     nil)))

(defun etaf-ui--tree-items (items expanded)
  "Validate all ITEMS and return visible entries under EXPANDED keys.
Each entry carries its depth, whether it is a branch, whether it is the last
of its siblings, and the guide a line-drawing caller puts before its label."
  (let ((seen (make-hash-table :test #'equal)))
    (cl-labels
        ((walk (nodes depth visible guide)
           (etaf-check-prop :items nodes (proper-list-p nodes)
                            "a list of tree items" 'etaf-tree)
           (let ((entries nil)
                 (index 0)
                 (count (length nodes)))
             (dolist (item nodes (nreverse entries))
               (etaf-check-prop
                :items item
                (and (proper-list-p item) (zerop (% (length item) 2))
                     (plist-get item :key)
                     (let ((key (plist-get item :key)))
                       (or (symbolp key) (stringp key) (numberp key)))
                     (stringp (plist-get item :label))
                     (not (string-empty-p (plist-get item :label)))
                     (not (gethash (plist-get item :key) seen)))
                "items with globally unique scalar keys and nonempty labels" 'etaf-tree)
               (let* ((key (plist-get item :key))
                      (children (plist-get item :children))
                      (last (= index (1- count))))
                 (setq index (1+ index))
                 (puthash key t seen)
                 (when visible
                   (push (list :key key :label (plist-get item :label)
                               :depth depth :branch (and children t)
                               :last last :guide guide)
                         entries))
                 (dolist (child (walk children (1+ depth)
                                      (and visible (member key expanded))
                                      (concat guide (if last "   " "│  "))))
                   (push child entries)))))))
      (walk items 0 t ""))))

(etaf-define-component etaf-tree
    (&key items expanded on-toggle on-select lines)
  "Render a controlled TREE with nested :children item plists.
EXPANDED is a caller-owned list of open keys; callbacks receive a key or the
next expanded key list.  LINES draws box-drawing guides instead of disclosure
arrows; a tree without callbacks is static and draws plain labels, so a
document can show a directory without adding tab stops."
  :validate
  (progn
    (etaf-check-prop :items items (and (proper-list-p items) items)
                     "a nonempty list of tree items" 'etaf-tree)
    (etaf-check-prop :on-toggle on-toggle (or (null on-toggle) (functionp on-toggle))
                     "a function or nil" 'etaf-tree)
    (etaf-check-prop :on-select on-select (or (null on-select) (functionp on-select))
                     "a function or nil" 'etaf-tree)
    (etaf-check-prop :lines lines (or (null lines) (eq lines t))
                     "a boolean" 'etaf-tree))
  :render
  (let* ((expanded (etaf-ui--reactive-value expanded))
         (_ (etaf-check-prop :expanded expanded (proper-list-p expanded)
                             "a list of expanded keys" 'etaf-tree))
         (flat (etaf-ui--tree-items items expanded)))
    (etaf-view
     (column :class "etaf-tree" :width 'stretch :item-gap '(lh 0)
             :focus-group (unless (and lines (null on-toggle)) 'vertical)
       (expr
        (mapcar
         (lambda (entry)
           (let* ((key (plist-get entry :key))
                  (branch (plist-get entry :branch))
                  (open (member key expanded))
                  (guide (plist-get entry :guide))
                  (caption (concat
                            (if lines
                                (concat guide (if (plist-get entry :last) "└─ " "├─ "))
                              (make-string (* 2 (plist-get entry :depth)) ?\s))
                            (if lines
                                (plist-get entry :label)
                              (if branch
                                  (etaf-ui--disclosure-label
                                   (plist-get entry :label)
                                   (if open 'chevron-down 'chevron-right) t)
                                (concat "  " (plist-get entry :label))))))
                  (toggle (lambda ()
                            (when on-toggle
                              (funcall on-toggle
                                       (if open (delete key (copy-sequence expanded))
                                         (cons key (copy-sequence expanded))))))))
             (if (and lines (null on-toggle) (null on-select))
                 (etaf-view (etaf-label :text caption :variant 'default))
               (etaf-view
                (etaf-button :label caption :variant 'ghost :aria-selected (and open t)
                             :aria-label (plist-get entry :label)
                             :aria-expanded (and branch (if open t 'false))
                             ;; Right opens and left closes a branch in place.
                             :on-direction
                             (when (and branch on-toggle)
                               (lambda (direction)
                                 (pcase direction
                                   ('right (if open 'release
                                             (funcall toggle) 'handled))
                                   ('left (if open (progn (funcall toggle) 'handled)
                                           'release))
                                   (_ 'release))))
                             :on-press
                             (lambda ()
                               (if branch
                                   (funcall toggle)
                                 (when on-select (funcall on-select key)))))))))
         flat))))))

(etaf-define-component etaf-calendar
    (&key (month '(2026 1)) value on-change (label "Calendar"))
  "Render a controlled month CALENDAR as (YEAR MONTH) and date VALUE.
ON-CHANGE receives (YEAR MONTH DAY)."
  :validate
  (progn
    (etaf-check-prop :month month (and (proper-list-p month) (= (length month) 2)
                                       (integerp (car month)) (integerp (cadr month))
                                       (<= 1 (cadr month) 12))
                     "a (YEAR MONTH) list" 'etaf-calendar)
    (etaf-check-prop :value value (or (null value) (integerp value))
                     "an integer day or nil" 'etaf-calendar)
    (etaf-check-prop :on-change on-change (or (null on-change) (functionp on-change))
                     "a function or nil" 'etaf-calendar))
  :render
  (let* ((year (car month)) (number (cadr month))
         (first (mod (1- (calendar-day-of-week (list number 1 year))) 7))
         (last (calendar-last-day-of-month number year))
         (name (calendar-month-name number))
         (cells (append (make-list first nil) (number-sequence 1 last)))
         (rows (cl-loop for start from 0 below (length cells) by 7
                        collect (cl-subseq cells start (min (+ start 7) (length cells)))))
         (week-days '("Mo" "Tu" "We" "Th" "Fr" "Sa" "Su"))
         (week-views
          (mapcar (lambda (day)
                    (etaf-node 'etaf-label
                               (list :text day :variant 'muted
                                     :width '(ch 4) :text-align 'center) nil))
                  week-days))
         (row-views
          (mapcar
           (lambda (calendar-row)
             (etaf-node 'row (list :item-gap '(ch 1))
                        (mapcar
                         (lambda (day)
                           (if day
                               (etaf-node
                                'etaf-button
                                (list :label (format "%2d" day)
                                      :variant 'ghost :width '(ch 4)
                                      :box-sizing 'border-box
                                      :padding '((lh 0) (ch 1))
                                      :text-align 'center
                                      :aria-selected (equal day value)
                                      :aria-label (format "%s %d" name day)
                                      :on-press
                                      (and on-change
                                           (lambda ()
                                             (funcall on-change (list year number day)))))
                                nil)
                             (etaf-node 'etaf-label (list :text "  " :width '(ch 4)) nil)))
                         calendar-row)))
           rows)))
    (etaf-node
     'column
     (list :class "etaf-calendar" :width 'stretch :item-gap '(lh 1)
           :focus-group 'grid)
     (append
      (list (etaf-node 'row (list :item-gap '(ch 1))
                       (list (etaf-node 'etaf-label (list :text label :variant 'strong) nil)
                             (etaf-node 'etaf-label
                                        (list :text (format "%s %d" name year)
                                              :variant 'muted) nil)))
            (etaf-node 'row (list :item-gap '(ch 1)) week-views))
      row-views))))

(etaf-define-component etaf-command-palette
    (&key open (title "Command palette") items on-select on-close)
  "Render a controlled COMMAND-PALETTE from LIST ITEMS in a modal Dialog."
  :validate
  (etaf-check-prop :on-close on-close (functionp on-close)
                   "a function" 'etaf-command-palette)
  :render
  (when (etaf-ui--reactive-value open)
    (etaf-node 'etaf-dialog
               (list :open open :title title :on-close on-close :width '(ch 56))
               (list (etaf-node 'etaf-list
                                (list :items items :on-select on-select) nil)))))

(defconst etaf-ui--qr-face '(:foreground "#000000" :background "#FFFFFF")
  "Anonymous face keeping a painted sign-in code scannable.
A scanner needs pure black modules on pure white, so this face carries no
Theme token and keeps that contrast in both palettes.")

(defun etaf-ui--qr-glyph (upper lower)
  "Return the half-block glyph for module flags UPPER and LOWER."
  (cond ((and upper lower) "█")
        (upper "▀")
        (lower "▄")
        (t " ")))

(defun etaf-ui--qr-module-p (row column)
  "Return non-nil when ROW sets the module at COLUMN.
A row shorter than COLUMN is blank past its end, as `etaf-ui-qr-paint'
documents."
  (and (< column (length row))
       (eq ?1 (aref row column))))

(defun etaf-ui-qr-paint (rows &optional quiet)
  "Paint module ROWS as a scannable code string.
ROWS is a list of strings of \"0\" and \"1\"; a shorter row is blank past its
end.  QUIET, when non-nil, is the number of blank modules drawn on every side;
nil uses four.  Two module rows share one text row through half blocks, and
every glyph keeps pure black on white because a scanner needs that contrast.
The caller owns the rows and nothing here reads a file or the network."
  (unless (and (proper-list-p rows) (cl-every #'stringp rows))
    (signal 'wrong-type-argument (list 'list-of-strings rows)))
  (if (null rows)
      ""
    (let* ((quiet (if (integerp quiet) (max 0 quiet) 4))
           (width (apply #'max (mapcar #'length rows)))
           (margin (make-string quiet ?\s))
           (air (make-list (ceiling quiet 2) (make-string width ?\s)))
           (lines
            (append
             air
             (cl-loop
              for rest on rows by #'cddr
              for upper = (car rest)
              for lower = (cadr rest)
              collect (cl-loop
                       for column below width
                       concat (etaf-ui--qr-glyph
                               (etaf-ui--qr-module-p upper column)
                               (etaf-ui--qr-module-p lower column))))
             air)))
      (mapconcat (lambda (line)
                   (propertize (concat margin line margin)
                               'face etaf-ui--qr-face))
                 lines "\n"))))

(etaf-define-component etaf-ui-qr-login
    (&key open code status (hint "请用手机客户端扫码，并在手机上确认登录。") on-close)
  "Show a scanned-code sign-in panel over the calling application.
The panel composes `etaf-dialog', so the page underneath keeps its content
and only dims, and the panel centers in the application's root canvas.  Mount
it as the last child of the application shell.  The caller owns the request
cycle and the account state; this component sends no request and asks for no
credentials."
  :validate
  (progn
    (etaf-check-prop :open open
                     (or (null open) (eq open t)
                         (etaf-ref-p open) (etaf-computed-p open))
                     "nil, t, a ref or a computed value" 'etaf-ui-qr-login)
    (etaf-check-prop :code code
                     (or (null code) (stringp code)
                         (etaf-ref-p code) (etaf-computed-p code))
                     "nil, a string, a ref or a computed value" 'etaf-ui-qr-login)
    (etaf-check-prop :status status
                     (or (null status) (stringp status)
                         (etaf-ref-p status) (etaf-computed-p status))
                     "nil, a string, a ref or a computed value" 'etaf-ui-qr-login)
    (etaf-check-prop :hint hint (or (null hint) (stringp hint))
                     "a string or nil" 'etaf-ui-qr-login))
  :render
  (when (etaf-ui--reactive-value open)
    (let* ((code-value (etaf-ui--reactive-value code))
           (code (and code-value
                      (not (string-empty-p code-value))
                      code-value))
           (status-value (etaf-ui--reactive-value status))
           (status (and status-value
                        (not (string-empty-p status-value))
                        status-value))
           (hint (and hint (not (string-empty-p hint)) hint))
           (lines (and code (split-string code "\n")))
           (columns (if lines (apply #'max (mapcar #'string-width lines)) 0))
           (wrap (max 1 (+ columns 4)))
           (parts (append (when status
                            (list (max 1 (ceiling (string-width status) wrap))))
                          (when code (list (length lines)))
                          (when hint
                            (list (max 1 (ceiling (string-width hint) wrap))))))
           ;; The dialog's own default caps a modal at 80% of the window, which
           ;; a tall code exceeds; request the height its content needs so the
           ;; status, code, hint and cancel stay together whenever they fit.
           (rows (if parts (+ 5 (1- (length parts)) (apply #'+ parts)) 5))
           (body
            (append
             ;; The status stays above the code: a tall code outgrows the
             ;; dialog's available height, and the transport message is what
             ;; the person scanning needs while the code itself keeps its
             ;; whole extent.
             (when status
               (list (etaf-node 'etaf-label
                                (list :text status :variant 'muted) nil)))
             (when code
               (list (etaf-node 'box
                                (list :class "etaf-qr-code"
                                      :color "#000000"
                                      :background-color "#FFFFFF")
                                (list (etaf-node 'text nil (list code))))))
             (when hint
               (list (etaf-node 'etaf-label
                                (list :text hint :variant 'muted
                                      :wrap-mode 'word :width 'stretch)
                                nil))))))
      (etaf-node
       'etaf-dialog
       (list :open t :title "扫码登录" :close-label "取消" :on-close on-close
             :height (list 'lh rows)
             :width (list 'ch (max 44 (+ columns 8))))
       (list (etaf-node 'column
                        (list :class "etaf-qr-login" :width 'stretch
                              :cross-align 'center :item-gap '(lh 1))
                        body))))))

(provide 'etaf-ui-advanced)
;;; etaf-ui-advanced.el ends here
