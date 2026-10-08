;;; performance-gate.el --- Fast GUI latency gate over registered scenarios -*- lexical-binding: t; -*-

;;; Commentary:
;; Development-tool interface, loaded by `scripts/performance.py gate'.
;; Function: taf-gate-start (configuration-file)
;; Load the configured scenario files, then run every matching scenario that
;; declares :gate back to back in the selected GUI window.  Each sample times
;; the fixture's :invoke and the following forced redisplay.  The JSON report
;; at the configuration's output path is rewritten after every scenario and
;; ends with status "done" or "error".
;;
;; Timed samples run unobserved and their conses exclude the measurement's
;; own; scenario files load from current byte-compiled copies.
;;
;; A scenario's :gate plist selects its budget class (:class) and may give
;; :rows for row-proportional classes.  A twin runs a second, untimed pass
;; from a snapshot of the buffer.  :twin diff measures the editing floor:
;; the fixture's :observe reports carry :ranges, (START OLD NEW) line
;; replacements in application order.  After each sample of that pass the
;; runner derives the smallest plain-buffer edit that yields the same text
;; and properties, then replays those edits on the snapshot with the same
;; redisplay timing, keeping point where the fixture keeps it so Emacs's
;; redisplay of the line at point does not favor the twin; text is compared
;; after every sample and text properties after the first and last.
;; :twin replay times the second pass's :invoke on the snapshot shown in the
;; selected window, for operations such as scrolling that act on the current
;; buffer.
;; Function: taf-gate-running-p ()
;; Return non-nil while a gate job is active.

;;; Code:
(require 'cl-lib)
(load (expand-file-name "performance-driver" (file-name-directory
                                              (or load-file-name buffer-file-name)))
      nil t)

(defvar taf-gate--job nil
  "Plist of the active gate job, or nil.")

(defvar taf-gate--report nil
  "Report plist written to the job's output file.")

(defconst taf-gate--warmups 5
  "Untimed operations before each scenario's samples.")

(defun taf-gate-running-p ()
  "Return non-nil while a gate job is active."
  (and taf-gate--job t))

(defconst taf-gate--display-variables
  '(truncate-lines word-wrap line-spacing bidi-display-reordering
    bidi-paragraph-direction long-line-threshold overline-margin
    header-line-format mode-line-format buffer-invisibility-spec)
  "Buffer-local display settings copied to twin buffers.")

(defun taf-gate--json (value)
  "Return VALUE with plists converted to `json-serialize' alists."
  (cond ((and (consp value) (keywordp (car value)))
         (let (out)
           (while value
             (push (cons (intern (substring (symbol-name (car value)) 1))
                         (taf-gate--json (cadr value)))
                   out)
             (setq value (cddr value)))
           (nreverse out)))
        ((eq value t) t)
        ((null value) :null)
        ((symbolp value) (symbol-name value))
        ((consp value) (vconcat (mapcar #'taf-gate--json value)))
        (t value)))

(defun taf-gate--save ()
  "Write the report atomically."
  (let* ((output (plist-get taf-gate--job :output))
         (pending (concat output ".tmp"))
         (coding-system-for-write 'utf-8-unix))
    (with-temp-file pending
      (insert (json-serialize (taf-gate--json taf-gate--report))))
    (rename-file pending output t)))

(defun taf-gate--message (condition)
  "Return a bounded description of error CONDITION.
Conditions may carry cyclic engine structures, so printing is limited."
  (let* ((print-circle t) (print-length 6) (print-level 3)
         (message (error-message-string condition)))
    (if (> (length message) 300) (concat (substring message 0 300) "...") message)))

(defun taf-gate--load (files)
  "Load scenario FILES and return their registrations in order."
  (let (registry)
    (cl-letf (((symbol-function 'taf-benchmark-register)
               (lambda (id &rest properties) (push (cons id properties) registry))))
      (dolist (file files) (taf-benchmark-load-scenarios file)))
    (nreverse registry)))

(defun taf-gate--show (buffer)
  "Show BUFFER alone in the selected window at its start."
  (delete-other-windows)
  (set-window-buffer (selected-window) buffer)
  (set-buffer buffer)
  (goto-char (point-min))
  (set-window-point (selected-window) (point-min))
  (set-window-start (selected-window) (point-min))
  (redisplay t))

(defun taf-gate--line-region (start count)
  "Return (BEG . END) of COUNT lines from line START plus one line on each side."
  (save-excursion
    (goto-char (point-min))
    (forward-line (max 0 (1- start)))
    (let ((beg (point)))
      (forward-line (+ count (if (> start 0) 1 0)))
      (cons beg (line-end-position)))))

(defun taf-gate--common-prefix (a b)
  "Return the length of A and B's common prefix, text properties included."
  (let* ((limit (min (length a) (length b)))
         (text (compare-strings a 0 limit b 0 limit))
         (limit (if (eq text t) limit (1- (abs text))))
         (i 0))
    (while (and (< i limit) (equal (text-properties-at i a) (text-properties-at i b)))
      (setq i (min (next-property-change i a limit) (next-property-change i b limit))))
    (min i limit)))

(defun taf-gate--common-suffix (a b limit)
  "Return the length of A and B's common suffix, at most LIMIT, with properties."
  (let ((la (length a)) (lb (length b)) (low 0) (high limit) (s 0))
    ;; Suffix equality is monotone in its length, so bisect it in C.
    (while (< low high)
      (let ((middle (/ (+ low high 1) 2)))
        (if (eq t (compare-strings a (- la middle) la b (- lb middle) lb))
            (setq low middle)
          (setq high (1- middle)))))
    (while (and (< s low)
                (equal (text-properties-at (- la s 1) a) (text-properties-at (- lb s 1) b)))
      (setq s (min low (- la (previous-property-change (- la s) a (- la low)))
                   (- lb (previous-property-change (- lb s) b (- lb low))))))
    (min s low)))

(defun taf-gate--minimal-edit (old new beg)
  "Return the smallest edit turning OLD into NEW at buffer position BEG, or nil."
  (let* ((p (taf-gate--common-prefix old new))
         (s (taf-gate--common-suffix old new (- (min (length old) (length new)) p)))
         (a (substring old p (- (length old) s)))
         (b (substring new p (- (length new) s))))
    (cond ((and (string-empty-p a) (string-empty-p b)) nil)
          ((string= a b) (list 'props (+ beg p) b))
          (t (list 'replace (+ beg p) (length a) b)))))

(defun taf-gate--apply-edit (edit)
  "Apply EDIT from `taf-gate--minimal-edit' to the current buffer."
  (let ((inhibit-read-only t) (position (nth 1 edit)))
    (pcase (car edit)
      ('replace
       (goto-char position)
       (delete-region position (+ position (nth 2 edit)))
       (insert (nth 3 edit)))
      ('props
       (let* ((text (nth 2 edit)) (length (length text)) (i 0))
         (while (< i length)
           (let ((next (or (next-property-change i text) length)))
             (set-text-properties (+ position i) (+ position next)
                                  (text-properties-at i text))
             (setq i next))))))))

(defun taf-gate--record (shadow live ranges)
  "Apply RANGES of LIVE to SHADOW as minimal edits; return the edits."
  (let (edits)
    (dolist (range ranges)
      (pcase-let* ((`(,start ,old ,new) range)
                   (old-region (with-current-buffer shadow (taf-gate--line-region start old)))
                   (new-region (with-current-buffer live (taf-gate--line-region start new)))
                   (edit (taf-gate--minimal-edit
                          (with-current-buffer shadow
                            (buffer-substring (car old-region) (cdr old-region)))
                          (with-current-buffer live
                            (buffer-substring (car new-region) (cdr new-region)))
                          (car old-region))))
        (when edit
          (with-current-buffer shadow (taf-gate--apply-edit edit))
          (push edit edits))))
    (nreverse edits)))

(defun taf-gate--equal-buffers-p (a b &optional properties)
  "Return non-nil when buffers A and B have equal text.
With PROPERTIES, text properties must be equal too."
  (and (= (buffer-size a) (buffer-size b))
       (zerop (with-current-buffer a
                (compare-buffer-substrings a nil nil b nil nil)))
       (or (not properties)
           (equal-including-properties (with-current-buffer a (buffer-string))
                                       (with-current-buffer b (buffer-string))))))

(defun taf-gate--copy-buffer (buffer name)
  "Return a plain buffer NAME with BUFFER's text, properties and display locals."
  (let ((text (with-current-buffer buffer (buffer-string)))
        (locals (with-current-buffer buffer
                  (mapcar (lambda (variable) (cons variable (symbol-value variable)))
                          taf-gate--display-variables)))
        (copy (generate-new-buffer name)))
    (with-current-buffer copy
      (pcase-dolist (`(,variable . ,value) locals)
        (set (make-local-variable variable) value))
      (insert text)
      (goto-char (point-min)))
    copy))

(defvar taf-gate--cons-overhead nil
  "Conses that `taf-gate--time' allocates around an operation that has none.")

(defun taf-gate--time-raw (function)
  "Call FUNCTION and redisplay; return (TOTAL-US OP-US CONSES)."
  (let* ((c0 (car (memory-use-counts)))
         (t0 (current-time))
         (_ (funcall function))
         (t1 (current-time))
         (c1 (car (memory-use-counts)))
         (_ (redisplay t))
         (t2 (current-time)))
    (list (* 1e6 (float-time (time-subtract t2 t0)))
          (* 1e6 (float-time (time-subtract t1 t0)))
          (- c1 c0))))

(defun taf-gate--time (function)
  "Call FUNCTION and redisplay; return (TOTAL-US OP-US CONSES).
CONSES excludes what the measurement itself allocates, calibrated once on
an operation that allocates nothing."
  (unless taf-gate--cons-overhead
    (setq taf-gate--cons-overhead
          (apply #'min (mapcar (lambda (_) (nth 2 (taf-gate--time-raw #'ignore)))
                               '(1 2 3)))))
  (let ((result (taf-gate--time-raw function)))
    (setcar (nthcdr 2 result) (max 0 (- (nth 2 result) taf-gate--cons-overhead)))
    result))

(defun taf-gate--run-scenario (id properties samples)
  "Run scenario ID with PROPERTIES for SAMPLES; return its result plist.
Timed samples run unobserved, so the fixture's report plumbing does not
count against the operation.  A twin then needs a second, untimed pass of
SAMPLES from a snapshot of the buffer: a diff twin records that pass's
ranges and replays them on the snapshot, a replay twin repeats it there."
  (let* ((gate (plist-get properties :gate))
         (twin (plist-get gate :twin))
         (fixture (funcall (plist-get properties :setup) 'gui))
         (buffer (plist-get fixture :buffer))
         (invoke (plist-get fixture :invoke))
         (ranges nil) (stop-observing nil) (shadow nil) (snapshot nil) (base 0)
         totals ops conses edits twin-totals verify twin-error
         (gcs gcs-done))
    (unwind-protect
        (progn
          (taf-gate--show buffer)
          (when-let* ((prepare (plist-get fixture :prepare))) (funcall prepare))
          (dotimes (i taf-gate--warmups)
            (funcall invoke i)
            (redisplay t))
          (garbage-collect)
          (redisplay t)
          (setq gcs gcs-done)
          (dotimes (i samples)
            (let ((index (+ taf-gate--warmups i)))
              (pcase-let ((`(,total ,op ,cons) (taf-gate--time (lambda () (funcall invoke index)))))
                (push total totals) (push op ops) (push cons conses))))
          (setq gcs (- gcs-done gcs))
          (setq verify (condition-case condition (funcall (plist-get fixture :verify))
                         (error (taf-gate--message condition))))
          (when twin
            (setq base (+ taf-gate--warmups samples)
                  snapshot (taf-gate--copy-buffer buffer " *taf-gate twin*"))
            (when (eq twin 'diff)
              (unless (plist-get fixture :observe)
                (error "Scenario %s declares a diff twin without :observe" id))
              (setq shadow (taf-gate--copy-buffer buffer " *taf-gate shadow*")
                    stop-observing (funcall (plist-get fixture :observe)
                                            (lambda (_buffer report)
                                              (setq ranges (append ranges (plist-get report :ranges))))))
              (dotimes (i samples)
                (setq ranges nil)
                (funcall invoke (+ base i))
                (redisplay t)
                (unless twin-error
                  (push (taf-gate--record shadow buffer ranges) edits)
                  (unless (taf-gate--equal-buffers-p shadow buffer (memq i (list 0 (1- samples))))
                    (setq twin-error (format "Reported ranges do not reproduce sample %d" i))))))))
      (when stop-observing (funcall stop-observing))
      (when shadow (kill-buffer shadow))
      (funcall (plist-get fixture :cleanup)))
    (when (and snapshot (not twin-error))
      (taf-gate--show snapshot)
      (setq edits (nreverse edits))
      (dotimes (i samples)
        (let ((index (+ base i)) (sample-edits (nth i edits)))
          (push (car (taf-gate--time
                      (if (eq twin 'diff)
                          (lambda () (save-excursion (mapc #'taf-gate--apply-edit sample-edits)))
                        (lambda () (funcall invoke index)))))
                twin-totals))))
    (when (buffer-live-p snapshot) (kill-buffer snapshot))
    (list :id id :gate gate
          :total (nreverse totals) :op (nreverse ops) :cons (nreverse conses)
          :twin (and twin-totals (nreverse twin-totals))
          :twin-error twin-error :gcs gcs :verify verify)))

(defun taf-gate--step ()
  "Run the next pending scenario, then reschedule."
  (let ((pending (plist-get taf-gate--job :pending)))
    (if (null pending)
        (progn (setf (plist-get taf-gate--report :status) "done")
               (taf-gate--save)
               (setq taf-gate--job nil))
      (let ((entry (car pending)))
        (setf (plist-get taf-gate--job :pending) (cdr pending))
        (setf (plist-get taf-gate--report :active) (car entry))
        (taf-gate--save)
        (let ((result (condition-case condition
                          (taf-gate--run-scenario (car entry) (cdr entry)
                                                  (plist-get taf-gate--job :samples))
                        (error (list :id (car entry) :gate (plist-get (cdr entry) :gate)
                                     :error (taf-gate--message condition))))))
          (setf (plist-get taf-gate--report :results)
                (append (plist-get taf-gate--report :results) (list result)))
          (setf (plist-get taf-gate--report :active) nil)
          (taf-gate--save)
          (run-at-time 0.01 nil #'taf-gate--step))))))

(defun taf-gate-start (configuration-file)
  "Start the gate job described by CONFIGURATION-FILE."
  (when taf-gate--job (error "A gate job is already running"))
  (let* ((configuration (json-parse-string
                         (with-temp-buffer (insert-file-contents configuration-file) (buffer-string))
                         :object-type 'plist :array-type 'list))
         (patterns (plist-get configuration :scenarios))
         (registry (taf-gate--load (plist-get configuration :scenario_files)))
         (selected (cl-remove-if-not
                    (lambda (entry)
                      (and (plist-get (cdr entry) :gate)
                           (cl-some (lambda (pattern) (string-match-p pattern (car entry))) patterns)))
                    registry)))
    (setq taf-gate--job (list :output (plist-get configuration :output)
                              :samples (plist-get configuration :samples)
                              :pending selected)
          taf-gate--report (list :status "running" :total (length selected)
                                 :frame (list :width (window-body-width nil t)
                                              :height (window-body-height nil t)
                                              :font (face-attribute 'default :family))
                                 :results nil))
    (taf-gate--save)
    (run-at-time 0.01 nil #'taf-gate--step)
    'scheduled))

(provide 'performance-gate)

;;; performance-gate.el ends here
