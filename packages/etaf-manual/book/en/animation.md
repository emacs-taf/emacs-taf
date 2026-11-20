# Animation

An animation is an ordinary reactive ref whose value moves with time. The application keeps writing its target the way it writes any other ref; the framework samples the displayed value on one shared clock and publishes each sample through the normal ref path, so bindings, damage and buffer updates behave exactly as for an application write. `etaf-transition` turns a target into a displayed ref that never jumps when the target changes, and `etaf-animation-frames` cycles a fixed sequence for spinners, marquees and typewriter effects. Both belong to the Scope that created them, share one clock with every other running animation, and stop with it when nothing runs. This chapter defines the two value sources, completion, interpolation and easing, the clock and its settings, stopping and finishing, and what happens when a run is interrupted. [Reactivity](reactivity.md) defines the refs, watches and Scopes underneath; [Runtime](runtime.md) defines the mounted Runtimes that publish the samples.

## Time-driven values

<!-- index: animation; shared clock; transition; frame sequence -->

An animation holds a ref whose value moves toward a target. The clock decides when a sample is due; each sample computes the value for the current time and writes it through the ordinary ref path, so a mounted Runtime sees an ordinary update. There is one clock per Emacs process, and it exists only while at least one animation is subscribed: the first activation starts a one-shot timer, and stopping the last animation cancels it. One sample advances every running animation in a single batch, in the order the animations joined the clock.

Interpolation is separate from timing: a sample needs the value between the previous value and the target. Built-in conversion covers numbers, color strings and equal-length lists or vectors; the extension variables below cover other shapes.

A transition follows a reactive source; a frame sequence cycles a fixed list. Use a transition when a value has a meaningful target and should arrive smoothly — a position, a size, a color, a fill level. Use frames when the value is chosen from a fixed set — spinners, marquees, blinking lamps, typewriter reveals.

### Transitions and frame sequences

<!-- index: etaf-transition; etaf-animation-frames; duration; easing; interval; loop; completion -->

#### Function: etaf-transition (source &key (duration 0.2) (easing 'ease-out) name on-complete)

Return a ref that follows reactive SOURCE over DURATION seconds.

**Arguments.** SOURCE is a ref, a computed value or a zero-argument function, exactly as in `etaf-watch`. DURATION is the travel time in seconds, defaults to 0.2 and may be zero. EASING is a name from `etaf-animation-easings` or an easing function. NAME labels the returned ref in diagnostics. ON-COMPLETE is a zero-argument function to run after a run reaches SOURCE.

**Semantics.** The returned ref starts at SOURCE's current value and is not running. Every later SOURCE change starts a run from the value currently displayed, so interrupting a run never jumps. Read the ref with `etaf-value` wherever the display should follow it. The animation belongs to the Scope active at creation, as in a Component's `:bindings` or setup; without such a Scope, stop it with `etaf-animation-stop`. A write of a target equal to the displayed value stops a run instead of starting one.

**Returns.** The displayed ref.

**Errors.** `error→ etaf-animation-error` with data `("Invalid duration" VALUE)` when DURATION is not a nonnegative number, and `("Unknown easing" VALUE)` when EASING is neither a function nor a name in `etaf-animation-easings`. `error→ wrong-type-argument` with data `(functionp VALUE)` when ON-COMPLETE is neither nil nor a function. An invalid SOURCE signals what `etaf-watch` signals.

**Example.** A target that a control can write.

```elisp
(let* ((level (etaf-ref 0))
       (shown (etaf-transition level :duration 0.3 :easing 'linear)))
  (etaf-value shown))
;; ⇒ 0
```

**See also.** `etaf-animation-frames`, `etaf-animation-interpolate`, `etaf-animation-stop`.

#### Function: etaf-animation-frames (frames &key (interval 0.1) (loop t) name on-complete)

Return a ref cycling through FRAMES every INTERVAL seconds.

**Arguments.** FRAMES is a nonempty list or vector whose elements are shown in order. INTERVAL is the time on each frame in seconds and defaults to 0.1. LOOP nil stops on the last frame instead of starting over; it defaults to t. NAME labels the returned ref in diagnostics. ON-COMPLETE is a zero-argument function to run when LOOP is nil and the last frame is reached.

**Semantics.** The ref starts on the first frame. The frame shown at a sample is chosen from the time since the sequence started, so a delayed sample skips frames rather than replaying them. The sequence is created running; the returned ref is read like any other ref. Scope ownership and validation follow `etaf-transition`.

