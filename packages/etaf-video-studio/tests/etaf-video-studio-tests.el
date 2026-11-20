;;; etaf-video-studio-tests.el --- Acceptance tests for etaf-video-studio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behavior scenarios.  Every scenario drives the application through
;; the interfaces declared in `etaf-video-studio.el' with a fixture
;; `pi-skill' that returns canned JSON and records its arguments; no project
;; store, ffmpeg, network or GUI is touched.  Internal helpers, private
;; structures and call counts stay out.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'etaf-video-studio)
(require 'etaf-ui)

(defconst etaf-video-studio-tests--fake
  (expand-file-name "fixtures/fake-pi-skill"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Fixture CLI standing in for `pi-skill'.")

(defvar etaf-video-studio-tests--root nil
  "Fixture library of the running scenario.")

(defvar etaf-video-studio-tests--log nil
  "Fixture invocation log of the running scenario.")

(defun etaf-video-studio-tests--json (value)
  "Encode VALUE as JSON keeping keyword plists objects and lists arrays.
`json-encode' guesses a list of plists as an alist, so fixtures use this
small recursive encoder instead."
  (cond
   ((null value) "null")
   ((eq value t) "true")
   ((stringp value) (json-encode value))
   ((numberp value) (number-to-string value))
   ((and (consp value) (keywordp (car value)))
    (concat "{"
            (mapconcat (lambda (pair)
                         (concat (json-encode (substring (symbol-name (car pair)) 1))
                                 ":" (etaf-video-studio-tests--json (cdr pair))))
                       (cl-loop for (key val) on value by #'cddr collect (cons key val))
                       ",")
            "}"))
   ((consp value)
    (concat "[" (mapconcat #'etaf-video-studio-tests--json value ",") "]"))
   (t (json-encode value))))

(defun etaf-video-studio-tests--write (name object)
  "Write OBJECT as JSON response NAME in the fixture library."
  (with-temp-file (expand-file-name name etaf-video-studio-tests--root)
    (insert (etaf-video-studio-tests--json object) "\n")))

(defun etaf-video-studio-tests--project (&rest overrides)
  "Return a public project plist with OVERRIDES."
  (let ((base (list :ok t
                    :id "video-1"
                    :title "教程样例"
                    :directory (expand-file-name "video-1" etaf-video-studio-tests--root)
                    :revision 0
                    :updated "2026-10-13T00:00:00Z"
                    :plan (list :version 1 :clips nil :captions nil)
                    :timeline nil
                    :duration 0
                    :undo nil
                    :redo nil
                    :history nil
                    :tasks nil)))
    (while overrides
      (setq base (plist-put base (pop overrides) (pop overrides))))
    base))

(defun etaf-video-studio-tests--clip (&rest overrides)
  "Return a plan clip plist with OVERRIDES."
  (let ((base (list :id "clip-1"
                    :file (expand-file-name "missing-source.mp4" etaf-video-studio-tests--root)
                    :in 0 :out 5 :speed 1 :gain 1)))
    (while overrides
      (setq base (plist-put base (pop overrides) (pop overrides))))
    base))

(defun etaf-video-studio-tests--setup ()
  "Create a fresh fixture library and return its directory."
  (setq etaf-video-studio-tests--root (make-temp-file "etaf-video-studio-" t)
        etaf-video-studio-tests--log (expand-file-name "calls.jsonl"
                                                       etaf-video-studio-tests--root))
  (setenv "FAKE_PI_SKILL_ROOT" etaf-video-studio-tests--root)
  (setenv "FAKE_PI_SKILL_LOG" etaf-video-studio-tests--log)
  (etaf-video-studio-tests--write "list.json" (list :ok t :projects nil
                                                    :root etaf-video-studio-tests--root))
  etaf-video-studio-tests--root)

(defun etaf-video-studio-tests--cleanup ()
  "Close the studio and remove the fixture library."
  (let ((buffer (get-buffer "*Video Studio*")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ignore-errors (etaf-video-studio-close)))))
  (when (and etaf-video-studio-tests--root
             (file-directory-p etaf-video-studio-tests--root))
    (ignore-errors (delete-directory etaf-video-studio-tests--root t)))
  (setq etaf-video-studio-tests--root nil
        etaf-video-studio-tests--log nil))

(defmacro etaf-video-studio-tests--with-app (arguments &rest body)
  "Open the studio with ARGUMENTS in a fixture library and run BODY.
ARGS is the argument list for `etaf-video-studio-open'; the fixture library
and the fake CLI are active only inside the body."
  (declare (indent 1) (debug (form body)))
  `(let* ((etaf-video-studio-executable etaf-video-studio-tests--fake)
          (etaf-video-studio-root (etaf-video-studio-tests--setup))
          (etaf-video-studio-theme-mode 'dark)
          (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (etaf-video-studio-open ,@arguments))
           (etaf-video-studio-tests--wait buffer)
           (with-current-buffer buffer
             ,@body))
       (etaf-video-studio-tests--cleanup))))

(defun etaf-video-studio-tests--wait (buffer &optional extra)
  "Wait until BUFFER's studio has no pending CLI query and EXTRA holds."
  (with-current-buffer buffer
    (let ((end (+ (float-time) 15)))
      (while (and (< (float-time) end)
                  (or (> (plist-get (etaf-video-studio-state) :pending) 0)
                      (not (funcall (or extra (lambda () t))))))
        (accept-process-output nil 0.05))
      (should (zerop (plist-get (etaf-video-studio-state) :pending))))))

(defun etaf-video-studio-tests--settle (buffer)
  "Wait for BUFFER's studio to finish its in-flight CLI queries."
  (etaf-video-studio-tests--wait buffer))

(defun etaf-video-studio-tests--body (buffer)
  "Return BUFFER's visible text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-video-studio-tests--calls ()
  "Return the fixture invocations as a list of argument lists."
  (when (and etaf-video-studio-tests--log
             (file-exists-p etaf-video-studio-tests--log))
    (with-temp-buffer
      (insert-file-contents etaf-video-studio-tests--log)
      (goto-char (point-min))
      (cl-loop while (not (eobp))
               for line = (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position))
               unless (string-empty-p line)
               collect (json-parse-string line :array-type 'list)
               do (forward-line 1)))))

(defun etaf-video-studio-tests--calls-for (command)
  "Return recorded invocations whose second argument is COMMAND."
  (cl-remove-if-not (lambda (call) (equal (nth 1 call) command))
                    (etaf-video-studio-tests--calls)))

(defun etaf-video-studio-tests--argument (arguments flag)
  "Return the value after FLAG in ARGUMENTS."
  (cadr (member flag arguments)))

(defun etaf-video-studio-tests--operation (call)
  "Parse CALL's `--operation' JSON."
  (json-parse-string (etaf-video-studio-tests--argument call "--operation")
                     :object-type 'plist :array-type 'list))

(defun etaf-video-studio-tests--edit-operation (command)
  "Run public edit COMMAND and return the operation it sent."
  (let ((count (length (etaf-video-studio-tests--calls-for "edit"))))
    (funcall command)
    (etaf-video-studio-tests--wait (current-buffer)
                                   (lambda ()
                                     (> (length (etaf-video-studio-tests--calls-for "edit"))
                                        count)))
    (etaf-video-studio-tests--operation
     (car (last (etaf-video-studio-tests--calls-for "edit"))))))

(defun etaf-video-studio-tests--type-input (ref text)
  "Type TEXT into the mounted text input REF through the UI.
The field's value must be empty or already the desired prefix."
  (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
    (should (etaf-text-input-begin runtime ref))
    (execute-kbd-macro (vconcat text))
    (etaf-text-input-end)))

(defun etaf-video-studio-tests--replace-input (ref text)
  "Replace the mounted text input REF's nonempty value with TEXT."
  (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
    (should (etaf-text-input-begin runtime ref))
    (execute-kbd-macro (kbd "C-a"))
    (execute-kbd-macro (kbd "C-k"))
    (execute-kbd-macro (vconcat text))
    (etaf-text-input-end)))

;;; Opening and closing

(ert-deftest etaf-video-studio-tests-open-mounts-and-close-releases ()
  "Opening mounts a live runtime and closing unmounts and kills the buffer."
  (etaf-video-studio-tests--with-app ()
    (should (buffer-live-p (current-buffer)))
    (should (etaf-runtime-for-buffer (current-buffer)))
    (let ((body (etaf-video-studio-tests--body (current-buffer))))
      (should (string-match-p "视频工作台" body))
      (should (string-match-p "项目" body))
      (should (string-match-p "预览" body))))
  (should-not (get-buffer "*Video Studio*")))

(ert-deftest etaf-video-studio-tests-open-project-lists-clips-and-captions ()
  "Opening a project shows its timeline and revision from the CLI."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "list.json"
     (list :ok t
           :projects (list (list :id "video-1" :title "教程样例"
                                 :directory (expand-file-name
                                             "video-1" etaf-video-studio-tests--root)
                                 :updated "2026-10-13T00:00:00Z" :revision 1))
           :root etaf-video-studio-tests--root))
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :revision 1
      :duration 12.5
      :plan (list :version 1
                  :clips (list (etaf-video-studio-tests--clip))
                  :captions (list (list :id "caption-1" :start 1 :end 3
                                        :text "先打开设置")))))
    (etaf-video-studio-refresh)
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((state (etaf-video-studio-state)))
      (should (= 1 (plist-get state :clips)))
      (should (= 1 (plist-get state :captions)))
      (should (= 1 (plist-get (plist-get state :project) :revision))))
    ;; The narrow layout hides the sidebar; the wide one shows clip rows.
    (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer)) 1600 60)
    (etaf-video-studio-tests--settle (current-buffer))
    (should (string-match-p "missing-source.mp4" (etaf-video-studio-tests--body (current-buffer))))
    (etaf-video-studio-select-pane 'captions)
    (etaf-video-studio-tests--settle (current-buffer))
    (should (string-match-p "先打开设置" (etaf-video-studio-tests--body (current-buffer))))))

