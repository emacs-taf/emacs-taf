;;; etaf-ui-selection.el --- Selection and value controls -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Selection controls are controlled Components.  They compose Button and
;; preserve the same VALUE/ON-CHANGE or writable REF contract as Checkbox.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui-basic)

(defun etaf-ui--selection-options (options component)
  "Validate alist OPTIONS for COMPONENT and return it unchanged."
  (etaf-check-prop :options options (and (proper-list-p options) options)
                   "a nonempty alist of scalar values and labels" component)
  (let (values labels)
    (dolist (option options)
      (etaf-check-prop :options option
                       (and (consp option)
                            (or (symbolp (car option))
                                (numberp (car option))
                                (stringp (car option)))
                            (stringp (cdr option))
                            (not (string-empty-p (cdr option)))
                            (not (member (car option) values))
                            (not (member (cdr option) labels)))
                       "an alist with unique scalar values and labels" component)
      (push (car option) values)
      (push (cdr option) labels)))
  options)

(defun etaf-ui--selection-colors (selected disabled)
  "Return (FG BG BORDER) for SELECTED and DISABLED selection controls.
Selection controls are tonal pills like Buttons: a selected control paints
the secondary button tint, an unselected one inherits its surface, and no
control carries an outline.  The secondary tokens are dialog tokens, so a
selected control stays crisp inside a modal above a dimmed shell."
  (let* ((fg (cond (disabled :ui-disabled-fg)
                   (selected :ui-button-secondary-fg)
                   (t :ui-fg)))
         (bg (cond (disabled :ui-disabled-bg)
                   (selected :ui-button-secondary-bg)))
         (theme (etaf-ui--style-tokens fg (or bg :ui-disabled-bg))))
    (list (plist-get theme fg) (and bg (plist-get theme bg)) nil)))

(etaf-define-component etaf-radio
    (&key (value etaf-ui--unsupplied) options (label "Choice")
          (on-change etaf-ui--unsupplied) disabled bind)
  "Render a controlled single-choice RADIO group.
OPTIONS is an alist of unique scalar values and labels.  VALUE/ON-CHANGE or
the writable BIND ref owns the selected value; the Component owns no state."
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-radio :value bind value on-change))
         (current (etaf-ui--reactive-value (car input)))
         (callback (cdr input)))
    (etaf-ui--selection-options options 'etaf-radio)
    (etaf-check-prop :label label (stringp label) "a string" 'etaf-radio)
    (etaf-check-prop :value current
                     (or (null current) (assoc current options))
                     "nil or a value in :options" 'etaf-radio)
    (etaf-view
     (column :class "etaf-radio-group" :role 'radiogroup :width 'stretch
       (etaf-label :text label :variant 'strong)
       (row :item-gap '(ch 1) :focus-group 'horizontal
         (expr
          (mapcar
           (lambda (option)
             (let* ((key (car option))
                    (caption (cdr option))
                    (selected (equal key current))
                    (colors (etaf-ui--selection-colors selected disabled)))
               (etaf-view
                (etaf-button
                 :label (concat (if selected "(o) " "( ) ") caption)
                 :aria-label caption :aria-checked selected
                 :variant 'ghost :disabled disabled
                 :color (nth 0 colors) :bgcolor (nth 1 colors)
                 :border (nth 2 colors)
                 :on-press (and (not disabled) callback
                                (lambda () (funcall callback key)))))))
           options)))))))

(etaf-define-component etaf-switch
    (&key (checked etaf-ui--unsupplied) (label "Switch")
          (on-change etaf-ui--unsupplied) disabled bind)
  "Render a controlled binary SWITCH using CHECKED/ON-CHANGE or BIND."
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-switch :checked bind checked on-change))
         (current (etaf-ui--reactive-value (car input)))
         (callback (cdr input))
         (colors (etaf-ui--selection-colors current disabled)))
    (etaf-check-prop :checked current (booleanp current) "a boolean" 'etaf-switch)
    (etaf-check-prop :label label (stringp label) "a string" 'etaf-switch)
    (etaf-view
     (etaf-button
      :label (format "%s %s" (if current "[x]" "[ ]") label)
      :aria-label label :variant 'ghost :disabled disabled
      :color (nth 0 colors) :bgcolor (nth 1 colors) :border (nth 2 colors)
      :on-press (and (not disabled) callback
                     (lambda () (funcall callback (not current))))))))

