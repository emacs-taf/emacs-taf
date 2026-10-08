;;; performance-scenarios.el --- Shared driver command fixtures -*- lexical-binding: t; -*-
(require 'cl-lib)

(defun taf-test-hot-leaf ()
  "Spend enough CPU time in a known application leaf to resolve its stack."
  (let ((until (+ (float-time) .04)) (count 0))
    (while (< (float-time) until) (setq count (1+ count)))
    count))

(defun taf-test-fixture (kind)
  "Return a self-contained KIND fixture for driver command tests."
  (let ((buffer (generate-new-buffer " *taf-tool-test*")) (count 0)
        (ready nil) (settled t) timers sink
        (profile-settings (cons profiler-max-stack-depth profiler-sampling-interval)))
    (push (run-at-time .01 nil (lambda () (setq ready t))) timers)
    (list :buffer buffer :ready (lambda () ready)
          :invoke
          (lambda (sample)
            (cl-incf count)
            (when (eq kind 'sequence)
              (unless (= sample (1- count))
                (error "Operation index did not advance across warmups"))
              (when (= count 1) (sleep-for .15)))
            (when (and (eq kind 'cold-slow) (= count 1)) (sleep-for .55))
            (when (and (eq kind 'diagnostic-fail) (profiler-running-p))
              (error "Deliberate profiler-pass failure"))
            (when (eq kind 'hot) (taf-test-hot-leaf))
            (pcase kind
              ('timeout (while t (sleep-for .1)))
              ('slow (sleep-for .02)
                     (with-current-buffer buffer (erase-buffer) (insert (number-to-string count))))
              ('context (with-current-buffer buffer
                          (setq-local text-scale-mode-amount 2)
                          (erase-buffer) (insert (number-to-string count))))
              ('async
               (setq settled nil)
               (push (run-at-time .015 nil
                                  (lambda ()
                                    (with-current-buffer buffer
                                      (erase-buffer) (insert (number-to-string count)))
                                    (setq settled t))) timers))
              (_ (with-current-buffer buffer (erase-buffer) (insert (number-to-string count)))))
            (when (and sink (not (eq kind 'diagnostic-fail)))
              (funcall sink buffer (list :provider 'fixture :stage 'update :duration-ms 0.01))
              (funcall sink buffer (list :provider 'ebox :strategy 'full :edits 1 :lines 2
                                         :duration-ms 0.01))))
          :settled (lambda () settled)
          :outcome (lambda ()
                     (when (eq kind 'counter) (sleep-for .12))
                     (list :count count))
          :verify (lambda ()
                    (if (eq kind 'fail) "Deliberate verification failure"
                      (with-current-buffer buffer (equal (buffer-string) (number-to-string count)))))
          :observe (lambda (collector) (setq sink collector) (lambda () (setq sink nil)))
          :cleanup (lambda ()
                     (mapc #'cancel-timer timers)
                     (when (buffer-live-p buffer) (kill-buffer buffer))
                     (when (eq kind 'cleanup-fail) (error "Deliberate cleanup failure"))
                     (unless (equal profile-settings (cons profiler-max-stack-depth profiler-sampling-interval))
                       (error "The driver did not restore profiler settings"))))))

(defvar text-scale-mode-amount 0)
(dolist (kind '(dispose dispose-unexpected dispose-missing dispose-context))
  (let ((variant kind))
    (taf-benchmark-register
     (format "fixture.%s" variant) :version 1 :modes '(batch) :budget-ms 100 :impact 'local
     :setup (lambda (_mode)
              (let ((buffer (generate-new-buffer " *disposal-fixture*")))
                (list :buffer buffer :disposes-buffer (not (eq variant 'dispose-unexpected))
                      :invoke (lambda (_sample)
                                (unless (eq variant 'dispose-missing) (kill-buffer buffer))
                                (when (eq variant 'dispose-context)
                                  (setq text-scale-mode-amount (1+ text-scale-mode-amount))))
                      :verify (lambda () t)
                      :cleanup (lambda () (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(dolist (kind '(counter async fail timeout slow context hot sequence cold-slow diagnostic-fail cleanup-fail))
  (let ((variant kind))
    (taf-benchmark-register
     (format "fixture.%s" variant) :version 1 :modes '(batch) :budget-ms (if (eq kind 'slow) 5 100)
     :required-providers '(fixture) :isolation 'series :impact 'local
     :description "Tool protocol fixture"
     :setup (lambda (_mode) (taf-test-fixture variant)))))

(defun taf-test-gate-fixture (kind)
  "Return a renderer-like gate fixture of KIND over a five-line buffer."
  (let ((buffer (generate-new-buffer " *taf-gate-fixture*")) sink)
    (with-current-buffer buffer
      (dotimes (i 5) (insert (format "row %d\n" i))))
    (list :buffer buffer
          :invoke
          (lambda (sample)
            (if (eq kind 'replay)
                (forward-line (if (cl-evenp sample) 1 -1))
              (with-current-buffer buffer
                ;; Rewrite the whole third line, changing only its face.
                (goto-char (point-min))
                (forward-line 2)
                (delete-region (point) (line-beginning-position 2))
                (insert (propertize "row 2" 'face (and (cl-evenp sample) 'bold)) "\n")
                (when sink
                  (funcall sink buffer (list :ranges (if (eq kind 'wrong-ranges)
                                                         '((0 1 1))
                                                       '((2 1 1)))))))))
          :verify (lambda () (with-current-buffer buffer (= (count-lines (point-min) (point-max)) 5)))
          :observe (lambda (collector) (setq sink collector) (lambda () (setq sink nil)))
          :cleanup (lambda () (kill-buffer buffer)))))

(defun taf-test-gate-prepared-fixture ()
  "Return a gate fixture whose :verify requires :prepare before every invoke."
  (let ((buffer (generate-new-buffer " *taf-gate-prepared*")) (prepared nil) (failure nil))
    (list :buffer buffer
          :prepare (lambda ()
                     (unless (eq (current-buffer) buffer)
                       (setq failure "Prepared outside the fixture buffer"))
                     (setq prepared t))
          :invoke (lambda (sample)
                    (unless prepared
                      (setq failure (format "Sample %d ran without :prepare" sample)))
                    (setq prepared nil))
          :verify (lambda () (or failure t))
          :cleanup (lambda () (kill-buffer buffer)))))

(taf-benchmark-register
 "fixture.gate.prepared" :version 1 :modes '(batch) :budget-ms 100
 :isolation 'series :impact 'local :description "Gate runner :prepare fixture"
 :gate (list :class 'local)
 :setup (lambda (_mode) (taf-test-gate-prepared-fixture)))

(dolist (kind '(rewrite wrong-ranges replay))
  (let ((variant kind))
    (taf-benchmark-register
     (format "fixture.gate.%s" variant) :version 1 :modes '(batch) :budget-ms 100
     :isolation 'series :impact 'local :description "Gate runner fixture"
     :gate (list :class 'local :twin (if (eq variant 'replay) 'replay 'diff))
     :setup (lambda (_mode) (taf-test-gate-fixture variant)))))
