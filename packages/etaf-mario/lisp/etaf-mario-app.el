;;; -*- lexical-binding: t; -*-
;;; etaf-mario-app.el --- The live game loop, input and lifetime

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The application advances its world on a fixed clock and publishes two
;; kinds of changed content through ETAF's retained Host boundary: canvas rows
;; and the four HUD counters.  Nothing here waits for the renderer; a slow
;; frame simply delays the next timer callback, and the simulation catches up
;; in fixed steps.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-mario-session)
(require 'etaf-mario-render)
(require 'etaf-mario-views)

(defgroup etaf-mario nil
  "Super Mario for ETAF."
  :group 'games)

(defcustom etaf-mario-buffer-name "*超级马里奥*"
  "Buffer name of the running game."
  :type 'string :group 'etaf-mario)

(defcustom etaf-mario-appearance 'auto
  "Initial appearance of new games: auto, light or dark."
  :type '(choice (const auto) (const light) (const dark)) :group 'etaf-mario)

(defcustom etaf-mario-frame-rate 30
  "Canvas refresh rate: 30 or 60 frames per second."
  :type '(choice (const 30) (const 60)) :group 'etaf-mario)

(defcustom etaf-mario-jump-feel 'normal
  "Jump height: normal, high or low."
  :type '(choice (const normal) (const high) (const low)) :group 'etaf-mario)

(defcustom etaf-mario-progress-file
  (expand-file-name "etaf-mario-progress.eld" user-emacs-directory)
  "File remembering the best score and the unlocked levels."
  :type 'file :group 'etaf-mario)

(defconst etaf-mario--row-refs
  (let ((refs (make-vector 64 nil))
        (index 0))
    (while (< index 64)
      (aset refs index (intern (format "etaf-mario-row-%d" index)))
      (setq index (1+ index)))
    refs)
  "Stable Text Host references for canvas rows.")

(defvar etaf-mario--timing-cache nil
  "Cached (HOLD REPEAT) key timings derived from the system repeat rate.")

(defun etaf-mario--key-timing ()
  "Return (HOLD REPEAT) seconds for held-key intent on this system."
  (unless etaf-mario--timing-cache
    (setq etaf-mario--timing-cache
          (or (and (eq system-type 'darwin) (executable-find "defaults")
                   (let ((read (lambda (key)
                                 (with-temp-buffer
                                   (and (eq 0 (call-process "defaults" nil t nil "read" "-g" key))
                                        (let ((value (string-to-number (buffer-string))))
                                          (and (> value 0) (* value 0.015))))))))
                     (let ((initial (funcall read "InitialKeyRepeat"))
                           (interval (funcall read "KeyRepeat")))
                       (and initial interval
                            (list (min 1.0 (max 0.15 (+ initial 0.06)))
                                  (min 0.5 (max 0.06 (+ (* 3 interval) 0.03))))))))
              '(0.30 0.12))))
  etaf-mario--timing-cache)

(defun etaf-mario--jump-scale (feel)
  "Return the jump speed multiplier of FEEL."
  (pcase feel
    ('high 1.12)
    ('low 0.9)
    (_ 1.0)))

;;; Progress

(defun etaf-mario--read-progress ()
  "Return the saved progress plist, or an empty one."
  (if (file-readable-p etaf-mario-progress-file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents etaf-mario-progress-file)
            (let ((value (read (current-buffer))))
              (and (listp value) value)))
        (error nil))
    nil))

(defun etaf-mario--write-progress (session)
  "Write SESSION's best score and unlocked level, ignoring write failures."
  (ignore-errors
    (let ((data (list :best (or (etaf-mario--session-best session) 0)
                      :unlocked (or (plist-get (etaf-mario--session-progress session)
                                                :unlocked)
                                    0))))
      (with-temp-file etaf-mario-progress-file
        (insert (prin1-to-string data))
        (insert "\n")))))

(defun etaf-mario--record-best (session)
  "Remember SESSION's score when it beats the stored best."
  (let ((score (etaf-mario-world-score (etaf-mario--session-world session))))
    (when (> score (or (etaf-mario--session-best session) 0))
      (setf (etaf-mario--session-best session) score)
      (plist-put (etaf-mario--session-progress session) :best score))))

(defun etaf-mario--record-unlock (session level)
  "Unlock up to campaign LEVEL in SESSION's progress."
  (let ((progress (etaf-mario--session-progress session)))
    (when (> level (or (plist-get progress :unlocked) 0))
      (plist-put progress :unlocked
                 (min level (1- (length etaf-mario-levels)))))))

;;; Display

(defun etaf-mario--level-label-at (index)
  "Return the readable world name of campaign INDEX."
  (let* ((definition (nth (mod index (length etaf-mario-levels)) etaf-mario-levels))
         (name (or (plist-get definition :name) "1-1"))
         (world (format "%d-%d" (1+ (/ index 4)) (1+ (mod index 4)))))
    (if (string-match "\\`[0-9]+-[0-9]+" name)
        (substring name 0 (match-end 0))
      world)))

(defun etaf-mario--session-level-label (session)
  "Return the readable world name of SESSION's level."
  (etaf-mario--level-label-at
   (etaf-mario-world-index (etaf-mario--session-world session))))

(defun etaf-mario--session-unlocked-label (session)
  "Return the readable name of SESSION's highest unlocked stage."
  (etaf-mario--level-label-at
   (or (plist-get (etaf-mario--session-progress session) :unlocked) 0)))

(defun etaf-mario--sync-label-refs (session)
  "Publish SESSION's level and best labels into their reactive cells.
The HUD and footer read these cells instead of recomputing a label in a
static text node, so a new stage or a new best score repaints the label."
  (let ((label (etaf-mario--session-level-label session))
        (best (or (etaf-mario--session-best session) 0)))
    (unless (equal (etaf-value (etaf-mario--session-level-ref session)) label)
      (setf (etaf-value (etaf-mario--session-level-ref session)) label))
    (unless (equal (etaf-value (etaf-mario--session-best-ref session)) best)
      (setf (etaf-value (etaf-mario--session-best-ref session)) best)))
  session)

(defun etaf-mario--stage-size (session window)
  "Return (COLS . ROWS) of SESSION's character stage for WINDOW.
The stage height is fixed by the level's block grid, so a tall window
letterboxes the game instead of stretching empty sky between the HUD and the
ground.  A short window clips the top rows and keeps the ground visible.
COLS leaves two character cells of slack: a row that reaches the canvas box
edge can lose its last cell to layout rounding and paint that cell with the
row's background instead."
  (let* ((live (and window (window-live-p window)))
         (cells (max 1 (if live
                           (floor (/ (window-body-width window t)
                                     (float (frame-char-width (window-frame window)))))
                         (or (etaf-viewport) 100))))
         (width (max 1 (- cells 2)))
         (height (if live (window-body-height window) 20))
         (stage (* etaf-mario-render--cell-height
                   (plist-get (etaf-mario-world-level
                               (etaf-mario--session-world session))
                              :height))))
    (cons (max 40 (min 200 width))
          (max 10 (min stage (- height 2))))))

(defun etaf-mario--sync-size (session)
  "Refit SESSION only when its window has actually changed size.
The stage size is derived from the raw window size, never from the clamped
canvas, so a window that only differs inside a clamp keeps its frame."
  (when-let* ((buffer (etaf-mario--session-buffer session))
              (window (get-buffer-window buffer)))
    (unless (and (= (window-body-width window)
                    (or (etaf-mario--session-win-cols session) 0))
                 (= (window-body-height window)
                    (or (etaf-mario--session-win-rows session) 0)))
      (etaf-mario--fit session window)
      t)))

(defun etaf-mario--fit (session window)
  "Fit SESSION's character stage to WINDOW.
The stage keeps a fixed character grid: a wider window shows more of the
level, never larger characters."
  (let* ((size (etaf-mario--stage-size session window))
         (cols (car size))
         (rows (cdr size))
         (window-cols (if (and window (window-live-p window))
                          (window-body-width window)
                        0))
         (window-rows (if (and window (window-live-p window))
                          (window-body-height window)
                        0)))
    (setf (etaf-mario--session-cols session) cols
          (etaf-mario--session-rows session) rows
          (etaf-mario--session-win-cols session) window-cols
          (etaf-mario--session-win-rows session) window-rows)
    (when (etaf-mario--session-size-ref session)
      ;; The canvas box is as wide as the window and two cells wider than the
      ;; composed frame, so no row reaches its edge.
      (setf (etaf-value (etaf-mario--session-size-ref session))
            (cons (+ cols 2) rows)))
    (etaf-mario--rebuild-frame session)))

(defun etaf-mario--rows-to-frame (texts)
  "Return TEXT rows as (REF . TEXT) cells.
The canvas box keeps two cells of slack beyond a row, so a full row cannot
lose its last cell to layout rounding."
  (let ((result nil)
        (index 0))
    (dolist (text texts)
      (push (cons (aref etaf-mario--row-refs (min index (1- (length etaf-mario--row-refs))))
                  text)
            result)
      (setq index (1+ index)))
    (nreverse result)))

(defun etaf-mario--rebuild-frame (session)
  "Compose SESSION's canvas again and ask the View to render it."
  (let* ((world (etaf-mario--session-world session))
         (cols (or (etaf-mario--session-cols session) 80))
         (rows (or (etaf-mario--session-rows session) 20))
         (result (etaf-mario-render-frame world cols rows)))
    (setf (etaf-mario--session-frame session) (etaf-mario--rows-to-frame (cdr result)))
    (when (etaf-mario--session-revision session)
      (setf (etaf-value (etaf-mario--session-revision session))
            (1+ (etaf-value (etaf-mario--session-revision session))))))
  (etaf-mario--sync-label-refs session))

(defun etaf-mario--hud-values (session)
  "Return SESSION's HUD (REF . TEXT) values."
  (let ((world (etaf-mario--session-world session)))
    (list (cons 'etaf-mario-hud-score (format "%06d" (etaf-mario-world-score world)))
          (cons 'etaf-mario-hud-coins (format "×%02d" (etaf-mario-world-coins world)))
          (cons 'etaf-mario-hud-time (format "%03d" (etaf-mario-world-time world)))
          (cons 'etaf-mario-hud-lives (format "×%d" (etaf-mario-world-lives world))))))

(defun etaf-mario--publish (session)
  "Publish SESSION's changed canvas rows and HUD counters."
  (etaf-mario--sync-size session)
  (etaf-mario--sync-label-refs session)
  (let ((runtime (etaf-mario--session-runtime session)))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (let* ((world (etaf-mario--session-world session))
             (cols (or (etaf-mario--session-cols session) 80))
             (rows (or (etaf-mario--session-rows session) 20))
             (texts (cdr (etaf-mario-render-frame world cols rows)))
             (old (etaf-mario--session-frame session))
             (updates nil))
        (if (or (null old) (/= (length texts) (length old)))
            (etaf-mario--rebuild-frame session)
          (cl-loop for text in texts
                   for cell in old
                   unless (equal text (cdr cell))
                   do (push (cons (car cell) text) updates))
          (setf (etaf-mario--session-frame session)
                (etaf-mario--rows-to-frame texts)))
        (dolist (pair (etaf-mario--hud-values session))
          (let ((previous (assq (car pair) (etaf-mario--session-hud session))))
            (unless (equal (cdr previous) (cdr pair))
              (push pair updates))))
        (when updates
          (etaf-runtime-update-host-contents runtime (nreverse updates)))
        (setf (etaf-mario--session-hud session)
              (etaf-mario--hud-values session))))))

;;; Input

(defun etaf-mario--deadline (session key)
  "Return SESSION's hold deadline for KEY."
  (or (plist-get (etaf-mario--session-held session) key) 0.0))

(defun etaf-mario--hold (session key &optional seconds)
  "Extend SESSION's KEY intent for SECONDS."
  (let* ((timing (etaf-mario--key-timing))
         (window (or seconds (if (> (etaf-mario--deadline session key) (float-time))
                                 (cadr timing)
                               (car timing)))))
    (setf (etaf-mario--session-held session)
          (plist-put (etaf-mario--session-held session) key
                     (+ (float-time) window)))))

(defun etaf-mario--held-p (session key)
  "Return non-nil when SESSION's KEY intent is still active."
  (> (etaf-mario--deadline session key) (float-time)))

(defun etaf-mario--input (session)
  "Return SESSION's simulation input plist for one step."
  (prog1 (list :left (etaf-mario--held-p session :left)
               :right (etaf-mario--held-p session :right)
               :run (etaf-mario--held-p session :run)
               :duck (etaf-mario--held-p session :duck)
               :jump (etaf-mario--session-jump-pressed session)
               :jump-held (> (etaf-mario--deadline session :jump) (float-time))
               :fire (etaf-mario--session-fire-pressed session))
    (setf (etaf-mario--session-jump-pressed session) nil
          (etaf-mario--session-fire-pressed session) nil)))

(defun etaf-mario--direction (session direction)
  "Handle DIRECTION for SESSION and stop focus navigation."
  (pcase direction
    ('left (etaf-mario--hold session :left))
    ('right (etaf-mario--hold session :right))
    ('up (etaf-mario--press-jump session))
    ('down (etaf-mario--hold session :duck)))
  'handled)

(defun etaf-mario--press-jump (session)
  "Register a jump press for SESSION."
  (when (eq (etaf-mario-session-phase session) 'playing)
    (setf (etaf-mario--session-jump-pressed session) t)
    (etaf-mario--hold session :jump)))

(defun etaf-mario--press-run (session)
  "Register a run and fire press for SESSION."
  (when (eq (etaf-mario-session-phase session) 'playing)
    (etaf-mario--hold session :run)
    (setf (etaf-mario--session-fire-pressed session) t)))

;;; Loop

(defun etaf-mario--set-phase (session phase)
  "Set SESSION's display PHASE."
  (setf (etaf-value (etaf-mario--session-phase-ref session)) phase))

(defun etaf-mario--stop-timer (session)
  "Cancel SESSION's pending frame timer."
  (when (timerp (etaf-mario--session-timer session))
    (cancel-timer (etaf-mario--session-timer session)))
  (setf (etaf-mario--session-timer session) nil))

(defun etaf-mario--frame-interval (session)
  "Return SESSION's frame interval in seconds."
  (/ 1.0 (float (or (plist-get (etaf-mario--session-settings session) :frame-rate)
                    etaf-mario-frame-rate))))

(defun etaf-mario--schedule (session)
  "Arm SESSION's next frame on a slot clock.
Anchoring the next slot to the previous one keeps a steady cadence when one
frame is slow, and a frame that misses its slot is skipped instead of queued."
  (when (eq (etaf-mario-session-phase session) 'playing)
    (let* ((interval (etaf-mario--frame-interval session))
           (now (float-time))
           (due (or (etaf-mario--session-next-due session) (+ now interval))))
      (while (< due now)
        (setq due (+ due interval)))
      (setf (etaf-mario--session-next-due session) due
            (etaf-mario--session-timer session)
            (run-at-time (max 0.001 (- due now)) nil #'etaf-mario--tick session)))))

(defun etaf-mario--tick (session)
  "Advance SESSION by the time elapsed since the last frame."
  (setf (etaf-mario--session-timer session) nil)
  (when (eq (etaf-mario-session-phase session) 'playing)
    (setf (etaf-mario--session-ticks session)
          (1+ (etaf-mario--session-ticks session)))
    (condition-case problem
        (progn
          (when (etaf-mario--pause-on-leave session)
            (etaf-mario--pause session))
          (when (eq (etaf-mario-session-phase session) 'playing)
            (let* ((now (float-time))
                   (elapsed (min 0.1 (max 0.0 (- now (or (etaf-mario--session-last-tick session) now)))))
                   (step etaf-mario-model-step)
                   (steps 0))
              (setf (etaf-mario--session-last-tick session) now)
              (cl-incf (etaf-mario--session-accumulator session) elapsed)
              (while (and (>= (etaf-mario--session-accumulator session) step)
                          (< steps 5))
                (etaf-mario-world-step (etaf-mario--session-world session)
                                       (etaf-mario--input session))
                (cl-decf (etaf-mario--session-accumulator session) step)
                (setq steps (1+ steps)))
              (etaf-mario--session-sync session)
              (etaf-mario--session-expire-message session)
              (etaf-mario--publish session)
              (etaf-mario--handle-status session))
            (etaf-mario--schedule session)))
      (error
       (etaf-mario--stop-timer session)
       (message "超级马里奥：%s" (error-message-string problem))))))

(defun etaf-mario--pause-on-leave (session)
  "Return non-nil when SESSION's buffer no longer owns the selected window."
  (let ((buffer (etaf-mario--session-buffer session)))
    (and buffer
         (not (eq (window-buffer (selected-window)) buffer))
         (null (get-buffer-window buffer)))))

(defun etaf-mario--handle-status (session)
  "React to SESSION's world status."
  (let ((world (etaf-mario--session-world session)))
    (pcase (etaf-mario-world-status world)
      ('cleared
       (when (<= (etaf-mario--world-status-timer world) 0.0)
         (etaf-mario--record-best session)
         (etaf-mario--record-unlock session (1+ (etaf-mario-world-index (etaf-mario--session-world session))))
         (etaf-mario--write-progress session)
         (etaf-mario--stop-timer session)
         (etaf-mario--sync-label-refs session)
         (etaf-mario--set-phase session
                                (if (>= (etaf-mario-world-index (etaf-mario--session-world session))
                                        (1- (length etaf-mario-levels)))
                                    'victory
                                  'cleared))))
      ('gameover
       (etaf-mario--record-best session)
       (etaf-mario--write-progress session)
       (etaf-mario--stop-timer session)
       (etaf-mario--sync-label-refs session)
       (etaf-mario--set-phase session 'gameover))
      ('dying
       (etaf-mario--session-say session "小心！" 1.0)))))

;;; Commands

(defun etaf-mario--start-game (session)
  "Begin playing SESSION from its current level."
  (setf (etaf-mario--session-accumulator session) 0.0
        (etaf-mario--session-last-tick session) (float-time)
        (etaf-mario--session-next-due session)
        (+ (float-time) (etaf-mario--frame-interval session)))
  (etaf-mario--set-phase session 'playing)
  (etaf-mario--schedule session))

(defun etaf-mario--resume (session)
  "Resume SESSION after a pause."
  (etaf-mario--start-game session))

(defun etaf-mario--pause (session)
  "Pause SESSION into its pause dialog."
  (etaf-mario--stop-timer session)
  (when (eq (etaf-mario-session-phase session) 'playing)
    (etaf-mario--set-phase session 'paused)))

(defun etaf-mario--pause-or-resume (session)
  "Toggle SESSION between playing and paused."
  (pcase (etaf-mario-session-phase session)
    ('playing (etaf-mario--pause session))
    ('paused (etaf-mario--resume session))))

(defun etaf-mario--restart (session)
  "Restart SESSION's current level."
  (let* ((index (etaf-mario-world-index (etaf-mario--session-world session)))
         (world (etaf-mario--session-world session))
         (fresh (etaf-mario-world-create
                 index
                 (list :score (etaf-mario-world-score world)
                       :coins (etaf-mario-world-coins world)
                       :lives (max 3 (etaf-mario-world-lives world))
                       :jump (etaf-mario--jump-scale
                              (plist-get (etaf-mario--session-settings session) :jump-feel))))))
    (setf (etaf-mario--session-world session) fresh)
    (etaf-mario--set-phase session 'playing)
    (etaf-mario--rebuild-frame session)
    (etaf-mario--start-game session)))

(defun etaf-mario--next-level (session)
  "Advance SESSION to the next level, or return to the title."
  (let* ((world (etaf-mario--session-world session))
         (next (1+ (etaf-mario-world-index (etaf-mario--session-world session)))))
    (if (>= next (length etaf-mario-levels))
        (etaf-mario--to-title session)
      (let ((fresh (etaf-mario-world-create
                    next
                    (list :score (etaf-mario-world-score world)
                          :coins (etaf-mario-world-coins world)
                          :lives (etaf-mario-world-lives world)
                          :big nil
                          :jump (etaf-mario--jump-scale
                                 (plist-get (etaf-mario--session-settings session) :jump-feel))))))
        (setf (etaf-mario--session-world session) fresh)
        (etaf-mario--set-phase session 'playing)
        (etaf-mario--rebuild-frame session)
        (etaf-mario--start-game session)))))

(defun etaf-mario--to-title (session)
  "Stop SESSION and show its title dialog."
  (etaf-mario--stop-timer session)
  (etaf-mario--set-phase session 'title)
  (etaf-mario--record-best session))

(defun etaf-mario--choose-level (session level)
  "Start SESSION at campaign LEVEL."
  (let ((fresh (etaf-mario-world-create
                level
                (list :score 0 :coins 0 :lives 3 :big nil
                      :jump (etaf-mario--jump-scale
                             (plist-get (etaf-mario--session-settings session) :jump-feel))))))
    (setf (etaf-mario--session-world session) fresh)
    (etaf-mario--rebuild-frame session)
    (etaf-mario--start-game session)))

(defun etaf-mario--select-dialog (session &optional open)
  "Open SESSION's level select dialog when OPEN, else keep it."
  (when open
    (etaf-mario--stop-timer session)
    (setf (etaf-mario--session-menu session) (etaf-mario-session-phase session))
    (etaf-mario--set-phase session 'select)))

(defun etaf-mario--close-select (session)
  "Close SESSION's level select dialog."
  (let ((previous (or (etaf-mario--session-menu session) 'title)))
    (etaf-mario--set-phase session previous)
    (when (eq previous 'playing)
      (etaf-mario--start-game session))))

(defun etaf-mario--settings (session)
  "Open SESSION's settings dialog."
  (etaf-mario--stop-timer session)
  (setf (etaf-mario--session-menu session) (etaf-mario-session-phase session))
  (etaf-mario--set-phase session 'settings))

(defun etaf-mario--close-settings (session)
  "Close SESSION's settings dialog."
  (let ((previous (or (etaf-mario--session-menu session) 'title)))
    (etaf-mario--set-phase session previous)
    (when (eq previous 'playing)
      (etaf-mario--start-game session))))

(defun etaf-mario--toggle-settings (session)
  "Open SESSION's settings dialog, or close it when it is already open."
  (if (eq (etaf-mario-session-phase session) 'settings)
      (etaf-mario--close-settings session)
    (etaf-mario--settings session)))

(defun etaf-mario--set-setting (session key value)
  "Set SESSION's setting KEY to VALUE and apply it."
  (plist-put (etaf-mario--session-settings session) key value)
  (pcase key
    (:frame-rate (setq etaf-mario-frame-rate value))
    (:jump-feel
     (setq etaf-mario-jump-feel value)
     (let ((world (etaf-mario--session-world session)))
       (setf (etaf-mario--world-jump-scale world)
             (etaf-mario--jump-scale value))))))

(defun etaf-mario--set-appearance (session value)
  "Set SESSION's appearance to VALUE."
  (setf (etaf-value (etaf-mario--session-appearance-ref session)) value))

(defun etaf-mario--toggle-theme (session)
  "Switch SESSION between light and dark appearance."
  (etaf-mario--set-appearance
   session
   (if (eq (etaf-value (etaf-mario--session-appearance-ref session)) 'dark)
       'light
     'dark)))

;;; Lifetime

(defun etaf-mario--shutdown (session)
  "Release SESSION's timer and save its progress."
  (etaf-mario--stop-timer session)
  (etaf-mario--record-best session)
  (etaf-mario--write-progress session)
  (setf (etaf-mario--session-runtime session) nil))

(defun etaf-mario-open (&optional level)
  "Open Super Mario and return its buffer.
LEVEL is an optional zero-based campaign index."
  (interactive)
  (let ((existing (etaf-app-buffer etaf-mario-buffer-name)))
    (if (and existing (etaf-app-state existing))
        (pop-to-buffer existing)
      (let* ((progress (or (etaf-mario--read-progress) (list :best 0 :unlocked 0)))
             (session (etaf-mario--session-make
                       (or level 0)
                       etaf-mario-appearance
                       (list :frame-rate etaf-mario-frame-rate
                             :jump-feel etaf-mario-jump-feel)
                       progress))
             (buffer (etaf-app-open
                      etaf-mario-buffer-name
                      (etaf-mario--view session)
                      :state session
                      :cursor nil
                      :mode-line nil
                      :on-fit (lambda (window) (etaf-mario--fit session window))
                      :on-close (lambda () (etaf-mario--shutdown session)))))
        (setf (etaf-mario--session-buffer session) buffer
              (etaf-mario--session-runtime session) (etaf-runtime-for-buffer buffer)
              (etaf-mario--session-accumulator session) 0.0
              (etaf-mario--session-last-tick session) (float-time))
        (when-let* ((runtime (etaf-mario--session-runtime session)))
          (etaf-runtime-flush runtime))
        buffer))))

(defun etaf-mario-doctor ()
  "Return a list of problems with the campaign and its artwork.
An empty list means every bundled level parses, every floating block leaves
two empty rows above the surface below it, and every sprite character has a
colour in every theme.  Each problem is a plist whose `:kind' names the
fault: `level' carries `:index' and `:message', `shelf' carries `:index',
`:column' and `:row', and `sprite' carries `:sprite' and `:character'."
  (let ((problems nil))
    (dotimes (index (length etaf-mario-levels))
      (let ((level (condition-case problem
                       (etaf-mario-level-parse (nth index etaf-mario-levels))
                     (error
                      (push (list :kind 'level :index index
                                  :message (error-message-string problem))
                            problems)
                      nil))))
        (when level
          (dolist (shelf (etaf-mario-level-clearance-problems level))
            (push (list :kind 'shelf :index index
                        :column (nth 0 shelf) :row (nth 1 shelf))
                  problems)))))
    (dolist (miss (etaf-mario-render-check-sprites))
      (push (list :kind 'sprite :sprite (nth 0 miss) :character (nth 1 miss))
            problems))
    (nreverse problems)))

(defun etaf-mario-close (&optional buffer-or-name)
  "Close the game in BUFFER-OR-NAME, by default the current buffer."
  (interactive)
  (let ((buffer (or buffer-or-name (current-buffer))))
    (when (etaf-app-state buffer)
      (etaf-app-close buffer))))

(defun etaf-mario-create ()
  "Return a session for LEVEL zero without displaying it."
  (etaf-mario--session-make 0 etaf-mario-appearance
                            (list :frame-rate etaf-mario-frame-rate
                                  :jump-feel etaf-mario-jump-feel)
                            (or (etaf-mario--read-progress) (list :best 0 :unlocked 0))))

(provide 'etaf-mario-app)
;;; etaf-mario-app.el ends here
