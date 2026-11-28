;;; etaf-posframe-modal.el --- Child-frame modal host for etaf-ui -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Hosts centered `etaf-ui' modal dialogs and `etaf-help' overlays inside
;; pooled graphical child frames centered over their owning window.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'posframe)
(require 'etaf-posframe-pool)
(require 'etaf-posframe-panel)
(require 'etaf-posframe-layout)
(require 'etaf-posframe-app)

;;; Modal child-frame host for `etaf-ui'

(defun etaf-posframe--modal-owner-rect (parent-window top-frame)
  "Return (X Y WIDTH HEIGHT) of PARENT-WINDOW in TOP-FRAME pixels.
Works identically whether PARENT-WINDOW lives directly in TOP-FRAME or
inside another floating child frame (such as an `etaf-posframe' app)."
  (let ((owner-frame (and (window-live-p parent-window)
                          (window-frame parent-window))))
    (cond
     ((and (frame-live-p owner-frame)
           (eq owner-frame top-frame)
           (window-live-p parent-window))
      (let ((edges (window-inside-pixel-edges parent-window)))
        (list (nth 0 edges)
              (nth 1 edges)
              (max 1 (- (nth 2 edges) (nth 0 edges)))
              (max 1 (- (nth 3 edges) (nth 1 edges))))))
     ((and (frame-live-p owner-frame)
           (frame-parent owner-frame))
      (let ((pos (frame-position owner-frame)))
        (list (or (car-safe pos) 0)
              (or (cdr-safe pos) 0)
              (max 1 (frame-pixel-width owner-frame))
              (max 1 (frame-pixel-height owner-frame)))))
     ((frame-live-p top-frame)
      (list 0 0
            (max 1 (frame-pixel-width top-frame))
            (max 1 (frame-pixel-height top-frame))))
     (t (list 0 0 800 600)))))

(defun etaf-posframe--modal-position (parent-window top-frame modal-w modal-h)
  "Return (X . Y) centering MODAL-W by MODAL-H over PARENT-WINDOW in TOP-FRAME."
  (let* ((rect (etaf-posframe--modal-owner-rect parent-window top-frame))
         (ox (nth 0 rect))
         (oy (nth 1 rect))
         (ow (nth 2 rect))
         (oh (nth 3 rect))
         (fw (if (frame-live-p top-frame)
                 (frame-pixel-width top-frame)
               (+ ox ow)))
         (fh (if (frame-live-p top-frame)
                 (frame-pixel-height top-frame)
               (+ oy oh)))
         (cx (+ ox (floor (/ (- ow modal-w) 2))))
         (cy (+ oy (floor (/ (- oh modal-h) 2))))
         (x (max 0 (min cx (max 0 (- fw modal-w)))))
         (y (max 0 (min cy (max 0 (- fh modal-h))))))
    (cons x y)))

(defun etaf-posframe--modal-geometry (req-width-px req-height-rows req-max-rows
                                      parent-window top-frame)
  "Compute (PIXEL-WIDTH COLUMNS ROW-BUDGET FILL-HEIGHT) for a modal frame."
  (let* ((rect (etaf-posframe--modal-owner-rect parent-window top-frame))
         (ow (nth 2 rect))
         (oh (nth 3 rect))
         (char-w (max 1 (frame-char-width top-frame)))
         (char-h (max 1 (frame-char-height top-frame)))
         (min-w (min ow (* 16 char-w)))
         (max-w (max min-w (- ow (* 2 char-w))))
         (pixel-width (max min-w (min (or req-width-px (* 48 char-w)) max-w)))
         (columns (max 1 (round (/ pixel-width (float char-w)))))
         (owner-rows (max 6 (floor (- oh (* 2 char-h)) (float char-h))))
         (fill-height (and (integerp req-height-rows) (> req-height-rows 0) t))
         (row-budget (if fill-height
                         (max 6 (min req-height-rows owner-rows))
                       (max 6 (min (or req-max-rows owner-rows) owner-rows)))))
    (list pixel-width columns row-budget fill-height)))

(defun etaf-posframe--recenter-modal (panel)
  "Re-center modal PANEL over its owning window without flashing."
  (when (and (etaf-posframe-live-p panel)
             (etaf-posframe--panel-modal-p panel))
    (let* ((frame (etaf-posframe--panel-frame panel))
           (top-frame (etaf-posframe--panel-parent-frame panel))
           (owner-win (or (let ((w (etaf-posframe--panel-modal-window panel)))
                            (and (window-live-p w) w))
                          (get-buffer-window (etaf-posframe--panel-parent panel) t))))
      (when (and (frame-live-p frame) (frame-live-p top-frame))
        (let* ((pos (etaf-posframe--modal-position
                     owner-win top-frame
                     (frame-pixel-width frame)
                     (frame-pixel-height frame)))
               (cur (frame-position frame)))
          (unless (equal pos cur)
            (let ((etaf-posframe--positioning t))
              (set-frame-position frame (car pos) (cdr pos))))
          (setf (etaf-posframe--panel-position panel) pos))))))

(defun etaf-posframe--fit-modal (panel window)
  "Recompute modal PANEL's clamped geometry, fit its content and re-center it."
  (let* ((etaf-posframe--fitting t)
         (options (etaf-posframe--panel-options panel))
         (top-frame (etaf-posframe--panel-parent-frame panel))
         (owner-win (or (let ((w (etaf-posframe--panel-modal-window panel)))
                          (and (window-live-p w) w))
                        (get-buffer-window (etaf-posframe--panel-parent panel) t)))
         (dims-changed nil))
    (when (and (frame-live-p top-frame) (window-live-p owner-win))
      (cl-destructuring-bind (pixel-width columns row-budget fill-height)
          (etaf-posframe--modal-geometry
           (plist-get options :requested-width-px)
           (plist-get options :requested-height-rows)
           (plist-get options :requested-max-height-rows)
           owner-win top-frame)
        (unless (and (equal pixel-width (plist-get options :pixel-width))
                     (equal row-budget (plist-get options :height))
                     (equal fill-height (plist-get options :fill-height)))
          (let ((updated (copy-sequence options)))
            (setq updated (plist-put updated :pixel-width pixel-width))
            (setq updated (plist-put updated :width columns))
            (setq updated (plist-put updated :height row-budget))
            (setq updated (plist-put updated :fill-height fill-height))
            (setf (etaf-posframe--panel-options panel) updated)
            (setq dims-changed t)))))
    (if dims-changed
        (etaf-posframe--fit-height panel window)
      (etaf-posframe--resize-to-content panel window))
    (etaf-posframe--recenter-modal panel)
    (etaf-posframe--remember-size panel window)))

(defun etaf-posframe--modal-help-noop ()
  "Ignore repeated `etaf-help' inside an already-open help modal child frame."
  (when-let* ((panel (etaf-posframe--current-panel)))
    (etaf-posframe--panel-parent panel)))

(defun etaf-posframe--modal-anchor-window (parent-buffer parent-window)
  "Return the non-modal window for centering a modal from PARENT-BUFFER.
When a modal (such as keyboard help) opens over another modal child frame,
walking up to the underlying application window prevents cascading shrinkage
while `restore-window' still returns focus to PARENT-WINDOW on dismissal."
  (let ((buf parent-buffer)
        (win parent-window)
        (seen nil))
    (while (and (buffer-live-p buf)
                (not (memq buf seen))
                (let ((p (buffer-local-value 'etaf-posframe--panel buf)))
                  (and (etaf-posframe--panel-p p)
                       (etaf-posframe--panel-modal-p p))))
      (push buf seen)
      (let* ((p (buffer-local-value 'etaf-posframe--panel buf))
             (next-buf (etaf-posframe--panel-parent p))
             (next-win (or (let ((w (etaf-posframe--panel-modal-window p)))
                             (and (window-live-p w) w))
                           (and (buffer-live-p next-buf)
                                (get-buffer-window next-buf t)))))
        (setq buf next-buf)
        (when (window-live-p next-win)
          (setq win next-win))))
    win))

(defun etaf-posframe--modal-root-buffer (panel)
  "Return the non-modal owning application buffer for modal PANEL."
  (let ((buf (etaf-posframe--panel-parent panel))
        (seen nil))
    (while (and (buffer-live-p buf)
                (not (memq buf seen))
                (let ((p (buffer-local-value 'etaf-posframe--panel buf)))
                  (and (etaf-posframe--panel-p p)
                       (etaf-posframe--panel-modal-p p))))
      (push buf seen)
      (setq buf (etaf-posframe--panel-parent
                 (buffer-local-value 'etaf-posframe--panel buf))))
    buf))

(defun etaf-posframe--sync-modal-visibility (&optional _frame)
  "Keep modal child frames visible only while their owning buffer is shown.
Switching tabs or buffers away from the owning application hides its modal
child frame; switching back re-centers and reveals it cleanly."
  (unless (or etaf-posframe--fitting etaf-posframe--dismissing)
    (dolist (panel (copy-sequence etaf-posframe--panels))
      (when (and (etaf-posframe-live-p panel)
                 (etaf-posframe--panel-modal-p panel)
                 (etaf-posframe--panel-settled panel))
        (let* ((frame (etaf-posframe--panel-frame panel))
               (root-buf (etaf-posframe--modal-root-buffer panel))
               (win (and (buffer-live-p root-buf)
                         (get-buffer-window root-buf 'visible))))
          (when (frame-live-p frame)
            (if (window-live-p win)
                (progn
                  (setf (etaf-posframe--panel-modal-window panel) win)
                  (unless (frame-visible-p frame)
                    (etaf-posframe--recenter-modal panel)
                    (make-frame-visible frame)))
              (when (frame-visible-p frame)
                (make-frame-invisible frame)))))))))

(defun etaf-posframe--show-modal-frame (panel lines)
  "Show modal PANEL's child frame in one pass without redundant refits.
Reuses a parked graphical child frame when available, keeping the frame
hidden while applying exact pixel dimensions and palette so it never
flashes or triggers `delete-frame' churn."
  (let* ((posframe-mouse-banish-function #'ignore)
         (options (etaf-posframe--panel-options panel))
         (budget (etaf-posframe--row-budget panel))
         (lines (max 1 (if (plist-get options :fill-height)
                           budget
                         (min lines budget))))
         (buffer (etaf-posframe--panel-buffer panel))
         (parent-frame (etaf-posframe--panel-parent-frame panel))
         (pooled (and (display-graphic-p)
                      (etaf-posframe--acquire-pooled-frame parent-frame)))
         (frame nil))
    (if pooled
        (setq frame (etaf-posframe--configure-pooled-frame pooled panel lines))
      (let* ((args (etaf-posframe--frame-args panel lines))
             (ov (copy-sequence (plist-get args :override-parameters))))
        (when (display-graphic-p)
          (setq ov (cons '(visibility . nil) (assq-delete-all 'visibility ov)))
          (setq args (plist-put (copy-sequence args) :override-parameters ov)))
        ;; Suppress `posframe--make-frame-visible' when present so the child frame
        ;; stays invisible until pixel sizing, palette, centering and border finish.
        (if (fboundp 'posframe--make-frame-visible)
            (cl-letf (((symbol-function 'posframe--make-frame-visible) #'ignore))
              (setq frame (apply #'posframe-show buffer args)))
          (setq frame (apply #'posframe-show buffer args)))))
    (let ((window (if (frame-live-p frame)
                      (frame-root-window frame)
                    (get-buffer-window buffer t))))
      (unless (window-live-p window)
        (signal 'etaf-posframe-error (list "Modal frame did not appear" buffer)))
      (set-window-scroll-bars window 0 nil nil)
      ;; `etaf-mount' already laid out the buffer at exact `:pixel-width' and
      ;; `row-budget'; size pixels directly without extra `etaf-runtime-refit's.
      (etaf-posframe--resize-to-content panel window)
      (etaf-posframe--remember-size panel window)
      (window-frame window))))

(defun etaf-posframe--update-modal (panel spec)
  "Update live modal PANEL from SPEC (palette, size and centered placement)."
  (when (etaf-posframe-live-p panel)
    (let* ((frame (etaf-posframe--panel-frame panel))
           (theme-ref (etaf-posframe--panel-theme panel))
           (palette (and (etaf-ref-p theme-ref) (etaf-value theme-ref)))
           (options (etaf-posframe--panel-options panel))
           (req-w (plist-get spec :width-px))
           (req-h (plist-get spec :height-rows))
           (req-max (plist-get spec :max-height-rows))
           (panel-ref (plist-get spec :panel))
           (runtime (etaf-posframe--panel-runtime panel)))
      (when (and palette (frame-live-p frame))
        (ignore-errors (etaf-posframe--set-frame-palette frame palette))
        (ignore-errors (etaf-posframe--paint-border panel)))
      (unless (and (equal req-w (plist-get options :requested-width-px))
                   (equal req-h (plist-get options :requested-height-rows))
                   (equal req-max (plist-get options :requested-max-height-rows)))
        (let ((updated (copy-sequence options)))
          (setq updated (plist-put updated :requested-width-px req-w))
          (setq updated (plist-put updated :requested-height-rows req-h))
          (setq updated (plist-put updated :requested-max-height-rows req-max))
          (setf (etaf-posframe--panel-options panel) updated)))
      (when (and runtime panel-ref (null (etaf-focused-host-ref runtime)))
        (ignore-errors (etaf-focus-within runtime panel-ref)))
      (etaf-posframe-refresh panel))))

(defun etaf-posframe--open-modal (spec)
  "Project a centered `etaf-ui' modal dialog SPEC into a real child frame.
Installed automatically into `etaf-ui-modal-host-function' when `etaf-posframe'
loads, so every `etaf-dialog' and `etaf-key-help' modal renders in a native
child frame while keeping the uniformly dimmed animated backdrop in the parent
buffer."
  (let* ((parent-buffer (plist-get spec :parent-buffer))
         (parent-window (plist-get spec :parent-window))
         (panel-ref (plist-get spec :panel))
         (key (plist-get spec :key))
         (req-w (plist-get spec :width-px))
         (req-h (plist-get spec :height-rows))
         (req-max (plist-get spec :max-height-rows))
         (help-p (plist-get spec :help-p))
         (on-close (plist-get spec :on-close))
         (theme-ref (plist-get spec :theme))
         (appearance-ref (plist-get spec :appearance))
         (view-fn (plist-get spec :view)))
    (when (and (etaf-posframe--display-supported-p)
               (buffer-live-p parent-buffer)
               (window-live-p parent-window)
               (functionp view-fn)
               (not (and help-p
                         (let ((pp (buffer-local-value 'etaf-posframe--panel
                                                       parent-buffer)))
                           (and (etaf-posframe--panel-p pp)
                                (etaf-posframe--panel-help-p pp))))))
      (let* ((owner-frame (window-frame parent-window))
             (anchor-window (etaf-posframe--modal-anchor-window
                             parent-buffer parent-window))
             (top-frame (etaf-posframe--top-frame owner-frame))
             (char-h (max 1 (frame-char-height top-frame)))
             (buffer (generate-new-buffer
                      (format " *ETAF Modal %d*"
                              (cl-incf etaf-posframe--counter))))
             (panel nil))
        (cl-destructuring-bind (pixel-width columns row-budget fill-height)
            (etaf-posframe--modal-geometry
             req-w req-h req-max anchor-window top-frame)
          (when-let* ((previous (etaf-posframe--panel-for-key key)))
            (etaf-posframe-hide previous))
          (etaf-posframe--prepare-buffer
           buffer nil (and (etaf-ref-p theme-ref) (etaf-value theme-ref))
           columns nil)
          (unwind-protect
              (progn
                (etaf-mount buffer view-fn
                            (list :viewport-width pixel-width
                                  :viewport-height row-budget))
                (let ((runtime (etaf-runtime-for-buffer buffer)))
                  (unless runtime
                    (signal 'etaf-posframe-error
                            (list "Modal View did not mount")))
                  ;; Focus the initial control BEFORE creating/selecting the new
                  ;; child frame so Ebox flushes against the already-settled
                  ;; parent window without forcing a 60-110ms full redisplay.
                  (when panel-ref
                    (ignore-errors (etaf-focus-within runtime panel-ref)))
                  (with-current-buffer buffer
                    (setq etaf-posframe--theme-ref theme-ref
                          etaf-posframe--appearance-ref appearance-ref
                          etaf-posframe--panel-keys-p nil)
                    (when help-p
                      ;; Repeated `?' inside an open help child frame reuses
                      ;; the current help instead of stacking another frame.
                      (let ((map (make-sparse-keymap)))
                        (when (current-local-map)
                          (set-keymap-parent map (current-local-map)))
                        (define-key map [remap etaf-help]
                                    (lambda ()
                                      (interactive)
                                      (etaf-posframe--modal-help-noop)))
                        (use-local-map map))))
                  (let* ((options
                          (list :key key
                                :at (lambda (info)
                                      (etaf-posframe--modal-position
                                       anchor-window top-frame
                                       (or (plist-get info :posframe-width)
                                           pixel-width)
                                       (or (plist-get info :posframe-height)
                                           (* row-budget char-h))))
                                :width columns
                                :pixel-width pixel-width
                                :height row-budget
                                :fill-height fill-height
                                :requested-width-px req-w
                                :requested-height-rows req-h
                                :requested-max-height-rows req-max
                                :focusable t
                                :focus-on-open t
                                :auto-hide nil
                                :title nil
                                :draggable nil
                                :resizable nil
                                :theme theme-ref))
                         (portal-closing nil)
                         (created
                          (etaf-posframe--make-panel
                           :buffer buffer
                           :options options
                           :parent parent-buffer
                           :parent-frame top-frame
                           :restore-frame owner-frame
                           :restore-window parent-window
                           :close-callback
                           (when (functionp on-close)
                             (lambda (_panel)
                               (when (and (not portal-closing)
                                          (buffer-live-p parent-buffer))
                                 (etaf-next-tick
                                  (lambda ()
                                    (when (buffer-live-p parent-buffer)
                                      (ignore-errors (funcall on-close))))))))
                           :modal-p t
                           :modal-window anchor-window
                           :help-p (and help-p t)))
                         (frame
                          (let ((etaf-posframe--fitting t))
                            (with-selected-frame top-frame
                              (etaf-posframe--show-modal-frame
                               created
                               (max 1 (etaf-posframe--lines buffer)))))))
                    (let ((etaf-posframe--dismissing t))
                      (setf (etaf-posframe--panel-frame created) frame
                            (etaf-posframe--panel-settled created) t)
                      (setq panel created)
                      (when (etaf-ref-p theme-ref)
                        (etaf-posframe--set-frame-palette
                         frame (etaf-value theme-ref)))
                      (with-current-buffer buffer
                        (setq etaf-posframe--panel created)
                        (add-hook 'after-change-functions
                                  (lambda (_beg _end _len)
                                    (when (and (not etaf-posframe--fitting)
                                               (etaf-posframe--panel-settled created)
                                               (etaf-posframe-live-p created)
                                               (not (plist-get
                                                     (etaf-posframe--panel-options created)
                                                     :fill-height))
                                               (not (etaf-text-input-active-p
                                                     (etaf-posframe--panel-runtime created))))
                                      (etaf-posframe-refresh created)))
                                  nil t))
                      (with-current-buffer parent-buffer
                        (add-hook 'kill-buffer-hook
                                  #'etaf-posframe--parent-killed nil t))
                      (push created etaf-posframe--panels)
                      (etaf-posframe--recenter-modal created)
                      (ignore-errors (etaf-posframe--paint-border created))
                      ;; Flush the parent buffer's already-dimmed frame-0 backdrop
                      ;; to the window system immediately before showing the child
                      ;; frame so the modal never pops over an undimmed canvas.
                      (when (display-graphic-p)
                        (redisplay))
                      (unless (frame-visible-p frame)
                        (make-frame-visible frame))
                      (select-frame-set-input-focus frame)
                      (raise-frame frame)
                      (when-let* ((win (frame-root-window frame)))
                        (select-window win)
                        (set-window-point win (point-min))
                        (setf (etaf-posframe--panel-focused created) t))
                      (etaf-posframe--refresh-hooks))
                    (list :frame frame
                          :runtime-fn (lambda ()
                                        (and (buffer-live-p buffer)
                                             (etaf-runtime-for-buffer buffer)))
                          :update (lambda (new-spec)
                                    (when (etaf-posframe-live-p created)
                                      (etaf-posframe--update-modal created new-spec)))
                          :close (lambda ()
                                   (setq portal-closing t)
                                   (when (etaf-posframe-live-p created)
                                     (etaf-posframe-hide created)))))))
            (unless panel
              (etaf-posframe--release-buffer-frame buffer nil top-frame)
              (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
                (ignore-errors (etaf-unmount runtime)))
              (when (buffer-live-p buffer)
                (ignore-errors (kill-buffer buffer))))))))))

(unless etaf-ui-modal-host-function
  (setq etaf-ui-modal-host-function #'etaf-posframe--open-modal))

(provide 'etaf-posframe-modal)
;;; etaf-posframe-modal.el ends here
