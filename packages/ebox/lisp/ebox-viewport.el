;;; ebox-viewport.el --- Event-loop viewport delivery -*- lexical-binding: t; -*-

;;; Commentary:
;; Emacs owns window events; Ebox owns the mounted viewport.  This module is
;; the single bridge between them.  Size and buffer-change hooks record frame
;; intents; one task samples current visible dimensions and refits mounts after
;; the drag settles.  A text scale change is a viewport intent too: it changes
;; every measured glyph, so one task refreshes the glyph caches and lays the
;; scaled mounts out again after the scale settles.  After each refit the
;; task tells `ebox-display-window-change-functions' which display windows
;; changed, so state that follows a window can refit in the same settle.

;;; Code:

(require 'cl-lib)
(require 'ebox-buffer)

(defvar ebox--window-size-change-in-progress nil
  "Non-nil while Ebox is draining one batch of viewport notifications.")

(defvar ebox--window-size-change-pending-frames nil
  "Frames awaiting viewport synchronization, deduplicated by EQ.
The queue holds no buffers, runtime roots or sampled dimensions.")

(defvar ebox--viewport-frame-sizes (make-hash-table :test #'eq)
  "Last frame size seen by the viewport bridge, keyed by frame.
A frame resize stays a user resize even while transient UI borrows window
space; only a window-configuration change inside an unchanged frame is
borrowed.")

(defun ebox--viewport-frame-size (frame)
  "Return FRAME's size in character rows and columns, or nil."
  (when (frame-live-p frame)
    (cons (frame-width frame) (frame-height frame))))

(defun ebox--viewport-record-frame-size (frame)
  "Record FRAME's current character size for the viewport bridge guard."
  (when-let* ((size (ebox--viewport-frame-size frame)))
    (puthash frame size ebox--viewport-frame-sizes)))

(defvar ebox--window-size-change-timer nil
  "The single owned task scheduled to drain viewport notifications.")

(defvar ebox-viewport-settle-delay 0.12
  "Seconds of quiet after the last size change before Ebox reflows.
Dragging a frame edge fires size events faster than one reflow completes, so
rendering every event queues reflow after reflow and freezes the session.
Reschedule this trailing delay on each event; the drag then reflows once it
settles instead of once per intermediate size.")

(defvar ebox-display-window-change-functions nil
  "Abnormal hook run in a mounted BUFFER with BUFFER and its display WINDOW.
It runs once a window change settles, after BUFFER's mount was refit, when
WINDOW became BUFFER's display window or its body pixel size changed since
the hook last ran for BUFFER.  Transient UI borrowing lines does not run it.
It runs even when a fixed mount viewport kept the layout unchanged.")

(defvar ebox--display-window-geometry (make-hash-table :test #'eq :weakness 'key)
  "Display window and body pixel size last delivered per mounted buffer.")

(defun ebox--display-window-notify (buffer window borrowed)
  "Run `ebox-display-window-change-functions' when BUFFER's WINDOW changed.
