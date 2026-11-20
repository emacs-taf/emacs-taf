;;; etaf-reactive.el --- Reactive cells, effects and scopes -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ETAF has one reactive graph.  Refs hold values, computeds cache derived
;; values lazily, and effects re-run when what they read changes.  A write
;; colors its direct observers dirty and their transitive observers "check";
;; queued effects then pull dirty computeds in dependency order, so an effect
;; whose computed inputs compare unchanged is skipped and no effect observes
;; a half-updated graph.
;;
;; Effects run in three phases: pre (watchers), render (Runtime bindings) and
;; post (post-flush watchers).  The outermost batch, or a write outside any
;; batch, drains the queues; between the render and post phases the drain
;; calls `etaf--drain-commit-function' so Runtimes write their buffers once.
;; Errors from individual effects are collected and the first is re-signaled
;; after the drain completes.
;;
;; Dependency lists are per observer.  Each source keeps a list of observers;
;; dropping a dependency removes the observer from short lists immediately and
;; lazily from long ones, so disposing many observers of one shared source is
;; amortized linear.

;;; Code:

(require 'cl-lib)
(require 'gv)

(define-error 'etaf-reactive-error "Invalid ETAF reactive operation")
(define-error 'etaf-render-side-effect-error
  "ETAF render must be side-effect free"
  'etaf-reactive-error)

;;;; Graph records

(cl-defstruct (etaf--source (:constructor nil) (:copier nil))
  "Common reactive source state."
  value test (version 0) subs (nsubs 0) (dead 0) (mark 0) name)

(cl-defstruct (etaf-ref (:include etaf--source)
                        (:constructor etaf--ref-create)
                        (:copier nil))
  "A writable shallow reactive cell.")

(cl-defstruct (etaf-computed (:include etaf--source)
                             (:constructor etaf--computed-create)
                             (:copier nil))
  "A lazy cached reactive value."
  getter deps (state 2) evaluated evaluating (active t))

(cl-defstruct (etaf-effect (:constructor etaf--effect-create) (:copier nil))
  "A dependency-tracked computation."
  fn deps (state 0) (phase 0) (id 0) home (active t) running on-stop
  owner data name)

(cl-defstruct (etaf-effect-scope (:constructor etaf--effect-scope-create)
                                 (:copier nil))
  "A tree of effects and cleanups with one disposal boundary."
  parent effects children cleanups name (active-p t))

;;;; Dynamic state

(defvar etaf--observer nil
  "The computed or effect collecting dependencies, or nil.")

(defvar etaf--observed nil
  "Sources read by `etaf--observer' during its current run.")

(defvar etaf--observe-stamp 0
  "Mark identifying the current tracking run.")

(defvar etaf--stamp 0
  "Monotonic mark counter for tracking and dependency diffs.")

(defvar etaf--effect-counter 0
  "Monotonic effect id; earlier effects run first within a phase.")

(defvar etaf--tracking-enabled-p t
  "Whether reactive reads may collect dependencies.")

(defvar etaf--active-scope nil
  "The Scope that owns newly created effects and cleanups.")

(defvar etaf--render-phase-p nil
  "Whether the current call is producing a View tree.")

(defvar etaf--batch-depth 0
  "Nesting depth of active batches.")

(defvar etaf--draining nil
  "Non-nil while queued effects are being drained.")

(defvar etaf--queues (vector nil nil nil)
  "Pending effects for the pre, render and post phases.")

(defvar etaf--ticks nil
  "Functions queued by `etaf-next-tick', most recent first.")