(etaf-define-component etaf-segmented
    (&key (value etaf-ui--unsupplied) options (on-change etaf-ui--unsupplied)
          disabled bind)
  "Render a compact controlled SEGMENTED selector from OPTIONS."
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-segmented :value bind value on-change))
         (current (etaf-ui--reactive-value (car input)))
         (callback (cdr input)))
    (etaf-ui--selection-options options 'etaf-segmented)
    (etaf-check-prop :value current
                     (or (null current) (assoc current options))
                     "nil or a value in :options" 'etaf-segmented)
    (etaf-view
     (row :class "etaf-segmented" :role 'tablist :item-gap '(ch 2)
          :focus-group 'horizontal
       (expr
        (mapcar
         (lambda (option)
           (let* ((key (car option)) (caption (cdr option))
                  (selected (equal key current)))
             (etaf-view
              ;; Selection changes the ghost's paint, not its padding or font.
              (etaf-button :label caption
                           :aria-label caption :aria-selected selected
                           :variant 'ghost
                           :disabled disabled
                           :on-press (and (not disabled) callback
                                          (lambda () (funcall callback key)))))))
         options))))))

(etaf-define-component etaf-slider
    (&key (value etaf-ui--unsupplied) (min 0) (max 100) (step 1)
          (label "Value") (on-change etaf-ui--unsupplied) disabled bind)
  "Render a controlled numeric SLIDER using the native number prompt.
VALUE must be an integer in MIN..MAX; STEP is a positive integer.  The
native prompt keeps editing accessible while the Component remains reusable;
Left and Right change the focused slider by STEP, stopping at MIN and the
largest STEP-aligned value not greater than MAX.  MAX need not be aligned."
  :validate
  (progn
    (etaf-check-prop :min min (integerp min) "an integer" 'etaf-slider)
    (etaf-check-prop :max max (and (integerp max) (<= min max))
                     "an integer greater than or equal to :min" 'etaf-slider)
    (etaf-check-prop :step step (and (integerp step) (> step 0))
                     "a positive integer" 'etaf-slider)
    (etaf-check-prop :label label (stringp label) "a string" 'etaf-slider))
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-slider :value bind value on-change))
         (current (etaf-ui--reactive-value (car input)))
         (callback (cdr input))
         (last-value (- max (% (- max min) step))))
    (etaf-check-prop :value current
                     (and (integerp current) (<= min current max)
                          (zerop (% (- current min) step)))
                     "an integer aligned to :step within :min..:max" 'etaf-slider)
    (etaf-view
     (column :class "etaf-slider" :width 'stretch
       (row :item-gap '(ch 1)
         (etaf-label :text label :variant 'strong)
         (etaf-label :text (format "%d" current) :variant 'muted))
       (etaf-button :label (format "◀  %d  ▶" current) :variant 'secondary
                    :disabled disabled :aria-label label
                    :on-direction
                    (and (not disabled) callback
                         (lambda (direction)
                           (pcase direction
                             ('left (funcall callback (max min (- current step))) 'handled)
                             ('right (funcall callback (min last-value (+ current step))) 'handled)
                             (_ 'release))))
                    :on-press
                    (and (not disabled) callback
                         (lambda ()
                           (let ((next (etaf-call-with-input
                                        (lambda ()
                                          (read-number (format "%s (%d-%d): " label min max)
                                                       current)))))
                             (unless (and (integerp next) (<= min next max)
                                          (zerop (% (- next min) step)))
                               (user-error "%s must be aligned to %d from %d to %d"
                                           label step min max))
                             (funcall callback next)))))))))

;;; ---------------------------------------------------------------------------
;;; Range
;;; ---------------------------------------------------------------------------

(defun etaf-ui--range-ratio-at-gesture (gesture track)
  "Return the pointer's fraction along GESTURE's TRACK Host, or nil.
TRACK names the measured Host; GESTURE's own :host-ref is used when TRACK is
nil."
  (let* ((window (plist-get gesture :window))
         (buffer (or (plist-get gesture :buffer)
                     (and (window-live-p window) (window-buffer window))))
         (host (or track (plist-get gesture :host-ref)))
         (xy (plist-get gesture :position))
         (runtime (and buffer (etaf-runtime-for-buffer buffer)))
         (bounds (and runtime host (etaf-host-ref-bounds runtime host))))
    (when (and bounds (consp xy) (numberp (car xy)))
      (with-current-buffer buffer
        (let* ((start (car bounds))
               (end (cdr bounds))
               (origin (save-excursion (goto-char start) (line-beginning-position)))
               (left (etaf-string-pixel-width (buffer-substring origin start)))
               (width (etaf-string-pixel-width (buffer-substring start end))))
          (when (> width 0)
            (max 0.0 (min 1.0 (/ (- (float (car xy)) left) width)))))))))

(defun etaf-ui--range-bound-p (value)
  "Return non-nil when VALUE is a static number or a reactive range bound."
  (or (numberp value) (etaf-ref-p value) (etaf-computed-p value)))

(defun etaf-ui--range-live-bounds (min max)
  "Read and validate MIN and MAX at their retained consumer boundary."
  (let ((low (etaf-ui--reactive-value min))
        (high (etaf-ui--reactive-value max)))
    ;; A source may be pending (nil) until backend metadata arrives; the
    ;; Fill already paints an empty span for that state.
    (etaf-check-prop :min low (or (null low) (numberp low))
                     "a number or pending nil" 'etaf-range)
    (etaf-check-prop :max high (or (null high) (numberp high))
                     "a number or pending nil" 'etaf-range)
    (when (and (numberp low) (numberp high))
      (etaf-check-prop :max high (>= high low)
                       "greater than or equal to :min" 'etaf-range))
    (cons low high)))

(defun etaf-ui--range-value-at-ratio (ratio min max step)
  "Return RATIO of the MIN..MAX span clamped to the bounds and snapped to STEP."
  (let ((clamped (max min (min max (+ min (* ratio (- max min)))))))
    (if (null step)
        clamped
      (let ((snapped (+ min (* step (fround (/ (- clamped min) (float step)))))))
        (max min (min max (if (and (integerp min) (integerp max) (integerp step))
                              (round snapped)
                            snapped)))))))

(etaf-define-component etaf-range
    (&key value (min 0) (max 100) step key-step on-change on-commit disabled
          color track-color (bar-height 40)
          label ref fill-ref)
  "Render an interactive horizontal RANGE: progress, seek or volume bar.

VALUE is a number or reactive source within MIN..MAX, and is snapped to STEP
when STEP is non-nil.  The range is controlled: it never stores the value.
A pointer click reports the pointed value through ON-CHANGE and ON-COMMIT;
dragging reports intermediate values through ON-CHANGE and the released value
through ON-COMMIT.  Both callbacks receive one number.

The bar is a track with an accent Fill overlay: the fill is an absolutely
positioned Host painted above the track, so the split is visible in every
context, and the track gives the row its measurable width.  FILL-REF names that
Fill Host (its `:id` mirrors the name); a caller may move it with
`etaf-runtime-update-host-geometries' and a `:width' percentage without
republishing the View, which is how a playing position advances in place.  A
press or drag re-proportions the two parts through retained Host geometry
before the caller's value arrives, so the gesture still follows the pointer
while a backend reply is pending.  BAR-HEIGHT is the painted thickness as a
percentage of the standard row (default 40), centered and rounded to at
least one pixel.  Graphical frames with SVG support paint this thickness;
text-only frames keep a thin rule.  The hit target stays one full row.

Left and Right on the focused range report the value moved by KEY-STEP
through ON-CHANGE and ON-COMMIT; Home and End report MIN and MAX.  KEY-STEP
defaults to STEP, else a twentieth of the span."
  :validate
  (progn
    (etaf-check-prop :min min (etaf-ui--range-bound-p min) "a number or reactive source" 'etaf-range)
    (etaf-check-prop :max max (etaf-ui--range-bound-p max)
                     "a number or reactive source" 'etaf-range)
    ;; Reactive bounds belong to the retained Fill getter.  Reading them in
    ;; input validation subscribes the Component input even though its props
    ;; retain the same source identities, re-running the Component's input on
    ;; every bound change.
    (when (and (numberp min) (numberp max))
      (etaf-check-prop :max max (>= max min)
                       "greater than or equal to :min" 'etaf-range))
    (etaf-check-prop :step step (or (null step) (and (numberp step) (> step 0)))
                     "a positive number or nil" 'etaf-range)
    (etaf-check-prop :key-step key-step
                     (or (null key-step) (and (numberp key-step) (> key-step 0)))
                     "a positive number or nil" 'etaf-range)
    (etaf-check-prop :bar-height bar-height (and (integerp bar-height) (> bar-height 0)
                                                  (<= bar-height 100))
                     "an integer percentage from 1 through 100" 'etaf-range)
    (etaf-check-prop :on-change on-change (or (null on-change) (functionp on-change))
                     "a function or nil" 'etaf-range)
    (etaf-check-prop :on-commit on-commit (or (null on-commit) (functionp on-commit))
                     "a function or nil" 'etaf-range)
    (etaf-check-prop :disabled disabled (booleanp disabled) "a boolean" 'etaf-range))
  :bindings ((drag (etaf-ref nil))
             (fill-target (or fill-ref (gensym "etaf-range-fill-")))
             ;; The track is measured for hit-testing, so it always has a ref.
             (track-target (or ref (gensym "etaf-range-track-"))))
  :render
  (let* ((rule
          (if (and (display-graphic-p) (image-type-available-p 'svg))
              (let* (;; The canvas only needs to cover the live viewport.
                     ;; A long text rule converted to one huge SVG can exceed
                     ;; native image limits when its frame becomes compact.
                     (width (max 1 (ceiling (or (car (etaf-viewport))
                                                (frame-pixel-width)))))
                     (height (cdr (etaf-ui--canvas-cell)))
                     (ink (max 1 (round (* height (/ bar-height 100.0)))))
                     (image
                      (create-image
                       (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><rect y='%d' width='%d' height='%d' fill='currentColor'/></svg>"
                               width height (/ (- height ink) 2) width ink)
                       'svg t :ascent 'center :scale 1)))
                (propertize " " 'display (list (list 'slice 0 0 width height) image)))
            (make-string 512 ?─)))
         ;; Read controlled/drag sources inside the Host getter, not the
         ;; Component render. A pointer move then changes only Fill geometry.
         ;; MIN and MAX follow the same contract: a reactive bound keeps a
         ;; duration change on the retained width binding instead of
         ;; subscribing this Component to the source.
         (filled (lambda ()
                   (let* ((raw (etaf-ui--reactive-value value))
                          (bounds (etaf-ui--range-live-bounds min max))
                          (low (car bounds))
                          (high (cdr bounds))
                          (span (and (numberp low) (numberp high) (- high low)))
                          (base (if (and (numberp raw) span (> span 0))
                                    (max 0.0 (min 1.0 (/ (float (- raw low)) span)))
                                  0.0))
                          (live (etaf-value drag)))
                     (list '% (* 100.0 (if (and live (equal (cdr live) raw)) (car live) base))))))
         (report (lambda (gesture commit)
                   (when-let* ((ratio (etaf-ui--range-ratio-at-gesture gesture track-target)))
                     (let* ((raw (etaf-ui--reactive-value value))
                            (bounds (etaf-ui--range-live-bounds min max))
                            (low (car bounds))
                            (high (cdr bounds))
                            (next (and (numberp low) (numberp high)
                                       (etaf-ui--range-value-at-ratio ratio low high step)))
                            (live (cons ratio raw)))
                       ;; Preview and authoritative value changes share the
                       ;; same retained Fill binding and atomic commit.
                       (unless (equal (etaf-value drag) live)
                         (etaf-set-value drag live))
                       (if commit
                           (when (and next on-commit) (funcall on-commit next))
                         (when (and next on-change) (funcall on-change next)))))))
         (key-report
          (lambda (move)
            (lambda ()
              (let* ((bounds (etaf-ui--range-live-bounds min max))
                     (low (car bounds))
                     (high (cdr bounds))
                     (raw (etaf-ui--reactive-value value)))
                (when (and (numberp low) (numberp high))
                  (let* ((amount (or key-step step (/ (- high low) 20.0)))
                         (current (if (numberp raw) raw low))
                         (next (pcase move
                                 ('min low)
                                 ('max high)
                                 (_ (max low (min high (+ current (* move amount))))))))
                    ;; Integer bounds and steps keep integer values.
                    (when (and (integerp low) (integerp high)
                               (not (floatp step)) (not (floatp key-step)))
                      (setq next (round next)))
                    (when on-change (funcall on-change next))
                    (when on-commit (funcall on-commit next))))))))
         (keys (unless disabled
                 (list (list "<home>" (funcall key-report 'min) "Minimum")
                       (list "<end>" (funcall key-report 'max) "Maximum"))))
         (direction (unless disabled
                      (lambda (direction)
                        (pcase direction
                          ('left (funcall (funcall key-report -1)) 'handled)
                          ('right (funcall (funcall key-report 1)) 'handled)
                          (_ 'release))))))
    (etaf-view
     (flex :flex-direction 'row :class "etaf-range" :width 'stretch :height '(lh 1)
          :position 'relative :z-index 0 :overflow 'hidden
          :role 'slider :tab-index (unless disabled 0)
          :aria-orientation 'horizontal :keys keys :on-direction direction
          :aria-label (or label "Range")
          :disabled disabled
          :pointer 'hand
          :on-press (and (not disabled)
                         ;; Keyboard activation carries no pointer gesture.
                         (lambda (&optional gesture)
                           (when gesture
                             (funcall report gesture nil)
                             (funcall report gesture t))))
          :on-drag (and (not disabled)
                        (lambda (gesture)
                          ;; Keyboard steps carry relative deltas, not a
                          ;; pointer position; the range's own keys own them.
                          (unless (plist-get gesture :keyboard)
                            (funcall report gesture (eq (plist-get gesture :phase) 'end)))))
          :ref track-target :id (symbol-name track-target)
       ;; A one-row image keeps the bar's ink independent of font glyphs.
       ;; Keep the rule in the line until box composition clips its image
       ;; slice; overflow hidden on this text box would drop the whole glyph.
       ;; The flow track keeps the entire row measurable for hit-testing.
       (box :height '(lh 1) :wrap-mode 'none :flex-grow 1 :flex-basis '(px 0)
            :min-width '(px 0)
            :color (or track-color (etaf-theme-token :ui-range-track "#C9CED6"))
         (text (expr rule)))
       ;; The fill paints above the track and moves through its retained
       ;; geometry, so a playing second or a drag step resizes one Host
       ;; instead of publishing a new View.
       (box :position 'absolute :z-index 0 :left '(px 0) :top '(lh 0)
            :width (funcall filled) :height '(lh 1) :wrap-mode 'none
            :color (or color (etaf-theme-token :ui-range-fill "#D8232A"))
            :ref fill-target :id (symbol-name fill-target)
         (text (expr rule)))))))

(cl-defun etaf-toggle-strip (&key options value on-change theme label surface)
  "Return OPTIONS as a one-row toggle, a propertized string.
OPTIONS is a nonempty alist of at least two unique scalar values and nonempty
labels.  VALUE is the selected value; ON-CHANGE, when non-nil, is called with
the value of the clicked segment.  THEME is a token plist that supplies
`:ui-panel-fg', `:ui-panel-border', `:ui-accent' and `:ui-accent-fg'.

The result is a control for a text row, such as a header line or a mode line,
where a Component cannot mount.  The segments sit in one rectangle: the whole
strip carries a single one-pixel outline, the selected segment paints the
accent behind its label, and the remaining segments keep the row's surface, so
a two-way and a three-way choice read alike.  Every segment is the same number
of columns wide, which keeps the outline and the labels aligned whatever the
caption lengths are.  LABEL, when non-nil, is painted before the strip in the
muted colour.  SURFACE is the row's own background behind an unselected
segment; nil keeps the Theme's panel surface."
  (etaf-ui--selection-options options 'etaf-toggle-strip)
  (etaf-check-prop :theme theme
                   (and (listp theme) (plist-get theme :ui-panel-border))
                   "a token plist with :ui-panel-border" 'etaf-toggle-strip)
  (etaf-check-prop :value value
                   (or (null value) (assoc value options))
                   "nil or a value in :options" 'etaf-toggle-strip)
  (when on-change
    (etaf-check-prop :on-change on-change (functionp on-change)
                     "a function" 'etaf-toggle-strip))
  (let* ((cells (max 3 (apply #'max
                              (mapcar (lambda (option)
                                        (+ 2 (string-width (cdr option))))
                                      options))))
         (border (plist-get theme :ui-panel-border))
         (fg (plist-get theme :ui-panel-fg))
         (accent (plist-get theme :ui-accent))
         (accent-fg (plist-get theme :ui-accent-fg))
         (outline (list :box (list :line-width 1 :color border)))
         pieces)
    (dolist (option options)
      (let* ((key (car option))
             (caption (cdr option))
             (selected (equal key value))
             (padding (- cells (string-width caption)))
             (left (/ padding 2))
             (right (- padding left))
             (map (make-sparse-keymap))
             (text (concat (make-string left ?\s) caption
                           (make-string right ?\s)))
             (press (lambda ()
                      (interactive)
                      (when on-change (funcall on-change key)))))
        (define-key map [header-line mouse-1] press)
        (define-key map [mode-line mouse-1] press)
        (define-key map [mouse-1] press)
        ;; Each segment owns its outline: three boxes side by side read as
        ;; three buttons, and the shared edge is what separates them.
        (push (append
               (list text
                     'face (append (list :background (if selected accent
                                                       (or surface
                                                           (plist-get theme :ui-panel-bg)))
                                         :foreground (if selected accent-fg fg)
                                         :weight (if selected 'bold 'normal)
                                         ;; A theme may invert its header line;
                                         ;; the segment keeps its own paint.
                                         :inverse-video nil)
                                   outline))
               ;; States do not stack: the selected segment already paints the
               ;; accent, so pointer hover belongs to the other segments only.
               (unless selected
                 (list 'mouse-face
                       (list :background (or (plist-get theme :ui-accent-soft-bg)
                                             (plist-get theme :ui-panel-bg)))))
               (list 'keymap map
                     'help-echo (format "%s" caption)))
              pieces)))
    (concat (when label
              (concat (propertize label
                                  'face (list :foreground
                                              (plist-get theme :ui-muted-fg)))
                      "  "))
            (apply #'concat
                   (mapcar (lambda (piece)
                             (apply #'propertize piece))
                           (nreverse pieces))))))

(provide 'etaf-ui-selection)
;;; etaf-ui-selection.el ends here
