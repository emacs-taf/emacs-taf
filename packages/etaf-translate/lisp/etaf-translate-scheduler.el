;;; etaf-translate-scheduler.el --- Viewport-first async batch scheduler -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Live viewport-first priority scheduler for `etaf-translate'.  Queries live
;; Host geometries (including `:overflow scroll' offsets and clipping bands)
;; via `etaf-runtime-host-geometries', dispatches visible and prefetch units
;; across bounded concurrent batches with streaming per-unit delivery, keeps
;; far off-screen units deferred without ghost loading placeholders, dynamically
;; re-prioritizes on scroll, auto-retries transient async failures, and cancels
;; obsolete work cleanly on disable or Runtime unmount.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ext)
(require 'etaf-translate-core)
(require 'etaf-translate-cache)
(require 'etaf-translate-engine)
(require 'etaf-translate-extract)

(cl-defstruct (etaf-translate-sched
               (:constructor etaf-translate-sched--make))
  "Per-session asynchronous batch translation scheduler."
  runtime
  cache
  engine-name
  fallback-engine
  prompt-style
  context
  source-lang
  target-lang
  glossary
  glossary-hash
  on-unit-ready     ; (lambda (unit translated) ...)
  on-unit-error     ; (lambda (unit error-msg) ...)
  on-units-queued   ; (lambda (units) ...)
  on-units-deferred ; (lambda (units) ...)
  on-state-change   ; (lambda () ...)
  (generation 0)
  (started-p nil)
  (pending nil)     ; ordered list of active queued units ready to dispatch
  (deferred nil)    ; off-screen units held until scrolled near viewport
  (queued-ids (make-hash-table :test #'eql))
  (active-ids (make-hash-table :test #'eql))
  (retry-counts (make-hash-table :test #'eql))
  (solo-ids (make-hash-table :test #'eql))
  (fallback-used (make-hash-table :test #'eql))
  (in-flight 0)
  (in-flight-units 0)
  (cancellers nil)) ; list of active cancel thunks (requests + retry timers)

(defun etaf-translate-sched-create (&rest args)
  "Create a scheduler from keyword ARGS."
  (apply #'etaf-translate-sched--make args))

(defun etaf-translate-sched-cancel (sched)
  "Cancel all queued and in-flight work on SCHED and advance its generation."
  (cl-incf (etaf-translate-sched-generation sched))
  (let ((cancellers (etaf-translate-sched-cancellers sched)))
    (setf (etaf-translate-sched-cancellers sched) nil
          (etaf-translate-sched-pending sched) nil
          (etaf-translate-sched-deferred sched) nil
          (etaf-translate-sched-in-flight sched) 0
          (etaf-translate-sched-in-flight-units sched) 0
          (etaf-translate-sched-started-p sched) nil)
    (clrhash (etaf-translate-sched-queued-ids sched))
    (clrhash (etaf-translate-sched-active-ids sched))
    (clrhash (etaf-translate-sched-retry-counts sched))
    (clrhash (etaf-translate-sched-solo-ids sched))
    (clrhash (etaf-translate-sched-fallback-used sched))
    (dolist (cancel cancellers)
      (when (functionp cancel)
        (ignore-errors (funcall cancel))))))

(defun etaf-translate-sched--live-geometries (runtime units)
  "Return hash table mapping integer Host IDs in UNITS to live geometry plists."
  (let ((table (make-hash-table :test #'eql))
        (ids nil))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (dolist (u units)
        (let ((hid (etaf-translate-unit-host-id u)))
          (when (integerp hid)
            (push hid ids))))
      (when ids
        (let* ((ordered (nreverse ids))
               (ctx (etaf-ext-context 'etaf-translate runtime))
               (geos (if ctx
                         (etaf-ext-geometries ctx ordered)
                       (etaf-runtime-host-geometries runtime ordered))))
          (dolist (entry geos)
            (puthash (car entry) (cdr entry) table)))))
    table))

(defun etaf-translate-sched--classify-unit (unit geo-table)
  "Return `(TIER . SORT-KEY)' for UNIT using live GEO-TABLE.
