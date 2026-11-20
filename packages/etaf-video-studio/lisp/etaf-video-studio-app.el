;;; etaf-video-studio-app.el --- Buffers, keys and commands of etaf-video-studio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application face of the video studio: the mountable View, its root
;; keys, the lifecycle and the public commands listed in the root entry.
;; Every command is one `video-project' invocation; long operations return a
;; task immediately and the background job belongs to `job-run', so closing
;; this application neither waits for nor stops an export, a recording or a
;; publish.  Only short CLI queries are cancelled on close.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-video-studio-theme)
(require 'etaf-video-studio-model)
(require 'etaf-video-studio-views)

(defconst etaf-video-studio--buffer-name "*Video Studio*"
  "Name of the single application buffer.")

(defvar etaf-video-studio-root nil
  "Project root the application pins for every CLI call.
Nil uses the CLI default (`~/Movies/Video Projects' or
`PI_SKILL_VIDEO_PROJECT_DIRECTORY'); set it to keep an application session
inside a different library, for example a test checkout.")

(defcustom etaf-video-studio-poll-seconds 2
  "Seconds between status polls while a project is displayed."
  :type 'number
  :group 'etaf-video-studio)

(defcustom etaf-video-studio-idle-poll-ticks 6
  "Poll runs between idle status checks.
Each run is `etaf-video-studio-poll-seconds' long, so the default checks a
displayed project with no running task about every twelve seconds."
  :type 'integer
  :group 'etaf-video-studio)

;; The keys are the shell's root `:keys': help lists them with these labels,
;; a focused control keeps its own RET, and the renderer keeps `n' and `?'.
(defconst etaf-video-studio--bindings
  '(("SPC" etaf-video-studio-toggle-playback "播放／暂停")
    ("f" etaf-video-studio-seek-forward "快进 5 秒")
    ("b" etaf-video-studio-seek-backward "后退 5 秒")
    ("m" etaf-video-studio-toggle-stage-audio "开启／关闭预览声音")
    ("N" etaf-video-studio-create-project "新建项目")
    ("a" etaf-video-studio-import-files "导入素材")
    ("g" etaf-video-studio-refresh "刷新项目")
    ("u" etaf-video-studio-undo "撤销修改")
    ("U" etaf-video-studio-redo "重做修改")
    ("s" etaf-video-studio-split-at-stage "当前位置分割")
    ("x" etaf-video-studio-remove-selected-clip "删除片段")
    ("i" etaf-video-studio-mark-in "设为入点")
    ("o" etaf-video-studio-mark-out "设为出点")
    ("," etaf-video-studio-move-clip-up "片段上移")
    ("." etaf-video-studio-move-clip-down "片段下移")
    ("v" etaf-video-studio-render-preview "生成成片预览")
    ("e" etaf-video-studio-render-screen "导出视频")
    ("C" etaf-video-studio-cancel-render "取消导出")
    ("c" etaf-video-studio-show-captions "字幕")
    ("r" etaf-video-studio-show-record "录屏")
    ("R" etaf-video-studio-toggle-record "开始或停止录制")
    ("p" etaf-video-studio-show-publish "导出与发布")
    ("t" etaf-video-studio-show-tasks "后台任务")
    ("T" etaf-video-studio-toggle-theme "切换主题")
    ("q" etaf-video-studio-close "关闭工作台"))
  "Root keys of the studio, as (KEY COMMAND LABEL).")

;;; Lifecycle

(defun etaf-video-studio--current ()
  "Return the current buffer's application, or signal `user-error'."
  (let ((app (etaf-app-state)))
    (if (etaf-video-studio--app-p app)
        app
      (user-error "Not an etaf-video-studio buffer"))))

(defun etaf-video-studio--view (app)
  "Return the mountable View for APP."
  (etaf-view (etaf-video-studio--shell :app app :keys etaf-video-studio--bindings)))

(defun etaf-video-studio--cancel-timers (app)
  "Cancel APP's timers."
  (when-let* ((timer (etaf-video-studio--app-poll-timer app)))
    (cancel-timer timer)
    (setf (etaf-video-studio--app-poll-timer app) nil))
  (when-let* ((timer (etaf-video-studio--app-stage-timer app)))
    (cancel-timer timer)
    (setf (etaf-video-studio--app-stage-timer app) nil)))

(defun etaf-video-studio--release (app)
  "Stop APP's timers and in-flight CLI queries; background jobs keep running."
  (etaf-video-studio--cancel-timers app)
  (etaf-video-studio-backend-cancel (etaf-video-studio--app-buffer app)))

(defun etaf-video-studio-close ()
  "Close the video studio in the current buffer."
  (interactive)
  (etaf-video-studio--current)
  (etaf-app-close))

(defun etaf-video-studio--start-timers (app)
  "Start APP's status poll and stage clock timers."
  (setf (etaf-video-studio--app-stage-timer app)
        (run-at-time 0 0.5 #'etaf-video-studio--stage-tick app)
        (etaf-video-studio--app-poll-timer app)
        (run-at-time etaf-video-studio-poll-seconds etaf-video-studio-poll-seconds
                     #'etaf-video-studio--poll app)))

;;;###autoload
(defun etaf-video-studio-open (&optional project root)
  "Open the video studio and return its buffer.
PROJECT optionally opens one project (an id or directory).  ROOT pins the
project library for this session; nil uses `etaf-video-studio-root' and
then the CLI default.  An already open studio is closed first."
  (interactive)
  (let* ((app (etaf-video-studio--make-app (or root etaf-video-studio-root)))
         (theme (etaf-video-studio--app-theme-ref app))
         ;; The View follows its window: the runtime refits after each
         ;; settled resize, so the studio keeps no size hook of its own.
         (buffer (etaf-app-open
                  etaf-video-studio--buffer-name (etaf-video-studio--view app)
                  :state app
                  ;; Cells beyond the shell continue the page surface.
                  :background (lambda () (plist-get (etaf-value theme) :ui-bg))
                  :cursor nil
                  :on-close (lambda () (etaf-video-studio--release app)))))
    (setf (etaf-video-studio--app-buffer app) buffer)
    (condition-case problem
        (with-current-buffer buffer
          (etaf-video-studio--start-timers app)
          (etaf-video-studio-refresh)
          (when project
            (etaf-video-studio-open-project project))
          buffer)
      ((error)
       (etaf-app-close buffer)
       (signal (car problem) (cdr problem))))))

;;; Requests

(defun etaf-video-studio--after-project (app result &optional message)
  "Adopt RESULT's project into APP and report the error or MESSAGE.
MESSAGE is a string or a function of the adopted project returning one."
  (if (plist-get result :ok)
      (let* ((data (plist-get result :data))
             (text (if (functionp message) (funcall message data) message)))
        (etaf-video-studio--app-adopt-project app data)
        (setf (etaf-video-studio--app-poll-signature app)
              (etaf-video-studio--project-signature data))
        (when (and (stringp text) (not (string-empty-p text)))
          (etaf-video-studio--app-set-message app "%s" text)))
    (etaf-video-studio--app-report-error app result)))

(defun etaf-video-studio--refresh-project (app &optional callback)
  "Refresh APP's current project, then run CALLBACK with the public project."
  (when-let* ((directory (plist-get (etaf-video-studio--app-project app) :directory)))
    (etaf-video-studio--app-request
     app (list "video-project" "status" directory)
     (lambda (result)
       (when (plist-get result :ok)
         (etaf-video-studio--app-adopt-project app (plist-get result :data))
         (funcall callback (plist-get result :data)))))))

(defun etaf-video-studio--root-args (app)
  "Return the `--root' arguments of APP."
  (etaf-video-studio--app-root-args app))

(defun etaf-video-studio-refresh ()
  "Reload the project list and the open project."
  (interactive)
  (let ((app (etaf-video-studio--current)))
    (etaf-video-studio--app-request
     app (append (list "video-project" "list") (etaf-video-studio--root-args app))
     (lambda (result)
       (if (plist-get result :ok)
           (progn
             (setf (etaf-video-studio--app-projects app)
                   (append (plist-get (plist-get result :data) :projects) nil))
             (if (plist-get (etaf-video-studio--app-project app) :directory)
                 (etaf-video-studio--refresh-project
                  app (lambda (_project)
                        (etaf-video-studio--app-set-message app "已刷新。")))
               (etaf-video-studio--app-set-message
                app "找到 %d 个项目。" (length (etaf-video-studio--app-projects app)))))
         (etaf-video-studio--app-report-error app result))))))

(defun etaf-video-studio-open-project (project)
  "Open PROJECT (an id, a directory or a list row) in the studio."
  (interactive
   (list (completing-read "打开项目: "
                          (mapcar (lambda (entry) (plist-get entry :id))
                                  (etaf-video-studio--app-projects
                                   (etaf-video-studio--current)))
                          nil t)))
  (let ((app (etaf-video-studio--current)))
    (when-let* ((directory (cond ((and (consp project) (plist-get project :directory))
                                  (plist-get project :directory))
                                 ((stringp project)
                                  (if (or (file-name-absolute-p project)
                                          (string-match-p "/" project))
                                      project
                                    (let ((root (etaf-video-studio--app-root app)))
                                      (if root (expand-file-name project root) project)))))))
      (etaf-video-studio--app-request
       app (list "video-project" "status" directory)
       (lambda (result)
         (if (plist-get result :ok)
             (let ((data (plist-get result :data)))
               (etaf-video-studio--app-clear-stage app)
               (setf (etaf-video-studio--app-pane app) 'preview
                     (etaf-video-studio--app-pages app) nil
                     (etaf-video-studio--app-clip-index app) nil
                     (etaf-video-studio--app-caption-index app) nil
                     (etaf-video-studio--app-caption-edit-id app) nil
                     (etaf-video-studio--app-publish-preview app) nil)
               (etaf-video-studio--app-adopt-project app data)
               (when (etaf-video-studio--app-selected-clip app)
                 (etaf-video-studio-select-clip 0))
               (etaf-video-studio-refresh)
               (etaf-video-studio--app-set-message
                app "已打开 %s · r%s" (plist-get data :title) (plist-get data :revision)))
           (etaf-video-studio--app-report-error app result)))))))

(defun etaf-video-studio-create-project (title)
  "Create a project titled TITLE and open it.
An empty TITLE signals `user-error'; confirmation and the new directory are
the CLI's, so no local state is guessed."
  (interactive "s项目标题: ")
  (let ((app (etaf-video-studio--current)))
    (when (string-empty-p (string-trim (or title "")))
      (user-error "项目标题不能为空"))
    (etaf-video-studio--app-request
     app (append (list "video-project" "create" "--title" (string-trim title))
                 (etaf-video-studio--root-args app) (list "--yes"))
     (lambda (result)
       (if (plist-get result :ok)
           (let ((directory (plist-get (plist-get result :data) :directory)))
             (etaf-set-value (etaf-video-studio--app-new-title-ref app) "")
             (etaf-video-studio-open-project directory)
             (etaf-video-studio--app-set-message app "已创建项目：%s" (string-trim title)))
         (etaf-video-studio--app-report-error app result))))))

(defun etaf-video-studio-import-files (files)
  "Import FILES into the current project as new clips.
FILES is a list of local media file names; each is probed by the CLI."
  (interactive
   (list (list (read-file-name "导入视频文件: " nil nil t))))
  (let ((app (etaf-video-studio--current)))
    (etaf-video-studio--app-project-args app)
    (unless files
      (user-error "至少需要一个视频文件"))
    (etaf-video-studio--app-request
     app (append (list "video-project" "import" (plist-get (etaf-video-studio--app-project app) :directory))
                 (cl-loop for file in files append (list "--file" (expand-file-name file)))
                 (list "--revision" (number-to-string
                                     (or (plist-get (etaf-video-studio--app-project app) :revision) 0)))
                 (list "--yes"))
     (lambda (result)
       (etaf-video-studio--after-project
        app result (format "已导入 %d 个素材。" (length files)))
       (when (and (plist-get result :ok) (etaf-video-studio--app-clips app))
         (etaf-video-studio-select-clip
          (max 0 (- (length (etaf-video-studio--app-clips app)) (length files)))))))))

(defun etaf-video-studio--sync-clip (app &optional id)
  "Refresh the selected clip's form after an accepted edit, retaining pane.
ID preserves selection through reordering; a removed clip selects its successor."
  (let* ((clips (etaf-video-studio--app-clips app))
         (pane (etaf-video-studio--app-pane app))
         (index (or (and id (cl-position id clips :key (lambda (clip) (plist-get clip :id))
                                         :test #'equal))
                    (etaf-video-studio--app-clip-index app))))
    (if (and clips index)
        (etaf-video-studio-select-clip (min index (1- (length clips))))
      (etaf-video-studio--app-clear-stage app))
    (setf (etaf-video-studio--app-pane app) pane)))

(defun etaf-video-studio--send-edit (app operation description)
  "Apply OPERATION to APP's project and describe it with DESCRIPTION."
  (etaf-video-studio--app-request
   app (list "video-project" "edit"
             (plist-get (etaf-video-studio--app-project app) :directory)
             "--operation" (json-encode operation)
             "--revision" (number-to-string
                           (or (plist-get (etaf-video-studio--app-project app) :revision) 0))
             "--yes")
   (lambda (result)
     (etaf-video-studio--after-project app result description)
     (if (member (plist-get operation :type) '("speed" "gain"))
         ;; A selector is immediately committed, never an unsaved draft.
         ;; Read the accepted value after success or restore the last known
         ;; project value after failure, without erasing pending trim edits.
         (let* ((speed (equal (plist-get operation :type) "speed"))
                (clip (etaf-video-studio--app-selected-clip app)))
           (etaf-set-value (if speed (etaf-video-studio--app-speed-ref app)
                             (etaf-video-studio--app-gain-ref app))
                           (or (plist-get clip (if speed :speed :gain)) 1)))
       (when (and (plist-get result :ok) (plist-get operation :clip))
         (etaf-video-studio--sync-clip app (plist-get operation :clip)))))))

(defun etaf-video-studio--number-from (ref label)
  "Return REF's value parsed as a number; signal `user-error' naming LABEL."
  (let* ((text (string-trim (format "%s" (or (etaf-value ref) ""))))
         (value (string-to-number text)))
    (unless (and (not (string-empty-p text))
                 (string-match-p "\\`[0-9]+\\(\\.[0-9]*\\)?\\'" text)
                 (>= value 0))
      (user-error "%s需要非负数字，当前是 %S" label text))
    value))

(defun etaf-video-studio-apply-trim ()
  "Trim the selected clip to the form's source in and out points."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app)))
    (unless clip (user-error "请先选择一个片段"))
    (let ((in (etaf-video-studio--number-from (etaf-video-studio--app-trim-in-ref app) "入点"))
          (out (etaf-video-studio--number-from (etaf-video-studio--app-trim-out-ref app) "出点")))
      (when (>= in out)
        (user-error "入点必须小于出点"))
      (etaf-video-studio--send-edit
       app (list :type "trim" :clip (plist-get clip :id) :in in :out out)
       (format "已裁切：%s – %ss" in out)))))

(defun etaf-video-studio-apply-split ()
  "Split the selected clip at the form's source time."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app)))
    (unless clip (user-error "请先选择一个片段"))
    (let ((at (etaf-video-studio--number-from (etaf-video-studio--app-split-ref app) "分割点")))
      (etaf-video-studio--send-edit
       app (list :type "split" :clip (plist-get clip :id) :at at)
       (format "已在 %ss 分割。" at)))))

(defun etaf-video-studio--stage-source-time (app)
  "Return APP's stage position in source time, or nil."
  (let* ((stage (etaf-video-studio--app-stage app))
         (state (and stage (ignore-errors
                             (etaf-video-state (etaf-video-studio--app-stage-handle app))))))
    (when (and stage state (eq (plist-get stage :kind) 'clip))
      (or (plist-get state :position) 0))))

(defun etaf-video-studio--draft-mark (app edge)
  "Copy APP's playback position into the trim draft at EDGE, without saving."
  (let ((position (etaf-video-studio--stage-source-time app)))
    (unless position (user-error "请先打开所选片段的素材预览"))
    (etaf-set-value (if (eq edge 'in) (etaf-video-studio--app-trim-in-ref app)
                     (etaf-video-studio--app-trim-out-ref app))
                    (format "%.3f" position))))

(defun etaf-video-studio--select-playback (app kind value)
  "Apply VALUE from APP's KIND selector, restoring the displayed value on error."
  (let* ((speed (eq kind 'speed))
         (ref (if speed (etaf-video-studio--app-speed-ref app)
                (etaf-video-studio--app-gain-ref app)))
         (old (etaf-value ref)))
    (etaf-set-value ref value)
    (condition-case problem
        (if speed (etaf-video-studio-apply-speed) (etaf-video-studio-apply-gain))
      (error (etaf-set-value ref old)
             (signal (car problem) (cdr problem))))))

(defun etaf-video-studio-mark-in ()
  "Set the selected clip's source in point to the stage position."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app))
         (position (and clip (etaf-video-studio--stage-source-time app))))
    (unless clip (user-error "请先选择一个片段"))
    (unless position
      (user-error "先播放素材预览，才能在当前位置设点"))
    (etaf-video-studio--send-edit
     app (list :type "trim" :clip (plist-get clip :id) :in (float position))
     (format "入点设为 %ss" (etaf-video-studio--seconds position)))))

(defun etaf-video-studio-mark-out ()
  "Set the selected clip's source out point to the stage position."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app))
         (position (and clip (etaf-video-studio--stage-source-time app))))
    (unless clip (user-error "请先选择一个片段"))
    (unless position
      (user-error "先播放素材预览，才能在当前位置设点"))
    (etaf-video-studio--send-edit
     app (list :type "trim" :clip (plist-get clip :id) :out (float position))
     (format "出点设为 %ss" (etaf-video-studio--seconds position)))))