With BORROWED non-nil, transient UI holds lines of the frame, so a shorter
body than last delivered is not a change."
  (let ((geometry (list window (window-body-width window t)
                        (window-body-height window t)))
        (last (gethash buffer ebox--display-window-geometry)))
    (unless (or (equal geometry last)
                (and borrowed (eq window (car last))
                     (< (nth 2 geometry) (nth 2 last))))
      (puthash buffer geometry ebox--display-window-geometry)
      (with-current-buffer buffer
        (run-hook-with-args 'ebox-display-window-change-functions buffer window)))))

(defun ebox--window-size-change-sync-frame (frame)
  "Refit mounted Ebox buffers whose display window is in FRAME."
  (when (frame-live-p frame)
    (let ((seen (make-hash-table :test #'eq))
          (frame-size (ebox--viewport-frame-size frame))
          (frame-changed
           (not (equal (ebox--viewport-frame-size frame)
                       (gethash frame ebox--viewport-frame-sizes)))))
      (dolist (window (window-list frame 'no-minibuf))
        (let ((buffer (window-buffer window)))
          (unless (gethash buffer seen)
            (puthash buffer t seen)
            (let ((mount (ebox-buffer-mount buffer))
                  (display-window (ebox--display-window buffer)))
              (when (and mount (window-live-p display-window)
                         (eq (window-frame display-window) frame))
                (let ((height (window-body-height display-window))
                      (borrowed (and (not frame-changed)
                                     (ebox--viewport-transient-space-borrow-p frame))))
                  ;; Borrowed space is not a resize.  A height decrease while
                  ;; the minibuffer, a completion popup or the echo area is
                  ;; showing keeps the mounted viewport; a frame change or
                  ;; height growth is real geometry.
                  ;;
                  ;; The echo area shows one or two lines, so only that much can
                  ;; be borrowed.  Treating any message as borrowed kept a page
                  ;; mounted in a small window at that size forever: the user
                  ;; resized the frame, the height was larger, the mount still
                  ;; reported the old rows and the page drew a small block in a
                  ;; big window.  A larger drop is a resize, message or not.
                  (let ((drop (- (or (ebox-mount-vh mount) 0) height)))
                    (unless (and borrowed (< height (or (ebox-mount-vh mount) -1))
                                 (<= drop 3))
                      (ebox-refit buffer)))
                  (when (buffer-live-p buffer)
                    (ebox--display-window-notify buffer display-window borrowed))))))))
      (when frame-size
        (puthash frame frame-size ebox--viewport-frame-sizes)))))

(defun ebox--viewport-transient-space-borrow-p (frame)
  "Whether FRAME's transient UI currently borrows its displayed space.
An active minibuffer or completion popup, and a message in the echo area,
take lines from displayed windows without the user resizing the frame.  A
mounted viewport keeps its committed size until that UI releases them."
  (or (let ((minibuffer (active-minibuffer-window)))
        (and minibuffer
             (eq (window-frame minibuffer) frame)))
      (and (current-message) t)))

(defvar ebox--text-scale-pending nil
  "Buffers awaiting metric refresh in the shared viewport task.")

(defun ebox--window-size-change-schedule ()
  "Schedule one task for live viewport intents outside the current batch."
  (setq ebox--window-size-change-pending-frames
        (cl-delete-if-not #'frame-live-p
                          ebox--window-size-change-pending-frames)
        ebox--text-scale-pending
        (cl-delete-if-not (lambda (buffer)
                            (and (buffer-live-p buffer) (ebox-buffer-mount buffer)))
                          ebox--text-scale-pending))
  (when (and (or ebox--window-size-change-pending-frames ebox--text-scale-pending)
             (not ebox--window-size-change-in-progress))
    (when ebox--window-size-change-timer
      (cancel-timer ebox--window-size-change-timer))
    (setq ebox--window-size-change-timer
          (run-at-time ebox-viewport-settle-delay nil
                       #'ebox--window-size-change-drain))))

(defun ebox--window-size-change-drain ()
  "Consume one frame batch, leaving nested notifications for a later task."
  (unless ebox--window-size-change-in-progress
    (let ((ebox--window-size-change-in-progress t)
          (frames (nreverse ebox--window-size-change-pending-frames))
          (buffers (nreverse ebox--text-scale-pending))
          first-error)
      (unwind-protect
          (progn
            (setq ebox--window-size-change-pending-frames nil
                  ebox--text-scale-pending nil
                  ebox--window-size-change-timer nil)
            (when buffers (ebox-clear-cache))
            ;; Timer dispatch inhibits quit by default.  Enable C-g only after
            ;; cleanup is installed.
            (let ((inhibit-quit nil))
              (while buffers
                (let ((buffer (pop buffers)))
                  (when (buffer-live-p buffer)
                    (condition-case failure
                        (ebox--refresh-metrics buffer)
                      (error (unless first-error (setq first-error failure))))))))
            (let ((inhibit-quit nil))
              (while frames
                (let ((frame (pop frames)))
                  (condition-case failure
                      (ebox--window-size-change-sync-frame frame)
                    (error (unless first-error (setq first-error failure))))))))
        ;; Keep unstarted work after a quit, but do not retry failed work.
        (dolist (buffer buffers)
          (unless (memq buffer ebox--text-scale-pending)
            (push buffer ebox--text-scale-pending)))
        (dolist (frame frames)
          (unless (memq frame ebox--window-size-change-pending-frames)
            (push frame ebox--window-size-change-pending-frames)))
        (let ((ebox--window-size-change-in-progress nil))
          (ebox--window-size-change-schedule)))
      (when first-error (signal (car first-error) (cdr first-error))))))

(defun ebox--window-size-change (frame)
  "Record FRAME's latest viewport intent without rendering inside the hook."
  (when (and (frame-live-p frame) (not noninteractive))
    (unless (memq frame ebox--window-size-change-pending-frames)
      (push frame ebox--window-size-change-pending-frames))
    (ebox--window-size-change-schedule)))

(defun ebox--window-size-change-minibuffer-exit ()
  "Recheck viewports once the minibuffer releases borrowed space.
A completion popup may close inside `minibuffer-exit-hook' while the exit is
still in progress, so the following settle re-reads the stable geometry."
  (dolist (frame (frame-list))
    (when (frame-live-p frame)
      (ebox--window-size-change frame))))

(when (boundp 'window-size-change-functions)
  (add-hook 'window-size-change-functions #'ebox--window-size-change))

;; Showing a mounted buffer in a window of another size changes its viewport
;; without resizing any window, so buffer changes are viewport intents too.
(when (boundp 'window-buffer-change-functions)
  (add-hook 'window-buffer-change-functions #'ebox--window-size-change))

(when (boundp 'minibuffer-exit-hook)
  (add-hook 'minibuffer-exit-hook #'ebox--window-size-change-minibuffer-exit))

;;;; Text scale

(defun ebox--text-scale-change ()
  "Record the current buffer's text scale change as a viewport intent."
  (when (ebox-buffer-mount (current-buffer))
    (unless (memq (current-buffer) ebox--text-scale-pending)
      (push (current-buffer) ebox--text-scale-pending))
    (ebox--window-size-change-schedule)))

;; Text scaling is buffer-local and changes the metrics the mount measured
;; with, so a scaled mounted buffer is a viewport intent.  The hook fires on
;; every step, including the step back to the unscaled size.
(add-hook 'text-scale-mode-hook #'ebox--text-scale-change)

(provide 'ebox-viewport)

;;; ebox-viewport.el ends here
