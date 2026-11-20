;;; etaf-performance.el --- Optional ETAF operation recorder -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This optional package records the flat provider reports emitted by one
;; mounted ETAF Runtime.  It has no advice registry and owns no timing path:
;; operation boundaries and durations come exclusively from the Runtime
;; observer contract.

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'ring)
(require 'seq)
(require 'tabulated-list)
(require 'etaf-runtime)

(defgroup etaf-performance nil
  "Operation timing reports emitted by ETAF runtimes."
  :group 'etaf)

(defcustom etaf-performance-max-records 200
  "Maximum completed operations retained by the recorder."
  :type 'integer
  :group 'etaf-performance)

(defconst etaf-performance-report-format-version 2
  "Current portable performance report format version.")

(cl-defstruct (etaf-performance-stage
               (:constructor etaf-performance--stage-create))
  "One flat provider report belonging to an operation."
  sequence provider category name duration status metadata)

(cl-defstruct (etaf-performance-operation
               (:constructor etaf-performance--operation-create))
  "One completed Runtime operation and its ordered provider reports."
  id kind label runtime-id buffer-name revision-before revision-after
  elapsed status gc-count gc-elapsed metadata stages)

(cl-defstruct (etaf-performance--attachment
               (:constructor etaf-performance--attachment-create))
  sink pending-keys)

(defvar etaf-performance--record-ring nil)
(defvar etaf-performance--pending (make-hash-table :test #'equal))
(defvar etaf-performance--attachments (make-hash-table :test #'eq))
(defvar-local etaf-performance--mode-runtime nil)

(defconst etaf-performance--report-context-keys
  '(:format-version :operation-id :sequence :runtime-id :buffer-name
    :provider :stage :status :duration-ms)
  "Flat report keys represented by typed recorder fields.")

(defun etaf-performance--copy-value (value)
  "Return a defensive recorder snapshot of VALUE."
  (cond
   ((stringp value) (copy-sequence value))
   ((consp value)
    (cons (etaf-performance--copy-value (car value))
          (etaf-performance--copy-value (cdr value))))
   ((vectorp value)
    (apply #'vector
           (mapcar #'etaf-performance--copy-value (append value nil))))
   ((hash-table-p value)
    (let ((copy (copy-hash-table value)))
      (clrhash copy)
      (maphash (lambda (key item)
                 (puthash (etaf-performance--copy-value key)
                          (etaf-performance--copy-value item)
                          copy))
               value)
      copy))
   (t value)))

(defun etaf-performance--copy-stage (stage)
  "Return an isolated snapshot of recorder STAGE."
  (etaf-performance--stage-create
   :sequence (etaf-performance-stage-sequence stage)
   :provider (etaf-performance-stage-provider stage)
   :category (etaf-performance-stage-category stage)
   :name (etaf-performance-stage-name stage)
   :duration (etaf-performance-stage-duration stage)
   :status (etaf-performance-stage-status stage)
   :metadata
   (etaf-performance--copy-value (etaf-performance-stage-metadata stage))))

(defun etaf-performance--copy-operation (operation)
  "Return an isolated snapshot of recorder OPERATION."
  (etaf-performance--operation-create
   :id (etaf-performance-operation-id operation)
   :kind (etaf-performance-operation-kind operation)
   :label (etaf-performance--copy-value
           (etaf-performance-operation-label operation))
   :runtime-id (etaf-performance-operation-runtime-id operation)
   :buffer-name (etaf-performance--copy-value
                 (etaf-performance-operation-buffer-name operation))
   :revision-before
   (etaf-performance-operation-revision-before operation)
   :revision-after
   (etaf-performance-operation-revision-after operation)
   :elapsed (etaf-performance-operation-elapsed operation)
   :status (etaf-performance-operation-status operation)
   :gc-count (etaf-performance-operation-gc-count operation)
   :gc-elapsed (etaf-performance-operation-gc-elapsed operation)
   :metadata
   (etaf-performance--copy-value
    (etaf-performance-operation-metadata operation))
   :stages (mapcar #'etaf-performance--copy-stage
                   (etaf-performance-operation-stages operation))))

(defun etaf-performance-records (&optional runtime-id)
  "Return newest-first immutable snapshots of completed records.
When RUNTIME-ID is non-nil, select only that integer observer report identity,
as exposed by `etaf-performance-operation-runtime-id'.  This also selects
historical records after unmount or reuse of a buffer name.  Omitted or nil
RUNTIME-ID selects all retained records."
  (unless (or (null runtime-id) (integerp runtime-id))
    (signal 'wrong-type-argument (list 'integerp runtime-id)))
  (let ((records (and etaf-performance--record-ring
                      (ring-elements etaf-performance--record-ring))))
    (mapcar #'etaf-performance--copy-operation
            (if runtime-id
                (seq-filter
                 (lambda (operation)
                   (equal runtime-id
                          (etaf-performance-operation-runtime-id operation)))
                 records)
              records))))

(defun etaf-performance--percentile (samples percentile)
  "Return nearest-rank PERCENTILE from numeric SAMPLES."
  (when samples
    (let* ((ordered (sort (copy-sequence samples) #'<))
           (rank (max 1 (ceiling (* percentile (length ordered))))))
      (nth (1- rank) ordered))))

(defun etaf-performance--provider-category (provider)
  "Return the public recorder category for PROVIDER."
  (if (eq provider 'etaf) 'runtime provider))

(defun etaf-performance--report-metadata (report)
  "Return REPORT fields not represented by typed recorder fields."
  (let (metadata)
    (while report
      (let ((key (pop report))
            (value (pop report)))
        (unless (memq key etaf-performance--report-context-keys)
          (setq metadata
                (append metadata
                        (list key (etaf-performance--copy-value value)))))))
    metadata))

(defun etaf-performance--stage-from-report (report)
  "Create one flat recorder stage from provider REPORT."
  (let ((provider (plist-get report :provider)))
    (etaf-performance--stage-create
     :sequence (plist-get report :sequence)
     :provider provider
     :category (etaf-performance--provider-category provider)
     :name (plist-get report :stage)
     :duration (plist-get report :duration-ms)
     :status (plist-get report :status)
     :metadata (etaf-performance--report-metadata report))))

(defun etaf-performance-operation-stage-summary (operation)
  "Summarize flat provider stages in OPERATION by category.

Each result contains `:category', `:count', and `:duration-ms'.  Provider
durations may overlap and are therefore never presented as exclusive time."
  (unless (etaf-performance-operation-p operation)
    (signal 'wrong-type-argument
            (list 'etaf-performance-operation-p operation)))
  (let ((table (make-hash-table :test #'eq)) result)
    (dolist (stage (etaf-performance-operation-stages operation))
      (let* ((category (etaf-performance-stage-category stage))
             (entry (or (gethash category table) (cons 0 0.0))))
        (setcar entry (1+ (car entry)))
        (setcdr entry (+ (cdr entry)
                         (etaf-performance-stage-duration stage)))
        (puthash category entry table)))
    (maphash
     (lambda (category entry)
       (push (list :category category :count (car entry)
                   :duration-ms (cdr entry))
             result))
     table)
    (sort result (lambda (left right)
                   (> (plist-get left :duration-ms)
                      (plist-get right :duration-ms))))))

(cl-defun etaf-performance-summary
    (&optional (records (etaf-performance-records)))
  "Summarize completed RECORDS by operation kind and label.
Omitted RECORDS selects all retained records; explicit nil selects none."
  (let ((groups (make-hash-table :test #'equal)) result)
    (dolist (operation records)
      (let ((key (cons (etaf-performance-operation-kind operation)
                       (etaf-performance-operation-label operation))))
        (puthash key
                 (cons (etaf-performance-operation-elapsed operation)
                       (gethash key groups))
                 groups)))
    (maphash
     (lambda (key samples)
       (push
        (list :kind (car key) :label (cdr key) :count (length samples)
              :min-ms (apply #'min samples)
              :p50-ms (etaf-performance--percentile samples 0.50)
              :p95-ms (etaf-performance--percentile samples 0.95)
              :max-ms (apply #'max samples)
              :mean-ms (/ (apply #'+ samples) (float (length samples))))
        result))
     groups)
    (sort result (lambda (left right)
                   (> (plist-get left :p95-ms)
                      (plist-get right :p95-ms))))))

(defun etaf-performance--retain (operation)
  "Retain completed OPERATION under the configured bound."
  (let ((limit (max 0 etaf-performance-max-records)))
    (if (zerop limit)
        (setq etaf-performance--record-ring nil)
      (unless (and etaf-performance--record-ring
                   (= (ring-size etaf-performance--record-ring) limit))
        (let ((existing (etaf-performance-records)))
          (setq etaf-performance--record-ring (make-ring limit))
          (dolist (record (reverse (seq-take existing limit)))
            (ring-insert etaf-performance--record-ring record))))
      (ring-insert etaf-performance--record-ring operation))))

(defun etaf-performance--final-report-p (report)
  "Return non-nil when REPORT closes one Runtime operation."
  (and (eq (plist-get report :provider) 'etaf)
       (eq (plist-get report :stage) 'runtime-operation)))

(defun etaf-performance--operation-from-reports (reports)
  "Create one completed operation from ordered flat REPORTS."
  (let* ((ordered
          (sort reports
                (lambda (left right)
                  (< (plist-get left :sequence)
                     (plist-get right :sequence)))))
         (final (car (last ordered))))
    (etaf-performance--operation-create
     :id (plist-get final :operation-id)
     :kind (plist-get final :kind)
     :label (plist-get final :label)
     :runtime-id (plist-get final :runtime-id)
     :buffer-name (plist-get final :buffer-name)
     :revision-before (plist-get final :revision-before)
     :revision-after (plist-get final :revision-after)
     :elapsed (plist-get final :duration-ms)
     :status (plist-get final :status)
     :gc-count (or (plist-get final :gc-count) 0)
     :gc-elapsed (or (plist-get final :gc-duration-ms) 0.0)
     :metadata (etaf-performance--report-metadata final)
     :stages (mapcar #'etaf-performance--stage-from-report ordered))))

(defun etaf-performance--pending-key (report)
  "Return the Runtime and operation correlation key for REPORT."
  (cons (plist-get report :runtime-id)
        (plist-get report :operation-id)))

(defun etaf-performance--capture (runtime report)
  "Capture one flat REPORT emitted by RUNTIME."
  (let* ((attachment (gethash runtime etaf-performance--attachments))
         (key (etaf-performance--pending-key report))
         (reports (cons (copy-tree report)
                        (gethash key etaf-performance--pending))))
    (when attachment
      (cl-pushnew key (etaf-performance--attachment-pending-keys attachment)
                  :test #'equal))
    (if (etaf-performance--final-report-p report)
        (progn
          (remhash key etaf-performance--pending)
          (when attachment
            (setf (etaf-performance--attachment-pending-keys attachment)
                  (delete key
                          (etaf-performance--attachment-pending-keys
                           attachment))))
          (etaf-performance--retain
           (etaf-performance--operation-from-reports reports))
          (when (eq (plist-get report :kind) 'unmount)
            (remhash runtime etaf-performance--attachments)))
      (puthash key reports etaf-performance--pending)))
  nil)

(defun etaf-performance--discard-pending (attachment)
  "Discard unfinished records owned by ATTACHMENT."
  (dolist (key (etaf-performance--attachment-pending-keys attachment))
    (remhash key etaf-performance--pending))
  (setf (etaf-performance--attachment-pending-keys attachment) nil))

;;;###autoload
(defun etaf-performance-start (runtime)
  "Attach the recorder to mounted RUNTIME and return RUNTIME.

Attachment is idempotent for this recorder.  A Runtime already owned by a
  different observer is rejected rather than replaced."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let* ((attachment (gethash runtime etaf-performance--attachments))
         (owned-sink (and attachment
                          (etaf-performance--attachment-sink attachment))))
    (cond
     (owned-sink
      (unless (etaf-runtime-compare-and-set-observer
               runtime owned-sink owned-sink)
        (error "ETAF recorder no longer owns the Runtime observer"))
      runtime)
     (t
      (when attachment
        (remhash runtime etaf-performance--attachments))
      (let* ((sink (lambda (report)
                     (etaf-performance--capture runtime report)))
             (new (etaf-performance--attachment-create
                   :sink sink :pending-keys nil)))
        (unless (etaf-runtime-compare-and-set-observer runtime nil sink)
          (error "ETAF runtime already has a different observer"))
        (puthash runtime new etaf-performance--attachments)
        runtime)))))

;;;###autoload
(defun etaf-performance-stop (runtime)
  "Detach this recorder from RUNTIME and return RUNTIME.

If another observer replaced the recorder sink, leave that observer intact."
  (unless (etaf-runtime-p runtime)
    (signal 'wrong-type-argument (list 'etaf-runtime-p runtime)))
  (when-let* ((attachment
               (gethash runtime etaf-performance--attachments)))
    (let ((sink (etaf-performance--attachment-sink attachment)))
      (condition-case nil
          (etaf-runtime-compare-and-set-observer runtime sink nil)
        (etaf-runtime-error nil)))
    (etaf-performance--discard-pending attachment)
    (remhash runtime etaf-performance--attachments))
  runtime)

;;;###autoload
(defun etaf-performance-call-operation (runtime kind label function)
  "Call FUNCTION as KIND and LABEL through RUNTIME's operation boundary."
  (etaf-runtime-call-operation runtime kind label function))

(cl-defmacro etaf-performance-with-operation
    ((runtime kind label) &rest body)
  "Evaluate BODY through RUNTIME's canonical operation boundary."
  (declare (indent 1) (debug ((form form form) body)))
  `(etaf-performance-call-operation
    ,runtime ,kind ,label (lambda () ,@body)))

;;;###autoload
(define-minor-mode etaf-performance-mode
  "Record operations for the Runtime mounted in the current buffer."
  :init-value nil
  :lighter " ETAF-Perf"
  (if etaf-performance-mode
      (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (unless runtime
          (setq etaf-performance-mode nil)
          (user-error "Current buffer has no mounted ETAF runtime"))
        (condition-case condition
            (progn
              (etaf-performance-start runtime)
              (setq etaf-performance--mode-runtime runtime))
          (error
           (setq etaf-performance-mode nil)
           (signal (car condition) (cdr condition)))))
    (when etaf-performance--mode-runtime
      (etaf-performance-stop etaf-performance--mode-runtime)
      (setq etaf-performance--mode-runtime nil))))

;;;###autoload
(defun etaf-performance-clear ()
  "Clear completed and unfinished performance records."
  (interactive)
  (setq etaf-performance--record-ring nil)
  (clrhash etaf-performance--pending)
  (when-let* ((panel (get-buffer "*ETAF Performance*")))
    (with-current-buffer panel
      (when (derived-mode-p 'etaf-performance-panel-mode)
        (tabulated-list-revert))))
  nil)

(defun etaf-performance--stage-report-data (stage)
  "Return portable report data for STAGE."
  (list :sequence (etaf-performance-stage-sequence stage)
        :provider (etaf-performance-stage-provider stage)
        :category (etaf-performance-stage-category stage)
        :stage (etaf-performance-stage-name stage)
        :duration-ms (etaf-performance-stage-duration stage)
        :status (etaf-performance-stage-status stage)
        :metadata
        (etaf-performance--copy-value
         (etaf-performance-stage-metadata stage))))

(defun etaf-performance--operation-report-data (operation)
  "Return portable report data for OPERATION."
  (list :id (etaf-performance-operation-id operation)
        :kind (etaf-performance-operation-kind operation)
        :label (etaf-performance--copy-value (etaf-performance-operation-label operation))
        :runtime-id (etaf-performance-operation-runtime-id operation)
        :buffer-name (etaf-performance--copy-value (etaf-performance-operation-buffer-name operation))
        :revision-before
        (etaf-performance-operation-revision-before operation)
        :revision-after
        (etaf-performance-operation-revision-after operation)
        :elapsed-ms (etaf-performance-operation-elapsed operation)
        :status (etaf-performance-operation-status operation)
        :gc-count (etaf-performance-operation-gc-count operation)
        :gc-duration-ms (etaf-performance-operation-gc-elapsed operation)
        :metadata
        (etaf-performance--copy-value
         (etaf-performance-operation-metadata operation))
        :stage-summary
        (etaf-performance-operation-stage-summary operation)
        :stages
        (mapcar #'etaf-performance--stage-report-data
                (etaf-performance-operation-stages operation))))

(defun etaf-performance--parse-darwin-power-state
    (battery-output custom-output)
  "Return normalized macOS power state from PMSET outputs.
BATTERY-OUTPUT identifies the active source; CUSTOM-OUTPUT contains settings."
  (let* ((source
          (cond
           ((string-match-p "Battery Power" (or battery-output "")) 'battery)
           ((string-match-p "AC Power" (or battery-output "")) 'ac)
           (t 'unknown)))
         (target-heading
          (pcase source ('battery "Battery Power") ('ac "AC Power") (_ nil)))
         active low-power)
    (dolist (line (split-string (or custom-output "") "\n" t))
      (cond
       ((string-match "^\\(.+ Power\\):[[:space:]]*$" line)
        (setq active (and target-heading
                          (string= (match-string 1 line) target-heading))))
       ((and active
             (string-match
              "^[[:space:]]*lowpowermode[[:space:]]+\\([01]\\)" line))
        (setq low-power (if (string= (match-string 1 line) "1")
                            'on 'off)))))
    (list :source source :low-power-mode (or low-power 'unknown))))

(defun etaf-performance--command-output (program &rest arguments)
  "Return PROGRAM output for ARGUMENTS, or nil on failure."
  (when program
    (with-temp-buffer
      (let ((default-directory temporary-file-directory))
        (when (eq 0 (apply #'call-process program nil t nil arguments))
          (buffer-string))))))

(defun etaf-performance--power-state ()
  "Return a portable local power-state snapshot."
  (if (not (eq system-type 'darwin))
      (list :source 'unknown :low-power-mode 'unknown)
    (let ((pmset (executable-find "pmset")))
      (if (not pmset)
          (list :source 'unknown :low-power-mode 'unknown)
        (etaf-performance--parse-darwin-power-state
         (etaf-performance--command-output pmset "-g" "batt")
         (etaf-performance--command-output pmset "-g" "custom"))))))

(defun etaf-performance-environment-data ()
  "Return the environment snapshot used to interpret latency records."
  (list :emacs-version emacs-version
        :system-type system-type
        :window-system window-system
        :graphic-display (display-graphic-p)
        :frame-pixel-size
        (list (frame-pixel-width) (frame-pixel-height))
        :window-body-pixel-size
        (list (window-body-width nil t) (window-body-height nil t))
        :gc-cons-threshold gc-cons-threshold
        :gc-cons-percentage gc-cons-percentage
        :native-comp-jit-compilation
        (and (boundp 'native-comp-jit-compilation)
             native-comp-jit-compilation)
        :load-average (load-average t)
        :power-state (etaf-performance--power-state)))

;;;###autoload
(cl-defun etaf-performance-report-data
    (&optional (records (etaf-performance-records)))
  "Return a portable report for completed performance RECORDS.
Omitted RECORDS selects all retained records; explicit nil selects none."
  (list :format-version etaf-performance-report-format-version
        :generated-at (format-time-string "%Y-%m-%dT%H:%M:%S%z")
        :environment (etaf-performance-environment-data)
        :summary (etaf-performance-summary records)
        :operations
        (mapcar #'etaf-performance--operation-report-data
                (reverse (copy-sequence records)))))

;;;###autoload
(cl-defun etaf-performance-report-string
    (&optional (records (etaf-performance-records)))
  "Return completed performance RECORDS as a readable report string.
Omitted RECORDS selects all retained records; explicit nil selects none."
  (concat ";; ETAF performance report\n"
          (pp-to-string (etaf-performance-report-data records))))

;;;###autoload
(defun etaf-performance-copy-report ()
  "Copy all retained performance records to the kill ring."
  (interactive)
  (let* ((record-count (length (etaf-performance-records)))
         (report (etaf-performance-report-string)))
    (kill-new report)
    (message "Copied %d ETAF performance operation%s"
             record-count (if (= 1 record-count) "" "s"))
    report))

;;;###autoload
(defun etaf-performance-export (file)
  "Export all retained performance records to FILE.

When called interactively, suggest a timestamped `.eld' file.  Refuse to
overwrite an existing file."
  (interactive
   (list
    (read-file-name
     "Export ETAF performance report: " nil
     (expand-file-name
      (format "etaf-performance-%s.eld"
              (format-time-string "%Y%m%d-%H%M%S"))
      default-directory))))
  (let ((report (etaf-performance-report-string)))
    (write-region report nil file nil 'silent nil 'excl)
    (message "Exported %d ETAF performance operations to %s"
             (length (etaf-performance-records))
             (abbreviate-file-name file))
    file))

(defun etaf-performance--format-object (value)
  "Format VALUE compactly for the performance table."
  (if (null value) "-" (format "%s" value)))

(defun etaf-performance--tabulated-entries ()
  "Return tabulated entries for retained operations and flat stages."
  (let (entries)
    (dolist (operation (reverse (etaf-performance-records)))
      (let ((id (etaf-performance-operation-id operation)))
        (push
         (list (cons 'operation id)
               (vector (number-to-string id)
                       (symbol-name (etaf-performance-operation-kind operation))
                       (or (etaf-performance-operation-label operation) "")
                       "operation" "-" "-"
                       (format "%.3f"
                               (etaf-performance-operation-elapsed operation))
                       (symbol-name
                        (etaf-performance-operation-status operation))
                       (etaf-performance--format-object
                        (etaf-performance-operation-buffer-name operation))))
         entries)
        (dolist (stage (etaf-performance-operation-stages operation))
          (push
           (list (cons id (etaf-performance-stage-sequence stage))
                 (vector
                  (format "%s.%s" id
                          (etaf-performance-stage-sequence stage))
                  "stage"
                  (symbol-name (etaf-performance-stage-name stage))
                  (symbol-name (etaf-performance-stage-category stage))
                  (symbol-name (etaf-performance-stage-provider stage))
                  (number-to-string
                   (etaf-performance-stage-sequence stage))
                  (format "%.3f" (etaf-performance-stage-duration stage))
                  (symbol-name (etaf-performance-stage-status stage))
                  "-"))
           entries))))
    (nreverse entries)))

(defun etaf-performance--panel-environment-line (&optional environment)
  "Return one compact header for performance ENVIRONMENT."
  (let* ((environment (or environment
                          (etaf-performance-environment-data)))
         (power (plist-get environment :power-state))
         (load (car (plist-get environment :load-average))))
    (format " ETAF Performance | Emacs %s | power %s/low:%s | load %.2f "
            (or (plist-get environment :emacs-version) "unknown")
            (or (plist-get power :source) 'unknown)
            (or (plist-get power :low-power-mode) 'unknown)
            (or load 0.0))))

(define-derived-mode etaf-performance-panel-mode
  tabulated-list-mode "ETAF-Performance"
  "Display ETAF operations and their flat provider reports."
  (setq tabulated-list-format
        [("ID" 9 t) ("Type" 10 t) ("Operation / Stage" 26 t)
         ("Category" 12 t) ("Provider" 12 t) ("Sequence" 9 t)
         ("Duration ms" 13 t) ("Status" 8 t) ("Buffer" 20 t)])
  (setq tabulated-list-padding 2
        tabulated-list-entries #'etaf-performance--tabulated-entries
        header-line-format (etaf-performance--panel-environment-line))
  (tabulated-list-init-header))

(define-key etaf-performance-panel-mode-map (kbd "c")
            #'etaf-performance-copy-report)
(define-key etaf-performance-panel-mode-map (kbd "w")
            #'etaf-performance-export)

;;;###autoload
(defun etaf-performance-show ()
  "Show retained ETAF operations and stages in a tabulated panel."
  (interactive)
  (let ((buffer (get-buffer-create "*ETAF Performance*")))
    (with-current-buffer buffer
      (etaf-performance-panel-mode)
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

(provide 'etaf-performance)

;;; etaf-performance.el ends here
