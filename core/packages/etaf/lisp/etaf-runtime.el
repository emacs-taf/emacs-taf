;;; etaf-runtime.el --- Fine-grained retained ETAF Runtime -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A mounted View becomes one retained segment tree whose Host segments own
;; Ebox nodes directly.  Every dynamic site (a property or text expression, a
;; branch, a keyed list, a Component render or input, a slot) is one reactive
;; effect bound to the segment it updates.  A change re-runs only the effects
;; that read it; they edit their own Ebox nodes in place, and Ebox relayouts
;; and repaints only the damaged region when the drain commits.  There is no
;; candidate tree, generation or publication transaction: the retained Ebox
;; tree is the single authority, and each region patch is atomic on its own.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-animation)
(require 'etaf-context)
(require 'etaf-observer)
(require 'etaf-behavior)
(require 'etaf-view)
(require 'etaf-component)

(define-error 'etaf-runtime-error "ETAF runtime error")
(define-error 'etaf-renderer-error "ETAF rendering error")

;; The native predicate is absent from Emacs builds without image support.
(declare-function imagep "image.c" (spec))
(declare-function etaf--dispatch-activation "etaf-events" (runtime host-ref))
(declare-function etaf--keys-validate "etaf-keys" (keys))
(declare-function etaf--region-validate "etaf-regions" (region))
(declare-function etaf--keys-register "etaf-keys" (runtime keys))
(declare-function etaf--keys-install "etaf-keys" (runtime))
(declare-function etaf--keys-uninstall "etaf-keys" (runtime))
(declare-function etaf-dispatch-event "etaf-events"
                  (runtime host-ref kind &optional payload payload-p))
(defvar etaf--drag-cancel-p)
(defvar cl--optimize-safety)

(defmacro etaf--defstruct (&rest args)
  "Define an internal record from ARGS whose compiled accessors skip type checks."
  (let ((cl--optimize-safety 0))
    (macroexpand-1 `(cl-defstruct ,@args))))

;;;; Records

(cl-defstruct (etaf-runtime (:constructor etaf--runtime-make) (:copier nil))
  "One mounted ETAF application over one Ebox buffer mount."
  buffer mounted-p input-finisher
  (instances (make-hash-table :test #'eql))
  root wrapper mounted-root root-dirty surface overlay-entries
  (hosts (make-hash-table :test #'equal))
  (nodes (make-hash-table :test #'eq))
  host-ids presentations (pres-seq 0)
  meta-spec meta-scope meta-snapshot key-layers
  (rev 0) dirty changed app-changed new-instances updated-instances retired-instances
  (last-new-count 0) (last-updated-count 0) (last-retired-count 0)
  errors observer (event-depth 0) (next-operation-id 0) mount-id
  fixed-viewport view (next-id 0) sticky viewport-ref display-ref keymap)

(etaf--defstruct (etaf--ictx (:constructor etaf--ictx-make) (:copier nil))
  "Evaluation context of one Component instance: owner, Context and theme."
  runtime owner root-p inner context (theme 'unset))

(etaf--defstruct (etaf--seg (:constructor etaf--seg-make) (:copier nil))
  "One retained View segment.
KIND is host, frag, expr, branch, list, row, comp, slot, root, surface,
overlay or pres.  Only Host segments own an Ebox NODE; the others group
their KIDS."
  kind parent kids node ctx effect src key data live txn)

(etaf--defstruct (etaf--host (:constructor etaf--host-make) (:copier nil))
  "Mounted state of one Host segment."
  id ref gref reg props eprops rprops theme behaviors keymap relays payload text
  presentation txn)

(etaf--defstruct (etaf--pres (:constructor etaf--pres-make) (:copier nil))
  "One keyed presentation entry owned by KEY on a Host segment.
MODE is `decorate', `override', `companion-inside', `companion-after' or
`companion-beside'.  PRIORITY orders multiple coexisting entries (lower first;
default 50).  SEQ breaks ties deterministically."
  key mode (priority 50) (seq 0) slot seg view text-override face spans)

(etaf--defstruct (etaf--pres-bucket (:conc-name etaf--pb-)
                                    (:constructor etaf--pb-make)
                                    (:copier nil))
  "Multi-owner presentation bucket attached to one Host segment.
DECORATIONS holds additive text face/span overlays, COMPANIONS holds
coexisting companion sub-segments, and OVERRIDES holds a priority stack of
replacement presentations.  OUTER, BESIDE-GRID and HOLDER are shared Ebox
structural wrappers managed idempotently across all active owners."
  decorations companions overrides outer beside-grid holder active-override)

(etaf--defstruct (etaf--instance (:constructor etaf--instance-make) (:copier nil))
  "One retained Component instance."
  id runtime spec seg ctx pctx scope cells slots-ref call attrs state setup-p
  context style-scope style-key style-revision local-refs prop-sources
  mounted-hooks updated-hooks unmounted-hooks input-effect defaults
  dead mounted-p updated-p (render-count 1) view txn)

;;;; Dynamic state

(defvar etaf--current-runtime nil
  "Runtime owning the current setup, lifecycle, or event operation.")

(defvar etaf--current-ictx nil
  "Evaluation context of the Component operation currently running.
`etaf--ctx-call' and Component setup bind it so effects created there can
capture the environment they must run in later.")

(defvar etaf--dirty-runtimes nil
  "Runtimes with work for the next drain commit.")

(defvar-local etaf--mount-cursor nil
  "Cursor state a mounted View replaced, as (HAD-LOCAL . CURSOR-TYPE).")

(defvar-local etaf--mount-text-selection nil
  "Text-selection state a mounted View replaced, as (HAD-LOCAL . VALUE).")

(defvar-local etaf--cursor-hidden nil
  "Whether the input modality, not the application, hid this buffer's cursor.")

(defun etaf--cursor-passive-pointer-p ()
  "Whether `last-command-event' is passive pointer motion or wheel scroll."
  (let* ((event last-command-event)
         (head (and (consp event) (car event))))
    (and (symbolp head)
         (or (eq head 'mouse-movement)
             (memq (event-basic-type head)
                   '(wheel-up wheel-down wheel-left wheel-right
                     mouse-4 mouse-5 mouse-6 mouse-7))))))

(defun etaf--cursor-pointer-command-p ()
  "Whether the running command came from a pointer button press or click."
  (let* ((event last-command-event)
         (head (and (consp event) (car event))))
    (and (symbolp head)
         (not (etaf--cursor-passive-pointer-p))
         (string-match-p "mouse-[123]\\'" (symbol-name head)))))

(defvar etaf-cursor-follows-input-modality nil
  "Whether a mounted canvas hides its cursor after a pointer click.
Nil by default so a mounted buffer behaves like an ordinary Emacs buffer:
clicking places point and keeps the user's native blinking cursor visible.
Set to non-nil (globally or buffer-locally) to hide the cursor after a pointer
click until the next keyboard command; applications that want no cursor at all
should pass `:cursor nil' to `etaf-app-open' or set `cursor-type' nil.")

(defun etaf--cursor-restore ()
  "Restore the native cursor hidden by `etaf--cursor-input-modality'."
  (when etaf--cursor-hidden
    (setq etaf--cursor-hidden nil)
    (if (and etaf--mount-cursor (car etaf--mount-cursor))
        (setq-local cursor-type (cdr etaf--mount-cursor))
      (kill-local-variable 'cursor-type))))

(defun etaf--cursor-input-modality ()
  "Follow the input modality with the native cursor of a mounted View.
When `etaf-cursor-follows-input-modality' is non-nil, a pointer click hides
the native cursor until the next keyboard command, while passive pointer
motion and wheel events leave cursor visibility unchanged.  When nil (the
default), the native cursor stays visible across pointer events, restoring any
cursor previously hidden by modality tracking."
  (cond
   ((not etaf-cursor-follows-input-modality)
    (etaf--cursor-restore))
   ((etaf--cursor-passive-pointer-p) nil)
   ((etaf--cursor-pointer-command-p)
    (unless etaf--cursor-hidden
      (setq etaf--cursor-hidden t)
      (setq-local cursor-type nil)))
   (t
    (etaf--cursor-restore))))

(defvar etaf--runtimes (make-hash-table :test #'eq :weakness 'key)
  "Mounted Runtime of each buffer.")

(defvar etaf--mount-counter 0
  "Last allocated Runtime mount id.")

(defvar etaf-runtime-mount-functions nil
  "Hook run with one argument, RUNTIME, after `etaf-mount' publishes its View.")

(defvar etaf-runtime-after-commit-functions nil
  "Hook run with one argument, RUNTIME, after a mounted Runtime commits.
Presentation-only flushes do not run this hook.")

(defvar etaf-runtime-unmount-functions nil
  "Hook run with one argument, RUNTIME, when a mounted Runtime begins unmounting.")

(defvar etaf-runtime-after-flush-functions nil
  "Hook run with one argument, RUNTIME, after a non-presentation Ebox flush.
Covers scroll-offset updates inside `:overflow scroll' containers, viewport
refits and application commits.")

(defvar etaf-runtime-meta-change-functions nil
  "Hook run with `(RUNTIME META)' when a mounted Runtime's `:meta' changes.")

(defvar etaf-runtime-focus-change-functions nil
  "Hook run with `(RUNTIME PREV-HOST-ID NEXT-HOST-ID)' when Host focus changes.")

(defvar etaf--in-presentation-mutation nil
  "Non-nil while applying or clearing Host presentation or overlay attachments.")

(defun etaf--forward-ebox-after-flush (buffer)
  "Forward BUFFER's Ebox flush to `etaf-runtime-after-flush-functions'."
  (when (and etaf-runtime-after-flush-functions
             (not etaf--in-presentation-mutation))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf--run-runtime-hooks 'etaf-runtime-after-flush-functions runtime))))

(add-hook 'ebox-after-flush-functions #'etaf--forward-ebox-after-flush)

(defun etaf--run-runtime-hooks (hook runtime &rest args)
  "Run HOOK functions with RUNTIME and ARGS, ignoring individual observer errors."
  (when (and hook (symbol-value hook))
    (dolist (fn (copy-sequence (symbol-value hook)))
      (when (functionp fn)
        (condition-case nil
            (let ((etaf--current-runtime runtime)
                  (etaf--render-phase-p nil))
              (apply fn runtime args))
          (error nil))))))

(defun etaf-current-runtime ()
  "Return the dynamically active Runtime, or nil outside a Runtime."
  etaf--current-runtime)

(defun etaf-runtime-revision (runtime)
  "Return RUNTIME's committed revision number."
  (etaf-runtime-rev runtime))

(defun etaf--runtime-touch (runtime)
  "Queue RUNTIME for the next drain commit."
  (unless (etaf-runtime-dirty runtime)
    (setf (etaf-runtime-dirty runtime) t)
    (push runtime etaf--dirty-runtimes)))

(defun etaf--runtime-changed (runtime)
  "Record that RUNTIME's Ebox tree changed."
  (when runtime
    (setf (etaf-runtime-changed runtime) t)
    (unless etaf--in-presentation-mutation
      (setf (etaf-runtime-app-changed runtime) t))
    (etaf--runtime-touch runtime)))

;;;; Transactions
;;
;; A drain applies effects directly to retained segments and Ebox nodes.  The
;; transaction of the current drain journals every change to state that
;; existed before it, so a failed pre or render effect can restore exactly
;; what was committed.  The cost is proportional to the touched state.
;; Objects created by the transaction carry it in their `txn' slot and are
;; not journaled; on rollback they are released instead.  Cleanup of
;; committed resources waits until the transaction commits.

(etaf--defstruct (etaf--txn (:constructor etaf--txn-make) (:copier nil))
  "Undo journal of one drain's uncommitted work."
  undo cells created ran stopped installs instances deferred dirty)

(defvar etaf--txn nil
  "Transaction of the current drain, or nil outside a drain.")

(defvar etaf--parked-effects nil
  "Effects whose output a rollback discarded; they re-run with later work.")

(defvar etaf--retry-parked nil
  "Non-nil when the next drain must re-run parked effects.")

(defsubst etaf--jaset (obj offset value stamp)
  "Set slot OFFSET of record OBJ to VALUE, journaling the old value.
STAMP is the offset of OBJ's creating transaction, or nil."
  (let ((txn etaf--txn))
    (when (and txn (not (and stamp (eq (aref obj stamp) txn))))
      (push (cons obj (cons offset (aref obj offset))) (etaf--txn-undo txn))))
  (aset obj offset value))

(defmacro etaf--journal-setters (struct stamp &rest slots)
  "Journal `setf' of STRUCT's SLOTS (all slots when nil) in a transaction.
STAMP names the slot holding an object's creating transaction, or nil."
  (let ((stamp-offset (and stamp (cl-struct-slot-offset struct stamp))))
    `(progn
       ,@(mapcar
          (lambda (slot)
            (let ((offset (cl-struct-slot-offset struct slot)))
              `(gv-define-setter ,(intern (format "%s-%s" struct slot)) (value obj)
                 (list 'etaf--jaset obj ,offset value ,stamp-offset))))
          (or slots
              (delq stamp (mapcar #'car (cdr (cl-struct-slot-info struct)))))))))

(etaf--journal-setters etaf--seg txn)
(etaf--journal-setters etaf--host txn)
(etaf--journal-setters etaf--instance txn)
(etaf--journal-setters etaf-runtime nil
                       new-instances updated-instances retired-instances
                       root-dirty changed app-changed surface)

(defun etaf--journal (function)
  "Record FUNCTION to undo a change when the transaction rolls back."
  (when etaf--txn (push function (etaf--txn-undo etaf--txn))))

(defun etaf--jputhash (key value table)
  "Put KEY to VALUE in TABLE, journaling the old entry."
  (when etaf--txn
    (let ((old (gethash key table 'etaf--absent)))
      (push (if (eq old 'etaf--absent)
                (lambda () (remhash key table))
              (lambda () (puthash key old table)))
            (etaf--txn-undo etaf--txn))))
  (puthash key value table))

(defun etaf--jremhash (key table)
  "Remove KEY from TABLE, journaling the old entry."
  (when etaf--txn
    (let ((old (gethash key table 'etaf--absent)))
      (unless (eq old 'etaf--absent)
        (push (lambda () (puthash key old table)) (etaf--txn-undo etaf--txn)))))
  (remhash key table))

(defun etaf--cell-install (cell value)
  "Install VALUE in internal CELL and notify its observers, journaling it."
  (when etaf--txn
    (push (cons cell (etaf-ref-value cell)) (etaf--txn-cells etaf--txn)))
  (etaf--ref-install cell value)
  (etaf--notify cell 2))

(defun etaf--node-set-props (node props old)
  "Give NODE PROPS; OLD restores it on rollback."
  (etaf--journal (lambda () (ebox-node-set-props node old)))
  (ebox-node-set-props node props))

(defun etaf--node-set-text (node text old)
  "Give text NODE TEXT; OLD restores it on rollback."
  (etaf--journal (lambda () (ebox-node-set-text node old)))
  (ebox-node-set-text node text))

(defun etaf--node-insert (parent node index)
  "Insert NODE into PARENT at INDEX."
  (etaf--journal (lambda () (ebox-node-remove node)))
  (ebox-node-insert parent node index))

(defun etaf--node-remove (node)
  "Remove NODE from its parent."
  (when etaf--txn
    (let ((parent (ebox-node-parent node)) (index (ebox-node-index node)))
      (when parent
        (etaf--journal (lambda () (ebox-node-insert parent node index))))))
  (ebox-node-remove node))

(defun etaf--node-move (node index)
  "Move NODE to INDEX among its siblings."
  (when etaf--txn
    (let ((old (ebox-node-index node)))
      (etaf--journal (lambda () (ebox-node-move node old)))))
  (ebox-node-move node index))

(defun etaf--txn-fresh-p (effect)
  "Return non-nil when EFFECT was created by the current transaction."
  (and etaf--txn (eq (etaf-effect-data effect) etaf--txn)))

(defun etaf--txn-defer (function)
  "Run FUNCTION when the transaction commits, or now outside one."
  (if etaf--txn
      (push function (etaf--txn-deferred etaf--txn))
    (funcall function)))

(defun etaf--txn-begin ()
  "Return a new transaction for the work after the last commit."
  (etaf--txn-make :ran (list nil)
                  :dirty (cons etaf--dirty-runtimes
                               (mapcar #'etaf-runtime-dirty etaf--dirty-runtimes))))

(defun etaf--txn-commit (txn)
  "Run TXN's deferred cleanup of replaced committed resources."
  (let ((etaf--txn nil))
    (dolist (function (reverse (etaf--txn-deferred txn)))
      (funcall function))))

(defun etaf--park (effect)
  "Keep EFFECT for a later retry."
  (when (etaf-effect-active effect)
    (setf (etaf-effect-state effect) 0)
    (unless (memq effect etaf--parked-effects)
      (push effect etaf--parked-effects))))

(defun etaf--txn-rollback (txn)
  "Restore everything TXN changed and release what it created."
  (let ((etaf--txn nil) (etaf--render-phase-p nil))
    (dolist (entry (etaf--txn-undo txn))
      (if (functionp entry)
          (funcall entry)
        (aset (car entry) (cadr entry) (cddr entry))))
    (dolist (effect (etaf--txn-created txn))
      (etaf-reactive-effect-stop effect t))
    (dolist (state (etaf--txn-installs txn))
      (when-let* ((cleanup (cddr state)))
        (ignore-errors (etaf-untracked (funcall cleanup)))))
    (dolist (inst (etaf--txn-instances txn))
      (when-let* ((scope (etaf--instance-scope inst)))
        (etaf-scope-stop scope)))
    (dolist (effect (etaf--txn-stopped txn))
      (unless (etaf-effect-active effect)
        (setf (etaf-effect-active effect) t)
        (etaf--park effect)))
    ;; Post effects observed committed output; only earlier phases re-run.
    (dolist (effect (car (etaf--txn-ran txn)))
      (when (< (etaf-effect-phase effect) 2)
        (etaf--park effect)))
    (let (cells)
      (dolist (entry (etaf--txn-cells txn))
        (etaf--ref-install (car entry) (cdr entry))
        (push (car entry) cells))
      (dolist (cell cells) (etaf--notify cell 2)))
    ;; Work queued by the restored cells waits with the parked effects.
    (dotimes (phase 2)
      (dolist (effect (aref etaf--queues phase))
        (etaf--park effect))
      (aset etaf--queues phase nil))
    (dolist (runtime etaf--dirty-runtimes)
      (setf (etaf-runtime-dirty runtime) nil))
    (let ((dirty (etaf--txn-dirty txn)))
      (setq etaf--dirty-runtimes (car dirty))
      (cl-loop for runtime in (car dirty) for flag in (cdr dirty)
               do (setf (etaf-runtime-dirty runtime) flag)))))

(defun etaf--requeue-parked ()
  "Queue the parked effects to run again."
  (let ((parked (nreverse etaf--parked-effects)))
    (setq etaf--parked-effects nil)
    (dolist (effect parked)
      (when (etaf-effect-active effect)
        (let ((old (etaf-effect-state effect)))
          (setf (etaf-effect-state effect) 2)
          (when (= old 0) (etaf--enqueue effect)))))))

;;;; Evaluation contexts

(defun etaf--ctx-inner (ctx)
  "Return CTX's context for descendants of one of its Hosts."
  (if (not (etaf--ictx-root-p ctx))
      ctx
    (or (etaf--ictx-inner ctx)
        (setf (etaf--ictx-inner ctx)
              (etaf--ictx-make :runtime (etaf--ictx-runtime ctx)
                               :owner (etaf--ictx-owner ctx)
                               :root-p nil
                               :context (etaf--ictx-context ctx)
                               :theme (etaf--ictx-theme ctx))))))

(defun etaf--ctx-theme (ctx)
  "Return the Theme source inherited by CTX, without reading it."
  (let ((theme (etaf--ictx-theme ctx)))
    (if (not (eq theme 'unset))
        theme
      (setf (etaf--ictx-theme ctx)
            (let ((etaf--current-context (etaf--ictx-context ctx)))
              (etaf--theme-source))))))

(defun etaf--ctx-call (ctx function &optional phase)
  "Call FUNCTION with CTX's Component environment and return its value.
PHASE is `render' (the default) or `lifecycle' for a retained effect that
must run outside the pure render phase."
  (let* ((instance (etaf--ictx-owner ctx))
         (spec (and instance (etaf--instance-spec instance)))
         (etaf--current-ictx ctx)
         (etaf--current-runtime (etaf--ictx-runtime ctx))
         (etaf--current-context (etaf--ictx-context ctx))
         (etaf--current-component-instance instance)
         (etaf--current-component-props (and instance (etaf--instance-cells instance)))
         (etaf--current-component-slots-ref
          (and instance (etaf--instance-slots-ref instance)))
         (etaf--current-component-state (and instance (etaf--instance-state instance)))
         (etaf--current-component-setup-defined-p
          (and spec (etaf--component-spec-setup spec) t))
         (etaf--current-component-setup-complete-p
          (and instance (etaf--instance-setup-p instance)))
         (etaf--render-parent-style-owners (and instance (etaf--instance-pctx instance)))
         (etaf--component-phase (and instance (if (eq phase 'lifecycle) 'setup 'render)))
         (etaf--render-phase-p (not (eq phase 'lifecycle))))
    (funcall function)))

(defun etaf--wrap-component-environment (function)
  "Return FUNCTION wrapped to run in the current Component environment.
A watcher, effect or computed getter created during Component setup or a
Runtime operation keeps that operation's Context, Runtime and lifecycle
phase on every later reactive run.  The wrapper forwards any arguments,
because watcher callbacks receive the new and old values."
  (let ((ctx etaf--current-ictx))
    (if (null ctx)
        function
      (lambda (&rest arguments)
        (etaf--ctx-call ctx (lambda () (apply function arguments)) 'lifecycle)))))

;; Name the hook with a function of its own.  `etaf-reactive' owns
;; `etaf--effect-environment' and delegates through this hook, so pointing the
;; hook at that wrapper would call it again from inside itself.
(defun etaf-runtime--animation-owner-buffer ()
  "Return the buffer of the currently active Runtime, or nil."
  (when-let* ((runtime (etaf-current-runtime)))
    (etaf-runtime-buffer runtime)))

(setq etaf--effect-environment-function #'etaf--wrap-component-environment)
(setq etaf-animation--owner-buffer-function #'etaf-runtime--animation-owner-buffer)

(defun etaf--note-update (ctx)
  "Record that an effect owned by CTX's instance re-ran."
  (let ((instance (etaf--ictx-owner ctx)))
    (when (and instance (etaf--instance-mounted-p instance)
               (not (etaf--instance-updated-p instance)))
      (let ((runtime (etaf--ictx-runtime ctx)))
        (setf (etaf--instance-updated-p instance) t)
        (push instance (etaf-runtime-updated-instances runtime))
        (etaf--runtime-touch runtime)))))

(defun etaf--effect (ctx owner function &optional quiet)
  "Run FUNCTION for OWNER in CTX now and return its retained effect, or nil.
Without a Runtime, FUNCTION runs once untracked.  An effect that read no
reactive source can never re-run, so it is released immediately.  Unless
QUIET, each later run records an update of CTX's Component instance."
  (if (null (etaf--ictx-runtime ctx))
      (progn (etaf-untracked (etaf--ctx-call ctx function)) nil)
    (let* ((first t)
           (effect
            (etaf-reactive-effect-create
             (lambda ()
               (if first
                   (setq first nil)
                 (unless quiet (etaf--note-update ctx)))
               (etaf--ctx-call ctx function))
             :phase 1 :owner owner :scope nil :data etaf--txn)))
      (when etaf--txn (push effect (etaf--txn-created etaf--txn)))
      (condition-case err
          (etaf-reactive-effect-run effect)
        ((error quit)
         (etaf-reactive-effect-stop effect t)
         (signal (car err) (cdr err))))
      (if (etaf-effect-deps effect)
          effect
        (etaf-reactive-effect-stop effect t)
        nil))))

(defun etaf--effect-rerun (effect)
  "Run retained EFFECT again now."
  (when (and effect (etaf-effect-active effect))
    (etaf-reactive-effect-run effect)))

(defun etaf--stop (effect)
  "Stop EFFECT when non-nil; a rollback revives a committed effect."
  (when (and effect (etaf-effect-active effect))
    (when (and etaf--txn (not (etaf--txn-fresh-p effect)))
      (push effect (etaf--txn-stopped etaf--txn)))
    (etaf-reactive-effect-stop effect t)))

;;;; Host properties

(defun etaf--behavior-source-p (value)
  "Return non-nil when VALUE has the public `:use' source grammar."
  (or (null value)
      (symbolp value)
      (etaf-behavior-spec-p value)
      (and (proper-list-p value)
           (cl-every (lambda (entry)
                       (or (symbolp entry) (etaf-behavior-spec-p entry)))
                     value))))

(defun etaf--validate-semantic-properties (props)
  "Return PROPS after validating ETAF Runtime-owned metadata values."
  (cl-loop for (property value) on props by #'cddr
           do
           (cond
            ((eq property :ref)
             (unless (or (null value) (symbolp value) (functionp value)
                         (and (consp value) (eq (car value) 'etaf-host)))
               (signal 'etaf-renderer-error
                       (list ":ref must be a symbol, function, or nil"))))
            ((eq property :role)
             (unless (or (null value) (symbolp value) (stringp value))
               (signal 'etaf-renderer-error
                       (list ":role must be a symbol, string, or nil"))))
            ((etaf--aria-property-p property)
             (unless (or (null value) (stringp value) (numberp value)
                         (symbolp value))
               (signal 'etaf-renderer-error
                       (list (format "%S has an invalid semantic value"
                                     property)))))
            ((etaf--event-property-p property)
             (unless (or (null value) (functionp value))
               (signal 'etaf-renderer-error
                       (list (format "%S must be a function or nil"
                                     property)))))
            ((eq property :disabled)
             (unless (memq value '(nil t))
               (signal 'etaf-renderer-error
                       (list ":disabled must be boolean"))))
            ((eq property :sticky)
             (unless (memq value '(nil top))
               (signal 'etaf-renderer-error
                       (list ":sticky must be `top' or nil"))))
            ((eq property :translate)
             (unless (memq value '(nil t yes no content))
               (signal 'etaf-renderer-error
                       (list ":translate must be t, `yes', `no', `content' or nil"))))
            ((eq property :tab-index)
             (unless (or (null value) (integerp value))
               (signal 'etaf-renderer-error
                       (list ":tab-index must be an integer or nil"))))
            ((eq property :focus-group)
             (unless (memq value '(nil vertical horizontal grid))
               (signal 'etaf-renderer-error
                       (list ":focus-group must be vertical, horizontal, grid or nil"))))
            ((eq property :focus-scope)
             (unless (memq value '(nil modal))
               (signal 'etaf-renderer-error
                       (list ":focus-scope must be `modal' or nil"))))
            ((eq property :key-scope)
             (unless (memq value '(nil local))
               (signal 'etaf-renderer-error
                       (list ":key-scope must be `local' or nil"))))
            ((eq property :keys)
             (etaf--keys-validate value))
            ((eq property :help)
             (unless (or (null value) (stringp value)
                         (and (proper-list-p value) (cl-every #'stringp value)))
               (signal 'etaf-renderer-error
                       (list ":help must be a string or a list of strings"))))
            ((eq property :on-direction)
             (unless (or (null value) (functionp value))
               (signal 'etaf-renderer-error
                       (list ":on-direction must be a function or nil"))))
            ((eq property :region)
             (etaf--region-validate value))
            ((eq property :use)
             (unless (or (etaf--behavior-source-p value)
                         (and (proper-list-p value)
                              (cl-every #'etaf-behavior-spec-p value)))
               (signal 'etaf-renderer-error
                       (list ":use must be a Behavior symbol, spec, or proper list"))))))
  props)

(defun etaf--behavior-specs (value)
  "Normalize resolved `:use' VALUE to a list of Behavior specs."
  (cl-labels
      ((resolve
        (entry)
        (cond
         ((etaf-behavior-spec-p entry) entry)
         ((and (symbolp entry) (fboundp entry))
          (let ((spec (funcall entry)))
            (unless (etaf-behavior-spec-p spec)
              (signal 'etaf-behavior-error
                      (list (format "Behavior constructor %S returned %S"
                                    entry spec))))
            spec))
         ((symbolp entry)
          (signal 'etaf-behavior-error
                  (list (format "Unknown Behavior constructor: %S" entry))))
         (t
          (signal 'etaf-behavior-error
                  (list (format "Invalid :use entry: %S" entry)))))))
    (let ((specs
           (cond
            ((null value) nil)
            ((or (symbolp value) (etaf-behavior-spec-p value))
             (list (resolve value)))
            ((proper-list-p value) (mapcar #'resolve value))
            (t
             (signal 'etaf-behavior-error
                     (list ":use must be a Behavior symbol, spec, or proper list")))))
          names)
      (dolist (spec specs)
        (let ((name (etaf-behavior-spec-name spec)))
          (when (memq name names)
            (signal 'etaf-behavior-error
                    (list (format "Duplicate Behavior on one Host: %S" name))))
          (push name names)))
      specs)))

(defun etaf--merge-behavior-props (props tag)
  "Return resolved PROPS of Host TAG with its `:use' Behavior attributes merged."
  (etaf--validate-semantic-properties props)
  (let* ((specs (etaf--behavior-specs (plist-get props :use)))
         (merged (etaf--plist-set props :use specs)))
    (dolist (spec specs)
      (let ((attributes (etaf--resolve-property-plist
                         (etaf-behavior-spec-attributes spec))))
        (etaf--validate-semantic-properties attributes)
        (while attributes
          (let ((key (pop attributes)) (value (pop attributes)))
            (cond
             ((or (etaf--event-property-p key) (eq key :disabled)
                  (etaf--owned-semantic-property-p key))
              (setq merged (etaf--merge-host-attrs
                            merged (list key value) tag
                            (etaf-behavior-spec-name spec))))
             ((eq key :keys)
              ;; The Host's own bindings shadow its Behaviors' bindings.
              (setq merged (etaf--plist-set
                            merged :keys (append (plist-get merged :keys) value))))
             ((not (plist-member merged key))
              (setq merged (append merged (list key value)))))))))
    merged))

(defun etaf--interaction-boundary-p (props)
  "Return non-nil when resolved PROPS describe an interaction boundary.
Disabled and callbackless controls still own their hit area.  Ordinary text
with only a reference or accessibility label remains part of its parent."
  (or (functionp (plist-get props :on-press))
      (functionp (plist-get props :on-drag))
      (plist-get props :disabled)
      (numberp (plist-get props :tab-index))
      (member (let ((role (plist-get props :role)))
                (if (symbolp role) (symbol-name role) role))
              '("button" "checkbox" "combobox" "link" "menuitem" "option"
                "radio" "slider" "spinbutton" "switch" "tab" "textbox"
                "treeitem"))))

(defun etaf--semantic-props-p (props)
  "Return non-nil when PROPS carry a non-nil ETAF semantic property."
  (cl-loop for (key value) on props by #'cddr
           thereis (and value (etaf--semantic-property-p key))))

(defun etaf--event-kind (property)
  "Return the event kind named by `:on-' PROPERTY."
  (intern (substring (symbol-name property) 4)))

(defun etaf--props-handlers (props)
  "Return the event handler alist of resolved Host PROPS."
  (let (handlers)
    (cl-loop for (key value) on props by #'cddr
             when (and (etaf--event-property-p key) (functionp value))
             do (push (cons (etaf--event-kind key) value) handlers))
    (nreverse handlers)))

(defun etaf--activation-keymap (runtime host ref press drag lock edge)
  "Return HOST's activation keymap dispatching REF in RUNTIME."
  (let ((key (list ref press drag lock edge))
        (cached (etaf--host-keymap host)))
    (if (and cached (equal (car cached) key))
        (cdr cached)
      (let ((map (ebox-keymap-create
                  :activate
                  (when press
                    (lambda () (etaf--dispatch-activation runtime ref)))
                  :drag
                  (when drag
                    (lambda (gesture)
                      (when (and (etaf-runtime-mounted-p runtime)
                                 (cdr (assq 'drag (etaf-runtime-handler-for runtime ref))))
                        (let ((etaf--drag-cancel-p
                               (eq (plist-get gesture :phase) 'cancel)))
                          (etaf-dispatch-event runtime ref 'drag gesture t)))))
                  :drag-lock-modifier lock
                  :drag-edge edge)))
        (setf (etaf--host-keymap host) (cons key map))
        map))))

(defun etaf--relay-dispatcher (runtime host ref kind)
  "Return HOST's stable Ebox function dispatching KIND events of REF in RUNTIME.
KIND is `swipe' or `scroll'.  The function identity stays constant across
renders, so a re-rendered `:on-swipe' or `:on-scroll' callback does not
invalidate layout."
  (let ((cached (assq kind (etaf--host-relays host))))
    (if (and cached (eq (cadr cached) ref))
        (cddr cached)
      (let ((fn (lambda (value)
                  (when (and (etaf-runtime-mounted-p runtime)
                             (cdr (assq kind (etaf-runtime-handler-for runtime ref))))
                    (etaf-dispatch-event runtime ref kind value t)))))
        (setf (etaf--host-relays host)
              (cons (cons kind (cons ref fn))
                    (assq-delete-all kind (etaf--host-relays host))))
        fn))))

;;;; Theme

(defvar etaf--theme-host-default-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Theme value to (Host name to resolved accepted defaults).")

(defun etaf--theme-host-defaults (theme name)
  "Return THEME's resolved defaults accepted by Host NAME."
  (if (null theme)
      nil
    (let* ((by-name (or (gethash theme etaf--theme-host-default-cache)
                        (puthash theme (make-hash-table :test #'eq)
                                 etaf--theme-host-default-cache)))
           (cached (gethash name by-name 'none)))
      (if (not (eq cached 'none))
          cached
        (let ((tail theme) result)
          (while tail
            (let ((key (pop tail)) (value (pop tail)))
              (when (and (keywordp key)
                         (ebox-style-schema-id key)
                         (ebox-style-property-accepted-p name key))
                (let ((resolved (etaf--theme-token-resolve-from-theme
                                 (etaf-theme-token key value) theme)))
                  (when resolved
                    (push key result)
                    (push resolved result))))))
          (puthash name (nreverse result) by-name))))))

(defun etaf--ctx-theme-value (ctx)
  "Return CTX's Theme plist, tracking a reactive Theme source."
  (let ((source (etaf--ctx-theme ctx)))
    (etaf--theme-source-value source nil t)))

(defun etaf--theme-hover-token-p (value)
  "Return non-nil when a `:hover-style' plist VALUE carries a Theme token."
  (and (proper-list-p value)
       (cl-loop for (_key item) on value by #'cddr
                thereis (etaf-theme-token-p item))))

(defun etaf--resolve-theme-plist (props theme)
  "Return PROPS with Theme tokens resolved from THEME.
Tokens nested in a `:hover-style' plist resolve too: Ebox turns that plist
into a native mouse face, where an unresolved token is an invalid attribute
and the hover paint is lost."
  (if (not (cl-loop for (key value) on props by #'cddr
                    thereis (or (etaf-theme-token-p value)
                                (and (eq key :hover-style)
                                     (etaf--theme-hover-token-p value)))))
      props
    (cl-loop for (key value) on props by #'cddr
             append (list key
                          (cond
                           ((etaf-theme-token-p value)
                            (etaf--theme-token-resolve-from-theme value theme))
                           ((eq key :hover-style)
                            (etaf--resolve-theme-plist value theme))
                           (t value))))))

;;;; Component styles

(defun etaf--instance-rules (instance theme)
  "Return INSTANCE's Component rule snapshot for THEME."
  (let* ((rules (etaf--component-spec-styles (etaf--instance-spec instance)))
         (key (etaf--instance-style-key instance)))
    (if (and key (eq (car key) theme) (eq (cdr key) rules))
        (etaf--instance-style-revision instance)
      (let ((resolved (mapcar (lambda (rule)
                                (cons (car rule)
                                      (etaf--resolve-theme-plist (cdr rule) theme)))
                              rules)))
        (setf (etaf--instance-style-key instance) (cons theme rules)
              (etaf--instance-style-revision instance)
              (ebox-style-scope-with-rules (etaf--instance-style-scope instance)
                                           resolved))))))

;;;; Ebox properties

(defconst etaf--rejected-host-props
  '(:face :surface-properties :selector-attributes :selector-state
    :ecss-scopes :ecss-scope-roots :interactions)
  "Ebox metadata ETAF Hosts must not author directly.")

(defconst etaf--affordance-props
  '(:help-echo :pointer :hover-style :hover-content :drag-lock-modifier
    :hover-group)
  "Host affordances passed to Ebox even on non-activating Hosts.")

(defun etaf--attribute-name (key)
  "Return selector attribute name of semantic KEY."
  (substring (symbol-name key) 1))

(defun etaf--image-props (props)
  "Return prepared Ebox image of resolved image PROPS."
  (let ((src (plist-get props :src))
        (columns (plist-get props :columns))
        (rows (plist-get props :rows))
        (adapter (or (plist-get props :adapter) 'auto))
        (inset (plist-get props :inset)))
    (unless (or (stringp src)
                (and (consp src) (eq (car src) 'image)
                     (proper-list-p (cdr src))
                     (symbolp (plist-get (cdr src) :type))
                     (or (stringp (plist-get (cdr src) :data))
                         (stringp (plist-get (cdr src) :file)))))
      (signal 'etaf-renderer-error
              (list (format "Image :src must be a file path or an image descriptor with :type and :data or :file: %S"
                            src))))
    (dolist (pair (list (cons :columns columns) (cons :rows rows)))
      (unless (and (integerp (cdr pair)) (> (cdr pair) 0))
        (signal 'etaf-renderer-error
                (list (format "Image %s must be a positive integer: %S"
                              (car pair) (cdr pair))))))
    (unless (memq adapter '(auto kitty text placeholder))
      (signal 'etaf-renderer-error
              (list (format "Image :adapter must be auto, kitty, text or placeholder: %S"
                            adapter))))
    (unless (or (null inset)
                (and (consp inset) (natnump (car inset)) (natnump (cdr inset))))
      (signal 'etaf-renderer-error
              (list (format "Image :inset must be nil or (TOP . BOTTOM) pixels: %S"
                            inset))))
    (ebox-image-prepare src columns rows :adapter adapter :inset inset)))

(defun etaf--compute-eprops (name props ctx theme runtime host ref)
  "Return the Ebox properties of Host NAME with resolved PROPS.
CTX supplies Component styles, THEME supplies tokens and defaults.  RUNTIME,
HOST and REF are non-nil for a mounted Host, which receives a keymap."
  (let ((tail props) (image-p (eq name 'image)) result attributes)
    (while tail
      (let ((key (pop tail)) (value (pop tail)))
        (cond
         ((memq key etaf--rejected-host-props)
          (signal 'etaf-renderer-error
                  (list (format "%S is not a canonical ETAF property" key))))
         ((eq key :content)
          (signal 'etaf-renderer-error
                  (list "Use View children for content, not :content")))
         ((memq key '(:class :id :key))
          (when value (push key result) (push value result)))
         ((eq key :role)
          (when value (push (cons "role" value) attributes)))
         ((memq key '(:focus-group :focus-scope))
          (when value (push key result) (push value result)))
         ((etaf--aria-property-p key)
          (push (cons (etaf--attribute-name key) value) attributes))
         ((or (etaf--semantic-property-p key) (eq key :styles)) nil)
         ((and image-p (memq key '(:src :columns :rows :adapter :inset))) nil)
         (t
          (when (etaf-theme-token-p value)
            (setq value (etaf--theme-token-resolve-from-theme value theme)))
          (when value (push key result) (push value result))))))
    ;; RESULT is built in reverse: each pair pushes its key, then its value.
    (when attributes
      (push :attributes result) (push (nreverse attributes) result))
    (when (etaf--interaction-boundary-p props)
      (let* ((disabled (plist-get props :disabled))
             (press (functionp (plist-get props :on-press)))
             (drag (functionp (plist-get props :on-drag)))
             (map (and runtime (or press drag) (not disabled)
                       (etaf--activation-keymap runtime host ref press drag
                                          (plist-get props :drag-lock-modifier)
                                          (plist-get props :drag-edge)))))
        (when map (push :keymap result) (push map result))
        (when (plist-get props :tab-index)
          (push :tab-index result) (push (plist-get props :tab-index) result))
        (when disabled (push :disabled result) (push t result))
        (when (and (or press drag) (not disabled) (not (plist-member props :pointer)))
          (push :pointer result) (push 'hand result))))
    (when (and runtime (functionp (plist-get props :on-swipe))
               (not (plist-get props :disabled)))
      (push :swipe result)
      (push (etaf--relay-dispatcher runtime host ref 'swipe) result))
    (when (and runtime (functionp (plist-get props :on-scroll))
               (not (plist-get props :disabled)))
      (push :scroll result)
      (push (etaf--relay-dispatcher runtime host ref 'scroll) result))
    (dolist (key etaf--affordance-props)
      (when (plist-member props key)
        (let ((value (plist-get props key)))
          ;; A hover style is a plist Ebox turns into a native mouse face;
          ;; resolve its tokens like any other Host style value.
          (when (and (eq key :hover-style)
                     (etaf--theme-hover-token-p value))
            (setq value (etaf--resolve-theme-plist value theme)))
          (push key result) (push value result))))
    (unless image-p
      (when-let* ((defaults (etaf--theme-host-defaults theme name)))
        (push :defaults result) (push defaults result)))
    (when-let* ((owner (etaf--ictx-owner ctx))
                (scope (or (etaf--instance-style-scope owner)
                           (and (etaf--component-spec-styles
                                 (etaf--instance-spec owner))
                                (setf (etaf--instance-style-scope owner)
                                      (ebox-style-scope-create nil))))))
      (push :ecss-scopes result) (push (list scope) result)
      (when (etaf--ictx-root-p ctx)
        (push :ecss-scope-roots result)
        (push (list (etaf--instance-rules owner theme)) result)))
    (setq result (nreverse result))
    (if (not image-p)
        result
      (append (cl-loop for (key value) on result by #'cddr
                       unless (ebox-style-schema-id key)
                       append (list key value))
              (list :image (etaf--image-props props))))))

;;;; View items

(defun etaf--flatten-into (value acc)
  "Push VALUE's View items onto ACC, last first, and return ACC."
  (cond
   ((null value) acc)
   ((stringp value) (cons (etaf--text-view-from-string value) acc))
   ((or (etaf--view-node-p value) (etaf--component-call-p value)
        (etaf--slot-projection-p value) (etaf--expr-p value))
    (cons value acc))
   ((and (consp value) (proper-list-p value))
    (dolist (item value acc)
      (setq acc (etaf--flatten-into item acc))))
   (t (signal 'etaf-renderer-error
              (list (format "Unresolved View item: %S" value))))))

(defun etaf--flatten (value)
  "Return VALUE's View items as a fresh list."
  (nreverse (etaf--flatten-into value nil)))

(defun etaf--item-key (item)
  "Return ITEM's identity key: a cons matched by `eq' car and `equal' cdr."
  (cond
   ((etaf--view-node-p item)
    (let ((name (etaf--view-node-name item))
          (key (plist-get (etaf--view-node-props item) :key)))
      (when key (setq key (etaf--resolve-property-value key)))
      (cons name (if (eq name 'fragment)
                     (or key (etaf--view-node-token item))
                   key))))
   ((etaf--component-call-p item)
    (let ((key (plist-get (etaf--component-call-props item) :key)))
      (cons (etaf--component-call-spec item)
            (and key (etaf--resolve-property-value key)))))
   ((etaf--expr-p item)
    (cons (etaf--expr-token item) (etaf--expr-kind item)))
   ((etaf--slot-projection-p item)
    (cons 'slot
          (if (etaf--slot-projection-captured-p item)
              (list (etaf--slot-projection-name item) 'captured
                    (etaf--item-key
                     (car (etaf--slot-content-children
                           (etaf--slot-projection-content item)))))
            (list (etaf--slot-projection-name item)
                  (etaf--slot-projection-token item)))))
   ((stringp item) (list 'text))))

(defsubst etaf--key-match-p (left right)
  "Return non-nil when identity keys LEFT and RIGHT denote one segment."
  (and (eq (car left) (car right)) (equal (cdr left) (cdr right))))

(defun etaf--next-id (runtime)
  "Allocate a RUNTIME-unique positive integer, or 0 without a Runtime."
  (if runtime (cl-incf (etaf-runtime-next-id runtime)) 0))

;;;; Segment geometry

(defsubst etaf--seg-outer-node (seg)
  "Return the Ebox node that represents Host SEG in its parent."
  (let* ((host (etaf--seg-data seg))
         (bucket (and host (etaf--host-presentation host))))
    (if bucket
        (or (etaf--pb-outer bucket) (etaf--seg-node seg))
      (etaf--seg-node seg))))

(defsubst etaf--host-kids-parent (seg)
  "Return the Ebox node that holds SEG's own application children."
  (let* ((host (and (eq (etaf--seg-kind seg) 'host) (etaf--seg-data seg)))
         (bucket (and host (etaf--host-presentation host))))
    (if (and bucket (etaf--pb-holder bucket))
        (etaf--pb-holder bucket)
      (etaf--seg-node seg))))

(defun etaf--pres-pin-companion-inside (phys parent)
  "Keep PHYS's `companion-inside' slots ordered at the tail of PARENT.
Return non-nil when any slot moved."
  (let* ((host (and (eq (etaf--seg-kind phys) 'host) (etaf--seg-data phys)))
         (bucket (and host (etaf--host-presentation host)))
         (slots (and bucket
                     (cl-loop for entry in (etaf--pb-companions bucket)
                              when (and (eq (etaf--pres-mode entry) 'companion-inside)
                                        (etaf--pres-slot entry)
                                        (eq (ebox-node-parent (etaf--pres-slot entry)) parent))
                              collect (etaf--pres-slot entry)))))
    (when slots
      (let* ((total (ebox-node-child-count parent))
             (start (- total (length slots)))
             (moved nil)
             (idx start))
        (when (>= start 0)
          (dolist (slot slots)
            (unless (= (ebox-node-index slot) idx)
              (etaf--node-move slot idx)
              (setq moved t))
            (setq idx (1+ idx))))
        moved))))

(defun etaf--seg-collect (seg acc)
  "Push SEG's physical nodes onto ACC, last first, and return ACC."
  (if (eq (etaf--seg-kind seg) 'host)
      (let ((node (etaf--seg-outer-node seg)))
        (if node (cons node acc) acc))
    (dolist (kid (etaf--seg-kids seg) acc)
      (setq acc (etaf--seg-collect kid acc)))))

(defun etaf--seg-nodes (seg)
  "Return SEG's physical nodes in order."
  (nreverse (etaf--seg-collect seg nil)))

(defun etaf--kids-nodes (seg)
  "Return the physical nodes of SEG's kids in order."
  (let (acc)
    (dolist (kid (etaf--seg-kids seg))
      (setq acc (etaf--seg-collect kid acc)))
    (nreverse acc)))

(defun etaf--seg-first-node (seg)
  "Return SEG's first physical node, or nil."
  (if (eq (etaf--seg-kind seg) 'host)
      (etaf--seg-outer-node seg)
    (cl-some #'etaf--seg-first-node (etaf--seg-kids seg))))

(defun etaf--seg-last-node (seg)
  "Return SEG's last physical node, or nil."
  (if (eq (etaf--seg-kind seg) 'host)
      (etaf--seg-outer-node seg)
    (let ((kids (etaf--seg-kids seg)))
      (and kids
           (or (etaf--seg-last-node (car (last kids)))
               (cl-some #'etaf--seg-last-node (cdr (reverse kids))))))))

(defun etaf--seg-phys (seg)
  "Return the Host, presentation or root segment whose node list holds SEG's nodes."
  (let ((parent (etaf--seg-parent seg)))
    (while (not (memq (etaf--seg-kind parent) '(host root surface overlay pres)))
      (setq parent (etaf--seg-parent parent)))
    parent))

(defun etaf--seg-prev-node (seg)
  "Return the physical node just before SEG's region, or nil."
  (let ((child seg) (parent (etaf--seg-parent seg)) found)
    (while parent
      (let ((tail (etaf--seg-kids parent)) before)
        (while (and tail (not (eq (car tail) child)))
          (push (car tail) before)
          (setq tail (cdr tail)))
        (setq found (cl-some #'etaf--seg-last-node before)))
      (if (or found (memq (etaf--seg-kind parent) '(host root surface overlay pres)))
          (setq parent nil)
        (setq child parent parent (etaf--seg-parent parent))))
    found))

(defun etaf--seg-anchor-prev (seg)
  "Return the node before live region SEG, read before SEG changes.
SEG must not be a Host: a Host's own kids start its node list."
  (let ((first (etaf--seg-first-node seg)))
    (if (and first (ebox-node-parent first))
        (ebox-node-child (ebox-node-parent first) (1- (ebox-node-index first)))
      (etaf--seg-prev-node seg))))

(defun etaf--seg-runtime (seg)
  "Return SEG's Runtime, or nil in a pure render."
  (etaf--ictx-runtime (etaf--seg-ctx seg)))

(defun etaf--root-dirty (runtime)
  "Mark RUNTIME's top-level node list as changed."
  (when runtime
    (setf (etaf-runtime-root-dirty runtime) t)
    (etaf--runtime-changed runtime)))

(defun etaf--place (seg prev)
  "Place live SEG's region nodes contiguously after PREV.
For a Host SEG, place its kids' nodes from the start of its node."
  (let* ((runtime (etaf--seg-runtime seg))
         (phys (if (memq (etaf--seg-kind seg) '(host root surface overlay pres))
                   seg (etaf--seg-phys seg))))
    (if (memq (etaf--seg-kind phys) '(root overlay))
        (etaf--root-dirty runtime)
      (let* ((parent (etaf--host-kids-parent phys))
             (index (cond (prev (1+ (ebox-node-index prev)))
                         ((eq (etaf--seg-kind phys) 'surface)
                          (ebox-node-child-count parent))
                         (t 0)))
            (nodes (if (eq phys seg) (etaf--kids-nodes seg) (etaf--seg-nodes seg)))
            changed)
        (dolist (node nodes)
          (let ((at (ebox-node-parent node)))
            (cond
             ((and (eq at parent) (= (ebox-node-index node) index)))
             ((eq at parent)
              (etaf--node-move node (if (< (ebox-node-index node) index)
                                        (1- index) index))
              (setq changed t))
             (t
              (when at (etaf--node-remove node))
              (etaf--node-insert parent node index)
              (setq changed t))))
          (setq index (1+ (ebox-node-index node))))
        (when (etaf--pres-pin-companion-inside phys parent)
          (setq changed t))
        (when changed (etaf--runtime-changed runtime))))))

(defun etaf--detach (seg node)
  "Remove disposed SEG's NODE from its live parent."
  (let ((runtime (etaf--seg-runtime seg))
        (parent (ebox-node-parent node)))
    (when runtime
      (if (or (null parent) (eq parent (etaf-runtime-wrapper runtime)))
          (etaf--root-dirty runtime)
        (etaf--node-remove node)
        (etaf--runtime-changed runtime)))))


;;;; Value identity

(defun etaf--value-same-p (left right)
  "Return non-nil when LEFT and RIGHT are the same View input.
Reactive sources and functions compare by identity, conses recursively and
other values with `equal'."
  (cond
   ((or (etaf-ref-p left) (etaf-computed-p left) (functionp left)
        (etaf--expr-p left))
    (eq left right))
   ((consp left)
    (and (consp right)
         (etaf--value-same-p (car left) (car right))
         (etaf--value-same-p (cdr left) (cdr right))))
   (t (equal left right))))

;;;; Building and patching segments

(defun etaf--item-kind (item)
  "Return the segment kind of View ITEM."
  (cond
   ((etaf--view-node-p item)
    (if (eq (etaf--view-node-name item) 'fragment) 'frag 'host))
   ((etaf--component-call-p item) 'comp)
   ((etaf--expr-p item)
    (pcase (etaf--expr-kind item)
      ('branch 'branch)
      ('keyed-list 'list)
      (_ 'expr)))
   ((etaf--slot-projection-p item) 'slot)
   (t (signal 'etaf-renderer-error
              (list (format "Unresolved View item: %S" item))))))

(defun etaf--explicit-key-p (item)
  "Return non-nil when ITEM carries an explicit `:key'."
  (cond
   ((etaf--view-node-p item) (plist-get (etaf--view-node-props item) :key))
   ((etaf--component-call-p item)
    (plist-get (etaf--component-call-props item) :key))))

(define-hash-table-test 'etaf--identity-key
  #'etaf--key-match-p (lambda (key) (sxhash-equal (cdr key))))

(defun etaf--check-keys (items keys)
  "Signal when explicitly keyed ITEMS repeat one of their KEYS.
A short list is scanned directly; a long one is indexed, so checking a
list stays linear in its length."
  (let (seen table (count 0))
    (cl-loop for item in items for key in keys
             when (etaf--explicit-key-p item)
             do (when (if table (gethash key table)
                        (cl-member key seen :test #'etaf--key-match-p))
                  (signal 'etaf-renderer-error
                          (list (format "View has duplicate sibling key: %S"
                                        (cdr key)))))
             (cond
              (table (puthash key t table))
              ((< (setq count (1+ count)) 16) (push key seen))
              (t (setq table (make-hash-table :test 'etaf--identity-key
                                              :size (length keys)))
                 (dolist (old (cons key seen)) (puthash old t table)))))))

(defun etaf--build-items (items keys parent ctx)
  "Build segments for ITEMS with KEYS under PARENT in CTX; return them.
A failure disposes the segments already built."
  (let (built)
    (condition-case err
        (progn
          (while items
            (push (etaf--build (pop items) (pop keys) parent ctx) built))
          (nreverse built))
      ((error quit)
       (dolist (seg built) (etaf--dispose seg nil))
       (signal (car err) (cdr err))))))

(defun etaf--build-list (items parent ctx)
  "Build segments for View ITEMS under PARENT in CTX."
  (let ((keys (mapcar #'etaf--item-key items)))
    (etaf--check-keys items keys)
    (etaf--build-items items keys parent ctx)))

(defun etaf--build (item key parent ctx)
  "Build and return the segment of View ITEM with KEY under PARENT in CTX.
A failure disposes everything the segment acquired and re-signals."
  (let ((seg (etaf--seg-make :kind (etaf--item-kind item) :parent parent
                             :ctx ctx :src item :key key :txn etaf--txn)))
    (condition-case err
        (progn
          (pcase (etaf--seg-kind seg)
            ('host (etaf--host-init seg))
            ('frag (setf (etaf--seg-kids seg)
                         (etaf--build-list
                          (etaf--flatten (etaf--view-node-children item)) seg ctx)))
            ('comp (etaf--comp-init seg))
            ('slot (etaf--slot-init seg))
            (_ (etaf--region-init seg)))
          (setf (etaf--seg-live seg) t)
          seg)
      ((error quit)
       (etaf--dispose seg nil)
       (signal (car err) (cdr err))))))

(defun etaf--patch (seg item)
  "Update live SEG to render ITEM, which has SEG's identity key."
  (pcase (etaf--seg-kind seg)
    ('host (etaf--host-patch seg item))
    ('frag
     (setf (etaf--seg-src seg) item)
     (etaf--patch-kids seg (etaf--flatten (etaf--view-node-children item))
                       (etaf--seg-ctx seg)))
    ('comp (etaf--comp-patch seg item))
    ('slot
     (etaf--stop (etaf--seg-effect seg))
     (setf (etaf--seg-src seg) item (etaf--seg-effect seg) nil)
     (etaf--slot-init seg))
    (_
     (etaf--stop (etaf--seg-effect seg))
     (setf (etaf--seg-src seg) item (etaf--seg-effect seg) nil)
     (when (eq (etaf--seg-kind seg) 'branch)
       (setf (etaf--seg-data seg) 'unset))
     (etaf--region-init seg))))

(defun etaf--patch-kids (seg items ctx)
  "Make SEG's kids render View ITEMS, building new kids in CTX.
Kids whose identity key matches are kept and patched; others are built or
disposed.  When SEG is live its nodes are moved into place."
  (let* ((old (etaf--seg-kids seg))
         (keys (mapcar #'etaf--item-key items)))
    (etaf--check-keys items keys)
    (if (and (= (length old) (length keys))
             (cl-loop for kid in old for key in keys
                      always (etaf--key-match-p (etaf--seg-key kid) key)))
        (cl-loop for kid in old for item in items
                 unless (eq (etaf--seg-src kid) item)
                 do (etaf--patch kid item))
      (let* ((live (etaf--seg-live seg))
             (prev (and live (not (memq (etaf--seg-kind seg) '(host root surface overlay pres)))
                        (etaf--seg-anchor-prev seg)))
             (pool (copy-sequence old))
             new matched fresh)
        (condition-case err
            (cl-loop for item in items for key in keys
                     do (let ((hit (if (and pool (etaf--key-match-p
                                                   (etaf--seg-key (car pool)) key))
                                       (car pool)
                                     (cl-find-if (lambda (kid)
                                                   (etaf--key-match-p
                                                    (etaf--seg-key kid) key))
                                                 pool))))
                          (if hit
                              (progn (setq pool (delq hit pool))
                                     (push (cons hit item) matched)
                                     (push hit new))
                            (let ((built (etaf--build item key seg ctx)))
                              (push built fresh)
                              (push built new)))))
          ((error quit)
           (dolist (kid fresh) (etaf--dispose kid nil))
           (signal (car err) (cdr err))))
        (setf (etaf--seg-kids seg) (nreverse new))
        (dolist (kid pool) (etaf--dispose kid live))
        (when live (etaf--place seg prev))
        (dolist (entry (nreverse matched))
          (unless (eq (etaf--seg-src (car entry)) (cdr entry))
            (etaf--patch (car entry) (cdr entry))))))))

;;;; Host segments

(defun etaf--host-generated-ref (seg)
  "Return SEG's generated Host reference."
  (let ((host (etaf--seg-data seg)))
    (or (etaf--host-gref host)
        (setf (etaf--host-gref host)
              (let ((runtime (etaf--seg-runtime seg)))
                (list 'etaf-host (and runtime (etaf-runtime-mount-id runtime))
                      (etaf--host-id host)))))))

(defun etaf--host-dynamic-p (props ctx)
  "Return non-nil when Host PROPS in CTX need a retained binding."
  (or (cl-loop for (_key value) on props by #'cddr
               thereis (etaf--expr-p value))
      (plist-get props :use)
      (let ((theme (etaf--ctx-theme ctx)))
        (or (etaf-ref-p theme) (etaf-computed-p theme)))))

(defun etaf--host-sync (seg)
  "Resolve Host SEG's properties and apply them to its node."
  (let* ((host (etaf--seg-data seg))
         (item (etaf--seg-src seg))
         (name (etaf--view-node-name item))
         (ctx (etaf--seg-ctx seg))
         (runtime (etaf--ictx-runtime ctx))
         (resolved (etaf--resolve-property-plist (etaf--view-node-props item)))
         (theme (etaf--ctx-theme-value ctx))
         (node (etaf--seg-node seg)))
    (unless (and node (etaf--host-restyle host name resolved theme node runtime))
      (let* ((props (if (plist-get resolved :use)
                        (etaf--merge-behavior-props resolved name)
                      (etaf--validate-semantic-properties resolved)))
             (ref (or (plist-get props :ref) (etaf--host-generated-ref seg)))
             (eprops (etaf--compute-eprops name props ctx theme runtime host ref)))
        (setf (etaf--host-props host) (etaf--resolve-theme-plist props theme)
              (etaf--host-ref host) ref
              (etaf--host-rprops host) resolved
              (etaf--host-theme host) theme)
        (unless (equal eprops (etaf--host-eprops host))
          (let ((old (etaf--host-eprops host)))
            (setf (etaf--host-eprops host) eprops)
            (when node
              (etaf--node-set-props node eprops old)
              (etaf--runtime-changed runtime))))
        (when node (etaf--host-commit seg))))))

(defsubst etaf--plain-style-key-p (key)
  "Return non-nil when Host property KEY passes to Ebox as a plain style."
  (not (or (memq key '(:key :styles :content :use))
           (etaf--semantic-property-p key)
           (memq key etaf--rejected-host-props))))

(defun etaf--host-restyle (host name props theme node runtime)
  "Apply resolved PROPS to mounted HOST when only plain style values changed.
NAME is the Host name, THEME the current Theme and NODE HOST's Ebox node.
Return non-nil when PROPS were applied, or nil when they need the full
property computation: keys, metadata, Behaviors or the Theme changed."
  (let ((old (etaf--host-rprops host))
        (eprops (etaf--host-eprops host)))
    (when (and old eprops (not (eq name 'image))
               (eq theme (etaf--host-theme host)))
      (let ((a old) (b props) (ok t) changed)
        (while (and ok a b)
          (let ((key (car b)) (value (cadr b)))
            (cond
             ((not (eq key (car a))) (setq ok nil))
             ((eq value (cadr a)))
             ;; Callbacks and metadata compare by identity: a new closure
             ;; over equal contents must still replace the committed one.
             ((not (etaf--plain-style-key-p key)) (setq ok nil))
             ((equal value (cadr a)))
             (t
              (when (etaf-theme-token-p value)
                (setq value (etaf--theme-token-resolve-from-theme value theme)))
              (when (and (eq key :hover-style)
                         (etaf--theme-hover-token-p value))
                (setq value (etaf--resolve-theme-plist value theme)))
              ;; A nil value drops its key from the Ebox properties.
              (if (and value (plist-get eprops key))
                  (push (cons key value) changed)
                (setq ok nil)))))
          (setq a (cddr a) b (cddr b)))
        (when (and ok (null a) (null b))
          (setf (etaf--host-rprops host) props)
          (when changed
            (let ((new (copy-sequence eprops)))
              (dolist (entry changed) (plist-put new (car entry) (cdr entry)))
              (setf (etaf--host-props host) (etaf--resolve-theme-plist props theme)
                    (etaf--host-eprops host) new)
              (etaf--node-set-props node new eprops)
              (etaf--runtime-changed runtime)))
          t)))))

(defun etaf--host-bind-props (seg)
  "Bind Host SEG's properties, retaining an effect when they are dynamic."
  (let ((ctx (etaf--seg-ctx seg)))
    (if (etaf--host-dynamic-p (etaf--view-node-props (etaf--seg-src seg)) ctx)
        (setf (etaf--seg-effect seg)
              (etaf--effect ctx seg (lambda () (etaf--host-sync seg))))
      (etaf--ctx-call ctx (lambda () (etaf--host-sync seg))))))

(defun etaf--text-value (value)
  "Return Text payload VALUE as one string."
  (cond
   ((stringp value) value)
   ((null value) "")
   ((and (proper-list-p value) (cl-every #'stringp value))
    (apply #'concat value))
   (t (signal 'etaf-renderer-error
              (list "Text payload must resolve to one string")))))

(defun etaf--text-set (seg text)
  "Show TEXT in Text Host SEG."
  (let ((host (etaf--seg-data seg)))
    (unless (equal-including-properties text (etaf--host-text host))
      (let* ((bucket (etaf--host-presentation host))
             (old (if bucket
                      (etaf--pb-effective-text host bucket)
                    (etaf--host-text host)))
             (runtime (etaf--seg-runtime seg)))
        (setf (etaf--host-text host) text)
        (when bucket
          (let ((remaining
                 (cl-remove-if #'etaf--pres-text-override
                               (etaf--pb-overrides bucket))))
            (unless (eq (length remaining) (length (etaf--pb-overrides bucket)))
              (setf (etaf--pb-overrides bucket) remaining)
              (when (and (etaf--pb-active-override bucket)
                         (etaf--pres-text-override (etaf--pb-active-override bucket)))
                (setf (etaf--pb-active-override bucket) (car remaining)))))
          (when (etaf--pb-empty-p bucket)
            (setf (etaf--host-presentation host) nil
                  bucket nil)
            (when (and runtime (etaf-runtime-presentations runtime))
              (etaf--jremhash seg (etaf-runtime-presentations runtime)))))
        (let ((desired (if bucket
                           (etaf--pb-effective-text host bucket)
                         text)))
          (when-let* ((node (etaf--seg-node seg)))
            (etaf--node-set-text node desired old)
            (etaf--runtime-changed runtime)))))))

(defun etaf--text-bind (seg)
  "Bind Text Host SEG's payload."
  (let* ((host (etaf--seg-data seg))
         (children (etaf--view-node-children (etaf--seg-src seg)))
         (payload (car children)))
    (when (cdr children)
      (signal 'etaf-renderer-error
              (list "Text requires exactly one string or expr payload")))
    (if (etaf--expr-p payload)
        (setf (etaf--host-payload host)
              (etaf--effect (etaf--seg-ctx seg) seg
                            (lambda ()
                              (etaf--text-set
                               seg (etaf--text-value
                                    (funcall (etaf--expr-thunk payload)))))))
      (etaf--text-set seg (etaf--text-value payload)))))

(defun etaf--host-init (seg)
  "Build Host SEG's binding, children and node."
  (let* ((item (etaf--seg-src seg))
         (name (etaf--view-node-name item))
         (ctx (etaf--seg-ctx seg))
         (host (etaf--host-make :id (etaf--next-id (etaf--ictx-runtime ctx))
                               :txn etaf--txn)))
    (setf (etaf--seg-data seg) host)
    (unless (memq name '(text box row column flex grid image))
      (signal 'etaf-renderer-error
              (list (format "Expected text, image, box, row, column, flex, or grid Host; received %S"
                            name))))
    (etaf--host-bind-props seg)
    (cond
     ((eq name 'text)
      (etaf--text-bind seg)
      (setf (etaf--seg-node seg)
            (ebox-text-create (etaf--host-text host) (etaf--host-eprops host))))
     (t
      (when (and (eq name 'image) (etaf--view-node-children item))
        (signal 'etaf-renderer-error (list "Image Host takes no children")))
      (setf (etaf--seg-kids seg)
            (etaf--build-list (etaf--flatten (etaf--view-node-children item))
                              seg (etaf--ctx-inner ctx)))
      (setf (etaf--seg-node seg)
            (ebox-node-create name (etaf--host-eprops host)
                              (etaf--kids-nodes seg)))))
    (etaf--host-commit seg)))

(defun etaf--host-patch (seg item)
  "Make live Host SEG render ITEM."
  (let ((old (etaf--seg-src seg))
        (host (etaf--seg-data seg)))
    (setf (etaf--seg-src seg) item)
    (unless (and (eq (etaf--view-node-props old) (etaf--view-node-props item))
                 (null (etaf--seg-effect seg)))
      (etaf--stop (etaf--seg-effect seg))
      (setf (etaf--seg-effect seg) nil)
      (etaf--host-bind-props seg))
    (if (eq (etaf--view-node-name item) 'text)
        (unless (equal-including-properties (etaf--view-node-children old)
                                            (etaf--view-node-children item))
          (etaf--stop (etaf--host-payload host))
          (setf (etaf--host-payload host) nil)
          (etaf--text-bind seg))
      (etaf--patch-kids seg (etaf--flatten (etaf--view-node-children item))
                        (etaf--ctx-inner (etaf--seg-ctx seg))))))

(defun etaf--host-unregister (runtime host)
  "Remove HOST's registered reference from RUNTIME."
  (when-let* ((ref (etaf--host-reg host)))
    (let* ((hosts (etaf-runtime-hosts runtime))
           (seg (gethash ref hosts)))
      (when (and seg (eq (etaf--seg-data seg) host))
        (etaf--jremhash ref hosts)))
    (setf (etaf--host-reg host) nil)))

(defun etaf--host-commit (seg)
  "Register Host SEG's reference and synchronize its Behaviors."
  (when-let* ((runtime (etaf--seg-runtime seg)))
    (let* ((host (etaf--seg-data seg))
           (ref (etaf--host-ref host)))
      (if (etaf--semantic-props-p (etaf--host-props host))
          (progn
            (unless (equal ref (etaf--host-reg host))
              (etaf--host-unregister runtime host)
              (etaf--jputhash ref seg (etaf-runtime-hosts runtime))
              (setf (etaf--host-reg host) ref))
            (etaf--jputhash (etaf--seg-node seg) seg (etaf-runtime-nodes runtime))
            (when-let* ((keys (plist-get (etaf--host-props host) :keys)))
              (etaf--keys-register runtime keys)))
        (when (etaf--host-reg host)
          (etaf--host-unregister runtime host)
          (etaf--jremhash (etaf--seg-node seg) (etaf-runtime-nodes runtime))))
      (when (if (plist-get (etaf--host-props host) :sticky)
                (not (equal ref (etaf-runtime-sticky runtime)))
              (equal ref (etaf-runtime-sticky runtime)))
        (setf (etaf-runtime-sticky runtime)
              (and (plist-get (etaf--host-props host) :sticky) ref))
        (etaf--runtime-changed runtime))
      (etaf--host-sync-behaviors seg))))

;;;; Behaviors

(defun etaf--behavior-same-p (left right)
  "Return non-nil when Behavior specs LEFT and RIGHT install the same thing."
  (and (eq (etaf-behavior-spec-name left) (etaf-behavior-spec-name right))
       (eq (etaf-behavior-spec-install left) (etaf-behavior-spec-install right))
       (etaf--value-same-p (etaf-behavior-spec-attributes left)
                           (etaf-behavior-spec-attributes right))))

(defun etaf--behavior-cleanup (runtime states)
  "Run the cleanups of Behavior STATES, recording failures on RUNTIME.
States installed by the current transaction are cleaned now; committed
states are cleaned when the transaction commits."
  (when etaf--txn
    (let ((fresh (etaf--txn-installs etaf--txn)) now later)
      (dolist (state states)
        (if (memq state fresh)
            (progn (setq fresh (delq state fresh)) (push state now))
          (push state later)))
      (setf (etaf--txn-installs etaf--txn) fresh)
      (when later
        (setq later (nreverse later))
        (etaf--txn-defer (lambda () (etaf--behavior-cleanup runtime later))))
      (setq states (nreverse now))))
  (dolist (state states)
    (when-let* ((cleanup (cddr state)))
      (condition-case err
          (let ((etaf--render-phase-p nil)
                (etaf--current-runtime runtime))
            (etaf-untracked (funcall cleanup)))
        ((error quit) (push err (etaf-runtime-errors runtime)))))))

(defun etaf--behavior-install (runtime spec props ref)
  "Install Behavior SPEC for Host PROPS with REF; return its cleanup."
  (when-let* ((install (etaf-behavior-spec-install spec)))
    (let* ((etaf--render-phase-p nil)
           (etaf--current-runtime runtime)
           (etaf--current-behavior-context
            (etaf--behavior-context-create
             :runtime runtime :host-props (etaf--plist-set props :ref ref)))
           (cleanup (etaf-untracked (funcall install))))
      (unless (or (null cleanup) (functionp cleanup))
        (signal 'etaf-behavior-error
                (list (format "Behavior %S installer must return cleanup"
                              (etaf-behavior-spec-name spec)))))
      cleanup)))

(defun etaf--host-sync-behaviors (seg)
  "Install, keep or clean up Host SEG's Behaviors."
  (let* ((runtime (etaf--seg-runtime seg))
         (host (etaf--seg-data seg))
         (props (etaf--host-props host))
         (specs (and (not (plist-get props :disabled)) (plist-get props :use)))
         (ref (etaf--host-ref host))
         (old (etaf--host-behaviors host)))
    (when (or specs old)
      (let (kept wanted)
        (dolist (spec specs)
          (let ((state (cl-find-if (lambda (state)
                                     (and (etaf--behavior-same-p (car state) spec)
                                          (equal (cadr state) ref)))
                                   old)))
            (when state
              (setq old (remq state old))
              (push state kept))
            (push (cons spec state) wanted)))
        (etaf--behavior-cleanup runtime old)
        (let (states)
          (condition-case err
              (dolist (entry (nreverse wanted))
                (push (or (cdr entry)
                          (let ((state (cons (car entry)
                                             (cons ref (etaf--behavior-install
                                                        runtime (car entry) props ref)))))
                            (when etaf--txn
                              (push state (etaf--txn-installs etaf--txn)))
                            state))
                      states))
            ((error quit)
             (setf (etaf--host-behaviors host)
                   (append states (cl-set-difference kept states :test #'eq)))
             (signal (car err) (cdr err))))
          (setf (etaf--host-behaviors host) (nreverse states)))))))

;;;; Regions

(defun etaf--region-init (seg)
  "Bind expression, branch or keyed-list region SEG."
  (let* ((ctx (etaf--seg-ctx seg))
         (expr (etaf--seg-src seg)))
    (setf (etaf--seg-effect seg)
          (etaf--effect
           ctx seg
           (pcase (etaf--seg-kind seg)
             ('expr
              (lambda ()
                (let ((value (funcall (etaf--expr-thunk expr))))
                  (etaf-untracked
                    (etaf--patch-kids seg (etaf--flatten value) ctx)))))
             ('branch
              (when (null (etaf--seg-data seg))
                (setf (etaf--seg-data seg) 'unset))
              (lambda ()
                (let ((arm (funcall (etaf--expr-range-snapshot expr))))
                  (unless (eql arm (etaf--seg-data seg))
                    (etaf-untracked
                      (etaf--patch-kids
                       seg (etaf--flatten (funcall (etaf--expr-range-item expr) arm))
                       ctx))
                    (setf (etaf--seg-data seg) arm)))))
             ('list
              (lambda ()
                (let ((items (funcall (etaf--expr-range-snapshot expr))))
                  (etaf-untracked (etaf--patch-list seg items))))))))))

(defun etaf--row-build (seg key item itemfn)
  "Build one keyed row of list SEG for ITEM with KEY using ITEMFN."
  (let* ((ctx (etaf--seg-ctx seg))
         (cell (etaf--ref-create :value item))
         (row (etaf--seg-make :kind 'row :parent seg :ctx ctx :src item
                              :key key :data cell :txn etaf--txn)))
    (condition-case err
        (progn
          (setf (etaf--seg-kids row)
                (etaf--build-list (etaf--flatten (funcall itemfn cell)) row ctx)
                (etaf--seg-live row) t)
          row)
      ((error quit)
       (etaf--dispose row nil)
       (signal (car err) (cdr err))))))

(defun etaf--row-repatch (row itemfn)
  "Patch ROW's kids against ITEMFN's View of its cell."
  (etaf--patch-kids row (etaf--flatten (funcall itemfn (etaf--seg-data row)))
                    (etaf--seg-ctx row)))

(defmacro etaf--row-src (row)
  "Read the item shown by list ROW without a type check."
  `(aref ,row ,(cl-struct-slot-offset 'etaf--seg 'src)))

(defun etaf--row-matches-p (row item keyfn)
  "Return non-nil when retained ROW can show ITEM: same item or same key."
  (or (eq (etaf--seg-src row) item)
      (equal (etaf--seg-key row) (funcall keyfn item))))

(defun etaf--patch-list (seg items)
  "Make keyed-list SEG show ITEMS, retaining rows by key.
Leading and trailing rows that still match cost one comparison each and
allocate nothing, so appending or editing near either end of a long list
stays proportional to the change."
  (let* ((expr (etaf--seg-src seg))
         (keyfn (etaf--expr-range-key expr))
         (itemfn (etaf--expr-range-item expr))
         (data (etaf--seg-data seg))
         (table (or (car data) (make-hash-table :test #'equal)))
         (itemfn-changed (and data (not (eq (cdr data) itemfn))))
         (live (etaf--seg-live seg))
         (old (etaf--seg-kids seg))
         (otail old) (itail items) (plen 0) (slen 0) (last-cell nil)
         changed-rows)
    ;; Matching leading rows.  Rows still showing the same item are
    ;; skipped with one unchecked slot read each.
    (while (and otail itail (eq (etaf--row-src (car otail)) (car itail)))
      (setq last-cell otail otail (cdr otail) itail (cdr itail)))
    (when last-cell (setq plen (- (length old) (length otail))))
    (while (and otail itail
                (etaf--row-matches-p (car otail) (car itail) keyfn))
      (unless (eq (etaf--seg-src (car otail)) (car itail))
        (push (cons (car otail) (car itail)) changed-rows))
      (setq last-cell otail otail (cdr otail) itail (cdr itail) plen (1+ plen)))
    ;; Matching trailing rows, compared from the end of what remains.
    (let ((ovec (and otail itail (vconcat otail)))
          (ivec (and otail itail (vconcat itail))))
      (when ovec
        (let ((oi (1- (length ovec))) (ii (1- (length ivec))))
          (while (and (>= oi 0) (>= ii 0)
                      (etaf--row-matches-p (aref ovec oi) (aref ivec ii) keyfn))
            (unless (eq (etaf--seg-src (aref ovec oi)) (aref ivec ii))
              (push (cons (aref ovec oi) (aref ivec ii)) changed-rows))
            (setq oi (1- oi) ii (1- ii) slen (1+ slen))))))
    (let* ((mid-old (if (zerop slen) otail (butlast otail slen)))
           (suffix (and (> slen 0) (last otail slen)))
           (mid-items (if (zerop slen) itail (butlast itail slen)))
           (mid-keys (mapcar keyfn mid-items))
           (mid-old-set (and mid-old (make-hash-table :test #'eq)))
           (seen (and (cdr mid-keys) (make-hash-table :test #'equal)))
           prev mid-rows fresh)
      (dolist (row mid-old) (puthash row t mid-old-set))
      (dolist (key mid-keys)
        (when (or (and seen (gethash key seen))
                  (let ((row (gethash key table)))
                    (and row (not (and mid-old-set (gethash row mid-old-set))))))
          (signal 'etaf-runtime-error
                  (list "Keyed Range keys must be unique" key)))
        (when seen (puthash key t seen)))
      (when (and live (or mid-old mid-items))
        (setq prev (or (and last-cell (etaf--seg-last-node (car last-cell)))
                       (and (> plen 1)
                            (cl-some #'etaf--seg-last-node
                                     (reverse (take plen old))))
                       (etaf--seg-anchor-prev seg))))
      (condition-case err
          (cl-loop for item in mid-items for key in mid-keys
                   do (let ((row (gethash key table)))
                        (if row
                            (progn (remhash row mid-old-set)
                                   (unless (eq (etaf--seg-src row) item)
                                     (push (cons row item) changed-rows))
                                   (push row mid-rows))
                          (let ((built (etaf--row-build seg key item itemfn)))
                            (push built fresh)
                            (push built mid-rows)))))
        ((error quit)
         (dolist (row fresh) (etaf--dispose row nil))
         (signal (car err) (cdr err))))
      (setq mid-rows (nreverse mid-rows))
      ;; Changed items flow through each reused row's cell.
      (dolist (entry changed-rows)
        (let* ((row (car entry)) (item (cdr entry)) (cell (etaf--seg-data row)))
          (setf (etaf--seg-src row) item)
          (unless (eq (etaf-ref-value cell) item)
            (etaf--cell-install cell item))))
      (dolist (row mid-old)
        (when (gethash row mid-old-set)
          (etaf--jremhash (etaf--seg-key row) table)
          (etaf--dispose row live)))
      (dolist (row fresh) (etaf--jputhash (etaf--seg-key row) row table))
      (unless (and (null mid-old) (null mid-rows))
        (setf (etaf--seg-kids seg)
              (cond
               ((and (null mid-old) (null suffix) (null otail) last-cell)
                ;; Pure append: the retained prefix is the whole old list.
                (let ((cell last-cell))
                  (etaf--journal (lambda () (setcdr cell nil))))
                (setcdr last-cell mid-rows)
                old)
               (t (append (take plen old) mid-rows suffix)))))
      (setf (etaf--seg-data seg) (cons table itemfn))
      (when itemfn-changed
        (dolist (row (etaf--seg-kids seg))
          (unless (memq row fresh)
            (etaf--row-repatch row itemfn))))
      (when (and live mid-rows)
        (etaf--place-rows seg mid-rows prev)))))

(defun etaf--place-rows (seg rows prev)
  "Place live list SEG's ROWS contiguously after node PREV."
  (let ((phys (etaf--seg-phys seg))
        (runtime (etaf--seg-runtime seg)))
    (if (eq (etaf--seg-kind phys) 'root)
        (etaf--root-dirty runtime)
      (let ((parent (etaf--host-kids-parent phys))
            (index (if prev (1+ (ebox-node-index prev)) 0))
            changed)
        (dolist (row rows)
          (dolist (node (etaf--seg-nodes row))
            (let ((at (ebox-node-parent node)))
              (cond
               ((and (eq at parent) (= (ebox-node-index node) index)))
               ((eq at parent)
                (etaf--node-move node (if (< (ebox-node-index node) index)
                                          (1- index) index))
                (setq changed t))
               (t
                (when at (etaf--node-remove node))
                (etaf--node-insert parent node index)
                (setq changed t))))
            (setq index (1+ (ebox-node-index node)))))
        (when (etaf--pres-pin-companion-inside phys parent)
          (setq changed t))
        (when changed (etaf--runtime-changed runtime))))))

;;;; Slots

(defun etaf--slot-init (seg)
  "Bind slot projection SEG."
  (let* ((projection (etaf--seg-src seg))
         (ctx (etaf--seg-ctx seg)))
    (if (etaf--slot-projection-captured-p projection)
        (let* ((content (etaf--slot-projection-content projection))
               (owners (etaf--slot-projection-style-owners projection))
               (owner-ctx
                (cond
                 ((null owners) ctx)
                 ((eq (etaf--ictx-runtime owners) (etaf--ictx-runtime ctx))
                  (etaf--ctx-inner owners))
                 (t
                  ;; Cross-Runtime portal projection: keep the caller's Context
                  ;; and Theme while rebinding Runtime and instance ownership to
                  ;; the target Runtime that mounts the projected Hosts.
                  (etaf--ictx-make
                   :runtime (etaf--ictx-runtime ctx)
                   :owner (etaf--ictx-owner ctx)
                   :root-p nil
                   :context (or (etaf--ictx-context owners)
                                (etaf--ictx-context ctx))
                   :theme (or (etaf--ctx-theme owners)
                              (etaf--ictx-theme ctx)))))))
          (etaf--patch-kids seg (etaf--flatten (etaf--slot-content-children content))
                            owner-ctx))
      (let ((name (etaf--slot-projection-name projection))
            (owner (etaf--ictx-owner ctx)))
        (setf (etaf--seg-effect seg)
              (etaf--effect
               ctx seg
               (lambda ()
                 (let* ((entry (assq name (etaf--current-slot-entries)))
                        (mode (if entry 'entry 'fallback)))
                   (etaf-untracked
                     (unless (eq mode (etaf--seg-data seg))
                       (dolist (kid (etaf--seg-kids seg))
                         (etaf--dispose kid (etaf--seg-live seg)))
                       (setf (etaf--seg-kids seg) nil)
                       (setf (etaf--seg-data seg) mode))
                     (if entry
                         (let ((content (cdr entry)))
                           (etaf--patch-kids
                            seg
                            (etaf--flatten (if (etaf--slot-content-p content)
                                               (etaf--slot-content-children content)
                                             content))
                            (etaf--ctx-inner
                             (if owner (etaf--instance-pctx owner) ctx))))
                       (etaf--patch-kids
                        seg (etaf--flatten (etaf--slot-projection-fallback projection))
                        ctx)))))))))))

;;;; Components

(defun etaf--comp-write-inputs (inst)
  "Resolve INST's business props and write the changed prop cells."
  (let* ((call (etaf--instance-call inst))
         (spec (etaf--instance-spec inst))
         (raw (etaf--resolve-property-plist (etaf--component-business-props call)))
         (resolved (etaf--component-resolve-input
                    spec raw (etaf--instance-defaults inst)))
         (props (car resolved))
         (cells (etaf--instance-cells inst)))
    (setf (etaf--instance-defaults inst) (cdr resolved))
    (cl-loop for name in (etaf--component-spec-props spec) for index from 1
             do (let ((value (plist-get props (etaf--component-prop-key name)))
                      (cell (aref cells index)))
                  (unless (etaf--reactive-same-p (etaf-ref-value cell) value)
                    (etaf--cell-install cell value))))))

(defun etaf--comp-bind-inputs (inst)
  "Bind INST's business props, retaining an effect when they are dynamic."
  (let ((pctx (etaf--instance-pctx inst)))
    (if (cl-loop for (_key value) on (etaf--component-call-props
                                      (etaf--instance-call inst))
                 by #'cddr
                 thereis (etaf--expr-p value))
        (setf (etaf--instance-input-effect inst)
              (etaf--effect pctx (etaf--instance-seg inst)
                            (lambda () (etaf--comp-write-inputs inst))
                            t))
      (etaf--ctx-call pctx (lambda () (etaf--comp-write-inputs inst))))))

(defun etaf--comp-setup (inst)
  "Run INST's setup in its own detached Scope."
  (let* ((spec (etaf--instance-spec inst))
         (runtime (etaf--instance-runtime inst))
         (ctx (etaf--instance-ctx inst))
         (etaf--render-phase-p nil)
         (scope (etaf-effect-scope :detached t
                                   :name (etaf--component-spec-name spec))))
    (setf (etaf--instance-scope inst) scope)
    (let* ((etaf--component-phase 'setup)
           (etaf--current-ictx ctx)
           (etaf--current-component-instance inst)
           (etaf--current-runtime runtime)
           (etaf--current-context (etaf--ictx-context ctx))
           (state (etaf-untracked
                    (etaf-scope-run
                     scope
                     (lambda ()
                       (funcall (etaf--component-spec-setup spec)
                                (etaf--instance-cells inst) nil))))))
      (when (functionp state)
        (signal 'etaf-runtime-error
                (list (format "Component %S :setup returned a function"
                              (etaf--component-spec-name spec)))))
      (setf (etaf--instance-state inst) state
            (etaf--instance-setup-p inst) t))))

(defun etaf--comp-attrs (inst)
  "Return INST's fallthrough Host attrs, evaluated in the caller's context."
  (let ((attrs (etaf--component-call-attrs (etaf--instance-call inst)))
        (pctx (etaf--instance-pctx inst)))
    (if (not (cl-loop for (_key value) on attrs by #'cddr
                      thereis (etaf--expr-p value)))
        attrs
      (cl-loop for (key value) on attrs by #'cddr
               append (list key
                            (if (etaf--expr-p value)
                                (let ((thunk (etaf--expr-thunk value)))
                                  (etaf--expr-create
                                   :thunk (lambda () (etaf--ctx-call pctx thunk))))
                              value))))))

(defun etaf--comp-show (seg view)
  "Show Component SEG's rendered VIEW."
  (let* ((inst (etaf--seg-data seg))
         (name (etaf--component-spec-name (etaf--instance-spec inst))))
    (etaf--validate-component-render-result view name)
    (setf (etaf--instance-view inst) view)
    (etaf--patch-kids
     seg (etaf--flatten (etaf--apply-component-attrs view (etaf--comp-attrs inst) name))
     (etaf--instance-ctx inst))))

(defun etaf--comp-bind-render (seg)
  "Render Component SEG once, or bind its `:render' in an effect."
  (let* ((inst (etaf--seg-data seg))
         (spec (etaf--instance-spec inst))
         (ctx (etaf--instance-ctx inst))
         (render (etaf--component-spec-render spec))
         (cells (etaf--instance-cells inst)))
    (if (etaf--component-spec-view-p spec)
        (etaf--comp-show
         seg (etaf-untracked
               (etaf--ctx-call
                ctx (lambda ()
                      (funcall render cells (etaf--component-call-slots
                                             (etaf--instance-call inst)))))))
      (setf (etaf--seg-effect seg)
            (etaf--effect
             ctx seg
             (lambda ()
               (let ((view (funcall render cells
                                    (etaf--component-call-slots
                                     (etaf--instance-call inst)))))
                 (etaf-untracked (etaf--comp-show seg view)))))))))

(defun etaf--comp-init (seg)
  "Create Component SEG's instance, run its setup and render it."
  (let* ((call (etaf--seg-src seg))
         (spec (etaf--component-call-spec call))
         (pctx (etaf--seg-ctx seg))
         (runtime (etaf--ictx-runtime pctx))
         (id (etaf--next-id runtime))
         (setup (etaf--component-spec-setup spec))
         (names (etaf--component-spec-props spec))
         (inst (etaf--instance-make
                :id id :runtime runtime :spec spec :seg seg :pctx pctx :call call
                :txn etaf--txn
                :cells (vconcat (list names)
                                (mapcar (lambda (_) (etaf--ref-create)) names))
                :slots-ref (and runtime (etaf--ref-create
                                         :value (etaf--component-call-slots call))))))
    (setf (etaf--seg-data seg) inst
          (etaf--instance-ctx inst)
          (etaf--ictx-make
           :runtime runtime :owner inst :root-p t
           :context (if setup
                        (etaf--context-create :parent (etaf--ictx-context pctx)
                                              :owner-id id)
                      (etaf--ictx-context pctx))
           :theme (if setup 'unset (etaf--ictx-theme pctx))))
    (when runtime
      (etaf--jputhash id inst (etaf-runtime-instances runtime))
      (when etaf--txn (push inst (etaf--txn-instances etaf--txn))))
    ;; Inputs are validated first, so invalid props report the same error
    ;; with or without a Runtime.
    (etaf--comp-bind-inputs inst)
    (when (and setup (null runtime))
      (signal 'etaf-renderer-error
              (list "Stateful Component requires `etaf-mount'")))
    (when setup (etaf--comp-setup inst))
    (etaf--comp-bind-render seg)
    (when runtime
      (push inst (etaf-runtime-new-instances runtime))
      (etaf--runtime-touch runtime))))

(defun etaf--comp-patch (seg call)
  "Give live Component SEG the new CALL from its re-rendered parent."
  (let* ((inst (etaf--seg-data seg))
         (old (etaf--instance-call inst))
         (slots (etaf--component-call-slots call))
         (ref (etaf--instance-slots-ref inst)))
    (setf (etaf--seg-src seg) call
          (etaf--instance-call inst) call)
    (unless (and (eq (etaf--component-call-props old) (etaf--component-call-props call))
                 (null (etaf--instance-input-effect inst)))
      (etaf--stop (etaf--instance-input-effect inst))
      (setf (etaf--instance-input-effect inst) nil)
      (etaf--comp-bind-inputs inst))
    (when (and ref (not (eq slots (etaf-ref-value ref))))
      (etaf--cell-install ref slots))
    (unless (etaf--value-same-p (etaf--component-call-attrs old)
                                (etaf--component-call-attrs call))
      (etaf--comp-show seg (etaf--instance-view inst)))))

(defun etaf--comp-dispose (seg detach)
  "Dispose Component SEG, detaching its nodes when DETACH."
  (let ((inst (etaf--seg-data seg)))
    (etaf--stop (etaf--seg-effect seg))
    (when inst (etaf--stop (etaf--instance-input-effect inst)))
    (dolist (kid (etaf--seg-kids seg)) (etaf--dispose kid detach))
    (when inst
      (setf (etaf--instance-dead inst) t)
      (let ((runtime (etaf--instance-runtime inst)))
        (when-let* ((scope (etaf--instance-scope inst)))
          (let ((stop (lambda ()
                        (let ((errors (let ((etaf--render-phase-p nil))
                                        (etaf-scope-stop scope))))
                          (when runtime
                            (setf (etaf-runtime-errors runtime)
                                  (append errors (etaf-runtime-errors runtime))))))))
            (if (and etaf--txn (not (eq (etaf--instance-txn inst) etaf--txn)))
                (etaf--txn-defer stop)
              (funcall stop))))
        (when runtime
          (etaf--jremhash (etaf--instance-id inst) (etaf-runtime-instances runtime))
          (when (etaf--instance-mounted-p inst)
            (push inst (etaf-runtime-retired-instances runtime))
            (etaf--runtime-touch runtime)))))))

;;;; Disposal

(defun etaf--dispose (seg detach)
  "Dispose SEG and its descendants; remove its nodes from Ebox when DETACH."
  (pcase (etaf--seg-kind seg)
    ('host
     (let ((host (etaf--seg-data seg))
           (runtime (etaf--seg-runtime seg))
           (outer (and (etaf--seg-data seg) (etaf--seg-outer-node seg))))
       (etaf--stop (etaf--seg-effect seg))
       (when host
         (etaf--stop (etaf--host-payload host))
         (when-let* ((bucket (etaf--host-presentation host)))
           (setf (etaf--host-presentation host) nil)
           (when (and runtime (etaf-runtime-presentations runtime))
             (etaf--jremhash seg (etaf-runtime-presentations runtime)))
           (dolist (entry (etaf--pb-companions bucket))
             (when-let* ((pseg (etaf--pres-seg entry)))
               (etaf--dispose pseg nil)))
           (when-let* ((ov (etaf--pb-active-override bucket))
                       (pseg (etaf--pres-seg ov)))
             (etaf--dispose pseg nil)))
         (when runtime
           (etaf--host-unregister runtime host)
           (when-let* ((host-ids (etaf-runtime-host-ids runtime)))
             (etaf--jremhash (etaf--host-id host) host-ids))
           (when (etaf--seg-node seg)
             (etaf--jremhash (etaf--seg-node seg) (etaf-runtime-nodes runtime)))
           (let ((states (etaf--host-behaviors host)))
             (setf (etaf--host-behaviors host) nil)
             (etaf--behavior-cleanup runtime states))))
       (dolist (kid (etaf--seg-kids seg)) (etaf--dispose kid nil))
       (when (and detach (or outer (etaf--seg-node seg)) (etaf--seg-live seg))
         (etaf--detach seg (or outer (etaf--seg-node seg))))))
    ('pres
     (etaf--stop (etaf--seg-effect seg))
     (dolist (kid (etaf--seg-kids seg)) (etaf--dispose kid nil)))
    ('comp (etaf--comp-dispose seg detach))
    (_
     (etaf--stop (etaf--seg-effect seg))
     (dolist (kid (etaf--seg-kids seg)) (etaf--dispose kid detach))))
  (setf (etaf--seg-effect seg) nil
        (etaf--seg-live seg) nil))

;;;; Component accessors

(defun etaf--require-setup (operation)
  "Signal unless a mounted Component's setup is running for OPERATION."
  (unless (and (eq etaf--component-phase 'setup)
               (etaf--instance-p etaf--current-component-instance)
               etaf--current-runtime)
    (etaf--component-definition-error "%s requires Component setup" operation))
  etaf--current-component-instance)

;;;###autoload
(defun etaf-prop (name)
  "Return the current Component's read-only reactive input NAME.
Call during setup, then read the result with `etaf-value' inside computed
getters, watchers or View expressions.  NAME is a declared prop symbol or
keyword; defaults are included.  A plain prop variable is a snapshot taken
when setup ran, while this source follows later inputs."
  (let* ((inst (etaf--require-setup "etaf-prop"))
         (key (and (symbolp name) (etaf--component-prop-key name)))
         (names (etaf--component-spec-props (etaf--instance-spec inst)))
         (index (cl-position key (mapcar #'etaf--component-prop-key names))))
    (unless index
      (etaf--component-definition-error
       "Component %S has no declared prop %S"
       (etaf--component-spec-name (etaf--instance-spec inst)) name))
    (or (cdr (assq key (etaf--instance-prop-sources inst)))
        (let* ((cell (aref (etaf--instance-cells inst) (1+ index)))
               (source (etaf-computed (lambda () (etaf-value cell))
                                      :name name)))
          (push (cons key source) (etaf--instance-prop-sources inst))
          source))))

;;;###autoload
(defun etaf-local-ref (name)
  "Return an instance-local Host reference named NAME during Component setup.
NAME is a non-nil symbol or string.  Equal names in one instance return the
same opaque reference; different instances never share it.  Pass it to a
Host's `:ref' and to Host query, focus or event APIs."
  (let ((inst (etaf--require-setup "etaf-local-ref")))
    (unless (and name (or (symbolp name) (stringp name)))
      (etaf--component-definition-error
       "Local reference name must be a non-nil symbol or string: %S" name))
    (or (cdr (assoc name (etaf--instance-local-refs inst)))
        (let ((ref (make-symbol (format "etaf-local-%s" name))))
          (push (cons (if (stringp name) (copy-sequence name) name) ref)
                (etaf--instance-local-refs inst))
          ref))))

(defun etaf--push-hook (callback slot operation)
  "Add CALLBACK to the setup instance's lifecycle SLOT for OPERATION."
  (unless (functionp callback)
    (signal 'wrong-type-argument (list 'functionp callback)))
  (unless (and (eq etaf--component-phase 'setup)
               (etaf--instance-p etaf--current-component-instance))
    (error "%s requires Component setup" operation))
  (let ((inst etaf--current-component-instance))
    (pcase slot
      ('mounted (push callback (etaf--instance-mounted-hooks inst)))
      ('updated (push callback (etaf--instance-updated-hooks inst)))
      ('unmounted (push callback (etaf--instance-unmounted-hooks inst)))))
  callback)

;;;###autoload
(defun etaf-on-mounted (callback)
  "Run CALLBACK after the current Component first appears on screen."
  (etaf--push-hook callback 'mounted "etaf-on-mounted"))

;;;###autoload
(defun etaf-on-updated (callback)
  "Run CALLBACK after a commit in which the current Component re-rendered."
  (etaf--push-hook callback 'updated "etaf-on-updated"))

;;;###autoload
(defun etaf-on-unmounted (callback)
  "Run CALLBACK after the current Component leaves the screen."
  (etaf--push-hook callback 'unmounted "etaf-on-unmounted"))

;;;; Root

(defun etaf--root-init (seg)
  "Bind root SEG, whose source is a View or a zero-argument function."
  (let ((ctx (etaf--seg-ctx seg))
        (src (etaf--seg-src seg)))
    (setf (etaf--seg-effect seg)
          (etaf--effect ctx seg
                        (lambda ()
                          (let ((value (if (functionp src) (funcall src) src)))
                            (etaf-untracked
                              (etaf--patch-kids seg (etaf--flatten value) ctx))))))))

(defun etaf--root-ctx (runtime)
  "Return a root evaluation context for RUNTIME, which may be nil."
  (etaf--ictx-make :runtime runtime :root-p nil
                   :context (etaf--context-create :owner-id 0)))

(defun etaf--root-sync (runtime)
  "Mount RUNTIME's top-level nodes when they changed."
  (when (etaf-runtime-root-dirty runtime)
    (setf (etaf-runtime-root-dirty runtime) nil)
    (let* ((nodes (etaf--kids-nodes (etaf-runtime-root runtime)))
           (overlays (etaf-runtime-overlay-entries runtime))
           (has-floating (or (etaf-runtime-surface runtime) overlays))
           (desired
            (if (and nodes (null (cdr nodes))
                     (not has-floating))
                (car nodes)
              (let ((wrapper (or (etaf-runtime-wrapper runtime)
                                 (setf (etaf-runtime-wrapper runtime)
                                       (ebox-node-create 'column nil)))))
                ;; A modal or named overlay needs a viewport canvas even when
                ;; the application is a single text Host or an intrinsically
                ;; short column.  Keep its original nodes and geometry; only
                ;; this outer canvas grows.  Node-owned scroll offsets survive
                ;; mounting.
                (ebox-node-set-props
                 wrapper
                 (when has-floating
                   (list :width 'stretch
                         :height (if (cdr (etaf-runtime-viewport runtime))
                                     '(vh 100)
                                   '(lh 32)))))
                ;; Include retained surface and overlay nodes in the
                ;; replacement itself.  Detaching and reattaching them would
                ;; discard Ebox's mounted projection while the outer canvas
                ;; identity stays unchanged.
                (ebox-node-replace-children
                 wrapper (append nodes
                                 (when-let* ((surface (etaf-runtime-surface runtime)))
                                   (etaf--kids-nodes surface))
                                 (cl-loop for (_k . oseg) in overlays
                                          append (etaf--kids-nodes oseg))))
                wrapper)))
           (buffer (etaf-runtime-buffer runtime)))
      ;; Managed transient and overlay content share the mounted tree, not
      ;; another buffer or Ebox mount.  Move them with a replaced root.
      (when-let* ((surface (etaf-runtime-surface runtime)))
        (setf (etaf--seg-node surface) desired))
      (dolist (entry overlays)
        (setf (etaf--seg-node (cdr entry)) desired))
      (unless (eq desired (etaf-runtime-mounted-root runtime))
        (when (and (ebox-node-parent desired)
                   (eq (ebox-node-parent desired) (etaf-runtime-wrapper runtime)))
          (ebox-node-remove desired))
        (when (buffer-live-p buffer)
          (let ((viewport (etaf-runtime-fixed-viewport runtime)))
            ;; Root replacement preserves this Runtime's observation lifetime,
            ;; including the new engine mount's first flush.
            (ebox-mount buffer desired :width (car viewport) :height (cdr viewport)
                        :observer (and (etaf-runtime-observer runtime)
                                       #'etaf--runtime-forward-ebox-report))))
        (setf (etaf-runtime-mounted-root runtime) desired
              (etaf-runtime-changed runtime) t)))))

;;;; Commit and lifecycle

(defun etaf--run-hooks (runtime hooks)
  "Run lifecycle HOOKS in RUNTIME, collecting failures in the drain."
  (dolist (hook (reverse hooks))
    (condition-case err
        (let ((etaf--current-runtime runtime)
              (etaf--render-phase-p nil))
          (funcall hook))
      ((error quit) (push err etaf--drain-errors)))))

(defun etaf--runtime-commit (runtime)
  "Bring RUNTIME's buffer up to date and run its lifecycle hooks."
  (etaf--root-sync runtime)
  (let ((did-commit nil)
        (app-changed (etaf-runtime-app-changed runtime)))
    (setf (etaf-runtime-app-changed runtime) nil)
    (when (etaf-runtime-changed runtime)
      (setf (etaf-runtime-changed runtime) nil)
      (ebox-flush)
      (cl-incf (etaf-runtime-rev runtime))
      (etaf--sticky-refresh runtime)
      (setq did-commit t))
    (let ((mounted (etaf-runtime-new-instances runtime))
          (updated (etaf-runtime-updated-instances runtime))
          (retired (etaf-runtime-retired-instances runtime)))
      (when (and (not did-commit) (or mounted updated))
        (ebox-flush))
      (setf (etaf-runtime-last-new-count runtime) (length mounted)
            (etaf-runtime-last-updated-count runtime) (length updated)
            (etaf-runtime-last-retired-count runtime) (length retired))
      (setf (etaf-runtime-new-instances runtime) nil
            (etaf-runtime-updated-instances runtime) nil
            (etaf-runtime-retired-instances runtime) nil)
      (dolist (inst updated)
        (setf (etaf--instance-updated-p inst) nil)
        (cl-incf (etaf--instance-render-count inst)))
      (dolist (inst (reverse mounted))
        (unless (etaf--instance-dead inst)
          (setf (etaf--instance-mounted-p inst) t)
          (etaf--run-hooks runtime (etaf--instance-mounted-hooks inst))))
      (dolist (inst (reverse updated))
        (unless (or (etaf--instance-dead inst) (memq inst mounted))
          (etaf--run-hooks runtime (etaf--instance-updated-hooks inst))))
      (dolist (inst (reverse retired))
        (etaf--run-hooks runtime (etaf--instance-unmounted-hooks inst))))
    (when (and did-commit app-changed (> (etaf-runtime-rev runtime) 1)
               (etaf-runtime-mounted-p runtime))
      (etaf--run-runtime-hooks 'etaf-runtime-after-commit-functions runtime))))

(defvar etaf--in-viewport-prepare nil
  "Non-nil while draining viewport-prepare updates before `ebox-refit' settles.")

(defun etaf--drain-commit ()
  "Commit every dirty Runtime; return non-nil when one was committed.
When a pre or render effect failed, first roll back the transaction so
only work committed before it remains."
  (let ((txn etaf--txn))
    (prog1
        (if (and txn (null etaf--dirty-runtimes) (not etaf--drain-failed)
                 (etaf--txn-pristine-p txn))
            ;; Nothing ran since the last commit; keep its transaction.
            nil
          (etaf--drain-commit-1 txn))
      ;; Flush any viewport refit queued by `ebox-refit' before post-flush
      ;; effects and `etaf-next-tick' callbacks inspect layout geometry.
      (when etaf--in-viewport-prepare
        (ebox-flush)))))

(defun etaf--txn-pristine-p (txn)
  "Return non-nil when TXN recorded nothing since it began."
  (not (or (car (etaf--txn-ran txn)) (etaf--txn-undo txn) (etaf--txn-cells txn)
           (etaf--txn-created txn) (etaf--txn-stopped txn) (etaf--txn-installs txn)
           (etaf--txn-instances txn) (etaf--txn-deferred txn))))

(defun etaf--drain-commit-1 (txn)
  "Finish TXN, commit every dirty Runtime and begin the next transaction."
  (setq etaf--txn nil etaf--run-log nil)
  (when txn
    (if etaf--drain-failed
        (progn (setq etaf--drain-failed nil)
               (etaf--txn-rollback txn))
      (etaf--txn-commit txn)))
  (prog1
      (when etaf--dirty-runtimes
        (let ((runtimes (nreverse etaf--dirty-runtimes)))
          (setq etaf--dirty-runtimes nil)
          (dolist (runtime runtimes)
            (setf (etaf-runtime-dirty runtime) nil)
            (when (etaf-runtime-mounted-p runtime)
              (etaf--runtime-commit runtime)))
          t))
    (setq etaf--txn (etaf--txn-begin)
          etaf--run-log (etaf--txn-ran etaf--txn))))

(defun etaf--drain-around (loop)
  "Run the drain LOOP in one Ebox batch and one transaction per commit."
  (when (and etaf--parked-effects
             (or etaf--retry-parked (aref etaf--queues 0) (aref etaf--queues 1)))
    (etaf--requeue-parked))
  (let* ((etaf--txn (etaf--txn-begin))
         (etaf--run-log (etaf--txn-ran etaf--txn))
         (etaf--retry-parked nil))
    (ebox-call-with-batch loop)))

(setq etaf--drain-commit-function #'etaf--drain-commit
      etaf--drain-around-function #'etaf--drain-around)

;;;; Mounting

(defun etaf--validate-mount-options (options)
  "Return valid mount OPTIONS."
  (unless (proper-list-p options)
    (signal 'etaf-runtime-error (list "Mount options must be a plist" options)))
  (cl-loop for (key value) on options by #'cddr
           do (pcase key
                (:viewport-width
                 (unless (or (null value) (and (numberp value) (> value 0)))
                   (signal 'etaf-runtime-error (list "Invalid :viewport-width" value))))
                (:viewport-height
                 (unless (or (null value) (and (numberp value) (> value 0)))
                   (signal 'etaf-runtime-error (list "Invalid :viewport-height" value))))
                (:observer
                 (unless (or (null value) (functionp value))
                   (signal 'etaf-runtime-error (list "Invalid :observer" value))))
                (:text-selection
                 (unless (memq value '(nil t))
                   (signal 'etaf-runtime-error (list "Invalid :text-selection" value))))
                (:meta
                 (unless (or (null value)
                             (and (proper-list-p value) (zerop (% (length value) 2))))
                   (signal 'etaf-runtime-error (list "Invalid :meta" value))))
                (_ (signal 'etaf-runtime-error (list "Unknown mount option" key)))))
  options)

(defun etaf--runtime-forward-ebox-report (_buffer report)
  "Forward Ebox flush REPORT into the active observed operation."
  (etaf-observer-emit (append (list :provider 'ebox :stage 'flush)
                             (cl-loop for (key value) on report by #'cddr
                                      unless (memq key '(:provider :stage))
                                      append (list key value)))))

(defun etaf--runtime-buffer-killed ()
  "Unmount the Runtime of the buffer being killed."
  (when-let* ((runtime (gethash (current-buffer) etaf--runtimes)))
    (ignore-errors (etaf--runtime-unmount-now runtime))))

;;;###autoload
(defun etaf-runtime-mount (buffer-or-name view &optional options)
  "Mount VIEW into BUFFER-OR-NAME and return the live buffer.
VIEW is a View or a zero-argument function returning one.  OPTIONS may
provide `:viewport-width' in pixels, `:viewport-height' in lines, `:observer'
(a one-argument report sink installed before the first render), and
`:text-selection' (t to enable native Emacs mark and pointer text selection)."
  (etaf--assert-not-rendering 'mount-runtime)
  (setq options (etaf--validate-mount-options options))
  (let* ((etaf--txn nil)
         (etaf--run-log nil)
         (buffer (get-buffer-create buffer-or-name))
         (old (gethash buffer etaf--runtimes)))
    (when old (etaf--runtime-unmount-now old))
    (let* ((runtime (etaf--runtime-make
                     :buffer buffer :mounted-p t
                     :mount-id (cl-incf etaf--mount-counter)
                     :fixed-viewport (cons (plist-get options :viewport-width)
                                     (plist-get options :viewport-height))
                     :observer (plist-get options :observer)
                     :view view))
           (root (etaf--seg-make :kind 'root :src view
                                 :ctx (etaf--root-ctx runtime))))
      (setf (etaf-runtime-root runtime) root)
      (puthash buffer runtime etaf--runtimes)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook #'etaf--runtime-buffer-killed nil t)
        ;; Capture the buffer's native cursor so optional input-modality hiding
        ;; (`etaf-cursor-follows-input-modality', nil by default) and unmount
        ;; always restore the caller's exact cursor state.
        (unless etaf--mount-cursor
          (setq etaf--mount-cursor
                (cons (local-variable-p 'cursor-type) cursor-type)))
        (when (plist-member options :text-selection)
          (unless etaf--mount-text-selection
            (setq etaf--mount-text-selection
                  (cons (local-variable-p 'ebox-allow-text-selection)
                        ebox-allow-text-selection)))
          (setq-local ebox-allow-text-selection
                      (and (plist-get options :text-selection) t)))
        (add-hook 'pre-command-hook #'etaf--cursor-input-modality nil t)
        ;; The canvas is a rendering, not a document: text typed into it would
        ;; be overwritten by the next paint and could never reach the source.
        ;; Ebox writes through `inhibit-read-only', so painting still works.
        (setq buffer-read-only t))
      (etaf--keys-install runtime)
      (condition-case err
          (etaf--runtime-run-operation
           runtime 'mount "mount"
           (lambda ()
             (etaf-call-with-batch
              (lambda ()
                ;; Initialise in the buffer the View is mounted into: a
                ;; component's `:setup' runs here, and it asks this buffer what
                ;; window it is drawn in.  Running it in whatever buffer the
                ;; caller happened to have current gave every mount the wrong
                ;; answer — a player embedded in a panel recorded `*scratch*'.
                (with-current-buffer buffer
                  (etaf--root-init root)
                  (setf (etaf--seg-live root) t)
                  (etaf--root-dirty runtime))))))
        ((error quit)
         (etaf--runtime-unmount-now runtime)
         (signal (car err) (cdr err))))
      (when (etaf-runtime-observer runtime)
        (ebox-buffer-set-observer buffer #'etaf--runtime-forward-ebox-report))
      (when (plist-member options :meta)
        (etaf--runtime-install-meta runtime (plist-get options :meta) t))
      (etaf--run-runtime-hooks 'etaf-runtime-mount-functions runtime)
      buffer)))

;;;###autoload
(defun etaf-mount (buffer-or-name view &optional options)
  "Mount VIEW into BUFFER-OR-NAME with OPTIONS and return its buffer.
See `etaf-runtime-mount'."
  (etaf-runtime-mount buffer-or-name view options))

(defun etaf--runtime-set-surface (runtime view origin)
  "Present transient VIEW in RUNTIME, inheriting ORIGIN's Context.
Nil VIEW disposes the surface.  The retained application nodes share a
viewport canvas with its absolute root-layer Hosts.  Application Components
are not remounted and their state, subscriptions and node scroll offsets
are retained."
  (etaf--assert-not-rendering 'present-surface)
  (etaf-call-with-batch
   (lambda ()
     (if (null view)
         (when-let* ((surface (etaf-runtime-surface runtime)))
           (setf (etaf-runtime-surface runtime) nil)
           (etaf--dispose surface t)
           (etaf--runtime-changed runtime))
       (when (etaf-runtime-surface runtime)
         (signal 'etaf-runtime-error (list "A transient surface is already open")))
       (let* ((source (or (etaf--runtime-host-seg runtime origin)
                          (etaf-runtime-root runtime)))
              (ctx (etaf--ictx-make
                    :runtime runtime
                    :context (etaf--ictx-context (etaf--seg-ctx source))))
              (surface (etaf--seg-make
                        :kind 'surface :src view :ctx ctx
                        :node (etaf-runtime-mounted-root runtime))))
         (condition-case err
             (progn
               (etaf--root-init surface)
               (setf (etaf--seg-live surface) t
                     (etaf-runtime-surface runtime) surface)
               (etaf--root-dirty runtime))
           ((error quit)
            (etaf--dispose surface nil)
            (signal (car err) (cdr err)))))))))

(defun etaf--runtime-unmount-now (runtime)
  "Dispose RUNTIME's segments and release its buffer, idempotently."
  (when (etaf-runtime-mounted-p runtime)
    (etaf--run-runtime-hooks 'etaf-runtime-unmount-functions runtime)
    (setf (etaf-runtime-mounted-p runtime) nil)
    (let ((buffer (etaf-runtime-buffer runtime))
          (root (etaf-runtime-root runtime))
          (etaf--render-phase-p nil)
          (etaf--txn nil)
          (etaf--run-log nil))
      (when (eq (gethash buffer etaf--runtimes) runtime)
        (remhash buffer etaf--runtimes))
      (when-let* ((surface (etaf-runtime-surface runtime)))
        (setf (etaf-runtime-surface runtime) nil)
        (etaf--dispose surface nil))
      (when-let* ((overlays (etaf-runtime-overlay-entries runtime)))
        (setf (etaf-runtime-overlay-entries runtime) nil)
        (dolist (entry overlays)
          (etaf--dispose (cdr entry) nil)))
      (when-let* ((mscope (etaf-runtime-meta-scope runtime)))
        (setf (etaf-runtime-meta-scope runtime) nil)
        (etaf-scope-stop mscope))
      (setf (etaf-runtime-meta-spec runtime) nil
            (etaf-runtime-meta-snapshot runtime) nil
            (etaf-runtime-key-layers runtime) nil)
      (when root (etaf--dispose root nil))
      (setq etaf--dirty-runtimes (delq runtime etaf--dirty-runtimes))
      (setf (etaf-runtime-dirty runtime) nil)
      (dolist (inst (etaf-runtime-retired-instances runtime))
        (dolist (hook (reverse (etaf--instance-unmounted-hooks inst)))
          (condition-case err
              (let ((etaf--current-runtime runtime)) (funcall hook))
            ((error quit) (push err (etaf-runtime-errors runtime))))))
      (setf (etaf-runtime-retired-instances runtime) nil
            (etaf-runtime-new-instances runtime) nil
            (etaf-runtime-updated-instances runtime) nil)
      (clrhash (etaf-runtime-hosts runtime))
      (clrhash (etaf-runtime-nodes runtime))
      (when (etaf-runtime-host-ids runtime)
        (clrhash (etaf-runtime-host-ids runtime)))
      (when (etaf-runtime-presentations runtime)
        (clrhash (etaf-runtime-presentations runtime)))
      (setf (etaf-runtime-sticky runtime) nil)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (etaf--sticky-clear)
          (remove-hook 'kill-buffer-hook #'etaf--runtime-buffer-killed t)
          (remove-hook 'pre-command-hook #'etaf--cursor-input-modality t)
          (setq etaf--cursor-hidden nil)
          (when etaf--mount-cursor
            (if (car etaf--mount-cursor)
                (setq-local cursor-type (cdr etaf--mount-cursor))
              (kill-local-variable 'cursor-type))
            (setq etaf--mount-cursor nil))
          (when etaf--mount-text-selection
            (if (car etaf--mount-text-selection)
                (setq-local ebox-allow-text-selection (cdr etaf--mount-text-selection))
              (kill-local-variable 'ebox-allow-text-selection))
            (setq etaf--mount-text-selection nil))
          (etaf--keys-uninstall runtime)
          (when (etaf-runtime-observer runtime)
            (ebox-buffer-set-observer buffer nil))
          (ebox-unmount-buffer buffer)))))
  runtime)

;;;###autoload
(defun etaf-runtime-unmount (&optional runtime)
  "Unmount RUNTIME, defaulting to the active or current-buffer Runtime."
  (etaf--assert-not-rendering 'unmount-runtime)
  (etaf--runtime-unmount-now (etaf-runtime-require-mounted runtime)))

;;;###autoload
(defun etaf-unmount (&optional runtime)
  "Unmount RUNTIME, defaulting to the active or current-buffer Runtime."
  (etaf-runtime-unmount runtime))

;;;###autoload
(defun etaf-render (view)
  "Render VIEW without a Runtime and return a detached Ebox root node.
Stateless Components are supported; stateful Components need `etaf-mount'."
  (let* ((root (etaf--seg-make :kind 'root :src view :ctx (etaf--root-ctx nil)))
         (etaf--render-phase-p t))
    (etaf--root-init root)
    (let ((nodes (etaf--kids-nodes root)))
      (if (and nodes (null (cdr nodes)))
          (car nodes)
        (ebox-node-create 'column nil nodes)))))

;;;; Runtime lookup

;;;###autoload
(defun etaf-runtime-for-buffer (buffer-or-name)
  "Return the live Runtime mounted in BUFFER-OR-NAME, or nil."
  (let* ((buffer (and buffer-or-name (get-buffer buffer-or-name)))
         (runtime (and buffer (gethash buffer etaf--runtimes))))
    (and runtime (etaf-runtime-mounted-p runtime) runtime)))

;;;###autoload
(defun etaf-runtime-require-mounted (&optional runtime)
  "Return mounted RUNTIME, the active Runtime or the current buffer's Runtime.
Signal `etaf-runtime-error' when none is mounted."
  (let ((runtime (or runtime etaf--current-runtime
                     (etaf-runtime-for-buffer (current-buffer)))))
    (unless (and (etaf-runtime-p runtime) (etaf-runtime-mounted-p runtime))
      (signal 'etaf-runtime-error (list "ETAF runtime is not mounted")))
    runtime))

;;;###autoload
(defun etaf-runtime-flush (&optional runtime)
  "Settle mounted RUNTIME's pending work and return its revision."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (unless (or etaf--draining (> etaf--batch-depth 0) etaf--render-phase-p)
      (let ((etaf--retry-parked t))
        (etaf--drain)))
    (etaf-runtime-rev runtime)))

;;;###autoload
(defun etaf-runtime-update-report (&optional runtime)
  "Return the last buffer update report of mounted RUNTIME, or nil.
The plist is the engine's flush report for the last commit: its strategy,
the edited range count, the line count, the ranges and the flush counter.
RUNTIME defaults to the Runtime of the current buffer; a non-mounted
Runtime signals `etaf-runtime-error'."
  (let* ((runtime (etaf-runtime-require-mounted runtime)))
    (ebox-buffer-update-report (etaf-runtime-buffer runtime))))

;;;; Sticky Host
;;
;; A `:sticky top' Host mirrors its first row into a displaying window's header
;; line once the window scrolls completely past the Host's rows, without ever
;; calling `set-window-start'.  Because the mirror shows only once
;; `window-start' reaches the line after the Host, the original row and the
;; mirror never appear simultaneously.  Header clicks run the mirrored cell's
;; primary binding at its buffer position.

(defvar-local etaf--sticky-span nil
  "(START . NEXT) of the sticky Host's lines, or nil.")

(defvar-local etaf--sticky-string nil
  "Header line string mirroring the sticky Host's first row.")
(put 'etaf--sticky-string 'risky-local-variable t)

(defvar-local etaf--sticky-remap nil
  "Face remapping cookie of the sticky header line, or nil.")

(defconst etaf--sticky-header-format
  '(:eval (and etaf--sticky-span
               (>= (window-start) (cdr etaf--sticky-span))
               'etaf--sticky-string))
  "Zero-allocation header line construct showing the sticky mirror once off-screen.")

(defun etaf--sticky-span-of (runtime)
  "Return (START . NEXT) of RUNTIME's sticky Host lines, or nil."
  (when-let* ((ref (etaf-runtime-sticky runtime))
              (seg (gethash ref (etaf-runtime-hosts runtime)))
              ((plist-get (etaf--host-props (etaf--seg-data seg)) :sticky))
              (node (etaf--seg-node seg))
              (bounds (ebox-node-bounds node t)))
    (save-excursion
      (goto-char (car bounds))
      (let ((start (line-beginning-position)))
        (goto-char (cdr bounds))
        (forward-line 1)
        (cons start (point))))))

(defun etaf--sticky-click (buffer position map)
  "Return a header keymap running MAP's primary binding at POSITION in BUFFER."
  (let ((header (make-sparse-keymap)))
    (define-key header [header-line down-mouse-1] #'ignore)
    (define-key header [header-line mouse-1]
                (lambda ()
                  (interactive)
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (when-let* ((command (lookup-key map [mouse-1]))
                                  ((commandp command)))
                        (save-excursion
                          (goto-char position)
                          (funcall command)))))))
    header))

(defun etaf--sticky-header (span)
  "Return the header string mirroring the first row of SPAN."
  (let* ((start (car span))
         (end (save-excursion (goto-char start) (line-end-position)))
         (text (buffer-substring start end))
         (position 0))
    (while (< position (length text))
      (let ((next (next-single-property-change position 'keymap text (length text)))
            (map (get-text-property position 'keymap text)))
        (when (and (keymapp map) (lookup-key map [mouse-1]))
          (put-text-property position next 'keymap
                             (etaf--sticky-click (current-buffer)
                                                 (+ start position) map)
                             text))
        (setq position next)))
    text))

(defun etaf--sticky-window-update (window &optional start)
  "Show or hide WINDOW's sticky header line without moving `window-start'."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (let* ((span etaf--sticky-span)
             (pos (or start (window-start window)))
             (shown (and span (>= pos (cdr span))))
             (hidden (eq (window-parameter window 'header-line-format) 'none)))
        (unless (eq (not shown) hidden)
          (set-window-parameter window 'header-line-format (unless shown 'none))
          (force-mode-line-update))))))

(defun etaf--sticky-scroll (window start)
  "Update WINDOW's sticky header visibility after scrolling to START."
  (etaf--sticky-window-update window start))

(defun etaf--sticky-windows ()
  "Update every window showing the current buffer."
  (dolist (window (get-buffer-window-list nil nil t))
    (etaf--sticky-window-update window)))

(defun etaf--sticky-clear ()
  "Remove sticky header state, face remap and hooks from the current buffer."
  (when (or etaf--sticky-remap etaf--sticky-span etaf--sticky-string
            (and (local-variable-p 'header-line-format)
                 (eq header-line-format etaf--sticky-header-format)))
    (when etaf--sticky-remap
      (face-remap-remove-relative etaf--sticky-remap)
      (setq etaf--sticky-remap nil))
    (when (local-variable-p 'header-line-format)
      (kill-local-variable 'header-line-format))
    (remove-hook 'window-scroll-functions #'etaf--sticky-scroll t)
    (remove-hook 'window-configuration-change-hook #'etaf--sticky-windows t)
    (setq etaf--sticky-span nil
          etaf--sticky-string nil)
    (dolist (window (get-buffer-window-list nil nil t))
      (when (eq (window-parameter window 'header-line-format) 'none)
        (set-window-parameter window 'header-line-format nil)))))

(defun etaf--sticky-refresh (runtime)
  "Mirror RUNTIME's sticky Host into its buffer's header line."
  (let ((buffer (etaf-runtime-buffer runtime)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((span (etaf--sticky-span-of runtime)))
          (cond
           (span
            (unless etaf--sticky-remap
              (setq etaf--sticky-remap
                    (face-remap-add-relative
                     'header-line '(:inherit default :box nil :underline nil
                                    :overline nil :inverse-video nil)))
              (setq-local header-line-format etaf--sticky-header-format)
              (add-hook 'window-scroll-functions #'etaf--sticky-scroll nil t)
              (add-hook 'window-configuration-change-hook
                        #'etaf--sticky-windows nil t))
            (setq etaf--sticky-span span
                  etaf--sticky-string (etaf--sticky-header span))
            (etaf--sticky-windows))
           (t
            (setf (etaf-runtime-sticky runtime) nil)
            (etaf--sticky-clear))))))))

;;;; Observation and operations

;;;###autoload
(defun etaf-runtime-set-observer (runtime observer)
  "Set mounted RUNTIME's report OBSERVER, a function or nil; return it."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (or (null observer) (functionp observer))
    (signal 'wrong-type-argument (list 'functionp observer)))
  (unless (eq observer (etaf-runtime-observer runtime))
    (when (and etaf--observer-context
               (eql (etaf-runtime-mount-id runtime)
                    (etaf--observer-context-runtime-id etaf--observer-context)))
      (error "ETAF observer cannot change during an active operation"))
    (ebox-buffer-set-observer (etaf-runtime-buffer runtime)
                              (and observer #'etaf--runtime-forward-ebox-report))
    (setf (etaf-runtime-observer runtime) observer))
  observer)

;;;###autoload
(defun etaf-runtime-compare-and-set-observer (runtime expected replacement)
  "Replace RUNTIME's observer EXPECTED with REPLACEMENT; return non-nil on success."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (dolist (observer (list expected replacement))
    (unless (or (null observer) (functionp observer))
      (signal 'wrong-type-argument (list 'functionp observer))))
  (when (eq expected (etaf-runtime-observer runtime))
    (etaf-runtime-set-observer runtime replacement)
    t))

(defun etaf--runtime-run-operation (runtime kind label function)
  "Call FUNCTION as RUNTIME operation KIND and LABEL, reporting when observed."
  (let ((observer (etaf-runtime-observer runtime))
        (current etaf--observer-context))
    (if (or (null observer)
            (and current (eql (etaf-runtime-mount-id runtime)
                              (etaf--observer-context-runtime-id current))))
        (funcall function)
      (let* ((operation-id (cl-incf (etaf-runtime-next-operation-id runtime)))
             (revision (etaf-runtime-rev runtime))
             (started (float-time))
             (gc-count gcs-done)
             (gc-time gc-elapsed)
             (status 'error)
             (context (etaf--observer-context-create
                       :sink observer :operation-id operation-id
                       :runtime-id (etaf-runtime-mount-id runtime)
                       :buffer-name (buffer-name (etaf-runtime-buffer runtime))
                       :diagnostic (lambda (diagnostic)
                                     (push diagnostic (etaf-runtime-errors runtime))))))
        (unwind-protect
            (etaf--observer-call-with-context
             context
             (lambda ()
               (condition-case err
                   (prog1 (funcall function) (setq status 'success))
                 (quit (setq status 'quit) (signal (car err) (cdr err))))))
          (etaf--observer-call-with-context
           context
           (lambda ()
             (etaf-observer-emit
              (list :provider 'etaf :stage 'runtime-operation
                    :kind kind :label (copy-sequence label) :status status
                    :revision-before revision
                    :revision-after (etaf-runtime-rev runtime)
                    :duration-ms (max 0.0 (* 1000.0 (- (float-time) started)))
                    :gc-count (- gcs-done gc-count)
                    :gc-duration-ms (max 0.0 (* 1000.0 (- gc-elapsed gc-time))))))))))))

;;;###autoload
(defun etaf-runtime-call-operation (runtime kind label function)
  "Call FUNCTION as one observed RUNTIME operation KIND with string LABEL.
Nested calls for one Runtime join the active operation.  Return FUNCTION's
result and re-signal its error."
  (unless (and (etaf-runtime-p runtime) (etaf-runtime-mounted-p runtime))
    (signal 'etaf-runtime-error (list "ETAF runtime is not mounted")))
  (unless (and (symbolp kind) kind)
    (signal 'wrong-type-argument (list 'symbolp kind)))
  (unless (stringp label)
    (signal 'wrong-type-argument (list 'stringp label)))
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (etaf--runtime-run-operation runtime kind label function))

;;;###autoload
(defun etaf-runtime-event-begin (runtime)
  "Enter one logical event batch for mounted RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (cl-incf (etaf-runtime-event-depth runtime))
  runtime)

;;;###autoload
(defun etaf-runtime-event-end (runtime)
  "Leave RUNTIME's logical event batch."
  (when (etaf-runtime-p runtime)
    (setf (etaf-runtime-event-depth runtime)
          (max 0 (1- (etaf-runtime-event-depth runtime)))))
  runtime)

;;;###autoload
(defun etaf-runtime-set-input-finisher (runtime finisher)
  "Set mounted RUNTIME's native input session FINISHER, a function or nil.
FINISHER receives RUNTIME and runs before a press on another Host."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (or (null finisher) (functionp finisher))
    (signal 'wrong-type-argument (list 'functionp finisher)))
  (setf (etaf-runtime-input-finisher runtime) finisher))

;;;; Viewport

;;;###autoload
(defun etaf-runtime-viewport (&optional runtime)
  "Return mounted RUNTIME's viewport as (WIDTH . HEIGHT) in pixels and lines.
A reactive reader, such as a render or computed, depends on the viewport and
reruns after it changes."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (buffer (etaf-runtime-buffer runtime))
         ;; The first render runs before its tree is mounted, so it reads
         ;; the viewport the mount is about to take.
         (viewport (or (ebox-mount-viewport buffer)
                       (let ((fixed (etaf-runtime-fixed-viewport runtime)))
                         (ebox-viewport-measure buffer (car fixed) (cdr fixed)))))
         (cell (or (etaf-runtime-viewport-ref runtime)
                   (setf (etaf-runtime-viewport-ref runtime)
                         (etaf--ref-create :value viewport :test #'equal
                                           :name "viewport")))))
    (etaf-value cell)
    viewport))

;;;###autoload
(defun etaf-runtime-window-viewport (&optional runtime)
  "Return RUNTIME's display-window viewport as (WIDTH . HEIGHT).
WIDTH is the width the window offers to a mounted tree: pixels on a
graphical frame, character cells on a text terminal.  HEIGHT is its body
height in lines.  RUNTIME defaults to the Runtime in the current buffer.
Nil when no window displays RUNTIME's buffer; read
`etaf-runtime-viewport' for the canvas size instead.  A non-mounted
Runtime signals `etaf-runtime-error'."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (window (get-buffer-window (etaf-runtime-buffer runtime) t)))
    (when (window-live-p window)
      (cons (ebox-viewport-window-width window)
            (window-body-height window)))))

(defun etaf--runtime-viewport-changed (buffer)
  "Publish BUFFER's new viewport to readers of its Runtime's viewport."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer))
              (cell (etaf-runtime-viewport-ref runtime)))
    (let ((etaf--in-viewport-prepare t))
      (etaf-set-value cell (ebox-mount-viewport buffer)))))

(add-hook 'ebox-viewport-prepare-functions #'etaf--runtime-viewport-changed)

;;;###autoload
(defun etaf-image-kitty-available-p (&optional frame)
  "Return a capability plist when FRAME supports Kitty terminal graphics.
FRAME defaults to the selected frame.  Return nil in batch sessions, on
graphical frames, or when FRAME's terminal does not support Kitty Unicode
placeholder graphics.  When non-nil, the plist contains `:cell-width',
`:cell-height' (pixel dimensions of one terminal cell) and `:local'."
  (ebox-image-kitty-available-p frame))

(defun etaf-display-metrics (&optional runtime)
  "Return RUNTIME's effective default-face metrics as a fresh plist.
The keys :char-width and :line-height are positive pixel sizes and :ascent
is an image ascent percentage.  RUNTIME defaults to the current Component
or buffer Runtime; an unmounted Runtime signals `etaf-runtime-error'.
A reactive read reruns after settled buffer text scaling, even with a fixed
viewport.  Image producers can repartition rows without remounting state."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (metrics (ebox-display-metrics (etaf-runtime-buffer runtime)))
         (cell (or (etaf-runtime-display-ref runtime)
                   (setf (etaf-runtime-display-ref runtime)
                         (etaf--ref-create :value metrics :test #'equal
                                           :name "display-metrics")))))
    (etaf-value cell)
    (copy-sequence metrics)))

(defun etaf--runtime-display-changed (buffer)
  "Publish BUFFER's settled display metrics and viewport in one batch."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
    (etaf-batch
      (when-let* ((cell (etaf-runtime-display-ref runtime)))
        (etaf-set-value cell (ebox-display-metrics buffer)))
      (etaf--runtime-viewport-changed buffer))))

(add-hook 'ebox-display-change-functions #'etaf--runtime-display-changed)

;;;###autoload
(defun etaf-runtime-refit (runtime viewport-width &optional viewport-height)
  "Fix RUNTIME's viewport to VIEWPORT-WIDTH pixels and VIEWPORT-HEIGHT lines.
A nil dimension follows the displaying window.  Return non-nil when the
layout changed.  A native input session does not delay the refit; it applies
immediately like any other refit."
  (let ((runtime (etaf-runtime-require-mounted runtime)))
    (when (and viewport-width
               (not (and (numberp viewport-width) (> viewport-width 0))))
      (signal 'wrong-type-argument (list 'numberp viewport-width)))
    (when (and viewport-height
               (not (and (numberp viewport-height) (> viewport-height 0))))
      (signal 'wrong-type-argument (list 'numberp viewport-height)))
    (etaf--assert-not-rendering 'runtime-refit)
    (setf (etaf-runtime-fixed-viewport runtime) (cons viewport-width viewport-height))
    (etaf--runtime-relayout runtime viewport-width viewport-height)))

(defun etaf--runtime-relayout (runtime width height)
  "Relayout RUNTIME for viewport WIDTH and HEIGHT as an observed operation.
Nil WIDTH and HEIGHT follow the displaying window.  Return non-nil when the
layout changed, which advances the revision."
  (etaf--runtime-run-operation
   runtime 'refit "refit"
   (lambda ()
     (when (ebox-mount-set-viewport (etaf-runtime-buffer runtime) width height)
       (cl-incf (etaf-runtime-rev runtime))
       (when (etaf-runtime-sticky runtime)
         (etaf--sticky-refresh runtime))
       t))))

;;;###autoload
(defun etaf-refit (&optional runtime window)
  "Relayout RUNTIME for WINDOW's current size; return the viewport or nil.
RUNTIME defaults to the current buffer's Runtime and WINDOW to a window
showing it.  Mounted Runtimes follow window resizes automatically."
  (let* ((runtime (or runtime (etaf-runtime-for-buffer (current-buffer))))
         (buffer (and (etaf-runtime-p runtime) (etaf-runtime-buffer runtime)))
         (window (or window (and (buffer-live-p buffer) (get-buffer-window buffer t)))))
    (when (and (etaf-runtime-p runtime) (etaf-runtime-mounted-p runtime)
               (window-live-p window))
      (setf (etaf-runtime-fixed-viewport runtime) (cons nil nil))
      (etaf--runtime-relayout runtime nil nil)
      (ebox-mount-viewport buffer))))

;;;###autoload
(defun etaf-transient-space-borrowed-p (window committed-rows)
  "Return non-nil when transient UI borrows lines from WINDOW.
COMMITTED-ROWS is the body height WINDOW's caller last laid out for.  The
minibuffer and the echo area keep one body line at rest; while one of them
is taller (an active completion session, a wrapped prompt or message) its
extra lines are borrowed from the display windows.  While they are and
WINDOW is shorter than COMMITTED-ROWS, a caller that laid out for
COMMITTED-ROWS keeps that layout instead of recomputing one for the
borrowed height.  Growth, a nil commitment and a shorter window with no
transient UI are real geometry, so they return nil and the caller follows
the window."
  (and (window-live-p window)
       (integerp committed-rows)
       (< (window-body-height window) committed-rows)
       (let* ((frame (window-frame window))
              (minibuffer (and (frame-live-p frame) (minibuffer-window frame))))
         (and (window-live-p minibuffer)
              (> (window-body-height minibuffer) 1)))))

;;;; Host queries

(defun etaf--runtime-host-seg (runtime ref)
  "Return RUNTIME's mounted Host segment registered as REF, or nil."
  (gethash ref (etaf-runtime-hosts runtime)))

(defun etaf-runtime-host-node (runtime ref)
  "Return the Ebox node of RUNTIME's Host REF, or nil."
  (let ((seg (etaf--runtime-host-seg runtime ref)))
    (and seg (etaf--seg-node seg))))

(defun etaf-runtime-node-host-ref (runtime node)
  "Return the reference of RUNTIME's nearest registered Host at or above NODE."
  (let ((nodes (etaf-runtime-nodes runtime)) found)
    (while (and node (not found))
      (let ((seg (gethash node nodes)))
        (if seg
            (setq found (etaf--host-ref (etaf--seg-data seg)))
          (setq node (ebox-node-parent node)))))
    found))

(defun etaf--walk-hosts (runtime function)
  "Call FUNCTION with each registered Host segment of RUNTIME in order."
  (let ((stack (append (delq nil (list (etaf-runtime-root runtime)
                                       (etaf-runtime-surface runtime)))
                       (mapcar #'cdr (etaf-runtime-overlay-entries runtime)))))
    (while stack
      (let ((seg (pop stack)))
        (when (and (eq (etaf--seg-kind seg) 'host)
                   (etaf--host-reg (etaf--seg-data seg)))
          (funcall function seg))
        (setq stack (append (etaf--seg-kids seg) stack))))))

(defun etaf--seg-ancestor-refs (seg)
  "Return the registered Host references above SEG, nearest first."
  (let ((parent (etaf--seg-parent seg)) refs)
    (while parent
      (when (and (eq (etaf--seg-kind parent) 'host)
                 (etaf--host-reg (etaf--seg-data parent)))
        (push (etaf--host-ref (etaf--seg-data parent)) refs))
      (setq parent (etaf--seg-parent parent)))
    (nreverse refs)))

;;;###autoload
(defun etaf-runtime-host-props-for (runtime host-ref)
  "Return a fresh copy of RUNTIME's semantic Host props for HOST-REF, or nil."
  (let ((seg (etaf--runtime-host-seg runtime host-ref)))
    (and seg (copy-sequence (etaf--host-props (etaf--seg-data seg))))))

;;;###autoload
(defun etaf-runtime-host-props-entries (runtime)
  "Return RUNTIME's mounted semantic Hosts as ((REF . PROPS) ...) in order."
  (let (entries)
    (etaf--walk-hosts runtime
                      (lambda (seg)
                        (let ((host (etaf--seg-data seg)))
                          (push (cons (etaf--host-ref host)
                                      (copy-sequence (etaf--host-props host)))
                                entries))))
    (nreverse entries)))

;;;###autoload
(defun etaf-runtime-handler-for (runtime host-ref)
  "Return HOST-REF's event handlers in RUNTIME as ((KIND . FUNCTION) ...)."
  (let ((seg (etaf--runtime-host-seg runtime host-ref)))
    (and seg (etaf--props-handlers (etaf--host-props (etaf--seg-data seg))))))

;;;###autoload
(defun etaf-runtime-handler-entries (runtime)
  "Return RUNTIME's Hosts with handlers as ((REF (KIND . FUNCTION) ...) ...)."
  (let (entries)
    (etaf--walk-hosts runtime
                      (lambda (seg)
                        (let* ((host (etaf--seg-data seg))
                               (handlers (etaf--props-handlers (etaf--host-props host))))
                          (when handlers
                            (push (cons (etaf--host-ref host) handlers) entries)))))
    (nreverse entries)))

;;;###autoload
(defun etaf-runtime-host-ancestor-refs (runtime host-ref)
  "Return the semantic Host references above HOST-REF in RUNTIME, nearest first."
  (let ((seg (etaf--runtime-host-seg runtime host-ref)))
    (and seg (etaf--seg-ancestor-refs seg))))

;;;###autoload
(defun etaf-runtime-host-ancestries (runtime host-refs)
  "Return a table from each of HOST-REFS to its lineage in RUNTIME.
A lineage lists the Host reference itself, then its semantic ancestors'
references, nearest first.  Unknown references are absent."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (ref host-refs table)
      (when-let* ((seg (etaf--runtime-host-seg runtime ref)))
        (puthash ref (cons ref (etaf--seg-ancestor-refs seg)) table)))))

;;;; Retained Host updates

(defun etaf--require-host-node (runtime ref)
  "Return RUNTIME's node for Host REF or signal `etaf-runtime-error'."
  (or (etaf-runtime-host-node runtime ref)
      (signal 'etaf-runtime-error (list "Unknown committed Host" ref))))

;;;###autoload
(defun etaf-runtime-update-host-contents (runtime updates)
  "Replace Host contents in mounted RUNTIME from UPDATES, ((REF . CONTENT) ...).
CONTENT is a string or an image from `create-image'.  Builds without native
image support accept strings only.  Every target validates before the first
change; invalid content signals `etaf-runtime-error'.  Return t."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (proper-list-p updates)
               (cl-every (lambda (entry)
                           (and (consp entry)
                                (or (stringp (cdr entry))
                                    (and (fboundp 'imagep) (imagep (cdr entry))))))
                         updates))
    (signal 'etaf-runtime-error (list "Invalid Host content updates" updates)))
  (let ((nodes (mapcar (lambda (entry)
                         (let ((node (etaf--require-host-node runtime (car entry))))
                           (unless (ebox-node-text-p node)
                             (signal 'etaf-runtime-error
                                     (list "Host cannot hold content" (car entry))))
                           node))
                       updates)))
    (ebox-with-batch
      (cl-loop for node in nodes for entry in updates
               do (ebox-node-set-text
                   node (if (stringp (cdr entry)) (cdr entry)
                          (propertize " " 'display (cdr entry))))))
    (cl-incf (etaf-runtime-rev runtime))
    (when (etaf-runtime-sticky runtime)
      (etaf--sticky-refresh runtime))
    t))

;;;###autoload
(defun etaf-runtime-update-host-content (runtime host-ref content)
  "Replace HOST-REF's content in mounted RUNTIME with string or image CONTENT."
  (etaf-runtime-update-host-contents runtime (list (cons host-ref content))))

;;;###autoload
(defun etaf-runtime-update-host-geometries (runtime updates)
  "Set Host geometry in mounted RUNTIME from UPDATES, ((REF . PLIST) ...).
Each PLIST holds Ebox position, size or layer properties.  Return t."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (proper-list-p updates)
               (cl-every (lambda (entry) (and (consp entry) (proper-list-p (cdr entry))))
                         updates))
    (signal 'etaf-runtime-error (list "Invalid Host geometry updates" updates)))
  (let ((nodes (mapcar (lambda (entry) (etaf--require-host-node runtime (car entry)))
                       updates)))
    (condition-case err
        (ebox-with-batch
          (cl-loop for node in nodes for entry in updates
                   do (cl-loop for (key value) on (cdr entry) by #'cddr
                               do (ebox-node-put node key value))))
      (error (signal 'etaf-runtime-error
                     (list "Host geometry update rejected" (mapcar #'car updates) err))))
    (cl-incf (etaf-runtime-rev runtime))
    (when (etaf-runtime-sticky runtime)
      (etaf--sticky-refresh runtime))
    t))

;;;###autoload
(defun etaf-runtime-update-host-geometry (runtime host-ref &rest geometry)
  "Set HOST-REF's GEOMETRY properties in mounted RUNTIME and return t."
  (etaf-runtime-update-host-geometries runtime (list (cons host-ref geometry))))

;;;; Host presentation and tree inspection

(defun etaf--runtime-index-host-ids (runtime)
  "Refresh and return RUNTIME's host-id -> segment table."
  (let ((table (or (etaf-runtime-host-ids runtime)
                   (setf (etaf-runtime-host-ids runtime)
                         (make-hash-table :test #'eql)))))
    (clrhash table)
    (cl-labels ((walk (seg)
                  (when seg
                    (when (and (eq (etaf--seg-kind seg) 'host)
                               (etaf--seg-live seg))
                      (puthash (etaf--host-id (etaf--seg-data seg)) seg table))
                    (dolist (kid (etaf--seg-kids seg))
                      (walk kid)))))
      (walk (etaf-runtime-root runtime)))
    table))

(defun etaf--runtime-seg-by-id (runtime host-id)
  "Return the live Host segment for integer HOST-ID in RUNTIME, or nil."
  (when (integerp host-id)
    (let* ((table (etaf-runtime-host-ids runtime))
           (seg (and table (gethash host-id table))))
      (unless (and seg (etaf--seg-live seg))
        (setq table (etaf--runtime-index-host-ids runtime)
              seg (gethash host-id table)))
      (and seg (etaf--seg-live seg) seg))))

(defun etaf--sanitize-host-props (props)
  "Return a data-only snapshot of Host PROPS without closures or cycles."
  (let ((tail props)
        (result nil)
        (has-press (and (functionp (plist-get props :on-press))
                        (not (plist-get props :disabled)))))
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (unless (or (memq key '(:keys :use :hover-content))
                    (etaf--event-property-p key)
                    (functionp value))
          (push key result)
          (push value result))))
    (when has-press
      (push :has-on-press result)
      (push t result))
    (nreverse result)))

(defun etaf--host-tree-collect (seg host-ids)
  "Collect read-only Host tree plists under SEG and index them in HOST-IDS."
  (when (and seg (etaf--seg-live seg))
    (if (eq (etaf--seg-kind seg) 'host)
        (let* ((host (etaf--seg-data seg))
               (id (etaf--host-id host))
               (item (etaf--seg-src seg))
               (tag (etaf--view-node-name item))
               (node (etaf--seg-node seg))
               (outer (etaf--seg-outer-node seg))
               (geo (or (and node (ebox-node-geometry node))
                        (and outer (not (eq outer node))
                             (ebox-node-geometry outer))))
               (children nil))
          (puthash id seg host-ids)
          (dolist (kid (etaf--seg-kids seg))
            (setq children (nconc children (etaf--host-tree-collect kid host-ids))))
          (list
           (list :id id
                 :ref (etaf--host-ref host)
                 :tag tag
                 :text (when (eq tag 'text) (etaf--host-text host))
                 :props (etaf--sanitize-host-props (etaf--host-props host))
                 :geometry geo
                 :children children)))
      (let ((result nil))
        (dolist (kid (etaf--seg-kids seg) result)
          (setq result (nconc result (etaf--host-tree-collect kid host-ids))))))))

;;;###autoload
(defun etaf-runtime-host-tree (&optional runtime)
  "Return mounted RUNTIME's committed application Host tree as read-only data.
RUNTIME defaults to the active or current-buffer Runtime.  Transient surfaces
and attached presentation companions are excluded; `:text' holds the
application's authoritative text even when a presentation overrides it."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (table (or (etaf-runtime-host-ids runtime)
                    (setf (etaf-runtime-host-ids runtime)
                          (make-hash-table :test #'eql)))))
    (clrhash table)
    (etaf--host-tree-collect (etaf-runtime-root runtime) table)))

(defun etaf--runtime-window-line-band (runtime)
  "Return (TOP . BOTTOM) 0-based visible buffer lines for RUNTIME, or nil."
  (let* ((buf (etaf-runtime-buffer runtime))
         (win (and (buffer-live-p buf) (get-buffer-window buf t))))
    (when (window-live-p win)
      (with-current-buffer buf
        (let* ((top (1- (line-number-at-pos (window-start win) t)))
               (end-pos (window-end win t))
               (bot (if end-pos
                        (line-number-at-pos end-pos t)
                      (+ top (window-body-height win)))))
          (cons (max 0 top) (max (1+ top) bot)))))))

(defun etaf--seg-clip-band (seg window-band)
  "Return (CLIP-TOP . CLIP-BOTTOM) for Host SEG intersected with WINDOW-BAND."
  (let ((top (and window-band (car window-band)))
        (bot (and window-band (cdr window-band)))
        (cur (etaf--seg-parent seg)))
    (while cur
      (when (eq (etaf--seg-kind cur) 'host)
        (let* ((host (etaf--seg-data cur))
               (ov (and host
                        (or (plist-get (etaf--host-eprops host) :overflow)
                            (plist-get (etaf--host-props host) :overflow)))))
          (when (memq ov '(scroll auto hidden))
            (when-let* ((node (etaf--seg-node cur))
                        (geo (ebox-node-geometry node)))
              (let ((ct (plist-get geo :y))
                    (cb (+ (plist-get geo :y) (max 0 (plist-get geo :height)))))
                (setq top (if top (max top ct) ct)
                      bot (if bot (min bot cb) cb)))))))
      (setq cur (etaf--seg-parent cur)))
    (when (and top bot)
      (cons top bot))))

;;;###autoload
(defun etaf-runtime-host-geometries (runtime host-ids)
  "Return live geometry and visibility for integer HOST-IDS in RUNTIME.
Return an alist of `(HOST-ID . PLIST)' for each live laid-out Host, where
PLIST holds `:x', `:y', `:width', `:height', `:clip-top', `:clip-bottom' and
`:visible-p'.  `:y' reflects every enclosing `:overflow scroll' offset."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (proper-list-p host-ids)
    (signal 'etaf-runtime-error (list "HOST-IDS must be a list" host-ids)))
  (let ((win-band (etaf--runtime-window-line-band runtime))
        (out nil))
    (dolist (id host-ids (nreverse out))
      (when-let* ((seg (etaf--runtime-seg-by-id runtime id)))
        (let* ((node (etaf--seg-node seg))
               (outer (etaf--seg-outer-node seg))
               (geo (or (and node (ebox-node-geometry node))
                        (and outer (not (eq outer node))
                             (ebox-node-geometry outer)))))
          (when geo
            (let* ((y (plist-get geo :y))
                   (h (max 1 (or (plist-get geo :height) 1)))
                   (clip (etaf--seg-clip-band seg win-band))
                   (ct (and clip (car clip)))
                   (cb (and clip (cdr clip)))
                   (vis (if clip
                            (and (> (+ y h) ct) (< y cb))
                          t)))
              (push (cons id (list :x (plist-get geo :x)
                                   :y y
                                   :width (plist-get geo :width)
                                   :height (plist-get geo :height)
                                   :clip-top ct
                                   :clip-bottom cb
                                   :visible-p vis))
                    out))))))))

;;;###autoload
(defun etaf-runtime-trigger-host-press (runtime host-id)
  "Dispatch an enabled `press' event on committed HOST-ID in RUNTIME.
Return non-nil when dispatched, or nil when HOST-ID is absent or has no
enabled `:on-press' handler."
  (etaf--assert-not-rendering 'trigger-host-press)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp host-id)
    (signal 'etaf-runtime-error (list "Host ID must be an integer" host-id)))
  (when-let* ((seg (etaf--runtime-seg-by-id runtime host-id)))
    (let* ((host (etaf--seg-data seg))
           (props (etaf--host-props host)))
      (when (and (not (plist-get props :disabled))
                 (functionp (plist-get props :on-press)))
        (etaf-dispatch-event runtime (etaf--host-ref host) 'press)
        t))))

;;;###autoload
(defun etaf-runtime-focus-host (runtime host-id)
  "Move logical focus to committed integer HOST-ID in mounted RUNTIME.
Return non-nil when HOST-ID was focused, or nil when absent or ineligible."
  (etaf--assert-not-rendering 'focus-host)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp host-id)
    (signal 'etaf-runtime-error (list "Host ID must be an integer" host-id)))
  (when-let* ((seg (etaf--runtime-seg-by-id runtime host-id))
              (node (etaf--seg-node seg)))
    (let ((buf (etaf-runtime-buffer runtime)))
      (when (buffer-live-p buf)
        (condition-case nil
            (progn (ebox-focus node buf) t)
          (user-error nil))))))

;;;###autoload
(defun etaf-runtime-scroll-host-into-view (runtime host-id &optional align)
  "Scroll enclosing scrollers of mounted RUNTIME so HOST-ID is visible.
ALIGN is nil (least movement), `start' or `end'.  Return non-nil when HOST-ID
was live, or nil when absent."
  (etaf--assert-not-rendering 'scroll-host-into-view)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp host-id)
    (signal 'etaf-runtime-error (list "Host ID must be an integer" host-id)))
  (unless (memq align '(nil start end))
    (signal 'etaf-runtime-error (list "Invalid scroll alignment" align)))
  (when-let* ((seg (etaf--runtime-seg-by-id runtime host-id))
              (node (etaf--seg-node seg)))
    (let ((buf (etaf-runtime-buffer runtime)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (ebox-node-scroll-into-view node align)
          ;; When displayed in an Emacs window, also reveal the root line.
          (when-let* ((win (get-buffer-window buf t))
                      (rline (ebox-node-root-line node)))
            (let* ((band (etaf--runtime-window-line-band runtime))
                   (top (and band (car band)))
                   (bot (and band (cdr band))))
              (when (and top bot (or (< rline top) (>= rline bot)))
                (save-excursion
                  (goto-char (point-min))
                  (forward-line rline)
                  (set-window-point win (point))
                  (with-selected-window win
                    (recenter (pcase align
                                ('start 0)
                                ('end -1)
                                (_ nil)))))))))
        t))))

(defun etaf--text-host-offset-for-pos (buf node text bounds target-pos)
  "Return character offset in TEXT corresponding to TARGET-POS inside BOUNDS."
  (with-current-buffer buf
    (let* ((start (car bounds))
           (limit (min target-pos (cdr bounds)))
           (len (length text))
           (idx 0)
           (p start))
      (while (and (< p limit) (< idx len))
        (when (and (eq (get-text-property p 'ebox-node) node)
                   (not (eql (char-after p) ?\u200b))
                   (not (eq (car-safe (get-text-property p 'display)) 'space)))
          (let ((ch (char-after p))
                (src (aref text idx)))
            (cond
             ((eql ch src) (setq idx (1+ idx)))
             ((and (eql ch ?\n) (memq src '(?\s ?\t ?\n)))
              (setq idx (1+ idx))))))
        (setq p (1+ p)))
      idx)))

;;;###autoload
(defun etaf-runtime-host-text-offset-at (runtime &optional position)
  "Return text Host offset and optional active region at POSITION in RUNTIME.
POSITION defaults to `point' in RUNTIME's buffer.  When POSITION sits inside a
mounted text Host, return a plist `(:id HOST-ID :offset CHAR-OFFSET :text TEXT
:region REGION)' where `:region' is `(BEG . END)' in `:text' when Emacs's
region is active and overlaps that Host, else nil.  Return nil when POSITION is
not on a text Host."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((buf (etaf-runtime-buffer runtime)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((pos (or position (point)))
               (node (and (>= pos (point-min)) (<= pos (point-max))
                          (ebox-node-at pos buf)))
               (nodes (etaf-runtime-nodes runtime))
               (seg (and node (gethash node nodes))))
          (when (and seg (eq (etaf--seg-kind seg) 'host) (etaf--seg-live seg)
                     (eq (etaf--view-node-name (etaf--seg-src seg)) 'text))
            (let* ((host (etaf--seg-data seg))
                   (text (or (etaf--host-text host) ""))
                   (bounds (ebox-node-bounds node t)))
              (when bounds
                (let* ((offset (etaf--text-host-offset-for-pos
                                buf node text bounds pos))
                       (region
                        (when (and (use-region-p)
                                   (< (region-beginning) (cdr bounds))
                                   (> (region-end) (car bounds)))
                          (let ((rbeg (etaf--text-host-offset-for-pos
                                       buf node text bounds
                                       (max (car bounds) (region-beginning))))
                                (rend (etaf--text-host-offset-for-pos
                                       buf node text bounds
                                       (min (cdr bounds) (region-end)))))
                            (when (< rbeg rend)
                              (cons rbeg rend))))))
                  (list :id (etaf--host-id host)
                        :offset offset
                        :text (substring-no-properties text)
                        :region region))))))))))

;;;; Runtime metadata

(defun etaf--meta-copy (value)
  "Return a detached copy of metadata VALUE."
  (cond
   ((stringp value) (substring-no-properties value))
   ((or (null value) (eq value t) (numberp value) (symbolp value)) value)
   ((proper-list-p value) (mapcar #'etaf--meta-copy value))
   ((consp value) (cons (etaf--meta-copy (car value))
                        (etaf--meta-copy (cdr value))))
   (t value)))

(defun etaf--meta-resolve (spec)
  "Resolve metadata SPEC plist, reading any reactive values."
  (when spec
    (let (out)
      (cl-loop for (k v) on spec by #'cddr
               do (let ((val (cond
                              ((or (etaf-ref-p v) (etaf-computed-p v))
                               (etaf-value v))
                              ((functionp v) (funcall v))
                              (t v))))
                    (setq out (plist-put out k (etaf--meta-copy val)))))
      out)))

(defun etaf--meta-has-dynamic-p (spec)
  "Return non-nil when metadata SPEC contains reactive or callable values."
  (cl-loop for (_k v) on spec by #'cddr
           thereis (or (etaf-ref-p v) (etaf-computed-p v) (functionp v))))

(defun etaf--runtime-install-meta (runtime meta silent)
  "Install META plist on mounted RUNTIME.
When SILENT is nil and the resolved snapshot changed, run
`etaf-runtime-meta-change-functions'."
  (when-let* ((old-scope (etaf-runtime-meta-scope runtime)))
    (setf (etaf-runtime-meta-scope runtime) nil)
    (etaf-scope-stop old-scope))
  (setf (etaf-runtime-meta-spec runtime) (copy-sequence meta))
  (let* ((prev (etaf-runtime-meta-snapshot runtime))
         (initial nil))
    (if (etaf--meta-has-dynamic-p meta)
        (let ((scope (etaf-effect-scope :detached t :name 'etaf-runtime-meta))
              (first-run t))
          (setf (etaf-runtime-meta-scope runtime) scope)
          (etaf-scope-run
           scope
           (lambda ()
             (etaf-watch-effect
              (lambda ()
                (let ((resolved (etaf--meta-resolve meta)))
                  (if first-run
                      (progn
                        (setq first-run nil initial resolved)
                        (setf (etaf-runtime-meta-snapshot runtime) resolved))
                    (unless (equal resolved (etaf-runtime-meta-snapshot runtime))
                      (setf (etaf-runtime-meta-snapshot runtime) resolved)
                      (when (etaf-runtime-mounted-p runtime)
                        (etaf--run-runtime-hooks
                         'etaf-runtime-meta-change-functions
                         runtime (etaf--meta-copy resolved)))))))
              :name 'etaf-runtime-meta))))
      (setq initial (etaf--meta-resolve meta))
      (setf (etaf-runtime-meta-snapshot runtime) initial))
    (when (and (not silent) (not (equal initial prev)))
      (etaf--run-runtime-hooks
       'etaf-runtime-meta-change-functions
       runtime (etaf--meta-copy initial)))
    (etaf--meta-copy initial)))

;;;###autoload
(defun etaf-runtime-meta (&optional runtime)
  "Return a detached copy of mounted RUNTIME's metadata plist, or nil.
RUNTIME defaults to the active or current-buffer Runtime."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (etaf--meta-copy (etaf-runtime-meta-snapshot runtime)))

;;;###autoload
(defun etaf-runtime-set-meta (runtime meta)
  "Set mounted RUNTIME's metadata plist to META and return the resolved plist.
META is nil or a proper plist whose values may be static data, `etaf-ref',
`etaf-computed' or zero-argument functions.  Reactive changes notify
`etaf-runtime-meta-change-functions'."
  (etaf--assert-not-rendering 'set-meta)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (or (null meta)
              (and (proper-list-p meta) (zerop (% (length meta) 2))))
    (signal 'etaf-runtime-error (list "Runtime meta must be a plist or nil" meta)))
  (etaf--runtime-install-meta runtime meta nil))

;;;; Named root overlays

;;;###autoload
(defun etaf-runtime-set-overlay (runtime key view &optional origin)
  "Mount, update or clear named root-layer overlay KEY with VIEW in RUNTIME.
KEY is a non-nil symbol identifying the overlay owner.  When VIEW is nil,
remove KEY's overlay.  VIEW inherits ORIGIN's (or the root's) Context and
Theme without remounting application Components or firing
`etaf-runtime-after-commit-functions'.  Return non-nil when changed."
  (etaf--assert-not-rendering 'set-overlay)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (symbolp key) key)
    (signal 'etaf-runtime-error (list "Overlay key must be a non-nil symbol" key)))
  (let ((etaf--in-presentation-mutation t)
        (changed nil))
    (etaf-call-with-batch
     (lambda ()
       (let ((existing (assq key (etaf-runtime-overlay-entries runtime))))
         (if (null view)
             (when existing
               (setf (etaf-runtime-overlay-entries runtime)
                     (assq-delete-all key (etaf-runtime-overlay-entries runtime)))
               (etaf--dispose (cdr existing) nil)
               (etaf--root-dirty runtime)
               (setq changed t))
           (if existing
               (let ((oseg (cdr existing)))
                 (setf (etaf--seg-src oseg) view)
                 (etaf--patch-kids oseg (etaf--flatten view) (etaf--seg-ctx oseg))
                 (etaf--root-dirty runtime)
                 (setq changed t))
             (let* ((source (or (and origin (etaf--runtime-host-seg runtime origin))
                                (etaf-runtime-root runtime)))
                    (ctx (etaf--ictx-make
                          :runtime runtime
                          :context (etaf--ictx-context (etaf--seg-ctx source))))
                    (oseg (etaf--seg-make
                           :kind 'overlay :src view :ctx ctx
                           :node (etaf-runtime-mounted-root runtime))))
               (condition-case err
                   (progn
                     (etaf--root-init oseg)
                     (setf (etaf--seg-live oseg) t
                           (etaf-runtime-overlay-entries runtime)
                           (append (etaf-runtime-overlay-entries runtime)
                                   (list (cons key oseg))))
                     (etaf--root-dirty runtime)
                     (setq changed t))
                 ((error quit)
                  (etaf--dispose oseg nil)
                  (signal (car err) (cdr err))))))))))
    changed))

;;;###autoload
(defun etaf-runtime-clear-overlay (runtime &optional key)
  "Remove named root overlays in mounted RUNTIME and return count removed.
When KEY is non-nil, remove only KEY; otherwise remove all overlays."
  (etaf--assert-not-rendering 'clear-overlay)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when (and key (not (symbolp key)))
    (signal 'etaf-runtime-error (list "Overlay key must be a symbol or nil" key)))
  (let ((etaf--in-presentation-mutation t)
        (removed 0))
    (if key
        (when (etaf-runtime-set-overlay runtime key nil)
          (setq removed 1))
      (let ((entries (etaf-runtime-overlay-entries runtime)))
        (when entries
          (etaf-call-with-batch
           (lambda ()
             (setf (etaf-runtime-overlay-entries runtime) nil)
             (dolist (entry entries)
               (etaf--dispose (cdr entry) nil)
               (cl-incf removed))
             (etaf--root-dirty runtime))))))
    removed))

;;;; Multi-owner Host presentations

(defun etaf--pb-empty-p (bucket)
  "Return non-nil when presentation BUCKET has no active entries."
  (and (null (etaf--pb-decorations bucket))
       (null (etaf--pb-companions bucket))
       (null (etaf--pb-overrides bucket))))

(defun etaf--pb-all-entries (bucket)
  "Return all active `etaf--pres' entries in BUCKET."
  (when bucket
    (append (etaf--pb-decorations bucket)
            (etaf--pb-companions bucket)
            (etaf--pb-overrides bucket))))

(defun etaf--pb-sort (entries &optional latest-first)
  "Return ENTRIES sorted by ascending priority and deterministic seq order."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((pa (etaf--pres-priority a))
                (pb (etaf--pres-priority b)))
            (if (/= pa pb)
                (< pa pb)
              (if latest-first
                  (> (etaf--pres-seq a) (etaf--pres-seq b))
                (< (etaf--pres-seq a) (etaf--pres-seq b))))))))

(defun etaf--pb-effective-text (host bucket)
  "Return rendered display string for text HOST under presentation BUCKET."
  (let* ((active-ov (and bucket (etaf--pb-active-override bucket)))
         (base (or (and active-ov (etaf--pres-text-override active-ov))
                   (etaf--host-text host)
                   ""))
         (decs (and bucket (etaf--pb-decorations bucket))))
    (if (null decs)
        base
      (let ((copy (copy-sequence base))
            (len (length base)))
        (dolist (dec decs copy)
          (when-let* ((wface (etaf--pres-face dec)))
            (when (> len 0)
              (add-face-text-property 0 len wface nil copy)))
          (dolist (span (etaf--pres-spans dec))
            (let* ((range (car span))
                   (raw (cdr span))
                   (face (if (and (consp raw) (keywordp (car raw))
                                  (plist-member raw :face))
                             (plist-get raw :face)
                           raw))
                   (beg (max 0 (min len (car range))))
                   (end (max beg (min len (cdr range)))))
              (when (and face (< beg end))
                (add-face-text-property beg end face nil copy)))))))))

(defun etaf--pres-validate-spans (spans)
  "Validate SPANS list for a `decorate' presentation spec."
  (unless (proper-list-p spans)
    (signal 'etaf-runtime-error (list "Decoration :spans must be a list" spans)))
  (dolist (span spans)
    (unless (and (consp span)
                 (consp (car span))
                 (integerp (caar span))
                 (integerp (cdar span))
                 (<= 0 (caar span))
                 (<= (caar span) (cdar span)))
      (signal 'etaf-runtime-error (list "Invalid decoration span" span)))
    (let* ((raw (cdr span))
           (face (if (and (consp raw) (keywordp (car raw))
                          (plist-member raw :face))
                     (plist-get raw :face)
                   raw)))
      (unless (or (symbolp face) (proper-list-p face))
        (signal 'etaf-runtime-error (list "Invalid decoration span face" span))))))

(defun etaf--pres-validate-spec (spec)
  "Validate presentation SPEC plist or nil, signaling `etaf-runtime-error'."
  (when spec
    (unless (proper-list-p spec)
      (signal 'etaf-runtime-error (list "Presentation spec must be a plist or nil" spec)))
    (cl-loop for (k _v) on spec by #'cddr
             unless (memq k '(:mode :text :view :spans :face :priority))
             do (signal 'etaf-runtime-error (list "Unknown presentation spec key" k)))
    (when (plist-member spec :priority)
      (let ((prio (plist-get spec :priority)))
        (unless (integerp prio)
          (signal 'etaf-runtime-error (list "Presentation :priority must be an integer" prio)))))
    (let ((mode (plist-get spec :mode))
          (text (plist-get spec :text))
          (view (plist-get spec :view))
          (spans (plist-get spec :spans))
          (face (plist-get spec :face)))
      (unless (memq mode '(decorate override companion-inside companion-after companion-beside))
        (signal 'etaf-runtime-error (list "Invalid presentation :mode" mode)))
      (pcase mode
        ('decorate
         (when (or text view)
           (signal 'etaf-runtime-error
                   (list "Decorate presentation does not take :text or :view" spec)))
         (when spans (etaf--pres-validate-spans spans))
         (unless (or (null face) (symbolp face) (proper-list-p face))
           (signal 'etaf-runtime-error (list "Invalid decoration :face" face))))
        ('override
         (when (or spans face)
           (signal 'etaf-runtime-error
                   (list "Override presentation does not take :spans or :face" spec)))
         (when (and text view)
           (signal 'etaf-runtime-error
                   (list "Override presentation takes either :text or :view, not both")))
         (unless (or (stringp text) view)
           (signal 'etaf-runtime-error
                   (list "Override presentation requires string :text or :view" spec))))
        (_
         (when (or text spans face)
           (signal 'etaf-runtime-error
                   (list "Companion presentation takes :view, not :text, :spans or :face" spec)))
         (unless view
           (signal 'etaf-runtime-error
                   (list "Companion presentation requires :view" spec)))))))
  spec)

(defun etaf--pres-wrapper-props (host mode &optional beside-count)
  "Return transparent wrapper Ebox props for HOST in companion MODE."
  (let* ((eprops (etaf--host-eprops host))
         (result nil))
    (dolist (key '(:width :min-width :max-width :flex-grow :flex-shrink
                   :flex-basis :align-self :justify-self :grid-column :grid-row))
      (when (plist-member eprops key)
        (let ((val (plist-get eprops key)))
          (when val
            (setq result (plist-put result key val))))))
    (unless (plist-get result :width)
      (setq result (plist-put result :width 'stretch)))
    (pcase mode
      ('companion-after
       (setq result (plist-put result :item-gap '(lh 0))))
      ('companion-beside
       (setq result (plist-put result :grid-template-columns
                               (make-list (1+ (max 1 (or beside-count 1))) '(fr 1))))
       (setq result (plist-put result :gap '((lh 0) (ch 2))))
       (setq result (plist-put result :align-items 'start))))
    result))

(defun etaf--pres-build-pseg (runtime seg container view)
  "Build and mount a `pres' sub-segment for VIEW inside CONTAINER under SEG."
  (let* ((pctx (etaf--ictx-make
                :runtime runtime
                :context (etaf--ictx-context (etaf--seg-ctx seg))))
         (pseg (etaf--seg-make :kind 'pres :src view :ctx pctx
                               :node container :live t)))
    (condition-case err
        (progn
          (etaf--patch-kids pseg (etaf--flatten view) pctx)
          pseg)
      ((error quit)
       (etaf--dispose pseg nil)
       (signal (car err) (cdr err))))))

(defun etaf--pb-detach-node (node)
  "Remove NODE from its Ebox parent when attached."
  (when (and node (ebox-node-parent node))
    (ebox-node-remove node)))

(defun etaf--pb-sync-children (parent desired)
  "Make PARENT hold DESIRED child Ebox nodes in order using remove/insert/move."
  (dolist (child (ebox-node-children parent))
    (unless (memq child desired)
      (ebox-node-remove child)))
  (let ((idx 0))
    (dolist (child desired)
      (let ((cur (ebox-node-parent child)))
        (cond
         ((and (eq cur parent) (= (ebox-node-index child) idx)))
         ((eq cur parent)
          (ebox-node-move child idx))
         (t
          (when cur (ebox-node-remove child))
          (ebox-node-insert parent child idx))))
      (setq idx (1+ idx)))))

(defun etaf--pb-sync-wrappers (runtime seg bucket)
  "Reconcile outer pairing wrappers for `companion-after' and `companion-beside'."
  (let* ((host (etaf--seg-data seg))
         (node (etaf--seg-node seg))
         (beside-slots (cl-loop for c in (etaf--pb-companions bucket)
                                when (eq (etaf--pres-mode c) 'companion-beside)
                                collect (etaf--pres-slot c)))
         (after-slots (cl-loop for c in (etaf--pb-companions bucket)
                               when (eq (etaf--pres-mode c) 'companion-after)
                               collect (etaf--pres-slot c)))
         (old-outer (or (etaf--pb-outer bucket) node))
         (old-grid (etaf--pb-beside-grid bucket))
         (parent (ebox-node-parent old-outer))
         (idx (and parent (ebox-node-index old-outer)))
         (root-level (or (null parent)
                         (eq parent (etaf-runtime-wrapper runtime))))
         (new-outer nil)
         (new-grid nil))
    (cond
     ;; Case 0: no outer companions.
     ((and (null beside-slots) (null after-slots))
      (setq new-outer node new-grid nil))
     ;; Case 1: beside only -> grid is outer.
     ((and beside-slots (null after-slots))
      (setq new-grid (if (and old-grid (eq old-grid old-outer))
                         old-grid
                       (ebox-node-create 'grid nil nil)))
      (ebox-node-set-props new-grid
                           (etaf--pres-wrapper-props host 'companion-beside
                                                     (length beside-slots)))
      (setq new-outer new-grid))
     ;; Case 2: after only -> column is outer.
     ((and (null beside-slots) after-slots)
      (setq new-outer (if (and (etaf--pb-outer bucket)
                               (not (eq (etaf--pb-outer bucket) old-grid)))
                          (etaf--pb-outer bucket)
                        (ebox-node-create 'column
                                          (etaf--pres-wrapper-props host 'companion-after)
                                          nil)))
      (setq new-grid nil))
     ;; Case 3: both beside and after -> column holds [grid, after...].
     (t
      (setq new-grid (if (and old-grid (not (eq old-grid old-outer)))
                         old-grid
                       (ebox-node-create 'grid nil nil)))
      (ebox-node-set-props new-grid
                           (list :width 'stretch
                                 :grid-template-columns
                                 (make-list (1+ (length beside-slots)) '(fr 1))
                                 :gap '((lh 0) (ch 2))
                                 :align-items 'start))
      (setq new-outer (if (and (etaf--pb-outer bucket)
                               (not (eq (etaf--pb-outer bucket) old-grid)))
                          (etaf--pb-outer bucket)
                        (ebox-node-create 'column
                                          (etaf--pres-wrapper-props host 'companion-after)
                                          nil)))))
    ;; Reconcile Ebox parent/child links using remove/insert/move so Ebox
    ;; clears internal layout run pointers cleanly on detached nodes.
    (if (eq new-outer old-outer)
        (cond
         ((and new-grid (eq new-grid new-outer))
          (etaf--pb-sync-children new-grid (cons node beside-slots)))
         (new-grid
          (etaf--pb-sync-children new-grid (cons node beside-slots))
          (etaf--pb-sync-children new-outer (cons new-grid after-slots)))
         ((not (eq new-outer node))
          (etaf--pb-sync-children new-outer (cons node after-slots))))
      ;; Outer identity changed: detach children first via ebox-node-remove,
      ;; then replace old-outer in parent with new-outer.
      (etaf--pb-detach-node node)
      (dolist (s beside-slots) (etaf--pb-detach-node s))
      (dolist (s after-slots) (etaf--pb-detach-node s))
      (when (and old-grid (not (eq old-grid new-grid)))
        (dolist (c (ebox-node-children old-grid)) (ebox-node-remove c)))
      (when (and (etaf--pb-outer bucket)
                 (not (eq (etaf--pb-outer bucket) new-outer))
                 (not (eq (etaf--pb-outer bucket) new-grid)))
        (dolist (c (ebox-node-children (etaf--pb-outer bucket)))
          (ebox-node-remove c)))
      (etaf--pb-detach-node old-outer)
      (when new-grid
        (etaf--pb-sync-children new-grid (cons node beside-slots)))
      (cond
       ((eq new-outer node) nil)
       ((eq new-outer new-grid) nil)
       (new-grid
        (etaf--pb-detach-node new-grid)
        (etaf--pb-sync-children new-outer (cons new-grid after-slots)))
       (t
        (etaf--pb-sync-children new-outer (cons node after-slots))))
      (setf (etaf--pb-outer bucket) (unless (eq new-outer node) new-outer)
            (etaf--pb-beside-grid bucket) new-grid)
      (if root-level
          (etaf--root-dirty runtime)
        (ebox-node-insert parent new-outer idx)))
    (setf (etaf--pb-outer bucket) (unless (eq new-outer node) new-outer)
          (etaf--pb-beside-grid bucket) new-grid)))

(defun etaf--pb-sync-inside (seg bucket)
  "Keep all `companion-inside' slots of BUCKET attached at the tail of SEG."
  (let ((node (etaf--seg-node seg)))
    (when node
      (dolist (c (etaf--pb-companions bucket))
        (when (eq (etaf--pres-mode c) 'companion-inside)
          (let ((slot (etaf--pres-slot c)))
            (unless (eq (ebox-node-parent slot) node)
              (etaf--pb-detach-node slot)
              (ebox-node-insert node slot)))))
      (etaf--pres-pin-companion-inside seg node))))

(defun etaf--pb-sync-override (runtime seg bucket)
  "Activate the top-priority override in BUCKET, or restore original content."
  (let* ((host (etaf--seg-data seg))
         (node (etaf--seg-node seg))
         (tag (etaf--view-node-name (etaf--seg-src seg)))
         (desired (car (etaf--pb-overrides bucket)))
         (prev (etaf--pb-active-override bucket)))
    (if (eq tag 'text)
        (progn
          (setf (etaf--pb-active-override bucket) desired)
          (when node
            (ebox-node-set-text node (etaf--pb-effective-text host bucket))))
      (unless (eq desired prev)
        ;; Temporarily detach companion-inside slots while swapping children.
        (let ((inside-slots
               (cl-loop for c in (etaf--pb-companions bucket)
                        when (eq (etaf--pres-mode c) 'companion-inside)
                        collect (etaf--pres-slot c))))
          (dolist (s inside-slots) (etaf--pb-detach-node s))
          (when (and prev (etaf--pres-seg prev))
            (etaf--dispose (etaf--pres-seg prev) nil)
            (setf (etaf--pres-seg prev) nil))
          (cond
           (desired
            (unless (etaf--pb-holder bucket)
              (let ((orig (ebox-node-children node))
                    (holder (ebox-node-create 'box nil nil)))
                (ebox-node-replace-children node nil)
                (ebox-node-replace-children holder orig)
                (setf (etaf--pb-holder bucket) holder)))
            (ebox-node-replace-children node nil)
            (condition-case err
                (let ((pseg (etaf--pres-build-pseg runtime seg node
                                                   (etaf--pres-view desired))))
                  (setf (etaf--pres-seg desired) pseg
                        (etaf--pb-active-override bucket) desired))
              ((error quit)
               (ebox-node-replace-children node nil)
               (setf (etaf--pb-overrides bucket)
                     (delq desired (etaf--pb-overrides bucket)))
               (setf (etaf--pb-active-override bucket) nil)
               (when-let* ((holder (etaf--pb-holder bucket)))
                 (let ((back (ebox-node-children holder)))
                   (ebox-node-replace-children holder nil)
                   (ebox-node-replace-children node back)
                   (setf (etaf--pb-holder bucket) nil)))
               (etaf--pb-sync-inside seg bucket)
               (signal (car err) (cdr err)))))
           (t
            (setf (etaf--pb-active-override bucket) nil)
            (when-let* ((holder (etaf--pb-holder bucket)))
              (let ((back (ebox-node-children holder)))
                (ebox-node-replace-children node nil)
                (ebox-node-replace-children holder nil)
                (ebox-node-replace-children node back)
                (setf (etaf--pb-holder bucket) nil)))))
          (etaf--pb-sync-inside seg bucket))))))

(defun etaf--pb-remove-structural (runtime seg bucket key)
  "Remove KEY's companion or override entry from BUCKET; return non-nil if removed."
  (let ((comp (cl-find key (etaf--pb-companions bucket) :key #'etaf--pres-key))
        (ov (cl-find key (etaf--pb-overrides bucket) :key #'etaf--pres-key))
        (changed nil))
    (when comp
      (setf (etaf--pb-companions bucket)
            (delq comp (etaf--pb-companions bucket)))
      (when-let* ((pseg (etaf--pres-seg comp)))
        (etaf--dispose pseg nil)
        (setf (etaf--pres-seg comp) nil))
      (etaf--pb-detach-node (etaf--pres-slot comp))
      (if (eq (etaf--pres-mode comp) 'companion-inside)
          (etaf--pb-sync-inside seg bucket)
        (etaf--pb-sync-wrappers runtime seg bucket))
      (setq changed t))
    (when ov
      (setf (etaf--pb-overrides bucket)
            (delq ov (etaf--pb-overrides bucket)))
      (etaf--pb-sync-override runtime seg bucket)
      (setq changed t))
    changed))

(defun etaf--pb-remove-decoration (seg bucket key)
  "Remove KEY's decoration entry from BUCKET; return non-nil if removed."
  (when-let* ((dec (cl-find key (etaf--pb-decorations bucket) :key #'etaf--pres-key)))
    (setf (etaf--pb-decorations bucket)
          (delq dec (etaf--pb-decorations bucket)))
    (let ((host (etaf--seg-data seg))
          (node (etaf--seg-node seg)))
      (when (and node (eq (etaf--view-node-name (etaf--seg-src seg)) 'text))
        (ebox-node-set-text node (etaf--pb-effective-text host bucket))))
    t))

(defun etaf--pb-cleanup-if-empty (runtime seg bucket)
  "Release BUCKET from Host SEG when empty."
  (when (etaf--pb-empty-p bucket)
    (setf (etaf--host-presentation (etaf--seg-data seg)) nil)
    (when (etaf-runtime-presentations runtime)
      (remhash seg (etaf-runtime-presentations runtime)))))

(defun etaf--pres-detach-key (runtime seg key)
  "Remove presentations owned by KEY (or all when KEY is nil) on SEG.
Must run inside `ebox-call-with-batch'.  Return non-nil when anything changed."
  (let* ((host (etaf--seg-data seg))
         (bucket (and host (etaf--host-presentation host))))
    (when bucket
      (let ((changed nil))
        (if (null key)
            (let ((keys (delete-dups
                         (mapcar #'etaf--pres-key (etaf--pb-all-entries bucket)))))
              (dolist (k keys)
                (when (etaf--pb-remove-decoration seg bucket k) (setq changed t))
                (when (etaf--pb-remove-structural runtime seg bucket k) (setq changed t))))
          (when (etaf--pb-remove-decoration seg bucket key) (setq changed t))
          (when (etaf--pb-remove-structural runtime seg bucket key) (setq changed t)))
        (etaf--pb-cleanup-if-empty runtime seg bucket)
        (when changed
          (etaf--runtime-changed runtime)
          t)))))

(defun etaf--pres-ensure-bucket (runtime seg)
  "Return or create the presentation bucket for Host SEG in RUNTIME."
  (let* ((host (etaf--seg-data seg))
         (bucket (etaf--host-presentation host))
         (table (or (etaf-runtime-presentations runtime)
                    (setf (etaf-runtime-presentations runtime)
                          (make-hash-table :test #'eq)))))
    (unless bucket
      (setq bucket (etaf--pb-make))
      (setf (etaf--host-presentation host) bucket))
    (puthash seg t table)
    bucket))

(defun etaf--pres-apply-1 (runtime seg key spec)
  "Apply presentation SPEC owned by KEY onto Host SEG in RUNTIME.
Must run inside `ebox-call-with-batch'.  Return non-nil when changed."
  (let* ((host (etaf--seg-data seg))
         (node (etaf--seg-node seg))
         (tag (etaf--view-node-name (etaf--seg-src seg))))
    (if (null spec)
        (etaf--pres-detach-key runtime seg key)
      (let ((mode (plist-get spec :mode))
            (text (plist-get spec :text))
            (view (plist-get spec :view))
            (spans (plist-get spec :spans))
            (face (plist-get spec :face))
            (priority (or (plist-get spec :priority) 50)))
        ;; Validate compatibility with Host kind.
        (cond
         ((and (eq mode 'decorate) (not (eq tag 'text)))
          (signal 'etaf-runtime-error
                  (list "Decorate presentation requires a text Host" tag)))
         ((and (eq mode 'override) text (not (eq tag 'text)))
          (signal 'etaf-runtime-error
                  (list "Text override presentation requires a text Host" tag)))
         ((and (eq mode 'override) view (memq tag '(text image)))
          (signal 'etaf-runtime-error
                  (list "View override presentation requires a container Host" tag)))
         ((and (eq mode 'companion-inside) (not (eq tag 'box)))
          (signal 'etaf-runtime-error
                  (list "companion-inside presentation requires a box Host" tag))))
        (pcase mode
          ('decorate
           (if (and (null spans) (null face))
               (let ((bucket (etaf--host-presentation host)))
                 (when (and bucket (etaf--pb-remove-decoration seg bucket key))
                   (etaf--pb-cleanup-if-empty runtime seg bucket)
                   (etaf--runtime-changed runtime)
                   t))
             (let* ((bucket (etaf--pres-ensure-bucket runtime seg))
                    (existing (cl-find key (etaf--pb-decorations bucket)
                                       :key #'etaf--pres-key))
                    (changed nil))
               (if existing
                   (unless (and (equal (etaf--pres-spans existing) spans)
                                (equal (etaf--pres-face existing) face)
                                (= (etaf--pres-priority existing) priority))
                     (setf (etaf--pres-spans existing) (copy-tree spans)
                           (etaf--pres-face existing) (copy-tree face)
                           (etaf--pres-priority existing) priority
                           (etaf--pb-decorations bucket)
                           (etaf--pb-sort (etaf--pb-decorations bucket))
                           changed t))
                 (let ((entry (etaf--pres-make
                               :key key :mode 'decorate :priority priority
                               :seq (cl-incf (etaf-runtime-pres-seq runtime))
                               :face (copy-tree face)
                               :spans (copy-tree spans))))
                   (setf (etaf--pb-decorations bucket)
                         (etaf--pb-sort (cons entry (etaf--pb-decorations bucket)))
                         changed t)))
               (when changed
                 (when node
                   (ebox-node-set-text node (etaf--pb-effective-text host bucket)))
                 (etaf--runtime-changed runtime)
                 t))))
          ('override
           (let* ((bucket (etaf--pres-ensure-bucket runtime seg))
                  (existing-ov (cl-find key (etaf--pb-overrides bucket)
                                        :key #'etaf--pres-key))
                  (existing-comp (cl-find key (etaf--pb-companions bucket)
                                          :key #'etaf--pres-key)))
             ;; Switching key from companion to override drops key's companion.
             (when existing-comp
               (etaf--pb-remove-structural runtime seg bucket key)
               (setq existing-ov nil))
             (cond
              ;; Fast path: text override update in place.
              ((and existing-ov text (etaf--pres-text-override existing-ov))
               (unless (and (equal-including-properties
                             text (etaf--pres-text-override existing-ov))
                            (= (etaf--pres-priority existing-ov) priority))
                 (setf (etaf--pres-text-override existing-ov) text
                       (etaf--pres-priority existing-ov) priority
                       (etaf--pb-overrides bucket)
                       (etaf--pb-sort (etaf--pb-overrides bucket) t))
                 (etaf--pb-sync-override runtime seg bucket)
                 (etaf--runtime-changed runtime)
                 t))
              ;; Fast path: active view override update in place.
              ((and existing-ov view
                    (eq existing-ov (etaf--pb-active-override bucket))
                    (etaf--pres-seg existing-ov))
               (let ((pseg (etaf--pres-seg existing-ov)))
                 (setf (etaf--pres-view existing-ov) view
                       (etaf--pres-priority existing-ov) priority
                       (etaf--seg-src pseg) view)
                 (etaf--patch-kids pseg (etaf--flatten view) (etaf--seg-ctx pseg))
                 (setf (etaf--pb-overrides bucket)
                       (etaf--pb-sort (etaf--pb-overrides bucket) t))
                 (etaf--pb-sync-override runtime seg bucket)
                 (etaf--runtime-changed runtime)
                 t))
              (t
               (when existing-ov
                 (etaf--pb-remove-structural runtime seg bucket key))
               (let ((entry (etaf--pres-make
                             :key key :mode 'override :priority priority
                             :seq (cl-incf (etaf-runtime-pres-seq runtime))
                             :text-override text :view view)))
                 (setf (etaf--pb-overrides bucket)
                       (etaf--pb-sort (cons entry (etaf--pb-overrides bucket)) t))
                 (etaf--pb-sync-override runtime seg bucket)
                 (etaf--runtime-changed runtime)
                 t)))))
          ((or 'companion-inside 'companion-after 'companion-beside)
           (let* ((bucket (etaf--pres-ensure-bucket runtime seg))
                  (existing-comp (cl-find key (etaf--pb-companions bucket)
                                          :key #'etaf--pres-key))
                  (existing-ov (cl-find key (etaf--pb-overrides bucket)
                                        :key #'etaf--pres-key)))
             ;; Switching key from override to companion drops key's override.
             (when existing-ov
               (etaf--pb-remove-structural runtime seg bucket key)
               (setq existing-comp nil))
             (if (and existing-comp
                      (eq (etaf--pres-mode existing-comp) mode)
                      (etaf--pres-seg existing-comp))
                 ;; Fast path: patch companion segment in place.
                 (let ((pseg (etaf--pres-seg existing-comp))
                       (prio-changed (/= (etaf--pres-priority existing-comp) priority)))
                   (setf (etaf--pres-priority existing-comp) priority
                         (etaf--pres-view existing-comp) view
                         (etaf--seg-src pseg) view)
                   (etaf--patch-kids pseg (etaf--flatten view) (etaf--seg-ctx pseg))
                   (when prio-changed
                     (setf (etaf--pb-companions bucket)
                           (etaf--pb-sort (etaf--pb-companions bucket)))
                     (if (eq mode 'companion-inside)
                         (etaf--pb-sync-inside seg bucket)
                       (etaf--pb-sync-wrappers runtime seg bucket)))
                   (etaf--runtime-changed runtime)
                   t)
               ;; New companion or companion mode change for key.
               (when existing-comp
                 (etaf--pb-remove-structural runtime seg bucket key))
               (let* ((slot (ebox-node-create 'column
                                              '(:width stretch :item-gap (lh 0))
                                              nil))
                      (pseg (etaf--pres-build-pseg runtime seg slot view))
                      (entry (etaf--pres-make
                              :key key :mode mode :priority priority
                              :seq (cl-incf (etaf-runtime-pres-seq runtime))
                              :slot slot :seg pseg :view view)))
                 (setf (etaf--pb-companions bucket)
                       (etaf--pb-sort (cons entry (etaf--pb-companions bucket))))
                 (if (eq mode 'companion-inside)
                     (etaf--pb-sync-inside seg bucket)
                   (etaf--pb-sync-wrappers runtime seg bucket))
                 (etaf--runtime-changed runtime)
                 t)))))))))

;;;###autoload
(defun etaf-runtime-set-host-presentations (runtime key updates)
  "Apply presentation UPDATES owned by KEY in mounted RUNTIME in one flush.
KEY is a non-nil symbol identifying the owner.  UPDATES is a list of
\(HOST-ID . SPEC) pairs where HOST-ID is an integer from
`etaf-runtime-host-tree' and SPEC is nil or a presentation plist with `:mode'
\(`decorate', `override', `companion-inside', `companion-after' or
`companion-beside'), optional `:priority' (integer, default 50), and
mode-specific payload (`:spans' / `:face', `:text' or `:view').  Multiple keys
coexist cleanly on the same Host.  Unknown or unmounted HOST-IDs are skipped.
Return the number of Hosts updated."
  (etaf--assert-not-rendering 'set-host-presentations)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (symbolp key) key)
    (signal 'etaf-runtime-error (list "Presentation key must be a non-nil symbol" key)))
  (unless (proper-list-p updates)
    (signal 'etaf-runtime-error (list "Presentation updates must be a list" updates)))
  (dolist (entry updates)
    (unless (and (consp entry) (integerp (car entry)))
      (signal 'etaf-runtime-error (list "Invalid presentation update entry" entry)))
    (etaf--pres-validate-spec (cdr entry)))
  (let ((count 0)
        (etaf--in-presentation-mutation t))
    (etaf-call-with-batch
     (lambda ()
       (ebox-call-with-batch
        (lambda ()
          (with-current-buffer (etaf-runtime-buffer runtime)
            (dolist (entry updates)
              (when-let* ((seg (etaf--runtime-seg-by-id runtime (car entry))))
                (when (etaf--pres-apply-1 runtime seg key (cdr entry))
                  (cl-incf count)))))))))
    count))

;;;###autoload
(defun etaf-runtime-set-host-presentation (runtime host-id key spec)
  "Attach or update presentation SPEC owned by KEY on HOST-ID in RUNTIME.
Return non-nil when HOST-ID was live and updated, or nil otherwise."
  (> (etaf-runtime-set-host-presentations runtime key (list (cons host-id spec))) 0))

;;;###autoload
(defun etaf-runtime-clear-presentations (runtime &optional key)
  "Remove attached presentations in mounted RUNTIME, restoring original Hosts.
When KEY is non-nil, remove only presentations owned by KEY without disturbing
other owners; otherwise remove all presentations.  Return the number of Hosts
updated."
  (etaf--assert-not-rendering 'clear-presentations)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when (and key (not (symbolp key)))
    (signal 'etaf-runtime-error (list "Presentation key must be a symbol or nil" key)))
  (let ((table (etaf-runtime-presentations runtime))
        (count 0)
        (etaf--in-presentation-mutation t))
    (when (and table (> (hash-table-count table) 0))
      (let ((targets nil))
        (maphash (lambda (seg _v)
                   (when (etaf--seg-live seg)
                     (let* ((host (etaf--seg-data seg))
                            (bucket (and host (etaf--host-presentation host))))
                       (when (and bucket
                                  (or (null key)
                                      (cl-some (lambda (e) (eq (etaf--pres-key e) key))
                                               (etaf--pb-all-entries bucket))))
                         (push seg targets)))))
                 table)
        (when targets
          (etaf-call-with-batch
           (lambda ()
             (ebox-call-with-batch
              (lambda ()
                (with-current-buffer (etaf-runtime-buffer runtime)
                  (dolist (seg targets)
                    (when (etaf--pres-detach-key runtime seg key)
                      (cl-incf count)))))))))))
    count))

(provide 'etaf-runtime)

;;; etaf-runtime.el ends here
