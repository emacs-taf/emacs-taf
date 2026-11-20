;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-app.el --- Idle presentation and input-owned teardown

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One presentation owns one animation timer, one transient input map and one
;; window configuration.  Stop is idempotent and clears ownership before any
;; callback can reenter it.  Automatic mode separately owns one idle watcher;
;; it never starts a process and suspends its watcher during presentation.

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-screensaver-playlist)
(require 'etaf-screensaver-engine)
(require 'etaf-screensaver-dsl)
(require 'etaf-screensaver-layers)
(require 'etaf-screensaver-loader)
(require 'etaf-screensaver-import)
(require 'etaf-screensaver-tte)
(require 'etaf-screensaver-frames)
(require 'etaf-screensaver-scene-donut)
(require 'etaf-screensaver-scene-equalizer)
(require 'etaf-screensaver-views)

(defcustom etaf-screensaver-idle-delay 300
  "Seconds without Emacs input before automatic presentation.
Set this before enabling `etaf-screensaver-mode'.  Enabling the mode again
re-arms its single watcher with the current value.  Mouse movement during a
presentation also starts a fresh idle interval when it dismisses the scene."
  :type 'number :group 'etaf-screensaver)

(cl-defstruct (etaf-screensaver--presentation (:constructor etaf-screensaver--presentation-new))
  session frame window configuration origin-buffer timer exit-map track-mouse frame-parameters
  (canvas (etaf-ref nil))
  program configured-seed resumable queue random-state seed index deadline last-time focus
  transition-duration read-ahead)

(defvar etaf-screensaver--active nil)
(defvar etaf-screensaver--idle-timer nil)

(defconst etaf-screensaver--playback-gc-cons-threshold (* 32 1024 1024)
  "GC threshold while a presentation is active.
A large global threshold makes one collection pause for half a second during
continuous playback.  A smaller threshold spread those collections into short
pauses; the previous user value is restored when the presentation stops.")

(defvar etaf-screensaver--saved-gc-cons-threshold nil
  "User GC threshold saved by the active presentation, or nil.")

(defun etaf-screensaver--begin-playback-gc ()
  "Lower `gc-cons-threshold' for one presentation, saving the old value."
  (unless etaf-screensaver--saved-gc-cons-threshold
    (setq etaf-screensaver--saved-gc-cons-threshold gc-cons-threshold)
    (setq gc-cons-threshold
          (min gc-cons-threshold etaf-screensaver--playback-gc-cons-threshold))))

(defun etaf-screensaver--end-playback-gc ()
  "Restore the GC threshold saved by `etaf-screensaver--begin-playback-gc'."
  (when etaf-screensaver--saved-gc-cons-threshold
    (setq gc-cons-threshold etaf-screensaver--saved-gc-cons-threshold
          etaf-screensaver--saved-gc-cons-threshold nil)))
(defvar etaf-screensaver-mode nil)
(defvar etaf-screensaver--resume nil
  "Playback position kept across dismissals of the configured program.
Set when a presentation stops and consumed by the next start that uses
the same effective configuration, so an interrupted screensaver restarts
its current work instead of replaying the round from its first item.  The
program generator retains its random state.  Explicit PROGRAM previews
neither consume nor replace this position.")

(defun etaf-screensaver--cancel-idle ()
  "Release the automatic mode's pending watcher."
  (when (timerp etaf-screensaver--idle-timer)
    (cancel-timer etaf-screensaver--idle-timer))
  (setq etaf-screensaver--idle-timer nil))

(defun etaf-screensaver--arm-idle ()
  "Arm one idle interval after this input or mouse-only wake."
  (etaf-screensaver--cancel-idle)
  (when (and etaf-screensaver-mode (not etaf-screensaver--active))
    (let ((idle (current-idle-time)))
      ;; Mouse motion need not reset Emacs's own idle clock.  Offset the
      ;; deadline in that case; the next ordinary command resets it normally.
      (setq etaf-screensaver--idle-timer
            (run-with-idle-timer
             (+ etaf-screensaver-idle-delay (if idle (float-time idle) 0)) nil
             #'etaf-screensaver--idle-fire)))))

(defun etaf-screensaver--idle-fire ()
  "Present only in an available, focused Emacs frame."
  (setq etaf-screensaver--idle-timer nil)
  (when (and etaf-screensaver-mode (not etaf-screensaver--active))
    (if (or (active-minibuffer-window) executing-kbd-macro (input-pending-p)
            (not (eq (frame-visible-p (selected-frame)) t))
            (and (display-graphic-p) (not (eq (frame-focus-state) t))))
        (etaf-screensaver--arm-idle)
      (condition-case problem
          (etaf-screensaver-start)
        (error
         (etaf-screensaver-mode -1)
         (display-warning 'etaf-screensaver (error-message-string problem) :warning))))))

(defun etaf-screensaver--wake-before-command ()
  "Consume input while presenting, then restore the previous interface."
  (when etaf-screensaver--active
    ;; A click comprises down and up.  Consume the down event and dismiss on
    ;; up, so a trailing click cannot activate a restored application's UI.
    (unless (memq 'down (event-modifiers last-command-event))
      (etaf-screensaver-stop))
    (setq this-command #'ignore)))

(defun etaf-screensaver--wake ()
  "Dismiss the presentation without replaying the wake event."
  (interactive)
  (etaf-screensaver-stop))

(defun etaf-screensaver--window-changed ()
  "Release a presentation whose owning window or frame disappeared."
  (when-let* ((owner etaf-screensaver--active))
    (let ((window (etaf-screensaver--presentation-window owner))
          (buffer (etaf-screensaver--session-buffer
                   (etaf-screensaver--presentation-session owner))))
      (unless (and (window-live-p window) (eq (window-buffer window) buffer)
                   (eq (frame-visible-p (etaf-screensaver--presentation-frame owner)) t))
        (etaf-screensaver-stop)))))

(defun etaf-screensaver--focus-changed ()
  "Release the presentation when its frame actually loses keyboard focus.
The global notification also runs for other frames.  A manually started
background preview must not mistake an unchanged nil focus for a loss."
  (when-let* ((owner etaf-screensaver--active))
    (let ((focus (frame-focus-state (etaf-screensaver--presentation-frame owner))))
      (when (memq focus '(t nil))
        (let ((previous (etaf-screensaver--presentation-focus owner)))
          (setf (etaf-screensaver--presentation-focus owner) focus)
          (when (and (eq previous t) (null focus))
            (etaf-screensaver-stop)))))))

(defun etaf-screensaver--frame-deleted (frame)
  "Release the presentation if its FRAME is being deleted."
  (when (and etaf-screensaver--active
             (eq frame (etaf-screensaver--presentation-frame etaf-screensaver--active)))
    (etaf-screensaver-stop)))

(defun etaf-screensaver--columns (window)
  "Return drawable columns in WINDOW, reserving Emacs's end-of-line cell."
  (max 1 (1- (window-body-width window))))

(defun etaf-screensaver--paint-echo (owner background)
  "Paint OWNER's echo row with BACKGROUND across the minibuffer width.
The echo row is below the presentation window but part of the visible mat;
leave the frame background alone so the title bar keeps its own color."
  (let* ((frame (etaf-screensaver--presentation-frame owner))
         (window (and (frame-live-p frame) (minibuffer-window frame))))
    (when (window-live-p window)
      (let* ((width (max 1 (window-body-width window)))
             (height (max 1 (window-total-height window)))
             (line (propertize (make-string width ?\s)
                              'face (list :background background))))
        (with-current-buffer (window-buffer window)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (buffer-undo-list t))
            (erase-buffer)
            (dotimes (row height)
              (insert line)
              (when (< row (1- height)) (insert "\n")))
            (goto-char (point-min))))))))

(defun etaf-screensaver--clear-echo (owner)
  "Empty OWNER's echo row without touching the frame background."
  (let* ((frame (etaf-screensaver--presentation-frame owner))
         (window (and (frame-live-p frame) (minibuffer-window frame))))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t)
              (buffer-undo-list t))
          (erase-buffer)
          (goto-char (point-min)))))))

(defun etaf-screensaver--canvas-face (owner)
  "Paint OWNER's scene background across the canvas and the echo row.
The echo row below the presentation window is part of the visible mat; the
card layout counts it, so the bottom and top distances stay equal."
  (let ((background (etaf-screensaver--session-background
                     (etaf-screensaver--presentation-session owner))))
    ;; The application canvas follows this source, so the scene background
    ;; repaints across every cell the View does not paint.
    (setf (etaf-value (etaf-screensaver--presentation-canvas owner)) background)
    (etaf-screensaver--paint-echo owner background)))

(defun etaf-screensaver--page-repeat-p (owner item)
  "Return non-nil when ITEM repeats OWNER's current running page."
  (equal item (etaf-screensaver--session-item
               (etaf-screensaver--presentation-session owner))))

(defun etaf-screensaver--read-ahead (owner now)
  "Give OWNER's next queued page one bounded metadata chunk at time NOW.
Peek only: no scene creation, playlist expansion, RNG advance or extra timer.
A repeated page keeps the running work, so it needs no preparation."
  (when (and (etaf-screensaver--presentation-queue owner)
             (not (etaf-screensaver--page-repeat-p
                   owner (car (etaf-screensaver--presentation-queue owner))))
             (<= (- (etaf-screensaver--presentation-deadline owner) now) 6))
    (let* ((item (etaf-screensaver--session-item
                  (etaf-screensaver--presentation-session owner)))
           (deadline (+ now (/ 0.25 (plist-get item :frame-rate)))))
      ;; Give queued IO only spare time in this frame's first quarter.
      ;; Expensive rendering or GC must not gain another IO tail.
      (when (< (float-time) deadline)
        (unless (etaf-screensaver--presentation-read-ahead owner)
          (let ((next (car (etaf-screensaver--presentation-queue owner))))
            (setf (etaf-screensaver--presentation-read-ahead owner)
                  (cons next
                        (cl-loop for tile in (or (plist-get next :tiles) (list next))
                                 for source = (etaf-screensaver--scene-reel-source
                                               (plist-get tile :definition))
                                 when source collect
                                 (etaf-screensaver--frames-preparation-new :source source))))))
        ;; At most one reader/chunk per callback, including a four-work mosaic.
        (when-let* ((preparation
                     (cl-find-if-not #'etaf-screensaver--frames-preparation-done
                                     (cdr (etaf-screensaver--presentation-read-ahead owner)))))
          (etaf-screensaver--frames-prepare-step
           preparation (min deadline (+ (float-time) 0.006))))))))

(defun etaf-screensaver--next (owner now)
  "Select OWNER's next item at wall time NOW.
A repeated page first advances the running work up to NOW, so the boundary
frame is not held while the page clock rolls over."
  (unless (etaf-screensaver--presentation-queue owner)
    (setf (etaf-screensaver--presentation-queue owner)
          (etaf-screensaver--program-round (etaf-screensaver--presentation-program owner)
                                           (etaf-screensaver--presentation-random-state owner))))
  (let* ((session (etaf-screensaver--presentation-session owner))
         (item (car (etaf-screensaver--presentation-queue owner)))
         (prepared (etaf-screensaver--presentation-read-ahead owner))
         (repeat (etaf-screensaver--page-repeat-p owner item))
         (deadline (etaf-screensaver--presentation-deadline owner)))
    (setf (etaf-screensaver--presentation-read-ahead owner) nil)
    (when (eq item (car prepared))
      (dolist (preparation (cdr prepared))
        (etaf-screensaver--frames-prepare-finish preparation)))
    (pop (etaf-screensaver--presentation-queue owner))
    (cl-incf (etaf-screensaver--presentation-index owner))
    (if repeat
        ;; A repeated page continues the running work instead of recreating
        ;; it.  Advance across the boundary as part of the same timeline:
        ;; dropping this interval leaves one frame's motion frozen at every
        ;; loop, which reads as a hitch in a continuous field.
        (let ((elapsed (max 0 (- now (etaf-screensaver--presentation-last-time owner)))))
          (etaf-screensaver--session-step session elapsed)
          (etaf-screensaver--session-render session))
      (etaf-screensaver--session-select
       session item
       (+ (etaf-screensaver--presentation-seed owner) (etaf-screensaver--presentation-index owner))
       (etaf-screensaver--presentation-transition-duration owner))
      (etaf-screensaver--canvas-face owner))
    (let ((next (+ deadline (plist-get item :duration))))
      ;; Keep the page grid stable when a callback is slightly late, but
      ;; start a fresh page after a stall longer than that page itself.
      (setf (etaf-screensaver--presentation-deadline owner)
            (if (< next now) (+ now (plist-get item :duration)) next)))))

(defun etaf-screensaver--arm-frame (owner)
  "Schedule OWNER's next frame only while it still owns the presentation."
  (when (eq owner etaf-screensaver--active)
    (let* ((session (etaf-screensaver--presentation-session owner))
           (item (etaf-screensaver--session-item session))
           (rate (plist-get item :frame-rate))
           (deadline (etaf-screensaver--presentation-deadline owner))
           (origin (- deadline (plist-get item :duration)))
           (now (float-time))
           ;; Anchor cadence to the page clock, not each late callback.  The
           ;; latter accumulates timer jitter and shifts the last outgoing
           ;; frame relative to the natural page boundary.  Missed grid slots
           ;; are skipped; never queue a burst of expired frame callbacks.
           (slot (1+ (floor (* rate (max 0 (- now origin))))))
           (due (min deadline (+ origin (/ slot (float rate))))))
      (setf (etaf-screensaver--presentation-timer owner)
            (run-at-time (max 0.001 (- due now))
                         nil #'etaf-screensaver--tick owner)))))

(defun etaf-screensaver--tick (owner)
  "Render one live frame for OWNER; failures unwind the whole presentation."
  (setf (etaf-screensaver--presentation-timer owner) nil)
  (when (eq owner etaf-screensaver--active)
    (condition-case problem
        (progn
          (etaf-screensaver--window-changed)
          (when (eq owner etaf-screensaver--active)
            (let* ((session (etaf-screensaver--presentation-session owner))
                   (window (etaf-screensaver--presentation-window owner))
                   (now (float-time))
                   (dt (max 0 (- now (etaf-screensaver--presentation-last-time owner)))))
              (etaf-screensaver--session-resize
               session (etaf-screensaver--columns window) (max 1 (window-body-height window)))
              (if (>= now (etaf-screensaver--presentation-deadline owner))
                  (progn (etaf-screensaver--next owner now)
                         (etaf-screensaver--session-publish session))
                (etaf-screensaver--session-advance session dt)
                (etaf-screensaver--read-ahead owner now))
              (setf (etaf-screensaver--presentation-last-time owner) now))
            (etaf-screensaver--arm-frame owner)))
      (quit (etaf-screensaver-stop))
      (error
       (etaf-screensaver-stop)
       ;; Do not repeatedly enter a broken scene while the user is idle.
       (when etaf-screensaver-mode (etaf-screensaver-mode -1))
       (display-warning 'etaf-screensaver (error-message-string problem) :warning)))))

(defun etaf-screensaver-start (&optional program)
  "Present PROGRAM, or `etaf-screensaver-program', and return its buffer.
Starting an already active presentation returns its buffer without replacing
its window snapshot.  Validate configuration before takeover.  Any failure
restores the interface and signals the original error.  Input is consumed;
keyboard input, mouse movement, a click or wheel input dismisses the scene.
This is a visual screensaver, not an operating-system security lock."
  (interactive)
  (if etaf-screensaver--active
      (etaf-screensaver--session-buffer
       (etaf-screensaver--presentation-session etaf-screensaver--active))
    (when (active-minibuffer-window)
      (user-error "Cannot start a screensaver while the minibuffer is active"))
    (etaf-screensaver--validate-options)
    (etaf-screensaver--begin-playback-gc)
    (let* ((tree (etaf-screensaver--compile-program (or program etaf-screensaver-program)))
           (resume (and (null program)
                        (equal (plist-get etaf-screensaver--resume :program) tree)
                        (equal (plist-get etaf-screensaver--resume :configured-seed) etaf-screensaver-seed)
                        etaf-screensaver--resume))
           (seed (or (and resume (plist-get resume :seed))
                     etaf-screensaver-seed (random most-positive-fixnum)))
           (rng (cl-make-random-state (if resume (plist-get resume :random-state) seed)))
           (queue (if resume
                      (copy-sequence (plist-get resume :queue))
                    (etaf-screensaver--program-round tree rng)))
           (item (pop queue))
           (frame (selected-frame))
           (configuration (current-window-configuration frame))
           (origin-buffer (current-buffer))
           (buffer (generate-new-buffer " *ETAF Screensaver*"))
           session owner)
      (condition-case problem
          (progn
            (setq session (etaf-screensaver--session-create
                           item (+ seed (if resume (plist-get resume :index) 0))
                           (etaf-screensaver--columns (selected-window))
                           (max 1 (window-body-height)) buffer)
                  owner (etaf-screensaver--presentation-new
                         :session session :frame frame :configuration configuration
                         :focus (frame-focus-state frame) :origin-buffer origin-buffer
                         :program tree :queue queue :random-state rng :seed seed
                         :configured-seed etaf-screensaver-seed :resumable (null program)
                         :transition-duration etaf-screensaver-transition-duration
                         :index (if resume (plist-get resume :index) 0)
                         :track-mouse track-mouse
                         :frame-parameters
                         (cl-loop for key in '(tab-bar-lines tool-bar-lines)
                                  for value = (frame-parameter frame key)
                                  when (and (numberp value) (> value 0))
                                  collect (cons key value))))
            (setq etaf-screensaver--active owner)
            (etaf-screensaver--cancel-idle)
            (switch-to-buffer buffer)
            (delete-other-windows)
            (setf (etaf-screensaver--presentation-window owner) (selected-window))
            (dolist (parameter (etaf-screensaver--presentation-frame-parameters owner))
              (set-frame-parameter frame (car parameter) 0))
            (set-window-margins nil 0 0)
            (set-window-fringes nil 0 0)
            (with-current-buffer buffer
              ;; The mode line must be gone before the body height is read:
              ;; the layout counts every row the window can draw.
              (setq-local mode-line-format nil header-line-format nil
                          tab-line-format nil display-line-numbers nil
                          show-trailing-whitespace nil
                          indicate-empty-lines nil))
            (etaf-screensaver--session-resize session (etaf-screensaver--columns (selected-window))
                                             (max 1 (window-body-height)))
            (etaf-app-open
             (buffer-name buffer)
             (etaf-view
              (etaf-screensaver-view
               :session session
               :on-close (lambda ()
                           (when (eq owner etaf-screensaver--active)
                             (etaf-screensaver-stop)))))
             :state session
             :background (etaf-screensaver--presentation-canvas owner)
             :cursor nil
             :mode-line nil
             :display nil
             :on-close (lambda ()
                         (when (eq owner etaf-screensaver--active)
                           (etaf-screensaver-stop))))
            (setf (etaf-screensaver--session-runtime session) (etaf-runtime-for-buffer buffer))
            ;; Mounted metrics may differ from frame defaults used in preflight.
            (etaf-screensaver--session-render session)
            (etaf-screensaver--session-publish session)
            (message nil)
            (etaf-screensaver--canvas-face owner)
            (let ((map (make-sparse-keymap)))
              (define-key map [t] #'etaf-screensaver--wake)
              (define-key map [mouse-movement] #'etaf-screensaver--wake)
              (setf (etaf-screensaver--presentation-exit-map owner)
                    (set-transient-map map (lambda () (eq owner etaf-screensaver--active)))))
            (setq track-mouse t)
            (add-hook 'pre-command-hook #'etaf-screensaver--wake-before-command)
            (add-hook 'window-configuration-change-hook #'etaf-screensaver--window-changed)
            (add-hook 'delete-frame-functions #'etaf-screensaver--frame-deleted)
            (add-function :after after-focus-change-function #'etaf-screensaver--focus-changed)
            (let ((now (float-time)))
              (setf (etaf-screensaver--presentation-last-time owner) now
                    (etaf-screensaver--presentation-deadline owner) (+ now (plist-get item :duration))))
            (etaf-screensaver--arm-frame owner)
            buffer)
        ((error quit)
         (if (and owner (eq owner etaf-screensaver--active))
             (etaf-screensaver-stop)
           (etaf-screensaver--end-playback-gc)
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (signal (car problem) (cdr problem)))))))

(defun etaf-screensaver-stop ()
  "Dismiss the screensaver, restore its windows and release its resources.
Idempotent.  No animation timer, transient keymap, mouse tracking change or
presentation buffer survives.  When automatic mode is enabled, only its
idle watcher and rearming hook remain, waiting a fresh idle interval."
  (interactive)
  (when-let* ((owner etaf-screensaver--active))
    ;; Explicit previews must not replace the configured program's position.
    (when (etaf-screensaver--presentation-resumable owner)
      (setq etaf-screensaver--resume
            (list :program (copy-tree (etaf-screensaver--presentation-program owner))
                  :configured-seed (etaf-screensaver--presentation-configured-seed owner)
                  :queue (cons (etaf-screensaver--session-item
                                (etaf-screensaver--presentation-session owner))
                               (etaf-screensaver--presentation-queue owner))
                  :random-state (cl-make-random-state (etaf-screensaver--presentation-random-state owner))
                  :index (etaf-screensaver--presentation-index owner)
                  :seed (etaf-screensaver--presentation-seed owner))))
    ;; Clear ownership first: unmount, buffer death and map teardown can reenter.
    (setq etaf-screensaver--active nil)
    (etaf-screensaver--clear-echo owner)
    (when (timerp (etaf-screensaver--presentation-timer owner))
      (cancel-timer (etaf-screensaver--presentation-timer owner)))
    (setf (etaf-screensaver--presentation-timer owner) nil
          (etaf-screensaver--presentation-read-ahead owner) nil)
    (remove-hook 'pre-command-hook #'etaf-screensaver--wake-before-command)
    (remove-hook 'window-configuration-change-hook #'etaf-screensaver--window-changed)
    (remove-hook 'delete-frame-functions #'etaf-screensaver--frame-deleted)
    (remove-function after-focus-change-function #'etaf-screensaver--focus-changed)
    (setq track-mouse (etaf-screensaver--presentation-track-mouse owner))
    (when-let* ((exit (etaf-screensaver--presentation-exit-map owner)))
      (funcall exit))
    (let* ((session (etaf-screensaver--presentation-session owner))
           (buffer (etaf-screensaver--session-buffer session))
           (runtime (etaf-screensaver--session-runtime session))
           (frame (etaf-screensaver--presentation-frame owner))
           (restore-current (eq (current-buffer) buffer)))
      (unwind-protect
          (when (and runtime (etaf-runtime-mounted-p runtime)) (etaf-unmount runtime))
        (setf (etaf-screensaver--session-runtime session) nil)
        (etaf-screensaver--session-flush-images session nil)
        (when (frame-live-p frame)
          (with-selected-frame frame
            (when (etaf-screensaver--presentation-frame-parameters owner)
              (modify-frame-parameters frame (etaf-screensaver--presentation-frame-parameters owner)))
            (set-window-configuration (etaf-screensaver--presentation-configuration owner))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when restore-current
          (set-buffer (if (buffer-live-p (etaf-screensaver--presentation-origin-buffer owner))
                          (etaf-screensaver--presentation-origin-buffer owner)
                        (window-buffer (selected-window)))))
        (etaf-screensaver--arm-idle)
        (etaf-screensaver--end-playback-gc))))
  nil)

(defun etaf-screensaver-status ()
  "Return a bounded snapshot of automatic mode and the active presentation.
The plist contains :active, :automatic and, while active, :scene, :buffer,
:index (zero-based playlist position), :seed, :ticks, :elapsed, :columns,
:rows, :frame-rate, :params and :up-next (the remainder of this round).
:presentation names the layout; :works lists the simultaneous scene ids and
:up-next-works lists the works on each remaining page.  :scene remains the
first work's id.  :duration is this page's dwell time.  :transition-progress
is nil outside a reveal, otherwise its elapsed fraction from zero to one.
Returned lists are copies; changing them does not configure playback."
  (let ((owner etaf-screensaver--active))
    (append (list :active (and owner t) :automatic (and etaf-screensaver-mode t))
            (when owner
              (let ((session (etaf-screensaver--presentation-session owner)))
                (list :scene (etaf-screensaver--scene-id (etaf-screensaver--session-scene session))
                      :buffer (buffer-name (etaf-screensaver--session-buffer session))
                      :index (etaf-screensaver--presentation-index owner)
                      :seed (etaf-screensaver--session-seed session)
                      :ticks (etaf-screensaver--session-ticks session)
                      :elapsed (etaf-screensaver--session-elapsed session)
                      :columns (etaf-screensaver--session-window-columns session)
                      :rows (etaf-screensaver--session-window-rows session)
                      :frame-rate (plist-get (etaf-screensaver--session-item session) :frame-rate)
                      :duration (plist-get (etaf-screensaver--session-item session) :duration)
                      :transition-progress
                      (when (etaf-screensaver--session-previous-rows session)
                        (/ (etaf-screensaver--session-elapsed session)
                           (etaf-screensaver--session-transition-duration session)))
                      :presentation (plist-get (etaf-screensaver--session-item session) :presentation)
                      :works (etaf-screensaver--item-works (etaf-screensaver--session-item session))
                      :params (copy-tree (etaf-screensaver--session-params session))
                      :up-next (mapcar (lambda (item) (plist-get item :scene))
                                       (etaf-screensaver--presentation-queue owner))
                      :up-next-works (mapcar #'etaf-screensaver--item-works
                                            (etaf-screensaver--presentation-queue owner))))))))

(defun etaf-screensaver--item-works (item)
  "Return the independent work identifiers displayed by ITEM."
  (mapcar (lambda (work) (plist-get work :scene)) (or (plist-get item :tiles) (list item))))

(define-minor-mode etaf-screensaver-mode
  "Toggle automatic, input-dismissed screensavers after Emacs is idle.
Disabling also dismisses an active presentation and releases the idle watcher.
Calling this repeatedly does not stack timers or hooks.  No external process
is started.  Configure the delay and playback program in Emacs Lisp."
  :global t :group 'etaf-screensaver
  (etaf-screensaver--cancel-idle)
  (remove-hook 'post-command-hook #'etaf-screensaver--arm-idle)
  (if (not etaf-screensaver-mode)
      (etaf-screensaver-stop)
    (unless (and (numberp etaf-screensaver-idle-delay) (> etaf-screensaver-idle-delay 0))
      (setq etaf-screensaver-mode nil)
      (etaf-screensaver--fail "Idle delay must be a positive number"))
    (add-hook 'post-command-hook #'etaf-screensaver--arm-idle)
    (etaf-screensaver--arm-idle)))

(etaf-screensaver-load-scenes)

(provide 'etaf-screensaver-app)
;;; etaf-screensaver-app.el ends here
