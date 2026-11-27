;;; etaf.el --- Text application framework facade -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: ETAF contributors
;; Version: 0.3.17
;; Package-Requires: ((emacs "29.1") (ebox "3.1.6") (ecss "0.1.0"))
;; Keywords: ui, tools, convenience
;; URL: https://github.com/emacs-taf/etaf

;;; Commentary:

;; The ETAF framework: a retained view layer that compiles a declarative
;; form into boxes, lays them out, and paints them into an Emacs buffer.
;;
;; `pmset' is optional: on macOS it only annotates latency records with
;; the local power state, and its absence leaves that field unknown.
;;
;; Public API
;;
;; Load this package with (require 'etaf) after adding the repository
;; root to load-path.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; implementations and precise
;; docstrings remain beside their definitions.  The ETAF Reference Manual contains workflows.
;;
;; Macro: etaf-action-define (name arguments &rest body)
;;;###autoload (autoload 'etaf-action-define "etaf" nil nil 'macro)
;; Define and register named Action NAME with ARGUMENTS and BODY.
;;
;; The generated function receives RUNTIME as its first argument when called
;; through `etaf-dispatch'.
;;
;; Error: etaf-action-error
;; Invalid ETAF Action
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-async-error
;; Invalid asynchronous adapter or timeout; parent is etaf-reactive-error.
;; Error: etaf-async-timeout
;; Asynchronous wait exceeded its timeout; parent is etaf-async-error.
;; Error: etaf-async-cancelled
;; Pending work was cancelled; parent is etaf-async-error.
;; These conditions are recorded in Resource/Data error state. Cancellation or
;; timeout never certifies rollback of external writes.
;;
;; Function: etaf-async (start)
;;;###autoload (autoload 'etaf-async "etaf" nil nil)
;; Describe a lazy asynchronous loader using START.
;; Return this value from a Resource loader or Data source operation.  START
;; receives RESOLVE and REJECT functions and may return a zero-argument cancel
;; function.  It starts work without blocking and completes once: RESOLVE takes
;; the ordinary loader result; REJECT takes Emacs condition data.  Returning nil
;; means the work cannot be cancelled, but obsolete completion is still ignored.
;; The owning Resource or Controller starts and releases the operation; this is
;; not a standalone promise.  Native timers and processes may call completion
;; functions later on the Emacs thread.
;;
;; Function: etaf-process-run (command &key callback timeout environment directory (output 'string) (coding 'utf-8-unix) name)
;;;###autoload (autoload 'etaf-process-run "etaf" nil nil)
;; Run COMMAND, a list of a program and its arguments, without blocking and
;; return a job.  CALLBACK receives one result plist when the job settles:
;; :status is `exit', `signal', `timeout' or `failed' (the program could not
;; start), :exit the exit code or signal number, :output stdout as a string
;; or, with OUTPUT `json', its parsed value (objects as plists, arrays as
;; lists, null as nil, false as :false; nil when empty or invalid), :stderr
;; the complete standard error text and :message a description for timeouts
;; and failures.  Both streams are read completely after exit.  The callback
;; never runs before this function returns, runs at most once and never
;; after `etaf-process-cancel'.  TIMEOUT seconds stops the process and
;; settles the job as `timeout'.  ENVIRONMENT is a list of "NAME=VALUE"
;; strings overriding `process-environment', DIRECTORY the working
;; directory, CODING the decoding of both streams and NAME the process label.
;; What an exit code or output field means stays with the caller.  To load
;; a Resource or Data source, return (etaf-async (lambda (resolve reject)
;; ...)) whose START runs the job and returns a canceller calling
;; `etaf-process-cancel'.  Long-lived interactive processes are out of scope.
;;
;; Function: etaf-process-cancel (job)
;;;###autoload (autoload 'etaf-process-cancel "etaf" nil nil)
;; Stop JOB from `etaf-process-run' without running its callback; return
;; non-nil when JOB had not settled yet.  Its process is deleted.
;;
;; Function: etaf-process-live-p (job)
;;;###autoload (autoload 'etaf-process-live-p "etaf" nil nil)
;; Return non-nil while JOB has neither settled nor been cancelled.
;;
;; Function: etaf-action-redefine-run (function)
;;;###autoload (autoload 'etaf-action-redefine-run "etaf" nil nil)
;; Run FUNCTION while allowing intentional Action redefinition.
;;
;; Normal duplicate registrations remain errors.  This dynamic authoring
;; boundary replaces only the process-global name binding used by future
;; `etaf-dispatch' calls; it does not flush or rerender mounted Runtimes.
;;
;; Function: etaf-activate (&optional runtime)
;;;###autoload (autoload 'etaf-activate "etaf" nil t)
;; Dispatch `press' for the focused Host, or the interaction boundary at point.
;;
;; RUNTIME is the mounted Runtime to activate, or nil for the current buffer.
;; Live keyboard focus wins even when publication or inspection moved point;
;; without focus, position lookup uses committed Ebox node keymaps. Native
;; RET/return activation follows the same rule. Pointer presses keep their
;; clicked target. Enabled press handlers are
;; native activation/navigation targets; disabled or callbackless controls block
;; ancestor activation. Ebox remains the focus and native keymap authority.
;;
;; Function: etaf-transition (source &key (duration 0.2) (easing 'ease-out) (delay 0) name on-complete)
;;;###autoload (autoload 'etaf-transition "etaf" nil nil)
;; Return a ref that follows reactive SOURCE over DURATION seconds.
;; SOURCE is a ref, computed or zero-argument function as in `etaf-watch'; the
;; returned ref starts at SOURCE's current value.  Every later SOURCE change
;; restarts the interpolation from the value currently shown, so interruption
;; never jumps.  DURATION of zero with zero DELAY applies the target at once.
;; DELAY waits that many seconds on the shared clock before interpolating.
;; EASING is a name from `etaf-animation-easings' or a function.  ON-COMPLETE
;; runs after a run reaches SOURCE.  Read the returned ref with `etaf-value'
;; wherever the display follows it.  Created during Component setup or
;; `:bindings', the animation belongs to its Scope and stops on disposal;
;; otherwise call `etaf-animation-stop'.  NAME labels diagnostics, and invalid
;; inputs signal `etaf-animation-error'.
;;
;; Function: etaf-spring (source &key stiffness damping mass (precision 0.01) preset name on-complete)
;;;###autoload (autoload 'etaf-spring "etaf" nil nil)
;; Return a ref that follows reactive SOURCE with damped spring physics.
;; Unlike `etaf-transition', changing SOURCE mid-flight preserves the current
;; velocity so rapid retargeting carries natural momentum.  PRESET names a
;; bundle in `etaf-animation-spring-presets'; explicit STIFFNESS, DAMPING or
;; MASS override the preset (or defaults 180, 22, 1).  PRECISION is the
;; positive settling threshold.  Supports numbers, color strings and equal-shape
;; lists or vectors containing them.  Scope ownership, ON-COMPLETE and
;; `etaf-animation-error' validation follow `etaf-transition'.
;;
;; Function: etaf-animation-frames (frames &key (interval 0.1) (loop t) name on-complete)
;;;###autoload (autoload 'etaf-animation-frames "etaf" nil nil)
;; Return a ref cycling through FRAMES every INTERVAL seconds.
;; FRAMES is a nonempty list or vector shown in order; LOOP nil stops on the
;; last frame and runs ON-COMPLETE.  Read the returned ref with `etaf-value'
;; wherever the display follows it.  Scope ownership and `etaf-animation-error'
;; validation follow `etaf-transition'.
;;
;; Function: etaf-animation-tick (callback &key (interval 0) name)
;;;###autoload (autoload 'etaf-animation-tick "etaf" nil nil)
;; Subscribe CALLBACK (DT ELAPSED) to the shared clock and return an elapsed
;; ref.  INTERVAL is a nonnegative minimum spacing in animation seconds between
;; invocations; zero runs on every tick.  The returned ref holds elapsed
;; animation seconds and accepts `etaf-animation-stop', `etaf-animation-finish'
;; and `etaf-animation-active-p'.  Scope ownership follows `etaf-transition'.
;;
;; Function: etaf-animation-timeline (steps &key loop name on-complete)
;;;###autoload (autoload 'etaf-animation-timeline "etaf" nil nil)
;; Run declarative STEPS on the shared clock and return its step-index ref.
;; STEPS is a nonempty list of step plists: `(:delay SECONDS)', `(:call FN)',
;; `(:run FN :duration SECONDS [:easing EASING])' and `(:parallel STEP-LIST)'.
;; LOOP non-nil repeats from the first step; otherwise ON-COMPLETE runs after
;; the final step.  `etaf-animation-finish' completes remaining steps in order
;; and runs ON-COMPLETE; when `etaf-animation-enabled' is nil, a non-looping
;; timeline resolves its steps immediately.  Scope ownership follows
;; `etaf-transition'.
;;
;; Function: etaf-animation-stop (source)
;;;###autoload (autoload 'etaf-animation-stop "etaf" nil nil)
;; Stop animating SOURCE, a ref returned by `etaf-transition', `etaf-spring',
;; `etaf-animation-frames', `etaf-animation-tick' or `etaf-animation-timeline', and keep
;; its value where it is.  Later writes to a transition or spring target no
;; longer animate it.  A non-animated SOURCE signals `etaf-animation-error'.
;;
;; Function: etaf-animation-finish (source)
;;;###autoload (autoload 'etaf-animation-finish "etaf" nil nil)
;; Stop animating SOURCE by applying its final value now.
;; A transition or spring applies its current target and runs its completion
;; callback when running; a running timeline finishes its remaining steps in
;; order and runs its completion callback; a frame sequence or tick keeps its
;; current value.
;;
;; Function: etaf-animation-active-p (source)
;;;###autoload (autoload 'etaf-animation-active-p "etaf" nil nil)
;; Return non-nil while SOURCE's animation is subscribed to the shared clock.
;; A resting transition or spring and an unknown source return nil.
;;
;; Function: etaf-animation-interpolate (from to progress)
;;;###autoload (autoload 'etaf-animation-interpolate "etaf" nil nil)
;; Return the value at PROGRESS (0 to 1) between FROM and TO.
;; PROGRESS 1 returns TO unchanged.  Numbers convert arithmetically, color
;; strings blend in `etaf-animation-color-space', and equal-length lists or
;; vectors convert element-wise while equal non-numbers stand still, so Ebox
;; length values such as `(lh 2)' interpolate in place.  Entries in
;; `etaf-animation-interpolators' run first.
;;
;; Function: etaf-animation-quantize (value step)
;;;###autoload (autoload 'etaf-animation-quantize "etaf" nil nil)
;; Snap numeric elements of VALUE to multiples of positive STEP.
;; Lists and vectors quantize element-wise while non-numbers stay unchanged,
;; preventing fine-grained face or image cache churn.  Non-positive STEP
;; signals `etaf-animation-error'.
;;
;; Variable: etaf-animation-enabled
;; Whether animations interpolate over time.  When nil, new transitions and
;; springs apply their target immediately, running transitions and springs snap
;; to their target, non-looping timelines finish immediately, and frame
;; sequences or ticks hold their current value.  Setting it back to t does not
;; restart stopped runs.
;;
;; Variable: etaf-animation-frame-rate
;; Display clock rate in frames per second for running animations.
;; A positive upper bound; one clock serves every running animation.  Changing it
;; applies to the running clock.
;;
;; Each publication yields a full period before the next sample.  Keyboard input
;; does not suppress sampling; elapsed time advances without catch-up frames.
;; Lisp and redisplay still share Emacs's main thread, so expensive scenes must
;; use a lower rate and bounded per-frame work.
;;
;; Variable: etaf-animation-paused
;; While non-nil the shared clock stops advancing: running animations hold
;; their displayed value and keep their progress, and clearing it resumes
;; exactly where they stopped.  Unlike `etaf-animation-enabled', pausing does
;; not resolve or stop a run.
;;
;; Variable: etaf-animation-speed
;; Animation speed multiplier, a positive number.  2 advances every animation
;; twice as fast and 0.5 half as fast; a change applies from the next tick
;; without moving a run's progress.
;;
;; Variable: etaf-animation-color-space
;; Color space used by `etaf-animation-interpolate': `rgb' (default) or `oklab'.
;;
;; Variable: etaf-animation-pause-hidden
;; When non-nil, animations owned by a mounted Runtime hold their progress
;; while that Runtime's buffer has no visible window, resuming seamlessly once
;; shown again.  Default nil.
;;
;; Variable: etaf-animation-spring-presets
;; Alist of (NAME . PLIST) spring presets (`snappy', `gentle', `bouncy',
;; `stiff') supplying `:stiffness', `:damping' and `:mass' for `etaf-spring'.
;;
;; Variable: etaf-animation-easings
;; Alist of (NAME . FUNCTION) easing curves mapping progress 0..1 to eased
;; progress.  `etaf-transition' accepts a name from this alist or a function.
;;
;; Variable: etaf-animation-interpolators
;; Ordered ((PREDICATE . FUNCTION) ...) consulted before built-in conversion.
;; PREDICATE takes FROM and TO; FUNCTION takes FROM, TO and PROGRESS.
;;
;; Error: etaf-animation-error
;; Invalid ETAF animation operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-app-open (name view &key state on-fit on-close background foreground (cursor 'inherit) mode-line (display t) mount-options meta)
;;;###autoload (autoload 'etaf-app-open "etaf" nil nil)
;; Open VIEW as the application buffer NAME and return the buffer.
;; An application is one named buffer showing one mounted View; this is its
;; lifecycle entry, replacing per-application buffer setup, resize hooks and
;; face remapping.  An open application of the same NAME closes first.  The
;; buffer gets canvas settings (truncated lines without hscroll or a
;; truncation glyph, zero scroll margins, no line numbers) and shows through
;; DISPLAY: t selects it in the selected window regardless of the user's
;; `display-buffer' rules, a function receives the buffer, nil leaves it
;; undisplayed (useful in tests).
;; ON-FIT, a function of the display window, runs in the buffer before VIEW
;; mounts and again, in one reactive batch, after each settled change of
;; that window's size or identity and after text scaling, including under a
;; fixed viewport; transient UI borrowing lines does not run it.  Fit page
;; sizes, row budgets or a fixed canvas there instead of in a resize hook.
;; ON-CLOSE, a function of no arguments, runs once in the buffer when the
;; buffer is killed, `etaf-app-close' closes it or a reopen replaces it,
;; while VIEW is still mounted; Emacs exit is not covered, so persist state
;; that must survive it from `kill-emacs-hook'.  BACKGROUND and FOREGROUND,
;; each a colour string, ref, computed or zero-argument function, remap the
;; default face so cells the View does not paint match it; reactive sources
;; repaint when they change.  CURSOR, unless `inherit' (the default), sets
;; `cursor-type' before mounting, which is the cursor the Runtime restores.
;; MODE-LINE nil (the default) hides the mode line, t keeps it and another
;; value becomes `mode-line-format'.  STATE is what `etaf-app-state' returns.
;; MOUNT-OPTIONS, a plist or a function of the display window (nil when
;; undisplayed) returning one, go to `etaf-mount'; a function runs in the
;; buffer after ON-FIT, so a fixed viewport height can come from the fitted
;; state.  META, when non-nil, supplies a Runtime metadata plist (identifying
;; `:app', `:kind', `:uri', `:title' or reactive sources) merged into `:meta'
;; mount options.  When mounting fails the application closes, the buffer is
;; killed and the error propagates.  Declare keys with the root Host's `:keys'.
;;
;; Function: etaf-app-close (&optional buffer-or-name)
;;;###autoload (autoload 'etaf-app-close "etaf" nil t)
;; Close the application in BUFFER-OR-NAME, by default the current buffer.
;; Run its close function, unmount its View and kill the buffer; return t.
;; A buffer without an open application signals `user-error'.  A close
;; function error propagates after the buffer is gone; killing the buffer
;; directly reports that error as a message instead.
;;
;; Function: etaf-app-state (&optional buffer-or-name)
;;;###autoload (autoload 'etaf-app-state "etaf" nil nil)
;; Return the STATE given to `etaf-app-open' for the open application in
;; BUFFER-OR-NAME (default the current buffer), or nil.  Commands use it to
;; find their application from the buffer they run in; the close function
;; still sees it.
;;
;; Function: etaf-app-buffer (name)
;;;###autoload (autoload 'etaf-app-buffer "etaf" nil nil)
;; Return the buffer of the open application NAME, or nil.  An entry command
;; that should reselect an open application instead of reopening it checks
;; this first.
;;
;; Function: etaf-pip-open (id view &key title parent (size 'medium) (corner 'bottom-right) theme on-return on-close on-resize on-size-change on-corner-change)
;;;###autoload (autoload 'etaf-pip-open "etaf" nil nil)
;; Open a floating adaptive Picture-in-Picture window for symbol ID showing
;; VIEW and return its buffer.  Recycles graphical child frames safely,
;; exposes a draggable adaptive header bar and 4px resize border, and tracks
;; live window bounds without pinning the viewport so manual drag-resizing
;; reflows the View and any embedded GPU video layer continuously.
;;
;; Function: etaf-pip-close (id &optional restore-focus)
;;;###autoload (autoload 'etaf-pip-close "etaf" nil nil)
;; Close floating Picture-in-Picture window ID, run its ON-CLOSE callback,
;; park its graphical child frame for reuse and return non-nil if it was open.
;;
;; Function: etaf-pip-active-p (id)
;;;###autoload (autoload 'etaf-pip-active-p "etaf" nil nil)
;; Return non-nil when floating Picture-in-Picture window ID is currently live.
;;
;; Function: etaf-pip-bounds (id)
;;;###autoload (autoload 'etaf-pip-bounds "etaf" nil nil)
;; Return reactive live inner bounds plist of Picture-in-Picture window ID
;; (`:width-px', `:height-px', `:cols', `:rows', `:cell-w', `:cell-h', `:size'
;; and `:corner').
;;
;; Function: etaf-pip-frame (id)
;;;###autoload (autoload 'etaf-pip-frame "etaf" nil nil)
;; Return the floating child frame of Picture-in-Picture window ID, or nil.
;;
;; Function: etaf-pip-buffer (id)
;;;###autoload (autoload 'etaf-pip-buffer "etaf" nil nil)
;; Return the mounted buffer of Picture-in-Picture window ID, or nil.
;;
;; Function: etaf-pip-cycle-size (id)
;;;###autoload (autoload 'etaf-pip-cycle-size "etaf" nil nil)
;; Cycle Picture-in-Picture window ID among `small', `medium' and `large'.
;;
;; Function: etaf-pip-cycle-corner (id)
;;;###autoload (autoload 'etaf-pip-cycle-corner "etaf" nil nil)
;; Dock Picture-in-Picture window ID clockwise across the parent frame corners
;; while preserving any manually dragged dimensions.
;;
;; Function: etaf-pip-refresh-chrome (id)
;;;###autoload (autoload 'etaf-pip-refresh-chrome "etaf" nil nil)
;; Repaint Picture-in-Picture window ID's background, border and header bar.
;;
;; Function: etaf-fullscreen-mode (&optional buffer)
;;;###autoload (autoload 'etaf-fullscreen-mode "etaf" nil nil)
;; Return BUFFER's reactive fullscreen mode: nil, `window' or `frame'.
;; BUFFER defaults to the current buffer.
;;
;; Function: etaf-fullscreen-active-p (&optional buffer)
;;;###autoload (autoload 'etaf-fullscreen-active-p "etaf" nil nil)
;; Return non-nil when BUFFER is currently in `window' or `frame' fullscreen.
;;
;; Function: etaf-fullscreen-enter (&optional mode buffer &key (hide-mode-line t) on-change)
;;;###autoload (autoload 'etaf-fullscreen-enter "etaf" nil nil)
;; Enter fullscreen MODE (`window' or `frame') for BUFFER.
;; `window' hides the buffer's mode-line in place without changing splits or OS
;; spaces; `frame' saves window splits and the frame's `fullscreen' parameter,
;; collapses to one window, enters OS fullscreen on graphical frames, and
;; restores everything on exit or buffer kill.
;;
;; Function: etaf-fullscreen-exit (&optional buffer)
;;;###autoload (autoload 'etaf-fullscreen-exit "etaf" nil nil)
;; Exit fullscreen for BUFFER, restoring mode-line, splits and frame state.
;;
;; Function: etaf-fullscreen-toggle (&optional mode buffer &key (hide-mode-line t) on-change)
;;;###autoload (autoload 'etaf-fullscreen-toggle "etaf" nil nil)
;; Toggle fullscreen MODE (`window' or `frame') for BUFFER, switching directly
;; between tiers or exiting when MODE is already active.
;;
;; Function: etaf-appearance ()
;;;###autoload (autoload 'etaf-appearance "etaf" nil nil)
;; Return the appearance inherited from the nearest host, or the frame mode.
;;
;; The value is `light' or `dark'.  A host that renders a surface of a
;; different appearance than its frame (a light panel inside a dark frame)
;; provides it with `etaf-appearance-provide'; a provided ref is read
;; reactively, so the Components below re-render when the host switches.
;;
;; A palette derived from faces reads this inside its own computation, the one
;; a Theme computed or a render holds: Ebox resolves colors while a View
;; renders, so an application that read the faces once at mount keeps the
;; colors of the theme that was active then.  Reading this registers the
;; switch Emacs reports through `enable-theme-functions' and recomputes the
;; palette from the new faces.
;;
;; Function: etaf-appearance-mode (&optional override)
;;;###autoload (autoload 'etaf-appearance-mode "etaf" nil nil)
;; Return a computed appearance mode that follows the host.
;;
;; OVERRIDE, when non-nil, is a ref holding `light' or `dark' and wins; that
;; is what an application's own light/dark switch writes.  The computed tracks
;; the host appearance, so a Component that reads it re-renders when the host
;; switches.
;;
;; Function: etaf-appearance-provide (appearance)
;;;###autoload (autoload 'etaf-appearance-provide "etaf" nil nil)
;; Provide APPEARANCE (`light' or `dark') to the current Component subtree.
;;
;; APPEARANCE may be a ref or a computed, so a host that switches appearance
;; republishes the subtree without re-rendering it.  An invalid value signals
;; `etaf-context-error' before anything is provided.
;;
;; Function: etaf-behavior-context-info (context)
;;;###autoload (autoload 'etaf-behavior-context-info "etaf" nil nil)
;; Return CONTEXT's installation facts as a fresh plist.
;; CONTEXT comes from `etaf-current-behavior-context` during an installer.
;; Keys are :runtime (the owning Runtime), :host-ref (the effective Host reference)
;; and :properties (installation-time semantic Host properties).
;; The plist and property container are fresh; contained values retain identity
;; and must be treated as read-only. These facts remain readable after cleanup,
;; but do not certify that the Host is still mounted.
;; Use Runtime public queries for committed state, and return installer cleanup
;; to release resources on replacement, rollback or unmount.
;; Invalid CONTEXT signals `etaf-behavior-error`.
;;
;; Function: etaf-behavior-create (name &rest attributes)
;;;###autoload (autoload 'etaf-behavior-create "etaf" nil nil)
;; Create a Behavior spec named NAME from keyword ATTRIBUTES.
;;
;; The reserved `:install' attribute is an optional zero-argument installer that
;; returns nil or a cleanup function; it is not merged into Host properties.
;;
;; Error: etaf-behavior-error
;; Invalid ETAF Behavior
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Macro: etaf-batch (&rest body)
;;;###autoload (autoload 'etaf-batch "etaf" nil nil 'macro)
;; Evaluate BODY in one reactive batch and return its last value, or nil for
;; an empty body. Nested batches join the outermost scope. Use for several
;; related state writes; the function form and failure contract follow below.
;;
;; Function: etaf-call-with-batch (function)
;;;###autoload (autoload 'etaf-call-with-batch "etaf" nil nil)
;; Call zero-argument FUNCTION and return its result after pending reactive
;; work finishes. Ref writes are immediately readable; existing observers and
;; Runtime updates wait for the outermost batch. Events and Actions use this
;; same boundary, so explicit batches compose with their callbacks.
;; If FUNCTION errors or quits, pending work still drains before its original
;; condition is re-signaled. Written refs remain changed; the batch provides
;; neither rollback nor atomic publication across Runtimes. If only draining
;; fails, that condition signals. FUNCTION must be callable; use outside
;; rendering on the main Emacs event loop. This scope is synchronous: later
;; asynchronous callbacks must establish their own batch. No resource or
;; Runtime ownership is transferred to the batch.
;;
;; Function: etaf-next-tick (function)
;;;###autoload (autoload 'etaf-next-tick "etaf" nil nil)
;; Call zero-argument FUNCTION after pending reactive work is published and
;; return nil. Inside a batch, event callback or effect, FUNCTION runs once
;; the outermost batch drained and mounted Runtimes wrote their buffers, so
;; Hosts created by earlier writes have positions and scroll ranges; use it
;; to scroll to or focus a row that a callback just added. Outside a batch
;; FUNCTION runs immediately. Queued functions run in order, also after a
;; failed drain; the first error they signal is re-signaled. Not during
;; rendering.
;;
;; Error: etaf-component-call-error
;; Invalid ETAF Component call
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-check-prop (property value valid-p expected &optional component)
;;;###autoload (autoload 'etaf-check-prop "etaf" nil nil)
;; Return VALUE when VALID-P is non-nil; otherwise report an input error.
;; PROPERTY is a keyword and EXPECTED is a description string. COMPONENT names
;; the input owner, defaulting to the Component whose :validate form is running.
;; Helpers outside validation supply COMPONENT explicitly. Checks must not mutate
;; input values or perform external effects. Failure signals etaf-component-call-error
;; naming the component, property, received value and expectation. Large values
;; are abbreviated; no resources are copied or owned.
;; Use (etaf-check-prop :count count (natnump count) "a nonnegative integer")
;; in a Component's ordinary Elisp :validate form. Malformed check metadata
;; signals etaf-component-definition-error.
;;
;; Error: etaf-component-definition-error
;; Invalid ETAF Component definition
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-component-redefine-run (function)
;;;###autoload (autoload 'etaf-component-redefine-run "etaf" nil nil)
;; Run FUNCTION while allowing intentional Component redefinition.
;;
;; Duplicate Component definitions remain errors except for unchanged declarations
;; reloaded from the same library, which keep their original definition. Authoring
;; tools use this boundary after disposing the old Runtime to replace a declaration
;; or refresh its captured values, even when its source text is unchanged.
;;
;; Function: etaf-component-set-styles (name styles)
;;;###autoload (autoload 'etaf-component-set-styles "etaf" nil nil)
;; Replace the static style form for Component NAME with STYLES.
;;
;; STYLES must use the same `((SELECTOR PROPERTY VALUE ...) ...)'
;; contract accepted by `etaf-define-component'.  This small runtime authoring
;; hook is useful to tools which reload a stylesheet without redefining the
;; Component itself, such as a source/preview playground.  The next mount or
;; render observes the replacement; existing mounted runtimes are not flushed
;; implicitly.
;;
;; Function: etaf-computed (getter &key test name)
;;;###autoload (autoload 'etaf-computed "etaf" nil nil)
;; Create a lazy cached value computed by zero-argument GETTER.
;;
;; TEST optionally compares old and new values.  NAME optionally labels the
;; computed value.  Mounted consumers retain their publication when all their
;; reactive inputs compare unchanged.  A computed created during Component
;; setup runs its getter in that Component's environment on every later run,
;; so `etaf-inject', `etaf-current-runtime' and `etaf-viewport' reads inside
;; it keep working after the first run.  Unobserved computations stay lazy.
;;
;; Function: etaf-computed-p (x)
;;;###autoload (autoload 'etaf-computed-p "etaf" nil nil)
;;
;;
;; Error: etaf-context-error
;; Invalid ETAF Context operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-current-behavior-context ()
;;;###autoload (autoload 'etaf-current-behavior-context "etaf" nil nil)
;; Return the Behavior context active during an installer, or nil.
;;
;; Function: etaf-current-prop (name)
;;;###autoload (autoload 'etaf-current-prop "etaf" nil nil)
;; Return current Component prop NAME.
;;
;; NAME is normally an ordinary symbol used by the `:setup' lexical shorthand.
;; The function is also useful to code that deliberately avoids that shorthand.
;;
;; Function: etaf-current-slot (name &optional fallback)
;;;###autoload (autoload 'etaf-current-slot "etaf" nil nil)
;; Return composable children for slot NAME, or FALLBACK when absent.
;; Supplied children retain caller Context and style ownership when passed,
;; appended or wrapped as View children. Treat each child value as opaque;
;; use only during Component render and do not retain beyond its Runtime.
;;
;; Function: etaf-current-slots ()
;;;###autoload (autoload 'etaf-current-slots "etaf" nil nil)
;; Return the current Component's slot alist of opaque composable children.
;; Values follow etaf-current-slot ownership and lifecycle constraints.
;;
;; Function: etaf-data-cancel (controller)
;;;###autoload (autoload 'etaf-data-cancel "etaf" nil nil)
;; Cancel CONTROLLER's pending request without stopping it; return CONTROLLER.
;; Loaded items remain available.  A cancelled write has unknown external
;; certainty unless its provider already reported a committed result; cancelling
;; its subsequent refresh never changes that known result.
;;
;; Function: etaf-data-controller (source &key query (page 1) (page-size 20) selection auto-load name item-key owner-scope initial-result timeout)
;;;###autoload (autoload 'etaf-data-controller "etaf" nil nil)
;; Create a reactive Data Controller for SOURCE.
;;
;; QUERY, PAGE, PAGE-SIZE, result ITEMS, TOTAL, STATUS, ERROR, and SELECTION are
;; stored in refs.  When AUTO-LOAD is non-nil, the controller loads immediately
;; and reloads after query or pagination refs change.  NAME optionally labels the
;; controller for diagnostics.  ITEM-KEY identifies selection and selected-item
;; state; it defaults to the source's `:item-key' capability when available.
;; When OWNER-SCOPE is supplied, or when a current ETAF Scope exists, the
;; controller's own child Scope is disposed with that owner; otherwise it keeps
;; the detached Scope behavior.  INITIAL-RESULT may be a normalized source result
;; for QUERY/PAGE/PAGE-SIZE; it seeds a successful Controller without another
;; load.  INITIAL-RESULT and AUTO-LOAD are mutually exclusive.
;; TIMEOUT is nil or positive seconds for each asynchronous operation.
;; Loads retain previously accepted items while refreshing, after error and after
;; cancellation.  Stopping the Controller cancels pending work and ignores late
;; completion without undoing external writes.
;;
;; Function: etaf-data-error (controller)
;;;###autoload (autoload 'etaf-data-error "etaf" nil nil)
;; Return CONTROLLER's observable error ref; read its value with `etaf-value`.
;; The value is nil without a captured failure, otherwise condition data.
;; The controller owns this ref; consumers observe it and do not write it.
;;
;; Error: etaf-data-error
;; Invalid ETAF data operation; parent condition for Data contract failures.
;; Catch with condition-case. This condition is distinct from calling the
;; same-named reader function to inspect a controller's captured failure.
;;
;; Function: etaf-data-item-identity (controller item)
;;;###autoload (autoload 'etaf-data-item-identity "etaf" nil nil)
;; Return ITEM's stable selection identity in CONTROLLER.
;;
;; The identity comes from the Controller's explicit `:item-key', then from its
;; source capability, and otherwise is ITEM itself.
;;
;; Function: etaf-data-items (controller)
;;;###autoload (autoload 'etaf-data-items "etaf" nil nil)
;; Return CONTROLLER's loaded items ref.
;;
;; Function: etaf-data-load (controller)
;;;###autoload (autoload 'etaf-data-load "etaf" nil nil)
;; Start CONTROLLER's source load; return the synchronous result or nil pending.
;; Loading before first success uses `loading'; later reads use `refreshing' and
;; retain items.  Completion publishes `success', `error' or `cancelled'.
;; Synchronous source errors are recorded and re-signaled.  Asynchronous source
;; errors are recorded; rendering errors still signal from completion.
;; A new load cancels the old request.  Superseding a pending write records unknown
;; external certainty; it does not imply rollback.
;;
;; Function: etaf-data-memory-source (items &key id-key name)
;;;###autoload (autoload 'etaf-data-memory-source "etaf" nil nil)
;; Create an in-memory Data source over ITEMS.
;;
;; ID-KEY identifies records for `replace', `update', and `delete' mutations,
;; and is exposed to Data Controllers as the source's stable item identity.
;; NAME optionally labels the source for diagnostics.
;; Queries may be nil, a predicate, a search string, a plist, an alist, or an
;; exact value.  Supported mutations are `insert', `replace', `update', `delete',
;; and `reset'.
;;
;; Function: etaf-data-mutate (controller operation payload)
;;;###autoload (autoload 'etaf-data-mutate "etaf" nil nil)
;; Run source OPERATION with PAYLOAD and then reconcile its result.
;; Synchronous writes return their result.  An asynchronous write returns nil
;; while pending; inspect status and mutation outcome after completion.  A second
;; write is rejected while the first write is pending.  Cancellation, timeout or
;; an unclassified external failure never implies that the write was rolled back.
;;
;; Function: etaf-data-mutate-many (controller operations)
;;;###autoload (autoload 'etaf-data-mutate-many "etaf" nil nil)
;; Apply OPERATIONS to CONTROLLER's source and reconcile once.
;; OPERATIONS is a non-empty list of (OPERATION PAYLOAD) pairs applied in order.
;; A source with the optional `:mutate-batch' capability applies the whole list
;; atomically; any other source runs the v1 `:mutate' callback for each pair.
;; The committed result is a plist whose `:operation' is `mutate-many' with
;; `:results' in order and `:changes' when the results report it.  Signals
;; `etaf-data-error' for an empty or malformed list or an asynchronous source
;; result.  A signaled operation stops the batch, publishes an external-unknown
;; failure outcome carrying the completed results under `:results', and is
;; re-signaled after publication.
;;
;; Function: etaf-data-mutation-outcome (controller)
;;;###autoload (autoload 'etaf-data-mutation-outcome "etaf" nil nil)
;; Return a copy of CONTROLLER's latest mutation outcome envelope.
;;
;; The envelope contains `:certainty' (`committed', `rolled-back', or
;; `external-unknown'), the raw mutation result, and an opaque reconciliation
;; token.  A batch failure additionally carries the completed prefix under
;; `:results'.  While an asynchronous write is outstanding, :pending-p is non-nil and
;; certainty is external-unknown.  After completion :pending-p is nil or absent.
;; The reader tracks mutation changes in reactive Views and effects; callers
;; do not write its state.  Treat the token as opaque.  No outcome means
;; no mutation has started.  Stopped Controllers reject access.
;;
;; Function: etaf-data-next-page (controller)
;;;###autoload (autoload 'etaf-data-next-page "etaf" nil nil)
;; Move CONTROLLER to the next page and return the new page.
;;
;; Function: etaf-data-page (controller)
;;;###autoload (autoload 'etaf-data-page "etaf" nil nil)
;; Return CONTROLLER's page ref.
;;
;; Function: etaf-data-page-size (controller)
;;;###autoload (autoload 'etaf-data-page-size "etaf" nil nil)
;; Return CONTROLLER's page-size ref.
;;
;; Function: etaf-data-previous-page (controller)
;;;###autoload (autoload 'etaf-data-previous-page "etaf" nil nil)
;; Move CONTROLLER to the previous page and return the new page.
;;
;; Function: etaf-data-query (controller)
;;;###autoload (autoload 'etaf-data-query "etaf" nil nil)
;; Return CONTROLLER's query ref.
;;
;; Function: etaf-data-reconciliation-state (controller)
;;;###autoload (autoload 'etaf-data-reconciliation-state "etaf" nil nil)
;; Return CONTROLLER's current reconciliation state symbol, if any.
;; A committed mutation starts `reconciliation-pending'; its refresh ends in
;; `reconciled' or `reconciliation-error'.  Other outcomes report
;; `rolled-back' or `external-unknown'.  No mutation yet returns nil.
;;
;; Function: etaf-data-retry-reconciliation (controller)
;;;###autoload (autoload 'etaf-data-retry-reconciliation "etaf" nil nil)
;; Reload a committed mutation without replaying its source mutation.
;;
;; The operation is allowed only for a committed outcome whose reconciliation
;; token is pending or failed; unknown and rolled-back outcomes are deliberately
;; not retried.
;; Return the synchronous loaded page, or nil when asynchronous work is pending
;; or no retry is eligible.  Observe status and `etaf-data-reconciliation-state'
;; to distinguish completion.  No automatic write retry is performed.
;;
;; Function: etaf-data-reload (controller)
;;;###autoload (autoload 'etaf-data-reload "etaf" nil nil)
;; Reload CONTROLLER; return the synchronous result or nil while pending.
;;
;; Function: etaf-data-select (controller identity &optional (selected-p t))
;;;###autoload (autoload 'etaf-data-select "etaf" nil nil)
;; Select or deselect IDENTITY in CONTROLLER.
;;
;; When SELECTED-P is nil, remove IDENTITY from the selection.
;;
;; Function: etaf-data-select-one (controller identity)
;;;###autoload (autoload 'etaf-data-select-one "etaf" nil nil)
;; Replace CONTROLLER selection with the single IDENTITY.
;;
;; Use this explicit single-selection operation for tables and list views.  The
;; existing `etaf-data-select' API remains additive for multi-select controls.
;;
;; Function: etaf-data-selected-item (controller &optional item-key)
;;;###autoload (autoload 'etaf-data-selected-item "etaf" nil nil)
;; Return the loaded item matching CONTROLLER's first selected identity.
;;
;; ITEM-KEY overrides the function supplied to `etaf-data-controller'.  When no
;; key function is available, item identity is compared directly.  Return nil
;; when the selection or current page has no matching item.
;;
;; Function: etaf-data-selected-ref (controller identity)
;;;###autoload (autoload 'etaf-data-selected-ref "etaf" nil nil)
;; Return CONTROLLER's stable boolean selection ref for IDENTITY.
;;
;; The returned ref changes only when IDENTITY enters or leaves the controller's
;; selection.  Repeated calls for the same identity return the same ref for the
;; controller lifetime.  Updates made through the selection APIs or by writing
;; the public `etaf-data-selection' ref directly are both reflected.
;;
;; Function: etaf-data-selection (controller)
;;;###autoload (autoload 'etaf-data-selection "etaf" nil nil)
;; Return CONTROLLER's selected identity list ref.
;;
;; Function: etaf-data-set-page (controller page)
;;;###autoload (autoload 'etaf-data-set-page "etaf" nil nil)
;; Set CONTROLLER page to PAGE and return PAGE.
;;
;; Function: etaf-data-set-page-size (controller page-size)
;;;###autoload (autoload 'etaf-data-set-page-size "etaf" nil nil)
;; Set CONTROLLER page size to PAGE-SIZE and return PAGE-SIZE.
;;
;; Function: etaf-data-set-query (controller query)
;;;###autoload (autoload 'etaf-data-set-query "etaf" nil nil)
;; Set CONTROLLER query to QUERY and return QUERY.
;;
;; Function: etaf-data-source (&rest capabilities)
;;;###autoload (autoload 'etaf-data-source "etaf" nil nil)
;; Create a Data source from callable CAPABILITIES.
;;
;; CAPABILITIES is a plist.  `:load' is required and receives QUERY, PAGE, and
;; PAGE-SIZE.  It must return a plist containing at least `:items', and may return
;; `:total', `:page', and `:page-size'.  `:mutate' is optional and receives
;; OPERATION and PAYLOAD.  An optional `:mutate-v2' capability has the same
;; arguments but may return a tagged commit-certainty outcome; it is additive and
;; never changes the v1 callback.  An optional `:mutate-batch' capability
;; receives a list of (OPERATION PAYLOAD) pairs and returns one result per pair;
;; a transactional backend turns the list into one atomic write and
;; `etaf-data-mutate-many' reconciles the Controller once for the batch.
;; `:dispose' is optional and runs when the owning
;; controller stops.  `:item-key' optionally returns stable selection identity
;; for one item.  `:provider' may name the source in observation reports and
;; defaults to `data'.
;; Load and mutation callbacks may instead return `etaf-async'; resolve with the
;; ordinary result and reject with condition data.  A v2 result has :certainty
;; committed/rolled-back/external-unknown, :result for committed, and :error
;; condition data for rolled-back.  A v1 normal return means committed.
;; A rejection, cancellation or timeout leaves external write certainty unknown.
;; Each Controller owns its source disposal; use separate source lifecycles for
;; independent Controllers.
;;
;; Function: etaf-data-source-capabilities (source)
;;;###autoload (autoload 'etaf-data-source-capabilities "etaf" nil nil)
;; Return a fresh plist of SOURCE's supported :load, :mutate, :mutate-v2,
;; :mutate-batch, :dispose, :item-key, :provider and :name entries when present.
;; Callbacks
;; and metadata retain identity; replacing entries leaves SOURCE unchanged.
;; Use to compose an adapter with etaf-data-source without inspecting private
;; representation. Preserve callback inputs/results and forward disposal.
;; The adapted source has one owning Controller; do not give its underlying
;; source another owner. Reading capabilities starts no work and transfers
;; no ownership. Invalid sources signal wrong-type-argument.
;;
;; Function: etaf-data-source-load-page (source &optional query page page-size)
;;;###autoload (autoload 'etaf-data-source-load-page "etaf" nil nil)
;; Load and normalize one SOURCE page without creating a Controller.
;; QUERY is passed through unchanged.  PAGE and PAGE-SIZE default to 1 and 20.
;; This public preparation boundary performs no reactive publication; callers may
;; use its result as `:initial-result' for `etaf-data-controller'.
;; Only synchronous sources are supported; an asynchronous descriptor signals
;; `etaf-async-error' without starting its work.
;;
;; Function: etaf-data-status (controller)
;;;###autoload (autoload 'etaf-data-status "etaf" nil nil)
;; Return CONTROLLER's status ref.
;;
;; The status is idle, loading, refreshing, success, error or cancelled.
;; Read-only reloads use refreshing after an accepted result; writes use loading.
;; Previous items remain readable until a successful load replaces them.
;;
;; Function: etaf-data-stop (controller)
;;;###autoload (autoload 'etaf-data-stop "etaf" nil nil)
;; Stop CONTROLLER, dispose its Scope, and return cleanup errors.
;;
;; Error: etaf-data-stopped-error
;; ETAF data controller has been stopped
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-data-total (controller)
;;;###autoload (autoload 'etaf-data-total "etaf" nil nil)
;; Return CONTROLLER's total matching item count ref.
;;
;; Macro: etaf-define-behavior (name arguments &rest body)
;;;###autoload (autoload 'etaf-define-behavior "etaf" nil nil 'macro)
;; Define ordinary Behavior constructor NAME with ARGUMENTS and BODY.
;;
;; The constructor must return `etaf-behavior-create' data.  This is a function
;; definition convenience, not a second runtime or visual node model.
;;
;; Macro: etaf-define-component (name arguments &rest clauses)
;;;###autoload (autoload 'etaf-define-component "etaf" nil nil 'macro)
;; Define Component NAME from prop ARGUMENTS and CLAUSES.
;;
;; Reloading an identical declaration from the same library (source or bytecode)
;; retains its original definition, captured values and mounted instances. This
;; is not hot replacement: changed declarations, other libraries and ordinary
;; evaluated duplicates still signal etaf-component-call-error. To replace a
;; definition or refresh its captured values, dispose its Runtimes and use
;; etaf-component-redefine-run.
;;
;; Choose exactly one authoring frontend:
;;
;;   (etaf-define-component NAME (&key PROPS)
;;     [:bindings ((NAME INITIALIZER) ...)]
;;     [:validate ORDINARY-ELISP]
;;     [:setup SETUP]
;;     :view VIEW
;;     :styles ((SELECTOR ATTR ...)))
;;
;; or:
;;
;;   (etaf-define-component NAME (&key PROPS)
;;     [:bindings ((NAME INITIALIZER) ...)]
;;     [:validate ORDINARY-ELISP]
;;     [:setup SETUP]
;;     :render ORDINARY-ELISP
;;     :styles ((SELECTOR ATTR ...)))
;;
;; `:bindings' initializes named values once, in let* order, before optional
;; `:setup'.  Initializers can use initial props and earlier bindings.  Setup,
;; both View frontends and their callbacks can refer directly to these stable
;; values.  Names must be distinct ordinary symbols, not declared props.
;; Ref/computed/watch/local-ref ownership remains the Component Scope; failed
;; initialization disposes it.  Reorder retains values; replacement/unmount
;; releases the instance.  Rebinding a lexical name with setq does not replace
;; its stored value: mutate refs explicitly through `etaf-value'.
;;
;; With named bindings, optional `:setup' performs initialization; its return
;; value is ignored.  Without bindings, setup can return opaque state read by
;; the advanced `etaf-state' accessor, but not a render function.  `:view'
;; is unquoted DSL; `:render' is ordinary Elisp returning the same typed View,
;; usually through `etaf-view'.  `etaf-node' also constructs Views
;; programmatically.  Both frontends use the same prop and slot rules.  Declared
;; props are lexical snapshots for each setup or render evaluation; callbacks
;; may refer to them directly.  Passed refs retain identity and live value reads.
;; Business prop values use the reactive shallow equality rule: replacing an
;; object updates the retained instance even when its contents compare equal.
;; Keyed list items follow the same rule; keys retain instances, not old inputs.
;; Keep reactive value reads inside the View properties or expressions they
;; update.  A Component that reads a passed source, such as a ref, in its own
;; render re-renders alone when that source changes; its parent and its
;; siblings keep their instances, so a keyed list of block Components repaints
;; the block whose input changed.  Use `etaf-prop' in a binding initializer for
;; a tracked input; a plain prop variable in initialization is an initial
;; snapshot.
;;
;; A fragment result keeps its children in the enclosing Host layout, including
;; projected slots and stateful children. Component retention adds no visual
;; container. Declare a layout Host explicitly when the Component needs one.
;; Output may change between nil, one View and a fragment without resetting the
;; Component's bindings. Keyed children retain state while present; removal
;; releases their own instances even when the parent remains mounted.
;;
;; Props accept NAME or (NAME DEFAULT) after &key.  Defaults evaluate in order
;; on first missing input and can read earlier props.  Explicit nil is supplied.
;; Mounted instances retain successfully published defaults until replacement or
;; unmount; pure rendering evaluates defaults anew.  Default expressions must be
;; safe to retry after rejected publication; allocate mutable values explicitly.
;;
;; Optional :validate runs ordinary Elisp with resolved lexical props after
;; defaults, before bindings/setup or updated inputs are published. Its return
;; is ignored; etaf-check-prop or any signaled error rejects the input. Pure
;; rendering and mounted input evaluation share this phase. Validation must be
;; pure and may run again; it cannot use instance bindings, state, slots or
;; lifecycle. Check reactive handles by type and keep their live value reads and
;; value-dependent checks in rendering. Rejected input preserves the published
;; props and callbacks but does not undo the caller's business ref write.
;;
;; Component rules use ECSS author origin, specificity, source order and
;; importance through Ebox. &/:scope match each topmost owned Host; ordinary
;; selectors match owned descendants. Slots retain caller ownership and fallback
;; retains the consumer's scope. Inline declarations remain separate cascade input.
;;
;; Function: etaf-dispatch (action &rest arguments)
;;;###autoload (autoload 'etaf-dispatch "etaf" nil nil)
;; Dispatch named ACTION through the active Runtime with ARGUMENTS.
;;
;; An explicit Runtime may be supplied as the first argument: `(etaf-dispatch
;; RUNTIME ACTION ...)'.  Action functions receive Runtime first.
;;
;; Function: etaf-call-with-input (reader)
;;;###autoload (autoload 'etaf-call-with-input "etaf" nil nil)
;; Run zero-argument native input READER from the current Host event callback.
;; Ebox restores logical focus and checks that the same mounted Host remains
;; visible and enabled; invalidation signals a subtype of quit. Return the
;; reader result without applying application state. Reader errors and user
;; quit propagate. Calls outside events signal etaf-event-error. Native editing
;; owns its minibuffer or separate buffer; it must not edit the rendered surface.
;;
;; Function: etaf-dispatch-event (runtime host-ref kind &optional payload (payload-p nil))
;;;###autoload (autoload 'etaf-dispatch-event "etaf" nil nil)
;; Dispatch KIND for HOST-REF through mounted RUNTIME.
;; Native Hosts support :on-press activation and :on-drag gestures. ON-DRAG
;; receives the gesture plist documented by `ebox-keymap-create' :drag, once
;; per start/move/end/cancel phase. Each phase runs in its own reactive event
;; batch and publishes before the next pointer event. Primary-button tracking
;; belongs to Ebox; when both handlers are supplied, press is keyboard-only.
;; A Host with :drag-edge receives an extra `edge' phase while the pointer
;; rests in or past the window's edge band during the drag, with :edges naming
;; the edges, :overshoot the pointer's distance past the text area and :elapsed
;; the seconds since the previous edge phase; the callback owns any scrolling
;; of its own viewport.
;; Generated pointer gestures publish Ebox :active state through component
;; styles while held; pointer activation clears it before invoking :on-press.
;; Explicit event dispatch and keyboard activation do not create pointer state.
;; :on-swipe receives `left' or `right', the finger direction of one horizontal
;; two-finger trackpad gesture over the Host or its descendants; the nearest
;; enabled Host with :on-swipe handles it and momentum is absorbed (see
;; `ebox-wheel-swipe').  It does not make the Host activatable or change its
;; pointer.  :on-scroll on an `:overflow scroll' Host receives the new line
;; offset after the wheel, scroll keys or an `etaf-scroll-*' call changes it,
;; for example to load older rows when a history reaches offset 0; content
;; growth that keeps a pinned `:scroll-anchor end' Host at its end is not a
;; scroll.
;; Callbacks follow the current committed Host. A retained disabled Host can
;; receive native cancellation; removed or unmounted Hosts receive no more
;; application callbacks. Their Component scopes clean up normally. Other
;; :on-* names require explicit dispatch and do not imply native event support.
;; `:on-press-capture' is the one explicit ancestor hook: after a target press
;; callback succeeds, committed ancestor capture handlers run nearest-first.
;; Ordinary :on-press callbacks never bubble implicitly. `:on-focus-leave'
;; runs on enabled Hosts focus moves out of, then `:on-focus-enter' on those
;; it moves into, nearest first in each phase. Shared ancestors are skipped.
;; Both take no arguments and share one reactive batch; they observe the
;; already accepted focus, whether moved by Tab, arrows, a press or `etaf-focus'.
;; Redirecting focus stops notifications for the superseded destination.
;; These are movement notifications, not teardown hooks; removed/unmounted
;; Hosts use Component lifecycle cleanup instead.
;;
;;   When PAYLOAD-P is non-nil, pass PAYLOAD as the callback's only argument;
;; otherwise call the local callback with no arguments.
;;
;; Function: etaf-drag-step (runtime host-ref columns rows)
;;;###autoload (autoload 'etaf-drag-step "etaf" nil nil)
;; Drag HOST-REF in mounted RUNTIME (nil: current) by COLUMNS and ROWS from the
;; keyboard and return HOST-REF.  Dispatch one `start' and one `end' gesture to
;; its :on-drag with a pixel delta of COLUMNS character widths and ROWS line
;; heights, so every pointer drag handler, including the draggable and
;; resizable Behaviors, also works from keys.  The gestures carry `:keyboard'
;; t.  Non-numeric steps or a missing Host signal etaf-event-error.
;;
;; Function: etaf-event-target-within-p (host-ref)
;;;###autoload (autoload 'etaf-event-target-within-p "etaf" nil nil)
;; Return non-nil when the current event's target is HOST-REF or inside it.
;; Call from an event callback.  In an ancestor `:on-press-capture' callback the
;; target is the Host whose press callback ran; in any other callback it is the
;; callback's own Host.  HOST-REF is compared with `equal' against the target and
;; its committed Host ancestors, so a root shell can tell a press inside an open
;; panel from one on the surface around it.  Outside an event callback signal
;; `etaf-event-error'.
;;
;; Function: etaf-event-pointer-p ()
;;;###autoload (autoload 'etaf-event-pointer-p "etaf" nil nil)
;; Return non-nil when the current event came from a pointer button: a press
;; activated by a mouse or trackpad click.  Keyboard activation (RET or SPC)
;; returns nil.  Click-only policies, such as dismissing a modal when its
;; backdrop is clicked, use it so a key pressed while the modal has focus never
;; triggers them.  Outside an event callback signal `etaf-event-error'.
;;
;; Function: etaf-effect-scope (&key detached name)
;;;###autoload (autoload 'etaf-effect-scope "etaf" nil nil)
;; Create a Scope named NAME, owned by the current Scope unless DETACHED.
;; The parent disposes child scopes automatically. Without a parent, or when
;; DETACHED is non-nil, the caller must use `etaf-scope-stop` for cleanup.
;;
;; Function: etaf-error-boundary-run (function handler &key name)
;;;###autoload (autoload 'etaf-error-boundary-run "etaf" nil nil)
;; Run FUNCTION and handle its signaled error with HANDLER.
;;
;; HANDLER receives the raw condition object and its return value becomes the
;; boundary result.  NAME is accepted for caller diagnostics and does not change
;; control flow.  Errors signaled outside FUNCTION, or by HANDLER itself, are not
;; swallowed by this boundary.
;;
;; Error: etaf-event-error
;; Invalid ETAF Event
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-help (&optional runtime)
;;;###autoload (autoload 'etaf-help "etaf" nil t)
;; Open read-only keyboard help as a modal inside RUNTIME's existing buffer.
;; RUNTIME defaults to the active/current-buffer Runtime.  The opening scope
;; is captured before focus moves; repeated calls reuse that help.  No frame,
;; window, help buffer or application Runtime is created.  Escape closes the
;; help and restores a surviving opening focus and window position.  While
;; open, native window scrolling starts at the canvas top so the modal stays
;; visible; a rejected renderer restores the original position.  Return
;; the application buffer.  A non-mounted Runtime signals etaf-runtime-error.
;; `etaf-ui' supplies the searchable catalog presentation when loaded; core
;; alone supplies a scrollable modal.  Neither executes listed commands.
;; Calls inside an event or batch defer opening until its work is published.
;; Before each new opening, finish editing, then dispatch :on-help-open on
;; the nearest enabled Host in the current key scope, stopping at a modal
;; boundary.  The zero-argument callback may pause application activity;
;; its return value is ignored and its errors or quit abort opening.  Capture
;; the snapshot after it succeeds.  Reusing or closing help does not run it
;; or undo application changes.  Keep the Runtime mounted and do not open
;; help recursively from this callback.
;;
;; Function: etaf-help-close (&optional runtime)
;;;###autoload (autoload 'etaf-help-close "etaf" nil t)
;; Close RUNTIME's help and restore its surviving focus and window start.
;; Return non-nil when help was open, nil otherwise.  RUNTIME defaults to the
;; active/current-buffer Runtime; an unmounted Runtime signals
;; etaf-runtime-error.  Closing preserves application state and input; C-g
;; remains Emacs's native interrupt, not a close command.  Inside an event or
;; batch, restore focus and window position after modal removal is published;
;; a newer help opening or Runtime unmount is never overridden.
;;
;; Function: etaf-help-data (&optional runtime)
;;;###autoload (autoload 'etaf-help-data "etaf" nil nil)
;; Return a defensive read-only snapshot of RUNTIME's effective key scope.
;; The plist contains :title and :scope strings, :groups, :notes and :controls.
;; A group has :title, :source, :kind (application, framework or regions) and
;; :entries.  An entry has :key, :label, :source and optional :events (a key
;; vector).  Notes are scoped Host :help strings; controls are readable names.
;; There are no executable callbacks in the data.  Nearer Host keys shadow
;; outer keys even without a label; effective local maps supplement them.
;; While help is open return its opening snapshot.  RUNTIME defaults to the
;; active/current-buffer Runtime; an unmounted Runtime signals
;; etaf-runtime-error.  Use this data to compose a read-only help renderer.
;;
;; Variable: etaf-help-view-function
;; Nil (default), or a function of DATA and CLOSE returning a root-layer
;; modal help View.  DATA follows etaf-help-data; CLOSE is a zero-argument
;; dismissal callback.
;; The View inherits the opening Host's Context and mounted lifecycle, and
;; must not create buffers/windows or execute listed business commands.
;; Nil uses core's minimal scrollable modal; loading etaf-ui installs its
;; catalog renderer only when this value is nil, preserving custom renderers
;; without a reverse package dependency.
;;
;; Function: etaf-palette (&optional runtime)
;;;###autoload (autoload 'etaf-palette "etaf" nil t)
;; Choose and run a command or control of mounted RUNTIME by name.
;; Candidates are the labelled :keys the current focus reaches, Close when an
;; :on-dismiss Host is in scope, then every focusable control in the current
;; keyboard scope, named by :aria-label or its painted text.  Choosing a key runs its
;; command; choosing a control focuses it and dispatches its press.  The
;; palette is an execution surface reached from `M-x'; `?' opens `etaf-help'
;; instead so that viewing never runs anything.  An empty palette signals
;; user-error.
;;
;; Function: etaf-region-focus (region-id &optional runtime)
;;;###autoload (autoload 'etaf-region-focus "etaf" nil nil)
;; Focus REGION-ID's effective entry in mounted RUNTIME.
;; The entry is the last accepted focus position remembered inside the
;; region, then its declared `:enter' Host, then its first eligible stop.
;; RUNTIME defaults to the active Runtime.  Return the focused Host
;; reference; signal `etaf-event-error' when the region is unknown or has
;; no usable entry.
;;
;; Function: etaf-region-select (&optional runtime)
;;;###autoload (autoload 'etaf-region-select "etaf" nil t)
;; Select a region of mounted RUNTIME from the keyboard.
;; Show the declared regions of the current focus scope with their hint
;; keys, then read one key: a hint key focuses that region's effective
;; entry, an arrow key moves to the sibling region in that direction, `?'
;; repeats the hint and Escape cancels.  Other keys change nothing and keep
;; the selector open.  This is the framework's default `M-g' binding in
;; Runtime buffers.
;;
;; Function: etaf-focus (&optional runtime host-ref)
;;;###autoload (autoload 'etaf-focus "etaf" nil t)
;; Move focus to HOST-REF in mounted RUNTIME and move point to its position.
;;
;; Ebox owns mounted focus, navigation and publication, including :focus
;; component rules and their paint/layout changes. Pure views carry no focus.
;; Without HOST-REF, select its first eligible tab stop; an empty list leaves
;; focus and point unchanged and signals user-error. Explicit invalid targets signal
;; etaf-event-error. Negative or absent tab indexes still allow explicit focus.
;; Removal, hiding and disabling clear focus; a tab-index change alone does not.
;; Layout follows point only when it stayed at the target; manual point stays
;; at its numeric position clamped to the accessible buffer. Rejection restores
;; focus and point. No window is selected.
;;
;; Function: etaf-keymap-reserved-events (keymap)
;;;###autoload (autoload 'etaf-keymap-reserved-events "etaf" nil nil)
;; Return the framework-reserved events bound at the top level of KEYMAP.
;; Escape, the region selector entry, native quit, `?', Tab and the direction
;; keys are framework-owned and no application or component scope may
;; override them; direction behavior uses `:on-direction' instead.  The
;; result is a list of event vectors in binding order, or nil when KEYMAP is
;; nil, not a keymap, or free of conflicts.  Component authors use this to
;; reject a caller-supplied `:keymap' during validation.
;;
;; Function: etaf-direction (direction &optional runtime)
;;;###autoload (autoload 'etaf-direction "etaf" nil t)
;; Move DIRECTION in mounted RUNTIME and return the focused Host reference.
;; DIRECTION is `up', `down', `left' or `right'.  The nearest Host
;; `:on-direction' handler runs first (returning `handled', `hold' or
;; `release'); then a focused separator or slider steps; then focus moves
;; inside the surrounding region, entering the adjacent region at its edge.
;; Without a surrounding region the Ebox spatial movement applies and the
;; viewport scrolls at its edge.  Return nil when nothing moves.
;;
;; Function: etaf-set-direction-scheme (scheme &optional runtime)
;;;###autoload (autoload 'etaf-set-direction-scheme "etaf" nil t)
;; Select the direction SCHEME, `arrows' or `vim', after conflict checks.
;; Vim requires every mounted Runtime to be free of Host `:keys' and region
;; hint letters using `h', `j', `k' or `l'; conflicts are reported and the
;; previous scheme stays in effect.  RUNTIME limits the check and defaults
;; to the active one.  Return SCHEME.
;;
;; Variable: etaf-direction-scheme
;; Direction scheme of the key layer: `arrows' (default) or `vim'.
;; `arrows' leaves `h', `j', `k' and `l' to the application; `vim' dispatches
;; them as direction keys in navigation state.  Set it through
;; `etaf-set-direction-scheme' so a conflicting Runtime is reported instead
;; of shadowed.
;;
;; Function: etaf-focus-next (&optional runtime)
;;;###autoload (autoload 'etaf-focus-next "etaf" nil t)
;; Focus the next visible Host in mounted RUNTIME.
;;
;; Function: etaf-focus-previous (&optional runtime)
;;;###autoload (autoload 'etaf-focus-previous "etaf" nil t)
;; Focus the previous visible Host in mounted RUNTIME.
;;
;; Function: etaf-focus-within (runtime host-ref &optional count)
;;;###autoload (autoload 'etaf-focus-within "etaf" nil nil)
;; Navigate inside HOST-REF's committed subtree in RUNTIME (nil: current buffer).
;; Nil COUNT selects its first eligible stop; integer COUNT moves with wrapping,
;; negative moves backward and zero queries current focus membership. Ebox owns
;; ordering, visibility and identity. Missing/inaccessible roots or stops signal
;; user-error without changing focus or point. Focus changes require an accepted
;; publication boundary. This installs no input bindings or persistent trap.
;;
;; Function: etaf-focusable (&rest attributes)
;;;###autoload (autoload 'etaf-focusable "etaf" nil nil)
;; Return a focusable Behavior from ATTRIBUTES.
;;
;; When ATTRIBUTES does not specify `:tab-index', the Behavior supplies the
;; standard first tab stop, zero.  An explicit nil excludes it from tab navigation.
;;
;; Function: etaf-focused-host-ref (&optional runtime)
;;;###autoload (autoload 'etaf-focused-host-ref "etaf" nil nil)
;; Return Ebox's current focus Host reference in mounted RUNTIME.
;; Direct Ebox focus operations and these APIs observe the same buffer owner.
;;
;;
;;
;; Function: etaf-input-begin (runtime host-ref &rest options)
;;;###autoload (autoload 'etaf-input-begin "etaf" nil nil)
;; Start native editing of a mounted text Host's value; return a session.
;; Typed keys edit the value with ordinary Emacs commands, undo and input
;; methods while the Host keeps its layout, padding and borders and shows
;; each edit at once. OPTIONS are `ebox-input-begin''s :on-change, :on-leave,
;; :keymap and :local-variables. Publications continue; publishing the
;; session value into the Host is a no-op and another value replaces it.
;; Host, Runtime and single-session rules are errors.
;;
;; Function: etaf-input-text (session)
;;;###autoload (autoload 'etaf-input-text "etaf" nil nil)
;; Return a session's current property-free value, or nil once it ended.
;;
;; Function: etaf-input-end (session)
;;;###autoload (autoload 'etaf-input-end "etaf" nil nil)
;; End a session and return its value; the Host keeps displaying it.
;;
;; Function: etaf-input-active-p (&optional runtime)
;;;###autoload (autoload 'etaf-input-active-p "etaf" nil nil)
;; Return a mounted Runtime's active input session, or nil.
;;
;; Function: etaf-input-edit-command-add (command)
;;;###autoload (autoload 'etaf-input-edit-command-add "etaf" nil nil)
;; Add COMMAND to the commands that edit a native input session's text.
;; A command in this list that is bound in a session keymap edits the session
;; value; other session bindings run in the mounted buffer.  A value that is
;; not a command symbol signals `wrong-type-argument'.  Return the updated
;; list.
;;
;; Function: etaf-input-edit-command-remove (command)
;;;###autoload (autoload 'etaf-input-edit-command-remove "etaf" nil nil)
;; Remove COMMAND from the native input session's text-editing commands.
;; Return the updated list.
;;
;; Function: etaf-host-ref-bounds (runtime host-ref)
;;;###autoload (autoload 'etaf-host-ref-bounds "etaf" nil nil)
;; Return live Ebox bounds for HOST-REF in mounted RUNTIME.
;; The (START . END) span runs from the Host's first visible painted cell to
;; the end of its last painted row.  A `:visibility hidden' Host in flow
;; reports its blank slot; the result is nil when the Host owns no cells.
;;
;; Function: etaf-host-ref-at (runtime &optional position predicate)
;;;###autoload (autoload 'etaf-host-ref-at "etaf" nil nil)
;; Return the explicit `:ref' of the innermost Host painted at POSITION
;; (default point) in mounted RUNTIME, walking outwards to enclosing Hosts.
;; PREDICATE, when non-nil, selects the first reference it accepts, so a list
;; can map point to its row (`etaf-host-ref-position' is the inverse).
;; Generated references are never returned; nil means no matching Host.
;;
;; Variable: etaf-cursor-follows-input-modality
;;;###autoload (autoload 'etaf-cursor-follows-input-modality "etaf" nil nil)
;; Whether a mounted canvas hides its cursor after a pointer click.
;; Nil by default so a mounted buffer keeps Emacs's native blinking cursor
;; visible wherever point is placed by clicks or keyboard motion.  Set to
;; non-nil (globally or via `setq-local') to opt into hiding the cursor after
;; a pointer click until the next keyboard command; applications that want no
;; cursor at all should pass `:cursor nil' to `etaf-app-open'.
;;
;; Function: etaf-projection (runtime entries &optional source)
;;;###autoload (autoload 'etaf-projection "etaf" nil nil)
;; Return the source projection of RUNTIME's painted cells.
;; ENTRIES is an alist of (REF . (SOURCE-START . SOURCE-END)), one per Host
;; whose painted cells stand for a range of an application's source document.
;; The result is a vector of runs (DISPLAY-BEG DISPLAY-END SOURCE-BEG
;; SOURCE-END) ordered by display position, so an editor can translate a
;; painted position into a source offset and back.  Nothing is computed until
;; an application asks: renderings without source ranges pay no cost.  A Host
;; whose text wraps contributes one run per painted line, its range split in
;; proportion to the cells each line owns.
;;
;; Function: etaf-projection-source-offset (projection position)
;;;###autoload (autoload 'etaf-projection-source-offset "etaf" nil nil)
;; Return the source offset that painted POSITION stands for.
;; A position outside every run reports the nearest run edge.
;;
;; Function: etaf-projection-position (projection offset)
;;;###autoload (autoload 'etaf-projection-position "etaf" nil nil)
;; Return the painted position where source OFFSET lives, or nil.
;; An offset the paint skipped, such as a folded marker, maps to the start of
;; the next run; the end of the source maps after the last painted cell.
;;
;; Function: etaf-host-ref-size (runtime host-ref)
;;;###autoload (autoload 'etaf-host-ref-size "etaf" nil nil)
;; Return the committed painted border-box size as (WIDTH-PIXELS . HEIGHT-ROWS).
;; RUNTIME must be mounted. Margins and neighbouring columns are excluded;
;; clipping reduces the result, and absent or wholly hidden Hosts return nil.
;; Read after layout to prepare resources; the query does not publish and is
;; not intended for per-frame polling.
;;
;; Function: etaf-host-ref-position (runtime host-ref)
;;;###autoload (autoload 'etaf-host-ref-position "etaf" nil nil)
;; Return the first live Ebox position for HOST-REF in RUNTIME.
;;
;; Function: etaf-scroll-offset (runtime host-ref)
;;;###autoload (autoload 'etaf-scroll-offset "etaf" nil nil)
;; Return the scroll offset in lines of a Host with `:overflow scroll'.
;; RUNTIME must be mounted; an unknown HOST-REF signals an error.
;;
;; Function: etaf-scroll-to (runtime host-ref offset)
;;;###autoload (autoload 'etaf-scroll-to "etaf" nil nil)
;; Scroll a Host to OFFSET lines, `start' or `end'; return the clamped offset.
;; Combine `end' with the `:scroll-anchor end' style for chat and log views:
;; the Host then starts at and follows its last line until the user scrolls
;; away, and scrolling back to the end pins it again.
;;
;; Function: etaf-scroll-by (runtime host-ref delta)
;;;###autoload (autoload 'etaf-scroll-by "etaf" nil nil)
;; Scroll a Host by DELTA lines (negative scrolls up); return the new offset.
;;
;; Function: etaf-scroll-viewport (runtime delta)
;;;###autoload (autoload 'etaf-scroll-viewport "etaf" nil nil)
;; Scroll the active reading viewport in mounted RUNTIME by DELTA lines
;; (negative scrolls up): scrolls any enclosing scrollable Host at point first,
;; then falls back to scrolling the window displaying RUNTIME's buffer.
;; Return DELTA.
;;
;; Function: etaf-scroll-into-view (runtime host-ref &optional align)
;;;###autoload (autoload 'etaf-scroll-into-view "etaf" nil nil)
;; Scroll every scrolling Host around HOST-REF by the least distance that
;; shows it, for example a keyboard-selected row; return HOST-REF.  ALIGN
;; `start' or `end' puts the Host's top on a scroller's first line or its
;; bottom on the last line instead, for example to keep the reader's row in
;; place after older rows are prepended.  Window scrolling and point stay
;; with the caller.
;;
;; Function: etaf-inject (key &optional default (required-p nil required-p-supplied-p))
;;;###autoload (autoload 'etaf-inject "etaf" nil nil)
;; Return the nearest provided value for KEY.
;;
;; DEFAULT is returned when KEY is absent.  When REQUIRED-P is non-nil, absence
;; signals an error.  The optional third argument is explicit so a provided nil
;; can be distinguished from a missing dependency.
;;
;; Function: etaf-mount (buffer-or-name view &optional options)
;;;###autoload (autoload 'etaf-mount "etaf" nil nil)
;; Mount normalized VIEW into BUFFER-OR-NAME and return its buffer.
;; The mounted buffer preserves Emacs's native cursor across pointer clicks
;; and keyboard motion by default (`etaf-cursor-follows-input-modality' is nil,
;; or set to non-nil to hide the cursor on pointer clicks until the next
;; keyboard command).  A text input sets its own `cursor-type' while it edits,
;; and the caller's cursor state returns on unmount.
;; OPTIONS may provide `:viewport-width', `:viewport-height', `:observer' and
;; `:text-selection' (t to enable native Emacs mark and pointer selection); it
;; is forwarded to `etaf-runtime-mount' when the Runtime is loaded.
;;
;; Function: etaf-node (tag props children &optional named-slots)
;;;###autoload (autoload 'etaf-node "etaf" nil nil)
;; Construct one typed View node from evaluated ordinary Elisp values.
;; TAG is an exact Host or Component registry symbol.  PROPS is a keyword plist,
;; CHILDREN is a list of typed View children, and NAMED-SLOTS is a Component-only
;; alist from stable slot symbols to typed child lists.
;;
;; Hosts also accept Ebox native :help-echo (string, native three-argument
;; help function, or nil), :pointer (Ebox pointer symbol or nil), and
;; :hover-style (Ebox color/text-decoration paint plist or nil). These are
;; inherited capabilities, including through Component root attributes;
;; explicit nil blocks inheritance. Ebox validates and paints them. They do
;; not create an activation boundary or an ETAF hover event/state.
;;
;; A Host with `:sticky top' (or nil) mirrors its first row into a displaying
;; window's header line once that window scrolls completely past the Host's
;; lines (`window-start' reaches the line after the Host), without moving
;; `window-start', so the original row and mirror never appear simultaneously.
;; A primary mouse click on a mirrored cell runs that cell's press binding at
;; its buffer position; the mirror refreshes on commits, retained Host updates
;; and refits, and clears completely on unmount.  One Host per Runtime is
;; sticky (the last committed one wins); the Runtime owns `header-line-format'
;; in its buffer only while a sticky Host is mounted.  Because Emacs's header
;; line is a single-row, buffer-width strip that cannot hold point, keyboard
;; focus or native text input, use `:sticky top' only for lightweight
;; single-row headers in natively scrolling buffers; lay out fixed interactive
;; toolbars as a non-scrolling sibling above an `:overflow scroll' viewport.
;;
;; A Host with `:translate' declares a translation hint for extensions such
;; as `etaf-translate': nil inherits from ancestors, t or `yes' marks the
;; Host translatable, `no' excludes the Host and its subtree, and `content'
;; marks a primary content region.  Unsupported values signal
;; `etaf-renderer-error'.
;;
;; Keyboard operation is declared on Hosts.  `:keys' is a list of
;; (KEY COMMAND [LABEL]) entries: KEY is a key or key sequence as a `kbd'
;; string or vector, COMMAND a function called with no
;; arguments (interactively when it is a command), and LABEL names it in
;; `etaf-palette'.  COMMAND runs like a keymap binding, outside any batch:
;; each write publishes, so it can move to or begin input on a Host it just
;; revealed; wrap several writes in `etaf-batch' to publish them once.  A key works while focus, or point
;; when nothing is focused or a command moved point out of the focused Host,
;; is inside the Host; the nearest Host binding it
;; wins, disabled Hosts contribute nothing, and Host keys precede the buffer's
;; own keymaps.  Keys fall through to them when no Host binds them or a native
;; input session is active.  Applications declare their keys on the root Host
;; rather than installing keymaps of their own.  A pointer event, such as a
;; wheel turn, resolves from the Host under the pointer, so a pane can bind
;; `<wheel-up>' for itself and an unbound wheel still scrolls natively.  RET
;; activates a nearer enabled Host with a press handler before an enclosing
;; Host's RET entry, so a focused control keeps activation while the root
;; binds RET for its selection.  A sequence such as "C-c C-u" shares its prefix with the buffer's
;; maps; it may not start with a printing key, and one key cannot both run a
;; command and start a sequence anywhere in the Runtime (a render error).
;; Native command objects retain only weak references to their Runtime and
;; callback owners, so command history does not keep a disposed application
;; alive. Invoking a command after its mount ends signals `user-error'.
;; Component root `:keys' put the caller's entries first.
;; `:help' contributes a string or list of strings to the scoped help as
;; read-only usage notes, not a second key inventory.  Bindings and their
;; labels come from :keys or effective local keymaps.
;; `:region' declares a user-addressable functional range on a Host: a
;; plist whose `:id' is the stable identity, `:label' the display name,
;; `:key' one hint character, `:enter' the default entry Host reference,
;; and `:neighbors' a plist mapping `:left'/`:right'/`:up'/`:down' to
;; region ids.  Regions nest by Host ancestry.  `M-g' opens region
;; selection in a Runtime buffer: a hint key focuses the region's effective
;; entry and an arrow key moves to the adjacent region; `etaf-region-focus'
;; performs the same jump for application direct keys.  The selector entry
;; is framework-reserved and cannot be rebound through `:keys'.  Arrows and,
;; under the optional `vim' scheme, `h'/`j'/`k'/`l' run `etaf-direction': a
;; Host declares `:on-direction', a function called with the direction symbol
;; that returns `handled', `hold' or `release'.  `handled' and `hold' stop
;; there; `release' continues to the separator or slider step, the movement
;; inside the surrounding region and the adjacent-region boundary.  Tab and
;; S-Tab move between the focus stops of the current keyboard scope.  Arrow keys, Tab,
;; `?', Escape, `M-g' and `C-g' are framework-reserved; express direction
;; behavior through `:on-direction' instead of binding them.
;; `:key-scope local' (or nil) establishes a non-modal keyboard boundary.
;; While focus or the point fallback is inside it, the nearest local or modal
;; boundary contains :keys, :on-dismiss, :on-direction, :on-help-open, Tab,
;; direction/edge navigation, region selection, help and palette controls.
;; Unbound printing keys are ignored rather than invoking an enclosing Host
;; or buffer action; an unhandled Escape is ignored too.  Native editing
;; still owns its keys.  A focused local subtree remains authoritative even
;; when point moves outside it; only a real focus change leaves that layer.
;; Pointer and explicit focus/region jumps can leave a local boundary;
;; no second focus or application-mode state is created.
;; Combine a local boundary's :on-dismiss with an explicit focus destination
;; to return to its host without disposing the application.  A :region on
;; the same Host restores its last eligible control on reentry.
;; `:focus-scope modal' confines Tab, arrows and :keys to an open Host such as
;; a dialog; outer keys are unreachable while it is visible, and printing
;; keys nothing in it binds are ignored instead of reaching the buffer's
;; keymaps.  `?' opens read-only `etaf-help'; the nearest :on-help-open callback
;; can prepare the application before a new opening.  `:on-dismiss'
;; runs for Escape when no nearer Host binds it; the key layer searches
;; outward for the nearest enabled dismiss handler within the keyboard scope.
;; One press runs one handler regardless of its return value.  An inner
;; temporary state supplies a handler only while that state needs dismissal.
;; `:focus-group' vertical, horizontal or grid makes its focusable descendants
;; one Tab stop; arrows and
;; C-n/C-p/C-b/C-f move within it and then spatially to the nearest stop, and
;; entering it returns to the remembered or aria-selected member.  Arrow keys
;; on a focused Host with role separator or slider and :on-drag step it by
;; one cell along its :aria-orientation.  `:on-focus-enter' lets a region
;; such as a window activate when keyboard focus enters it.
;;
;; Error: etaf-observer-error
;; Invalid ETAF observer operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-on-mounted (callback)
;;;###autoload (autoload 'etaf-on-mounted "etaf" nil nil)
;; Run CALLBACK after the current Component is first published.
;;
;; Function: etaf-on-unmounted (callback)
;;;###autoload (autoload 'etaf-on-unmounted "etaf" nil nil)
;; Run CALLBACK when the current Component is disposed.
;;
;; Function: etaf-on-updated (callback)
;;;###autoload (autoload 'etaf-on-updated "etaf" nil nil)
;; Run CALLBACK after the current Component participates in an update.
;;
;; Function: etaf-performance-call-operation (runtime kind label function)
;;;###autoload (autoload 'etaf-performance-call-operation "etaf" nil nil)
;; Call FUNCTION as KIND and LABEL through RUNTIME's operation boundary.
;;
;; Function: etaf-performance-clear ()
;;;###autoload (autoload 'etaf-performance-clear "etaf" nil t)
;; Clear completed and unfinished performance records.
;;
;; Function: etaf-performance-copy-report ()
;;;###autoload (autoload 'etaf-performance-copy-report "etaf" nil t)
;; Copy all retained performance records to the kill ring.
;;
;; Function: etaf-performance-environment-data ()
;;;###autoload (autoload 'etaf-performance-environment-data "etaf" nil nil)
;; Return the environment snapshot used to interpret latency records.
;;
;; Function: etaf-performance-export (file)
;;;###autoload (autoload 'etaf-performance-export "etaf" nil t)
;; Export all retained performance records to FILE.
;;
;; When called interactively, suggest a timestamped `.eld' file.  Refuse to
;; overwrite an existing file.
;;
;; Variable: etaf-performance-max-records
;; Maximum completed operations retained by the recorder.
;;
;; Function: etaf-performance-mode (&optional arg)
;;;###autoload (autoload 'etaf-performance-mode "etaf" nil t)
;; Record operations for the Runtime mounted in the current buffer.
;;
;; This is a minor mode.  If called interactively, toggle the
;; `ETAF-Performance mode' mode.  If the prefix argument is positive,
;; enable the mode, and if it is zero or negative, disable the mode.
;;
;; If called from Lisp, toggle the mode if ARG is `toggle'.  Enable the
;; mode if ARG is nil, omitted, or is a positive number.  Disable the mode
;; if ARG is a negative number.
;;
;; To check whether the minor mode is enabled in the current buffer,
;; evaluate the variable `etaf-performance-mode'.
;;
;; The mode's hook is called both when the mode is enabled and when it is
;; disabled.
;;
;; Function: etaf-performance-operation-elapsed (x)
;;;###autoload (autoload 'etaf-performance-operation-elapsed "etaf" nil nil)
;; Access slot "elapsed" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-gc-count (x)
;;;###autoload (autoload 'etaf-performance-operation-gc-count "etaf" nil nil)
;; Access slot "gc-count" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-gc-elapsed (x)
;;;###autoload (autoload 'etaf-performance-operation-gc-elapsed "etaf" nil nil)
;; Access slot "gc-elapsed" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-id (x)
;;;###autoload (autoload 'etaf-performance-operation-id "etaf" nil nil)
;; Access slot "id" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-kind (x)
;;;###autoload (autoload 'etaf-performance-operation-kind "etaf" nil nil)
;; Access slot "kind" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-label (x)
;;;###autoload (autoload 'etaf-performance-operation-label "etaf" nil nil)
;; Access slot "label" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-p (x)
;;;###autoload (autoload 'etaf-performance-operation-p "etaf" nil nil)
;;
;;
;; Function: etaf-performance-operation-runtime-id (x)
;;;###autoload (autoload 'etaf-performance-operation-runtime-id "etaf" nil nil)
;; Access slot "runtime-id" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-stage-summary (operation)
;;;###autoload (autoload 'etaf-performance-operation-stage-summary "etaf" nil nil)
;; Summarize flat provider stages in OPERATION by category.
;;
;; Each result contains `:category', `:count', and `:duration-ms'.  Provider
;; durations may overlap and are therefore never presented as exclusive time.
;;
;; Function: etaf-performance-operation-stages (x)
;;;###autoload (autoload 'etaf-performance-operation-stages "etaf" nil nil)
;; Access slot "stages" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-operation-status (x)
;;;###autoload (autoload 'etaf-performance-operation-status "etaf" nil nil)
;; Access slot "status" of `etaf-performance-operation' struct X.
;;
;;
;; Function: etaf-performance-records (&optional runtime-id)
;;;###autoload (autoload 'etaf-performance-records "etaf" nil nil)
;; Return newest-first immutable snapshots of completed records.
;; When RUNTIME-ID is non-nil, select only that integer observer report identity,
;; as exposed by `etaf-performance-operation-runtime-id'.  This also selects
;; historical records after unmount or reuse of a buffer name.  Omitted or nil
;; RUNTIME-ID selects all retained records.
;;
;; Function: etaf-performance-report-data (&optional (records (etaf-performance-records)))
;;;###autoload (autoload 'etaf-performance-report-data "etaf" nil nil)
;; Return a detached portable report for completed RECORDS. Omitted RECORDS
;; selects retained records; explicit nil selects none. The versioned plist
;; includes :format-version, :environment, :summary and :operations. Operations
;; identify :id, :runtime-id and :buffer-name and contain flat :stages with
;; :provider, :stage, :duration-ms and provider :metadata. Nested provider
;; durations may overlap. This read-only operation does not clear recordings,
;; install observers, change the Runtime or invoke recorded application code.
;;
;; Function: etaf-performance-show ()
;;;###autoload (autoload 'etaf-performance-show "etaf" nil t)
;; Show retained ETAF operations and stages in a tabulated panel.
;;
;; Function: etaf-performance-stage-category (x)
;;;###autoload (autoload 'etaf-performance-stage-category "etaf" nil nil)
;; Access slot "category" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-duration (x)
;;;###autoload (autoload 'etaf-performance-stage-duration "etaf" nil nil)
;; Access slot "duration" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-metadata (x)
;;;###autoload (autoload 'etaf-performance-stage-metadata "etaf" nil nil)
;; Access slot "metadata" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-name (x)
;;;###autoload (autoload 'etaf-performance-stage-name "etaf" nil nil)
;; Access slot "name" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-provider (x)
;;;###autoload (autoload 'etaf-performance-stage-provider "etaf" nil nil)
;; Access slot "provider" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-stage-status (x)
;;;###autoload (autoload 'etaf-performance-stage-status "etaf" nil nil)
;; Access slot "status" of `etaf-performance-stage' struct X.
;;
;;
;; Function: etaf-performance-start (runtime)
;;;###autoload (autoload 'etaf-performance-start "etaf" nil nil)
;; Attach the recorder to mounted RUNTIME and return RUNTIME.
;;
;; Attachment is idempotent for this recorder.  A Runtime already owned by a
;;   different observer is rejected rather than replaced.
;;
;; Function: etaf-performance-stop (runtime)
;;;###autoload (autoload 'etaf-performance-stop "etaf" nil nil)
;; Detach this recorder from RUNTIME and return RUNTIME.
;;
;; If another observer replaced the recorder sink, leave that observer intact.
;;
;; Function: etaf-performance-summary (&optional (records (etaf-performance-records)))
;;;###autoload (autoload 'etaf-performance-summary "etaf" nil nil)
;; Summarize completed RECORDS by operation kind and label.
;; Omitted RECORDS selects all retained records; explicit nil selects none.
;;
;; Macro: etaf-performance-with-operation ((runtime kind label) &rest body)
;;;###autoload (autoload 'etaf-performance-with-operation "etaf" nil nil 'macro)
;; Evaluate BODY through RUNTIME's canonical operation boundary.
;;
;; Function: etaf-local-ref (name)
;;;###autoload (autoload 'etaf-local-ref "etaf" nil nil)
;; During Component setup, obtain a stable opaque Host reference for NAME,
;; a non-nil symbol or string. Equal names share a handle only within one
;; retained instance. Pass it to :ref and Host query, focus or event APIs;
;; expose it to callers explicitly when needed. It is neither state nor a key.
;; Only a committed Host resolves: failure preserves its previous target,
;; removal makes bounds/position queries return nil, and a new instance gets
;; a new handle. Calls outside setup or with invalid names signal
;; `etaf-component-definition-error`.
;;
;; Function: etaf-prop (name)
;;;###autoload (autoload 'etaf-prop "etaf" nil nil)
;; Return the current Component's stable read-only reactive input NAME.
;; Call during setup, then read with `etaf-value` in computed getters or watches.
;; NAME is a declared prop name or keyword; defaults are included. Plain prop
;; variables remain snapshots. Fine-grained bindings that read the prop update
;; only their own Host; watchers run in the same commit.
;; The Component owns the source; reads after disposal signal an error.
;;
;; Function: etaf-provide (key value)
;;;###autoload (autoload 'etaf-provide "etaf" nil nil)
;; Provide VALUE under stable Context KEY to the current subtree.
;;
;; Error: etaf-reactive-error
;; Invalid ETAF reactive operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-ref (initial-value &key test name)
;;;###autoload (autoload 'etaf-ref "etaf" nil nil)
;; Create a writable shallow reactive cell containing INITIAL-VALUE.
;; Lists, vectors, hash tables, records, functions and editor handles compare by
;; identity; other values use equal. Replacing an object notifies dependents
;; even when its contents match.
;;
;; TEST optionally compares old and new values.  NAME is used in diagnostics.
;;
;; Function: etaf-ref-p (x)
;;;###autoload (autoload 'etaf-ref-p "etaf" nil nil)
;;
;;
;; Function: etaf-refit (&optional runtime window)
;;;###autoload (autoload 'etaf-refit "etaf" nil nil)
;; Refit a mounted Runtime to the display window's current viewport size.
;; RUNTIME defaults to the Runtime of the current buffer, and WINDOW to the
;; window showing that buffer.  The width is the renderer's display-safe window
;; width, so the result matches what the renderer itself uses after a resize.
;; Return (WIDTH . HEIGHT) in pixels and lines, or nil when there is no mounted
;; Runtime or live window, which makes a call from a window-change hook a safe
;; no-op.  The framework already refits every mounted Runtime once a window
;; resize settles (see `etaf-runtime-viewport'), so call this only for windows
;; the resize notification does not cover, such as a buffer mounted before the
;; window manager displayed it.
;;
;; Function: etaf-render (view)
;;;###autoload (autoload 'etaf-render "etaf" nil nil)
;; Lower normalized VIEW to one atomic canonical Ebox input.
;; Host class/id, non-nil role and explicitly supplied aria-* attributes reach
;; Ebox selector subjects. ARIA nil remains a present nil attribute; comparison
;; uses ECSS value formatting. Ebox derives the disabled state from the same
;; :disabled interaction input used for focus and activation protection.
;; Selector relationships follow the rendered Host tree. Use Ebox's public
;; selector queries on the result; :selector-attributes and :selector-state
;; are adapter facts and cannot be supplied as View properties.
;;
;; This pure entry supports stateless Components.  Stateful Components require a
;;   Runtime because their setup Scope must have a lifecycle owner.
;;
;; Error: etaf-render-side-effect-error
;; ETAF render must be side-effect free
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-renderer-error
;; ETAF rendering error
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-resource (loader &key (immediate t) scope name timeout keep-value)
;;;###autoload (autoload 'etaf-resource "etaf" nil nil)
;; Create a Scope-owned Resource backed by LOADER.
;; LOADER returns a value, `etaf-resource-result', or a lazy `etaf-async' operation.
;; IMMEDIATE starts loading before returning; otherwise status starts as `idle'.
;; TIMEOUT is nil or positive seconds, applied to asynchronous waiting only.
;; With KEEP-VALUE non-nil, reload reports `refreshing' and retains the last
;; successful value until a replacement succeeds.  Failure or cancellation also
;; retains it.  Otherwise reload clears and cleans up the old value immediately.
;; The Resource owns a child Scope under SCOPE or the current Scope; without a
;; parent it is detached and the caller must dispose it.
;;
;; Function: etaf-resource-cancel (resource)
;;;###autoload (autoload 'etaf-resource-cancel "etaf" nil nil)
;; Cancel RESOURCE's pending load without disposing it, and return RESOURCE.
;; The first late completion is discarded, even when external work cannot be
;; cancelled.  The Resource may be loaded again.  No pending request is a no-op.
;;
;; Function: etaf-resource-dispose (resource)
;;;###autoload (autoload 'etaf-resource-dispose "etaf" nil nil)
;; Dispose RESOURCE and return cleanup errors collected by its Scope.
;;
;; Function: etaf-resource-error (resource)
;;;###autoload (autoload 'etaf-resource-error "etaf" nil nil)
;; Return RESOURCE's current loader failure or cancellation condition, or nil.
;;
;; Error: etaf-resource-error
;; Invalid ETAF Resource operation, such as reloading a disposed Resource.
;; Catch with condition-case. Loader failures are instead captured as Resource
;; state and inspected with the same-named reader function.
;;
;; Function: etaf-resource-load (resource)
;;;###autoload (autoload 'etaf-resource-load "etaf" nil nil)
;; Reload RESOURCE and return it, without waiting for asynchronous completion.
;; Cancel the previous request before starting the next.  Only the current
;; request can publish a result.  Loader failures become observable state;
;; cleanup and rendering failures still signal normally.  Reload after error,
;; timeout or cancellation retries the loader; no automatic retry is performed.
;;
;; Function: etaf-resource-result (value &key cleanup)
;;;###autoload (autoload 'etaf-resource-result "etaf" nil nil)
;; Return a Resource loader result containing VALUE and optional CLEANUP.
;;
;; CLEANUP must be nil or a zero-argument function.  The Resource runs it when
;; clearing or replacing the value and on disposal.  A first completion arriving
;; after cancellation is discarded and cleaned up; duplicate completions are
;; ignored.  A loader must transfer each result to only one Resource.
;;
;; Function: etaf-resource-status (resource)
;;;###autoload (autoload 'etaf-resource-status "etaf" nil nil)
;; Return RESOURCE status: idle, loading, refreshing, success, error or cancelled.
;;
;; Function: etaf-resource-value (resource)
;;;###autoload (autoload 'etaf-resource-value "etaf" nil nil)
;; Return RESOURCE's successful value, or nil before success.
;;
;; Function: etaf-runtime-buffer (x)
;;;###autoload (autoload 'etaf-runtime-buffer "etaf" nil nil)
;; Access slot "buffer" of `etaf-runtime' struct X.
;;
;; Function: etaf-current-runtime ()
;;;###autoload (autoload 'etaf-current-runtime "etaf" nil nil)
;; Return the Runtime that owns the current setup, lifecycle, or event
;; callback, or nil outside a Runtime operation.  Lifecycle code that needs
;; the mounted buffer must use `(etaf-runtime-buffer
;; (etaf-current-runtime))`; `current-buffer' is the caller's buffer and is
;; not guaranteed to be the mounted target when `etaf-mount' receives a name.
;;
;;
;; Error: etaf-runtime-error
;; ETAF runtime error
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-runtime-flush (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-flush "etaf" nil nil)
;; Settle mounted RUNTIME's pending reactive work and return its revision.
;; Work that a failed update discarded is retried with it.
;; Inside `etaf-call-with-batch' or a running commit the pending work stays
;; deferred to that boundary and the current revision is returned.
;; RUNTIME defaults to the Runtime of the current buffer.
;;
;; Function: etaf-runtime-revision (runtime)
;;;###autoload (autoload 'etaf-runtime-revision "etaf" nil nil)
;; Return RUNTIME's committed revision, an integer that increases once for
;; every commit that changed its buffer (ordinary reactive work, Host content
;; or geometry updates, and `etaf-runtime-refit' or `etaf-refit' calls that
;; changed the layout).  Tests and benchmarks compare revisions
;; to observe that a change was published.
;;
;; Function: etaf-runtime-update-report (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-update-report "etaf" nil nil)
;; Return the last buffer update report of mounted RUNTIME, or nil.
;; The plist is the engine's flush report for the last commit: its strategy,
;; the edited range count, the line count, the ranges and the flush counter.
;; RUNTIME defaults to the Runtime of the current buffer; a non-mounted
;; Runtime signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-set-input-finisher (runtime finisher)
;;;###autoload (autoload 'etaf-runtime-set-input-finisher "etaf" nil nil)
;; Set mounted RUNTIME's native input session finisher to FINISHER or nil.
;; The catalog's in-place text input registers a function while its session
;; is open; the framework runs it before a `press' dispatches to a Host
;; other than the edited Host, its descendants and the nearest Host framing
;; it, so a press elsewhere leaves the editing session.  FINISHER receives
;; RUNTIME and should finish the session with the application's own
;; keep/edit policy.  Setting nil removes
;; it.  A non-mounted Runtime or a non-function FINISHER signals an error.
;;
;; Function: etaf-runtime-input-finisher (x)
;;;###autoload (autoload 'etaf-runtime-input-finisher "etaf" nil nil)
;; Access slot "input-finisher" of `etaf-runtime' struct X.
;;
;; Function: etaf-runtime-for-buffer (buffer-or-name)
;;;###autoload (autoload 'etaf-runtime-for-buffer "etaf" nil nil)
;; Return the live Runtime mounted in BUFFER-OR-NAME, or nil.
;;
;; Function: etaf-runtime-handler-entries (runtime)
;;;###autoload (autoload 'etaf-runtime-handler-entries "etaf" nil nil)
;; Return committed handler contribution entries for RUNTIME.
;;
;; Function: etaf-runtime-host-ancestries (runtime host-refs)
;;;###autoload (autoload 'etaf-runtime-host-ancestries "etaf" nil nil)
;; Return committed semantic ancestries for HOST-REFS in RUNTIME.
;; The result is a hash table mapping each found reference to its lineage list
;; (REF PARENT-REF ... ROOT-REF).  Missing references are absent.  Callers use
;; it for overlapping hit tests; the lookup walks the retained Host parents.
;;
;; Function: etaf-runtime-host-props-entries (runtime)
;;;###autoload (autoload 'etaf-runtime-host-props-entries "etaf" nil nil)
;; Return committed Host contribution entries for RUNTIME.
;;
;; Function: etaf-runtime-host-props-for (runtime host-ref)
;;;###autoload (autoload 'etaf-runtime-host-props-for "etaf" nil nil)
;; Return committed semantic Host props for HOST-REF in RUNTIME.
;; The plist spine is fresh; contained values preserve identity and are
;; read-only. Later geometry publication does not replace fields in this copy.
;;
;; Function: etaf-runtime-update-host-content (runtime host-ref content)
;;;###autoload (autoload 'etaf-runtime-update-host-content "etaf" nil nil)
;; Replace HOST-REF's published content with CONTENT in mounted RUNTIME.
;;
;; This is the content half of the retained Host display boundary, next to
;; `etaf-runtime-update-host-geometry'.  CONTENT is a string, published as the
;; Host's text, or an image object as returned by `create-image', published as
;; one image cell showing that image at its own size; a caller that keeps a
;; fixed-size Host live with per-frame images (video, charts, captures) passes
;; a new image object per update. Strings retain caller-owned display
;; properties, including image slices. Use a Text Host for changing media:
;; replacing a Box's content changes its child structure instead.
;; The update replaces only the addressed Host
;; and publishes once through Ebox, so a caller whose controlled state changed
;; one value skips an ordinary ETAF publication.  The next ordinary publication
;; must render the same content, or the retained Host is reconciled to it.  A
;; committed update returns t.  Unknown Hosts, unmounted Runtimes, CONTENT that
;; is neither a string nor an image, and Hosts whose retained node cannot hold
;; content signal `etaf-runtime-error' without a partial update. Emacs builds
;; without native image support accept strings only; rejected values still
;; signal the same public error without changing the published content.
;;
;; Function: etaf-runtime-update-host-contents (runtime updates)
;;;###autoload (autoload 'etaf-runtime-update-host-contents "etaf" nil nil)
;; Replace several HOST-REF contents in one retained Ebox publication.
;;
;; UPDATES is an alist of committed Host references to replacement strings or
;; image objects.  Every target validates before the first replacement, so a
;; caller keeping several small contents live (text and frames together)
;; publishes once per change instead of once per node.  A committed update
;; returns t.  Invalid targets or updates, unmounted Runtimes, active Ebox
;; transactions, and rejected content signal `etaf-runtime-error' without a
;; partial update.
;;
;; Function: etaf-runtime-update-host-geometry (runtime host-ref &rest geometry)
;;;###autoload (autoload 'etaf-runtime-update-host-geometry "etaf" nil nil)
;; Set HOST-REF's position, size or layer properties in mounted RUNTIME.
;; GEOMETRY is a plist of style properties such as :left, :top, :width,
;; :height and :z-index.  Only the Host's relayout boundary is laid out and
;; its changed buffer region rewritten.  This is a display projection boundary for a
;; caller's already-updated controlled state: it does not change Component
;; props or implement window policy.  The next ordinary ETAF publication must
;; provide the same values, or the retained Host will be reconciled to that
;; publication.  A committed update returns t.  Invalid targets or geometry,
;; unmounted Runtimes, active Ebox transactions, and rejected geometry signal
;; `etaf-runtime-error' without a partial update.
;;
;; Function: etaf-runtime-update-host-geometries (runtime updates)
;;;###autoload (autoload 'etaf-runtime-update-host-geometries "etaf" nil nil)
;; Apply several HOST-REF/GEOMETRY pairs in one retained Ebox publication.
;; UPDATES is an alist whose keys are committed Host references and whose values
;; are geometry plists.  All targets validate before the batch starts and the
;; updates publish as one buffer write.  A committed update returns t.  Invalid
;; targets or updates, unmounted Runtimes, active Ebox transactions, and
;; rejected geometry signal `etaf-runtime-error' without a partial update.
;;
;; Hook: etaf-runtime-mount-functions
;; Hook run with one argument, RUNTIME, after `etaf-mount' publishes its initial View.
;; Individual observer errors are isolated so one observer cannot prevent other
;; observers or the mount from completing.
;;
;; Hook: etaf-runtime-after-commit-functions
;; Hook run with one argument, RUNTIME, after a mounted Runtime commits an
;; application change.  Presentation-only flushes and the initial mount do not
;; run this hook.  Individual observer errors are isolated.
;;
;; Hook: etaf-runtime-unmount-functions
;; Hook run with one argument, RUNTIME, when a mounted Runtime begins unmounting,
;; before its retained segments and buffer bindings are released.  Individual
;; observer errors are isolated.
;;
;; Hook: etaf-runtime-after-flush-functions
;; Hook run with one argument, RUNTIME, after an Ebox flush completes on a
;; mounted Runtime outside presentation-only mutations (including scroll-offset
;; changes inside `:overflow scroll' containers and viewport refits).
;; Individual observer errors are isolated.
;;
;; Hook: etaf-runtime-meta-change-functions
;; Hook run with `(RUNTIME META)' when a mounted Runtime's resolved metadata
;; plist changes.  Individual observer errors are isolated.
;;
;; Hook: etaf-runtime-focus-change-functions
;; Hook run with `(RUNTIME PREV-HOST-ID NEXT-HOST-ID)' when logical Host focus
;; changes in a mounted Runtime.  Individual observer errors are isolated.
;;
;; Function: etaf-runtime-meta (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-meta "etaf" nil nil)
;; Return a detached copy of mounted RUNTIME's resolved metadata plist, or nil.
;; RUNTIME defaults to the active or current-buffer Runtime.  An unmounted
;; Runtime signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-set-meta (runtime meta)
;;;###autoload (autoload 'etaf-runtime-set-meta "etaf" nil nil)
;; Set mounted RUNTIME's metadata plist to META and return the resolved plist.
;; META is nil or a proper plist whose values may be static data, `etaf-ref',
;; `etaf-computed' or zero-argument functions.  Reactive updates notify
;; `etaf-runtime-meta-change-functions'.  Forbidden during rendering.
;;
;; Function: etaf-runtime-host-tree (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-host-tree "etaf" nil nil)
;; Return the committed application Host tree of mounted RUNTIME as read-only data.
;; RUNTIME defaults to the active or current-buffer Runtime.  Each node is a
;; plist with `:id', `:ref', `:tag', `:text', `:props', `:geometry' and
;; `:children'.  Transient surfaces, overlays and attached presentation
;; companions are excluded, and `:text' always holds the application's
;; authoritative text even when a presentation overrides or decorates display.
;; An unmounted Runtime signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-host-geometries (runtime host-ids)
;;;###autoload (autoload 'etaf-runtime-host-geometries "etaf" nil nil)
;; Return live geometry and visibility for integer HOST-IDS in mounted RUNTIME.
;; Returns an alist of `(HOST-ID . PLIST)' entries holding `:x', `:y', `:width',
;; `:height', `:clip-top', `:clip-bottom' and `:visible-p'.  `:y' reflects all
;; enclosing `:overflow scroll' offsets and `:clip-top'/`:clip-bottom' intersect
;; clipping ancestors with the displaying window.  An unmounted Runtime or
;; non-list HOST-IDS signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-trigger-host-press (runtime host-id)
;;;###autoload (autoload 'etaf-runtime-trigger-host-press "etaf" nil nil)
;; Dispatch an enabled `press' event on committed integer HOST-ID in RUNTIME.
;; Return non-nil when dispatched, or nil when HOST-ID is absent or carries no
;; enabled `:on-press' handler.  An unmounted Runtime or non-integer HOST-ID
;; signals `etaf-runtime-error'.  Forbidden during rendering.
;;
;; Function: etaf-runtime-focus-host (runtime host-id)
;;;###autoload (autoload 'etaf-runtime-focus-host "etaf" nil nil)
;; Move logical focus to committed integer HOST-ID in mounted RUNTIME.
;; Return non-nil when focused, or nil when absent or ineligible.  An unmounted
;; Runtime or non-integer HOST-ID signals `etaf-runtime-error'.  Forbidden
;; during rendering.
;;
;; Function: etaf-runtime-scroll-host-into-view (runtime host-id &optional align)
;;;###autoload (autoload 'etaf-runtime-scroll-host-into-view "etaf" nil nil)
;; Scroll enclosing scrollers (and displaying Emacs window when needed) in
;; mounted RUNTIME so committed integer HOST-ID is visible.  ALIGN is nil,
;; `start' or `end'.  Return non-nil when HOST-ID was live.  Invalid arguments
;; signal `etaf-runtime-error'.  Forbidden during rendering.
;;
;; Function: etaf-runtime-host-text-offset-at (runtime &optional position)
;;;###autoload (autoload 'etaf-runtime-host-text-offset-at "etaf" nil nil)
;; Return text Host offset and active region info at POSITION in RUNTIME, or
;; nil when POSITION (default point) is not on a text Host.  Returns a plist
;; `(:id HOST-ID :offset CHAR-OFFSET :text TEXT :region REGION)'.  An unmounted
;; Runtime signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-set-overlay (runtime key view &optional origin)
;;;###autoload (autoload 'etaf-runtime-set-overlay "etaf" nil nil)
;; Mount, patch in place, or clear named root-layer overlay KEY with VIEW in
;; mounted RUNTIME without remounting application Components or firing
;; `etaf-runtime-after-commit-functions'.  KEY is a non-nil symbol; nil VIEW
;; removes KEY.  VIEW inherits ORIGIN's (or root's) Context and Theme.  Return
;; non-nil when changed.  Forbidden during rendering.
;;
;; Function: etaf-runtime-clear-overlay (runtime &optional key)
;;;###autoload (autoload 'etaf-runtime-clear-overlay "etaf" nil nil)
;; Remove named root-layer overlay KEY (or all overlays when KEY is nil) in
;; mounted RUNTIME and return the number removed.  Forbidden during rendering.
;;
;; Function: etaf-runtime-set-key-layer (runtime key entries &optional label priority)
;;;###autoload (autoload 'etaf-runtime-set-key-layer "etaf" nil nil)
;; Register or replace extension key layer KEY on mounted RUNTIME.  ENTRIES is
;; a list of `(KEY-DESC COMMAND [LABEL])' items; nil removes KEY.  Resolved
;; strictly below Host `:keys' and framework defaults, outside local/modal
;; boundaries.  Reserved keys signal `etaf-runtime-error'.  Returns active key
;; descriptions.  Forbidden during rendering.
;;
;; Function: etaf-runtime-clear-key-layer (runtime &optional key)
;;;###autoload (autoload 'etaf-runtime-clear-key-layer "etaf" nil nil)
;; Remove extension key layer KEY (or all when nil) from mounted RUNTIME and
;; return the count removed.  Forbidden during rendering.
;;
;; Function: etaf-runtime-set-host-presentation (runtime host-id key spec)
;;;###autoload (autoload 'etaf-runtime-set-host-presentation "etaf" nil nil)
;; Attach or update keyed presentation SPEC owned by non-nil symbol KEY on
;; integer HOST-ID in mounted RUNTIME.  SPEC is nil (clear KEY on HOST-ID) or a
;; plist with `:mode' (`decorate', `override', `companion-inside',
;; `companion-after' or `companion-beside'), optional integer `:priority'
;; (default 50), and mode payload (`:spans' / `:face' for `decorate', `:text'
;; or `:view' for `override', `:view' for companions).  Multiple keys coexist
;; cleanly on the same Host: decorations compose additively, companions order
;; by priority and overrides stack by priority.  Return non-nil when HOST-ID
;; was live and updated, or nil when absent.  Forbidden during rendering.
;;
;; Function: etaf-runtime-set-host-presentations (runtime key updates)
;;;###autoload (autoload 'etaf-runtime-set-host-presentations "etaf" nil nil)
;; Apply a list of `(HOST-ID . SPEC)' presentation UPDATES owned by KEY in
;; mounted RUNTIME in one atomic Ebox flush without firing
;; `etaf-runtime-after-commit-functions'.  Multiple keys coexist on the same
;; Host.  Unknown or unmounted HOST-IDs are skipped.  Return the number of
;; Hosts updated.  Invalid arguments signal `etaf-runtime-error'.  Forbidden
;; during rendering.
;;
;; Function: etaf-runtime-clear-presentations (runtime &optional key)
;;;###autoload (autoload 'etaf-runtime-clear-presentations "etaf" nil nil)
;; Remove attached presentations in mounted RUNTIME in one Ebox flush.  When
;; KEY is non-nil, clear only entries owned by KEY while keeping other owners
;; intact; otherwise clear all and restore every Host.  Return the number of
;; Hosts updated.  Forbidden during rendering.
;;
;; Function: etaf-runtime-list ()
;;;###autoload (autoload 'etaf-runtime-list "etaf" nil nil)
;; Return a list of all currently mounted live ETAF Runtimes ordered by mount
;; identity.
;;
;; Function: etaf-runtime-inspect-tree (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-inspect-tree "etaf" nil nil)
;; Return mounted RUNTIME's unified Component and Host tree as read-only data.
;; RUNTIME defaults to the active or current-buffer Runtime.  Each node carries
;; `:kind' (`component' or `host'), `:id', metadata and `:children'; transient
;; surfaces and presentation companions are excluded.  An unmounted Runtime
;; signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-host-id-at (runtime &optional position)
;;;###autoload (autoload 'etaf-runtime-host-id-at "etaf" nil nil)
;; Return `(INNERMOST-HOST-ID ... ROOT-HOST-ID)' at POSITION in mounted RUNTIME,
;; or nil when no Host covers POSITION (default point).  Presentation companion
;; nodes resolve to their owning application Host.  An unmounted Runtime signals
;; `etaf-runtime-error'.
;;
;; Function: etaf-runtime-inspect-host (runtime host-id)
;;;###autoload (autoload 'etaf-runtime-inspect-host "etaf" nil nil)
;; Return detailed read-only inspection snapshot for integer HOST-ID in mounted
;; RUNTIME, or nil when absent.  Computes box metrics, on-demand ECSS cascade
;; provenance and exact painted row spans without mutating buffers or caches.
;; Invalid arguments or an unmounted Runtime signal `etaf-runtime-error'.
;;
;; Function: etaf-runtime-inspect-component (runtime instance-id)
;;;###autoload (autoload 'etaf-runtime-inspect-component "etaf" nil nil)
;; Return detailed read-only snapshot for integer Component INSTANCE-ID in
;; mounted RUNTIME, or nil when absent.  Includes props, named bindings with
;; reactive metadata, Context bindings, local refs and render count.  Invalid
;; arguments or an unmounted Runtime signal `etaf-runtime-error'.
;;
;; Function: etaf-runtime-set-component-binding (runtime instance-id binding-name new-value)
;;;###autoload (autoload 'etaf-runtime-set-component-binding "etaf" nil nil)
;; Write NEW-VALUE to writable `etaf-ref' BINDING-NAME of Component INSTANCE-ID
;; in mounted RUNTIME and return t.  Signals `etaf-runtime-error' when RUNTIME
;; is unmounted, INSTANCE-ID or BINDING-NAME is unknown, or the binding is not a
;; writable `etaf-ref'.  Forbidden during rendering.
;;
;; Function: etaf-runtime-inspect-focus (runtime)
;;;###autoload (autoload 'etaf-runtime-inspect-focus "etaf" nil nil)
;; Return detached focus, region and effective key-scope diagnostics for mounted
;; RUNTIME.  An unmounted Runtime signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-commit-summary (runtime)
;;;###autoload (autoload 'etaf-runtime-commit-summary "etaf" nil nil)
;; Return a lightweight summary plist of mounted RUNTIME's latest commit with
;; `:rev', `:new-instances', `:updated-instances', `:retired-instances' and
;; `:update-report'.  An unmounted Runtime signals `etaf-runtime-error'.
;;
;; Function: etaf-runtime-instances (x)
;;;###autoload (autoload 'etaf-runtime-instances "etaf" nil nil)
;; Access slot "instances" of `etaf-runtime' struct X.
;;
;;
;; Function: etaf-runtime-mounted-p (x)
;;;###autoload (autoload 'etaf-runtime-mounted-p "etaf" nil nil)
;; Access slot "mounted-p" of `etaf-runtime' struct X.
;;
;;
;; Function: etaf-runtime-refit (runtime viewport-width &optional viewport-height)
;;;###autoload (autoload 'etaf-runtime-refit "etaf" nil nil)
;; Refit mounted RUNTIME to VIEWPORT-WIDTH pixels and VIEWPORT-HEIGHT lines.
;; A fixed dimension replaces window-size tracking for that dimension; a nil
;; dimension follows the displaying window, so an application that needs a
;; custom line count keeps an adaptive width with `(etaf-runtime-refit RUNTIME
;; nil LINES)'.  Viewport units and viewport-dependent layout are re-resolved
;; and the changed region rewritten.
;; Return non-nil when the layout changed.  The refit is one Runtime operation:
;; a mount `:observer' and `etaf-performance-mode' receive it as kind `refit'
;; with its Ebox flush report.  A native input session does not delay the
;; refit; it applies immediately like any other refit.  A non-mounted Runtime
;; signals `etaf-runtime-error' and non-positive sizes signal
;; `wrong-type-argument'.
;;
;; Function: etaf-runtime-viewport (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-viewport "etaf" nil nil)
;; Return mounted RUNTIME's canvas viewport as (WIDTH . HEIGHT).
;; WIDTH is pixels and HEIGHT is lines; the value matches the renderer's
;; display-safe window size and follows `etaf-runtime-refit', including the
;; automatic refit after a window size change.  RUNTIME defaults to the Runtime
;; in the current buffer, and a non-mounted Runtime signals
;; `etaf-runtime-error'.  The read is reactive: a render, computed or effect
;; that reads it reruns after the viewport changes, so a Component can size
;; fixed-grid content such as images and video to the window.
;;
;; Function: etaf-display-metrics (&optional runtime)
;;;###autoload (autoload 'etaf-display-metrics "etaf" nil nil)
;; Return a fresh plist with RUNTIME's effective default-face :char-width,
;; :line-height (positive pixels) and :ascent (image baseline percentage).
;; RUNTIME defaults to the current Component or buffer Runtime; an unmounted
;; Runtime signals `etaf-runtime-error'.  Text displays use unit cells and
;; 100 percent ascent.  The read is reactive: a render, effect or computed
;; reruns after settled buffer text scaling even when the viewport is fixed.
;; Image producers can repartition native pixel content into aligned rows
;; without resetting application state.
;;
;; Function: etaf-runtime-window-viewport (&optional runtime)
;;;###autoload (autoload 'etaf-runtime-window-viewport "etaf" nil nil)
;; Return RUNTIME's display-window viewport as (WIDTH . HEIGHT).
;; WIDTH is the width the window offers to a mounted tree: pixels on a
;; graphical frame, character cells on a text terminal.  HEIGHT is its body
;; height in lines.  Nil when no window displays RUNTIME's buffer; read
;; `etaf-runtime-viewport' for the canvas size instead.  A non-mounted Runtime
;; signals `etaf-runtime-error'.
;;
;; Function: etaf-scope-run (scope function)
;;;###autoload (autoload 'etaf-scope-run "etaf" nil nil)
;; Run FUNCTION with SCOPE active and return its value.  Effects, computeds,
;; watchers, child Scopes and cleanups created by FUNCTION belong to SCOPE.
;; An inactive SCOPE signals `etaf-reactive-error'.
;;
;; Function: etaf-scope-stop (scope)
;;;###autoload (autoload 'etaf-scope-stop "etaf" nil nil)
;; Dispose SCOPE and return cleanup conditions collected during teardown.
;; Stop child Scopes and owned effects, then run registered cleanup functions.
;; Errors and quits from cleanup are returned as condition data, not re-signaled;
;; remaining cleanup still runs. Stopping an already stopped Scope returns nil.
;; After stopping, SCOPE cannot be entered or accept effects or cleanup.
;; Call outside rendering; Component-owned Scopes are stopped automatically.
;;
;; Function: etaf-on-scope-dispose (function)
;;;###autoload (autoload 'etaf-on-scope-dispose "etaf" nil nil)
;; Register zero-argument FUNCTION for the current active Scope's disposal.
;; Return FUNCTION. Cleanup runs once, in reverse registration order, after
;; child Scopes and effects stop. A missing or stopped Scope signals an error.
;; Cleanup errors are collected by `etaf-scope-stop` without aborting teardown.
;;
;; Function: etaf-set-value (source new-value)
;;;###autoload (autoload 'etaf-set-value "etaf" nil nil)
;; Set writable reactive SOURCE to NEW-VALUE and return NEW-VALUE.
;;
;; Function: etaf-state ()
;;;###autoload (autoload 'etaf-state "etaf" nil nil)
;; Return the current Component instance's exact setup result.
;; The accessor is valid only while rendering a Component that declares setup.
;; A defined setup may return nil; setup presence is tracked independently.
;; Prefer named `:bindings' for handles used by the View and event callbacks.
;; Components using named bindings cannot also use this accessor.
;;
;; Function: etaf-surface-provide (surface)
;;;###autoload (autoload 'etaf-surface-provide "etaf" nil nil)
;; Provide SURFACE (`etaf-surface-create') to the current Component subtree.
;;
;; A host that frames content provides the slot, and the content declares its
;; own Theme, mode cell and mode labels on it with `etaf-surface-declare'.
;; The host reads the result after mounting; content outside such a host gets
;; nil from `etaf-surface-host' and keeps painting itself.
;;
;; Function: etaf-surface-host ()
;;;###autoload (autoload 'etaf-surface-host "etaf" nil nil)
;; Return the surface declaration of the nearest host, or nil.
;;
;; Call it from a Component `:setup' and declare only when it is non-nil, so
;; the same View works in a floating panel and in an ordinary buffer.
;;
;; Function: etaf-surface-create ()
;;;###autoload (autoload 'etaf-surface-create "etaf" nil nil)
;; Return an empty surface declaration for a host to provide.
;; The host provides it with `etaf-surface-provide' before rendering the
;; content and reads `etaf-surface-theme', `etaf-surface-mode' and
;; `etaf-surface-modes' afterwards.
;;
;; Function: etaf-surface-declare (surface &key theme mode modes)
;;;###autoload (autoload 'etaf-surface-declare "etaf" nil nil)
;; Declare the content's own surface on host SURFACE.
;;
;; THEME is a ref or computed holding the Theme plist the content paints
;; with, MODE a ref holding its current mode symbol, and MODES the ordered
;; alist of (MODE . LABEL) it can switch between.  A host paints its frame,
;; title bar and border from THEME and offers MODES as its switch, so the
;; content's palette and its switch stay one state: the host writes MODE, the
;; content reads it, and a change on either side repaints both.  Only the
;; keywords given are replaced.  An invalid value, or calling it while
;; rendering, signals an error before anything is stored.
;;
;; Function: etaf-surface-theme (surface)
;;;###autoload (autoload 'etaf-surface-theme "etaf" nil nil)
;; Return SURFACE's Theme source (a ref or computed), or nil.
;;
;; Function: etaf-surface-mode (surface)
;;;###autoload (autoload 'etaf-surface-mode "etaf" nil nil)
;; Return SURFACE's mode ref, or nil.  A host writes it to switch the content,
;; and the content's own switch writes the same ref.
;;
;; Function: etaf-surface-modes (surface)
;;;###autoload (autoload 'etaf-surface-modes "etaf" nil nil)
;; Return SURFACE's ordered alist of (MODE . LABEL), or nil.
;;
;; Function: etaf-string-pixel-width (string)
;;;###autoload (autoload 'etaf-string-pixel-width "etaf" nil nil)
;; Return the display pixel width of STRING's first line.
;; The measure honors STRING's `face' and `display' properties, so styled text
;; and plain text can measure differently.  A newline ends the measurement and
;; an empty string is zero.  A non-string signals `wrong-type-argument'.
;;
;; Function: etaf-theme-current-mode ()
;;;###autoload (autoload 'etaf-theme-current-mode "etaf" nil nil)
;; Return the current frame color mode as `light' or `dark'.
;;
;; This is only the default mode for palette resolution.  An application-owned
;; Theme toggle should pass its explicit mode to `etaf-theme-resolve-palette'
;; instead of changing the Emacs frame.  The function also ties its caller to
;; the theme-switch signal: a Theme computed that reads this value re-derives
;; once after an Emacs theme switch instead of keeping the mode it first read.
;;
;; Function: etaf-theme-provide (theme)
;;;###autoload (autoload 'etaf-theme-provide "etaf" nil nil)
;; Provide THEME property defaults to the current Component subtree.
;;
;; THEME is a property plist such as `(:color "#F4F6FB" :bgcolor "#202634")'.
;; Defaults enter Ebox as UA-origin declarations and follow ECSS precedence,
;; including UA-important precedence over author-important values. Normal Host
;; and Component declarations override normal defaults. Reactive ref/computed
;; plists remain tracked; invalid resolved values signal before the buffer is
;; written.
;;
;; Function: etaf-theme-resolve-palette (palette mode)
;;;###autoload (autoload 'etaf-theme-resolve-palette "etaf" nil nil)
;; Resolve semantic PALETTE token specs for explicit MODE.
;;
;; PALETTE is a keyword plist.  Each value may be a color string, a
;; `(LIGHT . DARK)' pair, or a `(:light LIGHT :dark DARK)' plist.  MODE is
;; `light' or `dark'.  The result is an ordinary Theme plist suitable for
;; `etaf-theme-provide'.  ETAF owns this semantic contract; a renderer-specific
;; palette package may adapt its own registry into this shape at the boundary.
;;
;; Function: etaf-theme-token (key &optional default transform)
;;;###autoload (autoload 'etaf-theme-token "etaf" nil nil)
;; Return a deferred Theme token for a static Component style.
;;
;; KEY is resolved when ETAF lowers the Component's `:styles' declaration, so a
;; static rule can use the current inherited Theme without turning every retained
;; Host into an inline dynamic property.  DEFAULT is used when KEY is absent.
;; TRANSFORM, when non-nil, is a pure function applied after nested defaults have
;; resolved; it lets a semantic color token lower to a backend value such as a
;; border specification without reading Theme during Component render.
;; The returned list is intentionally data, which also makes it safe to place
;; directly in a quoted `((SELECTOR PROPERTY VALUE ...) ...)' form.
;;
;; Function: etaf-theme-token-p (value)
;;;###autoload (autoload 'etaf-theme-token-p "etaf" nil nil)
;; Return non-nil when VALUE is a deferred ETAF Theme token.
;;
;; Function: etaf-toggleable (&rest attributes)
;;;###autoload (autoload 'etaf-toggleable "etaf" nil nil)
;; Return a Behavior converting ATTRIBUTES into a toggleable press action.
;;
;; `:value' and `:on-change' configure the action; all other attributes remain
;; part of the returned Behavior.
;;
;; Function: etaf-draggable-controlled (read on-change &key axis delta on-start on-move on-end on-cancel)
;;;###autoload (autoload 'etaf-draggable-controlled "etaf" nil nil)
;; Return a controlled drag Behavior for aggregate geometry state.  READ returns
;; a plist with :x/:y facts; ON-CHANGE receives the next detached plist.  AXIS
;; selects x, y or both.  DELTA converts Ebox pixel movement to caller units.
;; The Behavior retains only a transient gesture origin.  Construct the
;; Behavior once in a retained `:bindings' owner (or another retained owner),
;; not inside `:render': a render-created closure is a new handler identity and
;; cannot carry an active gesture across a parent projection.
;;
;; Function: etaf-resizable-controlled (read on-change &key edges min-width max-width min-height max-height delta on-start on-resize on-end on-cancel)
;;;###autoload (autoload 'etaf-resizable-controlled "etaf" nil nil)
;; Return a controlled resize Behavior for aggregate :x/:y/:width/:height
;; state.  EDGES defaults to right and bottom; READ supplies the current
;; numeric geometry and ON-CHANGE receives the next detached geometry plist.
;; Bounds and DELTA conversion are applied before the callback.  The Behavior
;; does not retain persistent application geometry.  Construct it once in a
;; retained `:bindings' owner when a parent may render during a gesture; a
;; render-created closure intentionally starts a fresh Behavior lifecycle.
;;
;; Function: etaf-draggable (&key x y axis delta on-start on-move on-end on-cancel)
;;;###autoload (autoload 'etaf-draggable "etaf" nil nil)
;; Return a Behavior that moves caller-owned numeric coordinate refs from Ebox
;; drag deltas.  X and Y must be writable `etaf-ref' values for the selected
;; AXIS (nil infers x, y, or both).  Each move and end writes the refs through
;; the normal reactive boundary; Ebox retains the gesture target and ETAF owns
;; no window or pointer state.  Optional callbacks receive the source gesture;
;; move/end run after writes and cancel leaves the last accepted values.
;; The Behavior also binds M-<arrow> keys (Move left/right/up/down along AXIS)
;; through `etaf-drag-step' so the Host moves one cell per key press;
;; `etaf-draggable-controlled' binds the same keys.
;;
;; Function: etaf-resizable (&key x y width height edges min-width max-width min-height max-height delta on-start on-resize on-end on-cancel)
;;;###autoload (autoload 'etaf-resizable "etaf" nil nil)
;; Return a Behavior that resizes caller-owned numeric geometry refs from Ebox
;; drag deltas.  EDGES defaults to right and bottom; left/top also update X/Y
;; so the opposite edge stays fixed.  WIDTH/HEIGHT and required coordinate refs
;; must be writable `etaf-ref' values.  Numeric min/max bounds clamp candidates
;; before publication.  Optional callbacks receive the source gesture and
;; resize/end run after refs are updated.  This Behavior has no desktop-window
;; policy and does not call Ebox private APIs.
;; It binds M-S-<arrow> keys (Wider, Narrower, Taller, Shorter) that grow or
;; shrink the dragged EDGES by one cell; `etaf-resizable-controlled' binds
;; the same keys.  Put move and resize Behaviors on separate Hosts, since one Host's
;; :on-drag handlers all receive every gesture.
;;
;; Function: etaf-transient-space-borrowed-p (window committed-rows)
;;;###autoload (autoload 'etaf-transient-space-borrowed-p "etaf" nil nil)
;; Return non-nil when transient UI borrows lines from WINDOW.
;; COMMITTED-ROWS is the body height WINDOW's caller last laid out for.  The
;; minibuffer and the echo area keep one body line at rest; while one of them
;; is taller (an active completion session, a wrapped prompt or message) its
;; extra lines are borrowed from the display windows.  While they are and
;; WINDOW is shorter than COMMITTED-ROWS, a caller that laid out for
;; COMMITTED-ROWS keeps that layout instead of recomputing one for the borrowed
;; height.  Growth, a nil commitment and a shorter window with no transient UI
;; are real geometry, so they return nil and the caller follows the window.
;;
;; Use this in a `window-size-change-functions' handler that fits application
;; layout state to its window, so a completion popup or prompt does not shrink
;; the application; the framework's own canvas already keeps its committed
;; viewport for the same borrow.
;;
;; Function: etaf-unmount (&optional runtime)
;;;###autoload (autoload 'etaf-unmount "etaf" nil nil)
;; Unmount RUNTIME, defaulting to the active or `current-buffer' Runtime.
;;
;; Function: etaf-value (source)
;;;###autoload (autoload 'etaf-value "etaf" nil nil)
;; Read reactive SOURCE and track the read in the current effect.
;;
;; Function: etaf-update-value (source function &rest arguments)
;;;###autoload (autoload 'etaf-update-value "etaf" nil nil)
;; Replace writable ref SOURCE with FUNCTION applied to its current value and
;; ARGUMENTS, returning the replacement.  For example:
;; (etaf-update-value count #'+ 2).  FUNCTION runs once; it must return a new
;; value without mutating the old value or performing external effects.
;; Rendering and read-only sources are rejected before FUNCTION runs.  An
;; updater error leaves the ref unchanged.  A later publication error retains
;; the application write, as with `etaf-set-value'.  Existing shallow equality,
;; reactive tracking and event batching apply; there is no implicit deep copy.
;;
;; Component: etaf-video (&key src (columns 100) (rows 30) (mode 'image) (ramp etaf-video-density-ramp) (audio etaf-video-audio) (volume etaf-video-audio-volume) (speed 1) (autoplay t) handle device-pixel-ratio display-fps position left top z-index)
;; Render a live video source in a fixed COLUMNS by ROWS canvas.
;;
;; SRC is nil for the built-in demo, a local file name, an HTTP(S) URL, or a
;; plist accepted by the video source normalizer.  A plist may name separate
;; video and audio streams with `:audio-url' and carry `:headers' and
;; `:proxy' for authenticated playback; `etaf-video-source-info' documents
;; the normalized keys.  MODE is `image' (one scaled
;; JPEG per frame, graphical frames only, falling back to `ascii' elsewhere),
;; `ascii' (one density-ramp character per pixel) or `color' (two full-color
;; pixels per `▀' half-block cell).  RAMP defaults to
;; `etaf-video-density-ramp', AUDIO/VOLUME/SPEED configure playback, and
;; AUTOPLAY starts it at mount; without AUTOPLAY the first frame is shown
;; paused.  DEVICE-PIXEL-RATIO overrides the display's device pixel ratio for
;; `image' frames so Retina screens stay sharp.  DISPLAY-FPS is nil (use
;; `etaf-video-display-fps') or a positive integer presentation-rate cap.
;; `etaf-video-render-backend' selects how a graphical frame reaches the
;; screen: `auto' (the default) prefers the native hardware `gpu' video layer
;; (macOS `CAOpenGLLayer', Windows Win32/WGL, Linux X11/Wayland EGL) when
;; `libmpv' and the platform GPU surface are available in a live graphical
;; frame (giving browser-grade low-CPU playback without recompiling Emacs),
;; then `canvas' if the `canvas' image type and `native/etaf-video-canvas' are
;; built, and falls back to `image'.  `gpu', `canvas' and `image' select a
;; specific backend; missing capabilities silently keep the `image' path, so an
;; application runs unchanged on released Emacs versions.  `ascii' and `color'
;; modes ignore this setting.
;; Image frames share one image across row-height slices so adjacent content
;; and controls below the canvas retain their normal line heights.  POSITION,
;; LEFT, TOP and Z-INDEX place the canvas; they are declared on the canvas node
;; itself so the retained content route can prove an inline placement winner
;; even when the canvas sits deep in an application layout.
;; AUDIO, VOLUME and SPEED also accept refs/computed sources; the Component
;; reads them in its playback effect, not its View. Live volume must stay
;; within 0..100 and speed must remain positive. Their identity can stay fixed
;; while a shared UI control updates the value without rebuilding the shell.
;;
;; HANDLE is a symbol registered while mounted for the `etaf-video-play'
;; family of control functions; a video without a handle still plays itself.
;;
;; Function: etaf-video-play (handle)
;;;###autoload (autoload 'etaf-video-play "etaf" nil nil)
;; Start or resume the mounted video identified by HANDLE.
;;
;; Function: etaf-video-pause (handle)
;;;###autoload (autoload 'etaf-video-pause "etaf" nil nil)
;; Pause the mounted video identified by HANDLE, keeping the last picture.
;;
;; Function: etaf-video-toggle-playback (handle)
;;;###autoload (autoload 'etaf-video-toggle-playback "etaf" nil nil)
;; Toggle the mounted video identified by HANDLE between play and pause.
;;
;; Function: etaf-video-step (handle)
;;;###autoload (autoload 'etaf-video-step "etaf" nil nil)
;; Pause the mounted video identified by HANDLE and present one more frame.
;;
;; Function: etaf-video-step-back (handle)
;;;###autoload (autoload 'etaf-video-step-back "etaf" nil nil)
;; Pause the mounted video identified by HANDLE and step backward one frame.
;; On libmpv this steps backward frame-accurately; on ffmpeg it seeks back 1s.
;;
;; Function: etaf-video-seek (handle seconds)
;;;###autoload (autoload 'etaf-video-seek "etaf" nil nil)
;; Move the mounted video identified by HANDLE to SECONDS.  A playing video
;; continues from there; a paused video presents that frame and stays paused.
;;
;; Function: etaf-video-set-speed (handle speed)
;;;###autoload (autoload 'etaf-video-set-speed "etaf" nil nil)
;; Set the playback rate of the mounted video identified by HANDLE.
;;
;; Function: etaf-video-set-volume (handle volume)
;;;###autoload (autoload 'etaf-video-set-volume "etaf" nil nil)
;; Set the audio volume of the mounted video identified by HANDLE, 0 to 100.
;;
;; Function: etaf-video-set-audio (handle audio)
;;;###autoload (autoload 'etaf-video-set-audio "etaf" nil nil)
;; Turn the audio sidecar of the mounted video identified by HANDLE on or off.
;;
;; Function: etaf-video-set-property (handle name value)
;;;###autoload (autoload 'etaf-video-set-property "etaf" nil nil)
;; Set playback engine property NAME to VALUE on mounted video HANDLE.
;; Supported on the libmpv engine; returns nil on engines without properties.
;;
;; Function: etaf-video-get-property (handle name &optional type)
;;;###autoload (autoload 'etaf-video-get-property "etaf" nil nil)
;; Read playback engine property NAME from mounted video HANDLE.
;; TYPE is `node' (default), `string', `bool', `int' or `float'.
;;
;; Function: etaf-video-command (handle &rest args)
;;;###autoload (autoload 'etaf-video-command "etaf" nil nil)
;; Send engine command ARGS to mounted video HANDLE (libmpv engine).
;;
;; Function: etaf-video-mpv-available-p ()
;;;###autoload (autoload 'etaf-video-mpv-available-p "etaf" nil nil)
;; Return non-nil when the cross-platform libmpv native backend is available.
;;
;; Function: etaf-video-gpu-available-p ()
;;;###autoload (autoload 'etaf-video-gpu-available-p "etaf" nil nil)
;; Return non-nil when the native hardware GPU video layer is available.
;;
;; Function: etaf-video-source-info (source)
;;;###autoload (autoload 'etaf-video-source-info "etaf" nil nil)
;; Return SOURCE's normalized playback metadata as a plist.
;;
;; SOURCE is nil for the built-in demo, a local file name, an HTTP(S) URL, or
;; a plist accepted by the `etaf-video' Component.  A local file name may
;; start with `~' or be relative to `default-directory'; it is expanded to an
;; absolute `:file' and `:target' before the decoders run.  The result holds
;; `:kind', `:file', `:url', `:target', `:audio-url', `:audio-target',
;; `:headers', `:proxy', `:width', `:height', `:duration', `:fps' and
;; `:audio'.  A source
;; whose video and audio are separate HTTP(S) streams describes them with
;; `:audio-url'; `:headers' (an alist, a hash table or one `Name: value'
;; string) and `:proxy' apply to every request both decoders make.  A present
;; `:audio-url' implies `:audio'.  Values come from ffprobe when it runs; a
;; missing ffprobe keeps documented defaults.  The result is authoritative
;; metadata and can be passed back as the Component's `:src' without another
;; probe, so an application that resizes or restarts a video keeps them.
;; Unsupported sources, unreadable files and malformed network options signal
;; `user-error'.
;;
;; Function: etaf-video-state (handle)
;;;###autoload (autoload 'etaf-video-state "etaf" nil nil)
;; Return the mounted video identified by HANDLE as a detached plist.
;; Keys are `:handle', `:engine', `:render-backend', `:mode', `:source',
;; `:playing', `:position', `:duration', `:speed', `:format', `:width',
;; `:height', `:display-fps', `:source-fps', `:received', `:presented',
;; `:dropped', `:audio', `:buffering', `:error' and `:ended'.  A handle with
;; no mounted video signals `user-error'.
;;
;; Variable: etaf-video-audio
;; Whether new videos play their source's audio track by default.
;; A `etaf-video' Component's `:audio' property overrides it per instance.
;;
;; Variable: etaf-video-audio-volume
;; Default audio volume for new videos, from 0 to 100.
;;
;; Variable: etaf-video-density-ramp
;; Characters used for one video pixel in the `ascii' render mode,
;; from darkest to lightest; must be nonempty and single-line.
;;
;; Variable: etaf-video-display-fps
;; Display timer rate in frames per second for new video playback.
;; It caps the presented frame rate; values below 1 are raised to 1.
;;
;; Variable: etaf-video-render-backend
;; Rendering backend for graphical `etaf-video' playback: `auto' (default),
;; `gpu', `canvas' or `image'.
;; `auto' prefers the native hardware `gpu' video layer when `libmpv' and the
;; platform GPU surface are ready on a live graphical frame (macOS
;; `CAOpenGLLayer', Windows Win32/WGL, Linux X11/Wayland EGL), then `canvas'
;; when Emacs supports canvas images and `native/etaf-video-canvas' is built,
;; and falls back to `image'.  `gpu' requests the native GPU overlay and falls
;; back to `image' when unavailable.  `canvas' reads BGRA frames into one
;; Emacs canvas image in place.  `image' forces the pure-Emacs image frame
;; pipeline (file-backed TIFF ring under `libmpv', JPEG under `ffmpeg').
;; Missing capabilities or non-graphical frames silently keep `image'.
;; `ascii' and `color' modes ignore this setting.
;;
;; Variable: etaf-video-engine
;; Playback engine for `etaf-video': `auto' (default), `mpv' or `ffmpeg'.
;; `auto' uses the optional cross-platform libmpv native module on graphical
;; frames in `image' mode and falls back to `ffmpeg' otherwise.
;;
;; Variable: etaf-video-mpv-library
;; Optional explicit path to the libmpv shared library (`dylib', `so' or `dll').
;;
;; Variable: etaf-video-ffmpeg-program
;; Name or absolute path of the ffmpeg executable used to decode video.
;;
;; Variable: etaf-video-ffplay-program
;; Name or absolute path of the ffplay executable used for audio.
;;
;; Variable: etaf-video-ffprobe-program
;; Name or absolute path of the ffprobe executable used for metadata.
;;
;; Macro: etaf-view (form &optional _environment)
;;;###autoload (autoload 'etaf-view "etaf" nil nil 'macro)
;; Construct a normalized ETAF View from structural FORM.
;;
;; FORM uses one grammar for Hosts and Component calls:
;;
;;   (NAME :PROPERTY VALUE ... CHILD ...)
;;
;; Properties must come first and children must come last.  Property values are
;; ordinary Elisp expressions.  In structural child positions, `(expr FORM)'
;; returns nil, strings, typed Views, or proper sequences of those values.
;; Inside a `text' Host, an expression must return one string.
;;
;; The core Hosts are `text', `box', `row', `column', `flex', `grid' and
;; `image'.  `image' renders one local media source as a fixed cell grid and
;; takes :src (a file path, or an image descriptor such as `create-image'
;; returns with :type and :data or :file, for in-memory thumbnails and
;; generated SVG), :columns and :rows (positive integers) plus an optional
;; :adapter (`auto', `text' or `placeholder').  The source is scaled to fill
;; the grid exactly; callers preserve aspect ratios by choosing the grid.
;; :inset (TOP . BOTTOM), pixels under one line height, leaves a graphics
;; image that much empty space inside its first and last rows, showing the
;; surrounding background, for a sub-line gap from adjacent text.
;; Unreadable or
;; undecodable sources become a placeholder instead of failing the render, and
;; the image owns its size, clipping and wrapping; wrap it in ordinary Boxes
;; for spacing, paint and interaction.
;;
;; Error: etaf-view-error
;; Invalid ETAF View
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: etaf-view-syntax-error
;; Invalid ETAF View syntax
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-canvas-cell (&optional runtime)
;;;###autoload (autoload 'etaf-canvas-cell "etaf" nil nil)
;; Return the cell the canvas draws as (CHAR-WIDTH . LINE-HEIGHT) pixels.
;; A canvas resolves `ch' and `lh' with this cell, so a layout that turns
;; pixels into cells divides by it rather than by the frame's face.
;;
;; Function: etaf-canvas-columns (&optional runtime)
;;;###autoload (autoload 'etaf-canvas-columns "etaf" nil nil)
;; Return how many whole cells wide RUNTIME's canvas viewport is.
;; A reactive read: a render that fits its layout this way reruns when the
;; viewport or the cell changes.
;;
;; Function: etaf-fit-columns (available preferred minimum &optional gap)
;;;###autoload (autoload 'etaf-fit-columns "etaf" nil nil)
;; Return (:across N :item W :offset O) fitting AVAILABLE canvas cells.
;; Items want PREFERRED cells and keep at least MINIMUM, GAP defaults to 3;
;; a column is added only while every item keeps its minimum, and OFFSET is
;; the cells to leave on one side so the remainder is symmetric.
;;
;; Function: etaf-viewport ()
;;;###autoload (autoload 'etaf-viewport "etaf" nil nil)
;; Return the viewport of the current Component subtree as (PIXELS . ROWS).
;; PIXELS is the width in pixels and ROWS the height in lines.  Inside an
;; `etaf-viewport-region' the value is that region's committed size; elsewhere
;; it is the mounted Runtime's viewport (see `etaf-runtime-viewport').  A
;; region reads as nil until its first flush commits geometry.
;;
;; The value is reactive: a render, effect or computed that reads it runs
;; again after the region or Runtime viewport changes.  Wrap application
;; content in `etaf-viewport-region' to make one application lay out for
;; whatever region hosts it instead of the whole mount.
;;
;; Component: etaf-viewport-region ()
;; Wrap its content in a nested viewport region.
;;
;; The region fills the space its parent gives it and publishes its committed
;; box as the viewport of every Component below it (see `etaf-viewport').
;; Application content wrapped in it lays out for the region instead of the
;; whole mount.  Host attributes passed at the call site (`:class', `:width',
;; `:height' and the other Host attributes) override the region's own
;; defaults.
;;
;; Do not give a region padding or a border: its border box is the published
;; viewport, so inset the content inside the region instead.
;;
;; Function: etaf-selector (source &key (test 'equal) name)
;;;###autoload (autoload 'etaf-selector "etaf" nil nil)
;; Return a function of KEY that is non-nil while reactive SOURCE equals KEY.
;; TEST is a hash table test (eq, eql or equal).  A reader depends only on its
;; own KEY, so moving a selection across a long list notifies the two affected
;; rows instead of every row.  Create it during Component setup or bindings;
;; the Scope owns its watcher.  Read it inside the View property or render it
;; updates, for example :background-color (if (funcall selected id) ...).
;;
;; Function: etaf-watch (source callback &key immediate (flush 'pre) test name)
;;;###autoload (autoload 'etaf-watch "etaf" nil nil)
;; Watch SOURCE and call CALLBACK with NEW and OLD values.
;;
;; SOURCE is a ref, computed or zero-argument function.  IMMEDIATE calls
;; CALLBACK for the initial value.  FLUSH is `pre' (before mounted Runtimes
;; write their buffers) or `post' (after).  TEST and NAME customize comparison
;; and diagnostics.  When CALLBACK returns a function, it runs before the next
;; callback and when the watcher stops.  Return a zero-argument stop function.
;; A watcher created during Component setup runs its callback in that
;; Component's environment on every later run, so Context and Runtime reads
;; inside the callback keep working after the first run.
;;
;; Function: etaf-watch-effect (function &key (flush 'pre) name)
;;;###autoload (autoload 'etaf-watch-effect "etaf" nil nil)
;; Run FUNCTION immediately and again after a reactive dependency change.
;;
;; FLUSH is `pre' or `post' as in `etaf-watch'.  NAME optionally labels the
;; effect.  If FUNCTION returns a function, it cleans up the previous run and
;; runs when the effect stops.  Return a zero-argument stop function.
;; An effect created during Component setup runs in that Component's
;; environment on every later run, so Context and Runtime reads inside it keep
;; working after the first run.
;;

;; Function: etaf-retained-resize-open (&optional buffer-or-name)
;;;###autoload (autoload 'etaf-retained-resize-open "etaf" nil t)
;; Mount a fixed-text resize example, returning BUFFER-OR-NAME (default
;; *ETAF Retained Resize*). Interactive calls display it. Native drag and
;; Shift-locked drag resize a clipped panel through controlled state and the
;; ordinary mounted Runtime; Escape restores its starting dimensions.
;; This example does not implement catalog window chrome or paragraph reflow.
;; Reopening replaces its existing mount; unrelated nonempty buffers are refused.
;; Unmount or kill the buffer to release it.
;;
;; Function: etaf-animation-example-open ()
;;;###autoload (autoload 'etaf-animation-example-open "etaf" nil t)
;; Mount the twenty-panel animation theatre and return its buffer; display it
;; when called interactively.  Includes pause, speed, frame-rate, theme and
;; native editing controls.  Cards reflow from four columns to one, controls
;; wrap, and content scrolls vertically.  Use at least 28 columns by 12 lines;
;; smaller windows clip the minimum canvas.  Only one theatre
;; owns the shared clock controls; unmount restores the previous clock settings.
;;
;; Function: etaf-resource-example-open ()
;;;###autoload (autoload 'etaf-resource-example-open "etaf" nil t)
;; Mount the asynchronous Resource example in *ETAF Resource Example* and
;; return that buffer. Interactive calls display it. Reloading, simulated
;; failure and cancellation use the displayed buttons. Repeated opens replace
;; the previous mount, releasing its pending work and loaded value.
;;
;; Function: etaf-resource-example-close ()
;;;###autoload (autoload 'etaf-resource-example-close "etaf" nil t)
;; Unmount and kill *ETAF Resource Example*. Repeated closing is harmless.
;;
;; Function: etaf-list-cache-create (&key interval grace max-backoff stop-codes)
;;;###autoload (autoload 'etaf-list-cache-create "etaf" nil nil)
;; Return a list cache with INTERVAL seconds of freshness and GRACE seconds.
;; A session keeps one cache and stores each list under its own key together
;; with the time it arrived, so a list can be shown at once and compared with a
;; fresh reply in the background (stale-while-revalidate).  INTERVAL defaults
;; to 120 and GRACE to 3: no background refresh starts in the first GRACE
;; seconds after the cache is started or armed.  Failed refreshes back off
;; (doubling up to MAX-BACKOFF seconds, default 1800) and one that fails with
;; a STOP-CODE (auth and blocked by default) pauses them until a load
;; succeeds.
;;
;; Function: etaf-list-cache-put (cache key rows total &key version at)
;;;###autoload (autoload 'etaf-list-cache-put "etaf" nil nil)
;; Cache ROWS and TOTAL under KEY and return the stored entry.
;; The entry records its arrival time, which is what the staleness rule and the
;; background refresh order read; the backend reply stays the source of truth.
;; VERSION, when the backend offers a version token, is stored so a caller can
;; send it with the next request. AT optionally supplies a persisted observation
;; time (nonnegative seconds since epoch); future times are clamped to now.
;; Omitting AT records the current time. Invalid AT leaves the cache unchanged.
;;
;; Function: etaf-list-cache-version (cache key)
;;;###autoload (autoload 'etaf-list-cache-version "etaf" nil nil)
;; Return KEY's stored version token, or nil.
;;
;; Function: etaf-list-cache-touch (cache key &optional version)
;;;###autoload (autoload 'etaf-list-cache-touch "etaf" nil nil)
;; Mark KEY's entry as just checked without replacing its rows.
;; A backend that answers that nothing changed for a conditional request
;; reports it here, so the entry is fresh again and no repaint happens.
;;
;; Function: etaf-list-cache-note-success (cache)
;;;###autoload (autoload 'etaf-list-cache-note-success "etaf" nil nil)
;; Record that a load succeeded: clear the failure backoff and any pause.
;;
;; Function: etaf-list-cache-note-failure (cache &optional code)
;;;###autoload (autoload 'etaf-list-cache-note-failure "etaf" nil nil)
;; Record that a load failed with error CODE and throttle the retries.
;; An unknown CODE backs the next attempt off; a stop-code (auth, blocked)
;; pauses background refreshes until a load succeeds.
;;
;; Function: etaf-list-cache-blocked-p (cache)
;;;###autoload (autoload 'etaf-list-cache-blocked-p "etaf" nil nil)
;; Return non-nil when CACHE paused background refreshes until a load succeeds.
;;
;; Function: etaf-list-cache-retry-at (cache)
;;;###autoload (autoload 'etaf-list-cache-retry-at "etaf" nil nil)
;; Return the time before which CACHE starts no background refresh, or nil.
;;
;; Function: etaf-list-cache-entry (cache key)
;;;###autoload (autoload 'etaf-list-cache-entry "etaf" nil nil)
;; Return KEY's cached entry (:rows :total :at), or nil.
;;
;; Function: etaf-list-cache-rows (cache key)
;;;###autoload (autoload 'etaf-list-cache-rows "etaf" nil nil)
;; Return KEY's cached rows, or nil.
;;
;; Function: etaf-list-cache-total (cache key)
;;;###autoload (autoload 'etaf-list-cache-total "etaf" nil nil)
;; Return KEY's cached total, or 0.
;;
;; Function: etaf-list-cache-stale-p (cache key &optional now interval)
;;;###autoload (autoload 'etaf-list-cache-stale-p "etaf" nil nil)
;; Return non-nil when KEY's entry is older than INTERVAL seconds.
;; NOW defaults to the current time and INTERVAL to the cache's own interval;
;; a key without an entry is missing rather than stale.
;;
;; Function: etaf-list-cache-unchanged-p (cache key rows total)
;;;###autoload (autoload 'etaf-list-cache-unchanged-p "etaf" nil nil)
;; Return non-nil when ROWS and TOTAL equal what KEY already holds.
;; A caller uses this to leave the page untouched when a background reply did
;; not change anything.
;;
;; Function: etaf-list-cache-next (cache keys &optional now interval)
;;;###autoload (autoload 'etaf-list-cache-next "etaf" nil nil)
;; Return the KEY that a background refresh should load next, or nil.
;; KEYS is the caller's ordered list of candidates; the stalest stale entry
;; comes first, and when every entry is fresh the first KEY without an entry is
;; warmed.  Nil while the cache is busy, inside its grace period, or when every
;; KEY is fresh and cached, so one refresh runs at a time.
;;
;; Function: etaf-list-cache-start (cache)
;;;###autoload (autoload 'etaf-list-cache-start "etaf" nil nil)
;; Start CACHE: begin its grace period and allow background refreshes.
;; A caller that already runs its own timer starts the cache once and then asks
;; `etaf-list-cache-next' what to load.
;;
;; Function: etaf-list-cache-arm (cache function &key interval)
;;;###autoload (autoload 'etaf-list-cache-arm "etaf" nil nil)
;; Arm CACHE to call FUNCTION every INTERVAL seconds until disarmed.
;; Uses INTERVAL, or the cache's own interval.  Arming again replaces the
;; previous timer and restarts the grace period; FUNCTION takes no arguments
;; and usually loads the key `etaf-list-cache-next' returns.
;;
;; Function: etaf-list-cache-armed-p (cache)
;;;###autoload (autoload 'etaf-list-cache-armed-p "etaf" nil nil)
;; Return non-nil when CACHE has a background refresh timer armed.
;;
;; Function: etaf-list-cache-busy-p (cache)
;;;###autoload (autoload 'etaf-list-cache-busy-p "etaf" nil nil)
;; Return non-nil when CACHE has a background refresh in flight.
;;
;; Function: etaf-list-cache-set-busy (cache busy)
;;;###autoload (autoload 'etaf-list-cache-set-busy "etaf" nil nil)
;; Record that CACHE has, or has not, a background refresh in flight.
;;
;; Function: etaf-list-cache-disarm (cache)
;;;###autoload (autoload 'etaf-list-cache-disarm "etaf" nil nil)
;; Stop CACHE's background refresh and clear its busy marker.
;; Call it when the owning session is disposed; a disarmed cache reports no
;; background work even after its entries grow old.
;;
;; Function: etaf-activity-publish (id plist)
;;;###autoload (autoload 'etaf-activity-publish "etaf" nil nil)
;; Publish or update live cross-application activity ID from PLIST.
;; ID is a non-nil symbol, nonempty string or cons cell compared with `equal'.
;; PLIST carries `:title' (required nonempty string) and optional `:app',
;; `:kind' (`media', `timer', `task', `inbox', `schedule' or `status'),
;; `:state' (`active', `paused' or `idle'), `:priority' (number, default 50),
;; `:subtitle', `:compact', `:icon', `:tone', `:progress', `:meter',
;; `:actions', `:open' and `:owner-runtime' (auto-removes on unmount).
;; Returns a detached copy of the stored activity plist.  Signals
;; `etaf-runtime-error' on invalid arguments.
;;
;; Function: etaf-activity-remove (id)
;;;###autoload (autoload 'etaf-activity-remove "etaf" nil nil)
;; Remove live cross-application activity ID and return non-nil if it existed.
;;
;; Function: etaf-activity-get (id)
;;;###autoload (autoload 'etaf-activity-get "etaf" nil nil)
;; Return a detached copy of live cross-application activity ID, or nil.
;;
;; Function: etaf-activity-list (&optional kind)
;;;###autoload (autoload 'etaf-activity-list "etaf" nil nil)
;; Return ordered detached snapshots of live activities, optionally for KIND.
;; Active activities precede paused and idle ones; ties break by descending
;; `:priority' and newest `:updated-at'.  Signals `etaf-runtime-error' on an
;; unknown KIND.
;;
;; Function: etaf-activity-ref ()
;;;###autoload (autoload 'etaf-activity-ref "etaf" nil nil)
;; Return the shared reactive ref holding ordered live activity snapshots.
;; Shells subscribe to this ref instead of polling applications.
;;
;; Function: etaf-activity-invoke (id action-id)
;;;###autoload (autoload 'etaf-activity-invoke "etaf" nil nil)
;; Invoke ACTION-ID (or `open') declared on live activity ID.
;; Signals `etaf-runtime-error' when ID or ACTION-ID is not registered.
;;
;; Hook: etaf-activity-change-functions
;; Hook run with `(EVENT ID ENTRY)' when live activities change.
;; EVENT is `publish' or `remove'; ENTRY is a detached plist or nil.
;; Individual observer errors are isolated.
;;
;; Function: etaf-notify (title &key id app detail (variant 'info) (ttl 5.0) group actions)
;;;###autoload (autoload 'etaf-notify "etaf" nil nil)
;; Publish notification TITLE to ETAF shell consumers and return a detached entry.
;; VARIANT is `info', `success', `warning' or `danger'; TTL is nonnegative
;; seconds (0 disables auto-collapse).  When GROUP matches an existing entry,
;; replaces it in place with an incremented `:count'.  Falls back to `message'
;; when `etaf-notify-functions' has no observers.
;;
;; Function: etaf-notify-dismiss (&optional id)
;;;###autoload (autoload 'etaf-notify-dismiss "etaf" nil nil)
;; Dismiss notification ID (or the newest entry when nil) and return remaining list.
;;
;; Function: etaf-notify-clear ()
;;;###autoload (autoload 'etaf-notify-clear "etaf" nil nil)
;; Clear all stored ETAF notifications and return nil.
;;
;; Function: etaf-notify-list ()
;;;###autoload (autoload 'etaf-notify-list "etaf" nil nil)
;; Return detached list of stored ETAF notifications, newest first.
;;
;; Function: etaf-notify-ref ()
;;;###autoload (autoload 'etaf-notify-ref "etaf" nil nil)
;; Return the shared reactive ref holding stored ETAF notifications.
;;
;; Hook: etaf-notify-functions
;; Hook run with `(ENTRY)' when `etaf-notify' records a notification.
;; Individual observer errors are isolated.  Presence of an observer suppresses
;; the fallback echo-area message.
;;
;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf.el" dir))
                                (file-exists-p (expand-file-name "etaf.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-view)
(require 'etaf-measure)
(require 'etaf-compiler)
(require 'etaf-component)
(require 'etaf-reactive)
(require 'etaf-animation)
(require 'etaf-observer)
(require 'etaf-context)
(require 'etaf-resource)
(require 'etaf-data)
(require 'etaf-runtime)
(require 'etaf-behavior)
(require 'etaf-controlled-behavior)
(require 'etaf-actions)
(require 'etaf-list-cache)
(require 'etaf-events)
(require 'etaf-keys)
(require 'etaf-regions)
(require 'etaf-help)
(require 'etaf-performance)
(require 'etaf-viewport)
(require 'etaf-app)
(require 'etaf-fullscreen)
(require 'etaf-pip)
(require 'etaf-process)
(require 'etaf-video-component)
(require 'etaf-projection)
(require 'etaf-inspect)
(require 'etaf-activity)

(autoload 'etaf-animation-example-open "examples/etaf-animation-example" nil t)
(autoload 'etaf-retained-resize-open "examples/etaf-retained-resize" nil t)
(autoload 'etaf-resource-example-open "examples/etaf-resource-example" nil t)
(autoload 'etaf-resource-example-close "examples/etaf-resource-example" nil t)

(provide 'etaf)
;;; etaf.el ends here
