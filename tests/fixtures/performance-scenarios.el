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
          (lambda (_sample)
            (cl-incf count)
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
            (when sink
              (funcall sink buffer (list :provider 'fixture :stage 'update :duration-ms 0.01))))
          :settled (lambda () settled)
          :verify (lambda ()
                    (if (eq kind 'fail) "Deliberate verification failure"
                      (with-current-buffer buffer (equal (buffer-string) (number-to-string count)))))
          :observe (lambda (collector) (setq sink collector) (lambda () (setq sink nil)))
          :cleanup (lambda ()
                     (mapc #'cancel-timer timers)
                     (when (buffer-live-p buffer) (kill-buffer buffer))
                     (unless (equal profile-settings (cons profiler-max-stack-depth profiler-sampling-interval))
                       (error "The driver did not restore profiler settings"))))))

(dolist (kind '(counter async fail timeout slow context hot))
  (let ((variant kind))
    (taf-benchmark-register
     (format "fixture.%s" variant) :version 1 :modes '(batch) :budget-ms (if (eq kind 'slow) 5 100)
     :required-providers '(fixture) :isolation 'series :impact 'local
     :description "Tool protocol fixture"
     :setup (lambda (_mode) (taf-test-fixture variant)))))
