;;; etaf-animation.el --- Time-driven reactive values -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An animation is an ordinary reactive ref whose value moves over time.  The
;; application keeps writing its target as usual; `etaf-transition' returns
;; the displayed ref and restarts the interpolation from the value currently
;; on screen, so interruption never jumps.  `etaf-animation-frames' cycles a
;; fixed list for spinners, marquees and typewriter effects.
;;
;; One shared clock samples every running animation and writes the samples
;; through the regular ref path, so Runtime bindings, Ebox damage and buffer
;; rewrites stay exactly the normal update flow.  Animations created during
;; Component setup belong to its Scope and stop when it is disposed; other
;; callers stop them with `etaf-animation-stop'.  The clock exists only while
;; something runs.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'etaf-reactive)

(define-error 'etaf-animation-error "Invalid ETAF animation operation")

(defvar etaf-animation-frame-rate 30
  "Display clock rate in frames per second for running animations.
A positive upper bound; the clock waits at least one frame period after each
publication.  It never queues catch-up frames or suppresses animation merely
because keyboard input is pending.  Each sample publishes one reactive batch.")

(defvar etaf-animation-enabled t
  "Whether animations interpolate over time.
When nil, new transitions apply their target immediately, running transitions
snap to their target and running frame sequences hold their current value.
Setting this back to t does not restart stopped runs.")

(defvar etaf-animation-paused nil
  "Whether the shared clock stops advancing.
While paused, running animations hold their displayed value and keep their
progress; setting this back to nil resumes exactly where they stopped.  Unlike
`etaf-animation-enabled', pausing does not resolve or stop a run.")

