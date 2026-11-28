;;; etaf-async-tests.el --- Public asynchronous loading behavior -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Native timers and external adapter callbacks exercise Resource/Data ownership.

;;; Code:
(require 'ert)
(require 'etaf)

(defun etaf-async-test-wait (predicate)
  "Process native callbacks until PREDICATE succeeds, with a bounded deadline."
  (let ((deadline (+ (float-time) 2)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.005))
    (should (funcall predicate))))

(ert-deftest etaf-async-resource-native-timer-refreshes-retained-value ()
  "Native completion replaces a retained value and releases it once."
  (let ((generation 0) released resource)
    (setq resource
          (etaf-resource
           (lambda ()
             (let ((value (cl-incf generation)))
               (etaf-async
                (lambda (resolve _reject)
                  (let ((timer
                         (run-at-time
                          0.02 nil resolve
                          (etaf-resource-result
                           value :cleanup (lambda () (push value released))))))
                    (lambda () (cancel-timer timer)))))))
           :immediate nil :keep-value t))
    (unwind-protect
        (progn
          (should (eq 'idle (etaf-resource-status resource)))
          (etaf-resource-load resource)
          (should (eq 'loading (etaf-resource-status resource)))
          (etaf-async-test-wait (lambda () (eq 'success (etaf-resource-status resource))))
          (should (= 1 (etaf-resource-value resource)))
          (etaf-resource-load resource)
          (should (eq 'refreshing (etaf-resource-status resource)))
          (should (= 1 (etaf-resource-value resource)))
          (should-not released)
          (etaf-async-test-wait (lambda () (eq 'success (etaf-resource-status resource))))
          (should (= 2 (etaf-resource-value resource)))
          (should (equal '(1) released)))
      (etaf-resource-dispose resource))
    (should (equal '(2 1) released))))

(ert-deftest etaf-async-resource-reject-cancel-timeout-and-retry ()
  "Failures retain optional old data, timeout cancels work, and reload retries."
  (let ((initial t) resolve reject (cancelled 0) resource)
    (setq resource
          (etaf-resource
           (lambda ()
             (if initial (progn (setq initial nil) 'ready)
               (etaf-async
                (lambda (yes no)
                  (setq resolve yes reject no)
                  (lambda () (cl-incf cancelled))))))
           :keep-value t :timeout 0.03))
    (unwind-protect
        (progn
          (etaf-resource-load resource)
          (funcall reject '(file-error "service unavailable"))
          (should (equal '(file-error "service unavailable") (etaf-resource-error resource)))
          (should (eq 'ready (etaf-resource-value resource)))
          (etaf-resource-load resource)
          (etaf-resource-cancel resource)
          (should (eq 'cancelled (etaf-resource-status resource)))
          (funcall resolve 'obsolete)
          (should (eq 'ready (etaf-resource-value resource)))
          (etaf-resource-load resource)
          (etaf-async-test-wait (lambda () (eq 'error (etaf-resource-status resource))))
          (should (eq 'etaf-async-timeout (car (etaf-resource-error resource))))
          (should (= 2 cancelled))
          (etaf-resource-load resource)
          (funcall resolve 'recovered)
          (should (eq 'success (etaf-resource-status resource)))
          (should (eq 'recovered (etaf-resource-value resource))))
      (etaf-resource-dispose resource))))

(ert-deftest etaf-async-resource-discards-old-and-duplicate-completions ()
  "Uncancellable old results cannot replace new data and transfer cleanup once."
  (let (completions released resource)
    (setq resource
          (etaf-resource
           (lambda ()
             (etaf-async (lambda (resolve _reject) (push resolve completions) nil)))))
    (unwind-protect
        (let* ((old (car completions))
               (old-value (etaf-resource-result 'old :cleanup (lambda () (push 'old released)))))
          (etaf-resource-load resource)
          (funcall (car completions)
                   (etaf-resource-result 'new :cleanup (lambda () (push 'new released))))
          (funcall old old-value)
          (funcall old old-value)
          (should (eq 'new (etaf-resource-value resource)))
          (should (equal '(old) released))
          (etaf-resource-dispose resource)
          (should (equal '(new old) released)))
      (etaf-resource-dispose resource))))

(ert-deftest etaf-async-validates-adapters-and-synchronous-page-preparation ()
  "Invalid adapters become errors; synchronous preparation never starts async IO."
  (should-error (etaf-async 42) :type 'wrong-type-argument)
  (should-error (etaf-resource (lambda () nil) :timeout 0) :type 'etaf-async-error)
  (dolist (start (list (lambda (_yes _no) (error "cannot start"))
                      (lambda (_yes _no) 42)
                      (lambda (_yes no) (funcall no "invalid condition") nil)))
    (let ((resource (etaf-resource (lambda () (etaf-async start)))))
      (unwind-protect
          (should (eq 'error (etaf-resource-status resource)))
        (etaf-resource-dispose resource))))
  (let* ((started nil)
         (source (etaf-data-source
                  :load (lambda (&rest _args)
                          (etaf-async (lambda (_yes _no) (setq started t)))))))
    (should-error (etaf-data-source-load-page source) :type 'etaf-async-error)
    (should-not started)))

(ert-deftest etaf-async-data-native-search-keeps-only-current-result ()
  "A slow old search finishing after a new search cannot change the current page."
  (let (finished timers controller)
    (setq controller
          (etaf-data-controller
           (etaf-data-source
            :load
            (lambda (query _page _size)
              (etaf-async
               (lambda (resolve _reject)
                 (push (run-at-time
                        (if (equal query "old") 0.06 0.01) nil
                        (lambda ()
                          (funcall resolve (list :items (list query) :total 1 :page 1))
                          (push query finished))) timers)
                 nil))))
           :query "old" :auto-load t))
    (unwind-protect
        (progn
          (should (eq 'loading (etaf-value (etaf-data-status controller))))
          (etaf-data-set-query controller "new")
          (etaf-async-test-wait (lambda () (member "new" finished)))
          (should (equal '("new") (etaf-value (etaf-data-items controller))))
          (etaf-async-test-wait (lambda () (member "old" finished)))
          (should (equal '("new") (etaf-value (etaf-data-items controller))))
          (should (eq 'success (etaf-value (etaf-data-status controller))))
          (etaf-data-reload controller)
          (should (eq 'refreshing (etaf-value (etaf-data-status controller)))))
      (etaf-data-stop controller)
      (mapc #'cancel-timer timers))))

(ert-deftest etaf-async-data-cancel-timeout-and-malformed-result-retain-items ()
  "Cancellation, timeout and invalid source pages preserve the accepted collection."
  (let (resolve (cancelled 0) controller)
    (setq controller
          (etaf-data-controller
           (etaf-data-source
            :load (lambda (&rest _args)
                    (etaf-async
                     (lambda (yes _no)
                       (setq resolve yes)
                       (lambda () (cl-incf cancelled))))))
           :initial-result '(:items (saved) :total 1) :timeout 0.02))
    (unwind-protect
        (progn
          (etaf-data-load controller)
          (etaf-data-cancel controller)
          (should (eq 'cancelled (etaf-value (etaf-data-status controller))))
          (funcall resolve '(:items (late)))
          (etaf-data-load controller)
          (etaf-async-test-wait (lambda () (eq 'error (etaf-value (etaf-data-status controller)))))
          (should (eq 'etaf-async-timeout (car (etaf-value (etaf-data-error controller)))))
          (should (= 2 cancelled))
          (etaf-data-load controller)
          (funcall resolve 'invalid-page)
          (should (eq 'error (etaf-value (etaf-data-status controller))))
          (should (equal '(saved) (etaf-value (etaf-data-items controller))))
          (etaf-data-load controller)
          (funcall resolve '(:items (recovered)))
          (should (equal '(recovered) (etaf-value (etaf-data-items controller)))))
      (etaf-data-stop controller))))

(ert-deftest etaf-async-data-committed-write-retries-only-failed-refresh ()
  "An asynchronous committed write is never replayed when its refresh fails."
  (let ((writes 0) (fail-read t) timer controller)
    (setq controller
          (etaf-data-controller
           (etaf-data-source
            :load (lambda (&rest _args)
                    (etaf-async
                     (lambda (resolve reject)
                       (setq timer (run-at-time
                                    0.01 nil
                                    (lambda ()
                                      (if fail-read (funcall reject '(error "refresh failed"))
                                        (funcall resolve '(:items (saved) :total 1))))))
                       (lambda () (cancel-timer timer)))))
            :mutate-v2 (lambda (_op _payload)
                         (etaf-async
                          (lambda (resolve _reject)
                            (setq timer
                                  (run-at-time 0.01 nil
                                               (lambda ()
                                                 (cl-incf writes)
                                                 (funcall resolve '(:certainty committed :result saved)))))
                            (lambda () (cancel-timer timer))))))))
    (unwind-protect
        (progn
          (should-not (etaf-data-mutate controller 'save 'draft))
          (should (plist-get (etaf-data-mutation-outcome controller) :pending-p))
          (should-error (etaf-data-mutate controller 'save 'draft) :type 'etaf-data-error)
          (etaf-async-test-wait (lambda () (eq 'error (etaf-value (etaf-data-status controller)))))
          (should (= 1 writes))
          (should (eq 'committed (plist-get (etaf-data-mutation-outcome controller) :certainty)))
          (should-not (plist-get (etaf-data-mutation-outcome controller) :pending-p))
          (setq fail-read nil)
          (etaf-data-retry-reconciliation controller)
          (etaf-async-test-wait (lambda () (eq 'success (etaf-value (etaf-data-status controller)))))
          (should (equal '(saved) (etaf-value (etaf-data-items controller))))
          (should (eq 'reconciled (etaf-data-reconciliation-state controller)))
          (should-not (etaf-data-retry-reconciliation controller))
          (should (= 1 writes)))
      (etaf-data-stop controller)
      (when timer (cancel-timer timer)))))

(ert-deftest etaf-async-data-write-certainty-survives-cancel-and-rejection ()
  "Only explicit provider evidence means rollback; cancelled writes remain unknown."
  (dolist (mode '(rollback reject cancel timeout unknown malformed))
    (let (resolve reject controller)
      (setq controller
            (etaf-data-controller
             (etaf-data-source
              :load (lambda (&rest _args) '(:items nil))
              :mutate-v2
              (lambda (&rest _args)
                (etaf-async (lambda (yes no) (setq resolve yes reject no) nil))))
             :timeout 0.02))
      (unwind-protect
          (progn
            (etaf-data-mutate controller 'save 'draft)
            (pcase mode
              ('rollback (funcall resolve '(:certainty rolled-back :error (error "rejected"))))
              ('reject (funcall reject '(error "connection lost")))
              ('cancel (etaf-data-cancel controller))
              ('timeout (etaf-async-test-wait
                         (lambda () (eq 'error (etaf-value (etaf-data-status controller))))))
              ('unknown (funcall resolve '(:certainty external-unknown)))
              ('malformed (funcall resolve 'invalid-outcome)))
            (should (eq (if (eq mode 'rollback) 'rolled-back 'external-unknown)
                        (plist-get (etaf-data-mutation-outcome controller) :certainty)))
            (should-not (plist-get (etaf-data-mutation-outcome controller) :pending-p))
            (should-not (etaf-data-retry-reconciliation controller))
            (when (memq mode '(cancel timeout))
              (funcall resolve '(:certainty committed :result late))
              (should (eq 'external-unknown
                          (plist-get (etaf-data-mutation-outcome controller) :certainty)))))
        (etaf-data-stop controller)))))

(etaf-define-component etaf-async-test-owner (&key loader source ready)
  :bindings ((resource (etaf-resource loader :immediate nil))
             (data (etaf-data-controller source)))
  :setup (etaf-on-mounted
          (lambda () (funcall ready resource data)
            (etaf-resource-load resource) (etaf-data-load data)))
  :view (column
          (text (expr (format "%s %s" (etaf-resource-status resource)
                              (etaf-value (etaf-data-status data)))))
          (text (expr (format "%S" (etaf-value (etaf-data-items data)))))))

(ert-deftest etaf-async-mounted-owner-unmount-invalidates-late-work ()
  "Unmount cancels owned work; late success cleans up without reviving the UI."
  (let ((buffer (generate-new-buffer " *async-owner*"))
        resource data finish-resource finish-data finish-write
        (cancelled 0) (released 0) (external-writes 0) items status runtime)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-async-test-owner
             :loader (lambda () (etaf-async
                                 (lambda (resolve _reject)
                                   (setq finish-resource resolve)
                                   (lambda () (cl-incf cancelled)))))
             :source (etaf-data-source
                      :load (lambda (&rest _args)
                              (etaf-async (lambda (resolve _reject) (setq finish-data resolve) nil)))
                      :mutate (lambda (&rest _args)
                                (etaf-async (lambda (resolve _reject)
                                              (setq finish-write
                                                    (lambda () (cl-incf external-writes)
                                                      (funcall resolve 'saved))) nil))))
             :ready (lambda (r d) (setq resource r data d)))))
          (setq runtime (etaf-runtime-for-buffer buffer)
                items (etaf-data-items data) status (etaf-data-status data))
          (should (string-match-p "loading loading" (with-current-buffer buffer (buffer-string))))
          (etaf-data-mutate data 'save 'draft)
          (etaf-unmount runtime)
          (funcall finish-resource (etaf-resource-result 'late :cleanup (lambda () (cl-incf released))))
          (funcall finish-data '(:items (late)))
          (funcall finish-write)
          (should (= 1 external-writes))
          (should (= 1 cancelled))
          (should (= 1 released))
          (should-not (etaf-value items))
          (should (eq 'loading (etaf-value status)))
          (should-not (etaf-runtime-for-buffer buffer))
          (should-error (etaf-resource-load resource) :type 'etaf-resource-error)
          (should-error (etaf-data-load data) :type 'etaf-data-stopped-error))
      (when (etaf-runtime-for-buffer buffer) (etaf-unmount (etaf-runtime-for-buffer buffer)))
      (kill-buffer buffer))))

(ert-deftest etaf-async-resource-publication-error-is-not-loader-error ()
  "A completion preserves its accepted value when an observer fails."
  (let (resolve resource stop)
    (setq resource (etaf-resource
                    (lambda () (etaf-async (lambda (yes _no) (setq resolve yes) nil)))))
    (setq stop (etaf-watch (lambda () (etaf-resource-value resource))
                          (lambda (_new _old) (error "observer failed"))))
    (unwind-protect
        (progn
          (should-error (funcall resolve 'accepted))
          (should (eq 'success (etaf-resource-status resource)))
          (should (eq 'accepted (etaf-resource-value resource)))
          (should-not (etaf-resource-error resource)))
      (funcall stop)
      (etaf-resource-dispose resource))))

(ert-deftest etaf-async-resource-cleanup-cannot-revive-an-old-request ()
  "Cleanup may start a newer request or dispose the owner without stale publication."
  (dolist (dispose '(nil t))
    (let ((value 0) (released 0) resolve resource)
      (setq resource
            (etaf-resource
             (lambda ()
               (cl-incf value)
               (if (= value 1)
                   (etaf-resource-result
                    'initial :cleanup (lambda ()
                                        (if dispose (etaf-resource-dispose resource)
                                          (etaf-resource-load resource))))
                 (etaf-async (lambda (yes _no) (setq resolve yes) nil))))
             :keep-value t))
      (unwind-protect
          (progn
            (etaf-resource-load resource)
            (funcall resolve (etaf-resource-result 'obsolete :cleanup (lambda () (cl-incf released))))
            (should (= 1 released))
            (if dispose
                (should-error (etaf-resource-load resource) :type 'etaf-resource-error)
              (should (eq 'refreshing (etaf-resource-status resource)))
              (funcall resolve 'latest)
              (should (eq 'latest (etaf-resource-value resource)))))
        (etaf-resource-dispose resource)))))

(ert-deftest etaf-async-cancellation-during-start-releases-returned-handle ()
  "Cancellation inside START still releases the handle returned afterward."
  (let ((cancelled 0) resource)
    (setq resource
          (etaf-resource
           (lambda ()
             (etaf-async
              (lambda (resolve _reject)
                (etaf-resource-cancel resource)
                (funcall resolve 'late)
                (lambda () (cl-incf cancelled)))))
           :immediate nil))
    (unwind-protect
        (progn
          (etaf-resource-load resource)
          (should (eq 'cancelled (etaf-resource-status resource)))
          (should-not (etaf-resource-value resource))
          (should (= 1 cancelled)))
      (etaf-resource-dispose resource))))

(ert-deftest etaf-async-resource-example-renders-real-loading-and-cancellation ()
  "The shipped example handles asynchronous success, refresh, failure and cancel."
  (let ((buffer (etaf-resource-example-open)))
    (unwind-protect
        (cl-labels ((shows (text)
                      (with-current-buffer buffer (string-match-p text (buffer-string))))
                    (press (ref)
                      (etaf-dispatch-event (etaf-runtime-for-buffer buffer) ref 'press)))
          (should (shows "LOADING"))
          (etaf-async-test-wait (lambda () (shows "Generation 1 is healthy")))
          (press 'resource-reload)
          (should (shows "REFRESHING"))
          (should (shows "Generation 1 is healthy"))
          (press 'resource-cancel)
          (should (shows "CANCELLED"))
          (press 'resource-fail)
          (etaf-async-test-wait (lambda () (shows "Synthetic service failure 3")))
          (press 'resource-reload)
          (etaf-async-test-wait (lambda () (shows "Generation 4 is healthy")))
          (should (shows "CLEANUPS  1")))
      (etaf-resource-example-close))
    (should-not (buffer-live-p buffer))))

(ert-deftest etaf-async-data-outcome-is-reactive-while-status-stays-loading ()
  "A pending write and its commit are observable even before first page completion."
  (let* (resolve stop seen
        (controller
         (etaf-data-controller
          (etaf-data-source
           :load (lambda (&rest _args) (etaf-async (lambda (_yes _no) nil)))
           :mutate (lambda (&rest _args)
                     (etaf-async (lambda (yes _no) (setq resolve yes) nil))))
          :auto-load t)))
    (setq stop
          (etaf-watch (lambda () (etaf-data-mutation-outcome controller))
                      (lambda (new _old) (push new seen))))
    (unwind-protect
        (progn
          (etaf-data-mutate controller 'save 'draft)
          (should (plist-get (car seen) :pending-p))
          (should (eq 'loading (etaf-value (etaf-data-status controller))))
          (funcall resolve 'saved)
          (should (eq 'committed (plist-get (car seen) :certainty)))
          (should-not (plist-get (car seen) :pending-p))
          (should (eq 'loading (etaf-value (etaf-data-status controller)))))
      (funcall stop)
      (etaf-data-stop controller))))

(provide 'etaf-async-tests)
;;; etaf-async-tests.el ends here