TIER 0 is currently visible, TIER 1 is inside the prefetch band, TIER 2 is
off-screen and deferred."
  (let* ((hid (etaf-translate-unit-host-id unit))
         (live (and (integerp hid) (gethash hid geo-table)))
         (geo (or live (etaf-translate-unit-geometry unit))))
    (cond
     ((null geo) (cons 0 0))
     ((and live (plist-get live :clip-top) (plist-get live :clip-bottom))
      (let* ((y (or (plist-get live :y) 0))
             (h (max 1 (or (plist-get live :height) 1)))
             (ct (plist-get live :clip-top))
             (cb (plist-get live :clip-bottom))
             (pad (max 0 etaf-translate-prefetch-lines))
             (up-pad (/ pad 2)))
        (cond
         ((plist-get live :visible-p)
          (cons 0 y))
         ((and (>= y cb) (<= (- y cb) pad))
          ;; Below viewport within prefetch band: closest ahead first.
          (cons 1 (- y cb)))
         ((and (<= (+ y h) ct) (<= (- ct (+ y h)) up-pad))
          ;; Above viewport within half prefetch band: after downward prefetch.
          (cons 1 (+ pad 1 (- ct (+ y h)))))
         (t
          (cons 2 y)))))
     (t
      ;; Unbounded headless buffer or virtualized provider without clip band.
      (cons 0 (or (plist-get geo :y) 0))))))

(defun etaf-translate-sched--partition (runtime units)
  "Partition UNITS into `(TIER0 TIER1 TIER2)' sorted by live viewport priority."
  (let ((geo-table (etaf-translate-sched--live-geometries runtime units))
        (t0 nil)
        (t1 nil)
        (t2 nil))
    (dolist (unit units)
      (let* ((cls (etaf-translate-sched--classify-unit unit geo-table))
             (tier (car cls))
             (key (cdr cls)))
        (pcase tier
          (0 (push (cons key unit) t0))
          (1 (push (cons key unit) t1))
          (_ (push unit t2)))))
    (setq t0 (mapcar #'cdr (sort (nreverse t0) (lambda (a b) (< (car a) (car b)))))
          t1 (mapcar #'cdr (sort (nreverse t1) (lambda (a b) (< (car a) (car b)))))
          t2 (nreverse t2))
    (list t0 t1 t2)))

(defun etaf-translate-sched-enqueue (sched units)
  "Enqueue UNITS on SCHED with live viewport-first prioritization.
Cached units resolve immediately via `:on-unit-ready' without scheduling I/O.
Only visible and prefetch units enter the active queue; far off-screen units
stay deferred until scrolled near the viewport.  Return async unit count."
  (let* ((runtime (etaf-translate-sched-runtime sched))
         (cache (etaf-translate-sched-cache sched))
         (src (etaf-translate-sched-source-lang sched))
         (tgt (etaf-translate-sched-target-lang sched))
         (eng (etaf-translate-sched-engine-name sched))
         (ghash (etaf-translate-sched-glossary-hash sched))
         (queued (etaf-translate-sched-queued-ids sched))
         (active (etaf-translate-sched-active-ids sched))
         (to-schedule nil)
         (need-async 0))
    (dolist (unit units)
      (let* ((hid (etaf-translate-unit-host-id unit))
             (key (etaf-translate-cache-key
                   (etaf-translate-unit-markup-text unit) src tgt eng ghash))
             (hit (etaf-translate-cache-get cache key)))
        (cond
         (hit
          (funcall (etaf-translate-sched-on-unit-ready sched) unit hit))
         ((gethash hid queued) nil)
         (t
          (puthash hid t queued)
          (cl-incf need-async)
          (push unit to-schedule)))))
    (when to-schedule
      (pcase-let ((`(,tier0 ,tier1 ,tier2)
                   (etaf-translate-sched--partition runtime (nreverse to-schedule))))
        (let ((newly-active (append tier0 tier1)))
          (dolist (u newly-active)
            (puthash (etaf-translate-unit-host-id u) t active))
          (setf (etaf-translate-sched-pending sched)
                (append tier0
                        (etaf-translate-sched-pending sched)
                        tier1)
                (etaf-translate-sched-deferred sched)
                (append (etaf-translate-sched-deferred sched) tier2))
          (when (and newly-active (etaf-translate-sched-on-units-queued sched))
            (funcall (etaf-translate-sched-on-units-queued sched) newly-active)))))
    (etaf-translate-sched--pump sched)
    need-async))

