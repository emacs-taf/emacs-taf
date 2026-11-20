;;; -*- lexical-binding: t; -*-
;;; etaf-video-studio-gui-scenarios.el --- Real workbench acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Load through the owning package with ETAF's emacs-gui-verifier available.
;; `etaf-video-studio-gui-run' drives rendered controls against real generated
;; media in a temporary library.  It records only the explicitly supplied
;; verification window, silently, and explicitly stops it after capture starts;
;; no personal windows or microphone are captured. A 30-second cap is a fallback.  Publication stops at its preview, without sending.
;; Call from a timer in a dedicated GUI instance and close that instance after
;; reading result.json.  Evidence stays outside the repository.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'etaf-video-studio)
(require 'emacs-gui-verifier)

(defvar etaf-video-studio-gui--root nil "Temporary media library.")
(defvar etaf-video-studio-gui--window nil "Explicit verification window ID.")

(defun etaf-video-studio-gui--state ()
  "Return the displayed application's public state."
  (with-current-buffer "*Video Studio*" (etaf-video-studio-state)))

(defun etaf-video-studio-gui--wait-idle ()
  "Wait at most ten seconds for short CLI queries to settle."
  (let ((end (+ (float-time) 10)))
    (while (and (< (float-time) end)
                (> (plist-get (etaf-video-studio-gui--state) :pending) 0))
      (sit-for 0.05))
    (when (> (plist-get (etaf-video-studio-gui--state) :pending) 0)
      (error "Studio CLI did not settle"))))

(defun etaf-video-studio-gui--key (key)
  "Deliver KEY through the real application command loop."
  (with-current-buffer "*Video Studio*" (execute-kbd-macro (kbd key))))

(defun etaf-video-studio-gui--press (ref)
  "Activate REF through native focus and RET, not model manipulation."
  (etaf-video-studio-gui--wait-idle)
  (let ((runtime (etaf-runtime-for-buffer "*Video Studio*")))
    (unless (etaf-focus runtime ref) (error "Cannot focus %s" ref))
    (execute-kbd-macro (kbd "RET"))))

(defun etaf-video-studio-gui--type (ref text &optional replace)
  "Type TEXT into REF; REPLACE clears its existing nonempty value."
  (let ((runtime (etaf-runtime-for-buffer "*Video Studio*")))
    (unless (etaf-text-input-begin runtime ref) (error "Cannot edit %s" ref))
    (when replace
      (execute-kbd-macro (kbd "C-a"))
      (execute-kbd-macro (kbd "C-k")))
    (execute-kbd-macro (vconcat text))
    (execute-kbd-macro (kbd "<escape>"))))

(defun etaf-video-studio-gui--choose (ref label)
  "Open dropdown REF and activate its visible LABEL through native focus."
  (etaf-video-studio-gui--press ref)
  (let ((runtime (etaf-runtime-for-buffer "*Video Studio*"))
        (remaining 20) found)
    (while (and (> remaining 0) (not found))
      (etaf-focus-next runtime)
      (setq remaining (1- remaining)
            found (string-match-p
                   (concat "\\(?:^\\|[[:space:]]\\)" (regexp-quote label)
                           "\\(?:$\\|[[:space:]]\\)")
                   (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))
    (unless found (error "Dropdown option not reachable: %s" label))
    (execute-kbd-macro (kbd "RET"))))

(defun etaf-video-studio-gui--resize (columns rows)
  "Resize only the verification frame to COLUMNS by ROWS."
  (let* ((buffer (get-buffer "*Video Studio*"))
         (frame (window-frame (get-buffer-window buffer t))))
    (set-frame-parameter frame 'fullscreen nil)
    (set-frame-size frame columns rows)
    (let ((end (+ (float-time) 5)))
      (while (and (< (float-time) end)
                  (let ((window (get-buffer-window buffer t)))
                    (or (/= (frame-width frame) columns)
                        (/= (cdr (etaf-runtime-viewport (etaf-runtime-for-buffer buffer)))
                            (window-body-height window)))))
        (sit-for 0.05)
        (redisplay t)))))

(defun etaf-video-studio-gui--footer-visible-p ()
  "Return non-nil when the footer remains inside the verification window."
  (with-current-buffer "*Video Studio*"
    (pos-visible-in-window-p (1- (point-max)) (get-buffer-window (current-buffer) t))))

(defun etaf-video-studio-gui--cli (&rest args)
  "Read the real skill's public JSON response for ARGS."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "pi-skill" nil t nil (append args '("--json"))))
      (error "CLI failed: %s" (buffer-substring-no-properties (point-min) (point-max))))
    (goto-char (point-min))
    (json-parse-buffer :object-type 'plist :array-type 'list)))

(defun etaf-video-studio-gui--project ()
  "Read the current project's public source of truth."
  (etaf-video-studio-gui--cli
   "video-project" "status"
   (plist-get (plist-get (etaf-video-studio-gui--state) :project) :directory)))

(defun etaf-video-studio-gui--prepare ()
  "Generate a real ten-second audiovisual source, without creating a project."
  (setq etaf-video-studio-gui--root (make-temp-file "studio-gui-" t))
  (let ((ffmpeg (or (and (file-executable-p "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
                         "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
                    (executable-find "ffmpeg"))))
    (with-temp-buffer
      (unless (zerop (call-process
                     ffmpeg nil t nil "-hide_banner" "-loglevel" "error" "-y"
                     "-f" "lavfi" "-i" "testsrc=size=640x360:rate=30:duration=10"
                     "-f" "lavfi" "-i" "sine=frequency=440:duration=10"
                     "-c:v" "libx264" "-preset" "veryfast" "-pix_fmt" "yuv420p"
                     "-c:a" "aac" "-shortest"
                     (expand-file-name "教程素材.mp4" etaf-video-studio-gui--root)))
        (error "FFmpeg: %s" (buffer-substring-no-properties (point-min) (point-max)))))))

(defun etaf-video-studio-gui-run (directory &optional recording-window)
  "Verify the complete local workflow into DIRECTORY.
RECORDING-WINDOW, when non-nil, must be the owned verification window's ID;
only that window is recorded.  Nil verifies target discovery without capture."
  (let (actions)
    (cl-labels
        ((state (key) (plist-get (etaf-video-studio-gui--state) key))
         (idle () (= 0 (state :pending)))
         (step (name execute predicate &optional screenshot timeout)
           (push (etaf-gui-verifier-action-create
                  :id name :execute (lambda (_context) (funcall execute))
                  :settled-p (lambda (_context) (and (idle) (funcall predicate)))
                  :settle-timeout (or timeout 15)
                  :assertions (lambda (_context)
                                (list (etaf-gui-verifier-assert name (funcall predicate))))
                  :screenshot screenshot) actions))
         (press (name ref predicate &optional screenshot timeout)
           (step name (lambda () (etaf-video-studio-gui--press ref)) predicate screenshot timeout))
         (pane (key)
           (press (format "pane-%s" key) (intern (format "video-studio-tab-%s" key))
                  (lambda () (eq key (state :pane)))))
         (task-done (kind profile)
           (cl-find-if (lambda (task)
                         (and (equal kind (plist-get task :kind))
                              (equal profile (plist-get task :profile))
                              (equal "completed" (plist-get task :status)))) (state :tasks))))
      (step "welcome" #'ignore (lambda () (= 0 (state :projects))) t)
      (step "project-title"
            (lambda () (etaf-video-studio-gui--type 'video-studio-new-title "制作一个教程")) #'idle)
      (press "create-project" 'video-studio-create (lambda () (state :project)) t)
      (step "import-source"
            (lambda ()
              ;; Script only the external file chooser's answer; the button
              ;; and application command still run through native focus/RET.
              (cl-letf (((symbol-function 'read-file-name)
                         (lambda (&rest _args)
                           (expand-file-name "教程素材.mp4" etaf-video-studio-gui--root))))
                (etaf-video-studio-gui--press 'video-studio-toolbar-import)))
            (lambda () (and (= 1 (state :clips)) (state :stage))) t)
      (step "seek-paused" (lambda () (etaf-video-studio-seek-to 3))
            (lambda () (and (< (abs (- 3 (plist-get (state :stage) :position))) 0.2)
                            (not (state :stage-playing)))))
      (step "seek-bar-keyboard"
            (lambda ()
              (unless (etaf-focus (etaf-runtime-for-buffer "*Video Studio*") 'video-studio-seek)
                (error "Seek bar not focusable"))
              (execute-kbd-macro (kbd "<right>")))
            (lambda () (< (abs (- 4 (plist-get (state :stage) :position))) 0.2)))
      (press "play" 'video-studio-stage-play (lambda () (state :stage-playing)))
      (press "pause" 'video-studio-stage-play (lambda () (not (state :stage-playing))))
      (press "seek-forward" 'video-studio-forward
             (lambda () (> (plist-get (state :stage) :position) 7)))
      (press "seek-backward" 'video-studio-back
             (lambda () (< (plist-get (state :stage) :position) 5)))
      (pane 'properties)
      (step "trim-fields"
            (lambda ()
              (etaf-video-studio-gui--type 'video-studio-trim-in "1" t)
              (etaf-video-studio-gui--type 'video-studio-trim-out "9" t)) #'idle)
      (press "trim" 'video-studio-trim-apply
             (lambda () (= 2 (plist-get (state :project) :revision))))
      (step "trim-source-clock" #'ignore
            (lambda () (< (abs (- 1 (plist-get (state :stage) :position))) 0.2)))
      (press "split" 'video-studio-split-apply (lambda () (= 2 (state :clips))) t)
      (press "move-down" 'video-studio-move-down
             (lambda () (= 1 (state :clip-index))))
      (press "move-up" 'video-studio-move-up
             (lambda () (= 0 (state :clip-index))))
      (press "remove" 'video-studio-remove-clip (lambda () (= 1 (state :clips))))
      (press "undo" 'video-studio-toolbar-undo (lambda () (= 2 (state :clips))))
      (press "redo" 'video-studio-toolbar-redo (lambda () (= 1 (state :clips))))
      (press "undo-again" 'video-studio-toolbar-undo (lambda () (= 2 (state :clips))))
      ;; Choosing a playback value applies it immediately; there is no
      ;; separate apply button, so this step also proves the undo path.
      (step "speed-select" (lambda () (etaf-video-studio-gui--choose 'video-studio-speed "2.0×"))
            (lambda () (= 2 (plist-get (car (plist-get (plist-get (etaf-video-studio-gui--project) :plan) :clips)) :speed))))
      ;; Undo returns the clip to its unedited state, where the CLI may omit
      ;; the field entirely; assert the edit is gone rather than a literal.
      (press "speed-undo" 'video-studio-toolbar-undo
             (lambda () (not (equal 2 (plist-get (car (plist-get (plist-get (etaf-video-studio-gui--project) :plan) :clips)) :speed)))))
      (step "gain-select" (lambda () (etaf-video-studio-gui--choose 'video-studio-gain "70%"))
            (lambda () (= 0.7 (plist-get (car (plist-get (plist-get (etaf-video-studio-gui--project) :plan) :clips)) :gain))))
      (press "gain-undo" 'video-studio-toolbar-undo
             (lambda () (not (equal 0.7 (plist-get (car (plist-get (plist-get (etaf-video-studio-gui--project) :plan) :clips)) :gain)))))
      (pane 'captions)
      (step "caption-fields"
            (lambda ()
              (etaf-video-studio-gui--type 'video-studio-caption-start "0")
              (etaf-video-studio-gui--type 'video-studio-caption-end "2")
              (etaf-video-studio-gui--type 'video-studio-caption-text "先导入素材，再剪辑视频")) #'idle)
      (press "caption-add" 'video-studio-caption-add (lambda () (= 1 (state :captions))) t)
      (press "caption-select" 'video-studio-caption-0 #'idle)
      (step "caption-text-update"
            (lambda () (etaf-video-studio-gui--type 'video-studio-caption-text "剪辑完成后，预览并导出" t)) #'idle)
      (press "caption-update" 'video-studio-caption-add
             (lambda () (equal "剪辑完成后，预览并导出"
                               (plist-get (car (plist-get (plist-get (etaf-video-studio-gui--project) :plan) :captions)) :text))))
      (press "caption-delete" 'video-studio-caption-delete (lambda () (= 0 (state :captions))))
      (press "caption-undo" 'video-studio-toolbar-undo (lambda () (= 1 (state :captions))))
      (pane 'record)
      (step "record-targets" #'ignore (lambda () (> (state :record-targets) 0)) t)
      (when recording-window
        (step "record-settings"
              (lambda ()
                (let* ((inventory (etaf-video-studio-gui--cli "video-project" "record" "targets"))
                       (index (cl-position recording-window (plist-get inventory :windows)
                                           :test #'equal :key (lambda (item) (plist-get item :id)))))
                  (unless index (error "Owned recording window disappeared"))
                  (etaf-video-studio-select-target index)
                  (etaf-video-studio-gui--type 'video-studio-record-duration "30" t))) #'idle)
        (press "record-owned-window" 'video-studio-record-toggle
               (lambda () (equal (plist-get (state :record) :status) "recording")) nil 30)
        (press "stop-owned-recording" 'video-studio-record-toggle
               (lambda () (or (equal (plist-get (state :record) :status) "stopping")
                              (task-done "record" nil))))
        (step "record-imports-clip" #'ignore (lambda () (and (task-done "record" nil)
                                                           (= 3 (state :clips)))) t 90))
      (press "render-preview" 'video-studio-render-preview
             (lambda () (and (state :preview) (eq 'preview (plist-get (state :stage) :kind)))) t 240)
      (press "play-cut" 'video-studio-stage-play (lambda () (state :stage-playing)))
      (press "pause-cut" 'video-studio-stage-play (lambda () (not (state :stage-playing))))
      (press "export" 'video-studio-toolbar-export (lambda () (task-done "render" "screen")) t 300)
      (pane 'publish)
      (step "publish-recipient"
            (lambda () (etaf-video-studio-gui--type 'video-studio-publish-chat "12345")) #'idle)
      (press "publish-preview-only" 'video-studio-publish-preview
             (lambda () (state :publish-preview)) t)
      (press "discard-publish" 'video-studio-publish-reset
             (lambda () (not (state :publish-preview))))
      (dolist (size '((170 54 "wide") (110 42 "ordinary") (80 32 "compact") (110 30 "short")))
        (let ((columns (nth 0 size)) (rows (nth 1 size)) (name (nth 2 size)))
          (pane 'properties)
          (step (concat "layout-" name)
                (lambda () (etaf-video-studio-gui--resize columns rows))
                #'etaf-video-studio-gui--footer-visible-p t)
          (press (concat "light-" name) 'video-studio-theme
                 (lambda () (eq etaf-video-studio-theme-mode 'light)) t)
          (press (concat "dark-" name) 'video-studio-theme
                 (lambda () (eq etaf-video-studio-theme-mode 'dark)))))
      (pane 'projects)
      (step "project-library" #'ignore (lambda () (= 1 (state :projects))) t)
      (etaf-gui-verifier-run
       (etaf-gui-verifier-scenario-create
        :name "video-studio-workflow"
        :claim "Real media, native controls, owned-window recording, local export and responsive tools"
        :initialize
        (lambda (context)
          (when (get-buffer "*Video Studio*")
            (with-current-buffer "*Video Studio*" (etaf-video-studio-close)))
          (etaf-video-studio-gui--prepare)
          (setq etaf-video-studio-gui--window recording-window)
          (let ((buffer (etaf-video-studio-open nil etaf-video-studio-gui--root)))
            (etaf-video-studio-gui--resize 170 54)
            (setf (etaf-gui-verifier-context-target-buffer context) buffer)))
        :actions (nreverse actions)
        :invariants
        (lambda (_context)
          (append (etaf-gui-verifier-line-height-assertions (get-buffer "*Video Studio*"))
                  (list (etaf-gui-verifier-assert "footer visible"
                                                  (etaf-video-studio-gui--footer-visible-p)))))
        :completion (lambda (_context)
                      (etaf-video-studio-gui--key "q")
                      (not (get-buffer "*Video Studio*"))))
       directory))))

(provide 'etaf-video-studio-gui-scenarios)
;;; etaf-video-studio-gui-scenarios.el ends here
