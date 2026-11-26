;;; etaf-fullscreen.el --- Two-tier fullscreen lifecycle for ETAF buffers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Shared two-tier fullscreen host for ETAF application buffers:
;; - `window' mode (buffer/window pure fullscreen): temporarily hides the
;;   buffer's mode-line without disturbing Emacs window splits or OS spaces,
;;   allowing Views (such as video players) to expand immediately with zero
;;   component remount.
;; - `frame' mode (OS/frame fullscreen): saves the frame's window configuration
;;   and `fullscreen' parameter, collapses to a single window, enters graphical
;;   frame fullscreen when not already fullscreen, and restores the exact
;;   previous window layout, frame state and mode-line on exit or buffer kill.
;;
;; Both tiers expose reactive state through `etaf-fullscreen-mode' and run
;; multi-phase viewport refits plus native GPU layer sync so transitions stay
;; crisp across redisplay and OS fullscreen animations.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)
(require 'etaf-runtime)

(declare-function etaf-app--fit "etaf-app" (buffer window))
(declare-function etaf-video--sync-all-gpu-instances "etaf-video-component" ())

(cl-defstruct (etaf-fullscreen--state (:constructor etaf-fullscreen--state--make))
  "Buffer-local fullscreen ownership state."
  mode-ref
  mode-line-saved
  mode-line-was-local
  mode-line-value
  frame
  saved-wconf
  saved-os-fullscreen
  changed-os-fullscreen
  on-change
  timers)

(defvar-local etaf-fullscreen--buffer-state nil
  "Buffer-local `etaf-fullscreen--state' record for the current buffer.")

(defun etaf-fullscreen--resolve-buffer (&optional buffer)
  "Return live buffer designated by BUFFER, defaulting to `current-buffer'."
  (let ((buf (cond ((null buffer) (current-buffer))
                   ((bufferp buffer) buffer)
                   ((stringp buffer) (get-buffer buffer))
                   (t (signal 'wrong-type-argument (list 'bufferp buffer))))))
    (unless (and buf (buffer-live-p buf))
      (error "Fullscreen target buffer is not live: %S" buffer))
    buf))

