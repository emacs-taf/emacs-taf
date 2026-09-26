;;; performance-driver.el --- Reusable Emacs interaction measurements -*- lexical-binding: t; -*-

;;; Commentary:
;; Development-tool interface, loaded by scripts/performance.py.
;; Function: taf-benchmark-register (id &rest properties)
;; Register a scenario with :setup, :modes, :budget-ms and :impact. SETUP takes
;; the mode symbol and returns :buffer, :invoke, :verify and :cleanup functions.
;; INVOKE takes an operation index, increasing through warmups and formal
;; samples within a scenario/set. VERIFY returns t or a short failure string.
;; Optional :settled is a predicate for asynchronous completion; :observe
;; takes a report sink and returns a cleanup function. Reports are provider
;; public observer plists. Optional :environment returns JSON-safe metadata.
;; Optional :outcome reads a bounded JSON-safe value from public application
;; APIs after timing and profiling stop, before verification. It must be read-only.
;; This records each latency sample's accepted result without enabling tracing.
;; :ready waits for fixture initialization; :prepare resolves targets after
;; showing the buffer and before timing. :required-providers lists expected
;; observer provider symbols. Observer cleanup/collection runs after timing
;; and profiling stop. CPU, allocation and provider traces use separate passes.
;; A fresh fixture is the default; :isolation series reuses it within a set.
;; Warmups use the same preparation, timing, settlement and verification as
;; formal samples. Their rows retain phase "warmup" and stay outside formal
;; latency statistics. The driver preserves the runtime's GC settings.
;; Function: taf-benchmark-start (configuration-file)
;; Start asynchronous GUI work, or run a batch job to completion.
;; Function: taf-benchmark-running-p ()
;; Query whether this driver owns an active job before reloading the tool.
;; Function: taf-benchmark-detach-fixture ()
;; After a run stops, transfer its retained live buffer to the caller without
;; invoking fixture cleanup. Return that buffer, or nil when none is live.
;; The caller owns its later cleanup; subsequent runs leave it intact.
;; Signal user-error while a job is running.
;; Function: taf-benchmark-cancel (&optional run-id)
;; Cancel only this tool's jobs and profiler. Never stop the Emacs process.
;; RUN-ID, when provided, must match the active run's identity.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'profiler)
(require 'subr-x)

(defvar comp-eln-to-el-h)

(defvar taf-benchmark--registry nil)
(defvar taf-benchmark--configuration nil)
(defvar taf-benchmark--report nil)
(defvar taf-benchmark--jobs nil)
(defvar taf-benchmark--timer nil)
(defvar taf-benchmark--fixture nil)
(defvar taf-benchmark--fixture-key nil)
(defvar taf-benchmark--window nil)
(defvar taf-benchmark--previous-buffer nil)
(defvar taf-benchmark--active nil)
(defvar taf-benchmark--observations nil)
(defvar taf-benchmark--unobserve nil)
(defvar taf-benchmark--profiling nil)
(defvar taf-benchmark--loaded-before nil)
(defvar taf-benchmark--profiler-settings nil)
(defvar taf-benchmark--locations nil)
(defvar taf-benchmark--library-history nil)
(defvar taf-benchmark--library-history-length nil)
(defvar taf-benchmark--runtime-libraries [])
(defvar taf-benchmark--unmapped-native-libraries [])

(defun taf-benchmark-register (id &rest properties)
  "Register scenario ID with supported PROPERTIES."
  (unless (and (stringp id) (not (assoc id taf-benchmark--registry))
               (functionp (plist-get properties :setup))
               (numberp (plist-get properties :budget-ms))
               (> (plist-get properties :budget-ms) 0)
               (cl-every (lambda (mode) (memq mode '(batch gui)))
                         (plist-get properties :modes))
               (plist-get properties :modes))
    (error "Invalid or duplicate performance scenario: %s" id))
  (setq properties (plist-put properties :source (or load-file-name buffer-file-name)))
  (push (cons id properties) taf-benchmark--registry))

(defun taf-benchmark--json-write (file value)
  "Atomically write JSON VALUE to FILE without printing application objects."
  (let ((coding-system-for-write 'utf-8-unix)
        (pending (concat file ".tmp")))
    (with-temp-file pending
      (insert (decode-coding-string
               (json-serialize value :null-object nil :false-object :false) 'utf-8))
      (insert "\n"))
    (rename-file pending file t)))

(defun taf-benchmark--save ()
  "Save the current bounded report."
  (taf-benchmark--json-write (plist-get taf-benchmark--configuration :output)
                             taf-benchmark--report))

(defun taf-benchmark--error (condition)
  "Return bounded CONDITION text, including errors containing closures."
  (let ((print-length 6) (print-level 4) (print-circle t))
    (truncate-string-to-width (error-message-string condition) 1200 nil nil "…")))

(defun taf-benchmark--files ()
  "Return loaded local Lisp library paths without reading function values."
  (let ((roots (plist-get taf-benchmark--configuration :code_roots)))
    (delq nil (mapcar (lambda (entry)
                       (when (and (stringp (car entry))
                                  (cl-some (lambda (root)
                                             (string-prefix-p (file-name-as-directory root)
                                                              (expand-file-name (car entry)))) roots))
                         (expand-file-name (car entry)))) load-history))))

(defun taf-benchmark--runtime-libraries ()
  "Record actual runtime library load formats outside the measured operation.
Selected package entries, lisp modules and examples count as runtime code;
explicit scenario adapters do not.  A changed load history refreshes this
cached evidence so lazy library loading is visible after an operation."
  (let ((history-length (length load-history)))
    (unless (and (eq taf-benchmark--library-history load-history)
                 (eql taf-benchmark--library-history-length history-length))
      (let ((roots
             (mapcar (lambda (root)
                       (cons (file-name-nondirectory (directory-file-name root))
                             (file-name-as-directory (file-truename root))))
                     (plist-get taf-benchmark--configuration :code_roots)))
            (scenarios (mapcar #'file-truename
                               (plist-get taf-benchmark--configuration :scenario_files)))
            libraries unmapped-native)
        (dolist (entry load-history)
          (when (stringp (car entry))
            (let* ((file (file-truename (car entry)))
                   (native (string-suffix-p ".eln" file))
                   (mapped (and native (boundp 'comp-eln-to-el-h)
                                (hash-table-p comp-eln-to-el-h)
                                (gethash (file-name-nondirectory file) comp-eln-to-el-h)))
                   (origin (if (stringp mapped) (file-truename mapped) file))
                   (matched nil))
              (dolist (root roots)
                (let* ((package (car root)) (directory (cdr root))
                       (relative (and (string-prefix-p directory origin)
                                      (substring origin (length directory)))))
                  (when (and relative (not (member origin scenarios))
                             (or (string-match-p
                                  (concat "\\`" (regexp-quote package) "\\.el\\(?:c\\|n\\)?\\(?:\\.gz\\)?\\'") relative)
                                 (string-prefix-p "lisp/" relative)
                                 (string-prefix-p "examples/" relative)))
                    (setq matched t)
                    (push (list :package package :library relative :file file :origin origin
                                :format (cond (native "native")
                                              ((string-match-p "\\.elc\\(?:\\.gz\\)?\\'" file) "compiled")
                                              ((string-match-p "\\.el\\(?:\\.gz\\)?\\'" file) "source")
                                              (t "unknown")))
                          libraries))))
              (when (and native (not matched) (not (stringp mapped)))
                (push (list :file file :scope "unmapped-external") unmapped-native)))))
        (setq taf-benchmark--runtime-libraries (vconcat (nreverse libraries))
              taf-benchmark--unmapped-native-libraries (vconcat (nreverse unmapped-native))
              taf-benchmark--library-history load-history
              taf-benchmark--library-history-length history-length))))
  taf-benchmark--runtime-libraries)

(defun taf-benchmark--environment ()
  "Capture stable execution context and separate dynamic GC settings."
  (let ((gui (eq (intern (plist-get taf-benchmark--configuration :mode)) 'gui)))
    (list :pid (emacs-pid) :emacs emacs-version :system system-configuration
          :emacs_start (float-time before-init-time) :init user-init-file
          :buffer (and taf-benchmark--fixture
                       (buffer-name (plist-get taf-benchmark--fixture :buffer)))
          :graphic (if (display-graphic-p) t :false)
          :foreground (if (and gui (eq (frame-focus-state (selected-frame)) t)) t :false)
          :font (format "%s" (frame-parameter nil 'font))
          :width (window-body-width nil t) :height (window-body-height nil t)
          :frame (sxhash-eq (selected-frame)) :window (sxhash-eq (selected-window))
          :text_scale (and (boundp 'text-scale-mode-amount) text-scale-mode-amount)
          :gc_threshold gc-cons-threshold :gc_percentage gc-cons-percentage
          :native_jit (if (and (boundp 'native-comp-jit-compilation) native-comp-jit-compilation) t :false)
          :runtime_libraries (taf-benchmark--runtime-libraries)
          :unmapped_native_libraries taf-benchmark--unmapped-native-libraries
          :context (when-let* ((probe (plist-get taf-benchmark--fixture :environment)))
                     (funcall probe)))))

(defun taf-benchmark--context-equal-p (before after)
  "Compare execution context, keeping automatic GC policy transitions as data."
  (cl-every (lambda (key) (equal (plist-get before key) (plist-get after key)))
            (append '(:pid :emacs :system :buffer :graphic :font :width :height :frame :window :text_scale :context)
                    (when (plist-get taf-benchmark--configuration :require_foreground) '(:foreground)))))

(defun taf-benchmark--window-valid-p ()
  "Check the exact GUI target without selecting another application."
  (or noninteractive
      (and (window-live-p taf-benchmark--window)
           (eq (selected-window) taf-benchmark--window)
           (eq (window-buffer taf-benchmark--window)
               (plist-get taf-benchmark--fixture :buffer))
           (display-graphic-p)
           (eq (frame-visible-p (selected-frame)) t)
           (not (active-minibuffer-window)))))

(defun taf-benchmark--capture-report (&rest arguments)
  "Collect only scalar fields from a provider observer's ARGUMENTS."
  (let* ((report (car (last arguments)))
         (provider (plist-get report :provider))
         (phases (plist-get report :phase-duration-ms)))
    (when provider
      (push (list :provider (symbol-name provider)
                  :stage (format "%s" (plist-get report :stage))
                  :correlation_id (or (plist-get report :correlation-id) (plist-get report :transaction-id))
                  :ms (plist-get report :duration-ms)
                  :phases (vconcat (cl-loop for (phase ms) on phases by #'cddr
                                           collect (list :phase (symbol-name phase) :ms ms)))
                  :strategy (format "%s" (plist-get report :strategy))
                  :projection (format "%s" (plist-get report :projection-kind))
                  :native_fallback
                  (when-let* ((reason (plist-get report :native-fallback-reason)))
                    (let ((print-length 12) (print-level 4) (print-circle t))
                      (truncate-string-to-width (format "%S" reason) 1200 nil nil "…")))
                  :native_declined
                  (when-let* ((reason (plist-get report :native-declined-reason)))
                    (let ((print-length 12) (print-level 4) (print-circle t))
                      (truncate-string-to-width (format "%S" reason) 1200 nil nil "…")))
                  :dirty_count (plist-get report :dirty-count)
                  :root_id (plist-get report :constraint-root-node-id)
                  :owners (vconcat (plist-get report :owner-ids))
                  :reconciled (plist-get report :reconciled-objects)
                  :text_operations (plist-get report :publication-text-operations)
                  :property_operations (plist-get report :publication-property-operations)
                  :rejections
                  (let ((print-length 12) (print-level 4))
                    (format "%S" (plist-get report :projection-rejections))))
            taf-benchmark--observations))))

(defun taf-benchmark--function-location (symbol)
  "Locate a profiler SYMBOL's source without calling the profiled function."
  (when (symbolp symbol)
    (when-let* ((file (symbol-file symbol 'defun)))
      (let ((source (if (string-suffix-p ".elc" file) (substring file 0 -1) file)))
        (list :file source
              :line (when (and (string-suffix-p ".el" source) (file-readable-p source))
                      (with-temp-buffer
                        (insert-file-contents source)
                        (when (re-search-forward
                               (concat "^(\\(?:cl-\\)?def\\(?:un\\|macro\\|subst\\) +"
                                       (regexp-quote (symbol-name symbol)) "[ \n]") nil t)
                          (line-number-at-pos (match-beginning 0))))))))))

(defun taf-benchmark--profile-summary (log unit)
  "Summarize profiler LOG in UNIT, never serializing captured environments."
  (let ((inclusive (make-hash-table :test #'equal))
        (self (make-hash-table :test #'equal))
        (symbols (make-hash-table :test #'equal)) (total 0) stacks rows)
    (maphash
     (lambda (stack weight)
       (cl-incf total weight)
       (let (seen names)
         (mapc (lambda (frame)
                 ;; Native profiler vectors pad unused stack slots with nil.
                 ;; Those are not anonymous function calls.
                 (when frame
                   (let ((name (if (symbolp frame) (symbol-name frame) "<anonymous>")))
                     (push name names)
                     (when (symbolp frame) (puthash name frame symbols))
                     (unless (member name seen)
                       (push name seen)
                       (puthash name (+ weight (gethash name inclusive 0)) inclusive))))) stack)
         (setq names (nreverse names))
         (when names (puthash (car names) (+ weight (gethash (car names) self 0)) self))
         (push (list :weight weight :stack (vconcat names)) stacks))) log)
    (maphash (lambda (name weight)
               (push (append (list :function name :inclusive weight :self (gethash name self 0))
                             (or (gethash name taf-benchmark--locations)
                                 (puthash name (taf-benchmark--function-location (gethash name symbols))
                                          taf-benchmark--locations))) rows)) inclusive)
    (list :unit unit :total total
          ;; Retain leaf hotspots as well as expensive callers. A long shared
          ;; call chain must not crowd every high-self-cost leaf out of the DTO.
          :functions (vconcat
                      (delete-dups
                       (append (seq-take (sort (copy-sequence rows)
                                              (lambda (a b) (> (plist-get a :self) (plist-get b :self)))) 60)
                               (seq-take (sort rows (lambda (a b) (> (plist-get a :inclusive)
                                                                    (plist-get b :inclusive)))) 60))))
          :stacks (vconcat (seq-take (sort stacks (lambda (a b) (> (plist-get a :weight)
                                                                    (plist-get b :weight)))) 15)))))

(defun taf-benchmark--profile-stop ()
  "Stop this tool's profiler before allocating or formatting its summaries."
  (when taf-benchmark--profiling
    ;; Stopping CPU first can make its log allocation dominate memory results.
    (let ((kind taf-benchmark--profiling))
      (if (eq kind 'memory) (profiler-memory-stop) (profiler-cpu-stop))
      (setq taf-benchmark--profiling nil)
      (when taf-benchmark--profiler-settings
        (setq profiler-max-stack-depth (car taf-benchmark--profiler-settings)
              profiler-sampling-interval (cdr taf-benchmark--profiler-settings)
              taf-benchmark--profiler-settings nil))
      (if (eq kind 'memory)
          (list :memory (taf-benchmark--profile-summary (profiler-memory-log) "bytes"))
        (list :cpu (taf-benchmark--profile-summary (profiler-cpu-log) "samples"))))))

(defun taf-benchmark--dispose ()
  "Dispose only the fixture created by this tool."
  (when taf-benchmark--unobserve
    (funcall taf-benchmark--unobserve)
    (setq taf-benchmark--unobserve nil))
  (when-let* ((cleanup (plist-get taf-benchmark--fixture :cleanup))) (funcall cleanup))
  (setq taf-benchmark--fixture nil taf-benchmark--fixture-key nil))

(defun taf-benchmark--finish (status &optional error-text)
  "Finish with STATUS and optional ERROR-TEXT, retaining GUI evidence."
  (when-let* ((profile (taf-benchmark--profile-stop)))
    (setf (plist-get taf-benchmark--report :failure_profile) profile))
  (when taf-benchmark--unobserve
    (condition-case cleanup-error
        (funcall taf-benchmark--unobserve)
      ((error quit)
       (setf (plist-get taf-benchmark--report :cleanup_error) (taf-benchmark--error cleanup-error))))
    (setq taf-benchmark--unobserve nil))
  (when error-text
    (setf (plist-get taf-benchmark--report :failure_reports)
          (vconcat (nreverse taf-benchmark--observations))))
  (setf (plist-get taf-benchmark--report :status) status
        (plist-get taf-benchmark--report :error) error-text
        (plist-get taf-benchmark--report :finished_at) (float-time)
        (plist-get taf-benchmark--report :loaded_files) (vconcat (taf-benchmark--files)))
  (setq taf-benchmark--jobs nil)
  (if noninteractive
      (condition-case cleanup-error (taf-benchmark--dispose)
        ((error quit)
         (setf (plist-get taf-benchmark--report :cleanup_error) (taf-benchmark--error cleanup-error)
               (plist-get taf-benchmark--report :status) "error")))
    ;; The final fixture buffer stays alive for inspection, but the benchmark
    ;; window returns to the user's buffer instead of a fixed-size workload.
    (when (and (window-live-p taf-benchmark--window)
               (buffer-live-p taf-benchmark--previous-buffer)
               taf-benchmark--fixture
               (eq (window-buffer taf-benchmark--window)
                   (plist-get taf-benchmark--fixture :buffer)))
      (set-window-buffer taf-benchmark--window taf-benchmark--previous-buffer)))
  (taf-benchmark--save))

(defun taf-benchmark--schedule (function &optional delay)
  "Schedule FUNCTION without a blocking GUI sleep."
  (setq taf-benchmark--timer (run-at-time (or delay 0.03) nil function)))

(defun taf-benchmark--progress (job stage)
  "Publish JOB and STAGE before entering potentially expensive work."
  (setf (plist-get taf-benchmark--report :active)
        (list :scenario (plist-get job :id) :sample (plist-get job :sample)
              :set (plist-get job :set) :phase (plist-get job :phase)
              :diagnostic_kind (plist-get job :diagnostic_kind)
              :iteration (or (plist-get job :iteration) (plist-get job :sample))
              :stage stage :started_at (float-time)))
  (taf-benchmark--save))

(defun taf-benchmark--await-foreground (function job)
  "Wait for the GUI without timing another application or stealing focus."
  (unless (equal (plist-get (plist-get taf-benchmark--report :active) :stage)
                 "waiting_for_foreground")
    (taf-benchmark--progress job "waiting_for_foreground"))
  (taf-benchmark--schedule function 0.25)
  nil)

(defun taf-benchmark--next ()
  "Prepare the next fixture and yield for redisplay."
  (condition-case condition
      (cond
       ((not (equal (plist-get taf-benchmark--report :status) "running")) nil)
       ((null taf-benchmark--jobs) (taf-benchmark--finish "completed"))
       ((and (not noninteractive) (plist-get taf-benchmark--configuration :require_foreground)
             (not (eq (frame-focus-state (selected-frame)) t)))
        (taf-benchmark--await-foreground #'taf-benchmark--next (car taf-benchmark--jobs)))
       (t
        (let* ((job (pop taf-benchmark--jobs))
               (spec (cdr (assoc (plist-get job :id) taf-benchmark--registry)))
               (key (list (plist-get job :id) (plist-get job :set) (plist-get job :diagnostic)))
               (reuse (and (eq (plist-get spec :isolation) 'series)
                           (equal key taf-benchmark--fixture-key))))
          (setq taf-benchmark--active (list :job job :spec spec))
          (taf-benchmark--progress job "setup")
          (unless reuse
            (taf-benchmark--dispose)
            (let ((started (float-time)))
              (setq taf-benchmark--fixture
                    (funcall (plist-get spec :setup)
                             (intern (plist-get taf-benchmark--configuration :mode))))
              (setq taf-benchmark--fixture-key key)
              (plist-put taf-benchmark--active :setup_ms (* 1000 (- (float-time) started)))))
          (unless (and (buffer-live-p (plist-get taf-benchmark--fixture :buffer))
                       (functionp (plist-get taf-benchmark--fixture :invoke))
                       (functionp (plist-get taf-benchmark--fixture :verify)))
            (error "Scenario returned an invalid fixture"))
          (unless noninteractive
            (select-window taf-benchmark--window)
            (set-window-buffer taf-benchmark--window (plist-get taf-benchmark--fixture :buffer))
            (redisplay t))
          (taf-benchmark--progress job "ready")
          (taf-benchmark--schedule #'taf-benchmark--ready))))
    ((error quit) (taf-benchmark--finish "error" (taf-benchmark--error condition)))))

(defun taf-benchmark--ready ()
  "Await explicit fixture readiness before measuring any operation."
  (condition-case condition
      (when (equal (plist-get taf-benchmark--report :status) "running")
        (with-current-buffer (plist-get taf-benchmark--fixture :buffer)
          (if (when-let* ((ready (plist-get taf-benchmark--fixture :ready))) (not (funcall ready)))
              (taf-benchmark--schedule #'taf-benchmark--ready 0.005)
            (taf-benchmark--invoke))))
    ((error quit) (taf-benchmark--finish "error" (taf-benchmark--error condition)))))

(defun taf-benchmark--invoke ()
  "Invoke one operation, recording action timing separately from setup."
  (condition-case condition
      (when (and (equal (plist-get taf-benchmark--report :status) "running")
                 (or noninteractive (not (plist-get taf-benchmark--configuration :require_foreground))
                     (eq (frame-focus-state (selected-frame)) t)
                     (taf-benchmark--await-foreground #'taf-benchmark--invoke
                                                      (plist-get taf-benchmark--active :job))))
        (unless (taf-benchmark--window-valid-p) (error "Benchmark GUI target changed"))
        (when-let* ((prepare (plist-get taf-benchmark--fixture :prepare)))
          (with-current-buffer (plist-get taf-benchmark--fixture :buffer) (funcall prepare)))
        (let* ((job (plist-get taf-benchmark--active :job))
               (diagnostic (plist-get job :diagnostic))
               (kind (plist-get job :diagnostic_kind)))
          (setq taf-benchmark--observations nil)
          (when (profiler-running-p) (error "Another profiler is already active"))
          (when diagnostic
            (when-let* (((equal kind "trace"))
                        (observe (plist-get taf-benchmark--fixture :observe)))
              (setq taf-benchmark--unobserve (funcall observe #'taf-benchmark--capture-report))))
          (taf-benchmark--progress job "action")
          (with-current-buffer (plist-get taf-benchmark--fixture :buffer)
            (let ((before (taf-benchmark--environment)))
              (plist-put taf-benchmark--active :before before))
            (when (member kind '("cpu" "memory"))
              (setq taf-benchmark--profiler-settings
                    (cons profiler-max-stack-depth profiler-sampling-interval))
              (setq profiler-max-stack-depth 80 profiler-sampling-interval 1000000)
              (if (equal kind "cpu") (profiler-cpu-start profiler-sampling-interval)
                (profiler-memory-start))
              (setq taf-benchmark--profiling (intern kind)))
            (plist-put taf-benchmark--active :counts (memory-use-counts))
            (plist-put taf-benchmark--active :gc_start gc-elapsed)
            (plist-put taf-benchmark--active :gcs_start gcs-done)
            (plist-put taf-benchmark--active :cpu_start (current-cpu-time))
            (plist-put taf-benchmark--active :started (float-time))
            (funcall (plist-get taf-benchmark--fixture :invoke)
                     (or (plist-get job :iteration) (plist-get job :sample)))
            (plist-put taf-benchmark--active :action_end (float-time)))
          (taf-benchmark--settle)))
    ((error quit)
     (taf-benchmark--finish "error" (taf-benchmark--error condition)))))

(defun taf-benchmark--settle ()
  "Await a scenario's explicit completion predicate, then verify its result."
  (condition-case condition
      (when (equal (plist-get taf-benchmark--report :status) "running")
        (with-current-buffer (plist-get taf-benchmark--fixture :buffer)
          (if (when-let* ((settled (plist-get taf-benchmark--fixture :settled))) (not (funcall settled)))
              (if (> (- (float-time) (plist-get taf-benchmark--active :started))
                     (plist-get taf-benchmark--configuration :timeout))
                  (error "Asynchronous scenario did not settle within its deadline")
                (taf-benchmark--schedule #'taf-benchmark--settle 0.005))
            (unless noninteractive (redisplay t))
            (let* ((finished (float-time))
                   (cpu (current-cpu-time))
                   (gc-ms (* 1000 (- gc-elapsed (plist-get taf-benchmark--active :gc_start))))
                   (gc-count (- gcs-done (plist-get taf-benchmark--active :gcs_start)))
                   (counts (cl-mapcar #'- (memory-use-counts) (plist-get taf-benchmark--active :counts)))
                   (profile (taf-benchmark--profile-stop))
                   (_unobserved
                    (when taf-benchmark--unobserve
                      (funcall taf-benchmark--unobserve)
                      (setq taf-benchmark--unobserve nil)))
                   (job (plist-get taf-benchmark--active :job))
                   (spec (plist-get taf-benchmark--active :spec))
                   (before (plist-get taf-benchmark--active :before))
                   (after (taf-benchmark--environment))
                   (outcome (when-let* ((probe (plist-get taf-benchmark--fixture :outcome)))
                              (funcall probe)))
                   (verification (funcall (plist-get taf-benchmark--fixture :verify)))
                   (row
                    (list :scenario (plist-get job :id) :set (plist-get job :set)
                          :sample (plist-get job :sample)
                          :phase (plist-get job :phase)
                          :iteration (or (plist-get job :iteration) (plist-get job :sample))
                          :diagnostic (if (plist-get job :diagnostic) t :false)
                          :diagnostic_kind (plist-get job :diagnostic_kind)
                          :outcome outcome
                          :wall_ms (* 1000 (- finished (plist-get taf-benchmark--active :started)))
                          :action_ms (* 1000 (- (plist-get taf-benchmark--active :action_end)
                                               (plist-get taf-benchmark--active :started)))
                          :settle_ms (* 1000 (- finished (plist-get taf-benchmark--active :action_end)))
                          :setup_ms (or (plist-get taf-benchmark--active :setup_ms) 0)
                          :settle_resolution_ms (if (plist-get taf-benchmark--fixture :settled) 5 0)
                          :gc_ms gc-ms :gc_count gc-count :allocations (vconcat counts)
                          :cpu_ms
                          (* 1000 (- (/ (float (car cpu)) (cdr cpu))
                                     (let ((start (plist-get taf-benchmark--active :cpu_start)))
                                       (/ (float (car start)) (cdr start)))))
                          :correct (if (eq verification t) t :false)
                          :verification (unless (eq verification t)
                                          (if (stringp verification) verification "Verification did not return t"))
                          :environment_stable (if (and (taf-benchmark--window-valid-p)
                                                      (taf-benchmark--context-equal-p before after)) t :false)
                          :before before :after after :budget_ms (plist-get spec :budget-ms)
                          :impact (symbol-name (or (plist-get spec :impact) 'unspecified))
                          :required_providers (vconcat (mapcar #'symbol-name (plist-get spec :required-providers)))
                          :reports (vconcat (nreverse taf-benchmark--observations)) :profile profile)))
              (setf (plist-get taf-benchmark--report :samples)
                    (vconcat (plist-get taf-benchmark--report :samples) (vector row)))
              (taf-benchmark--save)
              (unless (eq verification t) (error "Scenario verification failed: %s" verification))
              (unless (eq (plist-get row :environment_stable) t)
                (error "Execution context changed during the operation; sample retained"))
              (taf-benchmark--schedule #'taf-benchmark--next)))))
    ((error quit) (taf-benchmark--finish "error" (taf-benchmark--error condition)))))

(defun taf-benchmark--load-configuration (file)
  "Read FILE and load explicitly selected scenario entry files."
  (setq taf-benchmark--configuration
        (with-temp-buffer
          (insert-file-contents file)
          (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil :false-object nil)))
  (setq taf-benchmark--registry nil taf-benchmark--loaded-before (taf-benchmark--files)
        taf-benchmark--library-history nil taf-benchmark--library-history-length nil
        taf-benchmark--runtime-libraries [] taf-benchmark--unmapped-native-libraries [])
  (dolist (directory (plist-get taf-benchmark--configuration :load_paths))
    (add-to-list 'load-path directory))
  (dolist (source (plist-get taf-benchmark--configuration :scenario_files))
    (load source nil t t)))

(defun taf-benchmark-catalog (configuration-file)
  "Write the registered public scenario descriptors from CONFIGURATION-FILE."
  (taf-benchmark--load-configuration configuration-file)
  (taf-benchmark--json-write
   (plist-get taf-benchmark--configuration :output)
   (vconcat (mapcar (lambda (entry)
                     (let ((spec (cdr entry)))
                       (list :id (car entry) :source (plist-get spec :source)
                             :version (or (plist-get spec :version) 1)
                             :modes (vconcat (mapcar #'symbol-name (plist-get spec :modes)))
                             :budget_ms (plist-get spec :budget-ms)
                             :impact (symbol-name (or (plist-get spec :impact) 'unspecified))
                             :required_providers (vconcat (mapcar #'symbol-name (plist-get spec :required-providers)))
                             :isolation (symbol-name (or (plist-get spec :isolation) 'fresh))
                             :description (plist-get spec :description))))
                   (reverse taf-benchmark--registry)))))

(defun taf-benchmark-probe (configuration-file)
  "Record the existing server and loaded libraries without mounting a scenario."
  (setq taf-benchmark--configuration
        (with-temp-buffer
          (insert-file-contents configuration-file)
          (json-parse-buffer :object-type 'plist :array-type 'list)))
  (setq taf-benchmark--library-history nil taf-benchmark--library-history-length nil
        taf-benchmark--runtime-libraries [] taf-benchmark--unmapped-native-libraries [])
  (taf-benchmark--json-write
   (plist-get taf-benchmark--configuration :output)
   (list :environment (taf-benchmark--environment)
         :loaded_files (vconcat (taf-benchmark--files))
         :libraries
         (vconcat
          (mapcar
           (lambda (root)
             (let* ((name (file-name-nondirectory (directory-file-name root)))
                    (feature (intern name))
                    (entry (cl-find-if (lambda (item) (member (cons 'provide feature) (cdr item))) load-history)))
               (list :feature name :root root :loaded (if (featurep feature) t :false)
                     :file (and (stringp (car entry)) (car entry)))))
           (plist-get taf-benchmark--configuration :code_roots)))
         :profiler_active (if (profiler-running-p) t :false)
         :running (if (equal (plist-get taf-benchmark--report :status) "running") t :false)))
  'probed)

(defun taf-benchmark-start (configuration-file)
  "Run CONFIGURATION-FILE through one batch process or the existing GUI."
  (when (equal (plist-get taf-benchmark--report :status) "running")
    (user-error "A performance job is already running"))
  (taf-benchmark--dispose)
  (taf-benchmark--load-configuration configuration-file)
  (unless (or noninteractive (display-graphic-p)) (error "An existing graphical Emacs is required"))
  (when (and (not noninteractive) (active-minibuffer-window)) (error "An active minibuffer prevents measurement"))
  (setq taf-benchmark--window (selected-window)
        taf-benchmark--previous-buffer (window-buffer (selected-window))
        taf-benchmark--locations (make-hash-table :test #'equal)
        taf-benchmark--jobs (plist-get taf-benchmark--configuration :jobs)
        taf-benchmark--report
        (list :schema 1 :status "running" :error nil :started_at (float-time)
              :run_id (plist-get taf-benchmark--configuration :run_id)
              :mode (plist-get taf-benchmark--configuration :mode)
              :boundary "invoke through explicit settlement and redisplay return"
              :presentation_measured :false :environment (taf-benchmark--environment)
              :loaded_before (vconcat taf-benchmark--loaded-before) :samples []))
  (when (and (not noninteractive) (plist-get taf-benchmark--configuration :foreground))
    (select-frame-set-input-focus (window-frame taf-benchmark--window)))
  (taf-benchmark--save)
  (taf-benchmark--schedule #'taf-benchmark--next)
  (when noninteractive
    (while (equal (plist-get taf-benchmark--report :status) "running")
      (accept-process-output nil 0.01)))
  'scheduled)

(defun taf-benchmark-running-p ()
  "Return non-nil while this driver owns a running job."
  (equal (plist-get taf-benchmark--report :status) "running"))

(defun taf-benchmark-detach-fixture ()
  "Transfer the stopped run's retained fixture buffer to the caller.
Return its live buffer, or nil when no live fixture buffer remains.  Clear
the driver's fixture ownership without invoking cleanup, unmounting, or
killing the buffer.  The caller becomes responsible for later cleanup.
Signal `user-error' while a benchmark job is running."
  (when (taf-benchmark-running-p)
    (user-error "Cannot detach a fixture while a performance job is running"))
  (let ((buffer (plist-get taf-benchmark--fixture :buffer)))
    (setq taf-benchmark--fixture nil taf-benchmark--fixture-key nil)
    (and (buffer-live-p buffer) buffer)))

(defun taf-benchmark-cancel (&optional run-id)
  "Cancel this tool's scheduled work without terminating Emacs."
  (interactive)
  (when (and run-id (not (equal run-id (plist-get taf-benchmark--report :run_id))))
    (error "Cancellation belongs to another benchmark run"))
  (when (timerp taf-benchmark--timer) (cancel-timer taf-benchmark--timer))
  (when (equal (plist-get taf-benchmark--report :status) "running")
    (taf-benchmark--finish "cancelled"))
  'cancelled)

;;; performance-driver.el ends here