;;; Importing

(ert-deftest etaf-video-studio-tests-import-files-send-files-and-revision ()
  "Import sends every file with the current revision and --yes."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json" (etaf-video-studio-tests--project :revision 2))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-import-files (list "one.mp4" "two.mp4"))
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((import (car (last (etaf-video-studio-tests--calls-for "import")))))
      (should (equal (expand-file-name "one.mp4") (etaf-video-studio-tests--argument import "--file")))
      (should (member (expand-file-name "two.mp4") import))
      (should (equal "2" (etaf-video-studio-tests--argument import "--revision")))
      (should (member "--yes" import)))))

;;; Editing

(ert-deftest etaf-video-studio-tests-select-clip-prefills-and-trim-sends-edit ()
  "Selecting a clip prefills the form and applying it sends a trim."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :revision 1
      :plan (list :version 1
                  :clips (list (etaf-video-studio-tests--clip :in 1.5 :out 6.5))
                  :captions nil)))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-clip 0)
    (should (= 0 (plist-get (etaf-video-studio-state) :clip-index)))
    (let ((operation (etaf-video-studio-tests--edit-operation
                      #'etaf-video-studio-apply-trim)))
      (should (equal "trim" (plist-get operation :type)))
      (should (equal "clip-1" (plist-get operation :clip)))
      (should (= 1.5 (plist-get operation :in)))
      (should (= 6.5 (plist-get operation :out))))
    (let ((trim (car (last (etaf-video-studio-tests--calls-for "edit")))))
      (should (equal "1" (etaf-video-studio-tests--argument trim "--revision")))
      (should (member "--yes" trim)))))

(ert-deftest etaf-video-studio-tests-trim-input-editing-changes-operation ()
  "Typing in the trim field changes the operation the CLI receives."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :version 1
                  :clips (list (etaf-video-studio-tests--clip :in 0 :out 5))
                  :captions nil)))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'properties)
    (progn
      (etaf-video-studio-select-clip 0)
      (etaf-video-studio-tests--replace-input 'video-studio-trim-in "2.25")
      (let ((operation (etaf-video-studio-tests--edit-operation
                        #'etaf-video-studio-apply-trim)))
        (should (= 2.25 (plist-get operation :in)))
        (should (= 5 (plist-get operation :out)))))))

(ert-deftest etaf-video-studio-tests-edit-commands-send-exact-operations ()
  "Speed, gain, split, move and remove each send their documented JSON."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :version 1
                  :clips (list (etaf-video-studio-tests--clip :id "clip-1" :speed 2 :gain 0.7)
                               (etaf-video-studio-tests--clip :id "clip-2" :in 3 :out 4))
                  :captions nil)))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (progn
      (etaf-video-studio-select-clip 0)
      (let ((speed (etaf-video-studio-tests--edit-operation
                    #'etaf-video-studio-apply-speed)))
        (should (equal "speed" (plist-get speed :type)))
        (should (= 2 (plist-get speed :value))))
      (let ((gain (etaf-video-studio-tests--edit-operation
                   #'etaf-video-studio-apply-gain)))
        (should (equal "gain" (plist-get gain :type)))
        (should (= 0.7 (plist-get gain :value))))
      (let ((split (etaf-video-studio-tests--edit-operation
                    #'etaf-video-studio-apply-split)))
        (should (equal "split" (plist-get split :type)))
        (should (= 2.5 (plist-get split :at))))
      (etaf-video-studio-select-clip 1)
      (let ((move (etaf-video-studio-tests--edit-operation
                   #'etaf-video-studio-move-clip-up)))
        (should (equal "move" (plist-get move :type)))
        (should (= 0 (plist-get move :to))))
      (etaf-video-studio-select-clip 0)
      (let ((remove (etaf-video-studio-tests--edit-operation
                     #'etaf-video-studio-remove-selected-clip)))
        (should (equal "remove" (plist-get remove :type)))
        (should (equal "clip-1" (plist-get remove :clip)))))))

(ert-deftest etaf-video-studio-tests-undo-and-redo-step-history ()
  "Undo and redo send the history flag with the current revision."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project :undo t :redo nil :revision 4))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-undo)
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-redo)
    (etaf-video-studio-tests--settle (current-buffer))
    (let* ((calls (etaf-video-studio-tests--calls-for "history"))
           (undo (car calls))
           (redo (car (last calls))))
      (should (member "--undo" undo))
      (should (equal "4" (etaf-video-studio-tests--argument undo "--revision")))
      (should (member "--redo" redo))
      (should (member "--yes" redo)))))

;;; Rendering and tasks

(ert-deftest etaf-video-studio-tests-render-preview-starts-a-task ()
  "A preview request starts the background preview profile of the revision."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :version 1
                  :clips (list (etaf-video-studio-tests--clip))
                  :captions nil)))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-render-preview)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((render (car (last (etaf-video-studio-tests--calls-for "render")))))
      (should (equal "preview" (etaf-video-studio-tests--argument render "--profile")))
      (should (member "--yes" render)))
    (etaf-video-studio-render-screen)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((render (car (last (etaf-video-studio-tests--calls-for "render")))))
      (should (equal "screen" (etaf-video-studio-tests--argument render "--profile")))
      (should (member "--yes" render)))
    (etaf-video-studio-task-retry)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((retry (car (last (etaf-video-studio-tests--calls-for "render")))))
      (should (equal "screen" (etaf-video-studio-tests--argument retry "--profile")))
      (should (member "--resume" retry)))))