(defun etaf-fullscreen--ensure-state (buffer)
  "Return BUFFER's `etaf-fullscreen--state', creating it lazily."
  (with-current-buffer buffer
    (or etaf-fullscreen--buffer-state
        (setq etaf-fullscreen--buffer-state
              (etaf-fullscreen--state--make
               :mode-ref (etaf-ref nil :name 'etaf-fullscreen-mode))))))

(defun etaf-fullscreen--cancel-timers (state)
  "Cancel any pending refit timers owned by STATE."
  (dolist (tm (etaf-fullscreen--state-timers state))
    (when (timerp tm) (ignore-errors (cancel-timer tm))))
  (setf (etaf-fullscreen--state-timers state) nil))

(defun etaf-fullscreen--sync-now (buffer &optional force-fit)
  "Refit BUFFER's ETAF Runtime, application fit hook and native GPU layers.
When FORCE-FIT is nil, skip `etaf-app--fit' if `etaf-refit' reports an
unchanged viewport, avoiding spurious layout churn on settled timers."
  (when (buffer-live-p buffer)
    (let* ((win (get-buffer-window buffer t))
           (rt (etaf-runtime-for-buffer buffer))
           (changed nil))
      (when (and rt (etaf-runtime-mounted-p rt) win (window-live-p win))
        (let ((before (etaf-runtime-viewport rt))
              (after (ignore-errors (etaf-refit rt win))))
          (setq changed (not (equal before after)))
          (when (and (or force-fit changed) (fboundp 'etaf-app--fit))
            (ignore-errors (etaf-app--fit buffer win)))))
      (when (and (or force-fit changed)
                 (fboundp 'etaf-video--sync-all-gpu-instances))
        (ignore-errors (etaf-video--sync-all-gpu-instances))))))

(defun etaf-fullscreen--commit (buffer state target prev &optional frame-transition)
  "Atomically commit fullscreen mode TARGET (from PREV) for BUFFER and STATE.
Refits the viewport, publishes `mode-ref', notifies `:on-change', and runs
`etaf-app--fit' inside one `etaf-batch' so the buffer renders once at the
final post-mode-line row count with zero intermediate 1-row bounce."
  (etaf-fullscreen--cancel-timers state)
  (let* ((win (get-buffer-window buffer t))
         (rt (etaf-runtime-for-buffer buffer))
         (mounted (and rt (etaf-runtime-mounted-p rt) win (window-live-p win))))
    (etaf-batch
      (when mounted
        (ignore-errors (etaf-refit rt win)))
      (etaf-set-value (etaf-fullscreen--state-mode-ref state) target)
      (unless (eq prev target)
        (etaf-fullscreen--notify state target))
      (when (and mounted (fboundp 'etaf-app--fit))
        (ignore-errors (etaf-app--fit buffer win)))))
  (when (fboundp 'etaf-video--sync-all-gpu-instances)
    (ignore-errors (etaf-video--sync-all-gpu-instances)))
  (unless noninteractive
    ;; Delayed safety passes are no-ops once viewport settles; they only run
    ;; app fit when a custom mode-line or animated OS fullscreen changes size.
    (let ((delays (if frame-transition '(0.06 0.25 0.65) '(0.06))))
      (setf (etaf-fullscreen--state-timers state)
            (mapcar (lambda (d)
                      (run-at-time d nil #'etaf-fullscreen--sync-now buffer nil))
                    delays)))))

(defun etaf-fullscreen--apply-mode-line (buffer state hide)
  "Hide or restore BUFFER's mode-line according to HIDE using STATE."
  (with-current-buffer buffer
    (cond
     ((and hide (not (etaf-fullscreen--state-mode-line-saved state)))
      (setf (etaf-fullscreen--state-mode-line-saved state) t
            (etaf-fullscreen--state-mode-line-was-local state)
            (local-variable-p 'mode-line-format)
            (etaf-fullscreen--state-mode-line-value state) mode-line-format)
      (setq-local mode-line-format nil)
      (force-mode-line-update))
     ((and (not hide) (etaf-fullscreen--state-mode-line-saved state))
      (if (etaf-fullscreen--state-mode-line-was-local state)
          (setq-local mode-line-format (etaf-fullscreen--state-mode-line-value state))
        (kill-local-variable 'mode-line-format))
      (setf (etaf-fullscreen--state-mode-line-saved state) nil
            (etaf-fullscreen--state-mode-line-was-local state) nil
            (etaf-fullscreen--state-mode-line-value state) nil)
      (force-mode-line-update)))))

(defun etaf-fullscreen--restore-frame (buffer state)
  "Restore any frame fullscreen parameter and window configuration in STATE.
Returns non-nil when an OS fullscreen change was reverted."
  (let ((fr (etaf-fullscreen--state-frame state))
        (wconf (etaf-fullscreen--state-saved-wconf state))
        (saved-fs (etaf-fullscreen--state-saved-os-fullscreen state))
        (changed-os (etaf-fullscreen--state-changed-os-fullscreen state)))
    (setf (etaf-fullscreen--state-frame state) nil
          (etaf-fullscreen--state-saved-wconf state) nil
          (etaf-fullscreen--state-saved-os-fullscreen state) nil
          (etaf-fullscreen--state-changed-os-fullscreen state) nil)
    (when (and changed-os fr (frame-live-p fr))
      (ignore-errors (set-frame-parameter fr 'fullscreen saved-fs)))
    (when (and wconf fr (frame-live-p fr))
      (with-selected-frame fr
        (ignore-errors (set-window-configuration wconf))
        (when-let* (((buffer-live-p buffer))
                    (bwin (get-buffer-window buffer fr)))
          (when (window-live-p bwin)
            (select-window bwin)))))
    changed-os))

(defun etaf-fullscreen--enter-frame (buffer state)
  "Snapshot window/frame state in STATE and expand BUFFER to frame fullscreen.
Returns non-nil when OS fullscreen parameter changed."
  (let* ((win (or (get-buffer-window buffer t) (selected-window)))
         (fr (and win (window-live-p win) (window-frame win))))
    (when (and fr (frame-live-p fr))
      (let* ((cur-fs (frame-parameter fr 'fullscreen))
             (had-splits (not (one-window-p t fr)))
             (wconf (when had-splits (current-window-configuration fr)))
             (need-os (and (display-graphic-p fr)
                           (not noninteractive)
                           (not (memq cur-fs '(fullboth fullscreen))))))
        (setf (etaf-fullscreen--state-frame state) fr
              (etaf-fullscreen--state-saved-wconf state) wconf
              (etaf-fullscreen--state-saved-os-fullscreen state) cur-fs
              (etaf-fullscreen--state-changed-os-fullscreen state) nil)
        (when (and had-splits (window-live-p win))
          (with-selected-frame fr
            (ignore-errors (delete-other-windows win))))
        (when need-os
          (condition-case nil
              (progn
                (set-frame-parameter fr 'fullscreen 'fullboth)
                (setf (etaf-fullscreen--state-changed-os-fullscreen state) t))
            (error nil)))
        (etaf-fullscreen--state-changed-os-fullscreen state)))))

(defun etaf-fullscreen--notify (state mode)
  "Invoke STATE's `:on-change' callback with MODE, isolating errors."
  (when-let* ((fn (etaf-fullscreen--state-on-change state)))
    (ignore-errors (funcall fn mode))))

(defun etaf-fullscreen--buffer-killed ()
  "Restore frame and mode-line state if a fullscreen buffer is killed."
  (when-let* ((state etaf-fullscreen--buffer-state))
    (etaf-fullscreen--cancel-timers state)
    (when (etaf-value (etaf-fullscreen--state-mode-ref state))
      (etaf-fullscreen--restore-frame (current-buffer) state)
      (etaf-fullscreen--apply-mode-line (current-buffer) state nil)
      (etaf-set-value (etaf-fullscreen--state-mode-ref state) nil))))

;;;###autoload
(defun etaf-fullscreen-mode (&optional buffer)
  "Return the reactive fullscreen mode of BUFFER: nil, `window' or `frame'.
BUFFER defaults to the current buffer.  Reading this inside a Component
`:render' subscribes the View to fullscreen transitions."
  (let* ((buf (etaf-fullscreen--resolve-buffer buffer))
         (state (etaf-fullscreen--ensure-state buf)))
    (etaf-value (etaf-fullscreen--state-mode-ref state))))

;;;###autoload
(defun etaf-fullscreen-active-p (&optional buffer)
  "Return non-nil when BUFFER is currently in `window' or `frame' fullscreen.
BUFFER defaults to the current buffer and tracks fullscreen changes reactively."
  (and (etaf-fullscreen-mode buffer) t))

;;;###autoload
(cl-defun etaf-fullscreen-enter (&optional mode buffer &key (hide-mode-line t) on-change)
  "Enter fullscreen MODE (`window' or `frame') for BUFFER.
MODE defaults to `window' (in-window pure fullscreen without altering splits or
OS spaces).  `frame' saves the frame's window configuration and `fullscreen'
parameter, expands BUFFER to a single window, and enters OS fullscreen on
graphical frames.  When HIDE-MODE-LINE is non-nil (the default), temporarily
hides BUFFER's mode-line and restores it on exit or buffer kill.  Optional
ON-CHANGE runs with the new mode symbol on each transition.  Returns MODE."
  (let* ((target (or mode 'window))
         (buf (etaf-fullscreen--resolve-buffer buffer)))
    (unless (memq target '(window frame))
      (signal 'wrong-type-argument (list '(member window frame) target)))
    (let* ((state (etaf-fullscreen--ensure-state buf))
           (prev (etaf-value (etaf-fullscreen--state-mode-ref state)))
           (frame-changed nil))
      (when on-change
        (setf (etaf-fullscreen--state-on-change state) on-change))
      (with-current-buffer buf
        (add-hook 'kill-buffer-hook #'etaf-fullscreen--buffer-killed -60 t))
      (etaf-fullscreen--apply-mode-line buf state hide-mode-line)
      (cond
       ((and (eq target 'frame) (not (eq prev 'frame)))
        (setq frame-changed (etaf-fullscreen--enter-frame buf state)))
       ((and (eq target 'window) (eq prev 'frame))
        (setq frame-changed (etaf-fullscreen--restore-frame buf state))))
      (etaf-fullscreen--commit buf state target prev
                               (or frame-changed (eq target 'frame)))
      target)))

;;;###autoload
(defun etaf-fullscreen-exit (&optional buffer)
  "Exit fullscreen for BUFFER, restoring mode-line, splits and frame state.
BUFFER defaults to the current buffer.  Idempotent when BUFFER is not in
fullscreen.  Returns nil."
  (let* ((buf (etaf-fullscreen--resolve-buffer buffer))
         (state (buffer-local-value 'etaf-fullscreen--buffer-state buf)))
    (when state
      (let* ((prev (etaf-value (etaf-fullscreen--state-mode-ref state)))
             (had-frame (or (eq prev 'frame)
                            (etaf-fullscreen--state-frame state)
                            (etaf-fullscreen--state-saved-wconf state)))
             (frame-changed (when had-frame
                              (etaf-fullscreen--restore-frame buf state))))
        (etaf-fullscreen--apply-mode-line buf state nil)
        (when prev
          (etaf-fullscreen--commit buf state nil prev frame-changed)))))
  nil)

;;;###autoload
(cl-defun etaf-fullscreen-toggle (&optional mode buffer &key (hide-mode-line t) on-change)
  "Toggle fullscreen MODE (`window' or `frame') for BUFFER.
MODE defaults to `window'.  When BUFFER is already in MODE, exits fullscreen
and returns nil.  When BUFFER is normal or in the other fullscreen tier,
transitions directly to MODE and returns MODE.  HIDE-MODE-LINE and ON-CHANGE
are forwarded to `etaf-fullscreen-enter'."
  (let* ((target (or mode 'window))
         (buf (etaf-fullscreen--resolve-buffer buffer)))
    (unless (memq target '(window frame))
      (signal 'wrong-type-argument (list '(member window frame) target)))
    (if (eq (etaf-fullscreen-mode buf) target)
        (etaf-fullscreen-exit buf)
      (etaf-fullscreen-enter target buf
                             :hide-mode-line hide-mode-line
                             :on-change on-change))))

(provide 'etaf-fullscreen)
;;; etaf-fullscreen.el ends here
