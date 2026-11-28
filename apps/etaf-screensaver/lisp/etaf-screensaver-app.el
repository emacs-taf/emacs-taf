;;; etaf-screensaver-app.el --- Idle watcher, takeover and wake lifecycle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One active presentation owns one animation timer, one transient wake map
;; and one window snapshot.  Stopping clears ownership first so reentrant
;; unmount or buffer-kill hooks are safe.  Automatic mode separately owns one
;; idle timer and a post-command rearming hook.

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-screensaver-engine)

(defcustom etaf-screensaver-idle-delay 300
  "Seconds without Emacs input before automatic presentation starts.
Re-enable `etaf-screensaver-mode' after changing this value to re-arm
immediately."
  :type 'number
  :group 'etaf-screensaver)

(cl-defstruct (etaf-screensaver--presentation
               (:constructor etaf-screensaver--presentation-new))
  session frame window configuration origin-buffer timer exit-map
  track-mouse frame-parameters
  (canvas (etaf-ref nil))
  items order resumable queue random-state seed index deadline last-time
  focus transition-duration)

(defvar etaf-screensaver--active nil)
(defvar etaf-screensaver--idle-timer nil)
(defvar etaf-screensaver--resume nil
  "Saved playback position for resuming the configured playlist.")
(defvar etaf-screensaver-mode nil)

(defconst etaf-screensaver--playback-gc-cons-threshold (* 32 1024 1024)
  "GC threshold cap during playback to avoid long collection pauses.")

(defvar etaf-screensaver--saved-gc-cons-threshold nil)

(defun etaf-screensaver--begin-playback-gc ()
  "Cap `gc-cons-threshold' while presenting, saving the caller's value."
  (unless etaf-screensaver--saved-gc-cons-threshold
    (setq etaf-screensaver--saved-gc-cons-threshold gc-cons-threshold
          gc-cons-threshold (min gc-cons-threshold
                                 etaf-screensaver--playback-gc-cons-threshold))))

(defun etaf-screensaver--end-playback-gc ()
  "Restore the caller's `gc-cons-threshold'."
  (when etaf-screensaver--saved-gc-cons-threshold
    (setq gc-cons-threshold etaf-screensaver--saved-gc-cons-threshold
          etaf-screensaver--saved-gc-cons-threshold nil)))

;;; Idle mode.

(defun etaf-screensaver--cancel-idle ()
  "Cancel any pending automatic-mode idle timer."
  (when (timerp etaf-screensaver--idle-timer)
    (cancel-timer etaf-screensaver--idle-timer))
  (setq etaf-screensaver--idle-timer nil))