(defun etaf-video-studio-split-at-stage ()
  "Split the selected clip at the stage position."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app))
         (position (and clip (etaf-video-studio--stage-source-time app))))
    (unless clip (user-error "请先选择一个片段"))
    (unless position
      (user-error "先播放素材预览，才能在当前位置分割"))
    (etaf-video-studio--send-edit
     app (list :type "split" :clip (plist-get clip :id) :at (float position))
     (format "已在 %ss 分割。" (etaf-video-studio--seconds position)))))

(defun etaf-video-studio-apply-speed ()
  "Apply the speed select to the selected clip."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app))
         (value (etaf-value (etaf-video-studio--app-speed-ref app))))
    (unless clip (user-error "请先选择一个片段"))
    (etaf-video-studio--send-edit
     app (list :type "speed" :clip (plist-get clip :id) :value value)
     (format "速度设为 %sx" (etaf-video-studio--seconds value)))))

(defun etaf-video-studio-apply-gain ()
  "Apply the gain select to the selected clip."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app))
         (value (etaf-value (etaf-video-studio--app-gain-ref app))))
    (unless clip (user-error "请先选择一个片段"))
    (etaf-video-studio--send-edit
     app (list :type "gain" :clip (plist-get clip :id) :value value)
     (format "音量设为 %s%%" (etaf-video-studio--seconds (* 100 value))))))

