;;; etaf-posframe-panel.el --- Floating panel rendering, focus and lifecycle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Panel dismissal hooks, title-bar and border painting, hover/focus tracking,
;; theme synchronization, panel mounting, reshaping, toggling and teardown.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'posframe)
(require 'etaf-posframe-pool)

(declare-function etaf-posframe--anchor-window "etaf-posframe-layout" (parent &optional preferred))
(declare-function etaf-posframe--frame-geometry "etaf-posframe-layout" (frame))
(declare-function etaf-posframe--reposition-one "etaf-posframe-layout" (panel &optional force))
(declare-function etaf-posframe--sync-external-move "etaf-posframe-layout" (panel))
(declare-function etaf-posframe--sync-modal-visibility "etaf-posframe-modal" (&optional _frame))
(declare-function etaf-posframe--window-size-changed "etaf-posframe-layout" (frame))
(declare-function etaf-posframe-drag "etaf-posframe-layout" (panel &optional on-done))
(declare-function etaf-posframe-live-p "etaf-posframe-layout" (panel))

;;; Dismissal

(defun etaf-posframe--auto-panel-p (panel)
  "Return non-nil when PANEL hides before the next outside command."
  (eq (plist-get (etaf-posframe--panel-options panel) :auto-hide) t))

(defun etaf-posframe--pre-command ()
  "Hide auto panels before a command that runs outside them."
  (unless etaf-posframe--dismissing
    (let ((etaf-posframe--dismissing t))
      (dolist (panel (copy-sequence etaf-posframe--panels))
        (when (and (etaf-posframe--auto-panel-p panel)
                   (not (eq (current-buffer)
                            (etaf-posframe--panel-buffer panel))))
          (etaf-posframe-hide panel))))))

(defun etaf-posframe--check-blur ()
  "Notify any panel whose focus moved away to a different frame."
  (unless (or etaf-posframe--dismissing etaf-posframe--dragging)
    (let ((selected (selected-frame)))
      (dolist (panel (copy-sequence etaf-posframe--panels))
        (let ((frame (etaf-posframe--panel-frame panel)))
          (cond
           ((eq selected frame)
            (setf (etaf-posframe--panel-focused panel) t))
           ((etaf-posframe--panel-focused panel)
            (setf (etaf-posframe--panel-focused panel) nil)
            (when-let* ((cb (plist-get (etaf-posframe--panel-options panel) :on-blur)))
              (when (functionp cb)
                (let ((p panel) (fn cb))
                  (run-at-time 0 nil
                               (lambda ()
                                 (when (and (etaf-posframe-live-p p)
                                            (not etaf-posframe--dragging)
                                            (not (eq (selected-frame)
                                                     (etaf-posframe--panel-frame p))))
                                   (ignore-errors (funcall fn p)))))))))))))))

(defun etaf-posframe--focus-change ()
  "Track which panel holds the focus and repaint after a focus change."
  (unless etaf-posframe--dismissing
    (etaf-posframe--check-blur)
    (etaf-posframe--refresh-hover)
    (etaf-posframe--paint-borders)
    (etaf-posframe--sync-activation)))

(defun etaf-posframe--refresh-hooks ()
  "Install the dismiss hooks exactly while a panel needs them."
  (if (cl-some #'etaf-posframe--auto-panel-p etaf-posframe--panels)
      (add-hook 'pre-command-hook #'etaf-posframe--pre-command)
    (remove-hook 'pre-command-hook #'etaf-posframe--pre-command))
  (if etaf-posframe--panels
      (add-hook 'post-command-hook #'etaf-posframe--follow-focus)
    (remove-hook 'post-command-hook #'etaf-posframe--follow-focus))
  (if etaf-posframe--panels
      (add-function :after after-focus-change-function
                    #'etaf-posframe--focus-change)
    (remove-function after-focus-change-function
                     #'etaf-posframe--focus-change))
  (if (cl-some #'etaf-posframe--panel-modal-p etaf-posframe--panels)
      (progn
        (add-hook 'window-buffer-change-functions #'etaf-posframe--sync-modal-visibility)
        (add-hook 'window-configuration-change-hook #'etaf-posframe--sync-modal-visibility))
    (remove-hook 'window-buffer-change-functions #'etaf-posframe--sync-modal-visibility)
    (remove-hook 'window-configuration-change-hook #'etaf-posframe--sync-modal-visibility))
  (etaf-posframe--watch-hover))

;;; Rendering

(defun etaf-posframe--lines (buffer)
  "Return the number of rendered lines in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (not (eobp))
          (forward-line 1)
          (cl-incf count))
        count))))

(defconst etaf-posframe--theme-modes
  '((light . "亮") (auto . "随") (dark . "暗"))
  "Segments of the title-bar theme toggle, in display order.
The selected one is the panel's current `:theme'.")

(defun etaf-posframe--header-format (header theme width &optional modes mode)
  "Return HEADER as a full-width title bar for THEME and WIDTH columns.
MODES, an alist of (MODE . LABEL), adds the theme toggle at the right with
MODE selected; a panel without a switch passes nil and keeps a plain title
bar.  A content may hold a mode its switch does not offer, as the reader's
sepia paper is, and the strip then shows its choices with none selected.

The bar keeps the panel surface and adds a single hairline below it: a band
lifted toward the foreground reads as a second surface in a light theme, and
the theme's `header-line' box would draw a coloured outline around it."
  (when header
    (let* ((text (concat " " header))
           (surface (etaf-posframe--mix (plist-get theme :ui-panel-bg)
                                        (plist-get theme :ui-panel-fg) 0.03))
           (strip (and modes
                       (etaf-toggle-strip
                        :options modes
                        :value (and (assq mode modes) mode)
                        :theme theme
                        :surface surface
                        :on-change #'etaf-posframe--choose-theme-mode)))
           (padding (max 0 (- width (string-width text)
                              (if strip (string-width strip) 0))))
           (plain (propertize (concat text (make-string padding ?\s))
                              'face (list :background surface
                                          :foreground (plist-get theme :ui-panel-fg)
                                          :weight 'bold
                                          :height 1.0
                                          ;; A theme may render its own header
                                          ;; line inverted and boxed; the title
                                          ;; bar keeps the panel's palette,
                                          ;; paints every column and owns its
                                          ;; own separator.
                                          :inverse-video nil
                                          :box nil
                                          :extend t)
                              'underline (list :color (plist-get theme :ui-panel-border)
                                               :style 'line))))
      ;; The strip keeps its own faces: `propertize' over the whole bar would
      ;; replace the segment faces with the title bar's.
      (concat plain (or strip "")))))

(defvar-local etaf-posframe--non-scrollable nil
  "Non-nil in panel buffers whose viewport is locked against scrolling.")

(defvar-local etaf-posframe--headerless-drag nil
  "Non-nil in headerless `:draggable t' panel buffers.")

(defvar etaf-posframe--no-scroll-map
  (let ((map (make-sparse-keymap)))
    (dolist (ev '(wheel-up wheel-down double-wheel-up double-wheel-down
                  triple-wheel-up triple-wheel-down mouse-4 mouse-5))
      (define-key map (vector ev) #'ignore))
    (define-key map [remap scroll-up-command] #'ignore)
    (define-key map [remap scroll-down-command] #'ignore)
    (define-key map [remap mwheel-scroll] #'ignore)
    map)
  "Keymap suppressing accidental viewport scrolling in `:scrollable nil' panels.")

(defvar etaf-posframe--just-dragged nil
  "Non-nil for one command cycle after dragging an unfocused headerless panel.")

(defun etaf-posframe--handle-headerless-drag (event)
  "Track drag on a headerless `:draggable t' panel; replay click if not dragged."
  (let* ((start (and (consp event) (event-start event)))
         (win (and start (posn-window start)))
         (frame (and (window-live-p win) (window-frame win)))
         (panel (and frame (etaf-posframe--panel-for-frame frame)))
         (was-focused (and frame (eq (selected-frame) frame))))
    (if (and panel (display-graphic-p))
        (let* ((on-move (plist-get (etaf-posframe--panel-options panel) :on-move))
               (moved (progn
                        (raise-frame frame)
                        (etaf-posframe-drag panel on-move))))
          (when (and moved (not was-focused))
            (setq etaf-posframe--just-dragged panel))
          moved)
      nil)))

(defvar etaf-posframe--headerless-drag-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1]
                (lambda (ev)
                  (interactive "e")
                  (etaf-posframe--handle-headerless-drag ev)))
    map)
  "Keymap enabling smooth body drag on headerless `:draggable t' panels.")

(add-to-list 'emulation-mode-map-alists
             (list (cons 'etaf-posframe--non-scrollable etaf-posframe--no-scroll-map)
                   (cons 'etaf-posframe--headerless-drag etaf-posframe--headerless-drag-map)))

(defun etaf-posframe--lock-scroll (panel &optional window)
  "Keep PANEL's WINDOW pinned to `point-min' when `:scrollable' is nil."
  (when (and panel (not (plist-get (etaf-posframe--panel-options panel) :scrollable)))
    (let* ((buf (etaf-posframe--panel-buffer panel))
           (win (or window (and (buffer-live-p buf) (get-buffer-window buf t)))))
      (when (and (buffer-live-p buf) (window-live-p win))
        (with-current-buffer buf
          (when (> (window-start win) (point-min))
            (set-window-start win (point-min) t)))))))

(defun etaf-posframe--ensure-terminal-borders ()
  "Configure solid box-drawing glyphs for terminal child-frame borders once."
  (when (and (not (display-graphic-p)) (not noninteractive))
    (require 'disp-table)
    (unless standard-display-table
      (setq standard-display-table (make-display-table)))
    (dolist (slot '((box-vertical . ?│) (box-horizontal . ?─)
                    (box-down-right . ?┌) (box-down-left . ?┐)
                    (box-up-right . ?└) (box-up-left . ?┘)))
      (unless (display-table-slot standard-display-table (car slot))
        (set-display-table-slot standard-display-table (car slot)
                                (make-glyph-code (cdr slot)))))))

(defun etaf-posframe--prepare-buffer (buffer header theme width &optional mode scrollable)
  "Set BUFFER up as a panel surface with HEADER and THEME.
MODE adds the title-bar theme toggle over `etaf-posframe--theme-modes', as in
`etaf-posframe--header-format'.  SCROLLABLE defaults to t; nil locks scroll."
  (etaf-posframe--ensure-terminal-borders)
  (let ((theme theme)
        (can-scroll (if (null scrollable) nil t)))
    (with-current-buffer buffer
      (erase-buffer)
      (setq-local truncate-lines t)
      (setq-local buffer-display-table
                  (copy-sequence (or buffer-display-table
                                     standard-display-table
                                     (make-display-table))))
      (set-display-table-slot buffer-display-table 'truncation ?\s)
      (setq-local header-line-format
                  (etaf-posframe--header-format
                   header theme width
                   (and (assq mode etaf-posframe--theme-modes)
                        etaf-posframe--theme-modes)
                   mode))
      (setq-local mode-line-format nil)
      (setq-local tab-line-format nil)
      (setq-local display-line-numbers nil)
      (setq-local frame-title-format "")
      (setq-local left-margin-width nil)
      (setq-local right-margin-width nil)
      (setq-local left-fringe-width nil)
      (setq-local right-fringe-width nil)
      (setq-local fringes-outside-margins 0)
      (setq-local fringe-indicator-alist nil)
      (setq-local show-trailing-whitespace nil)
      (setq-local cursor-type nil)
      (setq-local cursor-in-non-selected-windows nil)
      (setq-local vertical-scroll-bar nil)
      (setq-local horizontal-scroll-bar nil)
      (unless can-scroll
        (setq-local etaf-posframe--non-scrollable t)
        (setq-local scroll-margin 0)
        (setq-local scroll-conservatively 0)
        (setq-local auto-hscroll-mode nil))
      ;; Mouse tracking in the buffer would make Emacs select the frame under
      ;; the pointer whenever it moves, so leaving a panel would take the
      ;; keyboard with it.  A panel keeps Emacs' focus rules: only a click moves
      ;; the keyboard.  The hover border reads the pointer from a timer instead.
      (setq-local track-mouse nil))))

(defun etaf-posframe--clamp-terminal-poshandler (handler)
  "Return HANDLER with its result kept inside a terminal frame.
A terminal border takes a cell outside the frame size, so a poshandler that
puts the frame origin at a screen edge (`point' at the first column, for
example) would lose its left or top border."
  (lambda (info)
    (let ((position (funcall handler info))
          (bevel (etaf-posframe--terminal-bevel (plist-get info :posframe))))
      (if (zerop bevel)
          position
        (let ((width (+ (or (plist-get info :posframe-width) 0) bevel))
              (height (+ (or (plist-get info :posframe-height) 0) bevel))
              (parent-width (or (plist-get info :parent-frame-width) 0))
              (parent-height (or (plist-get info :parent-frame-height) 0)))
          (cons (max 1 (min (car position)
                            (max 1 (- parent-width width 1))))
                (max 1 (min (cdr position)
                            (max 1 (- parent-height height 1))))))))))

(defun etaf-posframe--placement-poshandler (placement options)
  "Return the poshandler for PLACEMENT with OPTIONS."
  (etaf-posframe--clamp-terminal-poshandler
   (let ((stack (plist-get options :stack)))
     (pcase (car placement)
       ('cells (etaf-posframe--cell-poshandler (cdr placement)))
       ('pixels (lambda (_info) (cdr placement)))
       ('function (cdr placement))
       ('anchor
        (if stack
            (etaf-posframe--stacking-poshandler (cdr placement))
          (etaf-posframe--poshandler (cdr placement))))
       ('anchor+offset
        (let* ((anchor (nth 1 placement))
               (offset (cons (nth 2 placement) (nth 3 placement)))
               (base (etaf-posframe--offset-poshandler
                      (etaf-posframe--poshandler anchor) offset)))
          (if stack
              (etaf-posframe--stacking-poshandler anchor base)
            base)))))))

(defun etaf-posframe--frame-args (panel lines)
  "Return the `posframe-show' arguments for PANEL showing LINES of content."
  (let* ((options (etaf-posframe--panel-options panel))
         (title (plist-get options :title))
         (border (plist-get options :border))
         (theme-ref (etaf-posframe--panel-theme panel))
         (theme (and theme-ref (etaf-value theme-ref))))
    (append
     (list :width (plist-get options :width)
           :height (+ lines (if title 1 0))
           :min-height (+ 1 (if title 1 0))
           :left-fringe 0
           :right-fringe 0
           ;; A frame mid-drag is narrower than the canvas it still shows.
           ;; Posframe writes `truncate-lines' from this key, so without it
           ;; the old rows wrap and the board scrambles until the fit runs.
           :lines-truncate t
           :border-width (if (display-graphic-p)
                             (or (plist-get border :width)
                                 etaf-posframe-border-width)
                           ;; A terminal draws a frame border one cell wide, so a
                           ;; wider request keeps the border instead of the
                           ;; exact width.
                           (if (> (or (plist-get border :width)
                                      etaf-posframe-border-width)
                                  0)
                               1
                             0))
           :border-color (or (plist-get border :color)
                             (plist-get theme :ui-panel-border))
           :internal-border-width 0
           :respect-header-line (and title t)
           :accept-focus (and (plist-get options :focusable) t)
           ;; The frame paint matches the canvas surface so a sub-cell
           ;; remainder at the edge cannot show a second colour.
           :background-color (or (plist-get theme :ui-panel-bg) "#FFFFFF")
           :foreground-color (or (plist-get theme :ui-fg) "#000000")
           :override-parameters
           (append
            '((horizontal-scroll-bars . nil)
              (vertical-scroll-bars . nil)
              (top-visible . 24)
              (snap-width . 12))
            (when (etaf-posframe--draggable-p options)
              '((drag-with-header-line . t)))
            (when (null (plist-get options :resizable))
              '((drag-internal-border . nil)))))
     (list :poshandler
           (etaf-posframe--placement-poshandler
            (etaf-posframe--placement (plist-get options :at))
            options)))))

(defun etaf-posframe--fit (panel)
  "Fit PANEL's Runtime to WINDOW's frame width and its body height.
Follow the frame width, not the window's, because a transient scroll bar
would otherwise narrow the canvas and leave a scroll bar strip on the right."
  (let ((runtime (etaf-posframe--panel-runtime panel))
        (width (plist-get (etaf-posframe--panel-options panel) :pixel-width)))
    (etaf-runtime-refit runtime width nil)))

(defun etaf-posframe--text-height (panel window)
  "Return the pixel height of PANEL's rendered content in WINDOW.
A terminal cell is one pixel, and `window-text-pixel-size' counts the header
line there as one of the rows it measures.  Counting the buffer's text rows
keeps the frame at header plus content instead of adding a blank row."
  (condition-case nil
      (with-current-buffer (etaf-posframe--panel-buffer panel)
        (save-excursion
          (goto-char (point-max))
          ;; Preserve background-painted bottom padding rows (e.g. `:padding ((lh 1) ...)').
          ;; Only strip trailing newlines and unpainted trailing whitespace.
          (skip-chars-backward "\n")
          (unless (etaf-posframe--panel-modal-p panel)
            (while (and (> (point) (point-min))
                        (memq (char-before) '(?\s ?\t ?\n))
                        (not (let ((f (get-text-property (1- (point)) 'face)))
                               (and (listp f) (plist-get f :background)))))
              (backward-char 1)))
          (if (display-graphic-p)
              (cdr (window-text-pixel-size window nil (point) nil 10000 t))
            (* (count-lines (point-min) (point))
               (frame-char-height (window-frame window))))))
    (error nil)))

(defun etaf-posframe--row-budget (panel)
  "Return PANEL's content row budget, the `:height' it opened with."
  (let ((options (etaf-posframe--panel-options panel)))
    (or (plist-get options :height) etaf-posframe-default-max-height)))

(defun etaf-posframe--resize-to-content (panel window)
  "Fit PANEL's frame height to WINDOW's rendered rows.
The rendered content decides the height, but never beyond the rows the panel
was opened for: a View that fills its viewport, such as a complete app, would
otherwise stretch the frame to the measuring budget.  The clamp also keeps a
transient measurement from stretching the frame into an empty rectangle.
Return non-nil when the frame size changed; sizing a frame to the size it
already has is what turns one resize into a stream of size-change hooks."
  (let* ((frame (window-frame window))
         (options (etaf-posframe--panel-options panel))
         (width (plist-get options :pixel-width))
         (line (frame-char-height frame))
         (header (if (plist-get options :title)
                     (window-header-line-height window)
                   0))
         (limit (+ (* (etaf-posframe--row-budget panel) line) header))
         (content (+ (or (etaf-posframe--text-height panel window) 0) header))
         ;; `:fill-height' keeps the frame at the row budget, so an application
         ;; with a fixed-size board gets a full stage and the surface fills the
         ;; rest.
         (height (if (plist-get options :fill-height)
                     limit
                   (min content limit))))
    ;; `set-frame-size' with PIXELWISE non-nil sets the frame's text area
    ;; (`frame-text-width' / `frame-text-height'), excluding child-frame
    ;; borders.  Comparing against `frame-pixel-width' / `frame-pixel-height'
    ;; always differed by `2 * border-width', causing every refresh to resize
    ;; and reposition even when the frame already matched its exact size.
    (when (and width (> height 0)
               (or (/= width (frame-text-width frame))
                   (/= height (frame-text-height frame))))
      (set-frame-size frame width height t)
      t)))

(defun etaf-posframe--fit-height (panel window)
  "Lay PANEL out in its row budget, then fit the frame to the content."
  (let* ((options (etaf-posframe--panel-options panel))
         (width (plist-get options :pixel-width))
         (runtime (etaf-posframe--panel-runtime panel)))
    ;; The measuring layout uses the row budget rather than an open-ended
    ;; height: a View that paints a full viewport would report that budget as
    ;; its content, and its `:height' rows are what the panel promises.
    (etaf-runtime-refit runtime width (etaf-posframe--row-budget panel))
    (etaf-posframe--resize-to-content panel window)
    (etaf-runtime-refit runtime width nil)
    (etaf-posframe--fit panel)
    (etaf-posframe--lock-scroll panel window)))

(defvar posframe-mouse-banish-function)

(defun etaf-posframe--show-frame (panel lines)
  "Show PANEL's frame for LINES of content and return its frame.
On graphical displays, reuses a parked child frame when available and
configures it while hidden so neither `delete-frame' nor intermediate
flashes occur.  On text terminals, keeps the cell-based posframe path."
  (let* ((posframe-mouse-banish-function #'ignore)
         (budget (etaf-posframe--row-budget panel))
         ;; A filled panel is created at its full height, so the poshandler
         ;; places the stage it will keep instead of the one-row frame a short
         ;; View produces before the fit.
         (lines (max 1 (if (plist-get (etaf-posframe--panel-options panel)
                                      :fill-height)
                           budget
                         (min lines budget))))
         (buffer (etaf-posframe--panel-buffer panel))
         (parent-frame (etaf-posframe--panel-parent-frame panel)))
    (if (display-graphic-p)
        (let* ((etaf-posframe--positioning t)
               (pooled (etaf-posframe--acquire-pooled-frame parent-frame))
               (frame
                (if pooled
                    (etaf-posframe--configure-pooled-frame pooled panel lines)
                  (let* ((args (etaf-posframe--frame-args panel lines))
                         (ov (copy-sequence (plist-get args :override-parameters)))
                         (ov (cons '(visibility . nil)
                                   (assq-delete-all 'visibility ov)))
                         (hidden-args (plist-put (copy-sequence args)
                                                 :override-parameters ov)))
                    (if (fboundp 'posframe--make-frame-visible)
                        (cl-letf (((symbol-function 'posframe--make-frame-visible)
                                   #'ignore))
                          (apply #'posframe-show buffer hidden-args))
                      (apply #'posframe-show buffer hidden-args)))))
               (window (if (frame-live-p frame)
                           (frame-root-window frame)
                         (get-buffer-window buffer t))))
          (unless (window-live-p window)
            (signal 'etaf-posframe-error (list "Panel frame did not appear" buffer)))
          (setf (etaf-posframe--panel-frame panel) frame)
          (set-window-scroll-bars window 0 nil nil)
          (etaf-posframe--fit-height panel window)
          (etaf-posframe--reposition-one panel t)
          (unless (frame-visible-p frame)
            (make-frame-visible frame))
          (when (etaf-posframe--resize-to-content panel window)
            (etaf-posframe--reposition-one panel t))
          (etaf-posframe--remember-size panel window)
          frame)
      (let ((args (etaf-posframe--frame-args panel lines))
            (etaf-posframe--positioning t))
        (apply #'posframe-show buffer args)
        (dotimes (_ 2)
          (let ((window (get-buffer-window buffer t)))
            (when (window-live-p window)
              (set-window-scroll-bars window 0 nil nil)
              (etaf-posframe--fit panel)
              (let ((settled (min budget (etaf-posframe--lines buffer))))
                (unless (= settled lines)
                  (setq lines settled)
                  (apply #'posframe-show buffer
                         (plist-put (copy-sequence args) :height
                                    (+ settled (if (plist-get
                                                    (etaf-posframe--panel-options panel)
                                                    :title)
                                                   1 0)))))))))
        (let ((window (get-buffer-window buffer t)))
          (unless (window-live-p window)
            (signal 'etaf-posframe-error (list "Panel frame did not appear" buffer)))
          (set-window-scroll-bars window 0 nil nil)
          (etaf-posframe--fit-height panel window)
          (let ((settled (+ (window-body-height window)
                            (if (plist-get (etaf-posframe--panel-options panel) :title)
                                1
                              0))))
            (unless (= settled lines)
              (apply #'posframe-show buffer
                     (plist-put (copy-sequence args) :height settled))
              (etaf-posframe--fit-height panel window)))
          (setf (etaf-posframe--panel-frame panel) (window-frame window))
          (etaf-posframe--reposition-one panel)
          (etaf-posframe--remember-size panel window)
          (window-frame window))))))

(defun etaf-posframe--border-color (panel focused hovered)
  "Return PANEL's border colour for the FOCUSED or HOVERED state.
Focus and hover are the accent mixed into the surface, so the theme's own
hue still shows without a saturated one-pixel outline; hover is the weaker
hint and focus is the stronger one."
  (let* ((theme-ref (etaf-posframe--panel-theme panel))
         (palette (and (etaf-ref-p theme-ref) (etaf-value theme-ref)))
         (options (etaf-posframe--panel-options panel))
         (border (plist-get options :border))
         (surface (or (plist-get palette :ui-panel-bg)
                      (plist-get palette :ui-panel-border)))
         (resting (or (plist-get border :color)
                      (plist-get palette :ui-panel-border)))
         (accent (or (plist-get border :focus)
                     (plist-get palette :ui-accent))))
    (cond ((and focused (plist-get border :focus)) (plist-get border :focus))
          (focused (and accent (etaf-posframe--mix surface accent
                                                   etaf-posframe-border-focus-strength)))
          ;; A hovered panel does not hold the keyboard, so it takes a weak
          ;; accent hint; the border commits to the accent when the click lands.
          (hovered (or (plist-get border :hover)
                       (and accent (etaf-posframe--mix surface accent
                                                      etaf-posframe-border-hover-strength))))
          (t resting))))

(defun etaf-posframe--paint-border (panel)
  "Colour PANEL's border by whether it holds the focus or the pointer."
  (let ((frame (etaf-posframe--panel-frame panel)))
    (when (frame-live-p frame)
      (let* ((face (if (facep 'child-frame-border)
                       'child-frame-border
                     'internal-border))
             (color (etaf-posframe--border-color
                     panel (eq (selected-frame) frame)
                     (eq panel etaf-posframe--hover-panel))))
        (when (and color (not (equal color (face-attribute face :background frame))))
          (set-face-background face color frame))))))

(defvar etaf-posframe--painted-focus nil
  "Frame the panel borders were last painted for.")


(defun etaf-posframe--paint-borders ()
  "Refresh the focus border of every live panel."
  (setq etaf-posframe--painted-focus (selected-frame))
  (dolist (panel etaf-posframe--panels)
    (ignore-errors (etaf-posframe--paint-border panel))))

(defun etaf-posframe--pointer-panel ()
  "Return the panel under the mouse pointer, or nil.
`mouse-pixel-position' asks the window system which frame has the pointer,
child frames included, so this is the hover question itself.  The current
buffer cannot answer it: a motion command inside a panel runs while another
frame still holds the keyboard."
  (let* ((position (and (display-graphic-p) (mouse-pixel-position)))
         (frame (car-safe position))
         (x (and (consp (cdr-safe position)) (cadr position)))
         (y (let ((tail (cdr-safe (cdr-safe position))))
              (if (consp tail) (car tail) tail))))
    (when (and (frame-live-p frame)
               (numberp x) (numberp y)
               (>= x 0) (< x (frame-pixel-width frame))
               (>= y 0) (< y (frame-pixel-height frame)))
      (cl-find-if (lambda (panel)
                    (and (plist-get (etaf-posframe--panel-options panel)
                                    :focusable)
                         (eq (etaf-posframe--panel-frame panel) frame)))
                  etaf-posframe--panels))))

(defun etaf-posframe--refresh-hover ()
  "Point the hover hint at the panel under the pointer.
Return that panel, and paint only when the hint moved."
  (let ((panel (etaf-posframe--pointer-panel)))
    (unless (eq panel etaf-posframe--hover-panel)
      (setq etaf-posframe--hover-panel panel)
      (etaf-posframe--paint-borders))
    panel))

(defun etaf-posframe--watch-hover ()
  "Keep one pointer timer exactly while a panel frame is on screen.
Entering a panel runs a motion command, which paints the hint at once; leaving
one runs no command in the buffer the pointer lands in, so a reading clears the
hint instead.  A reading is one position query, not a poll of an application."
  (if (cl-some (lambda (panel)
                 (frame-live-p (etaf-posframe--panel-frame panel)))
               etaf-posframe--panels)
      (unless (timerp etaf-posframe--hover-timer)
        (setq etaf-posframe--hover-timer
              (run-with-timer etaf-posframe--hover-interval
                              etaf-posframe--hover-interval
                              #'etaf-posframe--refresh-hover)))
    (when (timerp etaf-posframe--hover-timer)
      (cancel-timer etaf-posframe--hover-timer)
      (setq etaf-posframe--hover-timer nil)
      (setq etaf-posframe--hover-panel nil))))

(defun etaf-posframe--focus-pointer-panel ()
  "Give the keyboard to the panel the pointer rests on.
Only a panel that accepts the keyboard enters the hover state."
  (when-let* ((panel etaf-posframe--hover-panel)
              (frame (etaf-posframe--panel-frame panel)))
    (unless (eq (selected-frame) frame)
      (etaf-posframe--restore-input-focus frame)
      (setf (etaf-posframe--panel-focused panel) t))))

(defun etaf-posframe--sync-activation ()
  "Show or hide the panel frames with Emacs' activation.
Hiding is what keeps the child frames out of the window manager's window list
while another application is in front."
  (when (and etaf-posframe-hide-inactive (display-graphic-p))
    (let ((active (cl-some #'frame-focus-state (frame-list))))
      (dolist (panel etaf-posframe--panels)
        (let ((frame (etaf-posframe--panel-frame panel)))
          (when (frame-live-p frame)
            (if active
                (unless (frame-parameter frame 'visibility)
                  (make-frame-visible frame))
              (when (frame-parameter frame 'visibility)
                (make-frame-invisible frame)))))))))

(defun etaf-posframe--raise-clicked-panel ()
  "Bring the panel a mouse button was pressed in to the front.
Emacs selects the clicked child frame but leaves the stacking order alone, so a
panel behind another stayed covered even while it held the keyboard.  Clicking
any part of a window is expected to raise it, so the click itself does that;
the keyboard only moves when the panel accepts it."
  (ignore-errors
    (let* ((event last-command-event)
           (position (and (consp event)
                          (memq (event-basic-type event)
                                '(mouse-1 mouse-2 mouse-3))
                          (event-start event)))
           (window (and position (posn-window position)))
           (frame (cond ((window-live-p window) (window-frame window))
                        ((frame-live-p window) window)))
           (panel (and frame (etaf-posframe--panel-for-frame frame))))
      (when panel
        (raise-frame frame)
        (if (eq panel etaf-posframe--just-dragged)
            (setq etaf-posframe--just-dragged nil)
          (when (and (window-live-p window)
                     (plist-get (etaf-posframe--panel-options panel) :focusable)
                     (not (eq (selected-frame) frame)))
            (let ((cur (selected-frame)))
              (when (and (frame-live-p cur) (null (frame-parent cur)))
                (setf (etaf-posframe--panel-restore-frame panel) cur
                      (etaf-posframe--panel-restore-window panel) (selected-window))))
            (select-window window)
            (setf (etaf-posframe--panel-focused panel) t)))))))

(defun etaf-posframe--follow-focus ()
  "Follow the pointer and the selection for the panel borders.
The panel under the pointer gets the hover border without taking the keyboard;
the keyboard moves only on a click, or on hover when
`etaf-posframe-focus-follows-mouse' asks for it."
  (dolist (panel (copy-sequence etaf-posframe--panels))
    (ignore-errors (etaf-posframe--sync-external-move panel)))
  (etaf-posframe--refresh-hover)
  (etaf-posframe--raise-clicked-panel)
  (etaf-posframe--check-blur)
  (when etaf-posframe-focus-follows-mouse
    (etaf-posframe--focus-pointer-panel))
  (etaf-posframe--sync-activation)
  (etaf-posframe--paint-borders))

(defun etaf-posframe--top-frame (&optional frame)
  "Return the top level frame above FRAME.
A panel is never derived from another panel's frame: a child frame, possibly a
stale one, would give it that frame's face metrics and colours."
  (let ((frame (or frame (selected-frame))))
    (while (and (frame-live-p frame) (frame-parent frame))
      (setq frame (frame-parent frame)))
    (if (etaf-posframe--frame-active-p frame)
        frame
      (or (cl-find-if (lambda (candidate)
                        (and (etaf-posframe--frame-active-p candidate)
                             (null (frame-parent candidate))))
                      (frame-list))
          (selected-frame)))))

(defun etaf-posframe--restore-input-focus (frame)
  "Select FRAME and give it the window system's input focus.
`select-frame' alone leaves the system without a key window after a focused
child frame is hidden or deleted, which then swallows the next command."
  (when (etaf-posframe--frame-active-p frame)
    (select-frame-set-input-focus frame)))

(defun etaf-posframe--release-buffer-frame (buffer &optional frame parent-frame)
  "Release the child frame associated with BUFFER safely.
On graphical displays, parks the child frame for reuse instead of calling
`delete-frame', avoiding macOS NS `NSTextInputContext' crashes inside
`ns_free_frame_resources'.  On text terminals, deletes the frame."
  (let ((target (or (and (frame-live-p frame) frame)
                    (and (buffer-live-p buffer)
                         (fboundp 'posframe--find-existing-posframe)
                         (posframe--find-existing-posframe buffer)))))
    (cond
     ((and (frame-live-p target) (display-graphic-p target) (frame-parent target))
      (etaf-posframe--park-frame target parent-frame))
     ((buffer-live-p buffer)
      (ignore-errors (posframe-hide buffer))
      (ignore-errors (posframe-delete-frame buffer)))
     ((frame-live-p target)
      (ignore-errors (make-frame-invisible target))
      (unless (display-graphic-p target)
        (let ((delete-frame-functions nil))
          (ignore-errors (delete-frame target))))))))

(defun etaf-posframe--teardown (panel)
  "Release PANEL's frame, Runtime and timer without callbacks."
  (let* ((etaf-posframe--dismissing t)
         (etaf-posframe--fitting t)
         (buffer (etaf-posframe--panel-buffer panel))
         (frame (etaf-posframe--panel-frame panel))
         (parent (etaf-posframe--panel-parent panel))
         (parent-frame (etaf-posframe--panel-parent-frame panel))
         (restore (etaf-posframe--panel-restore-frame panel))
         (restore-win (etaf-posframe--panel-restore-window panel)))
    ;; Hide nested panels parented to BUFFER first so nested modal chains
    ;; (such as `?' help over a dialog) unwind in LIFO order before FRAME is
    ;; parked.
    (when (buffer-live-p buffer)
      (dolist (child (copy-sequence etaf-posframe--panels))
        (when (and (not (eq child panel))
                   (eq (etaf-posframe--panel-parent child) buffer))
          (etaf-posframe-hide child))))
    (when (buffer-live-p parent)
      (with-current-buffer parent
        (unless (cl-some (lambda (other)
                           (eq (etaf-posframe--panel-parent other) parent))
                         etaf-posframe--panels)
          (remove-hook 'kill-buffer-hook #'etaf-posframe--parent-killed t))
        (when (eq etaf-posframe--parent-panel panel)
          (setq etaf-posframe--parent-panel nil))))
    ;; Hiding a child frame that held the window system's focus leaves macOS
    ;; without a key window unless input focus moves back before `orderOut:'.
    ;; Never restore focus to a pooled/parked frame; fall back to the active
    ;; top-level parent frame instead.
    (let* ((target-restore
            (cond
             ((and (etaf-posframe--frame-active-p restore)
                   (not (eq restore frame)))
              restore)
             ((and (etaf-posframe--frame-active-p parent-frame)
                   (not (eq parent-frame frame)))
              parent-frame)
             (t (let ((top (etaf-posframe--top-frame parent-frame)))
                  (and (etaf-posframe--frame-active-p top)
                       (not (eq top frame))
                       top)))))
           (need-restore
            (and target-restore
                 (or (eq (selected-frame) frame)
                     (etaf-posframe--panel-focused panel)
                     (and restore
                          (frame-live-p frame)
                          (frame-parent frame)
                          (not (frame-focus-state frame)))))))
      (when need-restore
        (etaf-posframe--restore-input-focus target-restore)
        (when (frame-parent target-restore)
          (raise-frame target-restore))
        (when (and (window-live-p restore-win)
                   (eq (window-frame restore-win) target-restore))
          (select-window restore-win))))
    (setf (etaf-posframe--panel-focused panel) nil)
    (when-let* ((timer (etaf-posframe--panel-timer panel)))
      (cancel-timer timer)
      (setf (etaf-posframe--panel-timer panel) nil))
    (when-let* ((timer (etaf-posframe--panel-fit-timer panel)))
      (cancel-timer timer)
      (setf (etaf-posframe--panel-fit-timer panel) nil))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when etaf-posframe--surface-scope
          (ignore-errors (etaf-scope-stop etaf-posframe--surface-scope))
          (setq etaf-posframe--surface-scope nil))))
    ;; Park (graphical) or delete (TTY) the child frame BEFORE killing BUFFER
    ;; so the root window is un-dedicated and switched to the park buffer first.
    (etaf-posframe--release-buffer-frame buffer frame parent-frame)
    (setf (etaf-posframe--panel-frame panel) nil)
    (when (buffer-live-p buffer)
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (ignore-errors (etaf-unmount runtime)))
      (ignore-errors (kill-buffer buffer)))))

;;;###autoload
(defun etaf-posframe--focus (panel)
  "Select PANEL's frame and window, remembering the host frame to restore."
  (let ((frame (etaf-posframe--panel-frame panel)))
    (when (etaf-posframe--frame-active-p frame)
      (unless (eq (selected-frame) frame)
        (setf (etaf-posframe--panel-restore-frame panel)
              (etaf-posframe--top-frame (selected-frame))))
      (select-frame frame)
      (when (frame-parameter frame 'window-id)
        (ignore-errors (x-focus-frame frame)))
      (when-let* ((window (get-buffer-window (etaf-posframe--panel-buffer panel) t)))
        (select-window window)
        (when (not (plist-get (etaf-posframe--panel-options panel) :scrollable))
          (etaf-posframe--lock-scroll panel window))
        (setf (etaf-posframe--panel-focused panel) t)))
    (etaf-posframe--paint-borders)))

;;;###autoload
(defun etaf-posframe-focus (panel)
  "Give input focus to live focusable PANEL and return PANEL when focused."
  (when (and (etaf-posframe-live-p panel)
             (plist-get (etaf-posframe--panel-options panel) :focusable))
    (etaf-posframe--focus panel)
    panel))

;;;###autoload
(defun etaf-posframe-unfocus (panel)
  "Return input focus from PANEL back to its host frame without hiding PANEL."
  (when (etaf-posframe-live-p panel)
    (let* ((frame (etaf-posframe--panel-frame panel))
           (restore (or (let ((r (etaf-posframe--panel-restore-frame panel)))
                          (and (etaf-posframe--frame-active-p r)
                               (not (eq r frame))
                               r))
                        (let ((p (etaf-posframe--panel-parent-frame panel)))
                          (and (etaf-posframe--frame-active-p p)
                               (not (eq p frame))
                               p)))))
      (setf (etaf-posframe--panel-focused panel) nil)
      (when (and (etaf-posframe--frame-active-p restore)
                 (eq (selected-frame) frame))
        (etaf-posframe--restore-input-focus restore)
        (etaf-posframe--paint-borders)
        t))))

(defun etaf-posframe-hide (&optional panel)
  "Hide PANEL and release its Runtime, timer and frame.
PANEL defaults to the panel of the current buffer.  Return non-nil when a live
panel was hidden."
  (interactive)
  (when-let* ((panel (or panel (etaf-posframe--current-panel))))
    (unless (etaf-posframe--panel-closed-p panel)
      (setf (etaf-posframe--panel-closed-p panel) t)
      (setq etaf-posframe--panels (delq panel etaf-posframe--panels))
      (when (eq panel etaf-posframe--hover-panel)
        (setq etaf-posframe--hover-panel nil))
      (etaf-posframe--teardown panel)
      (etaf-posframe--refresh-hooks)
      (etaf-posframe--paint-borders)
      (when-let* ((callback (etaf-posframe--panel-close-callback panel)))
        (condition-case error
            (funcall callback panel)
          (error (message "ETAF panel close callback failed: %s"
                          (error-message-string error)))))
      t)))

(defun etaf-posframe--set-frame-palette (frame palette)
  "Paint FRAME as PANEL's surface from PALETTE.
A theme switch resets a child frame's default face, so the surface colours and
that face are set together; setting only the frame parameters leaves text
without an explicit background on the old theme's colour.  The surface, not
the page, is the frame paint: a sub-cell remainder at the edge must not show a
second colour."
  (set-face-attribute 'default frame
                      :background (plist-get palette :ui-panel-bg)
                      :foreground (plist-get palette :ui-panel-fg))
  (set-frame-parameter frame 'background-color (plist-get palette :ui-panel-bg))
  (set-frame-parameter frame 'foreground-color (plist-get palette :ui-fg)))

(defun etaf-posframe--hold-theme (panel)
  "Keep PANEL on the palette it already paints.
`load-theme' changes the default face of every frame before it reports the
switch, and disabling every theme resets a child frame to white.  Holding the
palette keeps either intermediate state off the screen; the coalesced pass
then re-derives once."
  (let* ((theme (etaf-posframe--panel-theme panel))
         (palette (and (etaf-ref-p theme) (etaf-value theme)))
         (frame (etaf-posframe--panel-frame panel)))
    (when (and palette (frame-live-p frame))
      (etaf-posframe--set-frame-palette frame palette)
      (ignore-errors (etaf-posframe--paint-border panel)))))

(defun etaf-posframe--panel-adopted-p (panel)
  "Return non-nil when PANEL's content declared the surface it paints.
The slot itself always exists; only a content that declared its Theme owns
the palette, and only then does the panel paint that palette."
  (let ((surface (etaf-posframe--panel-surface panel)))
    (and surface (etaf-surface-theme surface) t)))

(defun etaf-posframe--panel-modes (panel)
  "Return (MODES MODE) PANEL's title bar offers, or nil when it has no switch.
An application that declared its surface brings its own modes and its own
mode cell; otherwise the panel offers its own `:theme' mode."
  (let* ((surface (etaf-posframe--panel-surface panel))
         (modes (and surface (etaf-surface-modes surface)))
         (mode-ref (and surface (etaf-surface-mode surface))))
    (if (and modes mode-ref)
        (list modes (etaf-value mode-ref))
      (let ((option (plist-get (etaf-posframe--panel-options panel) :theme)))
        (when (memq option '(light auto dark))
          (list etaf-posframe--theme-modes option))))))

(defun etaf-posframe--refresh-header (panel palette &optional width)
  "Rebuild PANEL's title bar for PALETTE and the mode it currently shows.
WIDTH, when given, is the new content width of a panel being resized."
  (let ((buffer (etaf-posframe--panel-buffer panel))
        (options (etaf-posframe--panel-options panel))
        (offered (etaf-posframe--panel-modes panel)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local header-line-format
                    (etaf-posframe--header-format
                     (plist-get options :title) palette
                     (or width (plist-get options :width))
                     (nth 0 offered) (nth 1 offered)))))))

(defun etaf-posframe--update-appearance (panel)
  "Point PANEL's appearance ref at the appearance its content should see.
An application that declared its surface follows the parent frame, because
the panel frame itself now paints that application's palette; every other
panel passes the polarity of its own palette."
  (let ((appearance (etaf-posframe--panel-appearance panel))
        (theme (etaf-posframe--panel-theme panel))
        (parent (etaf-posframe--panel-parent-frame panel)))
    (when (etaf-ref-p appearance)
      (let ((value
             (if (etaf-posframe--panel-adopted-p panel)
                 (let ((bg (and (frame-live-p parent)
                                (etaf-posframe--color
                                 (face-attribute 'default :background parent)))))
                   (if (and bg (etaf-posframe--dark-color-p bg)) 'dark 'light))
               (plist-get (and (etaf-ref-p theme) (etaf-value theme)) :ui-mode))))
        (when (and value (not (eq value (etaf-value appearance))))
          (etaf-batch (setf (etaf-value appearance) value)))))))

(defun etaf-posframe--apply-pinned-mode (panel surface)
  "Start SURFACE's content in PANEL's pinned mode, once.
The caller asked for that mode with `:theme' when it showed the panel, so a
content that owns its palette starts in it instead of in whatever its own
default is.  The mode cell then belongs to the content: the title-bar switch
writes it, and this function never overrides the choice again."
  (when (and surface (not (etaf-posframe--panel-pin-applied panel)))
    (let* ((options (etaf-posframe--panel-options panel))
           (pinned (plist-get options :theme))
           (modes (etaf-surface-modes surface))
           (mode-ref (etaf-surface-mode surface)))
      (when (and mode-ref (memq pinned '(light dark)) (assq pinned modes))
        (setf (etaf-posframe--panel-pin-applied panel) t)
        (unless (eq (etaf-value mode-ref) pinned)
          (etaf-set-value mode-ref pinned))))))

(defun etaf-posframe--sync-surface (panel)
  "Repaint PANEL's chrome from the surface its content declared.
A panel whose content owns its palette paints its frame, title bar and border
from that palette and offers that content's modes, so the switch in the title
bar and the application's own switch remain one state."
  (let ((theme-ref (etaf-posframe--panel-theme panel))
        (surface (etaf-posframe--panel-surface panel))
        (source (let ((surface (etaf-posframe--panel-surface panel)))
                  (and surface (etaf-surface-theme surface)))))
    (etaf-posframe--apply-pinned-mode panel surface)
    (when (and (etaf-ref-p theme-ref) source)
      (let ((palette (etaf-value source))
            (frame (etaf-posframe--panel-frame panel)))
        (unless (equal palette (etaf-value theme-ref))
          (etaf-batch (setf (etaf-value theme-ref) palette)))
        (when (frame-live-p frame)
          (ignore-errors (etaf-posframe--set-frame-palette frame palette))
          (ignore-errors (etaf-posframe--paint-border panel)))
        (etaf-posframe--update-appearance panel)
        (etaf-posframe--refresh-header panel (etaf-value theme-ref))))))

(defun etaf-posframe--watch-surface (panel)
  "Repaint PANEL's chrome whenever its content's surface changes.
The watcher lives in its own scope, held beside the panel buffer, so it is
released with the panel and never runs while the View renders."
  (let* ((buffer (etaf-posframe--panel-buffer panel))
         (surface (etaf-posframe--panel-surface panel)))
    (when (and surface (buffer-live-p buffer))
      (with-current-buffer buffer
        (let ((scope (etaf-effect-scope :detached t
                                        :name 'etaf-posframe-surface)))
          (setq etaf-posframe--surface-scope scope)
          (etaf-scope-run
           scope
           (lambda ()
             (etaf-watch
              (lambda ()
                (let ((theme (etaf-surface-theme surface))
                      (mode (etaf-surface-mode surface)))
                  (list (and theme (etaf-value theme))
                        (and mode (etaf-value mode)))))
              (lambda (_new _old)
                (when (buffer-live-p buffer)
                  (when-let* ((live (buffer-local-value 'etaf-posframe--panel
                                                        buffer)))
                    (etaf-posframe--sync-surface live))))
              :test #'equal
              :name 'etaf-posframe-surface))))))))

(defun etaf-posframe--apply-theme-to (panel)
  "Derive PANEL's Theme from its parent frame and repaint its title bar.
A pass that leaves the palette unchanged only re-asserts the frame colours,
because repainting the View is the expensive part of a theme change.  A panel
whose content declared its surface owns the palette already; the pass only
updates the appearance that content may follow."
  (if (etaf-posframe--panel-adopted-p panel)
      (progn
        (ignore-errors (etaf-posframe--hold-theme panel))
        (ignore-errors (etaf-posframe--update-appearance panel)))
    (let ((theme (etaf-posframe--panel-theme panel))
          (parent-frame (etaf-posframe--panel-parent-frame panel))
          (options (etaf-posframe--panel-options panel)))
      (when (and (etaf-ref-p theme) (frame-live-p parent-frame)
                 (memq (plist-get options :theme) '(auto light dark)))
        (ignore-errors
          (let* ((mode (plist-get options :theme))
                 (palette (etaf-posframe-theme
                           parent-frame
                           (and (not (eq mode 'auto)) mode)))
                 (frame (etaf-posframe--panel-frame panel)))
            (when (frame-live-p frame)
              (etaf-posframe--set-frame-palette frame palette))
            (unless (equal palette (etaf-value theme))
              (etaf-batch (setf (etaf-value theme) palette))
              (ignore-errors (etaf-posframe--paint-border panel))
              (ignore-errors (etaf-posframe--sync-activation)))
            (etaf-posframe--update-appearance panel)
            ;; The title bar repaints in both cases: the palette may be the same
            ;; while the toggle moved, as `auto' and `light' are in a light frame.
            (etaf-posframe--refresh-header panel palette)))))))

(defun etaf-posframe--apply-theme ()
  "Derive every live panel's Theme once from its parent frame."
  (dolist (panel (copy-sequence etaf-posframe--panels))
    (etaf-posframe--apply-theme-to panel)))

(defun etaf-posframe--choose-theme-mode (mode)
  "Switch the current panel to MODE.
A panel whose content declared its surface writes that content's mode cell, so
the application repaints and the title bar follows one state.  Every other
panel keeps the choice in its own `:theme' option for the rest of its life;
the caller's configuration is never written either way."
  (let ((panel (etaf-posframe--current-panel)))
    (when (etaf-posframe-live-p panel)
      (let* ((surface (etaf-posframe--panel-surface panel))
             (mode-ref (and surface (etaf-surface-mode surface))))
        (cond
         ((and mode-ref (assq mode (etaf-surface-modes surface)))
          (etaf-set-value mode-ref mode))
         ((memq mode '(light auto dark))
          (setf (etaf-posframe--panel-options panel)
                (plist-put (copy-sequence (etaf-posframe--panel-options panel))
                           :theme mode))
          (etaf-posframe--apply-theme-to panel)))))))

(defun etaf-posframe--theme-changed (&rest _)
  "Coalesce a theme switch into one pass after the current command.
`enable-theme-functions' and `disable-theme-functions' both report steps of
one switch, and disabling every theme in the middle resets each child frame to
white.  Holding the palette the panels already paint and re-deriving once
after the command keeps them from flashing a half-switched surface."
  (dolist (panel etaf-posframe--panels)
    (ignore-errors (etaf-posframe--hold-theme panel)))
  (when (timerp etaf-posframe--theme-timer)
    (cancel-timer etaf-posframe--theme-timer))
  (setq etaf-posframe--theme-timer
        (and etaf-posframe--panels
             (run-at-time 0 nil #'etaf-posframe--apply-theme))))

(add-hook 'enable-theme-functions #'etaf-posframe--theme-changed)
(add-hook 'disable-theme-functions #'etaf-posframe--theme-changed)
(add-hook 'window-size-change-functions #'etaf-posframe--window-size-changed)

(defun etaf-posframe--panel-for-key (key)
  "Return the live panel whose `:key' is KEY, or nil.
Panels without a `:key' share the nil identity, so showing one replaces the
previous one; panels with distinct keys coexist."
  (cl-find-if (lambda (panel)
                (equal key (plist-get (etaf-posframe--panel-options panel) :key)))
              etaf-posframe--panels))

(defun etaf-posframe--panel-for-buffer (buffer)
  "Return the live non-modal panel anchored to BUFFER."
  (cl-find-if (lambda (panel)
                (and (not (etaf-posframe--panel-modal-p panel))
                     (eq (etaf-posframe--panel-parent panel) buffer)))
              etaf-posframe--panels))

(defun etaf-posframe--current-panel ()
  "Return the panel of the current buffer, panel buffer included."
  (or etaf-posframe--panel
      (etaf-posframe--panel-for-buffer (current-buffer))))

;;;###autoload
(defun etaf-posframe-show (view &rest options)
  "Show VIEW in a floating panel and return the panel.
VIEW is a View or a zero-argument function returning one.  OPTIONS is the plist
described in the package Commentary."
  (unless (or (functionp view) view)
    (signal 'etaf-posframe-error (list "Panel View is nil")))
  ;; A new panel belongs to the frame the user is working in.  When a panel has
  ;; focus, its child frame is selected, and parenting the new panel to it would
  ;; delete the new panel together with the covering one.  Keep the caller's
  ;; buffer as the anchor, not the buffer the outer window happens to show.
  (let* ((called-buffer (current-buffer))
         (anchor-frame (etaf-posframe--anchor-frame (selected-frame))))
    (when (and (frame-live-p anchor-frame)
               (not (eq anchor-frame (selected-frame))))
      (select-frame anchor-frame)
      (set-buffer called-buffer)))
  (let* ((options (etaf-posframe--defaults
                   (etaf-posframe--validate (copy-sequence options))))
         (parent-frame (etaf-posframe--top-frame))
         (parent-window (etaf-posframe--anchor-window
                         parent-frame (selected-window)))
         (parent-buffer (etaf-posframe--anchor-buffer (current-buffer)))
         (char-width (max 1 (frame-char-width parent-frame)))
         (char-height (max 1 (frame-char-height parent-frame)))
         (parent-width (frame-pixel-width parent-frame))
         (parent-height (frame-pixel-height parent-frame))
         (available (max 20 (- (/ parent-width char-width)
                               (* 2 etaf-posframe--margin))))
         (width-spec (plist-get options :width))
         (columns (max 1 (min (if (numberp width-spec)
                                  width-spec
                                (round (/ (* parent-width (nth 1 width-spec))
                                          char-width)))
                              available)))
         ;; A panel must fit its parent frame: the row budget is clamped to the
         ;; rows the frame can show, so a tall game panel cannot run off screen.
         (height-spec (plist-get options :height))
         (budget (if (numberp height-spec)
                     height-spec
                   (round (/ (* parent-height (nth 1 height-spec)) char-height))))
         ;; Two rows stay free for the panel's border and the parent's mode
         ;; line.  The margin is measured in cells, not in pixels: a TTY frame
         ;; reports one pixel per cell, so a pixel count would cap a panel on a
         ;; 40-row terminal at eight rows.
         (capacity (max 4 (floor (- parent-height (* 2 char-height))
                                 (float char-height))))
         (max-height (min budget capacity))
         (theme-spec (plist-get options :theme))
         (theme (if (memq theme-spec '(auto light dark))
                    (etaf-posframe-theme parent-frame
                                         (and (not (eq theme-spec 'auto))
                                              theme-spec))
                  theme-spec))
         (theme-ref (if (or (etaf-ref-p theme) (etaf-computed-p theme))
                        theme
                      (etaf-ref theme)))
         ;; The slot an application that owns its palette declares itself on,
         ;; and the appearance a panel gives the View it frames.  Both outlive
         ;; the mount, so the panel keeps one readable state on each side.
         (surface (etaf-surface-create))
         (appearance (etaf-ref (plist-get (etaf-value theme-ref) :ui-mode)))
         (resolved (if (functionp view) (funcall view) view))
         (options (plist-put (plist-put options :width columns) :height max-height))
         (options (plist-put options :pixel-width (* columns char-width)))
         (panel nil)
         buffer)
    (unless (etaf-posframe--display-supported-p)
      (signal 'etaf-posframe-error
              (list "ETAF panels need a graphical frame or a terminal with child frames")))
    ;; Only the same key replaces a panel: different keys keep their own
    ;; frame, Runtime and position, so several panels stay open at once.
    (when-let* ((previous (etaf-posframe--panel-for-key
                           (plist-get options :key))))
      (etaf-posframe-hide previous))
    (unless resolved
      (signal 'etaf-posframe-error (list "Panel View returned nil" view)))
    (setq buffer (generate-new-buffer
                  (format " *ETAF Panel %d*" (cl-incf etaf-posframe--counter))))
    (etaf-posframe--prepare-buffer buffer (plist-get options :title)
                                   (etaf-value theme-ref)
                                   (plist-get options :width)
                                   (and (memq (plist-get options :theme)
                                              '(light auto dark))
                                        (plist-get options :theme))
                                   (plist-get options :scrollable))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (lambda ()
                        (etaf-view
                         (etaf-posframe--surface :theme theme-ref
                                                 :appearance appearance
                                                 :surface surface
                                                 :content (lambda () resolved))))
                      (list :viewport-width (* columns char-width)
                            :viewport-height max-height))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (unless runtime
              (signal 'etaf-posframe-error
                      (list "Panel View did not mount" view)))
            ;; The Theme ref and the surface live beside the panel buffer: the
            ;; panel struct stays printable, and the frame arguments read the
            ;; same ref.
            (with-current-buffer buffer
              (setq etaf-posframe--theme-ref theme-ref
                    etaf-posframe--surface surface
                    etaf-posframe--appearance-ref appearance))
            (setq panel (etaf-posframe--make-panel
                         :buffer buffer
                         :options options
                         :parent parent-buffer
                         :parent-frame parent-frame
                         :parent-window parent-window
                         :parent-geometry (etaf-posframe--frame-geometry parent-frame)
                         :parent-window-edges
                         (and (window-live-p parent-window)
                              (window-inside-pixel-edges parent-window))))
            ;; An application that declared its surface paints the frame this
            ;; panel is about to show, so the first paint is already its own.
            (etaf-posframe--sync-surface panel)
            (let ((etaf-posframe--dismissing t))
              (setf (etaf-posframe--panel-frame panel)
                    (etaf-posframe--show-frame
                     panel (max 1 (etaf-posframe--lines buffer))))
              ;; From here on a frame resized from outside re-lays the View out
              ;; at its new width instead of being snapped back.
              (setf (etaf-posframe--panel-settled panel) t)
              (etaf-posframe--set-frame-palette
               (etaf-posframe--panel-frame panel) (etaf-value theme-ref))
              (ignore-errors (etaf-posframe--paint-border panel))
              (ignore-errors (etaf-posframe--sync-activation))
              (etaf-posframe--watch-surface panel)
              (with-current-buffer buffer
                (setq etaf-posframe--panel panel
                      etaf-posframe--panel-keys-p t
                      etaf-posframe--headerless-drag
                      (and (not (plist-get options :title))
                           (plist-get options :draggable)
                           t)))
              (with-current-buffer parent-buffer
                (setq etaf-posframe--parent-panel panel)
                (add-hook 'kill-buffer-hook #'etaf-posframe--parent-killed nil t))
              (push panel etaf-posframe--panels)
              (when-let* ((seconds (plist-get options :auto-hide))
                          ((numberp seconds)))
                (setf (etaf-posframe--panel-timer panel)
                      (run-at-time seconds nil
                                   (lambda ()
                                     (when (memq panel etaf-posframe--panels)
                                       (etaf-posframe-hide panel))))))
              (when (plist-get options :focus-on-open)
                (etaf-posframe--focus panel))
              (etaf-posframe--refresh-hooks)
              panel)))
      (unless panel
        (etaf-posframe--release-buffer-frame buffer nil parent-frame)
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (ignore-errors (etaf-unmount runtime)))
        (when (buffer-live-p buffer)
          (ignore-errors (kill-buffer buffer)))))))

;;;###autoload
(defun etaf-posframe-toggle (view &rest options)
  "Hide the panel of the same `:key', or show VIEW with OPTIONS.
Without `:key' this is the panel of the current buffer.  Return the new panel,
or nil when it hid one."
  (let* ((options (etaf-posframe--validate (copy-sequence options)))
         (panel (if (plist-member options :key)
                    (etaf-posframe--panel-for-key (plist-get options :key))
                  (etaf-posframe--current-panel))))
    (if panel
        (progn (etaf-posframe-hide panel) nil)
      (apply #'etaf-posframe-show view options))))

(defun etaf-posframe--remember-size (panel window)
  "Record WINDOW's settled text size as PANEL's resize baseline.
The size is (WIDTH . HEIGHT) of the text area in pixels, which is what
`set-frame-size' takes back; a refused resize returns to it.  The frame's
position is recorded with it, because a top or left edge drag moves the frame
origin while it resizes, and a refused axis must not leave the panel
somewhere else."
  (when (window-live-p window)
    (let ((frame (window-frame window)))
      (setf (etaf-posframe--panel-size panel)
            (cons (window-body-width window t) (window-pixel-height window))
            (etaf-posframe--panel-position panel)
            (frame-position frame)))))

(provide 'etaf-posframe-panel)
;;; etaf-posframe-panel.el ends here
