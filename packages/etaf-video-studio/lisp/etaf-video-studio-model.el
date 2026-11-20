;;; etaf-video-studio-model.el --- State of etaf-video-studio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns the application record, the reactive snapshot the views
;; read and the request/response bookkeeping around the CLI.  It never
;; touches the project store directly: every read and write is one
;; `video-project' invocation through `etaf-video-studio-backend-call'.  The
;; record's plain fields hold live values (selection, form drafts, stage);
;; the snapshot ref is republished only when something a view displays
;; changed, so a two-second status poll does not repaint the shell.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-video-studio-backend)
(require 'etaf-video-studio-theme)

(defconst etaf-video-studio--status-ref 'etaf-video-studio-status
  "Retained Host reference of the footer status text.")

(defconst etaf-video-studio--active-statuses
  '("queued" "running" "recording" "stopping" "sending")
  "Task statuses that still change without a new request.")

(defconst etaf-video-studio--panes
  '(projects clips preview properties captions record publish tasks)
  "Panes the application switches between, in tab order.")

(cl-defstruct (etaf-video-studio--app (:constructor etaf-video-studio--app--create))
  "Application state of one etaf-video-studio buffer.
PROJECT is the CLI's public project plist (id, title, revision, plan,
timeline, duration, tasks); PREVIEW is the latest completed preview render
for the current revision, when one exists.  STAGE describes what the native
`etaf-video' shows: `(:file :kind :base ?:aspect :key)'.  The *-REF fields
are the reactive cells the views bind."
  buffer root
  projects project pane pages
  clip-index caption-index task-index
  record-targets record-target-index
  publish-preview stage preview
  caption-edit-id
  pending message
  theme-ref data-ref
  trim-in-ref trim-out-ref split-ref
  caption-start-ref caption-end-ref caption-text-ref
  new-title-ref record-duration-ref
  caption-id-ref
  record-audio-ref publish-target-ref publish-chat-ref publish-text-ref
  publish-topic-ref speed-ref gain-ref stage-audio-ref stage-time-ref
  poll-timer stage-timer poll-tick poll-signature
  stage-handle stage-generation stage-playing stage-position)

