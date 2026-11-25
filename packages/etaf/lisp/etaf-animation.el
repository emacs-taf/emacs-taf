;;; etaf-animation.el --- Time-driven reactive values -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An animation is an ordinary reactive ref whose value moves over time.  The
;; application keeps writing its target as usual; `etaf-transition' returns
;; the displayed ref and restarts the interpolation from the value currently
;; on screen, so interruption never jumps.  `etaf-spring' follows a target
;; with damped spring physics and preserves velocity across interruptions.
;; `etaf-animation-frames' cycles a fixed list for spinners, marquees and
;; typewriter effects.  `etaf-animation-tick' subscribes a per-frame callback
;; to the shared clock, and `etaf-animation-timeline' sequences delays, callbacks,
;; progress runs and parallel groups on the same clock.
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
When nil, new transitions and springs apply their target immediately, running
transitions and springs snap to their target, non-looping timelines finish
their steps immediately, and frame sequences or ticks hold their value.
Setting this back to t does not restart stopped runs.")

(defvar etaf-animation-paused nil
  "Whether the shared clock stops advancing.
While paused, running animations hold their displayed value and keep their
progress; setting this back to nil resumes exactly where they stopped.  Unlike
`etaf-animation-enabled', pausing does not resolve or stop a run.")

(defvar etaf-animation-speed 1.0
  "Animation speed multiplier.
A positive number scaling how fast the shared clock advances, so 2 runs every
animation twice as fast and 0.5 half as fast.  The change applies from the
next tick without moving a run's progress.")

(defvar etaf-animation-color-space 'rgb
  "Color space used by `etaf-animation-interpolate' when blending colors.
Supported values are `rgb' (component-wise sRGB, the default) and `oklab'
\(perceptually uniform OKLab blending).  An unknown value signals
`etaf-animation-error'.")

(defvar etaf-animation-pause-hidden nil
  "When non-nil, hold animations whose owner buffer has no visible window.
Animations created while a Runtime is mounted record that Runtime's buffer;
while that buffer is not displayed in any window, their progress pauses and
resumes seamlessly once a window displays the buffer again.")

(defvar etaf-animation-spring-presets
  '((snappy . (:stiffness 320 :damping 28 :mass 1.0))
    (gentle . (:stiffness 120 :damping 18 :mass 1.0))
    (bouncy . (:stiffness 260 :damping 12 :mass 1.0))
    (stiff  . (:stiffness 420 :damping 34 :mass 1.0)))
  "Alist of (NAME . PLIST) spring parameter presets for `etaf-spring'.
Each PLIST supplies `:stiffness', `:damping' and `:mass' defaults.")

(defvar etaf-animation-interpolators nil
  "Ordered ((PREDICATE . FUNCTION) ...) consulted before built-in conversion.
PREDICATE takes FROM and TO and decides whether FUNCTION applies; FUNCTION
takes FROM, TO and PROGRESS and returns the value at that progress.  The first
matching pair wins.  Built-in conversion handles numbers, color strings and
equal-length lists or vectors of convertible values.")

(defvar etaf-animation--owner-buffer-function nil
  "Hook installed by the Runtime layer returning the current mounted buffer.")

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

(defun etaf-animation--clamp-unit (value)
  "Clamp numeric VALUE into [0.0, 1.0]."
  (min 1.0 (max 0.0 (float value))))

(defun etaf-animation--srgb-to-linear (channel)
  "Convert sRGB CHANNEL in [0, 1] to linear light."
  (if (<= channel 0.04045)
      (/ channel 12.92)
    (expt (/ (+ channel 0.055) 1.055) 2.4)))

(defun etaf-animation--linear-to-srgb (channel)
  "Convert linear light CHANNEL to clamped sRGB in [0, 1]."
  (let ((c (etaf-animation--clamp-unit channel)))
    (if (<= c 0.0031308)
        (* 12.92 c)
      (- (* 1.055 (expt c (/ 1.0 2.4))) 0.055))))

(defun etaf-animation--cbrt (value)
  "Return the real cube root of VALUE."
  (cond
   ((= value 0.0) 0.0)
   ((< value 0.0) (- (expt (- value) (/ 1.0 3.0))))
   (t (expt value (/ 1.0 3.0)))))

(defun etaf-animation--rgb-to-oklab (r g b)
  "Convert sRGB triple R, G, B in [0, 1] to OKLab list (L A B)."
  (let* ((lr (etaf-animation--srgb-to-linear r))
         (lg (etaf-animation--srgb-to-linear g))
         (lb (etaf-animation--srgb-to-linear b))
         (l (etaf-animation--cbrt (+ (* 0.4122214708 lr)
                                     (* 0.5363325363 lg)
                                     (* 0.0514459929 lb))))
         (m (etaf-animation--cbrt (+ (* 0.2119034982 lr)
                                     (* 0.6806995451 lg)
                                     (* 0.1073969566 lb))))
         (s (etaf-animation--cbrt (+ (* 0.0883024619 lr)
                                     (* 0.2817188376 lg)
                                     (* 0.6299787005 lb)))))
    (list (+ (* 0.2104542553 l) (* 0.7936177850 m) (* -0.0040720468 s))
          (+ (* 1.9779984951 l) (* -2.4285922050 m) (* 0.4505937099 s))
          (+ (* 0.0259040371 l) (* 0.7827717662 m) (* -0.8086757660 s)))))

(defun etaf-animation--oklab-to-hex (lightness a b)
  "Convert OKLab LIGHTNESS, A, B back to a clamped hex color string."
  (let* ((l_ (+ lightness (* 0.3963377774 a) (* 0.2158037573 b)))
         (m_ (+ lightness (* -0.1055613458 a) (* -0.0638541728 b)))
         (s_ (+ lightness (* -0.0894841775 a) (* -1.2914855480 b)))
         (l (* l_ l_ l_))
         (m (* m_ m_ m_))
         (s (* s_ s_ s_))
         (lr (+ (* 4.0767416621 l) (* -3.3077115913 m) (* 0.2309699292 s)))
         (lg (+ (* -1.2684380046 l) (* 2.6097574011 m) (* -0.3413193965 s)))
         (lb (+ (* -0.0041960863 l) (* -0.7034186147 m) (* 1.7076147010 s))))
    (color-rgb-to-hex (etaf-animation--linear-to-srgb lr)
                      (etaf-animation--linear-to-srgb lg)
                      (etaf-animation--linear-to-srgb lb))))

(defun etaf-animation--blend-colors (from to progress)
  "Blend color strings FROM and TO at PROGRESS in `etaf-animation-color-space'."
  (pcase-let* ((`(,r1 ,g1 ,b1) (color-name-to-rgb from))
               (`(,r2 ,g2 ,b2) (color-name-to-rgb to)))
    (pcase etaf-animation-color-space
      ('rgb
       (color-rgb-to-hex
        (etaf-animation--clamp-unit (+ r1 (* (- r2 r1) progress)))
        (etaf-animation--clamp-unit (+ g1 (* (- g2 g1) progress)))
        (etaf-animation--clamp-unit (+ b1 (* (- b2 b1) progress)))))
      ('oklab
       (pcase-let* ((`(,l1 ,a1 ,k1) (etaf-animation--rgb-to-oklab r1 g1 b1))
                    (`(,l2 ,a2 ,k2) (etaf-animation--rgb-to-oklab r2 g2 b2)))
         (etaf-animation--oklab-to-hex
          (+ l1 (* (- l2 l1) progress))
          (+ a1 (* (- a2 a1) progress))
          (+ k1 (* (- k2 k1) progress)))))
      (other
       (signal 'etaf-animation-error (list "Unknown color space" other))))))

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
        (etaf-animation--blend-colors from to progress))
       ((and (listp from) (listp to) (= (length from) (length to)))
        (cl-mapcar (lambda (a b) (etaf-animation--interpolate a b progress))
                   from to))
       ((and (vectorp from) (vectorp to) (= (length from) (length to)))
        (cl-map 'vector (lambda (a b) (etaf-animation--interpolate a b progress))
                from to))
       ((equal from to) from)
       (t from)))))

;;;###autoload
(defun etaf-animation-interpolate (from to progress)
  "Return the value at PROGRESS (0 to 1) between FROM and TO.
PROGRESS 1 returns TO unchanged.  Numbers convert arithmetically, color
strings blend in `etaf-animation-color-space', and equal-length lists or
vectors convert element-wise while equal non-numbers stand still.  Extend
the conversion by adding (PREDICATE . FUNCTION) entries to
`etaf-animation-interpolators'."
  (if (>= progress 1)
      to
    (etaf-animation--interpolate from to progress)))

(defun etaf-animation--quantize-value (value step)
  "Quantize VALUE recursively to multiples of positive STEP."
  (cond
   ((numberp value)
    (* step (round (/ (float value) step))))
   ((proper-list-p value)
    (mapcar (lambda (item) (etaf-animation--quantize-value item step)) value))
   ((vectorp value)
    (cl-map 'vector (lambda (item) (etaf-animation--quantize-value item step)) value))
   (t value)))

;;;###autoload
(defun etaf-animation-quantize (value step)
  "Snap numeric elements of VALUE to multiples of positive STEP.
Numbers round to the nearest multiple of STEP; lists and vectors quantize
element-wise while non-numbers stay unchanged, so lengths such as `(px 13.7)'
snap cleanly to a pixel or color grid.  Invalid STEP signals
`etaf-animation-error'."
  (unless (and (numberp step) (> step 0))
    (signal 'etaf-animation-error (list "Invalid quantize step" step)))
  (etaf-animation--quantize-value value (float step)))

(cl-defstruct (etaf-animation (:constructor etaf--animation-create)
                              (:copier nil))
  "One running or resting animation."
  shown target watch-stop kind from to start duration delay easing on-complete
  sequence interval loop (active nil)
  owner-buffer last-time elapsed accum callback
  spring-pos spring-vel spring-target spring-stiffness spring-damping
  spring-mass spring-precision spring-shape
  timeline-steps timeline-index timeline-step-start)

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

(defun etaf-animation--owner-buffer ()
  "Return the currently mounting Runtime's buffer, or nil."
  (when (functionp etaf-animation--owner-buffer-function)
    (funcall etaf-animation--owner-buffer-function)))

(defun etaf-animation--hidden-p (animation)
  "Return non-nil when ANIMATION should hold because its buffer is hidden."
  (when etaf-animation-pause-hidden
    (let ((buffer (etaf-animation-owner-buffer animation)))
      (and (buffer-live-p buffer)
           (null (get-buffer-window buffer t))))))

(defun etaf-animation--shift-clock (animation delta)
  "Advance ANIMATION's stored clock anchors by DELTA so hidden time freezes."
  (when (numberp (etaf-animation-start animation))
    (cl-incf (etaf-animation-start animation) delta))
  (when (numberp (etaf-animation-last-time animation))
    (cl-incf (etaf-animation-last-time animation) delta))
  (when (numberp (etaf-animation-timeline-step-start animation))
    (cl-incf (etaf-animation-timeline-step-start animation) delta)))

;;;; Spring physics codec and stepping

(defun etaf-animation--spring-extract-1 (value channels)
  "Extract shape for VALUE and push float channels onto CHANNELS cell."
  (cond
   ((numberp value)
    (push (float value) (car channels))
    'number)
   ((etaf-animation--color-p value)
    (pcase-let ((`(,r ,g ,b) (color-name-to-rgb value)))
      (push (float r) (car channels))
      (push (float g) (car channels))
      (push (float b) (car channels)))
    'color)
   ((proper-list-p value)
    (cons 'list
          (mapcar (lambda (item)
                    (etaf-animation--spring-extract-1 item channels))
                  value)))
   ((vectorp value)
    (cons 'vector
          (cl-loop for item across value
                   collect (etaf-animation--spring-extract-1 item channels))))
   (t (cons 'literal value))))

(defun etaf-animation--spring-extract (value)
  "Return (SHAPE . FLOAT-VECTOR) for VALUE, or nil when non-numeric."
  (let* ((channels (list nil))
         (shape (etaf-animation--spring-extract-1 value channels))
         (values (nreverse (car channels))))
    (when values
      (cons shape (vconcat values)))))

(defun etaf-animation--spring-rebuild-1 (shape vec cursor)
  "Rebuild value matching SHAPE from VEC starting at CURSOR cons cell."
  (cond
   ((eq shape 'number)
    (let ((idx (car cursor)))
      (setcar cursor (1+ idx))
      (aref vec idx)))
   ((eq shape 'color)
    (let* ((idx (car cursor))
           (r (etaf-animation--clamp-unit (aref vec idx)))
           (g (etaf-animation--clamp-unit (aref vec (+ idx 1))))
           (b (etaf-animation--clamp-unit (aref vec (+ idx 2)))))
      (setcar cursor (+ idx 3))
      (color-rgb-to-hex r g b)))
   ((eq (car-safe shape) 'literal)
    (cdr shape))
   ((eq (car-safe shape) 'list)
    (mapcar (lambda (sub) (etaf-animation--spring-rebuild-1 sub vec cursor))
            (cdr shape)))
   ((eq (car-safe shape) 'vector)
    (vconcat
     (mapcar (lambda (sub) (etaf-animation--spring-rebuild-1 sub vec cursor))
             (cdr shape))))))

(defun etaf-animation--spring-rebuild (shape vec)
  "Reconstruct a value of SHAPE from float vector VEC."
  (etaf-animation--spring-rebuild-1 shape vec (list 0)))

(defun etaf-animation--spring-resolve (stiffness damping mass preset)
  "Resolve and validate spring parameters (STIFFNESS DAMPING MASS)."
  (let ((defaults (when preset
                    (or (cdr (assq preset etaf-animation-spring-presets))
                        (signal 'etaf-animation-error
                                (list "Unknown spring preset" preset))))))
    (let ((k (or stiffness (plist-get defaults :stiffness) 180.0))
          (c (or damping (plist-get defaults :damping) 22.0))
          (m (or mass (plist-get defaults :mass) 1.0)))
      (unless (and (numberp k) (> k 0))
        (signal 'etaf-animation-error (list "Invalid spring stiffness" k)))
      (unless (and (numberp c) (> c 0))
        (signal 'etaf-animation-error (list "Invalid spring damping" c)))
      (unless (and (numberp m) (> m 0))
        (signal 'etaf-animation-error (list "Invalid spring mass" m)))
      (list (float k) (float c) (float m)))))

(defun etaf-animation--spring-retarget (animation target)
  "Retarget spring ANIMATION to TARGET, preserving velocity across changes."
  (let* ((shown (etaf-animation-shown animation))
         (current (etaf-untracked (etaf-value shown)))
         (same (funcall (or (etaf-ref-test shown) #'etaf--reactive-same-p)
                        current target))
         (extracted (etaf-animation--spring-extract target)))
    (setf (etaf-animation-to animation) target)
    (cond
     ((and same (not (etaf-animation-active animation)))
      (etaf-animation--deactivate animation))
     ((or (not etaf-animation-enabled) (null extracted))
      (setf (etaf-animation-spring-vel animation) nil
            (etaf-animation-spring-pos animation) nil
            (etaf-animation-spring-target animation) nil
            (etaf-animation-spring-shape animation) nil)
      (etaf-animation--deactivate animation)
      (etaf-set-value shown target))
     ((and (etaf-animation-active animation)
           (equal (car extracted) (etaf-animation-spring-shape animation)))
      ;; Preserve live position and velocity for momentum-continuous retarget.
      (setf (etaf-animation-spring-target animation) (cdr extracted)))
     (t
      (let ((cur-extracted (etaf-animation--spring-extract current)))
        (if (and cur-extracted
                 (equal (car cur-extracted) (car extracted)))
            (let* ((pos (copy-sequence (cdr cur-extracted)))
                   (vel (make-vector (length pos) 0.0)))
              (setf (etaf-animation-spring-shape animation) (car extracted)
                    (etaf-animation-spring-pos animation) pos
                    (etaf-animation-spring-vel animation) vel
                    (etaf-animation-spring-target animation) (cdr extracted))
              (etaf-animation--activate animation)
              (setf (etaf-animation-last-time animation) etaf-animation--clock-time))
          (setf (etaf-animation-spring-vel animation) nil
                (etaf-animation-spring-pos animation) nil
                (etaf-animation-spring-target animation) nil
                (etaf-animation-spring-shape animation) nil)
          (etaf-animation--deactivate animation)
          (etaf-set-value shown target)))))))

(defun etaf-animation--sample-spring (animation now)
  "Advance damped spring ANIMATION to clock time NOW."
  (let* ((last (or (etaf-animation-last-time animation) now))
         (dt (min 0.1 (max 0.0 (- now last))))
         (pos (etaf-animation-spring-pos animation))
         (vel (etaf-animation-spring-vel animation))
         (target (etaf-animation-spring-target animation))
         (stiffness (etaf-animation-spring-stiffness animation))
         (damping (etaf-animation-spring-damping animation))
         (mass (etaf-animation-spring-mass animation))
         (precision (etaf-animation-spring-precision animation))
         (vel-eps (* precision 5.0))
         (count (length pos)))
    (setf (etaf-animation-last-time animation) now)
    (when (> dt 0.0)
      (let* ((steps (max 1 (min 32 (ceiling (/ dt 0.004)))))
             (h (/ dt (float steps))))
        (dotimes (_ steps)
          (dotimes (i count)
            (let* ((p (aref pos i))
                   (v (aref vel i))
                   (goal (aref target i))
                   (acc (/ (- (* stiffness (- goal p)) (* damping v)) mass))
                   (nv (+ v (* acc h)))
                   (np (+ p (* nv h))))
              (aset vel i nv)
              (aset pos i np))))))
    (let ((settled t))
      (dotimes (i count)
        (when (or (> (abs (- (aref target i) (aref pos i))) precision)
                  (> (abs (aref vel i)) vel-eps))
          (setq settled nil)))
      (if settled
          (progn
            (dotimes (i count) (aset vel i 0.0))
            (etaf-set-value (etaf-animation-shown animation)
                            (etaf-animation-to animation))
            (etaf-animation--deactivate animation)
            (etaf-animation--complete animation))
        (etaf-set-value (etaf-animation-shown animation)
                        (etaf-animation--spring-rebuild
                         (etaf-animation-spring-shape animation) pos))))))

;;;; Timeline compilation and stepping

(defun etaf-animation--compile-step (spec)
  "Validate timeline step plist SPEC and return an internal mutable record."
  (unless (and (proper-list-p spec) (keywordp (car spec)))
    (signal 'etaf-animation-error (list "Invalid timeline step" spec)))
  (cond
   ((plist-member spec :delay)
    (let ((delay (plist-get spec :delay)))
      (unless (and (numberp delay) (>= delay 0))
        (signal 'etaf-animation-error (list "Invalid timeline delay" delay)))
      (list :kind 'delay :duration (float delay))))
   ((plist-member spec :call)
    (let ((fn (plist-get spec :call)))
      (unless (functionp fn)
        (signal 'wrong-type-argument (list 'functionp fn)))
      (list :kind 'call :fn fn :done nil)))
   ((plist-member spec :run)
    (let ((fn (plist-get spec :run))
          (duration (plist-get spec :duration))
          (easing (or (plist-get spec :easing) 'linear)))
      (unless (functionp fn)
        (signal 'wrong-type-argument (list 'functionp fn)))
      (unless (and (numberp duration) (>= duration 0))
        (signal 'etaf-animation-error (list "Invalid duration" duration)))
      (list :kind 'run :fn fn :duration (float duration)
            :easing (etaf-animation--easing easing) :done nil)))
   ((plist-member spec :parallel)
    (let ((children (plist-get spec :parallel)))
      (unless (and (proper-list-p children) (> (length children) 0))
        (signal 'etaf-animation-error
                (list "Parallel step must be a nonempty list" children)))
      (list :kind 'parallel
            :children (mapcar #'etaf-animation--compile-step children))))
   (t
    (signal 'etaf-animation-error (list "Unknown timeline step" spec)))))

(defun etaf-animation--timeline-step-duration (step)
  "Return nominal duration in seconds of compiled timeline STEP."
  (pcase (plist-get step :kind)
    ('delay (plist-get step :duration))
    ('call 0.0)
    ('run (plist-get step :duration))
    ('parallel
     (cl-loop for child in (plist-get step :children)
              maximize (etaf-animation--timeline-step-duration child)))))

(defun etaf-animation--timeline-reset-step (step)
  "Reset completion flags of compiled STEP for another loop iteration."
  (pcase (plist-get step :kind)
    ((or 'call 'run) (plist-put step :done nil))
    ('parallel
     (dolist (child (plist-get step :children))
       (etaf-animation--timeline-reset-step child)))))

(defun etaf-animation--timeline-advance-step (step elapsed)
  "Advance compiled STEP at ELAPSED seconds; return non-nil when complete."
  (pcase (plist-get step :kind)
    ('delay
     (>= elapsed (plist-get step :duration)))
    ('call
     (unless (plist-get step :done)
       (plist-put step :done t)
       (funcall (plist-get step :fn)))
     t)
    ('run
     (let ((duration (plist-get step :duration)))
       (if (or (<= duration 0.0) (>= elapsed duration))
           (progn
             (unless (plist-get step :done)
               (plist-put step :done t)
               (funcall (plist-get step :fn) 1.0))
             t)
         (funcall (plist-get step :fn)
                  (funcall (plist-get step :easing) (/ elapsed duration)))
         nil)))
    ('parallel
     (let ((all-done t))
       (dolist (child (plist-get step :children))
         (unless (etaf-animation--timeline-advance-step child elapsed)
           (setq all-done nil)))
       all-done))))

(defun etaf-animation--timeline-finish-step (step)
  "Apply final state of compiled STEP immediately if not yet done."
  (pcase (plist-get step :kind)
    ('delay nil)
    ('call
     (unless (plist-get step :done)
       (plist-put step :done t)
       (funcall (plist-get step :fn))))
    ('run
     (unless (plist-get step :done)
       (plist-put step :done t)
       (funcall (plist-get step :fn) 1.0)))
    ('parallel
     (dolist (child (plist-get step :children))
       (etaf-animation--timeline-finish-step child)))))

(defun etaf-animation--timeline-finish-remaining (animation)
  "Complete every remaining step of timeline ANIMATION in order."
  (let* ((steps (etaf-animation-timeline-steps animation))
         (count (length steps))
         (idx (etaf-animation-timeline-index animation)))
    (while (< idx count)
      (etaf-animation--timeline-finish-step (nth idx steps))
      (setq idx (1+ idx)))
    (setf (etaf-animation-timeline-index animation) count)
    (etaf-set-value (etaf-animation-shown animation) count)))

(defun etaf-animation--sample-timeline (animation now)
  "Advance timeline ANIMATION to clock time NOW."
  (let* ((steps (etaf-animation-timeline-steps animation))
         (count (length steps))
         (keep-going t))
    (while (and keep-going (etaf-animation-active animation))
      (let* ((idx (etaf-animation-timeline-index animation))
             (step (nth idx steps))
             (step-start (etaf-animation-timeline-step-start animation))
             (step-elapsed (max 0.0 (- now step-start))))
        (if (etaf-animation--timeline-advance-step step step-elapsed)
            (let* ((step-dur (etaf-animation--timeline-step-duration step))
                   (next-start (min now (+ step-start step-dur)))
                   (next-idx (1+ idx)))
              (setf (etaf-animation-timeline-index animation) next-idx
                    (etaf-animation-timeline-step-start animation) next-start)
              (etaf-set-value (etaf-animation-shown animation) next-idx)
              (when (>= next-idx count)
                (if (etaf-animation-loop animation)
                    (progn
                      (dolist (s steps)
                        (etaf-animation--timeline-reset-step s))
                      (setf (etaf-animation-timeline-index animation) 0
                            (etaf-animation-timeline-step-start animation) now)
                      (etaf-set-value (etaf-animation-shown animation) 0)
                      ;; Guard against zero-duration loops spinning in one tick.
                      (setq keep-going nil))
                  (etaf-animation--deactivate animation)
                  (etaf-animation--complete animation)
                  (setq keep-going nil))))
          (setq keep-going nil))))))

;;;; Transition, frames, tick sampling

(defun etaf-animation--sample-transition (animation now)
  "Move ANIMATION's shown value toward its target at NOW."
  (let ((start (etaf-animation-start animation)))
    (if (< now start)
        (etaf-set-value (etaf-animation-shown animation)
                        (etaf-animation-from animation))
      (let* ((duration (etaf-animation-duration animation))
             (progress (if (<= duration 0)
                           1.0
                         (min 1.0 (max 0.0 (/ (- now start) duration))))))
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
                           (funcall (etaf-animation-easing animation) progress))))))))

(defun etaf-animation--sample-frames (animation now)
  "Publish ANIMATION's frame for NOW."
  (let* ((frames (etaf-animation-sequence animation))
         (count (length frames))
         (interval (etaf-animation-interval animation))
         (index (floor (/ (max 0.0 (- now (etaf-animation-start animation)))
                          (max 0.001 interval)))))
    (if (and (not (etaf-animation-loop animation)) (>= index count))
        (progn
          (etaf-set-value (etaf-animation-shown animation)
                          (elt frames (1- count)))
          (etaf-animation--deactivate animation)
          (etaf-animation--complete animation))
      (etaf-set-value (etaf-animation-shown animation)
                      (elt frames (mod index count))))))

(defun etaf-animation--sample-tick (animation now)
  "Advance tick subscription ANIMATION to clock time NOW."
  (let* ((last (or (etaf-animation-last-time animation) now))
         (delta (max 0.0 (- now last)))
         (interval (or (etaf-animation-interval animation) 0.0))
         (accum (+ (or (etaf-animation-accum animation) 0.0) delta)))
    (setf (etaf-animation-last-time animation) now)
    (if (or (<= interval 0.0) (>= accum interval))
        (let ((elapsed (+ (or (etaf-animation-elapsed animation) 0.0) accum)))
          (setf (etaf-animation-accum animation) 0.0
                (etaf-animation-elapsed animation) elapsed)
          (etaf-set-value (etaf-animation-shown animation) elapsed)
          (funcall (etaf-animation-callback animation) accum elapsed))
      (setf (etaf-animation-accum animation) accum))))

(defun etaf-animation--sample (animation now)
  "Publish ANIMATION's value for the clock time NOW."
  (pcase (etaf-animation-kind animation)
    ('transition (etaf-animation--sample-transition animation now))
    ('spring (etaf-animation--sample-spring animation now))
    ('frames (etaf-animation--sample-frames animation now))
    ('tick (etaf-animation--sample-tick animation now))
    ('timeline (etaf-animation--sample-timeline animation now))))

(defun etaf-animation--freeze (animation)
  "Stop ANIMATION without time, as when animation is disabled."
  (pcase (etaf-animation-kind animation)
    ((or 'transition 'spring)
     (etaf-set-value (etaf-animation-shown animation)
                     (etaf-animation-to animation))
     (etaf-animation--complete animation))
    ('timeline
     (unless (etaf-animation-loop animation)
       (etaf-animation--timeline-finish-remaining animation)
       (etaf-animation--complete animation)))
    (_ nil))
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
           (delta (* scale (max 0.0 (- wall etaf-animation--clock-stamp))))
           (now (+ etaf-animation--clock-time delta))
           (failure nil))
      (setq etaf-animation--clock-stamp wall
            etaf-animation--clock-time now)
      (etaf-batch
        (dolist (animation (copy-sequence etaf-animation--running))
          (if (etaf-animation--hidden-p animation)
              (etaf-animation--shift-clock animation delta)
            (condition-case error
                (etaf-animation--sample animation now)
              ((error quit)
               (etaf-animation--deactivate animation)
               (unless failure (setq failure error)))))))
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
target never jumps.  Disabled animation and zero duration with zero delay
apply TARGET now."
  (let* ((shown (etaf-animation-shown animation))
         (current (etaf-untracked (etaf-value shown)))
         (same (funcall (or (etaf-ref-test shown) #'etaf--reactive-same-p)
                        current target))
         (delay (or (etaf-animation-delay animation) 0.0)))
    (setf (etaf-animation-from animation) current
          (etaf-animation-to animation) target)
    (cond
     (same
      (etaf-animation--deactivate animation))
     ((or (not etaf-animation-enabled)
          (and (<= (etaf-animation-duration animation) 0)
               (<= delay 0)))
      (etaf-animation--deactivate animation)
      (etaf-set-value shown target))
     (t
      (etaf-animation--activate animation)
      (setf (etaf-animation-start animation)
            (+ etaf-animation--clock-time delay))))))

(defun etaf-animation--own (animation scope)
  "Register ANIMATION cleanup when SCOPE is active."
  (when scope
    (etaf-on-scope-dispose (lambda () (etaf-animation--stop animation)))))

;;;###autoload
(cl-defun etaf-transition (source &key (duration 0.2) (easing 'ease-out)
                                  (delay 0) name on-complete)
  "Return a ref that follows reactive SOURCE over DURATION seconds.
SOURCE is a ref, computed or zero-argument function as in `etaf-watch'; the
returned ref starts at SOURCE's current value.  Every later SOURCE change
restarts the interpolation from the value currently shown, so interrupting a
run does not jump.  DURATION is in seconds; zero with zero DELAY applies
SOURCE at once.  DELAY waits that many seconds on the shared clock before
interpolating.  EASING is a name from `etaf-animation-easings' or a function.
ON-COMPLETE runs after a run reaches SOURCE.  Read the returned ref with
`etaf-value' wherever the display should follow it.  Create it during
Component setup or `:bindings' so the Scope stops it on disposal; otherwise
call `etaf-animation-stop' yourself.  NAME labels the ref in diagnostics."
  (unless (and (numberp duration) (>= duration 0))
    (signal 'etaf-animation-error (list "Invalid duration" duration)))
  (unless (and (numberp delay) (>= delay 0))
    (signal 'etaf-animation-error (list "Invalid delay" delay)))
  (when (and on-complete (not (functionp on-complete)))
    (signal 'wrong-type-argument (list 'functionp on-complete)))
  (let* ((ease (etaf-animation--easing easing))
         (scope (etaf-current-effect-scope))
         (initial (etaf-untracked (funcall (etaf--watch-getter source))))
         (shown (etaf-ref initial :name (or name 'etaf-transition)))
         (animation (etaf--animation-create
                     :shown shown :target source :kind 'transition
                     :from initial :to initial :duration (float duration)
                     :delay (float delay) :easing ease
                     :on-complete on-complete
                     :owner-buffer (etaf-animation--owner-buffer))))
    (puthash shown animation etaf-animation--registry)
    (setf (etaf-animation-watch-stop animation)
          (etaf-watch source
                      (lambda (new _old) (etaf-animation--retarget animation new))
                      :name name))
    (etaf-animation--own animation scope)
    shown))

;;;###autoload
(cl-defun etaf-spring (source &key stiffness damping mass (precision 0.01)
                              preset name on-complete)
  "Return a ref that follows reactive SOURCE with damped spring physics.
SOURCE is a ref, computed or zero-argument function as in `etaf-watch'; the
returned ref starts at SOURCE's current value.  Unlike `etaf-transition',
changing SOURCE mid-flight preserves the spring's current velocity so rapid
updates carry natural momentum.  PRESET selects a named parameter bundle from
`etaf-animation-spring-presets'; explicit STIFFNESS, DAMPING or MASS override
the preset (or defaults 180, 22, 1).  PRECISION is the positive settling
threshold.  Supports numbers, color strings, and lists or vectors containing
them.  Scope ownership, ON-COMPLETE and `etaf-animation-stop' follow
`etaf-transition'.  NAME labels the ref in diagnostics."
  (unless (and (numberp precision) (> precision 0))
    (signal 'etaf-animation-error (list "Invalid spring precision" precision)))
  (when (and on-complete (not (functionp on-complete)))
    (signal 'wrong-type-argument (list 'functionp on-complete)))
  (pcase-let* ((`(,k ,c ,m) (etaf-animation--spring-resolve
                             stiffness damping mass preset))
               (scope (etaf-current-effect-scope))
               (initial (etaf-untracked (funcall (etaf--watch-getter source))))
               (shown (etaf-ref initial :name (or name 'etaf-spring)))
               (animation (etaf--animation-create
                           :shown shown :target source :kind 'spring
                           :from initial :to initial
                           :spring-stiffness k :spring-damping c
                           :spring-mass m :spring-precision (float precision)
                           :on-complete on-complete
                           :owner-buffer (etaf-animation--owner-buffer))))
    (puthash shown animation etaf-animation--registry)
    (setf (etaf-animation-watch-stop animation)
          (etaf-watch source
                      (lambda (new _old)
                        (etaf-animation--spring-retarget animation new))
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
                     :on-complete on-complete
                     :owner-buffer (etaf-animation--owner-buffer))))
    (puthash shown animation etaf-animation--registry)
    (when etaf-animation-enabled
      (etaf-animation--activate animation)
      (setf (etaf-animation-start animation) etaf-animation--clock-time))
    (etaf-animation--own animation scope)
    shown))

;;;###autoload
(cl-defun etaf-animation-tick (callback &key (interval 0) name)
  "Subscribe CALLBACK to the shared animation clock and return its elapsed ref.
CALLBACK takes two floats, (DT ELAPSED), representing the elapsed animation
seconds since the previous callback call and since creation.  INTERVAL is a
nonnegative minimum spacing in animation seconds between calls; zero runs on
every clock tick.  The returned ref holds the current elapsed seconds and
accepts `etaf-animation-stop', `etaf-animation-finish' and
`etaf-animation-active-p'.  Scope ownership follows `etaf-transition'.
NAME labels the ref in diagnostics."
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (unless (and (numberp interval) (>= interval 0))
    (signal 'etaf-animation-error (list "Invalid tick interval" interval)))
  (let* ((scope (etaf-current-effect-scope))
         (shown (etaf-ref 0.0 :name (or name 'etaf-animation-tick)))
         (animation (etaf--animation-create
                     :shown shown :kind 'tick :callback callback
                     :interval (float interval) :elapsed 0.0 :accum 0.0
                     :owner-buffer (etaf-animation--owner-buffer))))
    (puthash shown animation etaf-animation--registry)
    (when etaf-animation-enabled
      (etaf-animation--activate animation)
      (setf (etaf-animation-last-time animation) etaf-animation--clock-time))
    (etaf-animation--own animation scope)
    shown))

;;;###autoload
(cl-defun etaf-animation-timeline (steps &key loop name on-complete)
  "Run declarative STEPS on the shared clock and return its step-index ref.
STEPS is a nonempty list of step plists:
  (:delay SECONDS)
  (:call FUNCTION)
  (:run FUNCTION :duration SECONDS [:easing EASING])
  (:parallel STEP-LIST)
Each step runs in order; `:run' calls FUNCTION with eased progress from 0 to 1
and guarantees a final 1.0 call.  When LOOP is non-nil, the sequence restarts
after the last step.  Otherwise ON-COMPLETE runs after the final step finishes.
Calling `etaf-animation-finish' completes all remaining steps immediately in
order and fires ON-COMPLETE.  When `etaf-animation-enabled' is nil, a
non-looping timeline resolves its steps immediately without starting the clock.
Scope ownership follows `etaf-transition'.  NAME labels the ref."
  (unless (and (proper-list-p steps) (> (length steps) 0))
    (signal 'etaf-animation-error (list "STEPS must be a nonempty list" steps)))
  (when (and on-complete (not (functionp on-complete)))
    (signal 'wrong-type-argument (list 'functionp on-complete)))
  (let* ((compiled (mapcar #'etaf-animation--compile-step steps))
         (scope (etaf-current-effect-scope))
         (shown (etaf-ref 0 :name (or name 'etaf-animation-timeline)))
         (animation (etaf--animation-create
                     :shown shown :kind 'timeline
                     :timeline-steps compiled :timeline-index 0
                     :loop (and loop t) :on-complete on-complete
                     :owner-buffer (etaf-animation--owner-buffer))))
    (puthash shown animation etaf-animation--registry)
    (if etaf-animation-enabled
        (progn
          (etaf-animation--activate animation)
          (setf (etaf-animation-timeline-step-start animation)
                etaf-animation--clock-time))
      (unless loop
        (etaf-batch
          (etaf-animation--timeline-finish-remaining animation)
          (etaf-animation--complete animation))))
    (etaf-animation--own animation scope)
    shown))

;;;###autoload
(defun etaf-animation-stop (source)
  "Stop animating SOURCE and keep its value where it is.
SOURCE is a ref returned by `etaf-transition', `etaf-spring',
`etaf-animation-frames', `etaf-animation-tick' or `etaf-animation-timeline'.
Later writes to a transition or spring target no longer animate it.
Stopping an already stopped animation is harmless."
  (etaf-animation--stop (etaf-animation--animated source))
  source)

;;;###autoload
(defun etaf-animation-finish (source)
  "Stop animating SOURCE by applying its final value now.
A running transition or spring applies its current target and runs its
completion callback; a running timeline completes every remaining step in
order and runs its completion callback; a frame sequence or tick keeps its
current value."
  (let ((animation (etaf-animation--animated source)))
    (pcase (etaf-animation-kind animation)
      ((or 'transition 'spring)
       (when (etaf-animation-active animation)
         (etaf-set-value (etaf-animation-shown animation)
                         (etaf-animation-to animation))
         (etaf-animation--complete animation)))
      ('timeline
       (when (etaf-animation-active animation)
         (etaf-batch
           (etaf-animation--timeline-finish-remaining animation)
           (etaf-animation--complete animation))))
      (_ nil))
    (etaf-animation--stop animation)
    source))

;;;###autoload
(defun etaf-animation-active-p (source)
  "Return non-nil while SOURCE's animation is subscribed to the clock."
  (let ((animation (gethash source etaf-animation--registry)))
    (and animation (etaf-animation-active animation) t)))

(provide 'etaf-animation)

;;; etaf-animation.el ends here