(defun etaf-translate-sched-promote-visible (sched)
  "Re-classify pending and deferred units against live viewport geometry.
Newly visible units jump to the front of the active queue; unstarted units
scrolled far off-screen move back to deferred."
  (let* ((runtime (etaf-translate-sched-runtime sched))
         (pool (append (etaf-translate-sched-pending sched)
                       (etaf-translate-sched-deferred sched))))
    (when (and pool (etaf-runtime-mounted-p runtime))
      (pcase-let ((`(,tier0 ,tier1 ,tier2)
                   (etaf-translate-sched--partition runtime pool)))
        (let ((active (etaf-translate-sched-active-ids sched))
              (next-pending (append tier0 tier1))
              (newly-queued nil)
              (newly-deferred nil))
          (dolist (u next-pending)
            (let ((hid (etaf-translate-unit-host-id u)))
              (unless (gethash hid active)
                (puthash hid t active)
                (push u newly-queued))))
          (dolist (u tier2)
            (let ((hid (etaf-translate-unit-host-id u)))
              (when (gethash hid active)
                (remhash hid active)
                (push u newly-deferred))))
          (setf (etaf-translate-sched-pending sched) next-pending
                (etaf-translate-sched-deferred sched) tier2)
          (when (and newly-deferred (etaf-translate-sched-on-units-deferred sched))
            (funcall (etaf-translate-sched-on-units-deferred sched)
                     (nreverse newly-deferred)))
          (when (and newly-queued (etaf-translate-sched-on-units-queued sched))
            (funcall (etaf-translate-sched-on-units-queued sched)
                     (nreverse newly-queued)))
          (etaf-translate-sched--pump sched))))))

(defun etaf-translate-sched--take-batch (sched engine-spec)
  "Pop the next batch of units from SCHED respecting ENGINE-SPEC limits."
  (let* ((solo-ids (etaf-translate-sched-solo-ids sched))
         (head (car (etaf-translate-sched-pending sched))))
    (if (and head (gethash (etaf-translate-unit-host-id head) solo-ids))
        (progn
          (remhash (etaf-translate-unit-host-id head) solo-ids)
          (list (pop (etaf-translate-sched-pending sched))))
      (let* ((supports-batch (plist-get engine-spec :supports-batch))
             (first-fast (and (not (etaf-translate-sched-started-p sched))
                              (zerop (etaf-translate-sched-in-flight sched))))
             (base-units (if supports-batch (max 1 etaf-translate-batch-max-units) 1))
             (base-chars (max 200 (min (or (plist-get engine-spec :max-chars)
                                           etaf-translate-batch-max-chars)
                                       etaf-translate-batch-max-chars)))
             (max-units (if first-fast (min base-units 2) base-units))
             (max-chars (if first-fast (min base-chars 500) base-chars))
             (batch nil)
             (chars 0)
             (count 0))
        (setf (etaf-translate-sched-started-p sched) t)
        (while (and (etaf-translate-sched-pending sched)
                    (< count max-units)
                    (or (zerop count)
                        (and (not (gethash (etaf-translate-unit-host-id
                                            (car (etaf-translate-sched-pending sched)))
                                           solo-ids))
                             (<= (+ chars (length (etaf-translate-unit-markup-text
                                                   (car (etaf-translate-sched-pending sched)))))
                                 max-chars))))
          (let ((u (pop (etaf-translate-sched-pending sched))))
            (push u batch)
            (cl-incf count)
            (cl-incf chars (length (etaf-translate-unit-markup-text u)))))
        (nreverse batch)))))

(defun etaf-translate-sched--pump (sched)
  "Start queued translation batches up to `etaf-translate-max-concurrency'."
  (let ((limit (max 1 etaf-translate-max-concurrency))
        (engine-spec (etaf-translate--engine-require
                      (etaf-translate-sched-engine-name sched))))
    (while (and (etaf-translate-sched-pending sched)
                (< (etaf-translate-sched-in-flight sched) limit))
      (let ((batch (etaf-translate-sched--take-batch sched engine-spec)))
        (when batch
          (etaf-translate-sched--dispatch-batch sched engine-spec batch))))))

(defun etaf-translate-sched--schedule-retry (sched unit delay)
  "Re-queue UNIT as a solo request on SCHED after DELAY seconds."
  (let* ((gen (etaf-translate-sched-generation sched))
         (hid (etaf-translate-unit-host-id unit))
         (cancel-cell (list nil)))
    (puthash hid t (etaf-translate-sched-solo-ids sched))
    (if (<= delay 0)
        (progn
          (setf (etaf-translate-sched-pending sched)
                (cons unit (etaf-translate-sched-pending sched)))
          (etaf-translate-sched--pump sched))
      (let* ((timer
              (run-at-time
               delay nil
               (lambda ()
                 (when (car cancel-cell)
                   (setf (etaf-translate-sched-cancellers sched)
                         (delq (car cancel-cell)
                               (etaf-translate-sched-cancellers sched))))
                 (when (and (eql gen (etaf-translate-sched-generation sched))
                            (etaf-runtime-mounted-p
                             (etaf-translate-sched-runtime sched)))
                   (setf (etaf-translate-sched-pending sched)
                         (cons unit (etaf-translate-sched-pending sched)))
                   (etaf-translate-sched--pump sched)))))
             (cancel (lambda () (cancel-timer timer))))
        (setcar cancel-cell cancel)
        (push cancel (etaf-translate-sched-cancellers sched))))))

(defun etaf-translate-sched--dispatch-batch (sched engine-spec batch &optional using-fallback-p)
  "Send BATCH through ENGINE-SPEC and deliver results to SCHED callbacks.
When USING-FALLBACK-P is non-nil, BATCH is already running on the fallback
engine and will not cascade again."
  (let* ((gen (etaf-translate-sched-generation sched))
         (translate-fn (plist-get engine-spec :translate))
         (src (etaf-translate-sched-source-lang sched))
         (tgt (etaf-translate-sched-target-lang sched))
         (eng (etaf-translate-sched-engine-name sched))
         (fallback-name (or (etaf-translate-sched-fallback-engine sched)
                            (plist-get engine-spec :fallback)))
         (glossary (etaf-translate-sched-glossary sched))
         (ghash (etaf-translate-sched-glossary-hash sched))
         (cache (etaf-translate-sched-cache sched))
         (batch-len (length batch))
         (delivered (make-vector batch-len nil))
         (settled nil)
         (in-sync-start t)
         (cancel-cell (list nil)))
    (cl-incf (etaf-translate-sched-in-flight sched))
    (cl-incf (etaf-translate-sched-in-flight-units sched) batch-len)
    (let* ((deliver-unit
            (lambda (idx translated)
              (when (and (<= 0 idx) (< idx batch-len)
                         (not (aref delivered idx))
                         (stringp translated))
                (aset delivered idx t)
                (when (eql gen (etaf-translate-sched-generation sched))
                  (setf (etaf-translate-sched-in-flight-units sched)
                        (max 0 (1- (etaf-translate-sched-in-flight-units sched)))))
                (let* ((unit (nth idx batch))
                       (hid (etaf-translate-unit-host-id unit))
                       (key (etaf-translate-cache-key
                             (etaf-translate-unit-markup-text unit)
                             src tgt eng ghash)))
                  (remhash hid (etaf-translate-sched-queued-ids sched))
                  (remhash hid (etaf-translate-sched-active-ids sched))
                  (remhash hid (etaf-translate-sched-retry-counts sched))
                  (remhash hid (etaf-translate-sched-solo-ids sched))
                  (remhash hid (etaf-translate-sched-fallback-used sched))
                  (etaf-translate-cache-put cache key translated)
                  (funcall (etaf-translate-sched-on-unit-ready sched)
                           unit translated)))))
           (undelivered-units
            (lambda ()
              (cl-loop for unit in batch
                       for idx from 0
                       unless (aref delivered idx)
                       collect unit)))
           (handle-remaining-failure
            (lambda (remaining msg split-sync-p)
              (dolist (unit remaining)
                (let* ((hid (etaf-translate-unit-host-id unit))
                       (retries (gethash hid (etaf-translate-sched-retry-counts sched) 0))
                       (can-retry (and (not using-fallback-p)
                                       (< retries (max 0 etaf-translate-auto-retry-count))
                                       (or split-sync-p (not in-sync-start))))
                       (fb-spec (and (not using-fallback-p)
                                     fallback-name
                                     (not (eq fallback-name eng))
                                     (not (gethash hid (etaf-translate-sched-fallback-used sched)))
                                     (ignore-errors
                                       (etaf-translate--engine-require fallback-name)))))
                  (cond
                   (can-retry
                    (puthash hid (1+ retries)
                             (etaf-translate-sched-retry-counts sched))
                    (etaf-translate-sched--schedule-retry
                     sched unit (if split-sync-p 0 0.5)))
                   (fb-spec
                    (puthash hid t (etaf-translate-sched-fallback-used sched))
                    (etaf-translate-sched--dispatch-batch
                     sched fb-spec (list unit) t))
                   (t
                    (remhash hid (etaf-translate-sched-queued-ids sched))
                    (remhash hid (etaf-translate-sched-active-ids sched))
                    (remhash hid (etaf-translate-sched-retry-counts sched))
                    (remhash hid (etaf-translate-sched-solo-ids sched))
                    (remhash hid (etaf-translate-sched-fallback-used sched))
                    (funcall (etaf-translate-sched-on-unit-error sched)
                             unit (or msg "Translation failed"))))))))
           (finish
            (lambda ()
              (unless settled
                (setq settled t)
                (when (eql gen (etaf-translate-sched-generation sched))
                  (let ((left (cl-count nil delivered)))
                    (setf (etaf-translate-sched-in-flight sched)
                          (max 0 (1- (etaf-translate-sched-in-flight sched)))
                          (etaf-translate-sched-in-flight-units sched)
                          (max 0 (- (etaf-translate-sched-in-flight-units sched)
                                    left))))
                  (when (car cancel-cell)
                    (setf (etaf-translate-sched-cancellers sched)
                          (delq (car cancel-cell)
                                (etaf-translate-sched-cancellers sched))))))))
           (on-unit-done
            (lambda (idx translated)
              (when (and (eql gen (etaf-translate-sched-generation sched))
                         (etaf-runtime-mounted-p (etaf-translate-sched-runtime sched)))
                (funcall deliver-unit idx translated)
                (when-let* ((cb (etaf-translate-sched-on-state-change sched)))
                  (funcall cb)))))
           (on-done
            (lambda (translations)
              (funcall finish)
              (when (and (eql gen (etaf-translate-sched-generation sched))
                         (etaf-runtime-mounted-p (etaf-translate-sched-runtime sched)))
                (if (and (proper-list-p translations)
                         (= (length translations) batch-len))
                    (cl-loop for translated in translations
                             for idx from 0
                             do (funcall deliver-unit idx translated))
                  (let ((rem (funcall undelivered-units)))
                    (funcall handle-remaining-failure
                             rem "Unexpected translation count" (> batch-len 1))))
                (when-let* ((cb (etaf-translate-sched-on-state-change sched)))
                  (funcall cb))
                (etaf-translate-sched--pump sched))))
           (on-error
            (lambda (msg)
              (funcall finish)
              (when (and (eql gen (etaf-translate-sched-generation sched))
                         (etaf-runtime-mounted-p (etaf-translate-sched-runtime sched)))
                (let ((rem (funcall undelivered-units)))
                  (funcall handle-remaining-failure
                           rem (or msg "Translation failed") nil))
                (when-let* ((cb (etaf-translate-sched-on-state-change sched)))
                  (funcall cb))
                (etaf-translate-sched--pump sched))))
           (request (list :units (mapcar #'etaf-translate-unit-markup-text batch)
                          :source-lang src
                          :target-lang tgt
                          :glossary glossary
                          :context (etaf-translate-sched-context sched)
                          :prompt-style (etaf-translate-sched-prompt-style sched)
                          :on-unit-done on-unit-done)))
      (condition-case err
          (let ((cancel (funcall translate-fn request on-done on-error)))
            (setq in-sync-start nil)
            (when (and (not settled) (functionp cancel))
              (setcar cancel-cell cancel)
              (push cancel (etaf-translate-sched-cancellers sched))))
        (error
         (funcall on-error (error-message-string err))
         (setq in-sync-start nil))))))

(provide 'etaf-translate-scheduler)
;;; etaf-translate-scheduler.el ends here
