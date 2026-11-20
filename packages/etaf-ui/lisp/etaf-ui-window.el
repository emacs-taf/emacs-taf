;;; etaf-ui-window.el --- Controlled movable and resizable surfaces -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Window and panel shells are presentational, controlled Components.  They
;; project caller-owned geometry to Ebox and report gestures to caller-owned
;; callbacks.  They deliberately do not keep window state, assign z-order or
;; implement a workspace/window manager.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui-basic)

(defvar etaf-ui--window-icon-cache (make-hash-table :test #'equal)
  "Cached text-property SVG glyphs used by traffic-light hover labels.")

(defun etaf-ui--window-icon-size ()
  "Return a traffic-light glyph size that fits the current frame line."
  (let ((line-height (if (display-graphic-p) (cdr (etaf-ui--canvas-cell)) 16)))
    (max 10 (min 16 (- line-height 4)))))

(defun etaf-ui--window-hover-icon (symbol)
  "Return an immutable cached traffic-light Text value for SYMBOL.
The SVG circle fills with `currentColor', which Emacs resolves from the face
foreground where the glyph is displayed.  The Host `:color' therefore paints
the light, so an active-state change is a retained paint update rather than
new Text content.  Without SVG, one-cell ASCII marks inherit the same font
as neighboring text. Display size and SVG availability select variants."
  (let* ((svg (and (display-graphic-p)
                   (fboundp 'image-type-available-p)
                   (image-type-available-p 'svg)))
         (size (etaf-ui--window-icon-size))
         (variant (+ size (if svg 32 0)))
         (variants (gethash symbol etaf-ui--window-icon-cache)))
    (or (and variants (gethash variant variants))
        (let ((text (copy-sequence
                     (if svg symbol
                       (pcase symbol
                         ("⊗" "x") ("⊖" "-") ("⊕" "+") (_ "o"))))))
          (unless variants
            (setq variants (make-hash-table :test #'eql))
            (puthash symbol variants etaf-ui--window-icon-cache))
          (when svg
            (let* ((path (pcase symbol
                           ("⊗" "M3.5 3.5L10.5 10.5M10.5 3.5L3.5 10.5")
                           ("⊖" "M3.5 7H10.5")
                           ("⊕" "M3.5 7H10.5M7 3.5V10.5")
                           (_ "")))
                   (image
                    (create-image
                     (format
                      "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 14 14'><circle cx='7' cy='7' r='6.5' fill='currentColor'/><path d='%s' fill='none' stroke='#111111' stroke-width='1.4' stroke-linecap='round' stroke-linejoin='round'/></svg>"
                      size size path)
                     'svg t :ascent 'center)))
              (put-text-property 0 (length text) 'display image text)))
          (puthash variant text variants)))))

(defun etaf-ui--window-callback (property value component)
  "Validate optional callback VALUE for COMPONENT PROPERTY."
  (etaf-check-prop property value (or (null value) (functionp value))
                   "a function or nil" component)
  value)

(defun etaf-ui--window-mode (mode)
  "Return the live symbolic MODE value for a controlled window."
  (let ((mode (etaf-ui--reactive-value mode)))
    (etaf-check-prop :mode mode (memq mode '(normal minimized maximized))
                     "normal, minimized or maximized" 'etaf-window)
    mode))

(defun etaf-ui--window-control-inactive-color ()
  "Return the Theme token painting every traffic light of an inactive window."
  (etaf-ui--style-token :ui-window-title-fg))

(etaf-define-component etaf-ui--window-control-surface
    (&key active color hover-label aria-label callback group)
  "Project one traffic light's paint directly onto a retained native target.
This stateless surface also supports pure rendering."
  :view
  (box :class (if callback "etaf-button enabled etaf-window-control"
                "etaf-button disabled etaf-window-control")
       :role 'button :aria-label aria-label
       :width 'max-content :height '(lh 1)
       :pointer 'arrow :disabled (null callback)
       :tab-index (when callback 0) :on-press callback
       :color (if (etaf-ui--reactive-value active)
                  color (etaf-ui--window-control-inactive-color))
       :background-color (etaf-ui--style-token :ui-window-title-bg)
       :padding '((lh 0) (ch 0.30)) :font-weight 'bold
       :hover-group group
       :hover-content (etaf-ui--window-hover-icon hover-label)
       (text (expr (etaf-ui--window-hover-icon "⬤")))))

(defun etaf-ui--window-action (active aria-label callback color hover-label group)
  "Construct a controlled traffic light with caller-owned ACTIVE state."
  (etaf-node 'etaf-ui--window-control-surface
             (list :active active :aria-label aria-label :callback callback
                   :color color :hover-label hover-label :group group)
             nil))

(defun etaf-ui--window-handle (edge on-resize ref use &optional props)
  "Return a resize handle for EDGE with caller-owned input callbacks.
PROPS are appended to the handle node, so a frame can place the handle in a
grid cell or present it like the content it covers."
  (let* ((width (or (plist-get props :width) 'stretch))
         (height (or (plist-get props :height) 'stretch))
         ;; A Component property list is strict about duplicate keys.  Width
         ;; and height are the two defaults a frame may intentionally override
         ;; (the top-edge hit strip uses a pixel height), so consume those
         ;; overrides before composing the final node properties.
         (extra
          (cl-loop for (key value) on props by #'cddr
                   unless (memq key '(:width :height))
                   append (list key value)))
         (properties
          (append
           (list :key edge :class (format "etaf-window-resize-handle %s" edge)
                 :width width :height height :overflow 'hidden
                 :role 'separator :aria-label (format "Resize %s" edge)
                 :pointer (cond ((memq edge '(top bottom)) 'vdrag)
                                ((memq edge '(left right)) 'hdrag)
                                (t 'nhdrag))
                 ;; Window keys resize from anywhere inside, so the edges
                 ;; stay focusable for arrows without being Tab stops.
                 :tab-index (when (or on-resize use) -1))
           extra
           (when ref (list :ref ref))
           (when use (list :use use))
           (when on-resize
             (list :on-drag
                   (lambda (gesture) (funcall on-resize edge gesture)))))))
    (etaf-node 'box properties
               (list (etaf-node 'text nil (list " "))))))

(defun etaf-ui--panel-frame
    (content edges on-resize refs behaviors &optional header header-style drag-lock-modifier full-bleed)
  "Surround CONTENT with edge-owned resize handles for EDGES.

HEADER, when supplied, owns the frame's first row between the two corner
cells so a caller's title bar reaches both panel borders; HEADER-STYLE
presents those corner cells with the same background and rule, keeping the
covered title row visually closed.  Without HEADER the first row belongs to
the enabled top cells.  CONTENT owns the grid cell beside the handle cells;
with FULL-BLEED it instead spans the panel's full body and the handles paint
after it, so the body reaches the panel edges and a handle covers only the
cells it owns.  Callers that want a seamless body enable FULL-BLEED with the
top edge and the corners, whose cells sit in the title row or in the
content's own margin.
DRAG-LOCK-MODIFIER is forwarded to each handle's native gesture binding."
  (let* ((left (cl-intersection edges '(left top-left bottom-left)))
         (right (cl-intersection edges '(right top-right bottom-right)))
         (bottom (cl-intersection edges '(bottom bottom-left bottom-right)))
         (top-cells (cl-intersection edges '(top top-left top-right)))
         (left-width (if (or left top-cells) 6 0))
         (right-width (if (or right top-cells) 6 0))
         (handle (lambda (edge placement style)
                   (when (memq edge edges)
                     ;; Overlapping grid flow cells do not form a stacking
                     ;; layer.  Full-bleed body handles are absolute strips
                     ;; in the frame, sized by CSS from its current viewport.
                     ;; Each strip owns exactly the outermost row or column of
                     ;; the body, so the frame stays seamless: the strip is a
                     ;; hit surface rather than paint, and the application's own
                     ;; pixels stay visible right up to the frame edge.
                     (when full-bleed
                       (when-let* ((strip
                                    (pcase edge
                                      ('left
                                       (list :left '(px 0) :top '(lh 1)
                                             :width '(ch 1)
                                             :height `(calc (- (% 100) (lh ,(if bottom 2 1))))))
                                      ('right
                                       (list :left '(calc (- (% 100) (ch 1))) :top '(lh 1)
                                             :width '(ch 1)
                                             :height `(calc (- (% 100) (lh ,(if bottom 2 1))))))
                                      ('bottom-left
                                       '(:left (px 0) :top (calc (- (% 100) (lh 1)))
                                         :width (ch 1) :height (lh 1)))
                                      ('bottom
                                       '(:left (ch 1)
                                         :top (calc (- (% 100) (lh 1)))
                                         :width (calc (- (% 100) (ch 2)))
                                         :height (lh 1)))
                                      ('bottom-right
                                       '(:left (calc (- (% 100) (ch 1)))
                                         :top (calc (- (% 100) (lh 1)))
                                         :width (ch 1) :height (lh 1))))))
                         (setq placement
                               (append (list :position 'absolute :z-index 1
                                             ;; An identity backdrop keeps the
                                             ;; cells behind a blank handle, so
                                             ;; resizing never repaints the
                                             ;; application's edge.
                                             :backdrop-filter '(brightness 1))
                                       strip))))
                     (etaf-ui--window-handle
                      edge on-resize (cdr (assq edge refs))
                      (cdr (assq edge behaviors))
                      (append placement style
                              (list :drag-lock-modifier drag-lock-modifier))))))
         (title-cell (lambda (corner placement)
                       (or (funcall handle corner placement header-style)
                           (funcall handle 'top placement header-style)))))
    (etaf-node
     'grid
     (list :width 'stretch :height 'stretch
           :grid-template-columns
           (list (list 'px left-width)
                 '(minmax (px 0) (fr 1))
                 (list 'px right-width))
           :grid-template-rows
           (list '(lh 1) '(minmax (lh 0) (fr 1))
                 (if bottom '(lh 1) '(lh 0)))
           :gap '((lh 0) (px 0)))
     (delq
      nil
      (append
       (when header
         (list
          (etaf-node
           'flex
           (list :key 'header :width 'stretch :height '(lh 1)
                 :min-width '(px 0) :grid-column 2 :grid-row 1
                 :overflow 'hidden)
           (append
            (list
             (etaf-node 'column
                        (list :key 'header-content :width 'stretch
                              :height '(lh 1) :min-width '(px 0)
                              :flex-grow 1 :flex-shrink 1 :flex-basis '(px 0)
                              :overflow 'hidden)
                        header))
            ;; Ebox block geometry is row-based.  Reserve a narrow, explicit
            ;; top-edge cell at the end of the title row so the top resize
            ;; Behavior has a real public Host without adding a second row or
            ;; using an Emacs overlay.  The remaining title row stays the move
            ;; surface and the side corner cells cover the actual corners.
            (when (memq 'top edges)
              (list
               (funcall handle 'top
                        '(:width (px 6) :height (lh 1)
                          :flex-grow 0 :flex-shrink 0)
                        header-style)))))))
       (list
        (funcall title-cell 'top-left '(:grid-column 1 :grid-row 1))
        (unless header
          (funcall handle 'top '(:grid-column 2 :grid-row 1) nil))
        (funcall title-cell 'top-right '(:grid-column 3 :grid-row 1))
        (unless full-bleed
          (etaf-node 'column
                     (list :key 'content :width 'stretch :height 'stretch
                           :min-width '(px 0) :min-height '(lh 0)
                           :grid-column 2 :grid-row 2
                           :overflow 'hidden)
                     content))
        (when full-bleed
          (etaf-node 'column
                     (list :key 'content :width 'stretch :height 'stretch
                           :min-width '(px 0) :min-height '(lh 0)
                           :grid-column '(1 :span 3)
                           :grid-row (if bottom '(2 :span 2) 2)
                           :overflow 'hidden)
                     content))
        ;; Full-bleed handles paint above the body in the frame's own layer.
        (funcall handle 'left '(:grid-column 1 :grid-row 2) nil)
        (funcall handle 'right '(:grid-column 3 :grid-row 2) nil)
        (funcall handle 'bottom-left '(:grid-column 1 :grid-row 3) nil)
        (funcall handle 'bottom '(:grid-column 2 :grid-row 3) nil)
        (funcall handle 'bottom-right '(:grid-column 3 :grid-row 3) nil)))))))

(defconst etaf-ui--window-resize-edges
  '(top right bottom left top-left top-right bottom-right bottom-left)
  "Supported edge and corner names for resize handles.")

(etaf-define-component etaf-window-controls
    (&key (mode 'normal) (show-minimize t) (show-maximize t) (show-close t)
          (active t)
          on-minimize on-maximize on-restore on-close
          (group 'etaf-window-controls) class)
  "Render reusable macOS-style traffic-light controls.
GROUP is shared by the three buttons so Ebox updates all hover glyphs in one
incremental batch.  ACTIVE selects the macOS presentation: an inactive window
renders all three lights in one gray, while the active window keeps the red,
yellow and green lights.  The green Zoom light calls ON-RESTORE while MODE is
`maximized' and ON-MAXIMIZE otherwise, reading a reactive MODE when pressed so
a mode change never rebuilds the controls.  The component owns no window
policy; callbacks request caller-owned transitions."
  :validate
  (progn
    (etaf-check-prop :mode mode
                     (or (etaf-ref-p mode) (etaf-computed-p mode)
                         (memq mode '(normal minimized maximized)))
                     "normal, minimized or maximized" 'etaf-window-controls)
    (etaf-check-prop :active active
                     (or (etaf-ref-p active) (etaf-computed-p active)
                         (booleanp (etaf-ui--reactive-value active)))
                     "a boolean" 'etaf-window-controls)
    (etaf-check-prop :group group
                     (or (symbolp group) (stringp group) (numberp group))
                     "a scalar hover group key" 'etaf-window-controls)
    (dolist (entry `((:on-minimize . ,on-minimize)
                     (:on-maximize . ,on-maximize)
                     (:on-restore . ,on-restore)
                     (:on-close . ,on-close)))
      (etaf-ui--window-callback (car entry) (cdr entry)
                                'etaf-window-controls)))
  :render
  (let* ((zoom (and (or on-maximize on-restore)
                    (lambda ()
                      (let ((callback (if (eq (etaf-ui--window-mode mode) 'maximized)
                                          on-restore on-maximize)))
                        (when callback (funcall callback))))))
         (actions
          (append
           (when show-close
             (list (etaf-ui--window-action
                    active "Close" on-close "#FF5F57" "⊗" group)))
           (when show-minimize
             (list (etaf-ui--window-action
                    active "Minimize" on-minimize "#FEBC2E" "⊖" group)))
           (when show-maximize
             (list (etaf-ui--window-action
                    active "Zoom" zoom "#28C840" "⊕" group))))))
    (etaf-node 'flex
               (list :class (etaf-ui--class-value
                             "etaf-window-controls" nil class)
                     :role 'toolbar :aria-label "Window controls"
                     :focus-group 'horizontal
                     :width 'max-content :height '(lh 1)
                     :align-items 'center :column-gap '(ch 0.15))
               actions)))

(etaf-define-component etaf-ui--window-title-surface
    (&key title active title-font-size font-family)
  "Center TITLE and bind its tone to the window's reactive ACTIVE state.
The tone is read inside a Host property so focus changes stay retained paint
updates rather than title-bar re-renders."
  :view
  ;; Equal fixed side columns keep the title at the geometric center without
  ;; a positioned child, preserving Ebox's host line-height invariant.
  (box :width 'stretch :height '(lh 1)
       :flex-grow 1 :flex-basis '(px 0)
       :min-width '(px 0) :text-align 'center
       :font-weight 'bold
       :color (if (etaf-ui--reactive-value active)
                  (etaf-ui--style-token :ui-window-title-active-fg)
                (etaf-ui--style-token :ui-window-title-fg))
       (text :font-size title-font-size :font-family font-family
             ;; A reactive title is read like a reactive Label text; passing
             ;; the source through would reach the Text Host as an object.
             (expr (etaf-ui--text-value title)))))

(defun etaf-ui--window-title-style ()
  "Return the presentation shared by a title bar and its corner resize cells.
The panel copies these Theme-token properties so the title row keeps one
continuous background and bottom rule across the window's outer columns."
  (list :background-color (etaf-ui--style-token :ui-window-title-bg)
        :color (etaf-ui--style-token :ui-window-title-fg)
        :border-bottom (etaf-ui--style-border
                        (etaf-ui--style-token :ui-window-border))))

(etaf-define-component etaf-window-chrome
    (&key title (mode 'normal) (show-minimize t) (show-maximize t)
          (show-close t) (active t)
          on-minimize on-maximize on-restore on-close
          on-move (drag-lock-modifier 'shift)
          title-font-size font-family group ref class use)
  "Render a controlled window title bar and caller-owned action callbacks.

ON-MOVE receives Ebox's gesture plist from the title bar.  The component does
not change geometry; callers update their X/Y refs (or use an ETAF Behavior).
MODE selects the Zoom action's transition and the chrome's mode class; a
reactive MODE updates both without rebuilding the title bar.  Named `actions'
and default slots are projected after the built-in controls.  TITLE-FONT-SIZE
is nil to inherit typography, or a size ratio (1 is body text)."
  :validate
  (progn
    (etaf-check-prop :mode mode
                     (or (etaf-ref-p mode) (etaf-computed-p mode)
                         (memq mode '(normal minimized maximized)))
                     "normal, minimized or maximized" 'etaf-window-chrome)
    (dolist (entry `((:on-minimize . ,on-minimize)
                     (:on-maximize . ,on-maximize)
                     (:on-restore . ,on-restore)
                     (:on-close . ,on-close)
                     (:on-move . ,on-move)))
      (etaf-ui--window-callback (car entry) (cdr entry) 'etaf-window-chrome))
    (etaf-check-prop :active active
                     (or (etaf-ref-p active) (etaf-computed-p active)
                         (booleanp (etaf-ui--reactive-value active)))
                     "a boolean" 'etaf-window-chrome)
    (etaf-check-prop :drag-lock-modifier drag-lock-modifier
                     (or (null drag-lock-modifier)
                         (memq drag-lock-modifier
                               '(shift control meta super hyper)))
                     "nil or a supported modifier" 'etaf-window-chrome)
    (etaf-check-prop :title-font-size title-font-size
                     (or (null title-font-size)
                         (and (numberp title-font-size) (<= 0.3 title-font-size) (<= title-font-size 4)))
                     "nil or a size ratio (1 is body text)" 'etaf-window-chrome)
    (etaf-check-prop :font-family font-family
                     (or (null font-family) (stringp font-family))
                     "a string or nil" 'etaf-window-chrome)
    (etaf-check-prop :group group
                     (or (symbolp group) (stringp group) (numberp group))
                     "a scalar hover group key" 'etaf-window-chrome))
  :render
  (let* ((group (or group ref 'etaf-window-controls))
         (title-style (etaf-ui--window-title-style))
         (extra-actions (append (etaf-current-slot 'actions)
                                (etaf-current-slot 'default)))
         (left-actions
          (etaf-node 'etaf-window-controls
                     (list :mode mode :active active
                           :show-minimize show-minimize
                           :show-maximize show-maximize :show-close show-close
                           :on-minimize on-minimize :on-maximize on-maximize
                           :on-restore on-restore :on-close on-close
                           :group group)
                     nil))
         (title-node
          (etaf-node 'etaf-ui--window-title-surface
                     (list :title title :active active
                           :title-font-size title-font-size
                           :font-family font-family)
                     nil))
         (right-actions
          (etaf-node 'flex
                     (list :width '(ch 10) :height '(lh 1) :flex-shrink 0
                           :align-items 'center :justify-content 'end)
                     extra-actions))
         (children (list (etaf-node 'text nil (list " "))
                         left-actions title-node right-actions)))
    ;; The mode class is read inside the Host property so a reactive MODE
    ;; becomes one retained class binding instead of a title-bar re-render.
    (etaf-view
     (flex :class (etaf-ui--class-value "etaf-window-chrome"
                                        (etaf-ui--window-mode mode) class)
           :role 'heading :ref ref
           :width 'stretch
           :height '(lh 1) :z-index 30
           :font-size title-font-size :font-family font-family
           :pointer 'hand :drag-lock-modifier drag-lock-modifier
           :align-items 'center :justify-content 'center
           :padding '((lh 0) (ch 0))
           :background-color (plist-get title-style :background-color)
           :color (plist-get title-style :color)
           :border-bottom (plist-get title-style :border-bottom)
           :on-drag on-move
           :use use
           (expr children)))))

(etaf-define-component etaf-resizable-panel
    (&key (x '(px 0)) (y '(lh 0)) width height (position 'absolute)
          z-index (visible t) (min-width '(px 80)) max-width
          (min-height '(lh 2)) max-height (resizable t)
          (resize-edges etaf-ui--window-resize-edges) resize-refs resize-use
          on-resize on-move header-style drag-lock-modifier full-bleed
          font-size font-family ref id class role use overflow)
  "Render a controlled positioned panel with optional resize handles.

X, Y, WIDTH, HEIGHT, Z-INDEX, visibility and CLASS are passed to Ebox as
Host properties; they may be values, refs or computed values.  ON-MOVE
receives a gesture plist from the panel root, while ON-RESIZE receives EDGE
and that gesture plist.
Callbacks must update caller-owned geometry through ETAF's reactive APIs.
DRAG-LOCK-MODIFIER enables release-independent move and resize gestures;
nil keeps ordinary held-button tracking.  Ebox owns confirmation and cancel.
RESIZE-EDGES is a list of edge/corner symbols.  The `header' slot, when
supplied, owns the panel's first row between the corner cells; HEADER-STYLE
presents those corner cells like the header so its background and rule stay
closed across the row.  No geometry, constraints, z-order or interaction
state is retained by this Component.  FONT-SIZE is nil to inherit typography,
or a size ratio (1 is body text); FONT-FAMILY likewise inherits when nil."
  :validate
  (progn
    (etaf-check-prop :position position (memq position '(absolute relative))
                     "absolute or relative" 'etaf-resizable-panel)
    (etaf-check-prop :resizable resizable (booleanp resizable)
                     "a boolean" 'etaf-resizable-panel)
    (etaf-check-prop :resize-edges resize-edges
                     (and (proper-list-p resize-edges)
                          (cl-every (lambda (edge)
                                     (memq edge etaf-ui--window-resize-edges))
                                   resize-edges))
                     "a list of supported resize edges" 'etaf-resizable-panel)
    (etaf-check-prop :resize-refs resize-refs
                     (or (null resize-refs)
                         (and (proper-list-p resize-refs)
                              (cl-every
                               (lambda (entry)
                                 (and (consp entry)
                                      (memq (car entry) etaf-ui--window-resize-edges)
                                      (or (symbolp (cdr entry))
                                          (functionp (cdr entry)))))
                               resize-refs)))
                     "an edge-to-reference alist" 'etaf-resizable-panel)
    (etaf-check-prop :resize-use resize-use
                     (or (null resize-use)
                         (and (proper-list-p resize-use)
                              (cl-every
                               (lambda (entry)
                                 (and (consp entry)
                                      (memq (car entry) etaf-ui--window-resize-edges)))
                               resize-use)))
                     "an edge-to-Behavior alist" 'etaf-resizable-panel)
    (etaf-check-prop :full-bleed full-bleed (booleanp full-bleed)
                     "a boolean" 'etaf-resizable-panel)
    (etaf-ui--window-callback :on-resize on-resize 'etaf-resizable-panel)
    (etaf-ui--window-callback :on-move on-move 'etaf-resizable-panel)
    (etaf-check-prop :drag-lock-modifier drag-lock-modifier
                     (or (null drag-lock-modifier)
                         (memq drag-lock-modifier '(shift control meta super hyper)))
                     "nil or a supported modifier" 'etaf-resizable-panel)
    (etaf-check-prop :font-size font-size
                     (or (null font-size)
                         (and (numberp font-size) (<= 0.3 font-size) (<= font-size 4)))
                     "nil or a size ratio (1 is body text)" 'etaf-resizable-panel)
    (etaf-check-prop :font-family font-family
                     (or (null font-family) (stringp font-family))
                     "a string or nil" 'etaf-resizable-panel))
  :render
  (let* ((theme (etaf-ui--style-tokens :ui-window-fg :ui-window-bg :ui-window-border))
         (content (etaf-current-slot 'default))
         (header (etaf-current-slot 'header))
         (edges (and resizable (or on-resize resize-use) resize-edges))
         (framed (or header edges)))
    ;; Keep reactive geometry reads on Host properties.  The retained panel
    ;; frame, slots and gesture routes do not depend on each pointer position.
    (etaf-view
     (box :class (etaf-ui--class-value "etaf-resizable-panel" nil
                                       (etaf-ui--reactive-value class))
          :position position :left (etaf-ui--reactive-value x)
          :top (etaf-ui--reactive-value y)
          :width (etaf-ui--reactive-value width)
          :height (etaf-ui--reactive-value height)
          :z-index (etaf-ui--reactive-value z-index)
          :visibility (if (etaf-ui--reactive-value visible) 'visible 'hidden)
          :min-width (etaf-ui--reactive-value min-width)
          :max-width (etaf-ui--reactive-value max-width)
          :min-height (etaf-ui--reactive-value min-height)
          :max-height (etaf-ui--reactive-value max-height)
          :color (plist-get theme :ui-window-fg)
          :background-color (plist-get theme :ui-window-bg)
          :font-size font-size :font-family font-family
          :border (etaf-ui--style-border (plist-get theme :ui-window-border))
          :overflow (or overflow 'hidden) :ref ref :role (or role 'region)
          :on-drag on-move :use use :id id :drag-lock-modifier drag-lock-modifier
          (expr (if framed
                    (etaf-ui--panel-frame content edges on-resize
                                         resize-refs resize-use header header-style
                                         drag-lock-modifier full-bleed)
                  content))))))

(defun etaf-ui--window-keys (title-ref movable handle-refs edges)
  "Return window-wide `:keys' that move TITLE-REF and resize through handles.
MOVABLE enables M-arrows on the title bar.  HANDLE-REFS maps each active
resize edge in EDGES to its Host reference; M-S-arrows drag the right or
bottom edge, else the bottom-right corner, so focus anywhere in the window
moves or resizes it with the pointer's gesture handlers."
  (let* ((handle (lambda (preferred)
                   (cl-loop for edge in preferred
                            for ref = (cdr (assq edge handle-refs))
                            when (and (memq edge edges) ref (symbolp ref))
                            return ref)))
         (wide (funcall handle '(right bottom-right)))
         (tall (funcall handle '(bottom bottom-right)))
         (step (lambda (ref columns rows)
                 (lambda () (etaf-drag-step nil ref columns rows)))))
    (append
     (when movable
       (list (list "M-<left>" (funcall step title-ref -1 0) "Move window left")
             (list "M-<right>" (funcall step title-ref 1 0) "Move window right")
             (list "M-<up>" (funcall step title-ref 0 -1) "Move window up")
             (list "M-<down>" (funcall step title-ref 0 1) "Move window down")))
     (when wide
       (list (list "M-S-<right>" (funcall step wide 1 0) "Widen window")
             (list "M-S-<left>" (funcall step wide -1 0) "Narrow window")))
     (when tall
       (list (list "M-S-<down>" (funcall step tall 0 1) "Heighten window")
             (list "M-S-<up>" (funcall step tall 0 -1) "Shorten window"))))))

(etaf-define-component etaf-window
    (&key title (mode 'normal) (x '(px 0)) (y '(lh 0))
          (width '(ch 42)) (height '(lh 16)) z-index (visible t)
          (min-width '(px 160)) max-width (min-height '(lh 2)) max-height
          (resizable t) (resize-edges etaf-ui--window-resize-edges)
          resize-refs resize-use move-use full-bleed
          on-move on-resize on-focus on-minimize on-maximize on-restore on-close
          (drag-lock-modifier 'shift)
          title-font-size content-font-size font-family
          controls-group (controls-active t)
          (show-minimize t) (show-maximize t) (show-close t)
          ref id chrome-ref class use overflow)
  "Render a controlled window shell from `etaf-resizable-panel'.

The shell owns only presentation.  The caller owns MODE, X/Y, WIDTH/HEIGHT,
Z-INDEX and visibility and changes them through refs or ordinary props.  A
reactive MODE or VISIBLE updates the shell's mode classes, Zoom action and
content collapse as retained Host bindings without rebuilding the window; a
`minimized' window that stays visible collapses to its title bar.  The
title bar forwards ON-MOVE gestures; resize handles forward EDGE and gesture
to ON-RESIZE.  DRAG-LOCK-MODIFIER applies to both the title and all resize
handles; nil disables locking.  Action callbacks request a state transition.
With focus anywhere in the window, M-arrows move it through the title bar's
handlers and M-S-arrows resize it through the right/bottom handles.
ON-FOCUS runs for a press in the body and whenever focus enters the window.
TITLE-FONT-SIZE and CONTENT-FONT-SIZE independently inherit when nil (the
default), or accept size ratios.  FONT-FAMILY inherits when nil.
Slots are
`header' (extra title-bar content), `actions' (extra title-bar actions),
`default' (window body) and `footer'.  The default slot is wrapped in one
viewport region, so a Component rendered in the body reads the space it was
given as `(PIXELS . ROWS)` with `etaf-viewport'.  The window adds no inset of
its own and content owns its inner spacing; with FULL-BLEED the body rectangle
reaches the frame edges and enabled handles are hit strips over its edge
cells, while without it a handle keeps its own cell.  Pair FULL-BLEED with the
top edge and the corners when the body must stay seamless, since their cells
sit in the title row or in the content's own margin."
  :validate
  (progn
    (etaf-check-prop :mode mode
                     (or (etaf-ref-p mode) (etaf-computed-p mode)
                         (memq mode '(normal minimized maximized)))
                     "normal, minimized or maximized" 'etaf-window)
    (dolist (entry `((:on-move . ,on-move) (:on-resize . ,on-resize)
                     (:on-focus . ,on-focus)
                     (:on-minimize . ,on-minimize) (:on-maximize . ,on-maximize)
                     (:on-restore . ,on-restore) (:on-close . ,on-close)))
      (etaf-ui--window-callback (car entry) (cdr entry) 'etaf-window))
    (etaf-check-prop :drag-lock-modifier drag-lock-modifier
                     (or (null drag-lock-modifier)
                         (memq drag-lock-modifier
                               '(shift control meta super hyper)))
                     "nil or a supported modifier" 'etaf-window)
    (etaf-check-prop :controls-active controls-active
                     (or (etaf-ref-p controls-active)
                         (etaf-computed-p controls-active)
                         (booleanp (etaf-ui--reactive-value controls-active)))
                     "a boolean" 'etaf-window)
    (etaf-check-prop :title-font-size title-font-size
                     (or (null title-font-size)
                         (and (numberp title-font-size) (<= 0.3 title-font-size) (<= title-font-size 4)))
                     "nil or a size ratio (1 is body text)" 'etaf-window)
    (etaf-check-prop :content-font-size content-font-size
                     (or (null content-font-size)
                         (and (numberp content-font-size) (<= 0.3 content-font-size) (<= content-font-size 4)))
                     "nil or a size ratio (1 is body text)" 'etaf-window)
    (etaf-check-prop :full-bleed full-bleed (booleanp full-bleed)
                     "a boolean" 'etaf-window)
    (etaf-check-prop :font-family font-family
                     (or (null font-family) (stringp font-family))
                     "a string or nil" 'etaf-window))
  :bindings
  ;; Mode-dependent output is derived once per instance and read only inside
  ;; Host property expressions, so a reactive MODE publishes through retained
  ;; class, height and visibility bindings instead of re-rendering the shell.
  ((mode-input (etaf-prop 'mode))
   (visible-input (etaf-prop 'visible))
   ;; Window keys target the title bar and a resize handle, so both need a
   ;; Host reference even when the caller supplies none.
   (title-local-ref (etaf-local-ref 'title))
   (handle-local-refs
    (mapcar (lambda (edge) (cons edge (etaf-local-ref edge)))
            '(right bottom bottom-right)))
   (class-input (etaf-prop 'class))
   (live-mode (etaf-computed
               (lambda () (etaf-ui--window-mode (etaf-value mode-input)))))
   (collapsed (etaf-computed
               (lambda ()
                 (and (eq (etaf-value live-mode) 'minimized)
                      (etaf-ui--reactive-value (etaf-value visible-input))
                      t))))
   (panel-class (etaf-computed
                 (lambda ()
                   (etaf-ui--class-value "etaf-window" (etaf-value live-mode)
                                         (etaf-value class-input))))))
  :render
  (let* ((body (etaf-current-slot 'default))
         (header (etaf-current-slot 'header))
         (actions (etaf-current-slot 'actions))
         (title-ref (or chrome-ref title-local-ref))
         (handle-refs
          (append resize-refs
                  (cl-remove-if (lambda (entry) (assq (car entry) resize-refs))
                                handle-local-refs)))
         (active-edges
          (and resizable
               (cl-remove-if-not (lambda (edge)
                                   (or on-resize (assq edge resize-use)))
                                 resize-edges)))
         (keys (etaf-ui--window-keys title-ref (or on-move move-use)
                                     handle-refs active-edges))
         (footer (etaf-current-slot 'footer))
         (children
          (append (when body
                    (list (etaf-node 'etaf-viewport-region nil body)))
                  (when footer
                    (list (etaf-node 'row
                                     (list :class "etaf-window-footer"
                                           :width 'stretch)
                                     footer)))))
         (content
          (etaf-view
           (flex :class "etaf-window-content" :flex-direction 'column
                   :width 'stretch
                   :height (if (etaf-value collapsed) '(lh 0) 'stretch)
                   :visibility (if (etaf-value collapsed) 'hidden 'visible)
                   :font-size content-font-size
                   :font-family font-family
                   :overflow 'hidden
                   :pointer 'arrow
                   :on-press on-focus
                   :on-press-capture on-focus
                   (expr children))))
         (chrome
          (etaf-node 'etaf-window-chrome
                     (append (list :title title :mode live-mode :active controls-active
                                   :show-minimize show-minimize
                                   :show-maximize show-maximize :show-close show-close
                                   :on-minimize on-minimize :on-maximize on-maximize
                                   :on-restore on-restore :on-close on-close
                                   :title-font-size title-font-size
                                   :font-family font-family
                                   :drag-lock-modifier drag-lock-modifier
                                   :group controls-group
                                   :ref title-ref)
                             (when on-move (list :on-move on-move))
                             (when move-use (list :use move-use)))
                     header
                     (list (cons 'actions actions)))))
    (etaf-node 'etaf-resizable-panel
               (list :keys keys :on-focus-enter on-focus
                     :x x :y y :width width :height height :position 'absolute
                     :font-size (and title-font-size content-font-size
                                     (max title-font-size content-font-size))
                     :font-family font-family
                     :z-index z-index :visible visible :min-width min-width
                     :max-width max-width :min-height min-height :max-height max-height
                     :resizable resizable
                     :resize-edges resize-edges :resize-refs handle-refs
                     :resize-use resize-use :drag-lock-modifier drag-lock-modifier
                     :full-bleed full-bleed
                     :header-style (etaf-ui--window-title-style)
                     :on-resize on-resize
                     :ref ref :id id :class panel-class
                     :role 'dialog :use use :overflow overflow)
               (list content)
               (list (cons 'header (list chrome))))))

(provide 'etaf-ui-window)
;;; etaf-ui-window.el ends here
