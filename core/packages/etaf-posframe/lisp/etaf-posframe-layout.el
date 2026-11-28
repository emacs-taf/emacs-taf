;;; etaf-posframe-layout.el --- Panel resize, stacking, placement and dragging -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Live frame resizing, anchor and offset placement, multi-panel stacking,
;; mouse drag tracking, keyboard move/resize and public panel accessors.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'posframe)
(require 'etaf-posframe-pool)
(require 'etaf-posframe-panel)

(declare-function etaf-posframe--fit-modal "etaf-posframe-modal" (panel window))
(declare-function etaf-posframe--pin-position "etaf-posframe-app" (panel x y))

(defun etaf-posframe--resize-permitted (panel)
  "Return the (WIDTH-OK . HEIGHT-OK) PANEL's `:resizable' option allows.
`t' allows both axes, nil allows neither, and a list allows an axis whose
edges it names: `left' or `right' for a width change, `top' or `bottom' for a
height change."
  (let ((resizable (plist-get (etaf-posframe--panel-options panel) :resizable)))
    (cond
     ((eq resizable t) (cons t t))
     ((null resizable) (cons nil nil))
     ((listp resizable)
      (cons (or (memq 'left resizable) (memq 'right resizable) nil)
            (or (memq 'top resizable) (memq 'bottom resizable) nil)))
     (t (cons t t)))))

(defun etaf-posframe--restore-frame-size (panel window permitted)
  "Set back the axes PANEL's `:resizable' does not allow.
PERMITTED is its (WIDTH-OK . HEIGHT-OK).  An allowed axis keeps the size the
caller asked for and the origin its edge moved; a refused axis returns to the
settled size and origin, so a top or left edge drag cannot slide the panel.
Return non-nil when the frame was set back."
  (let* ((frame (window-frame window))
         (size (etaf-posframe--panel-size panel))
         (position (etaf-posframe--panel-position panel))
         (origin (frame-position frame))
         (width (if (car permitted)
                    (window-body-width window t)
                  (car size)))
         (height (if (cdr permitted)
                     (window-pixel-height window)
                   (cdr size)))
         (moved nil))
    (when (and size
               (or (/= width (window-body-width window t))
                   (/= height (window-pixel-height window))))
      (set-frame-size frame width height t)
      (setq moved t))
    (when (and position
               (or (and (not (car permitted))
                        (/= (car origin) (car position)))
                   (and (not (cdr permitted))
                        (/= (cdr origin) (cdr position)))))
      (let ((etaf-posframe--positioning t))
        (set-frame-position frame
                            (if (car permitted) (car origin) (car position))
                            (if (cdr permitted) (cdr origin) (cdr position))))
      (setq moved t))
    moved))

(defun etaf-posframe--adopt-frame-size (panel window)
  "Adopt the width and row budget of a frame resized from outside.
An outside resize (the user dragging an edge, a caller's `set-frame-size', a
tiling step) sets the frame size, so the canvas follows it instead of snapping
the frame back to the columns and rows the panel opened with.  A taller or
shorter frame becomes the new row budget, which lets a View that fills its
viewport, such as a complete app, show more or fewer rows.  `:resizable'
decides which axes accept the change, and a refused axis is put back.  Return
non-nil when the panel adopted or restored a size."
  (let* ((frame (window-frame window))
         (options (etaf-posframe--panel-options panel))
         (prev-size (etaf-posframe--panel-size panel))
         (char (frame-char-width frame))
         (width (window-body-width window t))
         (pixel-height (window-pixel-height window))
         ;; Only a change in the frame's actual pixel dimensions counts as an
         ;; outside resize.  A theme switch or initial redisplay can change
         ;; header-line or font height without resizing the frame, and must not
         ;; corrupt the panel's row budget.
         (width-changed (or (null prev-size) (/= width (car prev-size))))
         (height-changed (or (null prev-size) (/= pixel-height (cdr prev-size))))
         (header (if (plist-get options :title)
                     (window-header-line-height window)
                   0))
         (rows (max 1 (floor (- pixel-height header)
                             (float (frame-char-height frame)))))
         (budget (etaf-posframe--row-budget panel))
         (content (etaf-posframe--lines (etaf-posframe--panel-buffer panel)))
         (permitted (etaf-posframe--resize-permitted panel))
         (adopted options)
         (resized nil)
         (restored nil))
    (when (and (etaf-posframe--panel-settled panel) width-changed (> width 0))
      (cond
       ((= width (or (plist-get options :pixel-width) 0)))
       ((not (car permitted))
        (setq restored (etaf-posframe--restore-frame-size
                        panel window permitted)))
       (t
        (setq adopted (plist-put (plist-put (copy-sequence adopted)
                                           :pixel-width width)
                                 :width (max 1 (round (/ width (float char)))))
              resized t)
        (let ((theme-ref (etaf-posframe--panel-theme panel)))
          (when (and (plist-get adopted :title) (etaf-ref-p theme-ref))
            (etaf-posframe--refresh-header
             panel (etaf-value theme-ref) (plist-get adopted :width)))))))
    ;; A resize away from the row budget is the new budget: taller always, and
    ;; shorter only when it cuts into the content.  The panel's own fit sets
    ;; the frame to the content height, which must not shrink the budget.
    (when (and (etaf-posframe--panel-settled panel)
               height-changed
               (or (> rows budget) (< rows (min budget content))))
      (if (cdr permitted)
          (setq adopted (plist-put (copy-sequence adopted) :height rows)
                resized t)
        ;; The height is restored by this panel's own fit, which runs next.
        (unless restored
          (setq restored (etaf-posframe--restore-frame-size
                          panel window permitted)))))
    (when resized
      (setf (etaf-posframe--panel-options panel) adopted)
      ;; The retained renderer owns the layout, so the new size is laid out
      ;; once here, deferred out of the resize event that reported it.
      (etaf-runtime-refit (etaf-posframe--panel-runtime panel)
                          (plist-get adopted :pixel-width) rows))
    (or resized restored)))

;;;###autoload
(defun etaf-posframe--fit-now (panel)
  "Re-lay out PANEL at its frame size and fit the frame to the content.
Runs outside render and event callbacks; it never touches the buffer.  Only a
real size change re-lays the View out: re-laying out for a size the panel
already has is the cost that made a resize feel like a stall.  A panel that
fits more often than `etaf-posframe--fit-limit' in one second backs off for
`etaf-posframe--fit-backoff', so a condition that keeps resizing it can never
run away with the CPU."
  (when (and (etaf-posframe-live-p panel)
             (let ((muted (etaf-posframe--panel-fit-muted-until panel)))
               (cond
                ((null muted) t)
                ((>= (float-time) muted)
                 (setf (etaf-posframe--panel-fit-muted-until panel) nil)
                 t)
                (t nil))))
    (let* ((now (float-time))
           (start (etaf-posframe--panel-fit-window panel))
           (count (if (and start (< (- now start) 1.0))
                      (1+ (or (etaf-posframe--panel-fit-count panel) 0))
                    1)))
      (setf (etaf-posframe--panel-fit-window panel) (if (= count 1) now start)
            (etaf-posframe--panel-fit-count panel) count)
      (if (> count etaf-posframe--fit-limit)
          (progn
            (setf (etaf-posframe--panel-fit-muted-until panel)
                  (+ now etaf-posframe--fit-backoff)
                  (etaf-posframe--panel-fit-count panel) 0
                  (etaf-posframe--panel-fit-window panel) nil)
            (message "ETAF panel: %s fitted %d times in one second; backing off %ss"
                     (buffer-name (etaf-posframe--panel-buffer panel))
                     count etaf-posframe--fit-backoff))
        (let* ((buffer (etaf-posframe--panel-buffer panel))
               (window (get-buffer-window buffer t)))
          (when (window-live-p window)
            (if (etaf-posframe--panel-modal-p panel)
                (etaf-posframe--fit-modal panel window)
              ;; A frame resized from outside re-lays the View out at its new
              ;; width and rows; a content change needs no re-layout, because
              ;; ETAF already rendered it and a second layout writer duplicates
              ;; rows.  Either way only the frame height follows the content.
              (let ((adopted (etaf-posframe--adopt-frame-size panel window))
                    (fitted (etaf-posframe--resize-to-content panel window)))
                (when (and (or adopted fitted)
                           (etaf-posframe--panel-settled panel))
                  (etaf-posframe--fit panel))
                (etaf-posframe--lock-scroll panel window)
                (when fitted
                  (etaf-posframe--reposition panel)))
              (etaf-posframe--remember-size panel window))))))))

;;;###autoload
(defun etaf-posframe-refresh (&optional panel)
  "Schedule PANEL to fit its frame after the current event finishes.
PANEL defaults to the current buffer's panel.  Call it after the View's
content or style changed, or after the frame was resized; a frame resized from
outside becomes the panel width and the View re-lays out at it.  The fit is
deferred so it never runs inside a render or an event callback.  Return
non-nil when PANEL is live."
  (interactive)
  (let ((panel (or panel (etaf-posframe--current-panel))))
    (when (etaf-posframe-live-p panel)
      (when-let* ((timer (etaf-posframe--panel-fit-timer panel)))
        (cancel-timer timer))
      (setf (etaf-posframe--panel-fit-timer panel)
            ;; Zero delay runs on the next timer tick, after the redisplay
            ;; that reported the size: a resize therefore shows at most one
            ;; frame of the old layout instead of a visible garble.
            (run-at-time 0 nil
                         (lambda ()
                           (setf (etaf-posframe--panel-fit-timer panel) nil)
                           (ignore-errors (etaf-posframe--fit-now panel)))))
      t)))

(defun etaf-posframe--terminal-refit (panel)
  "Re-place PANEL in its terminal frame after the terminal changed size.
A terminal resize changes the parent frame's columns and rows, while a child
frame keeps the geometry it was created with.  Clamping the column count and
the row budget to the new frame and running the poshandler again keeps the
panel on screen at the anchor it was opened with."
  (when (etaf-posframe-live-p panel)
    (let* ((buffer (etaf-posframe--panel-buffer panel))
           (parent (etaf-posframe--panel-parent-frame panel))
           (options (etaf-posframe--panel-options panel))
           (char (max 1 (frame-char-width parent)))
           ;; One cell on each side stays free, so the frame border still fits.
           (columns (max 1 (min (or (plist-get options :width) 1)
                                (- (frame-width parent) 2))))
           (budget (max 1 (min (etaf-posframe--row-budget panel)
                               (- (frame-height parent) 2))))
           (lines (max 1 (min (etaf-posframe--lines buffer) budget))))
      (setf (etaf-posframe--panel-options panel)
            (plist-put (plist-put (plist-put (copy-sequence options)
                                             :width columns)
                                  :pixel-width (* columns char))
                       :height budget))
      (let ((posframe-mouse-banish-function #'ignore)
            (etaf-posframe--positioning t))
        (apply #'posframe-show buffer
               (etaf-posframe--frame-args panel lines)))
      (setf (etaf-posframe--panel-parent-geometry panel)
            (etaf-posframe--frame-geometry parent))
      (when-let* ((window (get-buffer-window buffer t)))
        (etaf-posframe--fit-height panel window)
        (etaf-posframe--remember-size panel window)))))

(defun etaf-posframe--frame-geometry (frame)
  "Return (PIXEL-WIDTH PIXEL-HEIGHT CHAR-WIDTH CHAR-HEIGHT) of FRAME, or nil."
  (when (frame-live-p frame)
    (list (frame-pixel-width frame)
          (frame-pixel-height frame)
          (max 1 (frame-char-width frame))
          (max 1 (frame-char-height frame)))))

(defun etaf-posframe--anchor-window (parent &optional preferred)
  "Return the non-minibuffer window on PARENT to anchor against.
Uses PREFERRED when it is live on PARENT and not a minibuffer, otherwise
PARENT's selected window (stepping back from the minibuffer when active)."
  (cond
   ((and (window-live-p preferred)
         (eq (window-frame preferred) parent)
         (not (window-minibuffer-p preferred)))
    preferred)
   ((frame-live-p parent)
    (let ((selected (frame-selected-window parent)))
      (if (and (window-live-p selected) (not (window-minibuffer-p selected)))
          selected
        (let ((mini-owner (minibuffer-selected-window)))
          (if (and (window-live-p mini-owner)
                   (eq (window-frame mini-owner) parent)
                   (not (window-minibuffer-p mini-owner)))
              mini-owner
            (frame-first-window parent))))))))

(defun etaf-posframe--placement-stacked-p (placement options)
  "Return non-nil when PLACEMENT with OPTIONS participates in anchor stacking."
  (and (plist-get options :stack)
       (memq (car placement) '(anchor anchor+offset))))

(defun etaf-posframe--placement-window-relative-p (placement)
  "Return non-nil when PLACEMENT depends on a parent window's pixel edges."
  (pcase (car placement)
    ('cells t)
    ('anchor (string-prefix-p "window-" (symbol-name (cdr placement))))
    ('anchor+offset (string-prefix-p "window-" (symbol-name (nth 1 placement))))
    (_ nil)))

(defun etaf-posframe--placement-point-p (placement)
  "Return non-nil when PLACEMENT anchors to buffer point."
  (and (memq (car placement) '(anchor anchor+offset))
       (memq (if (eq (car placement) 'anchor)
                 (cdr placement)
               (nth 1 placement))
             '(point point-top))))

(defun etaf-posframe--sync-external-move (panel)
  "Pin PANEL's position when the user dragged it via native title-bar drag.
Emacs's `drag-with-header-line' moves the child frame directly without calling
`etaf-posframe-drag', leaving `:at' on the old anchor.  Detecting a pure
position change (same frame text size, different position) pins the dragged
place so later theme switches, fits or resizes never snap it back."
  (when (and (etaf-posframe-live-p panel)
             (not etaf-posframe--positioning)
             (not etaf-posframe--dragging)
             (not (etaf-posframe--panel-modal-p panel))
             (etaf-posframe--panel-settled panel)
             (plist-get (etaf-posframe--panel-options panel) :draggable))
    (let* ((frame (etaf-posframe--panel-frame panel))
           (known-pos (etaf-posframe--panel-position panel))
           (known-size (etaf-posframe--panel-size panel))
           (cur-pos (frame-position frame))
           (window (get-buffer-window (etaf-posframe--panel-buffer panel) t))
           (cur-size (and (window-live-p window)
                          (cons (window-body-width window t)
                                (window-pixel-height window)))))
      (when (and known-pos cur-pos
                 (not (equal cur-pos known-pos))
                 known-size cur-size
                 (equal cur-size known-size))
        (let ((x (car cur-pos))
              (y (cdr cur-pos))
              (on-move (plist-get (etaf-posframe--panel-options panel) :on-move)))
          (etaf-posframe--pin-position panel x y)
          (when (functionp on-move)
            (ignore-errors (funcall on-move x y panel)))
          t)))))

(defun etaf-posframe--position-info (panel)
  "Build the poshandler `info' plist for live PANEL."
  (let* ((frame (etaf-posframe--panel-frame panel))
         (parent (etaf-posframe--panel-parent-frame panel))
         (pwin (etaf-posframe--anchor-window
                parent (etaf-posframe--panel-parent-window panel)))
         (pw (frame-pixel-width parent))
         (ph (frame-pixel-height parent))
         (fw (frame-pixel-width frame))
         (fh (frame-pixel-height frame))
         (pwin-live (window-live-p pwin))
         (pwin-left (if pwin-live (window-pixel-left pwin) 0))
         (pwin-top (if pwin-live (window-pixel-top pwin) 0))
         (pwin-w (if pwin-live (window-pixel-width pwin) pw))
         (pwin-h (if pwin-live (window-pixel-height pwin) ph))
         (header-h (if pwin-live (window-header-line-height pwin) 0))
         (mode-h (if pwin-live (window-mode-line-height pwin) 0))
         (tab-h (if (and pwin-live (fboundp 'window-tab-line-height))
                    (window-tab-line-height pwin)
                  0))
         (mini-w (minibuffer-window parent))
         (mini-h (if (window-live-p mini-w) (window-pixel-height mini-w) 0)))
    (list :position (if pwin-live (window-point pwin) 1)
          :parent-frame parent
          :parent-frame-width pw
          :parent-frame-height ph
          :parent-window pwin
          :parent-window-left pwin-left
          :parent-window-top pwin-top
          :parent-window-width pwin-w
          :parent-window-height pwin-h
          :posframe frame
          :posframe-width fw
          :posframe-height fh
          :posframe-buffer (etaf-posframe--panel-buffer panel)
          :font-width (max 1 (frame-char-width parent))
          :font-height (max 1 (frame-char-height parent))
          :header-line-height header-h
          :mode-line-height mode-h
          :tab-line-height tab-h
          :minibuffer-height mini-h
          :x-pixel-offset 0
          :y-pixel-offset 0)))

(defun etaf-posframe--reposition-one (panel &optional force)
  "Recompute and apply PANEL's `(X . Y)' position against its parent frame.
Respects `etaf-posframe--stack-obstacles' when bound by a reflow pass.
Point-anchored panels are left alone unless FORCE is non-nil."
  (when (and (etaf-posframe-live-p panel)
             (not (etaf-posframe--panel-modal-p panel)))
    (let* ((frame (etaf-posframe--panel-frame panel))
           (parent (etaf-posframe--panel-parent-frame panel))
           (options (etaf-posframe--panel-options panel))
           (placement (etaf-posframe--placement (plist-get options :at))))
      (when (and (frame-live-p frame) (frame-live-p parent)
                 (or force (not (etaf-posframe--placement-point-p placement))))
        (let* ((info (etaf-posframe--position-info panel))
               (pw (plist-get info :parent-frame-width))
               (ph (plist-get info :parent-frame-height))
               (bevel (etaf-posframe--terminal-bevel frame))
               (fw (+ (plist-get info :posframe-width) bevel))
               (fh (+ (plist-get info :posframe-height) bevel))
               (pos (condition-case nil
                        (funcall (etaf-posframe--placement-poshandler placement options) info)
                      (error (frame-position frame))))
               (raw-x (or (car-safe pos) 0))
               (raw-y (or (cdr-safe pos) 0))
               ;; Standard Posframe poshandlers encode right/bottom offsets as
               ;; negative pixel coordinates (e.g. `(-1 . 0)' for top-right).
               (norm-x (if (and (eq (car placement) 'function) (< raw-x 0))
                           (+ raw-x pw (- fw))
                         raw-x))
               (norm-y (if (and (eq (car placement) 'function) (< raw-y 0))
                           (+ raw-y ph (- fh))
                         raw-y))
               (min-x (if (> bevel 0) 1 0))
               (min-y (if (> bevel 0) 1 0))
               (max-x (max min-x (- pw fw (if (> bevel 0) 1 0))))
               (max-y (max min-y (- ph fh (if (> bevel 0) 1 0))))
               (x (max min-x (min norm-x max-x)))
               (y (max min-y (min norm-y max-y)))
               (cur (frame-position frame)))
          (when (or (/= x (or (car-safe cur) -1))
                    (/= y (or (cdr-safe cur) -1)))
            (let ((etaf-posframe--positioning t))
              (set-frame-position frame x y)))
          (setf (etaf-posframe--panel-parent-geometry panel)
                (etaf-posframe--frame-geometry parent))
          (let ((pwin (plist-get info :parent-window)))
            (when (window-live-p pwin)
              (setf (etaf-posframe--panel-parent-window panel) pwin
                    (etaf-posframe--panel-parent-window-edges panel)
                    (window-inside-pixel-edges pwin))))
          (when-let* ((win (get-buffer-window (etaf-posframe--panel-buffer panel) t)))
            (etaf-posframe--remember-size panel win))
          (cons x y))))))

(defun etaf-posframe--reflow-stacked (parent &optional force)
  "Reflow all live stacked panels on PARENT in oldest-first creation order.
Non-stacked panels on PARENT stay at their current positions and act as fixed
obstacles; each stacked panel is placed against those obstacles plus the
earlier stacked panels already placed in this pass, so panels never collide
with themselves, never reverse stack order, and never overlap when an earlier
panel changes height."
  (when (frame-live-p parent)
    (let* ((live (cl-remove-if-not
                  (lambda (p)
                    (and (not (etaf-posframe--panel-modal-p p))
                         (eq (etaf-posframe--panel-parent-frame p) parent)))
                  (etaf-posframe-panels)))
           (ordered (reverse live))
           (fixed nil)
           (stacked nil))
      (dolist (p ordered)
        (etaf-posframe--sync-external-move p)
        (let* ((opts (etaf-posframe--panel-options p))
               (placement (etaf-posframe--placement (plist-get opts :at))))
          (if (etaf-posframe--placement-stacked-p placement opts)
              (push p stacked)
            (push p fixed))))
      (setq stacked (nreverse stacked))
      (let ((obstacles (delq nil (mapcar (lambda (p)
                                           (etaf-posframe--frame-rect
                                            (etaf-posframe--panel-frame p)))
                                         fixed))))
        (dolist (p stacked)
          (let ((etaf-posframe--stack-obstacles obstacles))
            (etaf-posframe--reposition-one p force))
          (when-let* ((rect (etaf-posframe--frame-rect
                             (etaf-posframe--panel-frame p))))
            (push rect obstacles)))))))

(defun etaf-posframe--reposition-frame (parent)
  "Reposition all non-modal panels belonging to PARENT after PARENT resized.
Non-stacked panels reposition first (clamping pinned pixels and updating
anchors); stacked panels then reflow in oldest-first order around them."
  (when (frame-live-p parent)
    (let* ((live (cl-remove-if-not
                  (lambda (p)
                    (and (not (etaf-posframe--panel-modal-p p))
                         (eq (etaf-posframe--panel-parent-frame p) parent)))
                  (etaf-posframe-panels)))
           (ordered (reverse live))
           (has-stacked nil))
      (dolist (p ordered)
        (etaf-posframe--sync-external-move p)
        (let* ((opts (etaf-posframe--panel-options p))
               (placement (etaf-posframe--placement (plist-get opts :at))))
          (if (etaf-posframe--placement-stacked-p placement opts)
              (setq has-stacked t)
            (etaf-posframe--reposition-one p))))
      (when has-stacked
        (etaf-posframe--reflow-stacked parent)))))

(defun etaf-posframe--reposition (panel &optional force)
  "Recompute and apply PANEL's `(X . Y)' position against its parent frame.
Keeps anchored panels aligned when sizes change, keeps pinned pixel positions
clamped cleanly inside the parent frame, and reflows sibling stacked panels in
oldest-first order so a panel never collides with itself or swaps order.
Point-anchored panels are left alone unless FORCE is non-nil."
  (when (and (etaf-posframe-live-p panel)
             (not (etaf-posframe--panel-modal-p panel)))
    (etaf-posframe--sync-external-move panel)
    (let* ((parent (etaf-posframe--panel-parent-frame panel))
           (options (etaf-posframe--panel-options panel))
           (placement (etaf-posframe--placement (plist-get options :at))))
      (if (etaf-posframe--placement-stacked-p placement options)
          (progn
            (etaf-posframe--reflow-stacked parent force)
            (frame-position (etaf-posframe--panel-frame panel)))
        (let ((pos (etaf-posframe--reposition-one panel force)))
          (when-let* ((self-rect (etaf-posframe--frame-rect
                                  (etaf-posframe--panel-frame panel))))
            (when (cl-some
                   (lambda (other)
                     (and (not (eq other panel))
                          (not (etaf-posframe--panel-modal-p other))
                          (eq (etaf-posframe--panel-parent-frame other) parent)
                          (let* ((oopts (etaf-posframe--panel-options other))
                                 (oplace (etaf-posframe--placement (plist-get oopts :at))))
                            (etaf-posframe--placement-stacked-p oplace oopts))
                          (let ((orect (etaf-posframe--frame-rect
                                        (etaf-posframe--panel-frame other))))
                            (and orect (etaf-posframe--rect-overlap-p self-rect orect)))))
                   (etaf-posframe-panels))
              (etaf-posframe--reflow-stacked parent)))
          pos)))))

;;;###autoload
(defun etaf-posframe-reshape (panel &rest options)
  "Update live PANEL in place without recreating its frame or unmounting its View.
OPTIONS accepts `:width', `:height', `:at', `:theme', `:border',
`:fill-height' and `:focus-on-open'."
  (when (etaf-posframe-live-p panel)
    (let* ((cur-opts (copy-sequence (etaf-posframe--panel-options panel)))
           (parent (etaf-posframe--panel-parent-frame panel))
           (frame (etaf-posframe--panel-frame panel))
           (buffer (etaf-posframe--panel-buffer panel))
           (window (get-buffer-window buffer t))
           (char-w (max 1 (frame-char-width parent)))
           (char-h (max 1 (frame-char-height parent)))
           (pw (frame-pixel-width parent))
           (ph (frame-pixel-height parent))
           (avail (max 20 (- (/ pw char-w) (* 2 etaf-posframe--margin))))
           (cap (max 4 (floor (- ph (* 2 char-h)) (float char-h)))))
      (etaf-posframe--validate (copy-sequence options))
      (when (plist-member options :at)
        (let ((new-at (plist-get options :at)))
          (setq cur-opts (plist-put cur-opts :at new-at))
          (unless (memq (car (etaf-posframe--placement new-at))
                        '(anchor anchor+offset))
            (setq cur-opts (plist-put cur-opts :stack nil)))))
      (when (plist-member options :fill-height)
        (setq cur-opts (plist-put cur-opts :fill-height (plist-get options :fill-height))))
      (when (plist-member options :border)
        (setq cur-opts (plist-put cur-opts :border (plist-get options :border))))
      (when (plist-member options :width)
        (let* ((wspec (plist-get options :width))
               (cols (max 1 (min (if (numberp wspec)
                                     wspec
                                   (round (/ (* pw (nth 1 wspec)) char-w)))
                                 avail))))
          (setq cur-opts (plist-put cur-opts :width cols)
                cur-opts (plist-put cur-opts :pixel-width (* cols char-w)))))
      (when (plist-member options :height)
        (let* ((hspec (plist-get options :height))
               (budget (if (numberp hspec)
                           hspec
                         (round (/ (* ph (nth 1 hspec)) char-h)))))
          (setq cur-opts (plist-put cur-opts :height (min budget cap)))))
      (when (plist-member options :theme)
        (let* ((tspec (plist-get options :theme))
               (theme (if (memq tspec '(auto light dark))
                          (etaf-posframe-theme parent (and (not (eq tspec 'auto)) tspec))
                        tspec))
               (tref (etaf-posframe--panel-theme panel)))
          (setq cur-opts (plist-put cur-opts :theme tspec))
          (when (and (etaf-ref-p tref) (not (etaf-ref-p theme)))
            (setf (etaf-value tref) theme))
          (let ((pal (if (or (etaf-ref-p theme) (etaf-computed-p theme))
                         (etaf-value theme)
                       theme)))
            (etaf-posframe--set-frame-palette frame pal))))
      (setf (etaf-posframe--panel-options panel) cur-opts)
      (when (window-live-p window)
        (let ((etaf-posframe--dismissing t))
          (setf (etaf-posframe--panel-settled panel) nil)
          (unwind-protect
              (progn
                (etaf-posframe--fit-height panel window)
                (etaf-posframe--reposition panel t)
                (etaf-posframe--lock-scroll panel window)
                (etaf-posframe--remember-size panel window))
            (setf (etaf-posframe--panel-settled panel) t))))
      (ignore-errors (etaf-posframe--paint-border panel))
      (when (plist-member options :focus-on-open)
        (if (plist-get options :focus-on-open)
            (etaf-posframe-focus panel)
          (etaf-posframe-unfocus panel)))
      panel)))

;;;###autoload
(defun etaf-posframe-drag (panel &optional on-done)
  "Drag live PANEL smoothly with the mouse pointer inside its parent frame.
Works on headerless panels without `:title'.  When the pointer moves more than
3 pixels, pins the panel's new `(X . Y)' and calls ON-DONE with `(X Y PANEL)'."
  (when (and (etaf-posframe-live-p panel) (display-graphic-p))
    (let* ((frame (etaf-posframe--panel-frame panel))
           (parent (etaf-posframe--panel-parent-frame panel))
           (start-mouse (mouse-absolute-pixel-position))
           (start-pos (frame-position frame))
           (mx0 (or (car-safe start-mouse) 0))
           (my0 (or (cdr-safe start-mouse) 0))
           (fx0 (or (car-safe start-pos) 0))
           (fy0 (or (cdr-safe start-pos) 0))
           (pw (frame-pixel-width parent))
           (ph (frame-pixel-height parent))
           (fw (frame-pixel-width frame))
           (fh (frame-pixel-height frame))
           (cur-x fx0)
           (cur-y fy0)
           (moved nil)
           (etaf-posframe--dragging t))
      (when (and (numberp mx0) (numberp my0))
        (track-mouse
          (let ((done nil)
                (end-ev nil))
            (while (not done)
              (let ((ev (if (or noninteractive (display-graphic-p)
                                (not (bound-and-true-p xterm-mouse-mode)))
                            (read-event)
                          (read-key nil t))))
                (cond
                 ((mouse-movement-p ev)
                  (let* ((mp (mouse-absolute-pixel-position))
                         (dx (- (or (car-safe mp) mx0) mx0))
                         (dy (- (or (cdr-safe mp) my0) my0)))
                    (when (or moved (> (abs dx) 3) (> (abs dy) 3))
                      (setq moved t
                            cur-x (max 0 (min (+ fx0 dx) (max 0 (- pw fw))))
                            cur-y (max 0 (min (+ fy0 dy) (max 0 (- ph fh)))))
                      (set-frame-position frame cur-x cur-y))))
                 (t
                  (setq end-ev ev
                        done t)))))
            (when (and (not moved) end-ev)
              (push end-ev unread-command-events))))
        (when moved
          (etaf-posframe--pin-position panel cur-x cur-y)
          (when-let* ((win (get-buffer-window (etaf-posframe--panel-buffer panel) t)))
            (etaf-posframe--remember-size panel win))
          (when (functionp on-done)
            (ignore-errors (funcall on-done cur-x cur-y panel))))
        moved))))

(defun etaf-posframe--window-size-changed (frame)
  "Re-fit the panels FRAME hosts or the panel FRAME itself after a resize."
  (let* ((terminal (not (display-graphic-p frame)))
         (panels (copy-sequence etaf-posframe--panels))
         (cur-geom (etaf-posframe--frame-geometry frame))
         (parent-resized nil)
         (window-moved-panels nil)
         (modal-panels nil))
    (dolist (panel panels)
      (let* ((modal-win (etaf-posframe--panel-modal-window panel))
             (modal-owner (and (window-live-p modal-win)
                               (window-frame modal-win))))
        (cond
         ((eq (etaf-posframe--panel-frame panel) frame)
          (unless (and (etaf-posframe--panel-modal-p panel) etaf-posframe--fitting)
            (etaf-posframe-refresh panel)))
         ((and (etaf-posframe--panel-modal-p panel)
               (or (eq (etaf-posframe--panel-parent-frame panel) frame)
                   (and modal-owner (eq modal-owner frame))))
          (push panel modal-panels))
         ((eq (etaf-posframe--panel-parent-frame panel) frame)
          (if (not (equal cur-geom (etaf-posframe--panel-parent-geometry panel)))
              (setq parent-resized t)
            ;; Parent frame pixel size and character cell metrics are unchanged
            ;; (e.g. a window split, minibuffer resize or theme mode-line
            ;; tweak).  Only window-relative panels whose anchor window changed
            ;; edges need repositioning.
            (let* ((opts (etaf-posframe--panel-options panel))
                   (placement (etaf-posframe--placement (plist-get opts :at))))
              (when (etaf-posframe--placement-window-relative-p placement)
                (let* ((pwin (etaf-posframe--anchor-window
                              frame (etaf-posframe--panel-parent-window panel)))
                       (edges (and (window-live-p pwin)
                                   (window-inside-pixel-edges pwin))))
                  (when (and edges
                             (not (equal edges
                                         (etaf-posframe--panel-parent-window-edges panel))))
                    (push panel window-moved-panels))))))))))
    (cond
     (parent-resized
      (if terminal
          (let* ((live (reverse
                        (cl-remove-if-not
                         (lambda (p)
                           (and (not (etaf-posframe--panel-modal-p p))
                                (eq (etaf-posframe--panel-parent-frame p) frame)))
                         (etaf-posframe-panels))))
                 (fixed nil)
                 (stacked nil)
                 (obstacles nil))
            (dolist (p live)
              (let* ((opts (etaf-posframe--panel-options p))
                     (placement (etaf-posframe--placement (plist-get opts :at))))
                (if (etaf-posframe--placement-stacked-p placement opts)
                    (push p stacked)
                  (push p fixed))))
            (dolist (p (nreverse fixed))
              (etaf-posframe--terminal-refit p)
              (when-let* ((rect (etaf-posframe--frame-rect
                                 (etaf-posframe--panel-frame p))))
                (push rect obstacles)))
            (dolist (p (nreverse stacked))
              (let ((etaf-posframe--stack-obstacles obstacles))
                (etaf-posframe--terminal-refit p))
              (when-let* ((rect (etaf-posframe--frame-rect
                                 (etaf-posframe--panel-frame p))))
                (push rect obstacles))))
        (etaf-posframe--reposition-frame frame)
        (dolist (p panels)
          (when (and (not (etaf-posframe--panel-modal-p p))
                     (eq (etaf-posframe--panel-parent-frame p) frame))
            (etaf-posframe-refresh p)))))
     (window-moved-panels
      (dolist (p (nreverse window-moved-panels))
        (etaf-posframe--reposition p))))
    (dolist (m modal-panels)
      (etaf-posframe-refresh m))))

(defun etaf-posframe-panel-theme (panel)
  "Return PANEL's current Theme plist, or nil when it is not live."
  (when (etaf-posframe-live-p panel)
    (let ((theme (etaf-posframe--panel-theme panel)))
      (and (etaf-ref-p theme) (etaf-value theme)))))

(defun etaf-posframe-current-theme ()
  "Return the Theme of the panel whose View is rendering, or nil."
  (let ((runtime (ignore-errors (etaf-runtime-for-buffer (current-buffer)))))
    (when runtime
      (let ((panel (cl-find-if
                    (lambda (panel)
                      (eq (etaf-posframe--panel-runtime panel) runtime))
                    etaf-posframe--panels)))
        (and panel (etaf-posframe-panel-theme panel))))))

;;;###autoload
(defun etaf-posframe-panel-frame (panel)
  "Return PANEL's child frame, or nil when PANEL is not live."
  (when (etaf-posframe-live-p panel)
    (etaf-posframe--panel-frame panel)))

(defun etaf-posframe-live-p (panel)
  "Return non-nil while PANEL's frame exists and its Runtime is mounted."
  (and (etaf-posframe--panel-p panel)
       (frame-live-p (etaf-posframe--panel-frame panel))
       (etaf-runtime-mounted-p (etaf-posframe--panel-runtime panel))))

(defun etaf-posframe-panels ()
  "Return the live panels, most recent first."
  ;; Always return a fresh list so callers may mutate or hide panels while
  ;; walking it (`cl-remove-if-not' can return the original list when every
  ;; element matches).
  (cl-loop for panel in etaf-posframe--panels
           when (etaf-posframe-live-p panel)
           collect panel))

(provide 'etaf-posframe-layout)
;;; etaf-posframe-layout.el ends here
