;;; etaf-ui-feedback.el --- Status and feedback ETAF Components -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Presentational Components share semantic Theme tokens and caller-owned values.

;;; Code:
(require 'cl-lib)
(require 'etaf-ui-basic)

(declare-function etaf-ui-icon-lines "etaf-ui" (name &rest options))

(defun etaf-ui--feedback-keys (variant)
  "Return foreground, background and border palette keys for VARIANT."
  (pcase variant
    ('success '(:ui-success-fg :ui-success-bg :ui-success-border))
    ('warning '(:ui-warning-fg :ui-warning-bg :ui-warning-border))
    ('danger '(:ui-danger-fg :ui-danger-bg :ui-danger-border))
    ('info '(:ui-info-fg :ui-info-bg :ui-info-border))
    (_ '(:ui-fg :ui-bg :ui-border))))

(defun etaf-ui--feedback-theme (variant)
  "Return foreground, background and border tokens for VARIANT."
  (mapcar (lambda (key) (etaf-theme-token key (plist-get etaf-ui--style-palette key)))
          (etaf-ui--feedback-keys variant)))

(etaf-define-component etaf-badge (&key text (variant 'neutral))
  "Render compact TEXT status with semantic VARIANT styling."
  :render
  (let ((theme (etaf-ui--feedback-theme variant)))
    (etaf-view
     (box :class "etaf-badge" :role 'status :width 'max-content
          :padding-inline '(ch 1) :font-weight 'bold
          :color (nth 0 theme) :background-color (nth 1 theme)
       (text (expr (etaf-ui--text-value text)))))))

(etaf-define-component etaf-divider (&key (orientation 'horizontal) label)
  "Render a horizontal or vertical separator with optional horizontal LABEL."
  :validate
  (etaf-check-prop :orientation orientation (memq orientation '(horizontal vertical))
                   "horizontal or vertical" 'etaf-divider)
  :render
  (if (eq orientation 'vertical)
      (etaf-view
       (box :class "etaf-divider" :width '(px 1) :height 'stretch
            :background-color (etaf-theme-token :ui-border "#687386")))
    (etaf-view
     (flex :class "etaf-divider" :width 'stretch :align-items 'center
           :column-gap (when label '(ch 1))
       (box :flex-grow 1 :flex-basis '(px 0) :min-width '(px 0)
            :height '(lh 1) :border-bottom
            (etaf-ui--style-border (etaf-theme-token :ui-border "#687386")))
       (expr (when label (etaf-view (etaf-label :text label :variant 'muted))))
       (box :flex-grow 1 :flex-basis '(px 0) :min-width '(px 0)
            :height '(lh 1) :border-bottom
            (etaf-ui--style-border (etaf-theme-token :ui-border "#687386")))))))

(defun etaf-ui--progress-percent (value max)
  "Validate reactive VALUE and MAX and return percentage in [0.0, 100.0]."
  (let ((current (etaf-ui--reactive-value value))
        (limit (etaf-ui--reactive-value max)))
    (etaf-check-prop :max limit (and (numberp limit) (> limit 0))
                     "a positive number" 'etaf-progress)
    (etaf-check-prop :value current (and (numberp current) (<= 0 current limit))
                     "a number from zero through :max" 'etaf-progress)
    (/ (* 100.0 current) limit)))

(etaf-define-component etaf-ui--animated-progress (&key value max label variant)
  "Render a progress bar whose fill follows VALUE smoothly on the shared clock."
  :bindings
  ((value-prop (etaf-prop :value))
   (max-prop (etaf-prop :max))
   (shown (etaf-transition
           (lambda ()
             (etaf-ui--progress-percent (etaf-value value-prop)
                                        (etaf-value max-prop)))
           :duration 0.22 :easing 'ease-out
           :name 'etaf-progress)))
  :render
  (let* ((theme (etaf-ui--feedback-theme variant))
         (percent (max 0.0 (min 100.0 (etaf-animation-quantize
                                       (etaf-value shown) 0.5))))
         (rounded (round percent)))
    (ignore value max)
    (etaf-view
     (column :class "etaf-progress" :width 'stretch
       (row :item-gap '(ch 1)
         (etaf-label :text label :variant 'strong)
         (etaf-label :text (format "%d%%" rounded) :variant 'muted))
       (box :width 'stretch :height '(lh 1)
            :background-color (etaf-theme-token :ui-progress-track "#E2E8F0")
         (box :width (list '% percent) :height '(lh 1)
              :background-color (nth 0 theme)))))))

(etaf-define-component etaf-progress
    (&key value (max 100) label (variant 'success) animated)
  "Render VALUE out of positive MAX; both accept numbers or reactive values."
  :render
  (if animated
      (progn
        (etaf-ui--progress-percent value max)
        (etaf-view
         (etaf-ui--animated-progress
          :value value :max max :label label :variant variant)))
    (let* ((percent (round (etaf-ui--progress-percent value max)))
           (theme (etaf-ui--feedback-theme variant)))
      (etaf-view
       (column :class "etaf-progress" :width 'stretch
         (row :item-gap '(ch 1)
           (etaf-label :text label :variant 'strong)
           (etaf-label :text (format "%d%%" percent) :variant 'muted))
         (box :width 'stretch :height '(lh 1)
              :background-color (etaf-theme-token :ui-progress-track "#E2E8F0")
           (box :width (list '% percent) :height '(lh 1)
                :background-color (nth 0 theme))))))))

(etaf-define-component etaf-alert
    (&key title message (variant 'info) dismissible on-dismiss)
  "Render status text; DISMISSIBLE invokes caller-owned ON-DISMISS."
  :validate
  (progn
    (etaf-check-prop :title title (or (null title) (stringp title))
                     "a string or nil" 'etaf-alert)
    (etaf-check-prop :on-dismiss on-dismiss (or (not dismissible) (functionp on-dismiss))
                     "a function when dismissible" 'etaf-alert))
  :render
  (let ((theme (etaf-ui--feedback-theme variant)))
    (etaf-view
     (flex :class "etaf-alert" :width 'stretch :role 'alert
           :padding '((lh 1) (ch 2)) :column-gap '(ch 1)
           :color (nth 0 theme) :background-color (nth 1 theme)
       (column :flex-grow 1 :min-width '(px 0)
         (etaf-label :text title :variant 'strong :color (nth 0 theme))
         (etaf-label :text message :color (nth 0 theme) :wrap-mode 'word))
       (expr
        (when dismissible
          (etaf-view
           (etaf-button :label "×" :variant 'ghost :aria-label "Dismiss"
                        :on-press on-dismiss))))))))

(defun etaf-ui--statistic-format (current target)
  "Format animated numeric CURRENT matching integer or float shape of TARGET."
  (if (not (numberp current))
      (etaf-ui--text-value current)
    (if (integerp target)
        (number-to-string (round current))
      (format "%.1f" (float current)))))

(etaf-define-component etaf-ui--animated-statistic (&key label value trend)
  "Render a metric card whose numeric VALUE rolls smoothly on the shared clock."
  :bindings
  ((value-prop (etaf-prop :value))
   (shown (etaf-transition
           (lambda () (etaf-ui--reactive-value (etaf-value value-prop)))
           :duration 0.28 :easing 'ease-out
           :name 'etaf-statistic)))
  :render
  (let* ((muted (etaf-theme-token :ui-muted-fg "#687386"))
         (target (etaf-ui--reactive-value value))
         (display (if (numberp target)
                      (etaf-ui--statistic-format (etaf-value shown) target)
                    (etaf-ui--text-value target))))
    (etaf-view
     (column :class "etaf-statistic" :width 'stretch
             :item-gap '(lh 0)
             :padding '((lh 1) (ch 2))
             :background-color (etaf-theme-token :ui-panel-bg "#F6F7F9")
             :border (etaf-ui--style-border
                      (etaf-theme-token :ui-panel-border "#D9DDE3"))
       (etaf-label :text label :variant 'muted)
       (text :font-weight 'bold :color muted (expr display))
       (expr (when trend
               (etaf-view (etaf-label :text trend :variant 'success))))))))

(etaf-define-component etaf-statistic (&key label value trend animated)
  "Render a metric as a small panel: a muted caption, the figure, a trend.
The panel owns its surface and spacing so a row of metrics lines up; the
caller decides the width."
  :validate
  (etaf-check-prop :trend trend (or (null trend) (stringp trend))
                   "a string or nil" 'etaf-statistic)
  :render
  (if animated
      (etaf-view
       (etaf-ui--animated-statistic :label label :value value :trend trend))
    (let ((muted (etaf-theme-token :ui-muted-fg "#687386")))
      (etaf-view
       (column :class "etaf-statistic" :width 'stretch
               :item-gap '(lh 0)
               :padding '((lh 1) (ch 2))
               :background-color (etaf-theme-token :ui-panel-bg "#F6F7F9")
               :border (etaf-ui--style-border
                        (etaf-theme-token :ui-panel-border "#D9DDE3"))
         (etaf-label :text label :variant 'muted)
         (text :font-weight 'bold :color muted
           ;; A reactive value reads like a Label text; a source object would
           ;; reach the Text Host unresolved.
           (expr (etaf-ui--text-value value)))
         (expr (when trend
                 (etaf-view (etaf-label :text trend :variant 'success)))))))))

(etaf-define-component etaf-empty
    (&key (title "Nothing here") description action-label on-action)
  "Render an empty state with optional description and action."
  :validate
  (etaf-check-prop :on-action on-action (or (null action-label) (functionp on-action))
                   "a function when :action-label is supplied" 'etaf-empty)
  :view
  (column :class "etaf-empty" :width 'stretch :padding '((lh 1) (ch 2))
          :cross-align 'center :item-gap '(lh 1)
    (etaf-label :text title :variant 'strong)
    (etaf-label :text description :variant 'muted)
    (expr (when action-label
            (etaf-view (etaf-button :label action-label :on-press on-action))))))

(etaf-define-component etaf-ui--animated-skeleton (&key width height)
  "Render a subtly pulsing loading placeholder on the shared clock."
  :bindings
  ((pulse (etaf-animation-frames '(0.0 0.35 0.7 1.0 0.7 0.35)
                                 :interval 0.18 :name 'etaf-skeleton)))
  :render
  (let ((alpha (etaf-value pulse)))
    (etaf-view
     (box :class "etaf-skeleton is-animated" :width width :height height
          :background-color
          (etaf-theme-token
           :ui-progress-track "#E2E8F0"
           (lambda (base)
             (let ((peak (etaf-ui--state-hover-shift base)))
               (if (and (stringp base) (stringp peak))
                   (etaf-ui-color-mix base peak alpha)
                 base))))))))

(etaf-define-component etaf-skeleton (&key (width 'stretch) (height '(lh 1)) animated)
  "Render a loading placeholder with WIDTH and HEIGHT."
  :render
  (if animated
      (etaf-view (etaf-ui--animated-skeleton :width width :height height))
    (etaf-view
     (box :class "etaf-skeleton" :width width :height height
          :background-color (etaf-theme-token :ui-progress-track "#E2E8F0")))))

(defconst etaf-ui--spinner-styles
  '((braille . (2 ("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")))
    (dots    . (3 ("·  " "·· " "···" "·· ")))
    (line    . (1 ("|" "/" "-" "\\")))
    (meter   . (1 ("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█" "▇" "▆" "▅" "▄" "▃" "▂"))))
  "Spinner styles as (NAME . (CELL-WIDTH FRAME-LIST)).")

(etaf-define-component etaf-spinner
    (&key (style 'braille) label (variant 'info) (interval 0.09))
  "Render a shared-clock loading indicator with fixed width and optional LABEL."
  :validate
  (progn
    (etaf-check-prop :style style (and (symbolp style)
                                       (assq style etaf-ui--spinner-styles))
                     "braille, dots, line or meter" 'etaf-spinner)
    (etaf-check-prop :label label (or (null label) (stringp label))
                     "a string or nil" 'etaf-spinner)
    (etaf-check-prop :interval interval (and (numberp interval) (> interval 0))
                     "a positive number" 'etaf-spinner))
  :bindings
  ((spec (or (cdr (assq style etaf-ui--spinner-styles))
             (cdr (assq 'braille etaf-ui--spinner-styles))))
   (frame (etaf-animation-frames
           (cadr spec)
           :interval (if (and (numberp interval) (> interval 0))
                         interval 0.09)
           :name 'etaf-spinner)))
  :render
  (let ((theme (etaf-ui--feedback-theme variant))
        (glyph-width (car spec)))
    (etaf-view
     (row :class (format "etaf-spinner %s" style) :role 'status
          :item-gap '(ch 1) :cross-align 'center
       (box :width (list 'ch glyph-width) :height '(lh 1)
            :flex-shrink 0 :color (nth 0 theme)
         (text (expr (etaf-value frame))))
       (expr (when label
               (etaf-view (etaf-label :text label :variant 'muted))))))))

(defun etaf-ui--card-accent-color (variant)
  "Return the resolved semantic accent color for card VARIANT, or nil."
  (let ((key (pcase variant
               ((or 'primary 'info) :ui-accent)
               ('success :ui-success-fg)
               ('warning :ui-warning-fg)
               ('danger :ui-danger-fg)
               ('important :ui-important-fg)
               (_ nil))))
    (when key
      (plist-get (etaf-ui--style-tokens key) key))))

(etaf-define-component etaf-card
    (&key title description icon (variant 'default) (width 'stretch)
          (text-align 'start) on-press)
  "Render a reusable surface with optional TITLE and DESCRIPTION slots.
ICON draws a glyph from the icon sets before the title on the title's own
row.  VARIANT may be `default'/`neutral' or a semantic accent (`primary',
`info', `success', `warning', `danger', `important') that paints the title
and a crisp left accent rule from the Theme.  WIDTH sizes the card,
TEXT-ALIGN aligns both header and body content, and ON-PRESS makes the
whole surface activate with a hand pointer."
  :validate
  (etaf-check-prop :on-press on-press (or (null on-press) (functionp on-press))
                   "a function or nil" 'etaf-card)
  :render
  (let* ((theme (etaf-ui--style-tokens :ui-panel-fg :ui-panel-bg :ui-panel-border))
         (border (etaf-ui--style-border (plist-get theme :ui-panel-border)))
         (accent (etaf-ui--card-accent-color variant))
         (slot (etaf-current-slot 'default)))
    (etaf-view
     (column :class (format "etaf-card %s" variant) :width width
             :cross-align text-align
             :pointer (when on-press 'hand)
             :on-press on-press
             :padding '((lh 1) (ch 2))
             :item-gap '(lh 1)
             :color (plist-get theme :ui-panel-fg)
             :background-color (plist-get theme :ui-panel-bg)
             :border-top border
             :border-right border
             :border-bottom border
             :border-left (if accent
                              (etaf-ui--style-border accent 3)
                            border)
       (expr (when title
               (let* ((glyph (and icon
                                  (car (etaf-ui-icon-lines icon :lines 1))))
                      (title-text (etaf-ui--text-value title))
                      (label (if glyph (concat glyph " " title-text) title-text)))
                 (if accent
                     (etaf-node 'text (list :color accent :font-weight 'bold)
                                (list label))
                   (etaf-view (etaf-label :text label :variant 'strong))))))
       (expr (when description (etaf-view (etaf-label :text description :variant 'muted))))
       (expr (when slot
               (if (eq text-align 'start)
                   slot
                 (etaf-node 'box (list :width 'stretch :text-align text-align)
                            (if (listp slot) slot (list slot))))))))))

(defvar etaf-ui--avatar-cache (make-hash-table :test #'equal)
  "Round avatar image descriptors keyed by their source and pixel size.")

(defun etaf-ui--avatar-columns (size lines)
  "Return the integer column count of avatar SIZE, LINES high."
  (cond ((natnump size) (max 1 size))
        ((and (consp size) (eq (car size) 'ch) (natnump (cadr size)))
         (max 1 (cadr size)))
        (t (* 2 lines))))

(defun etaf-ui--avatar-photo (src)
  "Return (MIME . BASE64) for avatar photo SRC, or nil when unreadable."
  (let* ((descriptor (and (consp src) (eq (car src) 'image) (cdr src)))
         (file (if descriptor (plist-get descriptor :file) src))
         (data (and descriptor (plist-get descriptor :data)))
         (type (or (and descriptor (plist-get descriptor :type))
                   (and (stringp file) (image-supported-file-p file)))))
    (when (and (null data) (stringp file) (file-readable-p file))
      (setq data (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally file)
                   (buffer-string))))
    (when (and (stringp data) (memq type '(png jpeg gif webp svg)))
      (cons (format "image/%s" (if (eq type 'svg) "svg+xml" type))
            (base64-encode-string
             (if (multibyte-string-p data) (encode-coding-string data 'binary) data)
             t)))))

(defun etaf-ui--avatar-image (src initials foreground background columns lines)
  "Return a round avatar descriptor COLUMNS by LINES cells, or nil.
SRC is a photo source; without a readable photo, draw INITIALS in
FOREGROUND on a BACKGROUND circle."
  (when (and (display-images-p) (image-type-available-p 'svg))
    (let* ((cell (etaf-ui--canvas-cell))
           (cw (car cell)) (lh (cdr cell))
           (key (list src initials foreground background columns lines cw lh)))
      (or (gethash key etaf-ui--avatar-cache)
          (let* ((width (* columns cw)) (height (* lines lh))
                 (d (min width height)) (r (/ d 2.0))
                 (cx (/ width 2.0)) (cy (/ height 2.0))
                 (photo (and src (etaf-ui--avatar-photo src)))
                 (body
                  (if photo
                      (format "<defs><clipPath id='c'><circle cx='%s' cy='%s' r='%s'/></clipPath></defs><image x='%s' y='%s' width='%d' height='%d' preserveAspectRatio='xMidYMid slice' clip-path='url(#c)' xlink:href='data:%s;base64,%s'/>"
                              cx cy r (- cx r) (- cy r) d d (car photo) (cdr photo))
                    (format "<circle cx='%s' cy='%s' r='%s' fill='%s'/><text x='%s' y='%s' text-anchor='middle' dominant-baseline='central' font-family='%s' font-weight='bold' font-size='%s' fill='%s'>%s</text>"
                            cx cy r background cx cy
                            (xml-escape-string (or (face-attribute 'default :family nil t) "sans-serif"))
                            (round (* d (if (> (length initials) 1) 0.38 0.46)))
                            foreground (xml-escape-string initials)))))
            (when (> (hash-table-count etaf-ui--avatar-cache) 1024)
              (clrhash etaf-ui--avatar-cache))
            (puthash key
                     (list 'image :type 'svg
                           :data (format "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='%d' height='%d' viewBox='0 0 %d %d'>%s</svg>"
                                         width height width height body))
                     etaf-ui--avatar-cache))))))

(etaf-define-component etaf-avatar (&key name initials src (size '(ch 5))
                                        (variant 'info) (lines 3) background
                                        (shape 'circle))
  "Render an AVATAR with caller-provided NAME tooltip text.
SRC is an optional photo file or image descriptor.  On graphical frames
SHAPE `circle' draws the photo, or the initials on a colored disc, as a
round image; `square' and text frames use an initials box.  LINES sets its
height; BACKGROUND replaces VARIANT's colors with white initials on it."
  :validate
  (etaf-check-prop :shape shape (memq shape '(circle square))
                   "circle or square" 'etaf-avatar)
  :render
  (let* ((name (etaf-ui--text-value name))
         (initials (etaf-ui--text-value initials))
         (initials (if (string-empty-p initials)
                       (if (string-empty-p name) "?"
                         (upcase (substring name 0 (min 2 (length name)))))
                     initials))
         (theme (etaf-ui--feedback-theme variant)))
    (unless (and (integerp lines) (> lines 0))
      (signal 'wrong-type-argument (list 'natnump lines)))
    (let* ((columns (etaf-ui--avatar-columns size lines))
           (keys (etaf-ui--feedback-keys variant))
           ;; Only the avatar's own two colors are resolved: other palette
           ;; entries may be deferred tokens (hover fills), which a palette
           ;; resolution would reject as colors.
           (palette (and (eq shape 'circle)
                         (etaf-theme-resolve-palette
                          (list (nth 0 keys) (plist-get etaf-ui--style-palette (nth 0 keys))
                                (nth 1 keys) (plist-get etaf-ui--style-palette (nth 1 keys)))
                          (etaf-theme-current-mode))))
           (image (and (eq shape 'circle)
                       (etaf-ui--avatar-image
                        (etaf-ui--reactive-value src) initials
                        (if background "#FFFFFF"
                          (plist-get palette (nth 0 (etaf-ui--feedback-keys variant))))
                        (or background
                            (plist-get palette (nth 1 (etaf-ui--feedback-keys variant))))
                        columns lines))))
      (if image
          (etaf-view
           (box :class "etaf-avatar" :role 'img :aria-label name
                :width (list 'ch columns) :height (list 'lh lines)
                :flex-shrink 0
             (image :src image :columns columns :rows lines)))
        (etaf-view
         (box :class "etaf-avatar" :role 'img :aria-label name :width size
              :height (list 'lh lines) :box-sizing 'border-box
              :padding-top (list 'lh (/ (1- lines) 2))
              :text-align 'center :font-weight 'bold
              :color (if background "#FFFFFF" (nth 0 theme))
              :background-color (or background (nth 1 theme))
              :border (unless background (nth 2 theme))
           (text (expr initials))))))))

(defun etaf-ui--timeline-marker (list-style index)
  "Return the timeline marker LIST-STYLE draws at INDEX."
  (pcase list-style
    ('decimal (format "%d." index))
    ('bullet "o")
    (_ "")))

(defun etaf-ui--dot-view (color)
  "Return a small round marker drawn in COLOR.
A text grid has no pixel-height box, so the dot is the glyph itself: it keeps
the line height and sits on the baseline the label uses."
  (etaf-node 'text (list :color color) (list "•")))

(defun etaf-ui--status-token (status)
  "Return the Theme colour STATUS names, or the accent colour."
  (pcase status
    ('success (etaf-theme-token :ui-success-fg "#15803D"))
    ('warning (etaf-theme-token :ui-warning-fg "#B45309"))
    ('danger (etaf-theme-token :ui-danger-fg "#B91C1C"))
    ('info (etaf-theme-token :ui-info-fg "#0369A1"))
    (_ (etaf-theme-token :ui-accent "#2563EB"))))

(defun etaf-ui--timeline-item (item index list-style)
  "Return timeline ITEM at INDEX rendered under LIST-STYLE.
The time sits below the content, the way a chronology reads: title, what
happened, when.  A continuous left rail runs down the timeline, with each
entry's dot or index anchored cleanly against the rail on its title row."
  (let* ((time (plist-get item :time))
         (status (plist-get item :status))
         ;; A caller may spell the badge as a plist: :text is what the badge
         ;; reads and :variant names the colour.  A bare symbol keeps its old
         ;; meaning, a colour name used as the badge's own text.
         (status-variant (if (and (consp status) (plist-get status :variant))
                             (plist-get status :variant)
                           status))
         (status-text (if (consp status) (plist-get status :text) status))
         (title (plist-get item :title))
         (content (plist-get item :content))
         (border (etaf-theme-token :ui-border "#CBD5E1"))
         (marker
          (pcase list-style
            ('decimal
             (etaf-view
              (etaf-label :text (etaf-ui--timeline-marker list-style index)
                          :variant 'muted)))
            ('bullet
             (etaf-ui--dot-view
              (if status-variant (etaf-ui--status-token status-variant)
                (etaf-theme-token :ui-accent "#2563EB"))))
            (_ nil))))
    (etaf-view
     (column :class "etaf-timeline-item" :width 'stretch
             :item-gap '(lh 0)
             :border-left (etaf-ui--style-border border)
             :padding '((lh 0) (ch 2) (lh 1) (ch 2))
       (flex :class "etaf-timeline-body" :width 'stretch
             :gap '((lh 0) (ch 1)) :align-items 'center
         (expr marker)
         (etaf-label :text title :variant 'strong)
         (expr (when status-text
                 (etaf-view (etaf-badge
                             :text status-text
                             :variant (if (memq status-variant
                                                '(success warning danger info))
                                          status-variant
                                        'info))))))
       (expr
        (when content
          (etaf-node
           'box (list :width 'stretch
                      :padding-left (if (eq list-style 'none) '(ch 0) '(ch 2)))
           (list
            (cond ((functionp content) (funcall content))
                  ((stringp content)
                   (etaf-view (etaf-label :text content :variant 'default))))))))
       (expr (when time
               (etaf-node
                'box (list :width 'stretch
                           :padding-left (if (eq list-style 'none) '(ch 0) '(ch 2)))
                (list (etaf-view
                       (etaf-label :text time :variant 'muted))))))))))

(etaf-define-component etaf-timeline
    (&key items (list-style 'bullet) (start 1))
  "Render chronological ITEMS with :title, :content and optional :time, :status.
An item with TIME shows it above its title.  STATUS becomes the leading badge
and colours the dot: a symbol spells the badge with its own name, while a plist
of :text and :variant lets a caller write the badge in its own words.  Without
STATUS, LIST-STYLE picks the marker, starting at START.  A CONTENT that is a
function is called for a View, so a caller can compose a whole block under the
title."
  :validate
  (progn
    (etaf-check-prop :items items (and (proper-list-p items) items)
                     "a nonempty list of item plists" 'etaf-timeline)
    (etaf-check-prop :list-style list-style (memq list-style '(decimal bullet none))
                     "decimal, bullet or none" 'etaf-timeline)
    (etaf-check-prop :start start (and (integerp start) (>= start 0))
                     "a non-negative integer" 'etaf-timeline))
  :render
  (etaf-view
   (column :class "etaf-timeline" :width 'stretch :item-gap '(lh 0)
     (expr
      (cl-loop
       for item in items
       for index from start
       collect (etaf-ui--timeline-item item index list-style))))))

(etaf-define-component etaf-tag
    (&key text (variant 'neutral) closable on-close)
  "Render a compact TAG with optional caller-owned close action."
  :validate
  (etaf-check-prop :on-close on-close (or (not closable) (functionp on-close))
                   "a function when closable" 'etaf-tag)
  :render
  (let ((theme (etaf-ui--feedback-theme variant)))
    (etaf-view
     (row :class "etaf-tag" :item-gap '(ch 1) :width 'max-content
          :padding-inline '(ch 1) :background-color (nth 1 theme)
       (etaf-label :text text :color (nth 0 theme))
       (expr (when closable
               (etaf-view
                (etaf-button :label "×"
                             :aria-label (format "Remove %s" (etaf-ui--text-value text))
                             :variant 'ghost :color (nth 0 theme) :bgcolor (nth 1 theme)
                             :border (nth 1 theme)
                             :on-press on-close))))))))

(etaf-define-component etaf-kbd (&key keys)
  "Render keyboard KEYS as a compact accessible keycap group."
  :validate
  (etaf-check-prop :keys keys
                   (and (proper-list-p keys) keys
                        (cl-every (lambda (key) (and (stringp key)
                                                    (not (string-empty-p key)))) keys))
                   "a nonempty list of strings" 'etaf-kbd)
  :render
  (let* ((theme (etaf-ui--reactive-value (etaf-inject 'theme)))
         (bg (or (plist-get theme :ui-panel-bg)
                 (plist-get etaf-ui--style-palette :ui-panel-bg)))
         (fg (or (plist-get theme :ui-panel-fg)
                 (plist-get etaf-ui--style-palette :ui-panel-fg)))
         (fill (etaf-ui-color-mix bg fg 0.06))
         (edge (etaf-ui-color-mix bg fg 0.18)))
    (etaf-view
     (row :class "etaf-kbd" :item-gap '(ch 1) :width 'max-content
       (expr (mapcar (lambda (key)
                       (etaf-view
                        (box :padding '((lh 0) (ch 1)) :border-radius '(px 4)
                             :background-color fill :color fg
                             :border (etaf-ui--style-border edge)
                          (text (expr key)))))
                     keys))))))

(defconst etaf-check-mark-states
  '((empty . "待") (done . "完") (dropped . "弃") (skipped . "跳"))
  "States of `etaf-check-mark' and the glyph each draws without SVG.")

(defun etaf-ui--check-mark-icon (state)
  "Return the registered icon name drawing check-mark STATE."
  (pcase state
    ('empty 'checkbox)
    ('done 'checkbox-checked)
    ('dropped 'checkbox-crossed)
    ('skipped 'checkbox-dashed)))

(defun etaf-ui--check-mark-slot (state glyph)
  "Return GLYPH text carrying STATE's drawn mark when SVG is available."
  (let* ((slot (copy-sequence glyph))
         (icon (car (etaf-ui-icon-lines (etaf-ui--check-mark-icon state)
                                        :set 'svg :size 0.86 :lines 1)))
         (image (plist-get (text-properties-at 0 icon) 'display)))
    (when image
      (add-text-properties 0 (length slot) (list 'display image) slot))
    slot))

(etaf-define-component etaf-check-mark (&key state color glyph aria-label)
  "Render the drawn mark of a task STATE in one standard row."
  :validate
  (progn
    (etaf-check-prop :state state (assq state etaf-check-mark-states)
                     "empty, done, dropped or skipped" 'etaf-check-mark)
    (etaf-check-prop :glyph glyph
                     (or (null glyph) (and (stringp glyph)
                                           (not (string-empty-p glyph))))
                     "a nonempty string or nil" 'etaf-check-mark))
  :render
  (let ((slot (etaf-ui--check-mark-slot
               state (or glyph (alist-get state etaf-check-mark-states)))))
    (etaf-view
     (box :class (etaf-ui--class-value "etaf-check-mark" state nil)
          :role 'img :aria-label (or aria-label (alist-get state etaf-check-mark-states))
          :color color :width 'max-content
       (text (expr slot))))))

(defconst etaf-keycap-levels '(action region)
  "Keycap sizes: an action key is one row high, a region key is a square.")

(etaf-define-component etaf-keycap
    (&key text (level 'action) label active disabled on-press aria-label help-echo
          (variant 'outline))
  "Render keycap TEXT at action or region LEVEL with an optional caption LABEL.

Both levels keep the frame's own type size.  VARIANT picks how the cap is
painted: `filled' is a soft chip with one cell of inline padding and no
outline, which keeps a header full of hints reading as text; `outline' draws
the same cap as a hairline box with no fill, so a row of keys reads as keys.
The region level is bold in both variants and fills with the accent while its
region holds the keyboard."
  :validate
  (progn
    (etaf-check-prop :text text (and (stringp text) (not (string-empty-p text)))
                     "a nonempty string" 'etaf-keycap)
    (etaf-check-prop :variant variant (memq variant '(filled outline))
                     "filled or outline" 'etaf-keycap)
    (etaf-check-prop :level level (memq level etaf-keycap-levels)
                     "action or region" 'etaf-keycap)
    (etaf-check-prop :label label (or (null label) (stringp label))
                     "a string or nil" 'etaf-keycap)
    (etaf-check-prop :on-press on-press (or (null on-press) (functionp on-press))
                     "a function or nil" 'etaf-keycap))
  :render
  (let* ((theme (etaf-ui--feedback-theme 'neutral))
         (fg (nth 0 theme))
         (bg (nth 1 theme))
         (accent (etaf-theme-token :ui-accent
                                   (plist-get etaf-ui--style-palette :ui-accent)))
         (regionp (eq level 'region))
         (outlinep (eq variant 'outline))
         (fill (cond (outlinep nil)
                     (disabled (etaf-ui-color-mix bg fg 0.04))
                     ((and regionp active) accent)
                     (regionp (etaf-ui-color-mix bg fg 0.12))
                     (t (etaf-ui-color-mix bg fg 0.08))))
         (edge (cond (disabled (etaf-ui-color-mix bg fg 0.10))
                     ((and regionp active) accent)
                     (t (etaf-ui-color-mix bg fg 0.22))))
         (ink (cond (disabled (etaf-ui-color-mix fg bg 0.45))
                    ((and regionp active) (if outlinep accent bg))
                    ((and outlinep regionp) fg)
                    (outlinep (etaf-theme-token :ui-muted-fg
                                                (plist-get etaf-ui--style-palette :ui-muted-fg)))
                    (regionp fg)
                    (t (etaf-theme-token :ui-muted-fg
                                         (plist-get etaf-ui--style-palette :ui-muted-fg))))))
    (etaf-view
     (flex :flex-direction 'row :align-items 'center
           :class (etaf-ui--class-value
                   "etaf-keycap"
                   (cond ((and regionp active) "region on")
                         (regionp "region")
                         (disabled "action off")
                         (t "action"))
                   nil)
           :gap '((lh 0) (ch 1)) :flex-grow 0 :flex-shrink 0 :width 'auto
           :role (and on-press 'button)
           :tab-index (and on-press (if disabled -1 0))
           :on-press (and on-press (not disabled) on-press)
           :aria-label aria-label :help-echo help-echo
       (flex :flex-direction 'row :align-items 'center
             :justify-content 'center
             :width (if regionp '(ch 2) 'auto)
             :min-height '(lh 1)
             :padding-inline (unless regionp '(ch 1))
             :background-color fill
             :border (when outlinep (etaf-ui--style-border edge))
             :border-radius '(px 3)
         (text :font-weight (if regionp 'bold 'normal) :color ink
               (expr text)))
       (expr (when label
               (etaf-view
                (text :color (if disabled
                                 (etaf-ui-color-mix fg bg 0.45)
                               (etaf-theme-token :ui-muted-fg
                                                 (plist-get etaf-ui--style-palette :ui-muted-fg)))
                      (expr label)))))))))

(provide 'etaf-ui-feedback)
;;; etaf-ui-feedback.el ends here