(defun etaf-video-studio-move-clip-up ()
  "Move the selected clip one position earlier."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app))
         (index (etaf-video-studio--app-clip-index app)))
    (unless (and clip index (> index 0))
      (user-error "已经是第一个片段"))
    (etaf-video-studio--app-request
     app (list "video-project" "edit"
               (plist-get (etaf-video-studio--app-project app) :directory)
               "--operation" (json-encode (list :type "move" :clip (plist-get clip :id)
                                                :to (1- index)))
               "--revision" (number-to-string
                             (or (plist-get (etaf-video-studio--app-project app) :revision) 0))
               "--yes")
     (lambda (result)
       (etaf-video-studio--after-project
        app result (lambda (_data)
                     (setf (etaf-video-studio--app-clip-index app) (1- index))
                     "已上移。"))))))

(defun etaf-video-studio-move-clip-down ()
  "Move the selected clip one position later."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app))
         (index (etaf-video-studio--app-clip-index app))
         (count (length (etaf-video-studio--app-clips app))))
    (unless (and clip index (< index (1- count)))
      (user-error "已经是最后一个片段"))
    (etaf-video-studio--app-request
     app (list "video-project" "edit"
               (plist-get (etaf-video-studio--app-project app) :directory)
               "--operation" (json-encode (list :type "move" :clip (plist-get clip :id)
                                                :to (1+ index)))
               "--revision" (number-to-string
                             (or (plist-get (etaf-video-studio--app-project app) :revision) 0))
               "--yes")
     (lambda (result)
       (etaf-video-studio--after-project
        app result (lambda (_data)
                     (setf (etaf-video-studio--app-clip-index app) (1+ index))
                     "已下移。"))))))

