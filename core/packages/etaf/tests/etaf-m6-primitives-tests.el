;;; etaf-m6-primitives-tests.el --- Tests for View sugar, store, Portal and Suspense -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(ert-deftest etaf-view-declarative-when-unless-cond-and-let ()
  "Native when/unless/cond/let/let* and inline text expressions update reactively."
  (let ((flag (etaf-ref nil))
        (stage (etaf-ref 'idle))
        (count (etaf-ref 1)))
    (etaf-test-with-mount
        (_runtime
         (etaf-view
          (column
            (when (etaf-value flag)
              (text "shown-when")
              (text "extra-when"))
            (unless (etaf-value flag)
              (text "shown-unless"))
            (cond
             ((eq (etaf-value stage) 'idle) (text "stage-idle"))
             ((eq (etaf-value stage) 'busy) (text "stage-busy"))
             (t (text "stage-done")))
            (let* ((n (etaf-value count))
                   (doubled (* 2 n)))
              (text :font-weight (expr (if (> n 1) 'bold 'normal))
                    (format "n=%d d=%d" n doubled))))))
      (should (equal (etaf-test-lines) '("shown-unless" "stage-idle" "n=1 d=2")))
      (etaf-set-value flag t)
      (should (equal (etaf-test-lines)
                     '("shown-when" "extra-when" "stage-idle" "n=1 d=2")))
      (etaf-set-value stage 'busy)
      (should (equal (etaf-test-lines)
                     '("shown-when" "extra-when" "stage-busy" "n=1 d=2")))
      (etaf-set-value stage 'other)
      (etaf-set-value count 3)
      (should (equal (etaf-test-lines)
                     '("shown-when" "extra-when" "stage-done" "n=3 d=6")))
      (should (eq (etaf-test-face-attribute (etaf-test-face-at "n=3 d=6") :weight)
                  'bold)))))

(ert-deftest etaf-store-path-isolation-and-updates ()
  "Updating one store path notifies only that branch and ancestors, never siblings."
  (let* ((store (etaf-store-create
                 '(:user (:name "Alice" :role "dev")
                   :filter (:query "" :limit 20))
                 :name 'test-store))
         (name-runs 0)
         (query-runs 0)
         (user-runs 0)
         (upper-name (etaf-store-select store '(:user :name) #'upcase))
         (stop-name (etaf-watch-effect
                     (lambda ()
                       (etaf-store-get store :user :name)
                       (cl-incf name-runs))))
         (stop-query (etaf-watch-effect
                      (lambda ()
                        (etaf-store-get store :filter :query)
                        (cl-incf query-runs))))
         (stop-user (etaf-watch-effect
                     (lambda ()
                       (etaf-store-get store :user)
                       (cl-incf user-runs)))))
    (unwind-protect
        (progn
          (should (etaf-store-p store))
          (should (equal (etaf-value upper-name) "ALICE"))
          (should (= name-runs 1))
          (should (= query-runs 1))
          (should (= user-runs 1))
          ;; Writing :filter :query must NOT wake :user or :user :name subscribers.
          (etaf-store-set store '(:filter :query) "etaf")
          (should (= query-runs 2))
          (should (= name-runs 1))
          (should (= user-runs 1))
          ;; Writing identical value is a no-op.
          (etaf-store-set store '(:filter :query) "etaf")
          (should (= query-runs 2))
          ;; Writing :user :name wakes :user :name and ancestor :user, not :filter :query.
          (etaf-store-update store '(:user :name) (lambda (s) (concat s "!")))
          (should (equal (etaf-value upper-name) "ALICE!"))
          (should (= name-runs 2))
          (should (= user-runs 2))
          (should (= query-runs 2))
          ;; Atomic patch updates both branches in one batch.
          (etaf-store-patch store
                            '(:user :role) "lead"
                            '(:filter :limit) 50)
          (should (equal (etaf-store-get store :user :role) "lead"))
          (should (= (etaf-store-get store :filter :limit) 50))
          ;; Snapshot is detached; reset restores initial values cleanly.
          (let ((snap (etaf-store-snapshot store)))
            (should (equal (plist-get (plist-get snap :user) :name) "Alice!")))
          (etaf-store-reset store)
          (should (equal (etaf-store-get store :user :name) "Alice"))
          (should (equal (etaf-store-get store :filter :query) "")))
      (funcall stop-name)
      (funcall stop-query)
      (funcall stop-user))))

(ert-deftest etaf-start-transition-defers-updates-and-tracks-pending ()
  "Deferred transitions track pending state and settle cleanly on the next turn."
  (let* ((value (etaf-ref 'initial))
         (pending (etaf-ref nil))
         (completed nil)
         (cancel-called nil))
    (etaf-start-transition
     (lambda () (etaf-set-value value 'settled))
     :pending pending
     :on-complete (lambda () (setq completed t)))
    (should (etaf-value pending))
    (should (etaf-transition-pending-p))
    (should (eq (etaf-value value) 'initial))
    (accept-process-output nil 0.02)
    (should (eq (etaf-value value) 'settled))
    (should-not (etaf-value pending))
    (should-not (etaf-transition-pending-p))
    (should completed)
    ;; Cancellation prevents execution and clears pending immediately.
    (let ((cancel (etaf-start-transition
                   (lambda () (setq cancel-called t))
                   :pending pending)))
      (should (etaf-value pending))
      (funcall cancel)
      (should-not (etaf-value pending))
      (accept-process-output nil 0.02)
      (should-not cancel-called))))

(ert-deftest etaf-portal-in-buffer-header-line-and-host-registry ()
  "Portal mounts into root overlay, projects header-line, and supports custom hosts."
  (let ((open-ov (etaf-ref t))
        (open-hl (etaf-ref t))
        (hl-text (etaf-ref "Portal Header 1"))
        (custom-opened nil)
        (custom-closed nil))
    ;; 1. Host registry roundtrip
    (unwind-protect
        (progn
          (etaf-portal-register-host
           'test-target
           (lambda (spec)
             (setq custom-opened (plist-get spec :title))
             (list :close (lambda () (setq custom-closed t)))))
          (should (functionp (etaf-portal-host 'test-target))))
      (etaf-portal-register-host 'test-target nil)
      (should-not (etaf-portal-host 'test-target)))
    (ignore custom-opened custom-closed)
    ;; 2. In-buffer overlay portal escapes parent container, preserves underlying
    ;;    canvas outside its bounds, and cleans up on close.
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column :width '(ch 40) :height '(lh 5)
            (box :height '(lh 1) (text "base-row-0"))
            (box :height '(lh 1) (text "base-row-1"))
            (etaf-portal :target 'in-buffer :open open-ov :name 'test-ov
              (box :position 'absolute :top '(lh 3) :left '(ch 0) :height '(lh 1)
                (text "portal-overlay-body")))
            (etaf-portal :target 'header-line :open open-hl
                         :header-format (lambda () (etaf-value hl-text))))))
      (should (etaf-runtime-overlay-active-p runtime))
      (should (cl-some (lambda (l) (string-match-p "base-row-0" l))
                       (etaf-test-lines)))
      (should (cl-some (lambda (l) (string-match-p "portal-overlay-body" l))
                       (etaf-test-lines)))
      (should (equal header-line-format "Portal Header 1"))
      (etaf-set-value hl-text "Portal Header 2")
      (should (equal header-line-format "Portal Header 2"))
      (etaf-set-value open-ov nil)
      (etaf-set-value open-hl nil)
      (should-not (etaf-runtime-overlay-active-p runtime))
      (should-not header-line-format))))

(ert-deftest etaf-suspense-aggregates-resources-delay-and-errors ()
  "Suspense waits for multiple Resources, honors anti-flicker delay and error fallback."
  (let* ((resolve-a nil)
         (resolve-b nil)
         (reject-b nil)
         (res-a (etaf-resource
                 (lambda ()
                   (etaf-async (lambda (res _rej) (setq resolve-a res) nil)))))
         (res-b (etaf-resource
                 (lambda ()
                   (etaf-async (lambda (res rej)
                                 (setq resolve-b res reject-b rej)
                                 nil))))))
    (unwind-protect
        (progn
          (etaf-test-with-mount
              (_runtime
               (etaf-view
                (etaf-suspense
                 :resources (list res-a res-b)
                 :fallback (etaf-view (text "loading-both"))
                 :error-fallback (lambda (errs)
                                   (etaf-node 'text nil
                                              (list (format "err:%d" (length errs)))))
                 (text (format "ready:%s+%s"
                               (etaf-resource-value res-a)
                               (etaf-resource-value res-b))))))
            (should (equal (etaf-test-lines) '("loading-both")))
            ;; Resolving only A keeps fallback visible while B is still loading.
            (funcall resolve-a "A")
            (should (equal (etaf-test-lines) '("loading-both")))
            ;; Resolving B flips to settled slot content.
            (funcall resolve-b "B")
            (should (equal (etaf-test-lines) '("ready:A+B")))
            ;; Reloading B and failing triggers :error-fallback.
            (etaf-resource-load res-b)
            (should (equal (etaf-test-lines) '("loading-both")))
            (funcall reject-b '(error "boom"))
            (should (equal (etaf-test-lines) '("err:1"))))
          ;; Anti-flicker delay suppresses immediate fallback until timer fires.
          (let* ((resolve-c nil)
                 (res-c (etaf-resource
                         (lambda ()
                           (etaf-async (lambda (res _rej) (setq resolve-c res) nil))))))
            (unwind-protect
                (etaf-test-with-mount
                    (_runtime
                     (etaf-view
                      (etaf-suspense
                       :resources res-c
                       :delay 0.03
                       :fallback (etaf-view (text "delayed-fallback"))
                       (text (format "got:%s" (etaf-resource-value res-c))))))
                  (should-not (cl-some (lambda (l) (string-match-p "delayed-fallback" l))
                                       (etaf-test-lines)))
                  (accept-process-output nil 0.06)
                  (should (equal (etaf-test-lines) '("delayed-fallback")))
                  (funcall resolve-c "fast")
                  (should (equal (etaf-test-lines) '("got:fast"))))
              (etaf-resource-dispose res-c))))
      (etaf-resource-dispose res-a)
      (etaf-resource-dispose res-b))))

(provide 'etaf-m6-primitives-tests)
;;; etaf-m6-primitives-tests.el ends here
