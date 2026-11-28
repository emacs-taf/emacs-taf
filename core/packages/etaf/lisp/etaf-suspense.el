;;; etaf-suspense.el --- Declarative async Suspense boundary for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Declarative `<Suspense>' boundary aggregating one or more `etaf-resource' or
;; `etaf-data-controller' sources.  Shows `:fallback' while any source is
;; loading (with optional anti-flicker `:delay'), `:error-fallback' when a
;; source fails and an error fallback is supplied, and projects its default
;; slot children once settled.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)
(require 'etaf-resource)
(require 'etaf-data)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-runtime)

(defun etaf-suspense--resolve-sources (resources)
  "Resolve RESOURCES into a flat list of Resources or Data Controllers."
  (let ((raw (cond
              ((or (etaf-ref-p resources) (etaf-computed-p resources))
               (etaf-value resources))
              ((functionp resources) (funcall resources))
              (t resources))))
    (cond
     ((null raw) nil)
     ((or (etaf-resource-p raw) (etaf-data-controller-p raw)) (list raw))
     ((proper-list-p raw) (delq nil raw))
     (t (etaf--component-error
         "etaf-suspense :resources must be a Resource, Data Controller, or list: %S"
         raw)))))

(defun etaf-suspense--source-status (source)
  "Read reactive status symbol of Resource or Data Controller SOURCE."
  (cond
   ((etaf-resource-p source) (etaf-resource-status source))
   ((etaf-data-controller-p source) (etaf-value (etaf-data-status source)))
   (t (etaf--component-error
       "Unsupported etaf-suspense source: %S" source))))

(defun etaf-suspense--source-error (source)
  "Read reactive error condition of Resource or Data Controller SOURCE."
  (cond
   ((etaf-resource-p source) (etaf-resource-error source))
   ((etaf-data-controller-p source) (etaf-value (etaf-data-error source)))
   (t nil)))

(defun etaf-suspense--render-fallback (spec &optional arg)
  "Render fallback SPEC (nil, string, View, or function receiving optional ARG)."
  (cond
   ((null spec) nil)
   ((functionp spec)
    (if arg (funcall spec arg) (funcall spec)))
   (t spec)))

(etaf-define-component etaf-suspense (&key resources fallback (delay 0) error-fallback)
  "Aggregate async loading across RESOURCES and render FALLBACK while pending.
RESOURCES is an `etaf-resource', an `etaf-data-controller', a list of them, or
a reactive source/function returning them.  While any source is in `loading' or
`idle' status, displays FALLBACK (waiting DELAY seconds first when DELAY > 0 to
avoid loading-skeleton flicker on fast hits).  `refreshing' keeps showing ready
children.  When any source has status `error' and ERROR-FALLBACK is supplied,
renders ERROR-FALLBACK (called with the non-nil list of errors if a function)."
  :validate
  (progn
    (etaf-check-prop :delay delay (and (numberp delay) (>= delay 0))
                     "a nonnegative number"))
  :bindings
  ((delay-ready (etaf-ref (<= delay 0) :name 'etaf-suspense-delay-ready))
   (pending-box (list nil)))
  :setup
  (let ((timer nil)
        (active-p t))
    (letrec
        ((cancel-delay
          (lambda ()
            (when (timerp timer)
              (cancel-timer timer)
              (setq timer nil))))
         (sync-delay
          (lambda ()
            (when (and active-p (> delay 0))
              (if (car pending-box)
                  (unless (or (etaf-untracked (etaf-value delay-ready))
                              (timerp timer))
                    (setq timer
                          (run-with-timer
                           delay nil
                           (lambda ()
                             (setq timer nil)
                             (when (and active-p (car pending-box))
                               (etaf-set-value delay-ready t))))))
                (funcall cancel-delay)
                (when (etaf-untracked (etaf-value delay-ready))
                  (etaf-set-value delay-ready nil)))))))
      (etaf-on-mounted sync-delay)
      (etaf-on-updated sync-delay)
      (etaf-on-unmounted
       (lambda ()
         (setq active-p nil)
         (funcall cancel-delay)))))
  :render
  (let* ((items (etaf-suspense--resolve-sources resources))
         (pending nil)
         (errors nil))
    (dolist (item items)
      (let ((st (etaf-suspense--source-status item)))
        (cond
         ((memq st '(loading idle)) (setq pending t))
         ((eq st 'error)
          (push (or (etaf-suspense--source-error item) '(error "Resource error"))
                errors)))))
    (setcar pending-box pending)
    (setq errors (nreverse errors))
    (cond
     (pending
      (if (or (<= delay 0) (etaf-value delay-ready))
          (etaf-suspense--render-fallback fallback)
        nil))
     ((and errors error-fallback)
      (etaf-suspense--render-fallback error-fallback errors))
     (t
      (let ((kids (etaf-current-slot 'default)))
        (cond
         ((null kids) nil)
         ((null (cdr kids)) (car kids))
         (t (etaf-node 'fragment nil kids))))))))

(provide 'etaf-suspense)
;;; etaf-suspense.el ends here