(defun etaf-video-studio--make-app (&optional root)
  "Create an application record rooted at ROOT.
ROOT nil leaves the project root to the CLI default.  The buffer is set
once the application has opened."
  (etaf-video-studio--app--create
   :root root
   :pane 'projects
   :pages nil
   :pending 0
   :clip-index nil :caption-index nil :task-index nil
   :record-target-index nil
   :record-audio-ref (etaf-ref "none" :name 'video-studio-record-audio)
   :record-duration-ref (etaf-ref "300" :name 'video-studio-record-duration)
   :publish-target-ref (etaf-ref "telegram" :name 'video-studio-publish-target)
   :publish-chat-ref (etaf-ref "" :name 'video-studio-publish-chat)
   :publish-text-ref (etaf-ref "" :name 'video-studio-publish-text)
   :publish-topic-ref (etaf-ref "" :name 'video-studio-publish-topic)
   :trim-in-ref (etaf-ref "" :name 'video-studio-trim-in)
   :trim-out-ref (etaf-ref "" :name 'video-studio-trim-out)
   :split-ref (etaf-ref "" :name 'video-studio-split)
   :caption-start-ref (etaf-ref "" :name 'video-studio-caption-start)
   :caption-end-ref (etaf-ref "" :name 'video-studio-caption-end)
   :caption-text-ref (etaf-ref "" :name 'video-studio-caption-text)
   :caption-id-ref (etaf-ref "" :name 'video-studio-caption-id)
   :new-title-ref (etaf-ref "" :name 'video-studio-new-title)
   :speed-ref (etaf-ref 1 :name 'video-studio-speed)
   :gain-ref (etaf-ref 1 :name 'video-studio-gain)
   :stage-time-ref (etaf-ref 0 :name 'video-studio-stage-time)
   :stage-audio-ref (etaf-ref nil :name 'video-studio-stage-audio)
   :theme-ref (etaf-ref (etaf-video-studio-theme-defaults)
                        :name 'video-studio-theme)
   :data-ref (etaf-ref nil :name 'video-studio-data)))

(defconst etaf-video-studio--page-size 5
  "Rows per list page, keeping forms reachable in a short window.")

(defun etaf-video-studio--list-items (app kind)
  "Return APP's public list identified by KIND."
  (pcase kind
    ('projects (etaf-video-studio--app-projects app))
    ('clips (etaf-video-studio--app-clips app))
    ('captions (etaf-video-studio--app-captions app))
    ('record (etaf-video-studio--app-record-targets app))
    ('tasks (reverse (etaf-video-studio--app-tasks app)))))

(defun etaf-video-studio--page (app kind)
  "Return the clamped zero-based page of APP's KIND list."
  (min (or (alist-get kind (etaf-video-studio--app-pages app)) 0)
       (/ (max 0 (1- (length (etaf-video-studio--list-items app kind))))
          etaf-video-studio--page-size)))

(defun etaf-video-studio--page-items (app kind)
  "Return the visible page of APP's KIND list."
  (seq-take (nthcdr (* (etaf-video-studio--page app kind)
                       etaf-video-studio--page-size)
                    (etaf-video-studio--list-items app kind))
            etaf-video-studio--page-size))

(defun etaf-video-studio--app-clips (app)
  "Return the current project's clips as a list."
  (let ((plan (plist-get (etaf-video-studio--app-project app) :plan)))
    (append (plist-get plan :clips) nil)))

(defun etaf-video-studio--app-captions (app)
  "Return the current project's captions as a list."
  (let ((plan (plist-get (etaf-video-studio--app-project app) :plan)))
    (append (plist-get plan :captions) nil)))

(defun etaf-video-studio--app-tasks (app)
  "Return the current project's tasks as a list."
  (append (plist-get (etaf-video-studio--app-project app) :tasks) nil))

(defun etaf-video-studio--app-selected-clip (app)
  "Return the selected clip of APP, or nil."
  (let ((index (etaf-video-studio--app-clip-index app))
        (clips (etaf-video-studio--app-clips app)))
    (and (integerp index) (nth index clips))))

(defun etaf-video-studio--app-selected-caption (app)
  "Return the selected caption of APP, or nil."
  (let ((index (etaf-video-studio--app-caption-index app))
        (captions (etaf-video-studio--app-captions app)))
    (and (integerp index) (nth index captions))))

(defun etaf-video-studio--app-selected-target (app)
  "Return the selected recording target of APP, or nil."
  (let ((index (etaf-video-studio--app-record-target-index app))
        (targets (etaf-video-studio--app-record-targets app)))
    (and (integerp index) (nth index targets))))

(defun etaf-video-studio--app-active-tasks (app)
  "Return the tasks of APP whose status still changes."
  (cl-remove-if-not (lambda (task)
                      (member (plist-get task :status)
                              etaf-video-studio--active-statuses))
                    (etaf-video-studio--app-tasks app)))

(defun etaf-video-studio--app-record-task (app)
  "Return the active recording task of APP, or nil."
  (cl-find-if (lambda (task)
                (and (equal (plist-get task :kind) "record")
                     (member (plist-get task :status)
                             etaf-video-studio--active-statuses)))
              (etaf-video-studio--app-tasks app)))

(defun etaf-video-studio--app-render-task (app &optional profile revision)
  "Return the last render task of APP matching PROFILE and REVISION."
  (let (found)
    (dolist (task (etaf-video-studio--app-tasks app) found)
      (when (and (equal (plist-get task :kind) "render")
                 (or (null profile) (equal (plist-get task :profile) profile))
                 (or (null revision) (equal (plist-get task :revision) revision)))
        (setq found task)))))

(defun etaf-video-studio--app-preview-for-revision (app)
  "Return APP's completed preview render for its current revision, or nil."
  (let ((revision (plist-get (etaf-video-studio--app-project app) :revision)))
    (let (found)
      (dolist (task (etaf-video-studio--app-tasks app) found)
        (when (and (equal (plist-get task :kind) "render")
                   (equal (plist-get task :profile) "preview")
                   (equal (plist-get task :revision) revision)
                   (equal (plist-get task :status) "completed")
                   (plist-get task :output))
          (setq found task))))))

(defun etaf-video-studio--app-screen-export (app)
  "Return APP's completed screen export for its current revision, or nil."
  (let ((revision (plist-get (etaf-video-studio--app-project app) :revision)))
    (let (found)
      (dolist (task (etaf-video-studio--app-tasks app) found)
        (when (and (equal (plist-get task :kind) "render")
                   (equal (plist-get task :profile) "screen")
                   (equal (plist-get task :revision) revision)
                   (equal (plist-get task :status) "completed")
                   (plist-get task :output))
          (setq found task))))))

(defun etaf-video-studio--app-clamp-selection (app)
  "Keep APP's list selections inside their refreshed lists."
  (let ((clips (etaf-video-studio--app-clips app))
        (captions (etaf-video-studio--app-captions app))
        (tasks (etaf-video-studio--app-tasks app))
        (targets (etaf-video-studio--app-record-targets app)))
    (setf (etaf-video-studio--app-clip-index app)
          (if (null clips)
              nil
            (min (max 0 (or (etaf-video-studio--app-clip-index app) 0))
                 (1- (length clips)))))
    (setf (etaf-video-studio--app-caption-index app)
          (if (null captions)
              nil
            (min (max 0 (or (etaf-video-studio--app-caption-index app) 0))
                 (1- (length captions)))))
    (setf (etaf-video-studio--app-task-index app)
          (if (null tasks)
              nil
            (min (max 0 (or (etaf-video-studio--app-task-index app) 0))
                 (1- (length tasks)))))
    (setf (etaf-video-studio--app-record-target-index app)
          (if (null targets)
              nil
            (min (max 0 (or (etaf-video-studio--app-record-target-index app) 0))
                 (1- (length targets)))))))

(defun etaf-video-studio--app-adopt-project (app project)
  "Adopt the refreshed public PROJECT into APP and reconcile the stage.
The stage follows the current revision's completed preview when the user is
not watching a clip, so an edit marks the old preview stale instead of
pretending it is the new cut."
  (setf (etaf-video-studio--app-project app) project)
  (etaf-video-studio--app-clamp-selection app)
  (let* ((revision (plist-get project :revision))
         (preview (etaf-video-studio--app-preview-for-revision app)))
    (setf (etaf-video-studio--app-preview app) preview)
    (when (and (plist-get (etaf-video-studio--app-publish-preview app) :revision)
               (not (equal (plist-get (etaf-video-studio--app-publish-preview app) :revision)
                           revision)))
      ;; A confirmation for an older revision must never be reused.
      (setf (etaf-video-studio--app-publish-preview app) nil))
    (let ((stage (etaf-video-studio--app-stage app)))
      (cond
       ((null stage)
        (when preview
          (etaf-video-studio--app-set-stage app (plist-get preview :output) 'preview 0
                                            (plist-get preview :revision))))
       ((eq (plist-get stage :kind) 'preview)
        ;; A newer completed preview takes over; an older one stays on the
        ;; stage with a visible stale label instead of disappearing while a
        ;; status snapshot is in flight.
        (when (and preview
                   (not (equal (plist-get stage :file) (plist-get preview :output))))
          (etaf-video-studio--app-set-stage app (plist-get preview :output) 'preview 0
                                            (plist-get preview :revision))))))
    project))

(defun etaf-video-studio--app-set-stage (app file kind base &optional revision)
  "Show FILE in APP's video stage as KIND (a symbol) starting at BASE seconds.
REVISION records the project revision a rendered preview belongs to, so a
status poll can tell a stale preview from a current one without depending on
the task list.  A file that does not exist is not mounted; the caller reports
that instead of asking the native video Component to decode a missing path.
Every stage gets a fresh handle, so replacing a playing source can never
collide with the session that is still being torn down."
  (when (and (stringp file) (not (string-empty-p file)) (file-exists-p file))
    (let ((generation (1+ (or (etaf-video-studio--app-stage-generation app) 0)))
          (key (float-time)))
      (setf (etaf-video-studio--app-stage-generation app) generation
            (etaf-video-studio--app-stage-handle app)
            (intern (format "etaf-video-studio-stage-%d" generation))
            (etaf-video-studio--app-stage app)
            (list :file file :kind kind :base (or base 0) :aspect nil
                  :revision revision :key key :positioned nil
                  :handle (etaf-video-studio--app-stage-handle app)))
      (etaf-set-value (etaf-video-studio--app-stage-time-ref app) 0)
      (etaf-video-studio--app-probe-stage app)
      t)))

(defun etaf-video-studio--app-clear-stage (app)
  "Remove the video stage of APP."
  (setf (etaf-video-studio--app-stage app) nil
        (etaf-video-studio--app-stage-playing app) nil
        (etaf-video-studio--app-stage-position app) nil)
  (etaf-set-value (etaf-video-studio--app-stage-time-ref app) 0))

(defun etaf-video-studio--app-probe-stage (app)
  "Probe the stage file of APP for duration and pixel size.
The probe is one quick CLI call on the metadata path; its result only
updates the aspect used to size the canvas."
  (let ((stage (etaf-video-studio--app-stage app)))
    (when stage
      (etaf-video-studio--app-request
       app (list "video-edit" "probe" (plist-get stage :file))
       (lambda (result)
         (when (plist-get result :ok)
           (let ((data (plist-get result :data))
                 (current (etaf-video-studio--app-stage app)))
             (when (and current
                        (equal (plist-get current :file) (plist-get stage :file)))
               (setf (etaf-video-studio--app-stage app)
                     (plist-put (plist-put current :aspect
                                           (cons (or (plist-get data :width) 16)
                                                 (or (plist-get data :height) 9)))
                                :duration (plist-get data :duration)))))))))))

(defun etaf-video-studio--app-snapshot (app)
  "Return a plain snapshot plist of everything the views display."
  (list :projects (etaf-video-studio--app-projects app)
        :project (etaf-video-studio--app-project app)
        :pages (copy-tree (etaf-video-studio--app-pages app))
        :pane (etaf-video-studio--app-pane app)
        :clip-index (etaf-video-studio--app-clip-index app)
        :caption-index (etaf-video-studio--app-caption-index app)
        :task-index (etaf-video-studio--app-task-index app)
        :clip (etaf-video-studio--app-selected-clip app)
        :caption (etaf-video-studio--app-selected-caption app)
        :caption-edit-id (etaf-video-studio--app-caption-edit-id app)
        :record-targets (etaf-video-studio--app-record-targets app)
        :record-target-index (etaf-video-studio--app-record-target-index app)
        :record-target (etaf-video-studio--app-selected-target app)
        :record-task (etaf-video-studio--app-record-task app)
        :publish-preview (etaf-video-studio--app-publish-preview app)
        :preview (etaf-video-studio--app-preview app)
        :stage (etaf-video-studio--app-stage app)
        :stage-playing (etaf-video-studio--app-stage-playing app)
        :stage-position (etaf-video-studio--app-stage-position app)
        :pending (etaf-video-studio--app-pending app)
        :message (etaf-video-studio--app-message app)))

(defun etaf-video-studio--app-publish (app)
  "Republish APP's snapshot and settle the mounted Runtime."
  (etaf-set-value (etaf-video-studio--app-data-ref app)
                  (etaf-video-studio--app-snapshot app))
  (etaf-video-studio--app-flush app))

(defun etaf-video-studio--app-flush (app)
  "Flush pending reactive work of APP's runtime when it is mounted."
  (let ((buffer (etaf-video-studio--app-buffer app)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((runtime (ignore-errors (etaf-runtime-for-buffer buffer))))
          (when (and runtime (etaf-runtime-mounted-p runtime))
            (ignore-errors (etaf-runtime-flush runtime))))))))

(defun etaf-video-studio--app-set-message (app format-string &rest arguments)
  "Set APP's status message from FORMAT-STRING and ARGUMENTS.
The text reaches the footer through the retained Host boundary without a
View republication; a later ordinary publication renders the same value."
  (let ((text (apply #'format format-string arguments)))
    (setf (etaf-video-studio--app-message app) text)
    (when-let* ((buffer (etaf-video-studio--app-buffer app))
                ((buffer-live-p buffer))
                (runtime (with-current-buffer buffer
                           (ignore-errors (etaf-runtime-for-buffer buffer))))
                ((etaf-runtime-mounted-p runtime)))
      (ignore-errors
        (etaf-runtime-update-host-content runtime etaf-video-studio--status-ref text)))
    text))

(defun etaf-video-studio--app-request (app args callback)
  "Send CLI ARGS for APP and run CALLBACK with the result.
Pending requests are counted in the snapshot so the status line and the
busy state can see them; CALLBACK runs before the final republication."
  (setf (etaf-video-studio--app-pending app)
        (1+ (etaf-video-studio--app-pending app)))
  (etaf-video-studio--app-publish app)
  (etaf-video-studio-backend-call
   (etaf-video-studio--app-buffer app) args
   (lambda (result)
     (setf (etaf-video-studio--app-pending app)
           (max 0 (1- (etaf-video-studio--app-pending app))))
     (condition-case problem
         (funcall callback result)
       (error
        (etaf-video-studio--app-set-message
         app "处理结果失败：%s" (error-message-string problem))))
     (etaf-video-studio--app-publish app))))

(defun etaf-video-studio--app-request-quiet (app args callback)
  "Send CLI ARGS for APP like `etaf-video-studio--app-request' but quietly.
Background polls use this so a request that changes nothing does not cause
an extra shell publication at its start."
  (setf (etaf-video-studio--app-pending app)
        (1+ (etaf-video-studio--app-pending app)))
  (etaf-video-studio-backend-call
   (etaf-video-studio--app-buffer app) args
   (lambda (result)
     (setf (etaf-video-studio--app-pending app)
           (max 0 (1- (etaf-video-studio--app-pending app))))
     (condition-case problem
         (funcall callback result)
       (error
        (etaf-video-studio--app-set-message
         app "后台请求失败：%s" (error-message-string problem)))))))

(defun etaf-video-studio--app-report-error (app result)
  "Show RESULT's error in APP and return nil."
  (etaf-video-studio--app-set-message
   app "失败 [%s] %s%s"
   (or (plist-get result :code) "internal")
   (or (plist-get result :message) "未知错误")
   (let ((hint (plist-get result :hint)))
     (if (and (stringp hint) (not (string-empty-p hint)))
         (format " · %s" hint)
       "")))
  nil)

(defun etaf-video-studio--app-project-args (app)
  "Return the CLI arguments selecting APP's current project."
  (let ((directory (plist-get (etaf-video-studio--app-project app) :directory)))
    (unless directory
      (user-error "请先打开一个项目"))
    (list directory)))

(defun etaf-video-studio--app-root-args (app)
  "Return `--root' arguments for APP when it pins a project root."
  (let ((root (etaf-video-studio--app-root app)))
    (if (and (stringp root) (not (string-empty-p root)))
        (list "--root" root)
      nil)))

(provide 'etaf-video-studio-model)
;;; etaf-video-studio-model.el ends here