(ert-deftest etaf-video-studio-tests-refresh-adopts-completed-preview ()
  "A completed preview render becomes the project's playable preview."
  (etaf-video-studio-tests--with-app ()
    (let ((output (expand-file-name "r0-preview.mp4" etaf-video-studio-tests--root)))
      (etaf-video-studio-tests--write
       "status.json"
       (etaf-video-studio-tests--project
        :plan (list :version 1
                    :clips (list (etaf-video-studio-tests--clip))
                    :captions nil)
        :tasks (list (list :id "task-1" :kind "render" :job "video-render-1"
                           :status "completed" :revision 0 :profile "preview"
                           :output output :created "2026-10-13T00:00:00Z"))))
      (etaf-video-studio-open-project "video-1")
      (etaf-video-studio-tests--settle (current-buffer))
      (let ((state (etaf-video-studio-state)))
        (should (equal output (plist-get (plist-get state :preview) :output)))
        (should (= 0 (plist-get (plist-get state :preview) :revision))))
      ;; The output does not exist, so nothing is mounted and no decoder runs.
      (should-not (plist-get (etaf-video-studio-state) :stage)))))

(ert-deftest etaf-video-studio-tests-task-panel-lists-tasks-and-cancel ()
  "The tasks pane lists CLI tasks and cancel sends its CLI request."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :tasks (list (list :id "task-9" :kind "render" :job "video-render-9"
                         :status "running" :revision 2 :profile "screen"
                         :output "exports/r2-screen.mp4" :created "2026-10-13T00:00:00Z"))))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'tasks)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((body (etaf-video-studio-tests--body (current-buffer)))
          (output (plist-get (car (plist-get (etaf-video-studio-state) :tasks)) :output)))
      (should (string-match-p "r2-screen.mp4" body))
      (should (equal "exports/r2-screen.mp4" output)))
    (etaf-video-studio-cancel-render)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((cancel (car (last (etaf-video-studio-tests--calls-for "render")))))
      (should (member "--cancel" cancel))
      (should (member "--yes" cancel)))))