(defun etaf-video-studio-remove-selected-clip ()
  "Remove the selected clip from the project."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app)))
    (unless clip (user-error "请先选择一个片段"))
    (etaf-video-studio--send-edit
     app (list :type "remove" :clip (plist-get clip :id))
     (format "已删除 %s；可按 u 撤销。" (etaf-video-studio--basename (plist-get clip :file))))))

(defun etaf-video-studio--history (direction)
  "Step the project history in DIRECTION (`undo' or `redo')."
  (let* ((app (etaf-video-studio--current))
         (args (list "video-project" "history"
                     (plist-get (etaf-video-studio--app-project app) :directory)
                     (if (eq direction 'undo) "--undo" "--redo")
                     "--revision" (number-to-string
                                   (or (plist-get (etaf-video-studio--app-project app) :revision) 0))
                     "--yes")))
    (etaf-video-studio--app-request
     app args
     (lambda (result)
       (etaf-video-studio--after-project
        app result (if (eq direction 'undo) "已撤销一步。" "已重做一步。"))
       (when (plist-get result :ok)
         (etaf-video-studio--sync-clip app))))))

(defun etaf-video-studio-undo ()
  "Undo the last project edit."
  (interactive)
  (etaf-video-studio--history 'undo))

(defun etaf-video-studio-redo ()
  "Redo the last undone project edit."
  (interactive)
  (etaf-video-studio--history 'redo))

(defun etaf-video-studio--render (profile &optional resume)
  "Start a background render of PROFILE; RESUME reuses validated segments."
  (let* ((app (etaf-video-studio--current))
         (project (etaf-video-studio--app-project app))
         (_ (etaf-video-studio--app-project-args app))
         (args (append (list "video-project" "render" (plist-get project :directory)
                             "--profile" profile "--yes")
                       (when resume (list "--resume")))))
    (unless (etaf-video-studio--app-clips app)
      (user-error "先导入或录制一段素材"))
    (setf (etaf-video-studio--app-pane app)
          (if (equal profile "screen") 'tasks 'preview))
    (etaf-video-studio--app-request
     app args
     (lambda (result)
       (etaf-video-studio--after-project
        app result
        (lambda (data)
          (let ((task (plist-get data :task)))
            (format "%s 已开始：%s"
                    (if (equal profile "preview") "低清预览" "正式导出")
                    (or (plist-get task :id) "任务")))))))))

(defun etaf-video-studio-render-preview ()
  "Start a low-resolution preview render of the current revision."
  (interactive)
  (etaf-video-studio--render "preview"))

(defun etaf-video-studio-render-screen ()
  "Start a background screen-profile export of the current revision."
  (interactive)
  (etaf-video-studio--render "screen"))

(defun etaf-video-studio-task-retry ()
  "Resume an interrupted export of the current revision."
  (interactive)
  (etaf-video-studio--render "screen" t))

(defun etaf-video-studio-cancel-render ()
  "Cancel the current revision's running export."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (directory (plist-get (etaf-video-studio--app-project app) :directory)))
    (etaf-video-studio--app-request
     app (list "video-project" "render" directory "--cancel" "--yes")
     (lambda (result)
       (if (plist-get result :ok)
           (etaf-video-studio--refresh-project
            app (lambda (_project)
                  (etaf-video-studio--app-set-message app "已请求取消导出。")))
         (etaf-video-studio--app-report-error app result))))))

(defun etaf-video-studio-refresh-targets ()
  "Reload the recording target inventory.
Windows and displays are tagged with their kind so `record start' can pass
exactly one of `--window' or `--display'."
  (interactive)
  (let ((app (etaf-video-studio--current)))
    (etaf-video-studio--app-request
     app (list "video-project" "record" "targets")
     (lambda (result)
       (if (plist-get result :ok)
           (let ((data (plist-get result :data)))
             (setf (etaf-video-studio--app-record-targets app)
                   (append (cl-loop for window in (plist-get data :windows)
                                    collect (plist-put (copy-sequence window) :kind "window"))
                           (cl-loop for display in (plist-get data :displays)
                                    collect (plist-put (copy-sequence display) :kind "display"))))
             (setf (etaf-video-studio--app-record-target-index app)
                   (when (etaf-video-studio--app-record-targets app) 0))
             (etaf-video-studio--app-set-message
              app "找到 %d 个录制目标。" (length (etaf-video-studio--app-record-targets app))))
         (etaf-video-studio--app-report-error app result))))))

(defun etaf-video-studio-record-start ()
  "Start recording the selected target with the form's audio and duration."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (target (etaf-video-studio--app-selected-target app))
         (duration-text (string-trim (format "%s" (etaf-value
                                                   (etaf-video-studio--app-record-duration-ref app)))))
         (duration (string-to-number duration-text))
         (audio (format "%s" (etaf-value (etaf-video-studio--app-record-audio-ref app)))))
    (unless target (user-error "请先选择一个录制目标；可按 r 刷新目标列表"))
    (unless (and (string-match-p "\\`[0-9]+\\'" duration-text) (<= 1 duration 7200))
      (user-error "录制时长需要是 1 到 7200 秒的整数"))
    (etaf-video-studio--app-request
     app (list "video-project" "record" "start"
               (plist-get (etaf-video-studio--app-project app) :directory)
               (if (equal (plist-get target :kind) "display") "--display" "--window")
               (number-to-string (plist-get target :id))
               "--audio" audio
               "--duration" (number-to-string duration)
               "--yes")
     (lambda (result)
       (etaf-video-studio--after-project
        app result (format "开始录制：%s（%s，最多 %d 秒）"
                           (or (plist-get target :title) (plist-get target :name))
                           audio duration))))))

(defun etaf-video-studio-record-stop ()
  "Stop the running recording; the worker imports the file afterwards."
  (interactive)
  (let* ((app (etaf-video-studio--current)))
    (etaf-video-studio--app-request
     app (list "video-project" "record" "stop"
               (plist-get (etaf-video-studio--app-project app) :directory)
               "--yes")
     (lambda (result)
       (etaf-video-studio--after-project app result "已请求停止录制；保存完成后自动导入。")))))

(defun etaf-video-studio-toggle-record ()
  "Start recording the selected target, or stop the running recording."
  (interactive)
  (let ((app (etaf-video-studio--current)))
    (if (etaf-video-studio--app-record-task app)
        (etaf-video-studio-record-stop)
      (etaf-video-studio-record-start))))

(defun etaf-video-studio--publish-args (app &optional confirm)
  "Return the publish arguments for APP.
With CONFIRM, include the preview revision and `--yes'."
  (let* ((target (format "%s" (etaf-value (etaf-video-studio--app-publish-target-ref app))))
         (chat (string-trim (format "%s" (etaf-value (etaf-video-studio--app-publish-chat-ref app)))))
         (text (string-trim (format "%s" (etaf-value (etaf-video-studio--app-publish-text-ref app)))))
         (topic (string-trim (format "%s" (etaf-value (etaf-video-studio--app-publish-topic-ref app)))))
         (preview (etaf-video-studio--app-publish-preview app))
         (args (append
                (list "video-project" "publish"
                      (plist-get (etaf-video-studio--app-project app) :directory)
                      "--target" target)
                (when (and (equal target "telegram") (not (string-empty-p chat)))
                  (list "--chat" chat))
                (when (not (string-empty-p text)) (list "--text" text))
                (when (and (not (string-empty-p topic)) (string-match-p "\\`[0-9]+\\'" topic))
                  (list "--topic" topic))
                (when confirm
                  (list "--revision"
                        (number-to-string (or (plist-get preview :revision) 0))
                        "--yes")))))
    args))