**Returns.** The displayed ref.

**Errors.** `error→ etaf-animation-error` with data `("FRAMES must be a nonempty sequence" VALUE)` when FRAMES is nil, empty, a string or otherwise not a nonempty list or vector, and `("Invalid frame interval" VALUE)` when INTERVAL is not a positive number. `error→ wrong-type-argument` with data `(functionp VALUE)` when ON-COMPLETE is neither nil nor a function.

**Example.**

```elisp
(etaf-value (etaf-animation-frames '("|" "/" "-" "\\") :interval 0.12))
;; ⇒ "|"
```

**See also.** `etaf-transition`, `etaf-animation-stop`, `etaf-animation-easings`.

#### Property: :on-complete

The completion callback keyword of `etaf-transition` and `etaf-animation-frames`.

**Arguments.** A zero-argument function; optional.

**Semantics.** A transition runs it after a run reaches its target; a frame sequence runs it when LOOP is nil and the last frame is reached. The callback is queued after the publication of the sample that completed the run and runs when the pending reactive work has been published ([Reactivity](reactivity.md#batches-and-ticks)). It runs once per completed run, so a callback that retargets its own source — the usual way to build a loop — starts the next run after the previous one has landed. It does not run when a run is stopped before completion, when a transition applies its target because DURATION is zero or because `etaf-animation-enabled` is nil, or when frames are stopped or finished.

**Errors.** `error→ wrong-type-argument` with data `(functionp VALUE)` at construction when the value is neither nil nor a function.

**See also.** `etaf-transition`, `etaf-animation-frames`, `etaf-animation-finish`.

The example mounts a gauge that one transition fills over time.

```elisp :run
(etaf-define-component demo-animation-gauge ()
  "Fill a gauge that follows its target over time."
  :bindings ((level (etaf-ref 0))
             (shown (etaf-transition level :duration 0.5
                                     :easing 'ease-out :name 'gauge)))
  :setup (setf (etaf-value level) 1.0)
  :view
  (text (expr (format "level %.2f" (etaf-value shown)))))

(etaf-view (demo-animation-gauge))
```

### Interpolation and easing

<!-- index: etaf-animation-interpolate; interpolation; easing; color interpolation -->

#### Function: etaf-animation-interpolate (from to progress)

Return the value at PROGRESS between FROM and TO.

**Arguments.** FROM and TO are two values of the same kind. PROGRESS is a number; 0 returns FROM and 1 returns TO.

**Semantics.** PROGRESS 1 or more returns TO unchanged; a negative PROGRESS extrapolates past FROM. Numbers convert arithmetically and color strings blend component-wise in RGB. Equal-length lists and vectors convert element-wise and recursively, so a length such as `(lh 2)` moves inside its number; equal non-numbers stand still, and mismatched kinds, symbols or lengths return FROM unchanged. A matching pair in `etaf-animation-interpolators` is consulted first for PROGRESS below 1.

**Returns.** The converted value.

**Errors.** `error→ wrong-type-argument` with data `(number-or-marker-p VALUE)` when PROGRESS is not a number.

**Example.**

```elisp
(etaf-animation-interpolate '(lh 1) '(lh 4) 0.5)
;; ⇒ (lh 2.5)
```

**See also.** `etaf-animation-easings`, `etaf-animation-interpolators`, `etaf-transition`.

#### Variable: etaf-animation-easings

Alist of `(NAME . FUNCTION)` easing curves from progress to eased progress.

**Semantics.** The default names are `linear`, `ease`, `ease-in`, `ease-out` and `ease-in-out`, all mapping 0 to 0 and 1 to 1. An easing maps the fraction of the duration to the fraction of the distance, so an `ease-out` run covers most of the distance early and decelerates into the target. `etaf-transition` accepts a name from this alist or any function of one argument directly, so an application may add its own curve without changing the alist.

**See also.** `etaf-transition`, `etaf-animation-interpolate`.

#### Variable: etaf-animation-interpolators

Ordered `((PREDICATE . FUNCTION) ...)` conversions consulted before built-in interpolation.

**Semantics.** Each PREDICATE takes FROM and TO and decides whether its pair applies; the first match wins. The FUNCTION takes FROM, TO and PROGRESS and returns the value at that progress. The variable is read on each sample, so a registration made before creating the animation affects it. The hook is for shapes the built-in conversion does not cover, such as application records or unit-carrying values that should not convert element-wise.

**See also.** `etaf-animation-interpolate`.

### The shared clock

<!-- index: etaf-animation-frame-rate; etaf-animation-speed; etaf-animation-paused; sampling; frame rate -->

#### Variable: etaf-animation-frame-rate

Display clock rate in frames per second for running animations.

**Semantics.** The value is a positive number and defaults to 30. It is an upper bound, not a promise: each publication arms the next sample one period later, and a busy Emacs delivers fewer samples. One clock serves every running animation, and a change applies to the running clock. Keyboard input does not suppress sampling; elapsed time advances without catch-up frames. Lisp and redisplay share the Emacs main thread, so an expensive scene must lower this rate and bound the work done per sample.

**Errors.** A nonpositive or non-numeric value signals `etaf-animation-error` with data `("etaf-animation-frame-rate must be a positive number" VALUE)` when the next sample needs to be armed. Creating an animation while the value is invalid signals it to the caller; an invalid value changed while the clock runs stops every running animation and drops the clock after reporting the timer error once.

**See also.** `etaf-animation-speed`, `etaf-animation-paused`, `etaf-transition`.

#### Variable: etaf-animation-speed

Animation speed multiplier, a positive number; 1.0 is normal speed.

**Semantics.** The shared clock's time advances by the wall time between samples times this multiplier, so 2 runs every transition and frame sequence twice as fast and 0.5 half as fast. A change applies from the next sample and does not move a run's progress: a run half done stays half done and then advances at the new rate.

**Errors.** A nonpositive or non-numeric value signals `etaf-animation-error` with data `("etaf-animation-speed must be a positive number" VALUE)` where the clock reads it; a live change stops every running animation and drops the clock after reporting the timer error once.

**See also.** `etaf-animation-frame-rate`, `etaf-animation-paused`.

#### Variable: etaf-animation-paused

While non-nil, the shared clock stops advancing.

**Semantics.** Running animations hold their displayed value and keep their progress, and they stay subscribed. Clearing the variable resumes them exactly where they stopped; a run created while paused starts from its own first frame once the clock advances again. Pausing is not stopping: it resolves nothing, runs no completion callback, and leaves `etaf-animation-active-p` true.

**See also.** `etaf-animation-enabled`, `etaf-animation-speed`, `etaf-animation-active-p`.

### Stopping, finishing and the switch

<!-- index: etaf-animation-stop; etaf-animation-finish; etaf-animation-active-p; etaf-animation-enabled -->

#### Function: etaf-animation-stop (source)

Stop animating SOURCE and keep its value where it is.

**Arguments.** SOURCE is a ref returned by `etaf-transition` or `etaf-animation-frames`.

**Semantics.** The animation leaves the clock and keeps its displayed value; later writes to a transition's target no longer animate it. Stopping an already stopped animation is harmless. The animation stays known, so `etaf-animation-finish` and a repeated `etaf-animation-stop` still work.

**Returns.** The stopped SOURCE ref.

**Errors.** `error→ etaf-animation-error` with data `("Not an animated source" VALUE)` when SOURCE was not created by `etaf-transition` or `etaf-animation-frames`.

**See also.** `etaf-animation-finish`, `etaf-animation-active-p`, `etaf-transition`.

#### Function: etaf-animation-finish (source)

Stop animating SOURCE by applying its final value now.

**Arguments.** SOURCE is a ref returned by `etaf-transition` or `etaf-animation-frames`.

**Semantics.** A running transition writes its current target and runs its completion callback, exactly as a natural arrival would; a transition that is not running only stops. A frame sequence keeps the frame it currently displays. Either way the animation then leaves the clock and further target writes leave it alone.

**Returns.** The finished SOURCE ref.

**Errors.** `error→ etaf-animation-error` with data `("Not an animated source" VALUE)` when SOURCE was not created by `etaf-transition` or `etaf-animation-frames`.

**See also.** `etaf-animation-stop`, `etaf-animation-active-p`, `:on-complete`.

#### Function: etaf-animation-active-p (source)

Return non-nil while SOURCE's animation is subscribed to the shared clock.

**Arguments.** SOURCE is any value.

**Semantics.** A transition between runs and a transition that has landed are not active; a frame sequence is active while it cycles; a paused clock still counts its animations as active. A value that is not an animated ref returns nil rather than signaling, which makes the predicate safe for arbitrary sources.

**Returns.** Non-nil when the animation is subscribed to the clock.

**See also.** `etaf-animation-stop`, `etaf-animation-finish`, `etaf-animation-paused`.

#### Variable: etaf-animation-enabled

Whether animations interpolate over time; t by default.

**Semantics.** With a nil value, a new transition applies its target on the next write instead of starting a run, and a new frame sequence does not start at all. Running transitions snap to their target on the next sample and run their completion callback; running frame sequences hold their current frame. Setting the variable back to t does not restart anything that stopped, so it is the global off switch for time-driven behavior rather than a second pause. Applications use it to honor a reduced-motion preference while leaving every animation in place.

**See also.** `etaf-animation-paused`, `etaf-animation-stop`, `etaf-animation-active-p`.

## Ownership and interruption

<!-- index: Scope ownership; interruption; unmount; clock lifetime -->

Creating an animation during Component setup or `:bindings` registers its stop with the Component's Scope; unmounting the Runtime disposes the Scope, and the animation stops with its value frozen. A Scope-owned animation therefore needs no bookkeeping: the application writes the target, and the framework stops sampling when the component leaves. An animation created outside a Scope is the caller's responsibility; `etaf-animation-stop` releases its watch and lets the clock go when nothing else runs.

Interruption is the normal case, not an error. When the target changes while a transition is running, the run restarts from the displayed value with a fresh duration, so the value stays continuous and only its direction changes. Writing a target equal to the displayed value stops the run. Completing a run and then retargeting from the completion callback produces a loop with no jump and no scheduling bookkeeping: each run reports arrival once, and the callback starts the next.

A completion callback runs after the sample that completed the run is published, through the framework's next-tick queue ([Reactivity](reactivity.md#batches-and-ticks)), not inside the sample. It may therefore write refs, retarget the animation or update application state, just as an event callback may. An error signaled by a sample deactivates that animation and leaves the others running; the first such error is re-signaled after the sample batch, and an error from a completion callback follows the next-tick rules.

The clock is cheap because it is idle: no timer exists between a final stop and the next activation, and every sample does only the work the running animations prescribe. A frame sequence that changes one text value per sample and a transition that changes one size cost one reactive publication each; a sample that repaints a large scene costs more, which is what `etaf-animation-frame-rate` bounds.

## The example theatre

<!-- index: etaf-animation-example-open; example theatre -->

#### Function: etaf-animation-example-open ()

Mount the animation example theatre and return its buffer.

**Semantics.** The theatre fills its buffer with twenty panels that exercise frame sequences, transitions with retargeted loops, paint-heavy fields and text updates, plus a control bar for pausing the clock and changing its speed and frame rate, and a native editing pad that stays usable while every animation runs. The panels reflow from four columns to one as the window narrows. Only one theatre owns the global clock controls at a time; unmounting restores the previous values of `etaf-animation-paused`, `etaf-animation-speed` and `etaf-animation-frame-rate`. Interactive calls display the buffer. Use at least 28 columns by 12 lines.

**Returns.** The buffer holding the mounted theatre.

**See also.** `etaf-animation-stop`, `etaf-animation-paused`, `etaf-animation-frame-rate`.

## Errors and recovery

<!-- index: etaf-animation-error; invalid animation settings; timer errors -->

#### Error: etaf-animation-error

Invalid ETAF animation operation.

**Semantics.** The condition reports invalid construction arguments and operations on values that are not animations. Its data is a list whose first element names the problem, as in `("Invalid duration" -1)`, `("Unknown easing" bogus)`, `("FRAMES must be a nonempty sequence" nil)`, `("Invalid frame interval" 0)`, `("Not an animated source" REF)`, `("etaf-animation-frame-rate must be a positive number" 0)` and `("etaf-animation-speed must be a positive number" 0)`. The clock validates its settings when it arms the next sample, so an application that never sets the clock can meet the condition only through construction; a running clock stops its animations and reports the timer error once instead of repeating it. Recovery is to restore a valid setting and start a new animation.

**See also.** `etaf-transition`, `etaf-animation-frames`, `etaf-animation-stop`.

| Failure | What happens |
| --- | --- |
| A construction argument is invalid | `etaf-animation-error` or `wrong-type-argument` before any ref is created |
| A sample signals while several animations run | That animation stops; the others continue; the first error is re-signaled after the batch |
| The live frame rate or speed becomes invalid | Every running animation stops, the clock is dropped, one timer error is reported |
| A transition's target never changes | The ref rests at its current value; no timer runs |
| A Scope is disposed while its animation runs | The animation stops and keeps its value; later target writes do nothing |
| A transition that is not running is finished | It stops; no completion callback runs |