(defvar etaf--drain-commit-function nil
  "Function called when the pre and render queues are empty.
It returns non-nil when it did work, which restarts the drain loop.")

(defvar etaf--drain-around-function nil
  "Function called with the zero-argument drain loop, or nil.
The Runtime wraps a drain in one Ebox batch so it flushes once.")

(defvar etaf--effect-error-function nil
  "Function called with an effect and condition that escaped the effect.
It returns non-nil when it took ownership of the condition.")

(defvar etaf--drain-errors nil
  "Conditions collected by the current drain.")

(defvar etaf--drain-failed nil
  "Non-nil when a pre or render effect failed since the last drain commit.
The commit function reads and clears it to discard that work.")

(defvar etaf--run-log nil
  "When non-nil, a cons whose car collects every effect that runs.")

(defun etaf--assert-not-rendering (operation)
  "Reject detectable side-effect OPERATION during pure render."
  (when etaf--render-phase-p
    (signal 'etaf-render-side-effect-error (list operation))))

(defun etaf--reactive-same-p (left right)
  "Return non-nil when LEFT and RIGHT are reactively unchanged.
Conses, vectors, records, hash tables, functions and editor handles compare
by identity; other values use `equal'."
  (if (or (consp left) (vectorp left) (recordp left) (hash-table-p left)
          (functionp left) (bufferp left) (markerp left) (windowp left)
          (framep left) (overlayp left) (processp left))
      (eq left right)
    (equal left right)))

;;;; Subscriptions

(defsubst etaf--track (source)
  "Record SOURCE as read by the current observer."
  (when (and etaf--observer etaf--tracking-enabled-p
             (not (eq (etaf--source-mark source) etaf--observe-stamp)))
    (setf (etaf--source-mark source) etaf--observe-stamp)
    (push source etaf--observed)))

(defun etaf--node-deps (node)
  "Return observer NODE's dependency list."
  (if (etaf-effect-p node) (etaf-effect-deps node) (etaf-computed-deps node)))

(defun etaf--node-live-p (node source)
  "Return non-nil when NODE still observes SOURCE."
  (if (etaf-effect-p node)
      (and (etaf-effect-active node) (memq source (etaf-effect-deps node)))
    (and (etaf-computed-active node) (memq source (etaf-computed-deps node)))))

(defun etaf--prune (source)
  "Drop SOURCE's observers that no longer depend on it."
  (let (kept)
    (dolist (node (etaf--source-subs source))
      (when (etaf--node-live-p node source)
        (push node kept)))
    (setq kept (nreverse (delete-dups kept)))
    (setf (etaf--source-subs source) kept
          (etaf--source-nsubs source) (length kept)
          (etaf--source-dead source) 0)))

(defun etaf--unsubscribe (source node)
  "Stop SOURCE from notifying NODE."
  (if (<= (etaf--source-nsubs source) 16)
      (let ((subs (delq node (etaf--source-subs source))))
        (setf (etaf--source-subs source) subs
              (etaf--source-nsubs source) (length subs)))
    (cl-incf (etaf--source-dead source))
    (when (> (* 2 (etaf--source-dead source)) (etaf--source-nsubs source))
      (etaf--prune source))))

(defun etaf--subscribe (source node)
  "Make SOURCE notify NODE."
  (push node (etaf--source-subs source))
  (cl-incf (etaf--source-nsubs source)))

(defun etaf--set-deps (node new failed)
  "Install NEW as NODE's dependencies.
When FAILED is non-nil the run did not complete: keep old dependencies too."
  (let ((old (etaf--node-deps node)))
    ;; Fast path: the same reads in the same order.
    (let ((a old) (b new))
      (while (and a b (eq (car a) (car b)))
        (setq a (cdr a) b (cdr b)))
      (unless (and (null a) (null b))
        (let ((stamp (cl-incf etaf--stamp)))
          (dolist (s new) (setf (etaf--source-mark s) stamp))
          (dolist (s old)
            (if (eq (etaf--source-mark s) stamp)
                (setf (etaf--source-mark s) 0)
              (if failed
                  (push s new)
                (etaf--unsubscribe s node))))
          (dolist (s new)
            (when (eq (etaf--source-mark s) stamp)
              (setf (etaf--source-mark s) 0)
              (etaf--subscribe s node))))
        (if (etaf-effect-p node)
            (setf (etaf-effect-deps node) new)
          (setf (etaf-computed-deps node) new))))))

(defun etaf--release-deps (node)
  "Unsubscribe NODE from all its dependencies."
  (dolist (s (etaf--node-deps node))
    (etaf--unsubscribe s node))
  (if (etaf-effect-p node)
      (setf (etaf-effect-deps node) nil)
    (setf (etaf-computed-deps node) nil)))

(defmacro etaf--with-observer (node &rest body)
  "Run BODY collecting reads as NODE's dependencies; return BODY's value."
  (declare (indent 1) (debug t))
  (let ((ok (make-symbol "ok")) (result (make-symbol "result")))
    `(let ((etaf--observer ,node)
           (etaf--observed nil)
           (etaf--observe-stamp (cl-incf etaf--stamp))
           (,ok nil) ,result)
       (unwind-protect
           (setq ,result (progn ,@body) ,ok t)
         (etaf--set-deps etaf--observer (nreverse etaf--observed) (not ,ok)))
       ,result)))

(defmacro etaf-untracked (&rest body)
  "Evaluate BODY without collecting reactive dependencies."
  (declare (indent 0) (debug t))
  `(let ((etaf--observer nil)) ,@body))

;;;; Notification

(defun etaf--enqueue (effect)
  "Queue EFFECT in its phase."
  (let ((phase (etaf-effect-phase effect)))
    (aset etaf--queues phase (cons effect (aref etaf--queues phase)))))

(defun etaf--stale (node state)
  "Raise observer NODE to STATE (1 check, 2 dirty) and propagate."
  (if (etaf-effect-p node)
      (let ((old (etaf-effect-state node)))
        (when (< old state)
          (setf (etaf-effect-state node) state)
          (when (and (= old 0) (not (etaf-effect-running node)))
            (etaf--enqueue node))))
    (let ((old (etaf-computed-state node)))
      (when (< old state)
        (setf (etaf-computed-state node) state)
        (when (= old 0)
          (etaf--notify node 1))))))

(defun etaf--notify (source state)
  "Raise SOURCE's observers to STATE."
  (if (= 0 (etaf--source-dead source))
      (dolist (node (etaf--source-subs source))
        (etaf--stale node state))
    (let ((dead 0))
      (dolist (node (etaf--source-subs source))
        (if (etaf--node-live-p node source)
            (etaf--stale node state)
          (setq dead (1+ dead))))
      (when (> (* 2 dead) (etaf--source-nsubs source))
        (etaf--prune source)))))

;;;; Computed values

(defun etaf--computed-refresh (computed)
  "Bring COMPUTED up to date with its dependencies."
  (when (= (etaf-computed-state computed) 1)
    (let ((deps (etaf-computed-deps computed)))
      (while (and deps (= (etaf-computed-state computed) 1))
        (let ((s (car deps)))
          (when (etaf-computed-p s) (etaf--computed-refresh s)))
        (setq deps (cdr deps))))
    (when (= (etaf-computed-state computed) 1)
      (setf (etaf-computed-state computed) 0)))
  (when (= (etaf-computed-state computed) 2)
    (when (etaf-computed-evaluating computed)
      (signal 'etaf-reactive-error
              (list "Recursive computed evaluation"
                    (or (etaf-computed-name computed) computed))))
    (setf (etaf-computed-evaluating computed) t)
    (unwind-protect
        (let* ((old (etaf-computed-value computed))
               (new (if (etaf-computed-active computed)
                        (etaf--with-observer computed
                          (funcall (etaf-computed-getter computed)))
                      (etaf-untracked (funcall (etaf-computed-getter computed)))))
               (changed (or (not (etaf-computed-evaluated computed))
                            (not (funcall (or (etaf-computed-test computed)
                                              #'etaf--reactive-same-p)
                                          old new)))))
          (setf (etaf-computed-value computed) new
                (etaf-computed-evaluated computed) t
                (etaf-computed-state computed)
                (if (etaf-computed-active computed) 0 2))
          (when changed
            (cl-incf (etaf-computed-version computed))
            (dolist (node (etaf-computed-subs computed))
              (when (etaf--node-live-p node computed)
                (etaf--stale node 2)))))
      (setf (etaf-computed-evaluating computed) nil))))

;;;; Effects

(defun etaf--effect-run (effect)
  "Run EFFECT now, tracking its dependencies; return its function's value."
  (setf (etaf-effect-state effect) 0
        (etaf-effect-running effect) t)
  (when etaf--run-log (push effect (car etaf--run-log)))
  ;; One unwind form both records the dependencies and ends the run.
  (let ((etaf--observer effect)
        (etaf--observed nil)
        (etaf--observe-stamp (cl-incf etaf--stamp))
        (ok nil) result)
    (unwind-protect
        (setq result (funcall (etaf-effect-fn effect)) ok t)
      (etaf--set-deps effect (nreverse etaf--observed) (not ok))
      (setf (etaf-effect-running effect) nil)
      ;; A dependency changed while the effect ran: run it again.
      (when (and (/= 0 (etaf-effect-state effect)) (etaf-effect-active effect))
        (etaf--enqueue effect)))
    result))

(defun etaf--effect-update (effect)
  "Run queued EFFECT if a dependency really changed."
  (when (and (etaf-effect-active effect) (= (etaf-effect-state effect) 1))
    (let ((deps (etaf-effect-deps effect)))
      (while (and deps (= (etaf-effect-state effect) 1))
        (let ((s (car deps)))
          (when (etaf-computed-p s) (etaf--computed-refresh s)))
        (setq deps (cdr deps))))
    (when (= (etaf-effect-state effect) 1)
      (setf (etaf-effect-state effect) 0)))
  (when (and (etaf-effect-active effect) (= (etaf-effect-state effect) 2))
    (etaf--effect-run effect)))

(cl-defun etaf-reactive-effect-create (function &key (phase 0) owner data name
                                                (scope etaf--active-scope))
  "Create an effect running FUNCTION and return it without running it.
PHASE is 0 (pre), 1 (render) or 2 (post).  OWNER and DATA are opaque values
for the caller.  SCOPE owns the effect; nil leaves disposal to the caller."
  (let ((effect (etaf--effect-create :fn function :phase phase :owner owner
                                     :data data :name name
                                     :id (cl-incf etaf--effect-counter)
                                     :home scope)))
    (when scope
      (unless (etaf-effect-scope-active-p scope)
        (signal 'etaf-reactive-error (list "Inactive Scope" scope)))
      (push effect (etaf-effect-scope-effects scope)))
    effect))

(defun etaf-reactive-effect-run (effect)
  "Run EFFECT now with dependency tracking and return its value."
  (etaf--effect-run effect))

(defun etaf-reactive-effect-stop (effect &optional keep-scope)
  "Dispose EFFECT; run its stop function.
When KEEP-SCOPE is nil, also remove EFFECT from its owning Scope."
  (when (etaf-effect-active effect)
    (setf (etaf-effect-active effect) nil)
    (etaf--release-deps effect)
    (let ((scope (etaf-effect-home effect)))
      (when (and scope (not keep-scope))
        (setf (etaf-effect-scope-effects scope)
              (delq effect (etaf-effect-scope-effects scope)))))
    (when-let* ((stop (etaf-effect-on-stop effect)))
      (funcall stop))))

;;;; Draining

(defun etaf--effect-before-p (a b)
  "Return non-nil when effect A was created before B."
  (< (etaf-effect-id a) (etaf-effect-id b)))

(defun etaf--run-phase (phase)
  "Run the effects queued in PHASE."
  (let ((batch (aref etaf--queues phase)))
    (aset etaf--queues phase nil)
    (when (cdr batch)
      (setq batch (sort batch #'etaf--effect-before-p)))
    (dolist (effect batch)
      (condition-case err
          (etaf--effect-update effect)
        ((error quit)
         (setf (etaf-effect-state effect) 0)
         ;; A failed dependency refresh never reached the run itself.
         (when etaf--run-log (push effect (car etaf--run-log)))
         (unless (and etaf--effect-error-function
                      (funcall etaf--effect-error-function effect err))
           (when (< phase 2) (setq etaf--drain-failed t))
           (push err etaf--drain-errors)))))))

(defun etaf--drain-loop ()
  "Run the queued phases and commits until nothing remains."
  (let ((queues etaf--queues))
    (while (cond ((aref queues 0) (etaf--run-phase 0) t)
                 ((aref queues 1) (etaf--run-phase 1) t)
                 ((and etaf--drain-commit-function
                       (condition-case err
                           (funcall etaf--drain-commit-function)
                         ((error quit) (push err etaf--drain-errors) t))))
                 ((aref queues 2) (etaf--run-phase 2) t)))))

(defun etaf--drain ()
  "Run queued effects until the graph is settled; re-signal the first error.
Functions queued by `etaf-next-tick' run afterwards."
  (unless etaf--draining
    (unwind-protect
        (let ((etaf--draining t)
              (etaf--drain-errors nil)
              (etaf--drain-failed nil))
          (if etaf--drain-around-function
              (funcall etaf--drain-around-function #'etaf--drain-loop)
            (etaf--drain-loop))
          (when etaf--drain-errors
            (let ((first (car (last etaf--drain-errors))))
              (signal (car first) (cdr first)))))
      (etaf--run-ticks))))

(defun etaf--run-ticks ()
  "Run queued `etaf-next-tick' functions in order; re-signal the first error.
Functions queued while these run join the same pass."
  (let (failure)
    (while etaf--ticks
      (let ((ticks (nreverse etaf--ticks)))
        (setq etaf--ticks nil)
        (dolist (fn ticks)
          (condition-case err
              (funcall fn)
            ((error quit) (unless failure (setq failure err)))))))
    (when failure
      (signal (car failure) (cdr failure)))))

(defun etaf--settle ()
  "Drain queued effects unless a batch or drain is active."
  (when (and (= etaf--batch-depth 0) (not etaf--draining))
    (etaf--drain)))

(defun etaf-call-with-batch (function)
  "Call zero-argument FUNCTION with deferred reactive notifications.
Return FUNCTION's result after queued effects and Runtime updates finish.
Nested calls join the outer batch.  Ref writes are immediately readable,
but their effects wait until the outermost call completes.

If FUNCTION signals after writing refs, queued work still runs before the
original condition is re-signaled.  Written refs are not rolled back.  An
effect or Runtime error signals when FUNCTION itself completed normally.
Use outside rendering on the main Emacs event loop."
  (etaf--assert-not-rendering 'batch)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let ((ok nil) result)
    (unwind-protect
        (let ((etaf--batch-depth (1+ etaf--batch-depth)))
          (setq result (funcall function) ok t))
      (when (and (= etaf--batch-depth 0) (not etaf--draining))
        (if ok
            (etaf--drain)
          (ignore-errors (etaf--drain)))))
    result))

;;;###autoload
(defun etaf-next-tick (function)
  "Call zero-argument FUNCTION once pending reactive work is published.
Inside a batch, an event callback or an effect, FUNCTION runs after the
outermost batch has drained and every mounted Runtime has written its
buffer, so new Hosts have positions and scroll ranges.  Outside one,
nothing is pending and FUNCTION runs immediately.  Return nil."
  (etaf--assert-not-rendering 'next-tick)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (if (or (> etaf--batch-depth 0) etaf--draining)
      (push function etaf--ticks)
    (funcall function))
  nil)

(defmacro etaf-batch (&rest body)
  "Evaluate BODY with deferred reactive notifications and return its result.
Nested batches join the outermost one.  See `etaf-call-with-batch'."
  (declare (indent 0) (debug t))
  `(etaf-call-with-batch (lambda () ,@body)))

;;;; Public sources

;;;###autoload
(cl-defun etaf-ref (initial-value &key test name)
  "Create a writable shallow reactive cell containing INITIAL-VALUE.

Lists, vectors, hash tables, records, functions and editor handles compare by
identity; other values use equal.  Replacing an object notifies dependents
even when its contents match.
TEST optionally compares old and new values.  NAME is used in diagnostics."
  (etaf--assert-not-rendering 'create-ref)
  (when (and test (not (functionp test)))
    (signal 'wrong-type-argument (list 'functionp test)))
  (etaf--ref-create :value initial-value :test test :name name))

;;;###autoload
(cl-defun etaf-computed (getter &key test name)
  "Create a lazy cached value computed by zero-argument GETTER.

TEST optionally compares old and new values; consumers of an unchanged
result do not re-run.  NAME optionally labels the computed value.  The
active Scope owns the computed: stopping it releases its dependencies.

A computed created during Component setup runs its getter in that
Component's environment on every later run, so Context, Runtime and
`etaf-viewport' reads inside it keep working after the first run."
  (etaf--assert-not-rendering 'create-computed)
  (unless (functionp getter)
    (signal 'wrong-type-argument (list 'functionp getter)))
  (when (and test (not (functionp test)))
    (signal 'wrong-type-argument (list 'functionp test)))
  (let ((computed (etaf--computed-create
                   :getter (etaf--effect-environment getter)
                   :test test :name name)))
    (when (and etaf--active-scope (etaf-effect-scope-active-p etaf--active-scope))
      (push computed (etaf-effect-scope-effects etaf--active-scope)))
    computed))

(defun etaf--computed-stop (computed)
  "Release COMPUTED's dependencies; later reads recompute untracked."
  (when (etaf-computed-active computed)
    (setf (etaf-computed-active computed) nil
          (etaf-computed-state computed) 2)
    (etaf--release-deps computed)))

;;;###autoload
(defun etaf-value (source)
  "Read reactive SOURCE and track the read in the current effect."
  (cond
   ((etaf-ref-p source)
    (etaf--track source)
    (etaf-ref-value source))
   ((etaf-computed-p source)
    (unless (= 0 (etaf-computed-state source))
      (etaf--computed-refresh source))
    (etaf--track source)
    (etaf-computed-value source))
   (t (signal 'wrong-type-argument (list 'etaf-reactive-source-p source)))))

(defun etaf--check-value-write (source)
  "Require writable SOURCE outside View rendering."
  (when etaf--render-phase-p
    (signal 'etaf-render-side-effect-error
            (list 'write (and (etaf-ref-p source) (etaf-ref-name source)))))
  (unless (etaf-ref-p source)
    (signal 'etaf-reactive-error
            (list "Reactive value is read-only"
                  (if (etaf-computed-p source) (etaf-computed-name source)
                    (type-of source))))))

(defun etaf--ref-install (ref value)
  "Store VALUE in REF and bump its version without notifying observers."
  (setf (etaf-ref-value ref) value)
  (cl-incf (etaf-ref-version ref)))

(defun etaf--ref-notify (ref)
  "Notify REF's observers that it changed and settle outside batches."
  (etaf--notify ref 2)
  (etaf--settle))

(defun etaf-set-value (source new-value)
  "Set writable reactive SOURCE to NEW-VALUE and return NEW-VALUE."
  (etaf--check-value-write source)
  (unless (funcall (or (etaf-ref-test source) #'etaf--reactive-same-p)
                   (etaf-ref-value source) new-value)
    (setf (etaf-ref-value source) new-value)
    (cl-incf (etaf-ref-version source))
    (when (etaf-ref-subs source)
      (etaf--notify source 2)
      (etaf--settle)))
  new-value)

(gv-define-setter etaf-value (new-value source)
  `(etaf-set-value ,source ,new-value))

;;;###autoload
(defun etaf-update-value (source function &rest arguments)
  "Replace SOURCE with FUNCTION applied to its current value and ARGUMENTS.
Return the replacement value.  SOURCE must be a writable ref; rendering
rejects the operation before FUNCTION runs.  FUNCTION runs once and must
return a replacement without mutating the old value or performing effects.
An error from FUNCTION leaves SOURCE unchanged."
  (etaf--check-value-write source)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (etaf-set-value source (apply function (etaf-untracked (etaf-value source))
                                arguments)))

;;;; Watchers

(defun etaf--watch-getter (source)
  "Return a zero-argument getter for watch SOURCE."
  (cond
   ((or (etaf-ref-p source) (etaf-computed-p source))
    (lambda () (etaf-value source)))
   ((functionp source) source)
   (t (signal 'etaf-reactive-error
              (list "Watch source must be reactive or callable" source)))))

(defun etaf--flush-phase (flush)
  "Return the effect phase for watcher FLUSH."
  (pcase flush
    ((or 'pre 'sync 'nil) 0)
    ('post 2)
    (_ (signal 'etaf-reactive-error (list "Invalid watcher flush" flush)))))

(defvar etaf--effect-environment-function nil
  "Function wrapping a reactive callback in its creation environment.
The Runtime layer installs it.  `etaf-watch', `etaf-watch-effect' and
`etaf-computed' created during a Component setup or a Runtime operation call
it so later reactive runs keep that operation's Context, Runtime and
lifecycle phase.  It must name a function of its own: pointing at
`etaf--effect-environment' itself would make that wrapper call itself.")

(defun etaf--effect-environment (function)
  "Return FUNCTION wrapped in the environment current at its creation."
  (let ((wrap etaf--effect-environment-function))
    (if (or (null wrap) (eq wrap 'etaf--effect-environment))
        function
      (funcall wrap function))))

;;;###autoload
(cl-defun etaf-watch
    (source callback &key immediate (flush 'pre) test name)
  "Watch SOURCE and call CALLBACK with NEW and OLD values.

SOURCE is a ref, computed or zero-argument function.  IMMEDIATE calls
CALLBACK for the initial value.  FLUSH is `pre' (before Runtimes write their
buffers) or `post' (after).  TEST compares values; it defaults to the
source's test.  NAME labels diagnostics.  When CALLBACK returns a function,
it runs before the next callback and when the watcher stops.  Return a
zero-argument stop function.

A watcher created during Component setup runs its source getter and its
callback in that Component's environment on every later run, so Context and
Runtime reads inside either keep working after the first run.  A callable
SOURCE therefore reads the Component's own viewport instead of falling back
to the Runtime canvas."
  (etaf--assert-not-rendering 'watch)
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (let* ((callback (etaf--effect-environment callback))
         ;; The getter runs outside the Component's dynamic environment at
         ;; flush time, so a callable SOURCE would resolve `etaf-viewport'
         ;; against nothing and fall back to the canvas.  `etaf-computed'
         ;; already retains the environment; keep the two paths symmetric.
         (getter (etaf--effect-environment (etaf--watch-getter source)))
         (same-p (or test
                     (and (etaf--source-p source) (etaf--source-test source))
                     #'etaf--reactive-same-p))
         (initialized nil) old cleanup effect)
    (setq effect
          (etaf-reactive-effect-create
           (lambda ()
             (let ((new (funcall getter)))
               (etaf-untracked
                (if (and initialized (funcall same-p old new))
                    nil
                  (let ((previous old) (first (not initialized)))
                    (setq old new initialized t)
                    (when (or immediate (not first))
                      (when cleanup
                        (let ((f cleanup)) (setq cleanup nil) (funcall f)))
                      (let ((result (funcall callback new previous)))
                        (when (functionp result) (setq cleanup result)))))))))
           :phase (etaf--flush-phase flush)
           :name (or name 'watch)))
    (setf (etaf-effect-on-stop effect)
          (lambda () (when cleanup (let ((f cleanup)) (setq cleanup nil) (funcall f)))))
    (etaf--effect-run effect)
    (lambda () (etaf-reactive-effect-stop effect))))

;;;###autoload
(cl-defun etaf-watch-effect (function &key (flush 'pre) name)
  "Run FUNCTION immediately and again after a reactive dependency change.

FLUSH is `pre' or `post' as in `etaf-watch'.  NAME optionally labels the
effect.  If FUNCTION returns a function, it cleans up the previous run and
runs when the effect stops.  Return a zero-argument stop function.

An effect created during Component setup runs in that Component's
environment on every later run, so Context and Runtime reads inside it keep
working after the first run."
  (etaf--assert-not-rendering 'watch-effect)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let ((function (etaf--effect-environment function))
        cleanup effect)
    (setq effect
          (etaf-reactive-effect-create
           (lambda ()
             (when cleanup
               (let ((f cleanup)) (setq cleanup nil) (etaf-untracked (funcall f))))
             (let ((result (funcall function)))
               (when (functionp result) (setq cleanup result))))
           :phase (etaf--flush-phase flush)
           :name (or name 'watch-effect)))
    (setf (etaf-effect-on-stop effect)
          (lambda () (when cleanup (let ((f cleanup)) (setq cleanup nil) (funcall f)))))
    (etaf--effect-run effect)
    (lambda () (etaf-reactive-effect-stop effect))))

;;;###autoload
(cl-defun etaf-selector (source &key (test 'equal) name)
  "Return a keyed membership reader over reactive SOURCE.
The result is a function of one KEY returning non-nil while SOURCE's value
equals KEY under TEST, a hash table test (`eq', `eql' or `equal').  Each
reader depends only on its own KEY, so changing SOURCE notifies the readers
of the previous and the new value instead of every reader.  The active Scope
owns the watcher; NAME labels diagnostics."
  (etaf--assert-not-rendering 'selector)
  (unless (memq test '(eq eql equal))
    (signal 'wrong-type-argument (list '(member eq eql equal) test)))
  (let* ((cells (make-hash-table :test test))
         (current (etaf-untracked (etaf-value source)))
         (sweep 256))
    (etaf-watch
     source
     (lambda (new _old)
       (let ((previous current))
         (setq current new)
         (when (> (hash-table-count cells) sweep)
           (let (idle)
             (maphash (lambda (key cell)
                        (unless (cl-some (lambda (node)
                                           (etaf--node-live-p node cell))
                                         (etaf--source-subs cell))
                          (push key idle)))
                      cells)
             (dolist (key idle) (remhash key cells))
             (setq sweep (max 256 (* 2 (hash-table-count cells))))))
         (etaf-batch
           (when-let* ((cell (gethash previous cells)))
             (etaf-set-value cell nil))
           (when-let* ((cell (gethash new cells)))
             (etaf-set-value cell t)))))
     :test (lambda (a b) (funcall test a b))
     :name (or name 'selector))
    (lambda (key)
      (let ((cell (gethash key cells)))
        (unless cell
          (setq cell (etaf--ref-create
                      :value (and (funcall test key current) t)
                      :name (or name 'selector)))
          (puthash key cell cells))
        (etaf-value cell)))))

;;;; Scopes

;;;###autoload
(cl-defun etaf-effect-scope (&key detached name)
  "Create a Scope named NAME, owned by the current Scope unless DETACHED."
  (etaf--assert-not-rendering 'create-scope)
  (let* ((parent (and (not detached) etaf--active-scope))
         (scope (etaf--effect-scope-create :parent parent :name name)))
    (when parent
      (unless (etaf-effect-scope-active-p parent)
        (signal 'etaf-reactive-error (list "Inactive parent Scope" parent)))
      (push scope (etaf-effect-scope-children parent)))
    scope))

;;;###autoload
(defun etaf-current-effect-scope ()
  "Return the active Scope, or nil outside scoped execution."
  etaf--active-scope)

;;;###autoload
(defun etaf-scope-run (scope function)
  "Run FUNCTION with SCOPE active and return its value.
Effects, computeds, watchers, child Scopes and cleanups created by FUNCTION
belong to SCOPE.  An inactive SCOPE signals `etaf-reactive-error'."
  (unless (and (etaf-effect-scope-p scope) (etaf-effect-scope-active-p scope))
    (signal 'etaf-reactive-error (list "Cannot enter an inactive Scope")))
  (let ((etaf--active-scope scope))
    (funcall function)))

;;;###autoload
(defun etaf-on-scope-dispose (function)
  "Register zero-argument FUNCTION for the current active Scope's disposal.
Return FUNCTION.  Cleanup runs once, in reverse registration order, after
child Scopes and effects stop.  A missing or stopped Scope signals an error.
Cleanup errors are collected by `etaf-scope-stop' without aborting teardown."
  (etaf--assert-not-rendering 'register-scope-cleanup)
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (unless (and etaf--active-scope
               (etaf-effect-scope-active-p etaf--active-scope))
    (signal 'etaf-reactive-error
            (list "Cleanup registration requires an active Scope")))
  (push function (etaf-effect-scope-cleanups etaf--active-scope))
  function)

;;;###autoload
(defun etaf-scope-stop (scope)
  "Dispose SCOPE and return cleanup conditions collected during teardown.
Stop child Scopes and owned effects, then run registered cleanup functions.
Errors and quits from cleanup are returned as condition data, not re-signaled;
remaining cleanup still runs.  Stopping an already stopped Scope returns nil.
After stopping, SCOPE cannot be entered or accept effects or cleanup."
  (etaf--assert-not-rendering 'stop-scope)
  (when (and (etaf-effect-scope-p scope) (etaf-effect-scope-active-p scope))
    (setf (etaf-effect-scope-active-p scope) nil)
    (let ((children (etaf-effect-scope-children scope))
          (nodes (etaf-effect-scope-effects scope))
          errors)
      (setf (etaf-effect-scope-children scope) nil
            (etaf-effect-scope-effects scope) nil)
      (dolist (child children)
        (setq errors (nconc errors (etaf-scope-stop child))))
      (dolist (node nodes)
        (condition-case err
            (if (etaf-effect-p node)
                (etaf-reactive-effect-stop node t)
              (etaf--computed-stop node))
          ((error quit) (push err errors))))
      (dolist (cleanup (etaf-effect-scope-cleanups scope))
        (condition-case err
            (funcall cleanup)
          ((error quit) (push err errors))))
      (setf (etaf-effect-scope-cleanups scope) nil)
      (when-let* ((parent (etaf-effect-scope-parent scope)))
        (setf (etaf-effect-scope-children parent)
              (delq scope (etaf-effect-scope-children parent))))
      (nreverse errors))))

(provide 'etaf-reactive)

;;; etaf-reactive.el ends here
