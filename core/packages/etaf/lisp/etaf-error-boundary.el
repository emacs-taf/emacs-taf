;;; etaf-error-boundary.el --- Declarative error boundary Component -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Persistent declarative `etaf-error-boundary' Component that isolates render,
;; reactive update, lifecycle hook, and event/key callback errors inside its
;; subtree.  On error (never `quit'), the broken child subtree is disposed, an
;; optional `:on-error' callback receives `(:error CONDITION :phase PHASE :name
;; NAME)', and `:fallback' renders in place with a zero-argument RESET callback
;; that clears the error and remounts the children cleanly.

;;; Code:

(require 'cl-lib)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-reactive)
(require 'etaf-runtime)

(cl-defstruct (etaf--boundary (:constructor etaf--boundary-make) (:copier nil))
  "Mounted state of one `etaf-error-boundary' Component instance."
  seg error-ref attempt-ref fallback-ref error-cb-ref name-ref
  tripping-seg active-p)

(defun etaf--boundary-live-name (boundary)
  "Return BOUNDARY's current diagnostic `:name' value without tracking."
  (when-let* ((ref (etaf--boundary-name-ref boundary)))
    (etaf-untracked (etaf-value ref))))

(defun etaf--boundary-info (boundary err phase)
  "Build the diagnostic info plist for BOUNDARY catching ERR in PHASE."
  (list :error err
        :phase phase
        :name (etaf--boundary-live-name boundary)))

(defun etaf--boundary-seg-under-p (seg ancestor)
  "Return non-nil when SEG equals or descends from ANCESTOR."
  (let ((cursor seg) found)
    (while (and cursor (not found))
      (if (eq cursor ancestor)
          (setq found t)
        (setq cursor (etaf--seg-parent cursor))))
    found))

(defun etaf--boundary-for-seg (seg &optional include-self)
  "Return the nearest active enclosing `etaf--boundary' for SEG, or nil.
Unless INCLUDE-SELF is non-nil, search strictly above SEG.  An already-tripped
boundary is skipped so errors inside its `:fallback' bubble outward, unless
SEG belongs to the dying child subtree currently being unmounted by that
boundary."
  (let ((cursor (if include-self seg (and seg (etaf--seg-parent seg))))
        found)
    (while (and cursor (not found))
      (when-let* ((boundary (gethash cursor etaf--seg-boundaries)))
        (when (etaf--boundary-active-p boundary)
          (let ((tripped (etaf-ref-value (etaf--boundary-error-ref boundary)))
                (dying (etaf--boundary-tripping-seg boundary)))
            (cond
             ((null tripped)
              (setq found boundary))
             ((and dying (etaf--boundary-seg-under-p seg dying))
              (setq found boundary))))))
      (setq cursor (etaf--seg-parent cursor)))
    found))

(defun etaf--boundary-for-host (runtime host-ref)
  "Return the nearest active `etaf--boundary' enclosing HOST-REF in RUNTIME."
  (when-let* ((seg (etaf--runtime-host-seg runtime host-ref)))
    (etaf--boundary-for-seg seg nil)))

(defun etaf--boundary-for-effect (effect)
  "Return the nearest active `etaf--boundary' enclosing reactive EFFECT."
  (let* ((owner (etaf-effect-owner effect))
         (seg (cond
               ((etaf--seg-p owner) owner)
               ((etaf--instance-p owner) (etaf--instance-seg owner))
               ((etaf-effect-home effect)
                (gethash (etaf-effect-home effect) etaf--scope-segments)))))
    (when seg
      (etaf--boundary-for-seg seg nil))))

(defun etaf--boundary-notify (boundary info)
  "Invoke BOUNDARY's optional `:on-error' callback with INFO outside render."
  (when-let* ((cb-ref (etaf--boundary-error-cb-ref boundary))
              (on-error (etaf-untracked (etaf-value cb-ref))))
    (when (functionp on-error)
      (let ((etaf--render-phase-p nil))
        (funcall on-error info)))))

(defun etaf--boundary-reset (boundary)
  "Clear BOUNDARY's caught error and remount its children cleanly."
  (when (etaf--boundary-active-p boundary)
    (etaf-call-with-batch
     (lambda ()
       (setf (etaf--boundary-tripping-seg boundary) nil)
       (etaf-set-value (etaf--boundary-error-ref boundary) nil)
       (etaf-set-value (etaf--boundary-attempt-ref boundary)
                       (1+ (etaf-ref-value (etaf--boundary-attempt-ref boundary))))))))

(defun etaf--boundary-render-fallback (boundary info)
  "Return the fallback View for BOUNDARY given diagnostic INFO."
  (let* ((fb-ref (etaf--boundary-fallback-ref boundary))
         (fallback (and fb-ref (etaf-untracked (etaf-value fb-ref))))
         (reset (lambda () (etaf--boundary-reset boundary)))
         (view (cond
                ((functionp fallback)
                 (funcall fallback info reset))
                ((stringp fallback)
                 (etaf-node 'box (list :role 'alert)
                            (list (etaf-node 'text nil (list fallback)))))
                (fallback fallback)
                (t
                 (let ((label (or (plist-get info :name) "error-boundary"))
                       (msg (error-message-string (plist-get info :error))))
                   (etaf-node 'box (list :role 'alert)
                              (list (etaf-node 'text nil
                                               (list (format "Error in %s: %s"
                                                             label msg))))))))))
    view))

(defun etaf--boundary-trip (boundary err phase)
  "Trip BOUNDARY with condition ERR from PHASE, scheduling fallback render.
If BOUNDARY is already tripping for its dying child subtree, suppress without
overwriting the primary error.  Return t."
  (when (and boundary (etaf--boundary-active-p boundary))
    (let ((err-ref (etaf--boundary-error-ref boundary)))
      (unless (etaf-ref-value err-ref)
        (let* ((bseg (etaf--boundary-seg boundary))
               (info (etaf--boundary-info boundary err phase)))
          (setf (etaf--boundary-tripping-seg boundary)
                (car (etaf--seg-kids bseg)))
          (etaf-set-value err-ref info)
          (etaf--boundary-notify boundary info)))))
  t)

(defun etaf--boundary-handle-sync-error (seg err)
  "Handle synchronous render/mount condition ERR on boundary segment SEG.
Disposes partial kids, records ERR without failing the outer mount or sibling
subtrees, invokes `:on-error', and mounts the fallback immediately."
  (let ((boundary (gethash seg etaf--seg-boundaries)))
    (unless (and boundary
                 (etaf--boundary-active-p boundary)
                 (null (etaf-ref-value (etaf--boundary-error-ref boundary))))
      (signal (car err) (cdr err)))
    (dolist (kid (etaf--seg-kids seg))
      (etaf--dispose kid (etaf--seg-live seg)))
    (setf (etaf--seg-kids seg) nil
          (etaf--boundary-tripping-seg boundary) nil)
    (let ((info (etaf--boundary-info boundary err 'render)))
      (etaf--ref-install (etaf--boundary-error-ref boundary) info)
      (etaf--boundary-notify boundary info)
      (let* ((inst (etaf--seg-data seg))
             (view (etaf--ctx-call
                    (etaf--instance-ctx inst)
                    (lambda () (etaf--boundary-render-fallback boundary info)))))
        (etaf--comp-show seg view)))))

(defun etaf--boundary-handle-effect-error (effect err)
  "Runtime effect-error hook: isolate non-`quit' EFFECT errors in a boundary."
  (unless (eq (car err) 'quit)
    (when-let* ((boundary (etaf--boundary-for-effect effect)))
      (etaf--boundary-trip boundary err 'update))))

(defun etaf--boundary-handle-hook-error (inst err)
  "Runtime lifecycle-hook error handler: isolate non-`quit' hook errors."
  (unless (eq (car err) 'quit)
    (when-let* ((seg (and inst (etaf--instance-seg inst)))
                (boundary (etaf--boundary-for-seg seg nil)))
      (etaf-call-with-batch
       (lambda () (etaf--boundary-trip boundary err 'update)))
      t)))

(defun etaf--boundary-setup (err-ref attempt-ref fallback-ref error-cb-ref name-ref)
  "Register a mounted `etaf--boundary' record for the current Component setup."
  (let* ((inst etaf--current-component-instance)
         (seg (and inst (etaf--instance-seg inst)))
         (boundary (etaf--boundary-make
                    :seg seg
                    :error-ref err-ref
                    :attempt-ref attempt-ref
                    :fallback-ref fallback-ref
                    :error-cb-ref error-cb-ref
                    :name-ref name-ref
                    :active-p t)))
    (when seg
      (puthash seg boundary etaf--seg-boundaries)
      (etaf-on-unmounted
       (lambda ()
         (setf (etaf--boundary-active-p boundary) nil
               (etaf--boundary-tripping-seg boundary) nil)
         (remhash seg etaf--seg-boundaries))))
    boundary))

(setq etaf--effect-error-function #'etaf--boundary-handle-effect-error
      etaf--boundary-sync-error-function #'etaf--boundary-handle-sync-error
      etaf--boundary-hook-error-function #'etaf--boundary-handle-hook-error)

(etaf-define-component etaf-error-boundary (&key fallback on-error name)
  "Isolate render, reactive update, lifecycle, and event errors in children.

FALLBACK is a View, string, nil (default alert), or a function `(INFO RESET)'
returning a fallback View, where INFO is `(:error CONDITION :phase PHASE :name
NAME)' (`PHASE' is `render', `update', or `event') and RESET is a zero-argument
function that clears the error and remounts the children cleanly.
ON-ERROR, when supplied, is called with INFO when an error is caught.
NAME is an optional symbol or string carried in INFO for diagnostics.
User interrupts (`quit') are never caught."
  :bindings ((err-ref (etaf-ref nil :name 'etaf-error-boundary-error))
             (attempt-ref (etaf-ref 0 :name 'etaf-error-boundary-attempt))
             (boundary (etaf--boundary-setup
                        err-ref attempt-ref
                        (etaf-prop :fallback)
                        (etaf-prop :on-error)
                        (etaf-prop :name))))
  :validate
  (progn
    (etaf-check-prop :fallback fallback
                     (or (null fallback) (stringp fallback) (functionp fallback)
                         (etaf--view-node-p fallback)
                         (etaf--component-call-p fallback)
                         (proper-list-p fallback))
                     "a View, string, function, or nil" 'etaf-error-boundary)
    (etaf-check-prop :on-error on-error
                     (or (null on-error) (functionp on-error))
                     "a function or nil" 'etaf-error-boundary)
    (etaf-check-prop :name name
                     (or (null name) (symbolp name) (stringp name))
                     "a symbol, string, or nil" 'etaf-error-boundary))
  :render
  (let ((info (etaf-value err-ref))
        (attempt (etaf-value attempt-ref)))
    (if info
        (progn
          (setf (etaf--boundary-tripping-seg boundary) nil)
          (etaf--boundary-render-fallback boundary info))
      (etaf-view
       (fragment :key attempt
         (slot))))))

(provide 'etaf-error-boundary)
;;; etaf-error-boundary.el ends here
