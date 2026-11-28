;;; etaf-translate-session.el --- Per-Runtime session lifecycle via etaf-ext -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coordinates per-Runtime translation sessions natively on top of `etaf-ext'.
;; Lifecycle hooks (mount/commit/scroll/theme/unmount), compact mode-line
;; badges, permissioned Host presentations, Pure Mode, circuit-breaker
;; isolation and key layers are all managed by `etaf-ext'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ext)
(require 'etaf-translate-core)
(require 'etaf-translate-cache)
(require 'etaf-translate-rules)
(require 'etaf-translate-extract)
(require 'etaf-translate-engine)
(require 'etaf-translate-render)
(require 'etaf-translate-scheduler)

(declare-function etaf-translate-panel "etaf-translate-ui" (&optional runtime))
(declare-function etaf-translate-panel-close "etaf-translate-ui" ())
(declare-function etaf-translate--panel-for-runtime-p "etaf-translate-ui" (runtime))
(declare-function etaf-translate-at-point "etaf-translate-ui" (&optional text engine))

;;;; Provider extension protocol (for pre-wrapped virtualized readers)

(defvar etaf-translate--providers nil
  "Registered content provider adapters as an alist of (NAME . PLIST).")

(defun etaf-translate-register-provider (name &rest spec)
  "Register virtualized content provider adapter NAME with plist SPEC.
Supported keys:
  :match     Function `(runtime buffer)' returning non-nil when matched.
  :extract   Function `(runtime policy)' returning translation units.
  :apply     Function `(runtime unit translated mode style)' painting one unit.
  :clear     Function `(runtime)' restoring the original presentation."
  (unless (and (symbolp name) name)
    (signal 'etaf-translate-error (list "Provider name must be a non-nil symbol" name)))
  (unless (and (proper-list-p spec)
               (functionp (plist-get spec :match))
               (functionp (plist-get spec :extract))
               (functionp (plist-get spec :apply))
               (functionp (plist-get spec :clear)))
    (signal 'etaf-translate-error
            (list "Provider requires :match, :extract, :apply and :clear functions" name)))
  (setq etaf-translate--providers
        (cons (cons name (copy-sequence spec))
              (assq-delete-all name etaf-translate--providers)))
  name)

(defun etaf-translate-unregister-provider (name)
  "Remove virtualized content provider NAME and return non-nil if removed."
  (let ((found (assq name etaf-translate--providers)))
    (when found
      (setq etaf-translate--providers
            (assq-delete-all name etaf-translate--providers))
      t)))

(defun etaf-translate-providers ()
  "Return a list of registered virtualized provider names."
  (mapcar #'car (reverse etaf-translate--providers)))

(defun etaf-translate--find-provider (runtime)
  "Return the matching provider spec plist for RUNTIME, or nil."
  (let ((buf (etaf-runtime-buffer runtime)))
    (cl-loop for (_name . spec) in etaf-translate--providers
             when (ignore-errors (funcall (plist-get spec :match) runtime buf))
             return spec)))

;;;; Session state and observers

(defvar etaf-translate--manual-off (make-hash-table :test #'eq :weakness 'key)
  "Site explicitly disabled by user per Runtime, suppressing auto-enable.")

(defvar etaf-translate--attach-skip-start nil
  "Dynamic guard skipping auto-start inside `:on-attach'.")

(defvar etaf-translate--keep-panel-open nil
  "Dynamic guard keeping an open panel alive across `etaf-translate-disable'.")

(defvar etaf-translate-status-change-functions nil
  "Abnormal hook run with `(RUNTIME STATUS)' on translation status changes.")

(cl-defstruct (etaf-translate-session
               (:constructor etaf-translate-session--make))
  "Live translation session stored in `etaf-ext-ctx-state' on one Runtime."
  ctx
  runtime
  policy
  provider
  cache
  scheduler
  context
  (cache-hits 0)
  (units (make-hash-table :test #'eql))        ; host-id -> etaf-translate-unit
  (translations (make-hash-table :test #'eql)) ; host-id -> (SOURCE-HASH . TRANSLATED)
  (failed (make-hash-table :test #'eql))       ; host-id -> ERROR-MSG
  commit-timer
  scroll-timer
  (active t))

;;;; Helpers

(defun etaf-translate--require-runtime (&optional runtime)
  "Return mounted RUNTIME, defaulting to active or current-buffer Runtime."
  (let ((rt (or runtime
                (etaf-current-runtime)
                (etaf-runtime-for-buffer (current-buffer)))))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (signal 'etaf-translate-error
              (list "No mounted ETAF Runtime in current buffer")))
    rt))

(defun etaf-translate--session-for (runtime)
  "Return the live `etaf-translate-session' on RUNTIME via `etaf-ext', or nil."
  (when-let* ((ctx (etaf-ext-context 'etaf-translate runtime))
              (s (etaf-ext-ctx-state ctx)))
    (and (etaf-translate-session-p s)
         (etaf-translate-session-active s)
         s)))

(defun etaf-translate--update-indicator (runtime &optional status)
  "Refresh `etaf-ext' badge, live activity and status listeners for RUNTIME."
  (when (and runtime (etaf-runtime-mounted-p runtime))
    (let ((ctx (etaf-ext-context 'etaf-translate runtime))
          (st (or status (etaf-translate-status runtime))))
      (when ctx
        (etaf-ext-refresh-badge ctx)
        (let* ((active (plist-get st :active))
               (pend (or (plist-get st :pending) 0))
               (done (or (plist-get st :translated) 0))
               (tot (max 1 (or (plist-get st :total) 0)))
               (buf (etaf-runtime-buffer runtime)))
          (if (and active (> pend 0))
              (etaf-ext-set-activity
               ctx
               (list :kind 'task
                     :state 'active
                     :priority 66
                     :icon "译"
                     :tone 'info
                     :title "沉浸式翻译"
                     :subtitle (format "正在翻译页面（%d / %d 段）" done tot)
                     :compact (format "%d/%d" done tot)
                     :progress (list :value done :max tot)
                     :open (lambda ()
                             (when (buffer-live-p buf)
                               (pop-to-buffer buf)))))
            (etaf-ext-clear-activity ctx))))
      (dolist (fn (copy-sequence etaf-translate-status-change-functions))
        (when (functionp fn)
          (ignore-errors (funcall fn runtime st)))))))

(defun etaf-translate--ext-badge (ctx)
  "Return compact `etaf-ext' mode-line badge plist for CTX, or nil when idle."
  (let ((s (etaf-ext-ctx-state ctx)))
    (when (and (etaf-translate-session-p s)
               (etaf-translate-session-active s))
      (let* ((st (etaf-translate-status (etaf-ext-ctx-runtime ctx)))
             (tr (plist-get st :translated))
             (tot (plist-get st :total))
             (pend (plist-get st :pending))
             (fail (plist-get st :failed)))
        (cond
         ((> fail 0) (list :text (format "译!%d" fail) :variant 'danger))
         ((or (> pend 0) (and (> tot 0) (< tr tot)))
          (list :text (format "译[%d/%d]" tr tot) :variant 'info))
         (t (list :text "译✓" :variant 'success)))))))

;;;; Rendering helpers

(defun etaf-translate--normalize-compare (text)
  "Collapse whitespace and downcase TEXT for duplicate comparison."
  (downcase (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim (or text "")))))

(defun etaf-translate--same-as-source-p (unit translated)
  "Return non-nil when decoded TRANSLATED text equals UNIT's source text."
  (let* ((plain (mapconcat (lambda (seg) (or (plist-get seg :text) ""))
                           (etaf-translate-decode-runs translated unit)
                           ""))
         (a (etaf-translate--normalize-compare (etaf-translate-unit-source-text unit)))
         (b (etaf-translate--normalize-compare plain)))
    (and (not (string-empty-p a))
         (string= a b))))

(defun etaf-translate--presentation-entry (runtime unit translated mode style)
  "Return presentation update entry `(HOST-ID . SPEC)' for UNIT's TRANSLATED.
Suppresses redundant companion rows when TRANSLATED matches the original text."
  (if (etaf-translate--same-as-source-p unit translated)
      (cons (etaf-translate-unit-host-id unit) nil)
    (etaf-translate-build-presentation runtime unit translated mode style)))

(defun etaf-translate--mark-units-loading (session units)
  "Paint subtle loading indicators for queued UNITS in SESSION in one flush."
  (when (and units
             (etaf-translate-session-active session)
             (not (etaf-translate-session-provider session))
             (etaf-runtime-mounted-p (etaf-translate-session-runtime session)))
    (let* ((ctx (etaf-translate-session-ctx session))
           (runtime (etaf-translate-session-runtime session))
           (mode (plist-get (etaf-translate-session-policy session) :mode))
           (trans-table (etaf-translate-session-translations session))
           (batch nil))
      (dolist (unit units)
        (let* ((hid (etaf-translate-unit-host-id unit))
               (existing (gethash hid trans-table)))
          (unless (and existing
                       (equal (car existing) (etaf-translate-unit-source-hash unit)))
            (when-let* ((loading (etaf-translate-build-loading-presentation
                                  runtime unit mode)))
              (push loading batch)))))
      (when batch
        (etaf-ext-present ctx (nreverse batch)))
      (etaf-translate--update-indicator runtime))))

(defun etaf-translate--clear-units-loading (session units)
  "Remove unused loading indicators for UNITS moved back to deferred."
  (when (and units
             (etaf-translate-session-active session)
             (not (etaf-translate-session-provider session))
             (etaf-runtime-mounted-p (etaf-translate-session-runtime session)))
    (let* ((ctx (etaf-translate-session-ctx session))
           (trans-table (etaf-translate-session-translations session))
           (failed-table (etaf-translate-session-failed session))
           (batch nil))
      (dolist (unit units)
        (let ((hid (etaf-translate-unit-host-id unit)))
          (unless (or (gethash hid trans-table) (gethash hid failed-table))
            (push (cons hid nil) batch))))
      (when batch
        (etaf-ext-present ctx (nreverse batch))))))

(defun etaf-translate--apply-unit-translation (session unit translated)
  "Record and paint TRANSLATED for UNIT in SESSION."
  (when (and (etaf-translate-session-active session)
             (etaf-runtime-mounted-p (etaf-translate-session-runtime session)))
    (let* ((ctx (etaf-translate-session-ctx session))
           (runtime (etaf-translate-session-runtime session))
           (policy (etaf-translate-session-policy session))
           (mode (plist-get policy :mode))
           (style (plist-get policy :style))
           (hid (etaf-translate-unit-host-id unit))
           (provider (etaf-translate-session-provider session)))
      (remhash hid (etaf-translate-session-failed session))
      (puthash hid (cons (etaf-translate-unit-source-hash unit) translated)
               (etaf-translate-session-translations session))
      (if provider
          (funcall (plist-get provider :apply) runtime unit translated mode style)
        (let ((entry (etaf-translate--presentation-entry
                      runtime unit translated mode style)))
          (etaf-ext-present ctx (list entry))))
      (etaf-translate--update-indicator runtime))))

(defun etaf-translate--apply-unit-error (session unit msg)
  "Record and display a retryable error state for UNIT in SESSION."
  (when (and (etaf-translate-session-active session)
             (etaf-runtime-mounted-p (etaf-translate-session-runtime session)))
    (let* ((ctx (etaf-translate-session-ctx session))
           (runtime (etaf-translate-session-runtime session))
           (policy (etaf-translate-session-policy session))
           (mode (plist-get policy :mode))
           (hid (etaf-translate-unit-host-id unit)))
      (puthash hid (or msg "Translation failed")
               (etaf-translate-session-failed session))
      (unless (etaf-translate-session-provider session)
        (when-let* ((entry (etaf-translate-build-error-presentation
                            runtime unit mode msg
                            (lambda ()
                              (etaf-translate--retry-unit session hid)))))
          (etaf-ext-present ctx (list entry))))
      (etaf-translate--update-indicator runtime))))

(defun etaf-translate--retry-unit (session host-id)
  "Retry translating single HOST-ID in SESSION."
  (when-let* ((live (and (etaf-translate-session-active session)
                         (etaf-runtime-mounted-p (etaf-translate-session-runtime session))))
              (unit (gethash host-id (etaf-translate-session-units session))))
    (ignore live)
    (remhash host-id (etaf-translate-session-failed session))
    (etaf-translate-sched-enqueue
     (etaf-translate-session-scheduler session) (list unit))
    (etaf-translate--update-indicator (etaf-translate-session-runtime session))))

;;;; Scanning and incremental diffing

(defun etaf-translate--extract-session-units (session)
  "Extract current translation units for SESSION and refresh document context."
  (let ((ctx (etaf-translate-session-ctx session))
        (runtime (etaf-translate-session-runtime session))
        (policy (etaf-translate-session-policy session))
        (provider (etaf-translate-session-provider session)))
    (if provider
        (let* ((units (funcall (plist-get provider :extract) runtime policy))
               (heading (cl-find-if (lambda (u)
                                      (eq (etaf-translate-unit-kind u) 'heading))
                                    units))
               (title (and heading (etaf-translate-unit-source-text heading)))
               (doc-ctx (when title (list :title title))))
          (setf (etaf-translate-session-context session) doc-ctx)
          (when-let* ((sched (etaf-translate-session-scheduler session)))
            (setf (etaf-translate-sched-context sched) doc-ctx))
          units)
      (let* ((tree (etaf-ext-tree ctx))
             (title (etaf-translate-extract-title tree))
             (doc-ctx (when title (list :title title))))
        (setf (etaf-translate-session-context session) doc-ctx)
        (when-let* ((sched (etaf-translate-session-scheduler session)))
          (setf (etaf-translate-sched-context sched) doc-ctx))
        (etaf-translate-extract-units tree policy)))))

(defun etaf-translate--scan-and-translate (session &optional only-host-ids)
  "Scan SESSION's Runtime, apply cached/existing translations and queue misses.
When ONLY-HOST-IDS is non-nil, restrict processing to those Host IDs.
Detects major page navigation (such as switching an RSS article or web page)
and cancels stale requests before translating the new content."
  (when (and (etaf-translate-session-active session)
             (etaf-runtime-mounted-p (etaf-translate-session-runtime session)))
    (let* ((ctx (etaf-translate-session-ctx session))
           (runtime (etaf-translate-session-runtime session))
           (policy (etaf-translate-session-policy session))
           (mode (plist-get policy :mode))
           (style (plist-get policy :style))
           (src (plist-get policy :source-lang))
           (tgt (plist-get policy :target-lang))
           (eng (plist-get policy :engine))
           (ghash (etaf-translate-glossary-hash (plist-get policy :glossary)))
           (cache (etaf-translate-session-cache session))
           (provider (etaf-translate-session-provider session))
           (all-units (etaf-translate--extract-session-units session))
           (units (if only-host-ids
                      (cl-remove-if-not
                       (lambda (u) (memq (etaf-translate-unit-host-id u) only-host-ids))
                       all-units)
                    all-units))
           (unit-table (etaf-translate-session-units session))
           (trans-table (etaf-translate-session-translations session))
           (failed-table (etaf-translate-session-failed session))
           (prev-count (hash-table-count unit-table))
           (batch-presentations nil)
           (to-queue nil))
      (unless only-host-ids
        ;; Detect page replacement (e.g. RSS article switch or web navigation).
        (let ((new-ids (make-hash-table :test #'eql))
              (survived 0))
          (dolist (u all-units)
            (puthash (etaf-translate-unit-host-id u) t new-ids))
          (when (> prev-count 0)
            (maphash (lambda (hid _u)
                       (when (gethash hid new-ids)
                         (cl-incf survived)))
                     unit-table)
            (when (and (> prev-count 2) (< survived (/ prev-count 2)))
              (when-let* ((sched (etaf-translate-session-scheduler session)))
                (etaf-translate-sched-cancel sched))
              (when provider
                (funcall (plist-get provider :clear) runtime))))
          (let ((dead nil))
            (maphash (lambda (hid _v)
                       (unless (gethash hid new-ids) (push hid dead)))
                     trans-table)
            (dolist (hid dead) (remhash hid trans-table)))
          (let ((dead nil))
            (maphash (lambda (hid _v)
                       (unless (gethash hid new-ids) (push hid dead)))
                     failed-table)
            (dolist (hid dead) (remhash hid failed-table))))
        (clrhash unit-table))
      (dolist (unit units)
        (let* ((hid (etaf-translate-unit-host-id unit))
               (hash (etaf-translate-unit-source-hash unit))
               (existing (gethash hid trans-table)))
          (puthash hid unit unit-table)
          (cond
           ((and existing (equal (car existing) hash))
            (unless provider
              (push (etaf-translate--presentation-entry
                     runtime unit (cdr existing) mode style)
                    batch-presentations)))
           (t
            (let* ((ckey (etaf-translate-cache-key
                          (etaf-translate-unit-markup-text unit)
                          src tgt eng ghash))
                   (cached (etaf-translate-cache-get cache ckey)))
              (if cached
                  (progn
                    (cl-incf (etaf-translate-session-cache-hits session))
                    (puthash hid (cons hash cached) trans-table)
                    (remhash hid failed-table)
                    (if provider
                        (funcall (plist-get provider :apply)
                                 runtime unit cached mode style)
                      (push (etaf-translate--presentation-entry
                             runtime unit cached mode style)
                            batch-presentations)))
                (push unit to-queue)))))))
      (when (and batch-presentations (not provider))
        (etaf-ext-present ctx (nreverse batch-presentations)))
      (when to-queue
        (etaf-translate-sched-enqueue
         (etaf-translate-session-scheduler session) (nreverse to-queue)))
      (etaf-translate--update-indicator runtime))))

(defun etaf-translate--repaint-cached (session)
  "Repaint all already-translated units in SESSION with its current mode/style.
Zero network calls; switches modes in one atomic Ebox flush."
  (when (and (etaf-translate-session-active session)
             (etaf-runtime-mounted-p (etaf-translate-session-runtime session)))
    (let* ((ctx (etaf-translate-session-ctx session))
           (runtime (etaf-translate-session-runtime session))
           (policy (etaf-translate-session-policy session))
           (mode (plist-get policy :mode))
           (style (plist-get policy :style))
           (provider (etaf-translate-session-provider session))
           (unit-table (etaf-translate-session-units session))
           (trans-table (etaf-translate-session-translations session))
           (batch nil))
      (maphash
       (lambda (hid unit)
         (when-let* ((entry (gethash hid trans-table)))
           (if provider
               (funcall (plist-get provider :apply)
                        runtime unit (cdr entry) mode style)
             (push (etaf-translate--presentation-entry
                    runtime unit (cdr entry) mode style)
                   batch))))
       unit-table)
      (when (and batch (not provider))
        (etaf-ext-present ctx (nreverse batch)))
      (etaf-translate--update-indicator runtime))))

;;;; Session teardown and etaf-ext lifecycle callbacks

(defun etaf-translate--cancel-timers (session)
  "Cancel any pending debounce timers on SESSION."
  (when-let* ((t1 (etaf-translate-session-commit-timer session)))
    (cancel-timer t1)
    (setf (etaf-translate-session-commit-timer session) nil))
  (when-let* ((t2 (etaf-translate-session-scroll-timer session)))
    (cancel-timer t2)
    (setf (etaf-translate-session-scroll-timer session) nil)))

(defun etaf-translate--schedule-promote (session)
  "Schedule debounced viewport promotion on SESSION after scroll or flush."
  (when (and session (etaf-translate-session-active session))
    (when-let* ((old-timer (etaf-translate-session-scroll-timer session)))
      (cancel-timer old-timer))
    (if (<= etaf-translate-scroll-debounce 0)
        (progn
          (setf (etaf-translate-session-scroll-timer session) nil)
          (etaf-translate-sched-promote-visible
           (etaf-translate-session-scheduler session)))
      (setf (etaf-translate-session-scroll-timer session)
            (run-at-time
             etaf-translate-scroll-debounce nil
             (lambda ()
               (setf (etaf-translate-session-scroll-timer session) nil)
               (when (etaf-translate-session-active session)
                 (etaf-translate-sched-promote-visible
                  (etaf-translate-session-scheduler session)))))))))

(defun etaf-translate--stop-session (session &optional restore-p)
  "Stop SESSION, cancel work and timers, and restore Hosts when RESTORE-P."
  (when session
    (setf (etaf-translate-session-active session) nil)
    (etaf-translate--cancel-timers session)
    (when-let* ((sched (etaf-translate-session-scheduler session)))
      (etaf-translate-sched-cancel sched))
    (let ((ctx (etaf-translate-session-ctx session))
          (runtime (etaf-translate-session-runtime session))
          (provider (etaf-translate-session-provider session)))
      (when ctx
        (etaf-ext-ctx-set-state ctx nil))
      (when (and restore-p runtime (etaf-runtime-mounted-p runtime))
        (if provider
            (ignore-errors (funcall (plist-get provider :clear) runtime))
          (when ctx
            (ignore-errors (etaf-ext-clear-presentations ctx)))))
      (when (and runtime (etaf-runtime-mounted-p runtime))
        (etaf-translate--update-indicator runtime)))))

(defun etaf-translate--should-auto-attach-p (runtime)
  "Return non-nil when RUNTIME matches an `:auto-translate' rule."
  (when (and runtime
             (etaf-runtime-mounted-p runtime)
             (etaf-translate--has-auto-translate-rule-p))
    (let* ((policy (etaf-translate-resolve-policy runtime))
           (site (plist-get policy :site))
           (blocked-site (gethash runtime etaf-translate--manual-off)))
      (and (plist-get policy :auto-translate)
           (not (plist-get policy :never-translate))
           (not (and blocked-site (equal blocked-site (or site t))))))))

(defun etaf-translate--ext-on-attach (ctx)
  "Start full-page translation on CTX when auto-matched or manually attached."
  (unless (or etaf-translate--attach-skip-start
              (memq (etaf-ext-ctx-trigger ctx) '(command popup)))
    (etaf-translate-enable (etaf-ext-ctx-runtime ctx))))

(defun etaf-translate--ext-on-commit (ctx)
  "Schedule incremental rescan after an application commit on CTX."
  (when-let* ((session (etaf-ext-ctx-state ctx)))
    (when (and (etaf-translate-session-p session)
               (etaf-translate-session-active session))
      (when-let* ((old (etaf-translate-session-commit-timer session)))
        (cancel-timer old))
      (if (<= etaf-translate-commit-debounce 0)
          (progn
            (setf (etaf-translate-session-commit-timer session) nil)
            (etaf-translate--scan-and-translate session))
        (setf (etaf-translate-session-commit-timer session)
              (run-at-time etaf-translate-commit-debounce nil
                           (lambda ()
                             (setf (etaf-translate-session-commit-timer session) nil)
                             (etaf-translate--scan-and-translate session))))))))

(defun etaf-translate--ext-on-scroll (ctx)
  "Schedule viewport promotion when CTX's Runtime scrolls or flushes."
  (when-let* ((session (etaf-ext-ctx-state ctx)))
    (when (and (etaf-translate-session-p session)
               (etaf-translate-session-active session))
      (etaf-translate--schedule-promote session))))

(defun etaf-translate--ext-on-theme (ctx)
  "Repaint cached translations on CTX after Emacs switches themes."
  (when-let* ((session (etaf-ext-ctx-state ctx)))
    (when (and (etaf-translate-session-p session)
               (etaf-translate-session-active session))
      (etaf-translate--repaint-cached session))))

(defun etaf-translate--ext-on-detach (ctx)
  "Tear down active translation session when CTX detaches from its Runtime."
  (let ((rt (etaf-ext-ctx-runtime ctx))
        (session (etaf-ext-ctx-state ctx)))
    (when (etaf-translate-session-p session)
      (etaf-translate--stop-session session t))
    (when (and (not etaf-translate--keep-panel-open)
               (fboundp 'etaf-translate--panel-for-runtime-p)
               (etaf-translate--panel-for-runtime-p rt))
      (ignore-errors (etaf-translate-panel-close)))))

(defun etaf-translate--ext-popup (ctx)
  "Open the interactive translation control panel for CTX's Runtime."
  (when (fboundp 'etaf-translate-panel)
    (etaf-translate-panel (etaf-ext-ctx-runtime ctx)))
  nil)

;;;; Public commands and APIs

(defun etaf-translate--make-scheduler (session runtime policy cache)
  "Construct a configured scheduler bound to SESSION."
  (etaf-translate-sched-create
   :runtime runtime
   :cache cache
   :engine-name (plist-get policy :engine)
   :fallback-engine (plist-get policy :fallback-engine)
   :prompt-style (plist-get policy :prompt-style)
   :context (etaf-translate-session-context session)
   :source-lang (plist-get policy :source-lang)
   :target-lang (plist-get policy :target-lang)
   :glossary (plist-get policy :glossary)
   :glossary-hash (etaf-translate-glossary-hash (plist-get policy :glossary))
   :on-unit-ready (lambda (u tr) (etaf-translate--apply-unit-translation session u tr))
   :on-unit-error (lambda (u msg) (etaf-translate--apply-unit-error session u msg))
   :on-units-queued (lambda (units) (etaf-translate--mark-units-loading session units))
   :on-units-deferred (lambda (units) (etaf-translate--clear-units-loading session units))
   :on-state-change (lambda () (etaf-translate--update-indicator runtime))))

(defun etaf-translate--reenable-with (rt session overrides)
  "Restart SESSION on RT with policy plist OVERRIDES applied."
  (let ((policy (copy-sequence (etaf-translate-session-policy session))))
    (cl-loop for (k v) on overrides by #'cddr
             do (setq policy (plist-put policy k v)))
    (etaf-translate-enable rt
                           :mode (plist-get policy :mode)
                           :style (plist-get policy :style)
                           :scope (plist-get policy :scope)
                           :source-lang (plist-get policy :source-lang)
                           :target-lang (plist-get policy :target-lang)
                           :engine (plist-get policy :engine)
                           :fallback-engine (plist-get policy :fallback-engine)
                           :prompt-style (plist-get policy :prompt-style)
                           :glossary (plist-get policy :glossary)
                           :cache (etaf-translate-session-cache session))))

(defun etaf-translate-enable (&optional runtime &rest options)
  "Enable immersive translation on mounted RUNTIME with optional plist OPTIONS.
RUNTIME defaults to the active or current-buffer Runtime.  OPTIONS may override
`:mode', `:style', `:scope', `:source-lang', `:target-lang', `:engine',
`:fallback-engine', `:prompt-style', `:glossary' and `:cache'."
  (let* ((rt (etaf-translate--require-runtime runtime))
         (policy (etaf-translate-resolve-policy rt options))
         (cache (or (plist-get options :cache) (etaf-translate-default-cache))))
    (remhash rt etaf-translate--manual-off)
    ;; Validate engine early so bad configuration surfaces synchronously.
    (etaf-translate--engine-require (plist-get policy :engine))
    (when-let* ((old (etaf-translate--session-for rt)))
      (etaf-translate--stop-session old t))
    (let* ((etaf-translate--attach-skip-start t)
           (ctx (etaf-ext-attach 'etaf-translate rt)))
      (unless ctx
        (signal 'etaf-translate-error
                (list "Cannot attach etaf-translate extension (suspended or unavailable)")))
      (let* ((provider (etaf-translate--find-provider rt))
             (session (etaf-translate-session--make
                       :ctx ctx
                       :runtime rt
                       :policy policy
                       :provider provider
                       :cache cache
                       :active t))
             (sched (etaf-translate--make-scheduler session rt policy cache)))
        (setf (etaf-translate-session-scheduler session) sched)
        (etaf-ext-ctx-set-state ctx session)
        (etaf-translate--scan-and-translate session)
        (etaf-translate-status rt)))))

(defun etaf-translate-disable (&optional runtime)
  "Disable translation on RUNTIME and restore all Hosts to original content."
  (let* ((rt (etaf-translate--require-runtime runtime))
         (had-session (not (null (etaf-translate--session-for rt)))))
    (puthash rt (or (etaf-translate-current-site rt) t) etaf-translate--manual-off)
    (let ((etaf-translate--keep-panel-open t))
      (etaf-ext-detach 'etaf-translate rt))
    (and had-session t)))

(defun etaf-translate--mode-label (mode)
  "Return a concise human-readable label for presentation MODE."
  (pcase mode
    ('bilingual-stacked "双语对照")
    ('replace "原地替换")
    (_ "已关闭")))

;;;###autoload
(defun etaf-translate-toggle (&optional runtime)
  "Toggle immersive translation on or off for RUNTIME."
  (interactive)
  (let* ((rt (etaf-translate--require-runtime runtime))
         (was-active (not (null (etaf-translate--session-for rt))))
         (result (if was-active
                     (progn
                       (etaf-translate-disable rt)
                       nil)
                   (etaf-translate-enable rt))))
    (when (called-interactively-p 'any)
      (if was-active
          (message "沉浸式翻译：已关闭")
        (message "沉浸式翻译：已开启（%s）"
                 (etaf-translate--mode-label (plist-get result :mode)))))
    result))

(defun etaf-translate-set-mode (mode &optional runtime)
  "Switch active presentation MODE on RUNTIME without re-translating.
MODE is `bilingual-stacked' or `replace'."
  (etaf-translate--check-mode mode)
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt)))
    (if (not session)
        (etaf-translate-enable rt :mode mode)
      (setf (etaf-translate-session-policy session)
            (plist-put (copy-sequence (etaf-translate-session-policy session))
                       :mode mode))
      (etaf-translate--repaint-cached session)
      (etaf-translate-sched-promote-visible
       (etaf-translate-session-scheduler session))
      (etaf-translate-status rt))))

;;;###autoload
(defun etaf-translate-mode-cycle (&optional runtime)
  "Cycle RUNTIME through bilingual-stacked, replace and off."
  (interactive)
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt))
         (next-mode (if (not session)
                        'bilingual-stacked
                      (pcase (plist-get (etaf-translate-session-policy session) :mode)
                        ('bilingual-stacked 'replace)
                        (_ nil))))
         (result (cond
                  ((null next-mode)
                   (etaf-translate-disable rt)
                   nil)
                  ((not session)
                   (etaf-translate-enable rt :mode next-mode))
                  (t
                   (etaf-translate-set-mode next-mode rt)))))
    (when (called-interactively-p 'any)
      (message "沉浸式翻译：%s" (etaf-translate--mode-label next-mode)))
    result))

(defun etaf-translate-set-style (style &optional runtime)
  "Switch active bilingual STYLE on RUNTIME.
STYLE is one of `left-bar', `muted' or `tinted'."
  (etaf-translate--check-style style)
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt)))
    (if (not session)
        (etaf-translate-enable rt :style style)
      (setf (etaf-translate-session-policy session)
            (plist-put (copy-sequence (etaf-translate-session-policy session))
                       :style style))
      (etaf-translate--repaint-cached session)
      (etaf-translate-status rt))))

(defun etaf-translate-set-scope (scope &optional runtime)
  "Switch active extraction SCOPE (`content' or `full') on RUNTIME."
  (etaf-translate--check-scope scope)
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt)))
    (if (not session)
        (etaf-translate-enable rt :scope scope)
      (etaf-translate--reenable-with rt session (list :scope scope)))))

(defun etaf-translate-set-engine (engine &optional runtime)
  "Switch active translation ENGINE or named profile on RUNTIME."
  (etaf-translate--engine-require engine)
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt)))
    (if (not session)
        (etaf-translate-enable rt :engine engine)
      (etaf-translate--reenable-with rt session (list :engine engine)))))

(defun etaf-translate-set-languages (source-lang target-lang &optional runtime)
  "Switch SOURCE-LANG and TARGET-LANG for RUNTIME's active translation."
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt)))
    (if (not session)
        (etaf-translate-enable rt :source-lang source-lang :target-lang target-lang)
      (etaf-translate--reenable-with
       rt session (list :source-lang source-lang :target-lang target-lang)))))

(defun etaf-translate-set-prompt-style (prompt-style &optional runtime)
  "Switch LLM PROMPT-STYLE (`technical', `academic', `literary', `concise')."
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt)))
    (if (not session)
        (etaf-translate-enable rt :prompt-style prompt-style)
      (etaf-translate--reenable-with rt session (list :prompt-style prompt-style)))))

(defun etaf-translate-retry-failed (&optional runtime)
  "Retry all failed translation units on RUNTIME and return count retried."
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt))
         (to-retry nil))
    (when session
      (let ((units (etaf-translate-session-units session))
            (failed (etaf-translate-session-failed session)))
        (maphash (lambda (hid _msg)
                   (when-let* ((u (gethash hid units)))
                     (push u to-retry)))
                 failed)
        (clrhash failed)
        (when to-retry
          (etaf-translate-sched-enqueue
           (etaf-translate-session-scheduler session) (nreverse to-retry))
          (etaf-translate--update-indicator rt))))
    (length to-retry)))

(defun etaf-translate-refresh (&optional runtime)
  "Clear cached translations for RUNTIME's current units and re-translate them."
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt)))
    (if (not session)
        (etaf-translate-enable rt)
      (let* ((policy (etaf-translate-session-policy session))
             (cache (etaf-translate-session-cache session))
             (src (plist-get policy :source-lang))
             (tgt (plist-get policy :target-lang))
             (eng (plist-get policy :engine))
             (ghash (etaf-translate-glossary-hash (plist-get policy :glossary))))
        (maphash (lambda (_hid unit)
                   (etaf-translate-cache-remove
                    cache
                    (etaf-translate-cache-key
                     (etaf-translate-unit-markup-text unit)
                     src tgt eng ghash)))
                 (etaf-translate-session-units session))
        (etaf-translate--reenable-with rt session nil)))))

(defun etaf-translate--extract-paragraph-at-point ()
  "Extract and normalize the paragraph (or current line) at point in buffer."
  (let ((raw (or (thing-at-point 'paragraph t)
                 (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position)))))
    (etaf-translate--join-wrapped-lines raw)))

;;;###autoload
(defun etaf-translate-paragraph (&optional runtime)
  "Translate or toggle the paragraph at point.
In a mounted ETAF buffer (or when RUNTIME is given), toggle inline bilingual
translation for only the paragraph Host covering point (returning its Host ID
when enabled, or nil when restored).  In any ordinary non-ETAF Emacs buffer,
translate the paragraph at point in the floating pure-translation popup."
  (interactive)
  (let ((rt (if runtime
                (etaf-translate--require-runtime runtime)
              (let ((cand (or (etaf-current-runtime)
                              (etaf-runtime-for-buffer (current-buffer)))))
                (and cand (etaf-runtime-mounted-p cand) cand)))))
    (if (not rt)
        (let ((para (etaf-translate--extract-paragraph-at-point)))
          (if (string-empty-p para)
              (if (called-interactively-p 'any)
                  (progn
                    (message "沉浸式翻译：光标处无可翻译段落")
                    nil)
                (signal 'etaf-translate-error
                        (list "No paragraph at point to translate")))
            (etaf-translate-at-point para)))
      (let* ((buf (etaf-runtime-buffer rt))
             (line (with-current-buffer buf
                     (1- (line-number-at-pos (point) t))))
             (existing (etaf-translate--session-for rt))
             (cur-ctx (etaf-ext-context 'etaf-translate rt))
             (provider (or (and existing (etaf-translate-session-provider existing))
                           (etaf-translate--find-provider rt)))
             (policy (if existing
                         (etaf-translate-session-policy existing)
                       (etaf-translate-resolve-policy rt)))
             (tree (if cur-ctx (etaf-ext-tree cur-ctx) (etaf-runtime-host-tree rt)))
             (units (if provider
                        (funcall (plist-get provider :extract) rt policy)
                      (etaf-translate-extract-units tree policy)))
             (int-ids (cl-remove-if-not #'integerp
                                        (mapcar #'etaf-translate-unit-host-id units)))
             (geos (if cur-ctx
                       (etaf-ext-geometries cur-ctx int-ids)
                     (etaf-runtime-host-geometries rt int-ids)))
             (target
              (cl-find-if
               (lambda (u)
                 (when-let* ((geo (or (cdr (assq (etaf-translate-unit-host-id u) geos))
                                      (etaf-translate-unit-geometry u))))
                   (let ((y (or (plist-get geo :y) 0))
                         (h (max 1 (or (plist-get geo :height) 1))))
                     (and (<= y line) (< line (+ y h))))))
               units)))
        (if (not target)
            (progn
              (when (called-interactively-p 'any)
                (message "沉浸式翻译：光标处无可翻译段落"))
              nil)
          (let ((hid (etaf-translate-unit-host-id target)))
            (if (and existing
                     (gethash hid (etaf-translate-session-translations existing)))
                (progn
                  (remhash hid (etaf-translate-session-translations existing))
                  (remhash hid (etaf-translate-session-failed existing))
                  (etaf-ext-present (etaf-translate-session-ctx existing)
                                    (list (cons hid nil)))
                  (etaf-translate--update-indicator rt)
                  (when (called-interactively-p 'any)
                    (message "沉浸式翻译：已还原当前段"))
                  nil)
              (unless existing
                (etaf-translate--engine-require (plist-get policy :engine))
                (let* ((etaf-translate--attach-skip-start t)
                       (ctx (etaf-ext-attach 'etaf-translate rt))
                       (cache (etaf-translate-default-cache))
                       (session (etaf-translate-session--make
                                 :ctx ctx :runtime rt :policy policy :provider provider
                                 :cache cache :active t))
                       (sched (etaf-translate--make-scheduler session rt policy cache)))
                  (unless ctx
                    (signal 'etaf-translate-error
                            (list "Cannot attach etaf-translate extension")))
                  (setf (etaf-translate-session-scheduler session) sched)
                  (etaf-ext-ctx-set-state ctx session)
                  (setq existing session)))
              (etaf-translate--scan-and-translate existing (list hid))
              (when (called-interactively-p 'any)
                (message "沉浸式翻译：已翻译当前段"))
              hid)))))))

(defun etaf-translate-status (&optional runtime)
  "Return a detached status plist for translation on RUNTIME.
Keys: `:active', `:site', `:mode', `:style', `:scope', `:engine',
`:fallback-engine', `:prompt-style', `:source-lang', `:target-lang',
`:total', `:translated', `:cache-hits', `:pending', `:deferred' and `:failed'."
  (let* ((rt (etaf-translate--require-runtime runtime))
         (session (etaf-translate--session-for rt)))
    (if (not session)
        (let ((policy (etaf-translate-resolve-policy rt)))
          (list :active nil
                :site (plist-get policy :site)
                :mode (plist-get policy :mode)
                :style (plist-get policy :style)
                :scope (plist-get policy :scope)
                :engine (plist-get policy :engine)
                :fallback-engine (plist-get policy :fallback-engine)
                :prompt-style (plist-get policy :prompt-style)
                :source-lang (plist-get policy :source-lang)
                :target-lang (plist-get policy :target-lang)
                :total 0 :translated 0 :cache-hits 0
                :pending 0 :deferred 0 :failed 0))
      (let* ((policy (etaf-translate-session-policy session))
             (sched (etaf-translate-session-scheduler session))
             (total (hash-table-count (etaf-translate-session-units session)))
             (translated 0))
        (maphash (lambda (hid unit)
                   (when-let* ((entry (gethash hid (etaf-translate-session-translations session))))
                     (when (equal (car entry) (etaf-translate-unit-source-hash unit))
                       (cl-incf translated))))
                 (etaf-translate-session-units session))
        (list :active t
              :site (plist-get policy :site)
              :mode (plist-get policy :mode)
              :style (plist-get policy :style)
              :scope (plist-get policy :scope)
              :engine (plist-get policy :engine)
              :fallback-engine (plist-get policy :fallback-engine)
              :prompt-style (plist-get policy :prompt-style)
              :source-lang (plist-get policy :source-lang)
              :target-lang (plist-get policy :target-lang)
              :total total
              :translated translated
              :cache-hits (etaf-translate-session-cache-hits session)
              :pending (+ (length (etaf-translate-sched-pending sched))
                          (etaf-translate-sched-in-flight-units sched))
              :deferred (length (etaf-translate-sched-deferred sched))
              :failed (hash-table-count (etaf-translate-session-failed session)))))))

;;;; Native etaf-ext extension registration

(etaf-ext-define etaf-translate
  :name "沉浸式翻译"
  :version "0.3.0"
  :icon "译"
  :tone 'accent
  :prefix-hint "t"
  :description "在任意 ETAF 页面上叠加双语对照或原地替换翻译，保留行内代码、链接与 LaTeX 公式。"
  :activation #'etaf-translate--should-auto-attach-p
  :matches '(:apps t)
  :priority 10
  :debounce 0
  :permissions '(read-tree companion override interact popup keys)
  :commands
  (list (list 'toggle
              :subkey "t"
              :label "开关全页翻译"
              :fn (lambda (ctx)
                    (etaf-translate-toggle (etaf-ext-ctx-runtime ctx))))
        (list 'panel
              :subkey "p"
              :label "翻译控制面板"
              :fn (lambda (ctx)
                    (etaf-translate-panel (etaf-ext-ctx-runtime ctx))))
        (list 'mode-cycle
              :subkey "m"
              :label "循环双语/替换"
              :fn (lambda (ctx)
                    (etaf-translate-mode-cycle (etaf-ext-ctx-runtime ctx))))
        (list 'paragraph
              :subkey "."
              :label "翻译光标所在段"
              :fn (lambda (ctx)
                    (etaf-translate-paragraph (etaf-ext-ctx-runtime ctx)))))
  :popup #'etaf-translate--ext-popup
  :badge #'etaf-translate--ext-badge
  :on-attach #'etaf-translate--ext-on-attach
  :on-commit #'etaf-translate--ext-on-commit
  :on-scroll #'etaf-translate--ext-on-scroll
  :on-theme #'etaf-translate--ext-on-theme
  :on-detach #'etaf-translate--ext-on-detach)

(when (etaf-translate--has-auto-translate-rule-p)
  (etaf-ext-sync))

(provide 'etaf-translate-session)
;;; etaf-translate-session.el ends here
