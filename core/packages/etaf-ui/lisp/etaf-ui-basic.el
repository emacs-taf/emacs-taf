;;; etaf-ui-basic.el --- Basic reusable ETAF UI Components -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Label, Button, Checkbox, and Panel are the catalog's small semantic
;; building blocks. Compound inputs compose Button through the same contract.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui-style)

(declare-function etaf-ui-icon-lines "etaf-ui" (name &rest options))

(defun etaf-ui--disclosure-label (label direction &optional leading)
  "Return LABEL with a standard-row DIRECTION icon, optionally LEADING."
  (let* ((icon (car (etaf-ui-icon-lines direction :set 'svg :size 0.75)))
         ;; Keep an arrow in copied text and terminals too.  The icon registry's
         ;; ASCII fallback is for standalone icons, not a control's caption.
         (arrow (copy-sequence (pcase direction
                                 ('chevron-right "›")
                                 ('chevron-up "⌃")
                                 (_ "⌄")))))
    (add-text-properties 0 (length arrow) (text-properties-at 0 icon) arrow)
    (if leading (concat arrow " " label) (concat label " " arrow))))

(defvar etaf-ui--unsupplied (make-symbol "unsupplied")
  "Distinguish omitted controlled props from explicitly supplied nil.")

(defun etaf-ui--canvas-cell ()
  "Return (CHAR-WIDTH . LINE-HEIGHT) pixels of the canvas being drawn.
`ch' and `lh' lengths resolve against the canvas's own face, so anything
that turns pixels into cells, or states a pixel size for a cell count, reads
them here instead of the frame: a text scale or a canvas font is a different
cell from the frame's default face, and a size measured with the frame's one
leaves the drawing short of the region it measured.  Outside a mounted canvas
the selected frame's face stands in."
  (let ((metrics (ignore-errors (etaf-display-metrics))))
    (cons (or (plist-get metrics :char-width) (frame-char-width))
          (or (plist-get metrics :line-height) (frame-char-height)))))

(defun etaf-ui--controlled-input (component value-prop bind value on-change)
  "Resolve COMPONENT's BIND or explicit VALUE-PROP and ON-CHANGE.
Return the value source and callback as a cons.  A binding uses the caller's
ref directly; it owns no state or subscription of its own."
  (cl-labels ((invalid (prop received expected)
               (etaf-check-prop prop received nil expected component)))
    (if bind
        (progn
          (unless (etaf-ref-p bind)
            (invalid :bind bind "a writable ETAF ref"))
          (unless (eq value etaf-ui--unsupplied)
            (invalid value-prop value "omission when :bind is supplied"))
          (unless (eq on-change etaf-ui--unsupplied)
            (invalid :on-change on-change "omission when :bind is supplied"))
          (cons bind (lambda (next) (setf (etaf-value bind) next))))
      (unless (or (eq on-change etaf-ui--unsupplied)
                  (null on-change) (functionp on-change))
        (invalid :on-change on-change "a function or nil"))
      (cons (unless (eq value etaf-ui--unsupplied) value)
            (unless (eq on-change etaf-ui--unsupplied) on-change)))))

(defun etaf-ui--class-value (base state custom)
  "Return BASE and STATE classes with optional CUSTOM classes."
  (let ((custom (cond ((null custom) nil)
                      ((listp custom) custom)
                      (t (list custom)))))
    (mapconcat
     (lambda (class) (format "%s" class))
     (cl-remove-if
      (lambda (class) (or (null class) (equal class "")))
      (append (list base state) custom))
     " ")))

(defun etaf-ui--reactive-value (value)
  "Return VALUE, reading it when it is an ETAF reactive source."
  (if (or (etaf-ref-p value) (etaf-computed-p value))
      (etaf-value value)
    value))

(defun etaf-ui--text-value (value)
  "Return VALUE as a Text payload without discarding string properties."
  (setq value (etaf-ui--reactive-value value))
  (cond ((null value) "")
        ((stringp value) value)
        (t (format "%s" value))))

(defun etaf-ui--label-presentation (variant)
  "Return semantic presentation for Label VARIANT."
  (let* ((variant (or variant 'default))
         (color-key
          (pcase variant
            ('muted :ui-muted-fg)
            ('danger :ui-danger-fg)
            ('success :ui-success-fg)
            (_ :ui-fg)))
         (theme (etaf-ui--style-tokens color-key)))
    (list :variant variant
          :color (plist-get theme color-key)
          :font-weight (when (memq variant '(strong heading)) 'bold))))

(etaf-define-component etaf-label (&key text variant)
  "Render TEXT in a semantic Label with ordinary Box layout."
  :view
  (box
   :class (let ((presentation (etaf-ui--label-presentation variant)))
            (etaf-ui--class-value
             "etaf-label"
             (symbol-name (plist-get presentation :variant)) nil))
   :color (plist-get (etaf-ui--label-presentation variant) :color)
   :font-weight
   (plist-get (etaf-ui--label-presentation variant) :font-weight)
   (text (expr (etaf-ui--text-value text)))))

(defun etaf-ui--button-variant-values (variant disabled &optional selected)
  "Return themed defaults for Button VARIANT, DISABLED and SELECTED.
A selected ghost gains the secondary tint without changing its geometry.

Buttons are filled single-row pills: `primary' paints the accent, `secondary'
its soft tint and `ghost' inherits its surface.  Outlines
are omitted because a one-row control cannot pad above or below its text, so
a stroke around it always touches the glyphs.  A disabled button keeps its
variant's footprint so toggling availability never shifts its neighbours:
filled variants dim to the disabled surface, a ghost only dims its text.
A hover fill comes from the variant's hover token; a caller-provided surface
derives its own fill instead of repeating that token."
  (let* ((variant (or variant 'primary))
         (selected-ghost (and selected (eq variant 'ghost)))
         (fg (cond (disabled :ui-disabled-fg)
                   ((or (eq variant 'secondary) selected-ghost) :ui-button-secondary-fg)
                   ((eq variant 'ghost) :ui-button-ghost-fg)
                   (t :ui-button-primary-fg)))
         (bg (cond ((and (eq variant 'ghost) (not selected-ghost)) nil)
                   (disabled :ui-disabled-bg)
                   ((or (eq variant 'secondary) selected-ghost) :ui-button-secondary-bg)
                   (t :ui-button-primary-bg)))
         (hover (cond (disabled nil)
                      ((eq variant 'secondary) :ui-button-secondary-hover-bg)
                      ((eq variant 'ghost) :ui-button-ghost-hover-bg)
                      (t :ui-button-primary-hover-bg)))
         (theme (etaf-ui--style-tokens fg (or bg :ui-disabled-bg)
                                       (or hover :ui-disabled-bg))))
    (list :color (plist-get theme fg)
          :bgcolor (and bg (plist-get theme bg))
          :hover-bg (and hover (plist-get theme hover))
          :border nil
          :padding (if (memq variant '(primary secondary))
                       '((lh 0) (ch 1))
                     '((lh 0) (ch 1)))
          :font-weight (if (or disabled (eq variant 'ghost)) 'normal 'bold))))

(defun etaf-ui--button-hover-bg (variant surface fallback disabled selected)
  "Return the hover fill for VARIANT over SURFACE, or FALLBACK.
A caller-provided #RRGGBB SURFACE derives its own fill: a filled variant
deepens it so light labels stay readable, a tonal or ghost variant shifts it
away from its own lightness.  DISABLED or SELECTED controls do not hover; a
surface in another color spelling falls back to the variant token."
  (cond
   ((or disabled selected) nil)
   ((and (stringp surface) (etaf-ui--color-channels surface))
    (if (eq (or variant 'primary) 'primary)
        (etaf-ui--state-hover-deepen surface)
      (etaf-ui--state-hover-shift surface)))
   (t fallback)))

(etaf-define-component etaf-button
    (&key label on-press disabled id ref class color bgcolor border padding
          font-size font-weight tab-index aria-label aria-selected help-echo
          hover-content pointer hover-group use variant)
  "Render a standard pressable Button with a committed callback.

DISABLED removes the callback and default focus tab index.  Presentation props
remain caller-overridable.  ID reaches the rendered Host so anchor-based
surfaces can reference the Button by identity.  Runtime publishes ON-PRESS with
the visible Button, so a failed render keeps the previous callback and its
captured values."
  :render
  (let* ((label (etaf-ui--text-value label))
         (variant-values (etaf-ui--button-variant-values variant disabled aria-selected))
         (surface (etaf-ui--reactive-value bgcolor))
         (hover-bg (etaf-ui--button-hover-bg
                    variant surface (plist-get variant-values :hover-bg)
                    disabled (and aria-selected t))))
    (etaf-node
     'box
     (append
      (list
       :class (etaf-ui--class-value
               "etaf-button"
               (if disabled "disabled" "enabled")
               (cons (symbol-name (or variant 'primary))
                     (cond ((null class) nil)
                           ((listp class) class)
                           (t (list class)))))
       :ref ref :role 'button :disabled disabled
       :tab-index (unless disabled (or tab-index 0))
       :aria-label (or aria-label label)
       :aria-selected (and aria-selected t)
       :help-echo help-echo
       :pointer (or pointer (and (not disabled) 'arrow))
       :color (or color (plist-get variant-values :color))
       :background-color (or bgcolor (plist-get variant-values :bgcolor))
       :hover-style (when hover-bg (list :background-color hover-bg))
       :border (or border (etaf-theme-token :ui-button-border
                                            (plist-get variant-values :border)))
       :border-radius (etaf-theme-token :ui-button-radius '(px 0))
       :padding (or padding (etaf-theme-token :ui-button-padding
                                              (plist-get variant-values :padding)))
       :font-size font-size
       :font-weight (or font-weight (plist-get variant-values :font-weight))
       :use use
       :on-press (and (not disabled) on-press))
      (append
       (when id (list :id id))
       (when hover-content (list :hover-content hover-content))
       (when hover-group (list :hover-group hover-group))))
     (or (etaf-current-slot 'default)
         (list (etaf-node 'text nil (list label))))))
  :styles
  (("&" :width max-content :flex-shrink 0)
   ("&.disabled" :font-weight normal)
   ;; Keyboard focus must stay visible without moving geometry, and it paints
   ;; the same kind of change as hover: a fill.  A rule may change only the
   ;; background; a label keeps its own ink, weight and decoration in every
   ;; state, so no state adds an underline.
   ("&:focus"
    :background-color (etaf-theme-token :ui-button-ghost-hover-bg
                                        (etaf-theme-token :ui-bg "#FFFDF8"
                                                          etaf-ui--state-hover-shift)))))

(defun etaf-ui--checkbox-variant-values (disabled)
  "Return semantic Theme presentation for a DISABLED Checkbox.
The row inherits its surface; only the mark carries the accent, so a
checkbox reads as a labelled control rather than a boxed field."
  (let* ((prefix (if disabled "disabled" "enabled"))
         (fg (intern (format ":ui-checkbox-%s-fg" prefix)))
         (mark (if disabled :ui-disabled-fg :ui-button-secondary-fg))
         (theme (etaf-ui--style-tokens fg mark)))
    (list :color (plist-get theme fg)
          :mark-color (plist-get theme mark)
          :bgcolor nil
          :border nil)))

(etaf-define-component etaf-checkbox
    (&key (checked etaf-ui--unsupplied) label
          (on-change etaf-ui--unsupplied) disabled bind)
  "Render a controlled Checkbox using CHECKED/ON-CHANGE or writable ref BIND.
Non-nil BIND cannot be combined with explicit CHECKED or ON-CHANGE, even nil."
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-checkbox :checked bind checked on-change))
         (checked (car input))
         (on-change (cdr input)))
    (etaf-view
     (row
      :class (etaf-ui--class-value
              "etaf-checkbox" (if disabled "disabled" "enabled") nil)
      :role 'checkbox :disabled disabled
      :aria-label (etaf-ui--text-value label)
      :tab-index (unless disabled 0)
      :color (plist-get (etaf-ui--checkbox-variant-values disabled) :color)
      :background-color
      (plist-get (etaf-ui--checkbox-variant-values disabled) :bgcolor)
      :border (plist-get (etaf-ui--checkbox-variant-values disabled) :border)
      :on-press
      (and (not disabled) on-change
           (let ((callback on-change)
                 (source checked))
             (lambda ()
               (funcall callback (not (etaf-ui--reactive-value source))))))
      (box :class "etaf-checkbox-mark"
           :color (plist-get (etaf-ui--checkbox-variant-values disabled) :mark-color)
           (text (expr (if (etaf-ui--reactive-value checked) "[x]" "[ ]"))))
      (text (expr
             (let ((value (etaf-ui--text-value label)))
               (if (string-empty-p value) "" (concat " " value))))))))
  :styles
  (("&" :width max-content)
   ("&.disabled" :padding ((lh 0) (ch 0)))
   ("&.enabled" :padding ((lh 0) (ch 0)))
   (".etaf-checkbox-mark" :font-weight bold :width (ch 3))))

(etaf-define-component etaf-panel (&key title variant)
  "Render a titled Panel with named header and default slots."
  :render
  (let ((theme (etaf-ui--style-tokens
                :ui-panel-fg :ui-panel-bg :ui-panel-border)))
    (etaf-node
     'column
     (list :class (etaf-ui--class-value
                   "etaf-panel" (symbol-name (or variant 'default)) nil)
           :color (plist-get theme :ui-panel-fg)
           :background-color
           (unless (eq variant 'flat) (plist-get theme :ui-panel-bg))
           :border
           (unless (eq variant 'flat)
             (etaf-ui--style-border (plist-get theme :ui-panel-border)))
           :item-gap '(lh 1))
     (append
      (when title
        (list (etaf-node
               'etaf-label
               (list :class "etaf-panel-title" :text title :variant 'strong)
               nil)))
      (etaf-current-slot 'header)
      (etaf-current-slot 'default))))
  :styles
  (("&" :padding ((lh 1) (ch 2)))
   (".etaf-panel-title" :font-weight bold)))

(provide 'etaf-ui-basic)
;;; etaf-ui-basic.el ends here
