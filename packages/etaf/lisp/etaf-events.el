;;; etaf-events.el --- ETAF event, activation, and focus ports -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Events are Runtime-owned entry points into committed `:on-*' callbacks.
;; Ebox owns native targeting, focus and input lifetime; this module connects
;; those capabilities to application callbacks and reactive batches.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-runtime)

(defvar etaf--current-runtime)
(defvar etaf--observer-context)

(declare-function etaf-runtime-require-mounted "etaf-runtime" (&optional runtime))
(declare-function etaf-runtime-p "etaf-runtime" (value))
(declare-function etaf-runtime-mounted-p "etaf-runtime" (runtime))
(declare-function etaf-runtime-buffer "etaf-runtime" (runtime))
(declare-function etaf-runtime-handler-for "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-handler-entries "etaf-runtime" (runtime))
(declare-function etaf-runtime-host-props-for "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-host-props-entries "etaf-runtime" (runtime))
(declare-function etaf-runtime-host-ancestries "etaf-runtime" (runtime host-refs))
(declare-function etaf-runtime-host-ancestor-refs "etaf-runtime" (runtime host-ref))
(declare-function etaf-runtime-event-begin "etaf-runtime" (runtime))
(declare-function etaf-runtime-event-end "etaf-runtime" (runtime))
(declare-function etaf-runtime-observer "etaf-runtime" (runtime))
(declare-function etaf-runtime-call-operation
                  "etaf-runtime" (runtime kind label function))
(declare-function etaf-runtime-host-node "etaf-runtime" (runtime ref))
(declare-function etaf-runtime-node-host-ref "etaf-runtime" (runtime node))
(declare-function etaf--keys-scope-root "etaf-keys" (runtime &optional from))

(define-error 'etaf-event-error "Invalid ETAF Event")

(defvar etaf--current-event nil
  "Event context active while one Runtime callback runs.")

(defvar etaf--drag-cancel-p nil
  "Non-nil while Ebox delivers the terminal cancellation of an active drag.")

(defvar etaf--event-bubbling nil
  "Non-nil while dispatching one event's ancestor capture callbacks.")

;;;###autoload
(defun etaf-call-with-input (reader)
  "Run native input READER for the current event's committed Host.
Call from an event callback; no Runtime or Host reference is needed.  Ebox
owns target validity and focus restoration, while READER owns the native
editing session.  Return its result only if the target is still valid.
Errors and user quit propagate; target invalidation signals a subtype of
`quit'.  No application value is applied by this function."
  (etaf--assert-not-rendering 'read-input)
  (unless etaf--current-event
    (signal 'etaf-event-error (list "Native input requires a Host event callback")))
  (let ((runtime (plist-get etaf--current-event :runtime))
        (host-ref (plist-get etaf--current-event :host-ref)))
    (ebox-call-with-input (etaf--event-host-node runtime host-ref) reader
                          (etaf-runtime-buffer runtime))))

(defun etaf--event-host-node (runtime host-ref)
  "Return RUNTIME's node for HOST-REF or signal `user-error'."
  (or (etaf-runtime-host-node runtime host-ref)
      (user-error "No committed ETAF Host %S" host-ref)))

;;;###autoload
(defun etaf-event-target-within-p (host-ref)
  "Return non-nil when the current event's target is HOST-REF or inside it.
Call from an event callback.  In an ancestor `:on-press-capture' callback the
target is the Host whose press callback ran; in any other callback it is the
callback's own Host.  HOST-REF is compared with `equal' against the target and
its committed Host ancestors, so a root shell can tell a press inside an open
panel from one on the surface around it.  Outside an event callback signal
`etaf-event-error'."
  (unless etaf--current-event
    (signal 'etaf-event-error
            (list "Event target lookup requires a Host event callback")))
  (let* ((runtime (plist-get etaf--current-event :runtime))
         (target (or (plist-get etaf--current-event :target-host-ref)
                     (plist-get etaf--current-event :host-ref))))
    (or (equal target host-ref)
        (and (member host-ref (etaf-runtime-host-ancestor-refs runtime target))
             t))))

(defun etaf-event-pointer-p ()
  "Return non-nil when the current event came from a pointer button.
Call from an event callback.  A press activated by a mouse or trackpad click
returns non-nil; keyboard activation (RET or SPC) and explicit dispatch of a
non-mouse input return nil.  Click-only policies such as dismissing a modal
from its backdrop use it so the keyboard never triggers them by accident.
Outside an event callback signal `etaf-event-error'."
  (unless etaf--current-event
    (signal 'etaf-event-error
            (list "Event source lookup requires a Host event callback")))
  (and (mouse-event-p last-input-event) t))

(defun etaf-event-kind (kind)
  "Normalize event KIND to a non-keyword symbol."
  (let ((name (cond
               ((keywordp kind) (substring (symbol-name kind) 1))
               ((symbolp kind) (symbol-name kind))
               ((stringp kind) kind)
               (t (signal 'etaf-event-error
                          (list (format "Invalid event kind: %S" kind)))))))
    (setq name (if (string-prefix-p "on-" name)
                   (substring name 3)
                 name))
    (intern name)))

(defun etaf--event-handler (runtime host-ref kind)
  "Return callback for HOST-REF and KIND in RUNTIME, or nil."
  (cdr (assq (etaf-event-kind kind)
             (etaf-runtime-handler-for runtime host-ref))))

(defun etaf--maybe-finish-input-session (runtime host-ref)
  "Finish RUNTIME's native input session when HOST-REF supersedes it.
A press on the session's own Host, inside it, or on the nearest Host that
frames it keeps editing.  The Runtime's registered
finisher receives RUNTIME and runs inside the press batch, so its
publication settles before the superseding callback runs."
  (when-let* ((finisher (etaf-runtime-input-finisher runtime))
              (session (ebox-input-active-p (etaf-runtime-buffer runtime)))
              (session-ref (etaf-runtime-node-host-ref
                            runtime (ebox-input-session-node session))))
    (unless (or (equal host-ref session-ref)
                (member session-ref
                        (etaf-runtime-host-ancestor-refs runtime host-ref))
                (equal host-ref
                       (car (etaf-runtime-host-ancestor-refs runtime session-ref))))
      (funcall finisher runtime))))

;;;###autoload
(cl-defun etaf-dispatch-event
    (runtime host-ref kind &optional payload (payload-p nil))
  "Dispatch KIND for HOST-REF through mounted RUNTIME.

  When PAYLOAD-P is non-nil, pass PAYLOAD as the callback's only argument;
otherwise call the local callback with no arguments."
  (etaf--assert-not-rendering 'dispatch-event)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let* ((dispatch
         (lambda ()
           (when (and (plist-get (etaf-runtime-host-props-for runtime host-ref) :disabled)
                      (not (and etaf--drag-cancel-p (eq (etaf-event-kind kind) 'drag))))
             (signal 'etaf-event-error
                     (list (format "Cannot dispatch to disabled Host reference: %S"
                                   host-ref))))
           (let* ((event-kind (etaf-event-kind kind))
                  (callback (etaf--event-handler runtime host-ref event-kind)))
             (unless callback
               (signal 'etaf-event-error
                       (list (format "No %S handler for Host reference %S"
                                     event-kind host-ref))))
             (let ((etaf--current-runtime runtime)
                   (etaf--current-event
                    (list :runtime runtime :host-ref host-ref
                          :kind event-kind :payload payload)))
               (etaf-runtime-event-begin runtime)
               (unwind-protect
                   (progn
                     ;; A press outside an open editing session finishes that
                     ;; session inside this batch, before the new callback
                     ;; runs; the session's own publication then drains when
                     ;; the batch ends.
                     (when (eq event-kind 'press)
                       (etaf--maybe-finish-input-session runtime host-ref))
                     (let ((result (if payload-p
                                       (funcall callback payload)
                                     (funcall callback))))
                     ;; UI shells can install a capture callback on an
                     ;; ancestor Host.  This keeps activation and focus
                     ;; policy out of every leaf component while preserving
                     ;; the target callback's return value.
                     (when (and (eq event-kind 'press)
                                (not etaf--event-bubbling))
                       (let ((etaf--event-bubbling t))
                         (dolist (ancestor
                                  (etaf-runtime-host-ancestor-refs
                                   runtime host-ref))
                           (when-let* ((capture
                                       (etaf--event-handler
                                        runtime ancestor 'press-capture)))
                             (let ((etaf--current-event
                                    (list :runtime runtime
                                          :host-ref ancestor
                                          :target-host-ref host-ref
                                          :kind 'press-capture
                                          :payload payload)))
                               (if payload-p
                                   (funcall capture payload)
                                 (funcall capture)))))))
                     result))
                 (etaf-runtime-event-end runtime))))))
         (run (lambda () (etaf-call-with-batch dispatch))))
    (if (or etaf--observer-context (etaf-runtime-observer runtime))
        (etaf-runtime-call-operation
         runtime 'event
         (format "%s %S" (etaf-event-kind kind) host-ref)
         run)
      (funcall run))))

;;;###autoload
(defun etaf-input-begin (runtime host-ref &rest options)
  "Begin native editing of text HOST-REF in mounted RUNTIME; return a session.
The Host's text becomes the session value.  Keys typed in the Runtime's
buffer edit it with their ordinary Emacs commands, undo and input methods
while the Host keeps its layout and shows each edit at once.  OPTIONS are
those of `ebox-input-begin': :on-change receives each new value, :on-leave
runs when a click lands outside the Host's box, :keymap holds bindings
consulted first and :local-variables configures the editing commands.

Publications continue during the session.  Publishing the session value into
the Host is a no-op, so :on-change may write it to application state; another
value replaces the session text.  A missing Host, an unmounted Runtime and a
second session on the same buffer are errors."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (apply #'ebox-input-begin (etaf-runtime-buffer runtime)
         (or (etaf-runtime-host-node runtime host-ref)
             (signal 'etaf-event-error
                     (list "No committed Host reference" host-ref)))
         options))

(defun etaf-input-text (session)
  "Return SESSION's current property-free value, or nil once it ended."
  (ebox-input-text session))

(defun etaf-input-end (session)
  "End SESSION and return its value; the Host keeps displaying it."
  (ebox-input-end session))

(defun etaf-input-active-p (&optional runtime)
  "Return RUNTIME's active input session, or nil.
RUNTIME defaults to the Runtime in the current buffer."
  (let ((runtime (or runtime (etaf-current-runtime))))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (ebox-input-active-p (etaf-runtime-buffer runtime)))))

(defun etaf-input-edit-command-add (command)
  "Add COMMAND to the commands that edit a native input session's text.
A command in this list that is bound in a session keymap edits the session
value; other session bindings run in the mounted buffer.  COMMAND must be a
command symbol; another value signals `wrong-type-argument'.  Return the
updated list."
  (unless (and (symbolp command) (commandp command))
    (signal 'wrong-type-argument (list 'commandp command)))
  (add-to-list 'ebox-input-edit-commands command))

(defun etaf-input-edit-command-remove (command)
  "Remove COMMAND from the native input session's text-editing commands.
COMMAND must be a command symbol; another value signals `wrong-type-argument'.
Return the updated list."
  (unless (and (symbolp command) (commandp command))
    (signal 'wrong-type-argument (list 'commandp command)))
  (setq ebox-input-edit-commands (delq command ebox-input-edit-commands)))

(defun etaf-host-ref-bounds (runtime host-ref)
  "Return live Ebox bounds for HOST-REF in mounted RUNTIME.
The (START . END) span runs from the Host's first visible painted cell to
the end of its last painted row.  A `:visibility hidden' Host in flow reports
its blank slot; the result is nil when the Host owns no cells."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when-let* ((node (etaf-runtime-host-node runtime host-ref)))
    (ebox-node-bounds node t)))

;;;###autoload
(defun etaf-host-ref-at (runtime &optional position predicate)
  "Return the explicit Host reference painted at POSITION in mounted RUNTIME.
Walk from the innermost Host covering POSITION (default point) outwards and
return the first `:ref' an application supplied; with PREDICATE, the first
one PREDICATE accepts.  Return nil when no such Host encloses POSITION."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (with-current-buffer (etaf-runtime-buffer runtime)
    (let ((node (ebox-node-at (or position (point))))
          (nodes (etaf-runtime-nodes runtime))
          found)
      (while (and node (not found))
        (let* ((seg (gethash node nodes))
               (ref (and seg (plist-get (etaf--host-props (etaf--seg-data seg)) :ref))))
          (if (and ref (or (null predicate) (funcall predicate ref)))
              (setq found ref)
            (setq node (ebox-node-parent node)))))
      found)))

;;;###autoload
(defun etaf-host-ref-size (runtime host-ref)
  "Return HOST-REF's committed painted size as (PIXELS . ROWS).
RUNTIME must be mounted.  Return nil for an absent or wholly hidden Host.
Margins and neighbouring columns are excluded; clipping reduces the result.
Use this read-only query to prepare resources after layout, not per frame."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when-let* ((node (etaf-runtime-host-node runtime host-ref))
              (geometry (ebox-node-geometry node))
              (width (plist-get geometry :width))
              (height (plist-get geometry :height)))
    (and (> width 0) (> height 0) (cons width height))))

(defun etaf-host-ref-position (runtime host-ref)
  "Return the first live Ebox position for HOST-REF in RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when-let* ((node (etaf-runtime-host-node runtime host-ref)))
    (ebox-node-position node)))

(defun etaf--scroll-node (runtime host-ref)
  "Return the Ebox node of HOST-REF in mounted RUNTIME or signal an error."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (or (etaf-runtime-host-node runtime host-ref)
      (error "ETAF Host %S is not mounted" host-ref)))

(defun etaf-scroll-offset (runtime host-ref)
  "Return the scroll offset in lines of HOST-REF in mounted RUNTIME."
  (ebox-node-scroll-offset (etaf--scroll-node runtime host-ref)))

(defun etaf-scroll-to (runtime host-ref offset)
  "Scroll HOST-REF in mounted RUNTIME to OFFSET and return the applied offset.
OFFSET is a line count, `start' or `end'; it is clamped to the content.
Reaching the end pins a `:scroll-anchor end' Host so it follows new content."
  (ebox-node-set-scroll (etaf--scroll-node runtime host-ref)
                        (pcase offset
                          ('start 0)
                          ('end most-positive-fixnum)
                          ((pred integerp) offset)
                          (_ (signal 'wrong-type-argument
                                     (list '(or integer (member start end)) offset))))))

(defun etaf-scroll-by (runtime host-ref delta)
  "Scroll HOST-REF in mounted RUNTIME by DELTA lines; return the new offset."
  (let ((node (etaf--scroll-node runtime host-ref)))
    (ebox-node-set-scroll node (+ (ebox-node-scroll-offset node) delta))))

(defun etaf-scroll-into-view (runtime host-ref &optional align)
  "Scroll the scrolling Hosts around HOST-REF in RUNTIME so it shows.
Each enclosing scroller moves the least distance; return HOST-REF.
ALIGN `start' or `end' aligns the Host's top with a scroller's first line
or its bottom with the last line instead."
  (ebox-node-scroll-into-view (etaf--scroll-node runtime host-ref) align)
  host-ref)

(defun etaf--dispatch-activation (runtime host-ref)
  "Dispatch an enabled committed HOST-REF activation in RUNTIME."
  (let ((focused (and (not (mouse-event-p last-input-event))
                      (etaf-focused-host-ref runtime))))
    ;; Text-property keymaps can precede the Runtime's emulation map.  If
    ;; point drifted onto another control, reenter native activation at the
    ;; live focus.  At its restored position the engine resolves inherited
    ;; keymaps normally, including callbackless and disabled boundaries.
    (if (and focused
             (not (eql (point) (etaf-host-ref-position runtime focused))))
        (etaf-activate runtime)
      (if (and (not (plist-get (etaf-runtime-host-props-for runtime host-ref) :disabled))
               (etaf--event-handler runtime host-ref 'press))
          (etaf-dispatch-event runtime host-ref 'press)
        (user-error "No interactive ETAF Host at point")))))

;;;###autoload
(defun etaf-activate (&optional runtime)
  "Dispatch `press' for the focused Host, or the interaction boundary at point.

RUNTIME is the mounted Runtime to activate, or nil for the current buffer.
Live focus wins even when publication or inspection displaced point."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (with-current-buffer (etaf-runtime-buffer runtime)
    ;; Publication and inspection may move point without changing focus.
    ;; Restore its live position before entering the engine's native keymap.
    (when-let* ((ref (etaf-focused-host-ref runtime)))
      (etaf-focus runtime ref))
    (ebox-activate)))

;;;###autoload
(defun etaf-focus (&optional runtime host-ref)
  "Move focus to HOST-REF in mounted RUNTIME and move point to its position.

Ebox owns focus and its publication lifecycle.  Without HOST-REF, select the
first eligible tab stop without changing existing focus if no stop exists.
Invalid explicit targets signal `etaf-event-error'.  Tab index affects only
navigation; a negative or absent index permits explicit focus."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((buffer (etaf-runtime-buffer runtime)))
    (condition-case condition
        (if host-ref
            (ebox-focus (or (etaf-runtime-host-node runtime host-ref)
                            (signal 'etaf-event-error
                                    (list "No committed Host reference" host-ref)))
                        buffer)
          (ebox-focus-first buffer))
      (user-error
       (if host-ref
           (signal 'etaf-event-error (cdr condition))
         (signal (car condition) (cdr condition)))))))

;;;###autoload
(defun etaf-focused-host-ref (&optional runtime)
  "Return the currently focused Host reference in mounted RUNTIME."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when-let* ((node (ebox-focused-node (etaf-runtime-buffer runtime))))
    (etaf-runtime-node-host-ref runtime node)))

;;;###autoload
(defun etaf-focus-next (&optional runtime)
  "Focus the next visible Host in mounted RUNTIME's keyboard scope."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let* ((buffer (etaf-runtime-buffer runtime))
         (root (etaf--keys-scope-root runtime)))
    (if (eq root (ebox-focus-scope buffer))
        (ebox-focus-next 1 t buffer)
      (ebox-focus-within root 1 t buffer))))

;;;###autoload
(defun etaf-focus-previous (&optional runtime)
  "Focus the previous visible Host in mounted RUNTIME's keyboard scope."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let* ((buffer (etaf-runtime-buffer runtime))
         (root (etaf--keys-scope-root runtime)))
    (if (eq root (ebox-focus-scope buffer))
        (ebox-focus-previous 1 t buffer)
      (ebox-focus-within root -1 t buffer))))

;;;###autoload
(defun etaf-focus-within (runtime host-ref &optional count)
  "Focus a stop inside HOST-REF's committed subtree in RUNTIME.
Nil COUNT selects the first stop.  Integer COUNT moves forward or backward
with wrapping; zero queries current focus membership.  Ebox owns ordering,
visibility and retained identity.  Missing roots or stops signal `user-error'.
This creates no persistent focus restriction or additional input bindings."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (ebox-focus-within (etaf--event-host-node runtime host-ref) count t
                     (etaf-runtime-buffer runtime)))

(provide 'etaf-events)

;;; etaf-events.el ends here