(defvar etaf-animation-speed 1.0
  "Animation speed multiplier.
A positive number scaling how fast the shared clock advances, so 2 runs every
transition and frame sequence twice as fast and 0.5 half as fast.  The change
applies from the next tick without moving a run's progress.")

(defvar etaf-animation-interpolators nil
  "Ordered ((PREDICATE . FUNCTION) ...) consulted before built-in conversion.
PREDICATE takes FROM and TO and decides whether FUNCTION applies; FUNCTION
takes FROM, TO and PROGRESS and returns the value at that progress.  The first
matching pair wins.  Built-in conversion handles numbers, color strings and
equal-length lists or vectors of convertible values.")

(defun etaf-animation--bezier-axis (first second progress)
  "Return coordinate of cubic bezier control point FIRST, SECOND at PROGRESS."
  (let ((rest (- 1.0 progress)))
    (+ (* 3.0 rest rest progress first)
       (* 3.0 rest progress progress second)
       (* progress progress progress))))

(defun etaf-animation--cubic-bezier (x1 y1 x2 y2)
  "Return the easing function of CSS cubic-bezier(X1, Y1, X2, Y2)."
  (lambda (progress)
    (if (or (<= progress 0) (>= progress 1))
        progress
      (let ((low 0.0) (high 1.0) (middle 0.5))
        (dotimes (_ 24)
          (setq middle (/ (+ low high) 2.0))
          (if (< (etaf-animation--bezier-axis x1 x2 middle) progress)
              (setq low middle)
            (setq high middle)))
        (etaf-animation--bezier-axis y1 y2 middle)))))

(defvar etaf-animation-easings
  (list (cons 'linear #'identity)
        (cons 'ease (etaf-animation--cubic-bezier 0.25 0.1 0.25 1.0))
        (cons 'ease-in (etaf-animation--cubic-bezier 0.42 0.0 1.0 1.0))
        (cons 'ease-out (etaf-animation--cubic-bezier 0.0 0.0 0.58 1.0))
        (cons 'ease-in-out (etaf-animation--cubic-bezier 0.42 0.0 0.58 1.0)))
  "Alist of (NAME . FUNCTION) easing curves.
FUNCTION maps progress 0..1 to eased progress 0..1.  `etaf-transition'
accepts a name from this alist or any function directly.")

(defun etaf-animation--easing (easing)
  "Return the easing function for EASING, a symbol or function."
  (cond
   ((functionp easing) easing)
   ((and (symbolp easing) (assq easing etaf-animation-easings))
    (cdr (assq easing etaf-animation-easings)))
   (t (signal 'etaf-animation-error (list "Unknown easing" easing)))))

(defun etaf-animation--color-p (value)
  "Return non-nil when VALUE is a string Emacs accepts as a color."
  (and (stringp value) (color-name-to-rgb value) t))

(defun etaf-animation--registered-interpolation (from to progress)
  "Return (t . VALUE) from the first registered interpolator, or nil."
  (let (found result)
    (cl-loop for (predicate . function) in etaf-animation-interpolators
             unless found
             do (when (funcall predicate from to)
                  (setq found t
                        result (funcall function from to progress))))
    (when found (cons t result))))

(defun etaf-animation--interpolate (from to progress)
  "Convert FROM toward TO at PROGRESS without the endpoint shortcut."
  (let ((registered (etaf-animation--registered-interpolation from to progress)))
    (if registered
        (cdr registered)
      (cond
       ((and (numberp from) (numberp to)) (+ from (* (- to from) progress)))
       ((and (etaf-animation--color-p from) (etaf-animation--color-p to))
        (pcase-let* ((`(,r1 ,g1 ,b1) (color-name-to-rgb from))
                     (`(,r2 ,g2 ,b2) (color-name-to-rgb to)))
          (color-rgb-to-hex (+ r1 (* (- r2 r1) progress))
                            (+ g1 (* (- g2 g1) progress))
                            (+ b1 (* (- b2 b1) progress)))))
       ((and (listp from) (listp to) (= (length from) (length to)))
        (cl-mapcar (lambda (a b) (etaf-animation--interpolate a b progress))
                   from to))
       ((and (vectorp from) (vectorp to) (= (length from) (length to)))
        (cl-map 'vector (lambda (a b) (etaf-animation--interpolate a b progress))
                from to))
       ((equal from to) from)
       (t from)))))

(defun etaf-animation-interpolate (from to progress)
  "Return the value at PROGRESS (0 to 1) between FROM and TO.
PROGRESS 1 returns TO unchanged.  Numbers convert arithmetically, color
strings blend in RGB, and equal-length lists or vectors convert element-wise
while equal non-numbers stand still.  Extend the conversion by adding
\(PREDICATE . FUNCTION) entries to `etaf-animation-interpolators'."
  (if (>= progress 1)
      to
    (etaf-animation--interpolate from to progress)))

(cl-defstruct (etaf-animation (:constructor etaf--animation-create)
                              (:copier nil))
  "One running or resting animation."
  shown target watch-stop kind from to start duration easing on-complete
  sequence interval loop (active nil))

(defvar etaf-animation--running nil
  "Animations subscribed to the shared clock, most recent first.")

(defvar etaf-animation--timer nil
  "Pending one-shot clock timer, or nil while nothing runs.")

(defvar etaf-animation--ticking nil
  "Non-nil while a sample and its reactive publication are in progress.")

(defvar etaf-animation--clock-time nil
  "Animation time in seconds while the clock runs, or nil while stopped.
It advances by the wall time between ticks times `etaf-animation-speed'.")

(defvar etaf-animation--clock-stamp nil
  "Wall time of the previous clock tick, or nil while stopped.")

(defvar etaf-animation--registry (make-hash-table :test #'eq :weakness 'key)
  "Map of each animated ref to its animation.")

(defun etaf-animation--animated (source)
  "Return the animation behind animated SOURCE."
  (or (gethash source etaf-animation--registry)
      (signal 'etaf-animation-error (list "Not an animated source" source))))

(defun etaf-animation--tick-rate ()
  "Return the clock period in seconds after validating the frame rate."
  (let ((rate etaf-animation-frame-rate))
    (unless (and (numberp rate) (> rate 0))
      (signal 'etaf-animation-error
              (list "etaf-animation-frame-rate must be a positive number" rate)))
    (/ 1.0 rate)))

(defun etaf-animation--time-scale ()
  "Return the validated `etaf-animation-speed' multiplier."
  (let ((scale etaf-animation-speed))
    (unless (and (numberp scale) (> scale 0))
      (signal 'etaf-animation-error
              (list "etaf-animation-speed must be a positive number" scale)))
    scale))

(defun etaf-animation--ensure-clock ()
  "Initialize animation time and schedule at most one future sample."
  (let ((period (etaf-animation--tick-rate)))
    (etaf-animation--time-scale)
    (unless etaf-animation--clock-time
      (setq etaf-animation--clock-stamp (float-time)
            etaf-animation--clock-time etaf-animation--clock-stamp))
    (unless (or etaf-animation--timer etaf-animation--ticking)
      (setq etaf-animation--timer
            (run-at-time period nil #'etaf-animation--tick)))))

(defun etaf-animation--drop-clock ()
  "Stop the shared clock; the next activation restarts it."
  (when etaf-animation--timer
    (cancel-timer etaf-animation--timer))
  (setq etaf-animation--timer nil)
  ;; A completion callback can retarget the last run during publication.
  ;; Keep the same time base until that batch has finished.
  (unless etaf-animation--ticking
    (setq etaf-animation--clock-time nil
          etaf-animation--clock-stamp nil)))

(defun etaf-animation--activate (animation)
  "Subscribe ANIMATION to the shared clock."
  (unless (etaf-animation-active animation)
    (etaf-animation--ensure-clock)
    (setf (etaf-animation-active animation) t)
    (push animation etaf-animation--running)))

(defun etaf-animation--deactivate (animation)
  "Unsubscribe ANIMATION and stop the clock when nothing else runs."
  (when (etaf-animation-active animation)
    (setf (etaf-animation-active animation) nil)
    (setq etaf-animation--running (delq animation etaf-animation--running))
    (unless etaf-animation--running
      (etaf-animation--drop-clock))))

(defun etaf-animation--complete (animation)
  "Announce ANIMATION's completion after the current frame is published."
  (when-let* ((callback (etaf-animation-on-complete animation)))
    (etaf-next-tick callback)))

(defun etaf-animation--stop (animation)
  "Stop ANIMATION, keeping its displayed value, and drop its watcher."
  (etaf-animation--deactivate animation)
  (when-let* ((stop (etaf-animation-watch-stop animation)))
    (setf (etaf-animation-watch-stop animation) nil)
    (funcall stop)))

(defun etaf-animation--sample-transition (animation now)
  "Move ANIMATION's shown value toward its target at NOW."
  (let* ((duration (etaf-animation-duration animation))
         (progress (if (<= duration 0)
                       1.0
                     (min 1.0 (max 0.0 (/ (- now (etaf-animation-start animation))
                                          duration))))))
    (if (>= progress 1)
        (progn
          (etaf-set-value (etaf-animation-shown animation)
                          (etaf-animation-to animation))
          (etaf-animation--deactivate animation)
          (etaf-animation--complete animation))
      (etaf-set-value (etaf-animation-shown animation)
                      (etaf-animation-interpolate
                       (etaf-animation-from animation)
                       (etaf-animation-to animation)
                       (funcall (etaf-animation-easing animation) progress))))))

(defun etaf-animation--sample-frames (animation now)
  "Publish ANIMATION's frame for NOW."
  (let* ((frames (etaf-animation-sequence animation))
         (count (length frames))
         (interval (etaf-animation-interval animation))
         (index (floor (/ (- now (etaf-animation-start animation))
                          (max 0.001 interval)))))
    (if (and (not (etaf-animation-loop animation)) (>= index count))
        (progn
          (etaf-set-value (etaf-animation-shown animation)
                          (elt frames (1- count)))
          (etaf-animation--deactivate animation)
          (etaf-animation--complete animation))
      (etaf-set-value (etaf-animation-shown animation)
                      (elt frames (mod index count))))))

(defun etaf-animation--sample (animation now)
  "Publish ANIMATION's value for the clock time NOW."
  (pcase (etaf-animation-kind animation)
    ('transition (etaf-animation--sample-transition animation now))
    ('frames (etaf-animation--sample-frames animation now))))

(defun etaf-animation--freeze (animation)
  "Stop ANIMATION without time, as when animation is disabled."
  (pcase (etaf-animation-kind animation)
    ('transition
     (etaf-set-value (etaf-animation-shown animation)
                     (etaf-animation-to animation))
     (etaf-animation--complete animation))
    ('frames nil))
  (etaf-animation--deactivate animation))

(defun etaf-animation--publish ()
  "Advance animation time and publish at most one reactive batch."
  (cond
   ((not etaf-animation-enabled)
    (etaf-batch
      (dolist (animation (copy-sequence etaf-animation--running))
        (etaf-animation--freeze animation)))
    (etaf-animation--drop-clock))
   (etaf-animation-paused
    ;; Freezing the animation clock here resumes exactly where the pause
    ;; started; the timer keeps running so a later unpause needs no restart.
    (setq etaf-animation--clock-stamp (float-time)))
   (t
    (let* ((wall (float-time))
           (scale (etaf-animation--time-scale))
           (now (+ etaf-animation--clock-time
                   (* scale (max 0.0 (- wall etaf-animation--clock-stamp)))))
           (failure nil))
      (setq etaf-animation--clock-stamp wall
            etaf-animation--clock-time now)
      (etaf-batch
        (dolist (animation (copy-sequence etaf-animation--running))
          (condition-case error
              (etaf-animation--sample animation now)
            ((error quit)
             (etaf-animation--deactivate animation)
             (unless failure (setq failure error))))))
      (when failure
        (signal (car failure) (cdr failure)))))))

(defun etaf-animation--tick ()
  "Publish one sample, then yield a full period to the Emacs event loop."
  (setq etaf-animation--timer nil)
  (let (failure)
    (let ((etaf-animation--ticking t))
      (condition-case error
          (etaf-animation--publish)
        ((error quit) (setq failure error))))
    (condition-case error
        (if failure
            (progn
              (dolist (animation (copy-sequence etaf-animation--running))
                (etaf-animation--stop animation))
              (etaf-animation--drop-clock))
          (if etaf-animation--running
              (etaf-animation--ensure-clock)
            (etaf-animation--drop-clock)))
      ((error quit)
       ;; Invalid live clock settings must not create a repeating error storm.
       (dolist (animation (copy-sequence etaf-animation--running))
         (etaf-animation--stop animation))
       (etaf-animation--drop-clock)
       (unless failure (setq failure error))))
    (when failure (signal (car failure) (cdr failure)))))

(defun etaf-animation--retarget (animation target)
  "Move ANIMATION's shown value toward TARGET.
A run in flight restarts from the value currently displayed, so changing the
target never jumps.  Disabled animation and zero duration apply TARGET now."
  (let* ((shown (etaf-animation-shown animation))
         (current (etaf-untracked (etaf-value shown)))
         (same (funcall (or (etaf-ref-test shown) #'etaf--reactive-same-p)
                        current target)))
    (setf (etaf-animation-from animation) current
          (etaf-animation-to animation) target)
    (cond
     (same
      (etaf-animation--deactivate animation))
     ((or (not etaf-animation-enabled)
          (<= (etaf-animation-duration animation) 0))
      (etaf-animation--deactivate animation)
      (etaf-set-value shown target))
     (t
      (etaf-animation--activate animation)
      (setf (etaf-animation-start animation) etaf-animation--clock-time)))))

(defun etaf-animation--own (animation scope)
  "Register ANIMATION cleanup when SCOPE is active."
  (when scope
    (etaf-on-scope-dispose (lambda () (etaf-animation--stop animation)))))

;;;###autoload
(cl-defun etaf-transition (source &key (duration 0.2) (easing 'ease-out)
                                  name on-complete)
  "Return a ref that follows reactive SOURCE over DURATION seconds.
SOURCE is a ref, computed or zero-argument function as in `etaf-watch'; the
returned ref starts at SOURCE's current value.  Every later SOURCE change
restarts the interpolation from the value currently shown, so interrupting a
run does not jump.  DURATION is in seconds; zero applies SOURCE at once.
EASING is a name from `etaf-animation-easings' or a function.  ON-COMPLETE
runs after a run reaches SOURCE.  Read the returned ref with `etaf-value'
wherever the display should follow it.  Create it during Component setup or
`:bindings' so the Scope stops it on disposal; otherwise call
`etaf-animation-stop' yourself.  NAME labels the ref in diagnostics."
  (unless (and (numberp duration) (>= duration 0))
    (signal 'etaf-animation-error (list "Invalid duration" duration)))
  (when (and on-complete (not (functionp on-complete)))
    (signal 'wrong-type-argument (list 'functionp on-complete)))
  (let* ((ease (etaf-animation--easing easing))
         (scope (etaf-current-effect-scope))
         (initial (etaf-untracked (funcall (etaf--watch-getter source))))
         (shown (etaf-ref initial :name (or name 'etaf-transition)))
         (animation (etaf--animation-create
                     :shown shown :target source :kind 'transition
                     :from initial :to initial :duration (float duration)
                     :easing ease :on-complete on-complete)))
    (puthash shown animation etaf-animation--registry)
    (setf (etaf-animation-watch-stop animation)
          (etaf-watch source
                      (lambda (new _old) (etaf-animation--retarget animation new))
                      :name name))
    (etaf-animation--own animation scope)
    shown))

;;;###autoload
(cl-defun etaf-animation-frames (frames &key (interval 0.1) (loop t)
                                        name on-complete)
  "Return a ref cycling through FRAMES every INTERVAL seconds.
FRAMES is a nonempty list or vector shown in order.  LOOP nil stops on the
last frame instead and runs ON-COMPLETE.  Read the returned ref with
`etaf-value' wherever the display should follow it.  Create it during
Component setup or `:bindings' so the Scope stops it on disposal; otherwise
call `etaf-animation-stop' yourself.  NAME labels the ref in diagnostics."
  (unless (and (sequencep frames) (> (length frames) 0)
               (not (stringp frames)))
    (signal 'etaf-animation-error (list "FRAMES must be a nonempty sequence" frames)))
  (unless (and (numberp interval) (> interval 0))
    (signal 'etaf-animation-error (list "Invalid frame interval" interval)))
  (when (and on-complete (not (functionp on-complete)))
    (signal 'wrong-type-argument (list 'functionp on-complete)))
  (let* ((scope (etaf-current-effect-scope))
         (shown (etaf-ref (elt frames 0) :name (or name 'etaf-animation-frames)))
         (animation (etaf--animation-create
                     :shown shown :kind 'frames :sequence frames
                     :interval (float interval) :loop (and loop t)
                     :on-complete on-complete)))
    (puthash shown animation etaf-animation--registry)
    (when etaf-animation-enabled
      (etaf-animation--activate animation)
      (setf (etaf-animation-start animation) etaf-animation--clock-time))
    (etaf-animation--own animation scope)
    shown))

;;;###autoload
(defun etaf-animation-stop (source)
  "Stop animating SOURCE and keep its value where it is.
SOURCE is a ref returned by `etaf-transition' or `etaf-animation-frames'.
Later writes to a transition's target no longer animate it.  Stopping an
already stopped animation is harmless."
  (etaf-animation--stop (etaf-animation--animated source)))

;;;###autoload
(defun etaf-animation-finish (source)
  "Stop animating SOURCE by applying its final value now.
A transition applies its current target and runs its completion callback when
it was running; a frame sequence keeps its current frame."
  (let ((animation (etaf-animation--animated source)))
    (pcase (etaf-animation-kind animation)
      ('transition
       (when (etaf-animation-active animation)
         (etaf-set-value (etaf-animation-shown animation)
                         (etaf-animation-to animation))
         (etaf-animation--complete animation)))
      ('frames nil))
    (etaf-animation--stop animation)))

;;;###autoload
(defun etaf-animation-active-p (source)
  "Return non-nil while SOURCE's animation is subscribed to the clock."
  (let ((animation (gethash source etaf-animation--registry)))
    (and animation (etaf-animation-active animation) t)))

(provide 'etaf-animation)

;;; etaf-animation.el ends here
