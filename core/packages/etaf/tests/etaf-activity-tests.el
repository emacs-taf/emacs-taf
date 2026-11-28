;;; etaf-activity-tests.el --- Public tests for cross-app activities and notifications -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)

(defmacro etaf-activity-test--clean (&rest body)
  "Run BODY with an isolated clean activity and notification registry."
  `(let ((saved-acts (etaf-activity-list))
         (saved-notes (etaf-notify-list))
         (etaf-activity-change-functions nil)
         (etaf-notify-functions nil))
     (dolist (a saved-acts)
       (etaf-activity-remove (plist-get a :id)))
     (etaf-notify-clear)
     (unwind-protect
         (progn ,@body)
       (dolist (a (etaf-activity-list))
         (etaf-activity-remove (plist-get a :id)))
       (etaf-notify-clear)
       (dolist (a saved-acts)
         (etaf-activity-publish (plist-get a :id) a))
       (dolist (n (reverse saved-notes))
         (etaf-notify (plist-get n :title)
                      :id (plist-get n :id)
                      :app (plist-get n :app)
                      :detail (plist-get n :detail)
                      :variant (or (plist-get n :variant) 'info)
                      :ttl (or (plist-get n :ttl) 0.0)
                      :group (plist-get n :group)
                      :actions (plist-get n :actions))))))

(ert-deftest etaf-activity-publish-order-actions-and-reactive-ref ()
  (etaf-activity-test--clean
   (let* ((events nil)
          (toggled nil)
          (opened nil)
          (ref (etaf-activity-ref)))
     (add-hook 'etaf-activity-change-functions
               (lambda (ev id _entry) (push (cons ev id) events)))
     (add-hook 'etaf-activity-change-functions
               (lambda (&rest _) (error "isolated observer boom")))
     (should-error (etaf-activity-publish nil '(:title "Bad"))
                   :type 'etaf-runtime-error)
     (should-error (etaf-activity-publish 'bad-kind '(:kind bogus :title "Bad"))
                   :type 'etaf-runtime-error)
     (should-error (etaf-activity-publish 'no-title '(:kind media))
                   :type 'etaf-runtime-error)
     (etaf-activity-publish
      'test-paused
      (list :kind 'media :state 'paused :priority 90 :title "Paused Track"))
     (etaf-activity-publish
      'test-timer
      (list :kind 'timer :state 'active :priority 60 :title "Deep Focus"
            :compact "18:42"
            :open (lambda () (setq opened t))
            :actions (list (list :id 'toggle :label "Pause" :primary t
                                 :fn (lambda () (setq toggled t))))))
     (etaf-activity-publish
      'test-media
      (list :kind 'media :state 'active :priority 80 :title "Live Track"
            :compact "Live"))
     ;; Ordering: active high priority > active lower priority > paused
     (let ((ids (mapcar (lambda (a) (plist-get a :id)) (etaf-activity-list))))
       (should (equal ids '(test-media test-timer test-paused))))
     ;; Filtered query & detached copy
     (let* ((media-only (etaf-activity-list 'media))
            (snap (etaf-activity-get 'test-timer)))
       (should (= (length media-only) 2))
       (plist-put snap :title "Mutated")
       (should (equal (plist-get (etaf-activity-get 'test-timer) :title)
                      "Deep Focus")))
     ;; Reactive ref stays in sync
     (should (= (length (etaf-value ref)) 3))
     ;; Invoking declared actions and :open
     (etaf-activity-invoke 'test-timer 'toggle)
     (etaf-activity-invoke 'test-timer 'open)
     (should toggled)
     (should opened)
     (should-error (etaf-activity-invoke 'test-timer 'nonexistent)
                   :type 'etaf-runtime-error)
     ;; Removal updates ref and hook
     (should (etaf-activity-remove 'test-media))
     (should-not (etaf-activity-remove 'test-media))
     (should (= (length (etaf-value ref)) 2))
     (should (assq 'remove events)))))

(ert-deftest etaf-activity-auto-removes-when-owner-runtime-unmounts ()
  (etaf-activity-test--clean
   (let* ((buf (generate-new-buffer " *etaf-activity-owner*"))
          (rt nil))
     (unwind-protect
         (progn
           (etaf-mount
            buf
            (etaf-node 'text nil '("Owner view"))
            '(:viewport-width 320 :viewport-height 8))
           (setq rt (etaf-runtime-for-buffer buf))
           (etaf-activity-publish
            'owned-task
            (list :kind 'task :title "Background Task" :owner-runtime rt))
           (should (etaf-activity-get 'owned-task))
           (etaf-unmount rt)
           (setq rt nil)
           (should-not (etaf-activity-get 'owned-task)))
       (when (and rt (etaf-runtime-mounted-p rt))
         (etaf-unmount rt))
       (when (buffer-live-p buf)
         (kill-buffer buf))))))

(ert-deftest etaf-notify-grouping-dismissal-and-observer-isolation ()
  (etaf-activity-test--clean
   (let* ((seen nil)
          (ref (etaf-notify-ref)))
     (add-hook 'etaf-notify-functions
               (lambda (entry) (push (plist-get entry :title) seen)))
     (add-hook 'etaf-notify-functions
               (lambda (_) (error "observer error isolated")))
     (should-error (etaf-notify "" :variant 'info) :type 'etaf-runtime-error)
     (should-error (etaf-notify "Bad" :variant 'bogus) :type 'etaf-runtime-error)
     (let* ((n1 (etaf-notify "Build started" :app 'compile :group 'build))
            (n2 (etaf-notify "Build passed" :app 'compile :variant 'success
                             :detail "All checks ok" :group 'build))
            (n3 (etaf-notify "New DM" :app 'telega :variant 'warning)))
       ;; Grouping merges n1 -> n2 with count 2 and preserves id
       (should (equal (plist-get n1 :id) (plist-get n2 :id)))
       (should (= (plist-get n2 :count) 2))
       (should (= (length (etaf-notify-list)) 2))
       (should (= (length (etaf-value ref)) 2))
       (should (equal (plist-get (car (etaf-notify-list)) :title) "New DM"))
       ;; Dismiss specific id vs newest
       (etaf-notify-dismiss (plist-get n3 :id))
       (should (= (length (etaf-notify-list)) 1))
       (should (equal (plist-get (car (etaf-notify-list)) :title) "Build passed"))
       (etaf-notify-clear)
       (should (null (etaf-notify-list)))
       (should (null (etaf-value ref)))
       (should (= (length seen) 3))))))

(provide 'etaf-activity-tests)
;;; etaf-activity-tests.el ends here