;;; Recording

(ert-deftest etaf-video-studio-tests-record-targets-and-toggle-record ()
  "Targets come from the CLI and the toggle sends window, audio and duration."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json" (etaf-video-studio-tests--project))
    (etaf-video-studio-tests--write
     "targets.json"
     (list :ok t
           :windows (list (list :id 101 :title "Emacs" :app "Emacs" :width 1200 :height 800))
           :displays (list (list :id 1 :name "主屏幕" :width 2560 :height 1440))))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-refresh-targets)
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'record)
    (etaf-video-studio-tests--replace-input 'video-studio-record-duration "120")
    (etaf-video-studio-toggle-record)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((start (car (last (etaf-video-studio-tests--calls-for "record")))))
      (should (member "start" start))
      (should (equal "101" (etaf-video-studio-tests--argument start "--window")))
      (should (equal "none" (etaf-video-studio-tests--argument start "--audio")))
      (should (equal "120" (etaf-video-studio-tests--argument start "--duration")))
      (should (member "--yes" start)))
    (etaf-video-studio-record-stop)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((stop (car (last (etaf-video-studio-tests--calls-for "record")))))
      (should (member "stop" stop))
      (should (member "--yes" stop)))))

;;; Publishing

(ert-deftest etaf-video-studio-tests-publish-preview-then-confirm-with-revision ()
  "Publishing previews silently and confirms with the previewed revision."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :revision 3
      :tasks (list (list :id "task-2" :kind "render" :job "video-render-2"
                         :status "completed" :revision 3 :profile "screen"
                         :output "exports/r3-screen.mp4" :created "2026-10-13T00:00:00Z"))))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'publish)
    (etaf-video-studio-tests--type-input 'video-studio-publish-chat "12345")
    (etaf-video-studio-tests--type-input 'video-studio-publish-text "发布说明")
    (etaf-video-studio-publish-preview)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((preview (car (last (etaf-video-studio-tests--calls-for "publish")))))
      (should (equal "telegram" (etaf-video-studio-tests--argument preview "--target")))
      (should (equal "12345" (etaf-video-studio-tests--argument preview "--chat")))
      (should (equal "发布说明" (etaf-video-studio-tests--argument preview "--text")))
      (should-not (member "--yes" preview)))
    (should (= 3 (plist-get (plist-get (etaf-video-studio-state) :publish-preview) :revision)))
    (etaf-video-studio-publish-confirm)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((confirm (car (last (etaf-video-studio-tests--calls-for "publish")))))
      (should (equal "3" (etaf-video-studio-tests--argument confirm "--revision")))
      (should (member "--yes" confirm)))))

