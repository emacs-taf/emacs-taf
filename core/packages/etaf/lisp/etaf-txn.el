;;; etaf-txn.el --- Retained segment records, dynamic state and transactions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Core runtime records (`etaf-runtime', segments, component instances,
;; overlays and presentation buckets), dynamic evaluation state, and
;; transactional rollback journaling for retained segment edits.

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

(declare-function etaf-runtime-for-buffer "etaf-runtime" (buffer-or-name))
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

(defvar etaf--seg-boundaries (make-hash-table :test #'eq :weakness 'key)
  "Weak map from `etaf-error-boundary' Component segments to boundary records.")

(defvar etaf--scope-segments (make-hash-table :test #'eq :weakness 'key)
  "Weak map from Component setup Effect Scopes to their owning segments.")

(defvar etaf--boundary-sync-error-function nil
  "Hook `(SEG ERR)' called when a boundary Component fails synchronously.")

(defvar etaf--boundary-hook-error-function nil
  "Hook `(INST ERR)' called when a lifecycle hook signals inside a boundary.")

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

(provide 'etaf-txn)
;;; etaf-txn.el ends here