(defun etaf-video-studio-publish-preview ()
  "Ask the CLI for the publish preview of the current export."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (target (format "%s" (etaf-value (etaf-video-studio--app-publish-target-ref app))))
         (chat (string-trim (format "%s" (etaf-value (etaf-video-studio--app-publish-chat-ref app)))))
         (args (etaf-video-studio--publish-args app)))
    (when (and (equal target "telegram") (string-empty-p chat))
      (user-error "发布到 Telegram 需要填写 chat"))
    (etaf-video-studio--app-request
     app args
     (lambda (result)
       (if (plist-get result :ok)
           (let ((data (plist-get result :data)))
             (if (equal (plist-get data :status) "preview")
                 (progn
                   (setf (etaf-video-studio--app-publish-preview app)
                         (plist-put data :request args))
                   (etaf-video-studio--app-set-message
                    app "发布预览：r%s → %s（%s）"
                    (plist-get data :revision) (plist-get data :target)
                    (plist-get data :visibility)))
               ;; An identical completed publish is reported as a reused task.
               (etaf-video-studio--app-adopt-project app data)
               (etaf-video-studio--app-set-message app "这份成片与文案已经发布过，未重复发送。")))
         (etaf-video-studio--app-report-error app result))))))

(defun etaf-video-studio-publish-confirm ()
  "Confirm the previewed publish with its revision."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (preview (etaf-video-studio--app-publish-preview app))
         (revision (plist-get (etaf-video-studio--app-project app) :revision)))
    (unless preview (user-error "先预览一次发布"))
    (unless (equal (plist-get preview :revision) revision)
      (user-error "项目已更新，请重新预览发布"))
    (unless (equal (plist-get preview :request)
                   (etaf-video-studio--publish-args app))
      (user-error "发布目标或文案已修改，请重新预览发布"))
    (etaf-video-studio--app-request
     app (etaf-video-studio--publish-args app t)
     (lambda (result)
       (etaf-video-studio--after-project
        app result (format "发布已提交（确认 r%s）。" revision))))))

(defun etaf-video-studio-publish-reset ()
  "Discard the current publish preview."
  (interactive)
  (let ((app (etaf-video-studio--current)))
    (setf (etaf-video-studio--app-publish-preview app) nil)
    (etaf-video-studio--app-set-message app "已放弃发布预览。")
    (etaf-video-studio--app-publish app)))

(defun etaf-video-studio-add-caption ()
  "Add a caption from the form, or update the one being edited."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (start (etaf-video-studio--number-from (etaf-video-studio--app-caption-start-ref app) "开始"))
         (end (etaf-video-studio--number-from (etaf-video-studio--app-caption-end-ref app) "结束"))
         (text (string-trim (format "%s" (or (etaf-value (etaf-video-studio--app-caption-text-ref app)) ""))))
         (id (etaf-video-studio--app-caption-edit-id app)))
    (when (>= start end)
      (user-error "开始必须小于结束"))
    (when (string-empty-p text)
      (user-error "说明文字不能为空"))
    (etaf-video-studio--send-edit
     app (append (list :type "caption") (when id (list :id id))
                 (list :start start :end end :text text))
     (if id "已更新说明。" "已添加说明。"))
    (setf (etaf-video-studio--app-caption-edit-id app) nil
          (etaf-video-studio--app-caption-index app) nil)
    (etaf-set-value (etaf-video-studio--app-caption-id-ref app) "")
    (etaf-video-studio--app-publish app)))

(defun etaf-video-studio-delete-caption ()
  "Delete the selected caption."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (caption (etaf-video-studio--app-selected-caption app)))
    (unless caption (user-error "请先选择一条说明"))
    (etaf-video-studio--send-edit
     app (list :type "caption" :id (plist-get caption :id) :remove t)
     "已删除说明。")
    (setf (etaf-video-studio--app-caption-edit-id app) nil
          (etaf-video-studio--app-caption-index app) nil)
    (etaf-video-studio--app-publish app)))