(ert-deftest etaf-video-studio-tests-publish-confirm-before-preview-signals ()
  "Confirming without a preview, or after an edit, signals `user-error'."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :revision 1
      :tasks (list (list :id "task-3" :kind "render" :job "video-render-3"
                         :status "completed" :revision 1 :profile "screen"
                         :output "exports/r1-screen.mp4" :created "2026-10-13T00:00:00Z"))))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (should-error (etaf-video-studio-publish-confirm) :type 'user-error)
    (etaf-video-studio-select-pane 'publish)
    (etaf-video-studio-tests--type-input 'video-studio-publish-chat "12345")
    (etaf-video-studio-publish-preview)
    (etaf-video-studio-tests--settle (current-buffer))
    ;; A newer revision invalidates the confirmation.
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project :revision 2))
    (etaf-video-studio-refresh)
    (etaf-video-studio-tests--settle (current-buffer))
    (should-not (plist-get (etaf-video-studio-state) :publish-preview))
    (should-error (etaf-video-studio-publish-confirm) :type 'user-error)))

;;; Captions

(ert-deftest etaf-video-studio-tests-captions-add-update-delete ()
  "Captions can be added, updated by id and removed through the CLI."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :version 1 :clips (list (etaf-video-studio-tests--clip))
                  :captions (list (list :id "caption-1" :start 1 :end 3
                                        :text "旧说明")))))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'captions)
    (etaf-video-studio-tests--settle (current-buffer))
    ;; Update the selected caption through the prefilled form.
    (etaf-video-studio-select-caption 0)
    ;; Submitting the text field runs the update; no second call is needed.
    (etaf-video-studio-tests--replace-input 'video-studio-caption-text "新说明")
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((update (car (last (etaf-video-studio-tests--calls-for "edit")))))
      (should (equal "caption-1" (plist-get (etaf-video-studio-tests--operation update) :id)))
      (should (equal "新说明" (plist-get (etaf-video-studio-tests--operation update) :text))))
    ;; Delete it.
    (etaf-video-studio-select-caption 0)
    (etaf-video-studio-delete-caption)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((delete (car (last (etaf-video-studio-tests--calls-for "edit")))))
      (should (eq t (plist-get (etaf-video-studio-tests--operation delete) :remove))))
    ;; Add a new one from a cleared form.
    (etaf-video-studio-clear-caption-form)
    (etaf-video-studio-tests--type-input 'video-studio-caption-start "2")
    (etaf-video-studio-tests--type-input 'video-studio-caption-end "4")
    (etaf-video-studio-tests--type-input 'video-studio-caption-text "新加的说明")
    (etaf-video-studio-tests--settle (current-buffer))
    (let* ((add (car (last (etaf-video-studio-tests--calls-for "edit"))))
           (operation (etaf-video-studio-tests--operation add)))
      (should (equal "caption" (plist-get operation :type)))
      (should-not (plist-get operation :id))
      (should (= 2 (plist-get operation :start)))
      (should (equal "新加的说明" (plist-get operation :text))))))

;;; Keys and panes

(ert-deftest etaf-video-studio-tests-documented-keys-drive-commands ()
  "The documented keys switch panes, refresh, toggle the theme and close."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json" (etaf-video-studio-tests--project :undo t))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (execute-kbd-macro (kbd "t"))
    (should (eq 'tasks (plist-get (etaf-video-studio-state) :pane)))
    (execute-kbd-macro (kbd "p"))
    (should (eq 'publish (plist-get (etaf-video-studio-state) :pane)))
    (execute-kbd-macro (kbd "r"))
    (should (eq 'record (plist-get (etaf-video-studio-state) :pane)))
    (execute-kbd-macro (kbd "c"))
    (should (eq 'captions (plist-get (etaf-video-studio-state) :pane)))
    (let ((calls (length (etaf-video-studio-tests--calls-for "list"))))
      (execute-kbd-macro (kbd "g"))
      (etaf-video-studio-tests--wait (current-buffer)
                                     (lambda ()
                                       (> (length (etaf-video-studio-tests--calls-for "list"))
                                          calls))))
    (execute-kbd-macro (kbd "T"))
    (should (eq etaf-video-studio-theme-mode 'light))
    (execute-kbd-macro (kbd "u"))
    (etaf-video-studio-tests--settle (current-buffer))
    (should (member "--undo" (car (last (etaf-video-studio-tests--calls-for "history")))))
    (execute-kbd-macro (kbd "q"))
    (should-not (get-buffer "*Video Studio*"))))

;; Emacs ignores a face attribute that is not a color and logs it on every
;; redisplay; help's dimmed backdrop cannot paint it at all.
(defun etaf-video-studio-tests--deferred-faces (buffer)
  "Return the deferred Theme tokens left in BUFFER's face properties."
  (with-current-buffer buffer
    (let ((position (point-min)) found walk)
      (setq walk (lambda (value)
                   (cond ((etaf-theme-token-p value) (push (nth 1 value) found))
                         ((consp value)
                          (funcall walk (car value))
                          (funcall walk (cdr value))))))
      (while (< position (point-max))
        (funcall walk (get-text-property position 'face))
        (setq position (next-single-property-change position 'face nil (point-max))))
      (delete-dups found))))

(ert-deftest etaf-video-studio-tests-faces-hold-concrete-colors ()
  "Every pane paints concrete colors in both themes, including its icons."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "list.json"
     (list :ok t
           :projects (list (list :id "video-1" :title "教程样例"
                                 :directory (expand-file-name
                                             "video-1" etaf-video-studio-tests--root)
                                 :updated "2026-10-13T00:00:00Z" :revision 1))
           :root etaf-video-studio-tests--root))
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :revision 1 :duration 5
      :plan (list :version 1 :clips (list (etaf-video-studio-tests--clip)) :captions nil)))
    (should-not (etaf-video-studio-tests--deferred-faces (current-buffer)))
    (etaf-video-studio-refresh)
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer)) 1600 60)
    (dolist (theme '(dark light))
      (unless (eq theme etaf-video-studio-theme-mode)
        (execute-kbd-macro (kbd "T")))
      (dolist (pane '(projects clips preview properties captions record publish tasks))
        (etaf-video-studio-select-pane pane)
        (etaf-video-studio-tests--settle (current-buffer))
        (let ((tokens (etaf-video-studio-tests--deferred-faces (current-buffer))))
          (should (equal (list theme pane nil) (list theme pane tokens)))))
      (execute-kbd-macro (kbd "m"))
      (let ((tokens (etaf-video-studio-tests--deferred-faces (current-buffer))))
        (should (equal (list theme 'audio nil) (list theme 'audio tokens)))))))

(ert-deftest etaf-video-studio-tests-canvas-and-help-follow-the-application ()
  "The canvas surface follows the theme and help labels every studio key."
  (etaf-video-studio-tests--with-app ()
    (let ((surface (lambda ()
                     (plist-get (car (last (alist-get 'default face-remapping-alist)))
                                :background))))
      (should (equal (funcall surface) "#0b0e14"))
      (execute-kbd-macro (kbd "T"))
      (should (equal (funcall surface) "#eef2f7")))
    (let* ((data (etaf-help-data (etaf-runtime-for-buffer (current-buffer))))
           (entries (apply #'append (mapcar (lambda (group) (plist-get group :entries))
                                            (plist-get data :groups))))
           (labels (mapcar (lambda (key)
                             (plist-get (cl-find key entries
                                                 :key (lambda (entry) (plist-get entry :key))
                                                 :test #'equal)
                                        :label))
                           '("SPC" "f" "b" "m" "q"))))
      (should (equal labels '("播放／暂停" "快进 5 秒" "后退 5 秒"
                              "开启／关闭预览声音" "关闭工作台"))))
    (with-temp-buffer
      (should-error (etaf-video-studio-close) :type 'user-error))))

(ert-deftest etaf-video-studio-tests-layout-switches-and-keeps-drafts ()
  "Refitting switches the layout without losing a form draft."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :version 1 :clips (list (etaf-video-studio-tests--clip))
                  :captions nil)))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'properties)
    (etaf-video-studio-select-clip 0)
    (etaf-video-studio-tests--replace-input 'video-studio-trim-in "3.5")
    ;; A narrow mount shows the pane tabs and no sidebar.
    (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer)) 80 40)
    (etaf-video-studio-tests--settle (current-buffer))
    (should (string-match-p "任务" (etaf-video-studio-tests--body (current-buffer))))
    ;; A wide viewport adds the sidebar and the details column.
    (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer)) 1600 40)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((body (etaf-video-studio-tests--body (current-buffer))))
      (should (string-match-p "片段剪辑" body))
      (should (string-match-p "项目" body)))
    ;; The draft typed before the resize is still applied by the next edit.
    (let ((operation (etaf-video-studio-tests--edit-operation
                      #'etaf-video-studio-apply-trim)))
      (should (= 3.5 (plist-get operation :in))))))

;;; Errors and state

(ert-deftest etaf-video-studio-tests-invalid-input-signals-user-error ()
  "Bad forms and impossible requests signal `user-error' before the CLI."
  (etaf-video-studio-tests--with-app ()
    (should-error (etaf-video-studio-create-project "   ") :type 'user-error)
    (should-error (etaf-video-studio-apply-trim) :type 'user-error)
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :version 1 :clips (list (etaf-video-studio-tests--clip))
                  :captions nil)))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'properties)
    (etaf-video-studio-select-clip 0)
    (etaf-video-studio-tests--replace-input 'video-studio-trim-in "abc")
    (should-error (etaf-video-studio-apply-trim) :type 'user-error)
    (let ((before (length (etaf-video-studio-tests--calls-for "edit"))))
      (should-error (etaf-video-studio-apply-trim) :type 'user-error)
      (should (= before (length (etaf-video-studio-tests--calls-for "edit")))))
    (should-error (etaf-video-studio-record-start) :type 'user-error)))

(ert-deftest etaf-video-studio-tests-cli-errors-surface-in-status ()
  "A CLI error object becomes a readable status message, not a signal."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "list.json"
     (list :ok nil :error "conflict" :message "项目正在被其他入口修改"
           :hint "稍后重试"))
    (etaf-video-studio-refresh)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((message (plist-get (etaf-video-studio-state) :message)))
      (should (string-match-p "conflict" message))
      (should (string-match-p "项目正在被其他入口修改" message)))))

(ert-deftest etaf-video-studio-tests-missing-executable-reports-deps ()
  "A missing CLI reports `deps' in the status line and still closes."
  (let* ((etaf-video-studio-executable
          (expand-file-name "does-not-exist-pi-skill"
                            temporary-file-directory))
         (buffer (etaf-video-studio-open)))
    (unwind-protect
        (with-current-buffer buffer
          (etaf-video-studio-tests--settle buffer)
          (should (string-match-p "deps" (or (plist-get (etaf-video-studio-state) :message) "")))
          (etaf-video-studio-close)
          (should-not (get-buffer "*Video Studio*")))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (ignore-errors (etaf-video-studio-close)))))))

(ert-deftest etaf-video-studio-tests-state-is-detached-and-theme-toggles ()
  "The reported state is plain data and the theme toggles both ways."
  (etaf-video-studio-tests--with-app ()
    (let ((first (etaf-video-studio-state)))
      (should (listp first))
      ;; Mutating the returned value must not change the next report.
      (plist-put first :pane 'tasks)
      (should-not (eq 'tasks (plist-get (etaf-video-studio-state) :pane))))
    (should (eq etaf-video-studio-theme-mode 'dark))
    (etaf-video-studio-toggle-theme)
    (should (eq etaf-video-studio-theme-mode 'light))
    (etaf-video-studio-toggle-theme)
    (should (eq etaf-video-studio-theme-mode 'dark))))

(ert-deftest etaf-video-studio-tests-stage-selected-clip-reports-missing-file ()
  "Selecting a clip whose source is gone reports it and mounts no video."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :version 1 :clips (list (etaf-video-studio-tests--clip))
                  :captions nil)))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-clip 0)
    (etaf-video-studio-tests--settle (current-buffer))
    (should-not (plist-get (etaf-video-studio-state) :stage))
    (should (string-match-p "素材文件不存在"
                            (or (plist-get (etaf-video-studio-state) :message) "")))))

(ert-deftest etaf-video-studio-tests-paged-clips-remain-reachable ()
  "Every clip remains reachable and selection reveals its stable page."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :version 1 :clips
                  (cl-loop for n from 0 below 13
                           collect (etaf-video-studio-tests--clip
                                    :id (format "clip-%d" n)
                                    :file (format "/missing/part-%02d.mp4" n))))))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'clips)
    (etaf-video-studio-page-list 'clips 1)
    (let ((body (etaf-video-studio-tests--body (current-buffer))))
      (should (string-match-p "part-05.mp4" body))
      (should-not (string-match-p "part-00.mp4" body)))
    (let ((focused (etaf-focus (etaf-runtime-for-buffer (current-buffer)) 'video-studio-clip-5)))
      (should focused))
    (execute-kbd-macro (kbd "RET"))
    (should (= 5 (plist-get (etaf-video-studio-state) :clip-index)))
    (etaf-video-studio-select-clip 12)
    (let ((pages (plist-get (etaf-video-studio-state) :pages)))
      (should (= 2 (alist-get 'clips pages))))
    (etaf-video-studio-page-list 'clips -100)
    (let ((state (etaf-video-studio-state)))
      (should (= 0 (alist-get 'clips (plist-get state :pages))))
      (should (= 12 (plist-get state :clip-index))))))

(ert-deftest etaf-video-studio-tests-empty-project-actions-are-safe ()
  "Missing projects and empty exports report recovery instead of bad CLI args."
  (etaf-video-studio-tests--with-app ()
    (should-error (etaf-video-studio-import-files '("/missing.mp4")) :type 'user-error)
    (should-error (etaf-video-studio-render-screen) :type 'user-error)
    (should-error (etaf-video-studio-show-export) :type 'user-error)
    (should-error (etaf-video-studio-seek-to 1) :type 'user-error)
    (should-error (etaf-video-studio-page-list 'unknown 1) :type 'user-error)
    (should-error (etaf-video-studio-select-pane 'unknown) :type 'user-error)
    (etaf-video-studio-tests--write "status.json" (etaf-video-studio-tests--project))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (should-error (etaf-video-studio-render-preview) :type 'user-error)))

(ert-deftest etaf-video-studio-tests-publish-changes-require-another-preview ()
  "Changing a recipient, caption or topic never sends an unreviewed request."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write "status.json" (etaf-video-studio-tests--project))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-select-pane 'publish)
    (etaf-video-studio-tests--type-input 'video-studio-publish-chat "12345")
    (etaf-video-studio-tests--type-input 'video-studio-publish-text "原文案")
    (etaf-video-studio-tests--type-input 'video-studio-publish-topic "1")
    (dolist (field '((video-studio-publish-chat . "67890")
                     (video-studio-publish-text . "新的文案")
                     (video-studio-publish-topic . "42")))
      (etaf-video-studio-publish-preview)
      (etaf-video-studio-tests--settle (current-buffer))
      (etaf-video-studio-tests--replace-input (car field) (cdr field))
      (should-error (etaf-video-studio-publish-confirm) :type 'user-error))
    (let ((confirmed (cl-remove-if-not
                      (lambda (call) (member "--yes" call))
                      (etaf-video-studio-tests--calls-for "publish"))))
      (should-not confirmed))))

(ert-deftest etaf-video-studio-tests-edit-refreshes-form-from-result ()
  "After a trim the form reflects the accepted clip rather than stale drafts."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json" (etaf-video-studio-tests--project
                    :plan (list :clips (list (etaf-video-studio-tests--clip)))))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-video-studio-tests--write
     "edit.json" (etaf-video-studio-tests--project
                  :revision 1 :plan (list :clips (list (etaf-video-studio-tests--clip :in 2)))))
    (etaf-video-studio-apply-trim)
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((operation (etaf-video-studio-tests--edit-operation #'etaf-video-studio-apply-trim)))
      (should (= 2 (plist-get operation :in))))))

(ert-deftest etaf-video-studio-tests-wide-tool-switch-keeps-controls-live ()
  "Switching from clip editing to captions enables the selected cue's controls."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write
     "status.json"
     (etaf-video-studio-tests--project
      :plan (list :clips (list (etaf-video-studio-tests--clip))
                  :captions (list (list :id "cue-1" :start 0 :end 2 :text "字幕")))))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer)) 1600 50)
    (etaf-video-studio-select-pane 'captions)
    (etaf-video-studio-select-caption 0)
    (let ((focused (etaf-focus (etaf-runtime-for-buffer (current-buffer))
                               'video-studio-caption-delete)))
      (should focused))
    (execute-kbd-macro (kbd "RET"))
    (etaf-video-studio-tests--settle (current-buffer))
    (let ((operation (etaf-video-studio-tests--operation
                      (car (last (etaf-video-studio-tests--calls-for "edit"))))))
      (should (equal "cue-1" (plist-get operation :id)))
      (should (plist-get operation :remove)))))

(ert-deftest etaf-video-studio-tests-empty-workspace-has-one-material-prompt ()
  "An empty wide project has one material prompt, not two competing empty panes."
  (etaf-video-studio-tests--with-app ()
    (etaf-video-studio-tests--write "status.json" (etaf-video-studio-tests--project))
    (etaf-video-studio-open-project "video-1")
    (etaf-video-studio-tests--settle (current-buffer))
    (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer)) 1600 50)
    (let ((body (etaf-video-studio-tests--body (current-buffer))))
      (should (string-match-p "添加你的第一段素材" body))
      (should-not (string-match-p "片段 (0)" body)))))

(ert-deftest etaf-video-studio-tests-fractional-times-stay-with-their-labels ()
  "Minute, hour and day-scale times stay on the same visible row as their labels."
  (etaf-video-studio-tests--with-app ()
    (dolist (duration '(60.183 3600.123 86400.123))
      (etaf-video-studio-tests--write
       "status.json"
       (etaf-video-studio-tests--project
        :plan (list :clips (list (etaf-video-studio-tests--clip :out duration)))))
      (etaf-video-studio-open-project "video-1")
      (etaf-video-studio-tests--settle (current-buffer))
      (dolist (size '((1600 . 50) (800 . 28)))
        (etaf-runtime-refit (etaf-runtime-for-buffer (current-buffer)) (car size) (cdr size))
        (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
          ;; Short viewports scroll the body rather than compressing fields.
          ;; Each focused control must reveal its complete label and value.
          (dolist (field `((video-studio-trim-out "出点" ,(format "%.3f" duration))
                           (video-studio-split-at "位置" ,(format "%.3f" (/ duration 2.0)))
                           (video-studio-gain "音量" "100%")))
            (etaf-focus runtime (car field))
            (let ((body (etaf-video-studio-tests--body (current-buffer))))
              (should (string-match-p
                       (concat (cadr field) "[^\n]*" (regexp-quote (caddr field))) body))
              (should (string-match-p "片段剪辑" body))
              (should (string-match-p "删除片段" body))))
          (etaf-focus runtime 'video-studio-trim-apply)
          (should (string-match-p "应用裁切"
                                  (etaf-video-studio-tests--body (current-buffer)))))))))

(provide 'etaf-video-studio-tests)
;;; etaf-video-studio-tests.el ends here