(defun etaf-screensaver--arm-idle ()
  "Arm one idle interval after user input or a mouse-only wake."
  (etaf-screensaver--cancel-idle)
  (when (and etaf-screensaver-mode (not etaf-screensaver--active))
    (let ((idle (current-idle-time)))
      (setq etaf-screensaver--idle-timer
            (run-with-idle-timer
             (+ etaf-screensaver-idle-delay (if idle (float-time idle) 0))
             nil #'etaf-screensaver--idle-fire)))))

(defun etaf-screensaver--idle-fire ()
  "Start presentation if the selected frame is visible, focused and idle."
  (setq etaf-screensaver--idle-timer nil)
  (when (and etaf-screensaver-mode (not etaf-screensaver--active))
    (if (or (active-minibuffer-window) executing-kbd-macro (input-pending-p)
            (not (eq (frame-visible-p (selected-frame)) t))
            (and (display-graphic-p) (not (eq (frame-focus-state) t))))
        (etaf-screensaver--arm-idle)
      (condition-case problem
          (etaf-screensaver-open)
        (error
         (etaf-screensaver-mode -1)
         (display-warning 'etaf-screensaver
                          (error-message-string problem) :warning))))))

;;; Wake & environment guards.

(defun etaf-screensaver--wake-before-command ()
  "Consume wake input and dismiss on release for mouse clicks."
  (when etaf-screensaver--active
    (unless (memq 'down (event-modifiers last-command-event))
      (etaf-screensaver-stop))
    (setq this-command #'ignore)))

(defun etaf-screensaver--wake ()
  "Dismiss the active presentation without replaying the event."
  (etaf-screensaver-stop))

(defun etaf-screensaver--window-changed ()
  "Stop if the presentation's window or frame disappeared."
  (when-let* ((owner etaf-screensaver--active))
    (let ((window (etaf-screensaver--presentation-window owner))
          (buffer (etaf-screensaver--session-buffer
                   (etaf-screensaver--presentation-session owner))))
      (unless (and (window-live-p window)
                   (eq (window-buffer window) buffer)
                   (eq (frame-visible-p (etaf-screensaver--presentation-frame owner)) t))
        (etaf-screensaver-stop)))))

(defun etaf-screensaver--focus-changed ()
  "Stop only when the owning frame transitions from focused to unfocused."
  (when-let* ((owner etaf-screensaver--active))
    (let ((focus (frame-focus-state (etaf-screensaver--presentation-frame owner))))
      (when (memq focus '(t nil))
        (let ((previous (etaf-screensaver--presentation-focus owner)))
          (setf (etaf-screensaver--presentation-focus owner) focus)
          (when (and (eq previous t) (null focus))
            (etaf-screensaver-stop)))))))

(defun etaf-screensaver--frame-deleted (frame)
  "Stop when the presentation's owning FRAME is deleted."
  (when (and etaf-screensaver--active
             (eq frame (etaf-screensaver--presentation-frame etaf-screensaver--active)))
    (etaf-screensaver-stop)))

;;; Echo-row background & timing.

(defun etaf-screensaver--columns (window)
  "Return drawable columns in WINDOW, reserving Emacs's end-of-line cell."
  (max 1 (1- (window-body-width window))))

(defun etaf-screensaver--paint-echo (owner background)
  "Paint OWNER's echo row with BACKGROUND without changing frame parameters."
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
  "Clear OWNER's echo row."
  (let* ((frame (etaf-screensaver--presentation-frame owner))
         (window (and (frame-live-p frame) (minibuffer-window frame))))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t)
              (buffer-undo-list t))
          (erase-buffer)
          (goto-char (point-min)))))))

(defun etaf-screensaver--sync-canvas-background (owner)
  "Synchronize OWNER's canvas ref and echo row to the current scene color."
  (let ((bg (etaf-screensaver--session-background
             (etaf-screensaver--presentation-session owner))))
    (setf (etaf-value (etaf-screensaver--presentation-canvas owner)) bg)
    (etaf-screensaver--paint-echo owner bg)))

(defun etaf-screensaver--next (owner now)
  "Advance OWNER to the next playlist item at wall time NOW."
  (unless (etaf-screensaver--presentation-queue owner)
    (setf (etaf-screensaver--presentation-queue owner)
          (etaf-screensaver--playlist-round
           (etaf-screensaver--presentation-items owner)
           (etaf-screensaver--presentation-order owner)
           (etaf-screensaver--presentation-random-state owner))))
  (let* ((session (etaf-screensaver--presentation-session owner))
         (item (pop (etaf-screensaver--presentation-queue owner)))
         (repeat (equal item (etaf-screensaver--session-item session)))
         (deadline (etaf-screensaver--presentation-deadline owner)))
    (cl-incf (etaf-screensaver--presentation-index owner))
    (if repeat
        (let ((elapsed (max 0 (- now (etaf-screensaver--presentation-last-time owner)))))
          (etaf-screensaver--session-step session elapsed)
          (etaf-screensaver--session-render session))
      (etaf-screensaver--session-select
       session item
       (+ (etaf-screensaver--presentation-seed owner)
          (etaf-screensaver--presentation-index owner))
       (etaf-screensaver--presentation-transition-duration owner))
      (etaf-screensaver--sync-canvas-background owner))
    (let ((next (+ deadline (plist-get item :duration))))
      (setf (etaf-screensaver--presentation-deadline owner)
            (if (< next now) (+ now (plist-get item :duration)) next)))))

(defun etaf-screensaver--arm-frame (owner)
  "Schedule OWNER's next tick on an absolute frame grid."
  (when (eq owner etaf-screensaver--active)
    (let* ((session (etaf-screensaver--presentation-session owner))
           (item (etaf-screensaver--session-item session))
           (rate (plist-get item :frame-rate))
           (deadline (etaf-screensaver--presentation-deadline owner))
           (origin (- deadline (plist-get item :duration)))
           (now (float-time))
           (slot (1+ (floor (* rate (max 0 (- now origin))))))
           (due (min deadline (+ origin (/ slot (float rate))))))
      (setf (etaf-screensaver--presentation-timer owner)
            (run-at-time (max 0.001 (- due now))
                         nil #'etaf-screensaver--tick owner)))))

(defun etaf-screensaver--tick (owner)
  "Advance and publish one animation frame for OWNER."
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
               session (etaf-screensaver--columns window)
               (max 1 (window-body-height window)))
              (if (>= now (etaf-screensaver--presentation-deadline owner))
                  (progn
                    (etaf-screensaver--next owner now)
                    (etaf-screensaver--session-publish session))
                (etaf-screensaver--session-advance session dt))
              (setf (etaf-screensaver--presentation-last-time owner) now))
            (etaf-screensaver--arm-frame owner)))
      (quit (etaf-screensaver-stop))
      (error
       (etaf-screensaver-stop)
       (when etaf-screensaver-mode (etaf-screensaver-mode -1))
       (display-warning 'etaf-screensaver
                        (error-message-string problem) :warning)))))

;;; Interactive scene picker & public commands.

(defun etaf-screensaver--read-scene (prompt)
  "Prompt with PROMPT for a registered scene symbol with title/summary hints."
  (let* ((names (mapcar #'symbol-name (etaf-screensaver-scenes)))
         (table
          (lambda (string pred action)
            (if (eq action 'metadata)
                `(metadata
                  (annotation-function
                   . ,(lambda (cand)
                        (when-let* ((scene (cdr (assq (intern cand)
                                                      etaf-screensaver--scenes))))
                          (let ((title (etaf-screensaver--scene-title scene))
                                (summary (etaf-screensaver--scene-summary scene)))
                            (if (equal summary "")
                                (format "  %s" title)
                              (format "  %s — %s" title summary)))))))
              (complete-with-action action names string pred)))))
    (intern (completing-read prompt table nil t))))

(defun etaf-screensaver-open (&optional playlist seed)
  "Present PLAYLIST (default `etaf-screensaver-playlist') and return its buffer.
Interactively with a prefix argument, prompt for a single scene to preview.
Optional integer SEED makes randomized scene choices reproducible.
Starting while active returns the existing buffer without overwriting the
saved window configuration.  Any key, mouse movement, click or wheel input
dismisses the presentation and restores the prior windows."
  (interactive
   (list (when current-prefix-arg
           (etaf-screensaver--read-scene "Screensaver: "))))
  (if etaf-screensaver--active
      (etaf-screensaver--session-buffer
       (etaf-screensaver--presentation-session etaf-screensaver--active))
    (when (active-minibuffer-window)
      (user-error "Cannot start a screensaver while the minibuffer is active"))
    (unless (or (null seed) (integerp seed))
      (etaf-screensaver--fail "Seed must be an integer or nil"))
    (etaf-screensaver--validate-options)
    (let* ((items (etaf-screensaver--compile-playlist (or playlist etaf-screensaver-playlist)))
           (order etaf-screensaver-order)
           (resumable (and (null playlist) (null seed)))
           (resume (and resumable
                        (equal (plist-get etaf-screensaver--resume :items) items)
                        (eq (plist-get etaf-screensaver--resume :order) order)
                        etaf-screensaver--resume))
           (active-seed (or (and resume (plist-get resume :seed))
                            seed (random most-positive-fixnum)))
           (rng (cl-make-random-state (if resume (plist-get resume :random-state) active-seed)))
           (queue (if resume
                      (copy-sequence (plist-get resume :queue))
                    (etaf-screensaver--playlist-round items order rng)))
           (item (pop queue))
           (frame (selected-frame))
           (configuration (current-window-configuration frame))
           (origin-buffer (current-buffer))
           (buffer (generate-new-buffer " *ETAF Screensaver*"))
           session owner)
      (etaf-screensaver--begin-playback-gc)
      (condition-case problem
          (progn
            (setq session (etaf-screensaver--session-create
                           item (+ active-seed (if resume (plist-get resume :index) 0))
                           (etaf-screensaver--columns (selected-window))
                           (max 1 (window-body-height)) buffer)
                  owner (etaf-screensaver--presentation-new
                         :session session :frame frame :configuration configuration
                         :focus (frame-focus-state frame) :origin-buffer origin-buffer
                         :items items :order order :resumable resumable
                         :queue queue :random-state rng :seed active-seed
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
              (setq-local mode-line-format nil header-line-format nil
                          tab-line-format nil display-line-numbers nil
                          show-trailing-whitespace nil indicate-empty-lines nil))
            (etaf-screensaver--session-resize
             session (etaf-screensaver--columns (selected-window))
             (max 1 (window-body-height)))
            (etaf-app-open
             (buffer-name buffer)
             (etaf-view (etaf-screensaver--view :session session))
             :state session
             :background (etaf-screensaver--presentation-canvas owner)
             :cursor nil
             :mode-line nil
             :display nil
             :on-close (lambda ()
                         (when (eq owner etaf-screensaver--active)
                           (etaf-screensaver-stop))))
            (setf (etaf-screensaver--session-runtime session)
                  (etaf-runtime-for-buffer buffer))
            (etaf-screensaver--session-render session)
            (etaf-screensaver--session-publish session)
            (message nil)
            (etaf-screensaver--sync-canvas-background owner)
            (let ((map (make-sparse-keymap))
                  (wake (lambda () (interactive) (etaf-screensaver--wake))))
              (define-key map [t] wake)
              (define-key map [mouse-movement] wake)
              (setf (etaf-screensaver--presentation-exit-map owner)
                    (set-transient-map map (lambda () (eq owner etaf-screensaver--active)))))
            (setq track-mouse t)
            (add-hook 'pre-command-hook #'etaf-screensaver--wake-before-command)
            (add-hook 'window-configuration-change-hook #'etaf-screensaver--window-changed)
            (add-hook 'delete-frame-functions #'etaf-screensaver--frame-deleted)
            (add-function :after after-focus-change-function #'etaf-screensaver--focus-changed)
            (let ((now (float-time)))
              (setf (etaf-screensaver--presentation-last-time owner) now
                    (etaf-screensaver--presentation-deadline owner)
                    (+ now (plist-get item :duration))))
            (etaf-screensaver--arm-frame owner)
            buffer)
        ((error quit)
         (if (and owner (eq owner etaf-screensaver--active))
             (etaf-screensaver-stop)
           (etaf-screensaver--end-playback-gc)
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (signal (car problem) (cdr problem)))))))

(defun etaf-screensaver-preview (scene)
  "Interactively pick and preview SCENE without altering playlist state."
  (interactive (list (etaf-screensaver--read-scene "Preview screensaver: ")))
  (etaf-screensaver-open (etaf-screensaver--resolve-scene scene)))

(defun etaf-screensaver-stop ()
  "Dismiss the active screensaver, restore windows and release all resources.
Idempotent and safe to call repeatedly."
  (interactive)
  (when-let* ((owner etaf-screensaver--active))
    (when (etaf-screensaver--presentation-resumable owner)
      (setq etaf-screensaver--resume
            (list :items (copy-tree (etaf-screensaver--presentation-items owner))
                  :order (etaf-screensaver--presentation-order owner)
                  :queue (cons (etaf-screensaver--session-item
                                (etaf-screensaver--presentation-session owner))
                               (etaf-screensaver--presentation-queue owner))
                  :random-state (cl-make-random-state
                                 (etaf-screensaver--presentation-random-state owner))
                  :index (etaf-screensaver--presentation-index owner)
                  :seed (etaf-screensaver--presentation-seed owner))))
    ;; Clear ownership first so unmount or kill hooks cannot reenter.
    (setq etaf-screensaver--active nil)
    (etaf-screensaver--clear-echo owner)
    (when (timerp (etaf-screensaver--presentation-timer owner))
      (cancel-timer (etaf-screensaver--presentation-timer owner)))
    (setf (etaf-screensaver--presentation-timer owner) nil)
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
          (when (and runtime (etaf-runtime-mounted-p runtime))
            (etaf-unmount runtime))
        (setf (etaf-screensaver--session-runtime session) nil)
        (when (frame-live-p frame)
          (with-selected-frame frame
            (when (etaf-screensaver--presentation-frame-parameters owner)
              (modify-frame-parameters
               frame (etaf-screensaver--presentation-frame-parameters owner)))
            (set-window-configuration
             (etaf-screensaver--presentation-configuration owner))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when restore-current
          (set-buffer (if (buffer-live-p (etaf-screensaver--presentation-origin-buffer owner))
                          (etaf-screensaver--presentation-origin-buffer owner)
                        (window-buffer (selected-window)))))
        (etaf-screensaver--arm-idle)
        (etaf-screensaver--end-playback-gc))))
  nil)

(defun etaf-screensaver-status ()
  "Return a snapshot plist of automatic mode and the active presentation."
  (let ((owner etaf-screensaver--active))
    (append (list :active (and owner t)
                  :automatic (and etaf-screensaver-mode t))
            (when owner
              (let ((session (etaf-screensaver--presentation-session owner)))
                (list :scene (etaf-screensaver--scene-id
                              (etaf-screensaver--session-scene session))
                      :buffer (buffer-name (etaf-screensaver--session-buffer session))
                      :index (etaf-screensaver--presentation-index owner)
                      :seed (etaf-screensaver--session-seed session)
                      :ticks (etaf-screensaver--session-ticks session)
                      :elapsed (etaf-screensaver--session-elapsed session)
                      :columns (etaf-screensaver--session-window-columns session)
                      :rows (etaf-screensaver--session-window-rows session)
                      :frame-rate (plist-get (etaf-screensaver--session-item session) :frame-rate)
                      :duration (plist-get (etaf-screensaver--session-item session) :duration)
                      :frame (plist-get (etaf-screensaver--session-item session) :frame)
                      :transition-progress
                      (when (etaf-screensaver--session-previous-rows session)
                        (/ (etaf-screensaver--session-elapsed session)
                           (etaf-screensaver--session-transition-duration session)))
                      :params (copy-tree (etaf-screensaver--session-params session))
                      :up-next (mapcar (lambda (item) (plist-get item :scene))
                                       (etaf-screensaver--presentation-queue owner))))))))

(define-minor-mode etaf-screensaver-mode
  "Toggle automatic, input-dismissed screensavers after Emacs is idle.
Disabling also dismisses an active presentation and releases the idle timer."
  :global t
  :group 'etaf-screensaver
  (etaf-screensaver--cancel-idle)
  (remove-hook 'post-command-hook #'etaf-screensaver--arm-idle)
  (if (not etaf-screensaver-mode)
      (etaf-screensaver-stop)
    (unless (and (numberp etaf-screensaver-idle-delay)
                 (> etaf-screensaver-idle-delay 0))
      (setq etaf-screensaver-mode nil)
      (etaf-screensaver--fail "Idle delay must be a positive number"))
    (add-hook 'post-command-hook #'etaf-screensaver--arm-idle)
    (etaf-screensaver--arm-idle)))

(provide 'etaf-screensaver-app)
;;; etaf-screensaver-app.el ends here