(defun etaf-video-studio-clear-caption-form ()
  "Clear the caption form and leave edit mode."
  (interactive)
  (let ((app (etaf-video-studio--current)))
    (setf (etaf-video-studio--app-caption-edit-id app) nil
          (etaf-video-studio--app-caption-index app) nil)
    (dolist (accessor '(etaf-video-studio--app-caption-start-ref
                        etaf-video-studio--app-caption-end-ref
                        etaf-video-studio--app-caption-text-ref))
      (etaf-set-value (funcall accessor app) ""))
    (etaf-video-studio--app-publish app)))

;;; Selection and panes

(defun etaf-video-studio-select-pane (pane)
  "Switch to PANE."
  (interactive
   (list (intern (completing-read "面板: "
                                  (mapcar #'symbol-name etaf-video-studio--panes) nil t))))
  (let ((app (etaf-video-studio--current)))
    (unless (memq pane etaf-video-studio--panes)
      (user-error "未知面板：%s" pane))
    (when-let* ((stage (etaf-video-studio--app-stage app))
                (runtime (etaf-runtime-for-buffer (current-buffer)))
                (viewport (etaf-runtime-viewport runtime)))
      (when (or (< (car viewport) etaf-video-studio--aside-min-pixels)
                (< (cdr viewport) 34))
        ;; A single-pane layout unmounts its video while another tool is open.
        (setf (plist-get stage :positioned) nil)))
    (setf (etaf-video-studio--app-pane app) pane)
    (etaf-video-studio--app-publish app)
    (when (and (eq pane 'record) (null (etaf-video-studio--app-record-targets app)))
      (etaf-video-studio-refresh-targets))))

(defun etaf-video-studio--show-pane (pane)
  "Switch to PANE and report it."
  (etaf-video-studio-select-pane pane))

(defun etaf-video-studio-show-record () "Show the recording pane." (interactive)
       (etaf-video-studio--show-pane 'record))
(defun etaf-video-studio-show-captions () "Show the captions pane." (interactive)
       (etaf-video-studio--show-pane 'captions))
(defun etaf-video-studio-show-publish () "Show the publish pane." (interactive)
       (etaf-video-studio--show-pane 'publish))
(defun etaf-video-studio-show-tasks () "Show the tasks pane." (interactive)
       (etaf-video-studio--show-pane 'tasks))

(defun etaf-video-studio-select-clip (index)
  "Select clip INDEX and prefill the trimming form."
  (interactive "n片段序号: ")
  (etaf-batch
   (let* ((app (etaf-video-studio--current))
         (clips (etaf-video-studio--app-clips app)))
    (when (and (integerp index) (<= 0 index) (< index (length clips)))
      (let ((clip (nth index clips)))
        (setf (etaf-video-studio--app-clip-index app) index
              (etaf-video-studio--app-pane app) 'properties
              (alist-get 'clips (etaf-video-studio--app-pages app))
              (/ index etaf-video-studio--page-size))
        (etaf-set-value (etaf-video-studio--app-trim-in-ref app)
                        (etaf-video-studio--seconds (plist-get clip :in)))
        (etaf-set-value (etaf-video-studio--app-trim-out-ref app)
                        (etaf-video-studio--seconds (plist-get clip :out)))
        (etaf-set-value (etaf-video-studio--app-split-ref app)
                        (etaf-video-studio--seconds
                         (+ (or (plist-get clip :in) 0)
                            (/ (- (or (plist-get clip :out) 0) (or (plist-get clip :in) 0)) 2.0))))
        (when (member (or (plist-get clip :speed) 1) '(0.5 1 2 4))
          (etaf-set-value (etaf-video-studio--app-speed-ref app)
                          (or (plist-get clip :speed) 1)))
        (when (member (or (plist-get clip :gain) 1) '(0.5 0.7 1 1.5))
          (etaf-set-value (etaf-video-studio--app-gain-ref app)
                          (or (plist-get clip :gain) 1)))
        (etaf-video-studio-stage-selected-clip)
        (etaf-video-studio--app-publish app))))))

(defun etaf-video-studio-select-caption (index)
  "Select caption INDEX and load it into the form."
  (interactive "n说明序号: ")
  (let* ((app (etaf-video-studio--current))
         (captions (etaf-video-studio--app-captions app)))
    (when (and (integerp index) (<= 0 index) (< index (length captions)))
      (let ((caption (nth index captions)))
        (setf (alist-get 'captions (etaf-video-studio--app-pages app))
              (/ index etaf-video-studio--page-size)
              (etaf-video-studio--app-caption-index app) index
              (etaf-video-studio--app-caption-edit-id app) (plist-get caption :id))
        (etaf-set-value (etaf-video-studio--app-caption-start-ref app)
                        (etaf-video-studio--seconds (plist-get caption :start)))
        (etaf-set-value (etaf-video-studio--app-caption-end-ref app)
                        (etaf-video-studio--seconds (plist-get caption :end)))
        (etaf-set-value (etaf-video-studio--app-caption-text-ref app)
                        (or (plist-get caption :text) ""))
        (etaf-set-value (etaf-video-studio--app-caption-id-ref app)
                        (or (plist-get caption :id) ""))
        (etaf-video-studio--app-publish app)))))

(defun etaf-video-studio-select-target (index)
  "Select recording target INDEX."
  (interactive "n目标序号: ")
  (let* ((app (etaf-video-studio--current))
         (targets (etaf-video-studio--app-record-targets app)))
    (when (and (integerp index) (<= 0 index) (< index (length targets)))
      (setf (etaf-video-studio--app-record-target-index app) index
            (alist-get 'record (etaf-video-studio--app-pages app))
            (/ index etaf-video-studio--page-size))
      (etaf-video-studio--app-publish app))))

(defun etaf-video-studio-select-task (index)
  "Select task INDEX."
  (interactive "n任务序号: ")
  (let* ((app (etaf-video-studio--current))
         (tasks (etaf-video-studio--app-tasks app)))
    (when (and (integerp index) (<= 0 index) (< index (length tasks)))
      (setf (etaf-video-studio--app-task-index app) index)
      (etaf-video-studio--app-publish app))))

;;; Stage

(defun etaf-video-studio-stage-selected-clip ()
  "Show the selected clip's source in the stage, seeked to its in point."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (clip (etaf-video-studio--app-selected-clip app)))
    (unless clip (user-error "请先选择一个片段"))
    (let ((file (plist-get clip :file))
          (base (or (plist-get clip :in) 0)))
      (if (and (stringp file) (file-exists-p file))
          (progn
            (etaf-video-studio--app-set-stage app file 'clip base)
            (etaf-video-studio--app-set-message
             app "素材预览：%s（从 %ss 起）"
             (etaf-video-studio--basename file) (etaf-video-studio--seconds base))
            (etaf-video-studio--app-publish app))
        (etaf-video-studio--app-set-message app "素材文件不存在：%s" (or file "—"))))))

(defun etaf-video-studio-stage-preview-output ()
  "Show the completed preview render of the current revision."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (preview (etaf-video-studio--app-preview app)))
    (unless preview (user-error "当前版本还没有完成的低清预览；按 v 生成"))
    (etaf-video-studio--app-set-stage app (plist-get preview :output) 'preview 0
                                      (plist-get preview :revision))
    (etaf-video-studio--app-set-message app "成片预览：%s"
                                        (etaf-video-studio--basename (plist-get preview :output)))
    (etaf-video-studio--app-publish app)))

(defun etaf-video-studio-toggle-playback ()
  "Toggle the stage video; without a stage, show the selected clip."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (stage (etaf-video-studio--app-stage app))
         (state (and stage
                     (ignore-errors
                       (etaf-video-state (etaf-video-studio--app-stage-handle app))))))
    (cond
     ((and stage state)
      (etaf-video-toggle-playback (etaf-video-studio--app-stage-handle app)))
     (stage
      (etaf-video-studio--app-set-message app "预览正在准备，请稍候。"))
     ((etaf-video-studio--app-preview app)
      (etaf-video-studio-stage-preview-output))
     (t
      (etaf-video-studio-stage-selected-clip)))))

(defun etaf-video-studio-toggle-stage-audio ()
  "Toggle the preview stage's sound."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (ref (etaf-video-studio--app-stage-audio-ref app)))
    (etaf-set-value ref (not (etaf-value ref)))
    (etaf-video-studio--app-set-message
     app (if (etaf-value ref) "预览声音已打开。" "预览声音已关闭。"))))

(defun etaf-video-studio-seek-to (seconds)
  "Seek the displayed source to absolute SECONDS, clamped to its duration."
  (interactive "n定位到秒数: ")
  (unless (and (numberp seconds) (>= seconds 0))
    (user-error "时间必须是非负秒数"))
  (let* ((app (etaf-video-studio--current))
         (handle (etaf-video-studio--app-stage-handle app)))
    (unless (etaf-video-studio--app-stage app)
      (user-error "先选择一个片段或生成成片预览"))
    (let* ((state (etaf-video-state handle))
           (target (min seconds (or (plist-get state :duration) seconds))))
      (etaf-video-seek handle target)
      (etaf-set-value (etaf-video-studio--app-stage-time-ref app) target)
      target)))

(defun etaf-video-studio--seek (delta)
  "Seek the stage video by DELTA seconds when it has a session."
  (let* ((app (etaf-video-studio--current))
         (stage (etaf-video-studio--app-stage app)))
    (unless stage (user-error "还没有可播放的预览"))
    (let* ((state (ignore-errors
                    (etaf-video-state (etaf-video-studio--app-stage-handle app))))
           (position (or (and state (plist-get state :position)) 0))
           (duration (or (and state (plist-get state :duration)) 0))
           (target (max 0 (min duration (+ position delta)))))
      (etaf-video-studio-seek-to target)
      (etaf-video-studio--app-set-message app "定位到 %.1f 秒。" target))))

(defun etaf-video-studio-seek-forward ()
  "Seek the stage video forward five seconds."
  (interactive)
  (etaf-video-studio--seek 5))

(defun etaf-video-studio-seek-backward ()
  "Seek the stage video back five seconds."
  (interactive)
  (etaf-video-studio--seek -5))

;;; Theme and status

(defun etaf-video-studio-toggle-theme ()
  "Switch between the dark and light palette."
  (interactive)
  (let ((app (etaf-video-studio--current)))
    (setq etaf-video-studio-theme-mode
          (if (eq etaf-video-studio-theme-mode 'dark) 'light 'dark))
    (etaf-set-value (etaf-video-studio--app-theme-ref app)
                    (etaf-video-studio-theme-defaults))
    (etaf-video-studio--app-set-message
     app "已切换为%s主题。" (if (eq etaf-video-studio-theme-mode 'dark) "深色" "浅色"))
    (etaf-video-studio--app-publish app)))

(defun etaf-video-studio--stage-tick (app)
  "Refresh APP's stage clock and playing state without a View rebuild."
  (when (buffer-live-p (etaf-video-studio--app-buffer app))
    (let* ((stage (etaf-video-studio--app-stage app))
           (state (and stage
                       (ignore-errors
                         (etaf-video-state
                          (etaf-video-studio--app-stage-handle app))))))
      (when state
        (etaf-set-value (etaf-video-studio--app-stage-time-ref app)
                        (or (plist-get state :position) 0)))
      (when (and state (not (plist-get stage :positioned)))
        (setf (plist-get stage :positioned) t)
        (when (> (or (plist-get stage :base) 0) 0)
          (etaf-video-seek (etaf-video-studio--app-stage-handle app)
                           (plist-get stage :base))))
      (when (buffer-live-p (etaf-video-studio--app-buffer app))
        (let ((playing (and state (plist-get state :playing) t))
              (position (if (and state stage)
                            (format "%s / %s%s"
                                    (etaf-video-studio--clock
                                     (or (plist-get state :position) 0))
                                    (etaf-video-studio--clock (plist-get state :duration))
                                    (cond ((plist-get state :playing) " · 播放中")
                                          ((plist-get state :ended) " · 已结束")
                                          (t " · 已暂停")))
                          (if stage "—" nil))))
          (setf (etaf-video-studio--app-stage-position app) position)
          (when (and (not (equal playing (etaf-video-studio--app-stage-playing app)))
                     (not (null stage)))
            (setf (etaf-video-studio--app-stage-playing app) playing)
            (etaf-video-studio--app-publish app))
          (when position
            (let ((runtime (with-current-buffer (etaf-video-studio--app-buffer app)
                             (ignore-errors (etaf-runtime-for-buffer (current-buffer))))))
              (when (and runtime (etaf-runtime-mounted-p runtime))
                (ignore-errors
                  (etaf-runtime-update-host-content runtime 'video-studio-position position))
                (ignore-errors
                  (etaf-runtime-update-host-content runtime 'video-studio-footer-position position))))))))))

(defun etaf-video-studio--project-signature (project)
  "Return a compact signature of PROJECT for change detection."
  (when project
    (list (plist-get project :revision)
          (plist-get project :updated)
          (mapcar (lambda (task)
                    (list (plist-get task :id) (plist-get task :status)
                          (plist-get task :last_write) (plist-get task :receipt)))
                  (plist-get project :tasks)))))

(defun etaf-video-studio--poll (app)
  "Refresh a displayed project when its state or tasks changed."
  (when (buffer-live-p (etaf-video-studio--app-buffer app))
    (let* ((active (etaf-video-studio--app-active-tasks app))
           (displayed (get-buffer-window (etaf-video-studio--app-buffer app) t))
           (tick (1+ (or (etaf-video-studio--app-poll-tick app) 0))))
      (setf (etaf-video-studio--app-poll-tick app) tick)
      (when (and (plist-get (etaf-video-studio--app-project app) :directory)
                 (zerop (etaf-video-studio--app-pending app))
                 (or active
                     (and displayed (zerop (% tick etaf-video-studio-idle-poll-ticks)))))
        (etaf-video-studio--app-request-quiet
         app (list "video-project" "status"
                   (plist-get (etaf-video-studio--app-project app) :directory))
         (lambda (result)
           (when (plist-get result :ok)
             (let* ((data (plist-get result :data))
                    (signature (etaf-video-studio--project-signature data))
                    (previous (etaf-video-studio--app-preview app)))
               (unless (equal signature (etaf-video-studio--app-poll-signature app))
                 (setf (etaf-video-studio--app-poll-signature app) signature)
                 (etaf-video-studio--app-adopt-project app data)
                 ;; A preview that just finished becomes the stage even when
                 ;; the user was watching a clip, because the render was the
                 ;; explicit request; later clip selections stay selected.
                 (let ((preview (etaf-video-studio--app-preview app)))
                   (when (and preview
                              (not (equal (plist-get previous :output)
                                          (plist-get preview :output))))
                     (etaf-video-studio--app-set-stage
                      app (plist-get preview :output) 'preview 0
                      (plist-get preview :revision))))
                 (etaf-video-studio--app-publish app))))))))))

;;; Public state

(defun etaf-video-studio-page-list (kind delta)
  "Move KIND's list by DELTA pages, keeping selection unchanged.
KIND is projects, clips, captions, record or tasks.  DELTA is an integer."
  (let ((app (etaf-video-studio--current)))
    (unless (and (memq kind '(projects clips captions record tasks))
                 (integerp delta))
      (user-error "列表或页码无效"))
    (setf (alist-get kind (etaf-video-studio--app-pages app))
          (max 0 (+ (etaf-video-studio--page app kind) delta)))
    (setf (alist-get kind (etaf-video-studio--app-pages app))
          (etaf-video-studio--page app kind))
    (etaf-video-studio--app-publish app)))

(defun etaf-video-studio-show-export ()
  "Reveal the current revision's completed export in the file manager."
  (interactive)
  (let* ((app (etaf-video-studio--current))
         (task (etaf-video-studio--app-screen-export app))
         (file (plist-get task :output)))
    (unless (and file (file-exists-p file))
      (user-error "当前版本还没有可打开的成片，请先导出"))
    (if (eq system-type 'darwin)
        (start-process "video-studio-reveal" nil "open" "-R" file)
      (dired (file-name-directory file)))
    file))

(defun etaf-video-studio-state ()
  "Return the current studio's state as a detached plist.
Keys are `:buffer', `:root', `:projects' (count), `:project' (id title
revision or nil), `:pane', `:clip-index', `:caption-index', `:task-index',
`:clips' (count), `:captions' (count), `:tasks' (status list), `:record'
(the active recording task or nil), `:preview' (output revision), `:stage'
(source path and kind), `:stage-playing', `:pending' and `:message'."
  (let* ((app (etaf-video-studio--current))
         (project (etaf-video-studio--app-project app))
         (preview (etaf-video-studio--app-preview app))
         (stage (etaf-video-studio--app-stage app)))
    (list :buffer (etaf-video-studio--app-buffer app)
          :root (etaf-video-studio--app-root app)
          :projects (length (etaf-video-studio--app-projects app))
          :project (when project
                     (list :id (plist-get project :id)
                           :title (plist-get project :title)
                           :revision (plist-get project :revision)
                           :directory (plist-get project :directory)
                           :undo (plist-get project :undo)
                           :redo (plist-get project :redo)))
          :pane (etaf-video-studio--app-pane app)
          :pages (mapcar (lambda (kind) (cons kind (etaf-video-studio--page app kind)))
                         '(projects clips captions record tasks))
          :clip-index (etaf-video-studio--app-clip-index app)
          :caption-index (etaf-video-studio--app-caption-index app)
          :task-index (etaf-video-studio--app-task-index app)
          :clips (length (etaf-video-studio--app-clips app))
          :captions (length (etaf-video-studio--app-captions app))
          :tasks (mapcar (lambda (task)
                           (list :id (plist-get task :id)
                                 :kind (plist-get task :kind)
                                 :status (plist-get task :status)
                                 :revision (plist-get task :revision)
                                 :profile (plist-get task :profile)
                                 :output (plist-get task :output)))
                         (etaf-video-studio--app-tasks app))
          :record-targets (length (etaf-video-studio--app-record-targets app))
          :record-target-index (etaf-video-studio--app-record-target-index app)
          :record (etaf-video-studio--app-record-task app)
          :preview (when preview
                     (list :output (plist-get preview :output)
                           :revision (plist-get preview :revision)))
          :publish-preview
          (let ((sent (etaf-video-studio--app-publish-preview app)))
            (when sent
              (list :revision (plist-get sent :revision)
                    :target (plist-get sent :target)
                    :chat (plist-get sent :chat)
                    :text (plist-get sent :text)
                    :visibility (plist-get sent :visibility))))
          :stage (when stage
                   (list :file (plist-get stage :file)
                         :kind (plist-get stage :kind)
                         :base (plist-get stage :base)
                         :position (etaf-value (etaf-video-studio--app-stage-time-ref app))))
          :stage-playing (etaf-video-studio--app-stage-playing app)
          :pending (etaf-video-studio--app-pending app)
          :message (etaf-video-studio--app-message app))))

(provide 'etaf-video-studio-app)
;;; etaf-video-studio-app.el ends here
