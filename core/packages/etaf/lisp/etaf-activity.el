;;; etaf-activity.el --- Cross-application live activities and notifications -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Cross-application live activities and event notifications for ETAF shells.
;; Applications publish structured status snapshots and actions without knowing
;; about any consumer shell; shells subscribe reactively with zero polling.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-reactive)
(require 'etaf-runtime)

(defconst etaf-activity--valid-kinds
  '(media timer task inbox schedule status)
  "Supported semantic kinds for live ETAF activities.")

(defconst etaf-activity--valid-states
  '(active paused idle)
  "Supported lifecycle states for live ETAF activities.")

(defconst etaf-activity--valid-variants
  '(info success warning danger)
  "Supported semantic variants for ETAF notifications.")

(defconst etaf-activity--max-notifications 30
  "Maximum number of notifications retained in `etaf-notify-list'.")

(defvar etaf-activity-change-functions nil
  "Abnormal hook run when live activities change.
Each function is called with `(EVENT ID ENTRY)' where EVENT is `publish' or
`remove', ID is the activity key and ENTRY is a detached activity plist (or
nil on removal).  Individual observer errors are isolated.")

(defvar etaf-notify-functions nil
  "Abnormal hook run when `etaf-notify' publishes a notification.
Each function is called with `(ENTRY)', a detached notification plist.
Individual observer errors are isolated.  When at least one observer is
installed, `etaf-notify' does not echo a fallback message.")

(defvar etaf-activity--table (make-hash-table :test #'equal)
  "Internal map from activity ID to normalized activity plist.")

(defvar etaf-activity--ref (etaf-ref nil :name 'etaf-activities)
  "Shared reactive ref holding ordered detached activity snapshots.")

(defvar etaf-activity--notifications nil
  "Internal list of stored notification plists, newest first.")

(defvar etaf-activity--notify-seq 0
  "Monotonic sequence counter for generated notification IDs.")

(defvar etaf-activity--notify-ref (etaf-ref nil :name 'etaf-notifications)
  "Shared reactive ref holding detached notification plists, newest first.")

(defun etaf-activity--run-hook (hook &rest args)
  "Run abnormal HOOK with ARGS while isolating individual observer errors."
  (dolist (fn (copy-sequence (symbol-value hook)))
    (when (functionp fn)
      (condition-case nil
          (apply fn args)
        (error nil)))))

(defun etaf-activity--state-rank (state)
  "Return sort rank for activity STATE (smaller ranks earlier)."
  (pcase state
    ('active 0)
    ('paused 1)
    (_ 2)))

(defun etaf-activity--copy-plist (plist)
  "Return a shallowly detached copy of PLIST with nested lists copied."
  (when plist
    (let ((copy (copy-sequence plist)))
      (when-let* ((prog (plist-get copy :progress)))
        (when (listp prog)
          (setq copy (plist-put copy :progress (copy-sequence prog)))))
      (when-let* ((acts (plist-get copy :actions)))
        (when (listp acts)
          (setq copy (plist-put copy :actions
                                (mapcar (lambda (a)
                                          (if (listp a) (copy-sequence a) a))
                                        acts)))))
      copy)))

(defun etaf-activity--ordered-snapshot (&optional kind)
  "Return ordered list of detached activity plists, optionally for KIND."
  (let (items)
    (maphash
     (lambda (_id entry)
       (when (or (null kind) (eq (plist-get entry :kind) kind))
         (push (etaf-activity--copy-plist entry) items)))
     etaf-activity--table)
    (sort items
          (lambda (a b)
            (let ((ra (etaf-activity--state-rank (plist-get a :state)))
                  (rb (etaf-activity--state-rank (plist-get b :state))))
              (if (/= ra rb)
                  (< ra rb)
                (let ((pa (or (plist-get a :priority) 50))
                      (pb (or (plist-get b :priority) 50)))
                  (if (/= pa pb)
                      (> pa pb)
                    (> (or (plist-get a :updated-at) 0.0)
                       (or (plist-get b :updated-at) 0.0))))))))))

(defun etaf-activity--sync-ref ()
  "Publish the current ordered activity snapshot into `etaf-activity--ref'."
  (setf (etaf-value etaf-activity--ref) (etaf-activity--ordered-snapshot)))

(defun etaf-activity--sync-notify-ref ()
  "Publish detached notification snapshots into `etaf-activity--notify-ref'."
  (setf (etaf-value etaf-activity--notify-ref)
        (mapcar #'etaf-activity--copy-plist etaf-activity--notifications)))

(defun etaf-activity--validate-actions (actions)
  "Validate ACTIONS list of plists, returning normalized copy."
  (unless (listp actions)
    (signal 'etaf-runtime-error (list "Activity actions must be a list" actions)))
  (mapcar
   (lambda (act)
     (unless (and (listp act) (proper-list-p act)
                  (symbolp (plist-get act :id))
                  (plist-get act :id)
                  (stringp (plist-get act :label))
                  (functionp (plist-get act :fn)))
       (signal 'etaf-runtime-error
               (list "Each action needs :id symbol, :label string and :fn function" act)))
     (copy-sequence act))
   actions))

(defun etaf-activity--same-payload-p (old new)
  "Return non-nil when activity plists OLD and NEW match ignoring timestamps."
  (and old
       (equal (plist-get old :app) (plist-get new :app))
       (eq (plist-get old :kind) (plist-get new :kind))
       (eq (plist-get old :state) (plist-get new :state))
       (equal (plist-get old :priority) (plist-get new :priority))
       (equal (plist-get old :title) (plist-get new :title))
       (equal (plist-get old :subtitle) (plist-get new :subtitle))
       (equal (plist-get old :compact) (plist-get new :compact))
       (equal (plist-get old :icon) (plist-get new :icon))
       (eq (plist-get old :tone) (plist-get new :tone))
       (equal (plist-get old :progress) (plist-get new :progress))
       (eq (plist-get old :meter) (plist-get new :meter))
       (eq (plist-get old :open) (plist-get new :open))
       (eq (plist-get old :owner-runtime) (plist-get new :owner-runtime))
       (equal (plist-get old :actions) (plist-get new :actions))))

;;;###autoload
(defun etaf-activity-publish (id plist)
  "Publish or update live activity ID with normalized fields from PLIST.
Returns a detached copy of the published activity plist."
  (unless (or (and (symbolp id) (not (null id)))
              (and (stringp id) (not (string-empty-p id)))
              (consp id))
    (signal 'etaf-runtime-error (list "Invalid activity ID" id)))
  (unless (and (listp plist) (proper-list-p plist) (zerop (% (length plist) 2)))
    (signal 'etaf-runtime-error (list "Activity specification must be a plist" plist)))
  (let* ((kind (or (plist-get plist :kind) 'status))
         (state (or (plist-get plist :state) 'active))
         (priority (or (plist-get plist :priority) 50))
         (title (plist-get plist :title))
         (subtitle (plist-get plist :subtitle))
         (compact (plist-get plist :compact))
         (icon (plist-get plist :icon))
         (tone (plist-get plist :tone))
         (progress (plist-get plist :progress))
         (meter (plist-get plist :meter))
         (open-fn (plist-get plist :open))
         (owner-rt (plist-get plist :owner-runtime))
         (actions (when-let* ((raw (plist-get plist :actions)))
                    (etaf-activity--validate-actions raw)))
         (app (or (plist-get plist :app) (and (symbolp id) id))))
    (unless (memq kind etaf-activity--valid-kinds)
      (signal 'etaf-runtime-error (list "Invalid activity :kind" kind)))
    (unless (memq state etaf-activity--valid-states)
      (signal 'etaf-runtime-error (list "Invalid activity :state" state)))
    (unless (numberp priority)
      (signal 'etaf-runtime-error (list "Activity :priority must be a number" priority)))
    (unless (and (stringp title) (not (string-empty-p title)))
      (signal 'etaf-runtime-error (list "Activity :title must be a nonempty string" title)))
    (when (and progress (not (and (listp progress) (proper-list-p progress))))
      (signal 'etaf-runtime-error (list "Activity :progress must be a plist" progress)))
    (when (and meter (not (functionp meter)))
      (signal 'etaf-runtime-error (list "Activity :meter must be a function" meter)))
    (when (and open-fn (not (functionp open-fn)))
      (signal 'etaf-runtime-error (list "Activity :open must be a function" open-fn)))
    (when (and tone (not (memq tone '(info success warning danger neutral))))
      (signal 'etaf-runtime-error (list "Invalid activity :tone" tone)))
    (let* ((existing (gethash id etaf-activity--table))
           (entry (list :id id
                        :app app
                        :kind kind
                        :state state
                        :priority priority
                        :title title
                        :subtitle subtitle
                        :compact compact
                        :icon icon
                        :tone tone
                        :progress (and progress (copy-sequence progress))
                        :meter meter
                        :actions actions
                        :open open-fn
                        :owner-runtime owner-rt
                        :updated-at (or (plist-get plist :updated-at) (float-time)))))
      (unless (etaf-activity--same-payload-p existing entry)
        (puthash id entry etaf-activity--table)
        (etaf-activity--sync-ref)
        (etaf-activity--run-hook 'etaf-activity-change-functions
                                 'publish id (etaf-activity--copy-plist entry)))
      (etaf-activity--copy-plist (gethash id etaf-activity--table)))))

;;;###autoload
(defun etaf-activity-remove (id)
  "Remove live activity ID when present and return non-nil if it existed."
  (when (gethash id etaf-activity--table)
    (remhash id etaf-activity--table)
    (etaf-activity--sync-ref)
    (etaf-activity--run-hook 'etaf-activity-change-functions 'remove id nil)
    t))

;;;###autoload
(defun etaf-activity-get (id)
  "Return a detached copy of live activity ID, or nil."
  (etaf-activity--copy-plist (gethash id etaf-activity--table)))

;;;###autoload
(defun etaf-activity-list (&optional kind)
  "Return ordered detached snapshots of live activities, optionally for KIND."
  (when (and kind (not (memq kind etaf-activity--valid-kinds)))
    (signal 'etaf-runtime-error (list "Invalid activity kind filter" kind)))
  (etaf-activity--ordered-snapshot kind))

;;;###autoload
(defun etaf-activity-ref ()
  "Return the shared reactive ref holding ordered live activity snapshots."
  etaf-activity--ref)

;;;###autoload
(defun etaf-activity-invoke (id action-id)
  "Invoke ACTION-ID (or `open') declared on live activity ID."
  (let ((entry (gethash id etaf-activity--table)))
    (unless entry
      (signal 'etaf-runtime-error (list "Unknown live activity" id)))
    (if (eq action-id 'open)
        (let ((fn (or (plist-get entry :open)
                      (plist-get (cl-find 'open (plist-get entry :actions)
                                          :key (lambda (a) (plist-get a :id)))
                                 :fn))))
          (unless (functionp fn)
            (signal 'etaf-runtime-error (list "Activity has no open action" id)))
          (funcall fn))
      (let* ((act (cl-find action-id (plist-get entry :actions)
                           :key (lambda (a) (plist-get a :id))))
             (fn (and act (plist-get act :fn))))
        (unless (functionp fn)
          (signal 'etaf-runtime-error (list "Unknown activity action" id action-id)))
        (funcall fn)))))

(defun etaf-activity--on-runtime-unmount (runtime)
  "Remove any live activities owned by unmounting RUNTIME."
  (let (doomed)
    (maphash
     (lambda (id entry)
       (when (eq (plist-get entry :owner-runtime) runtime)
         (push id doomed)))
     etaf-activity--table)
    (dolist (id doomed)
      (etaf-activity-remove id))))

(add-hook 'etaf-runtime-unmount-functions #'etaf-activity--on-runtime-unmount)

;;;###autoload
(cl-defun etaf-notify (title &key id app detail (variant 'info) (ttl 5.0)
                             group actions)
  "Publish notification TITLE to ETAF consumers and return a detached entry.
When GROUP matches an existing notification, replaces it in place with an
incremented `:count'.  Falls back to `message' when no observer is installed
on `etaf-notify-functions'."
  (unless (and (stringp title) (not (string-empty-p title)))
    (signal 'etaf-runtime-error (list "Notification title must be a nonempty string" title)))
  (unless (memq variant etaf-activity--valid-variants)
    (signal 'etaf-runtime-error (list "Invalid notification variant" variant)))
  (unless (and (numberp ttl) (>= ttl 0))
    (signal 'etaf-runtime-error (list "Invalid notification ttl" ttl)))
  (let* ((norm-actions (when actions (etaf-activity--validate-actions actions)))
         (existing (when group
                     (cl-find group etaf-activity--notifications
                              :key (lambda (n) (plist-get n :group))
                              :test #'equal)))
         (count (if existing (1+ (or (plist-get existing :count) 1)) 1))
         (nid (or id
                  (and existing (plist-get existing :id))
                  (cl-incf etaf-activity--notify-seq)))
         (entry (list :id nid
                      :app app
                      :title title
                      :detail (or detail "")
                      :variant variant
                      :ttl (float ttl)
                      :group group
                      :count count
                      :actions norm-actions
                      :time (format-time-string "%H:%M")
                      :created-at (float-time)))
         (filtered (if existing
                       (cl-remove (plist-get existing :id)
                                  etaf-activity--notifications
                                  :key (lambda (n) (plist-get n :id))
                                  :test #'equal)
                     etaf-activity--notifications))
         (next (cons entry (cl-subseq filtered 0
                                      (min (1- etaf-activity--max-notifications)
                                           (length filtered))))))
    (setq etaf-activity--notifications next)
    (etaf-activity--sync-notify-ref)
    (if etaf-notify-functions
        (etaf-activity--run-hook 'etaf-notify-functions
                                 (etaf-activity--copy-plist entry))
      (unless noninteractive
        (message "[%s] %s%s"
                 (or app 'etaf)
                 title
                 (if (and (stringp detail) (not (string-empty-p detail)))
                     (concat " — " detail)
                   ""))))
    (etaf-activity--copy-plist entry)))

;;;###autoload
(defun etaf-notify-dismiss (&optional id)
  "Dismiss notification ID (or the newest notification when ID is nil).
Returns the remaining detached notification list."
  (let ((target (or id (plist-get (car etaf-activity--notifications) :id))))
    (when target
      (setq etaf-activity--notifications
            (cl-remove target etaf-activity--notifications
                       :key (lambda (n) (plist-get n :id))
                       :test #'equal))
      (etaf-activity--sync-notify-ref)))
  (etaf-notify-list))

;;;###autoload
(defun etaf-notify-clear ()
  "Clear all stored ETAF notifications and return nil."
  (setq etaf-activity--notifications nil)
  (etaf-activity--sync-notify-ref)
  nil)

;;;###autoload
(defun etaf-notify-list ()
  "Return detached list of stored ETAF notifications, newest first."
  (mapcar #'etaf-activity--copy-plist etaf-activity--notifications))

;;;###autoload
(defun etaf-notify-ref ()
  "Return the shared reactive ref holding stored ETAF notifications."
  etaf-activity--notify-ref)

(provide 'etaf-activity)
;;; etaf-activity.el ends here
