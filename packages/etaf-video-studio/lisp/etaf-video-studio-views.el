;;; etaf-video-studio-views.el --- Views of etaf-video-studio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Views are pure projections of the model snapshot and the draft refs; no
;; storage, network, process or controller call belongs here, because ETAF
;; rejects a render with side effects.  The shell is a flow layout: a fixed
;; header, persistent tools/tabs, an aspect-preserving preview and ordered
;; clip sequence beside the editor (one pane in short/compact windows), and a fixed
;; footer.  Every control a person can press carries a stable `:ref', so a
;; GUI pass can focus and activate it without synthesising clicks.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-video-studio-theme)
(require 'etaf-video-studio-model)

(declare-function etaf-video-studio-import-files "etaf-video-studio-app" (files))
(declare-function etaf-video-studio-create-project "etaf-video-studio-app" (title))
(declare-function etaf-video-studio-refresh "etaf-video-studio-app" ())
(declare-function etaf-video-studio-open-project "etaf-video-studio-app" (project))
(declare-function etaf-video-studio-select-pane "etaf-video-studio-app" (pane))
(declare-function etaf-video-studio-select-clip "etaf-video-studio-app" (index))
(declare-function etaf-video-studio-select-caption "etaf-video-studio-app" (index))
(declare-function etaf-video-studio-select-target "etaf-video-studio-app" (index))
(declare-function etaf-video-studio-select-task "etaf-video-studio-app" (index))
(declare-function etaf-video-studio-apply-trim "etaf-video-studio-app" ())
(declare-function etaf-video-studio-apply-split "etaf-video-studio-app" ())
(declare-function etaf-video-studio-apply-speed "etaf-video-studio-app" ())
(declare-function etaf-video-studio-apply-gain "etaf-video-studio-app" ())
(declare-function etaf-video-studio--draft-mark "etaf-video-studio-app" (app edge))
(declare-function etaf-video-studio--select-playback "etaf-video-studio-app" (app kind value))
(declare-function etaf-video-studio-move-clip-up "etaf-video-studio-app" ())
(declare-function etaf-video-studio-move-clip-down "etaf-video-studio-app" ())
(declare-function etaf-video-studio-remove-selected-clip "etaf-video-studio-app" ())
(declare-function etaf-video-studio-undo "etaf-video-studio-app" ())
(declare-function etaf-video-studio-redo "etaf-video-studio-app" ())
(declare-function etaf-video-studio-render-preview "etaf-video-studio-app" ())
(declare-function etaf-video-studio-render-screen "etaf-video-studio-app" ())
(declare-function etaf-video-studio-cancel-render "etaf-video-studio-app" ())
(declare-function etaf-video-studio-refresh-targets "etaf-video-studio-app" ())
(declare-function etaf-video-studio-show-captions "etaf-video-studio-app" ())
(declare-function etaf-video-studio-show-publish "etaf-video-studio-app" ())
(declare-function etaf-video-studio-show-record "etaf-video-studio-app" ())
(declare-function etaf-video-studio-show-tasks "etaf-video-studio-app" ())
(declare-function etaf-video-studio-seek-forward "etaf-video-studio-app" ())
(declare-function etaf-video-studio-seek-backward "etaf-video-studio-app" ())
(declare-function etaf-video-studio-toggle-record "etaf-video-studio-app" ())
(declare-function etaf-video-studio-publish-preview "etaf-video-studio-app" ())
(declare-function etaf-video-studio-publish-confirm "etaf-video-studio-app" ())
(declare-function etaf-video-studio-publish-reset "etaf-video-studio-app" ())
(declare-function etaf-video-studio-add-caption "etaf-video-studio-app" ())
(declare-function etaf-video-studio-delete-caption "etaf-video-studio-app" ())
(declare-function etaf-video-studio-clear-caption-form "etaf-video-studio-app" ())
(declare-function etaf-video-studio-stage-selected-clip "etaf-video-studio-app" ())
(declare-function etaf-video-studio-stage-preview-output "etaf-video-studio-app" ())
(declare-function etaf-video-studio-toggle-playback "etaf-video-studio-app" ())
(declare-function etaf-video-studio-toggle-stage-audio "etaf-video-studio-app" ())
(declare-function etaf-video-studio-mark-in "etaf-video-studio-app" ())
(declare-function etaf-video-studio-mark-out "etaf-video-studio-app" ())
(declare-function etaf-video-studio-split-at-stage "etaf-video-studio-app" ())
(declare-function etaf-video-studio-toggle-theme "etaf-video-studio-app" ())
(declare-function etaf-video-studio-close "etaf-video-studio-app" ())
(declare-function etaf-video-studio-task-retry "etaf-video-studio-app" ())
(declare-function etaf-video-studio-page-list "etaf-video-studio-app" (kind delta))
(declare-function etaf-video-studio-show-export "etaf-video-studio-app" ())
(declare-function etaf-video-studio-seek-to "etaf-video-studio-app" (seconds))

(defconst etaf-video-studio--aside-min-pixels 1100
  "Published viewport width from which the details column is shown.")

(defconst etaf-video-studio--tab-keys
  '((projects . "项目")
    (clips . "片段")
    (preview . "预览")
    (properties . "剪辑")
    (captions . "字幕")
    (record . "录屏")
    (publish . "导出")
    (tasks . "任务"))
  "Tab labels by pane key.")

(defun etaf-video-studio--view-value (value)
  "Read a display VALUE or a reactive value inside its consuming Host."
  (if (or (etaf-ref-p value) (etaf-computed-p value)) (etaf-value value) value))

(defun etaf-video-studio--border (color)
  "Return a one-pixel solid border in raw or deferred COLOR."
  (if (etaf-theme-token-p color)
      (etaf-theme-token (nth 1 color) (nth 2 color) #'etaf-video-studio--border)
    (list '(px 1) 'solid color)))

(defun etaf-video-studio--clock (seconds)
  "Format SECONDS as a playback clock."
  (let* ((seconds (max 0 (round (or seconds 0))))
         (hours (/ seconds 3600))
         (minutes (/ (% seconds 3600) 60))
         (rest (% seconds 60)))
    (if (> hours 0)
        (format "%d:%02d:%02d" hours minutes rest)
      (format "%02d:%02d" minutes rest))))

(defun etaf-video-studio--seconds (value)
  "Format a plan VALUE of seconds without trailing zeros."
  (if (numberp value)
      (let ((text (format "%.3f" (float value))))
        (replace-regexp-in-string "\\.?0+\\'" "" text))
    "—"))

(defun etaf-video-studio--basename (path)
  "Return PATH's file name, or an em dash for nil."
  (if (and (stringp path) (not (string-empty-p path)))
      (file-name-nondirectory path)
    "—"))

(defun etaf-video-studio--status-variant (status)
  "Return the badge variant for a task STATUS string."
  (pcase status
    ("completed" 'success)
    ((or "failed" "unknown") 'danger)
    ((or "running" "recording" "sending" "queued" "stopping") 'warning)
    ((or "interrupted" "lost") 'warning)
    (_ 'neutral)))

(defun etaf-video-studio--task-status-label (status)
  "Return a readable status, preserving an unknown backend value."
  (or (cdr (assoc status '(("queued" . "排队中") ("running" . "处理中")
                           ("recording" . "录制中") ("stopping" . "正在保存")
                           ("sending" . "发送中") ("completed" . "已完成")
                           ("failed" . "失败") ("unknown" . "待核对")
                           ("interrupted" . "已中断") ("cancelled" . "已取消")
                           ("lost" . "已中断"))))
      status "未知"))

(defun etaf-video-studio--clip-duration (clip)
  "Return CLIP's contribution to the timeline, or nil when unknown."
  (let ((in (plist-get clip :in))
        (out (plist-get clip :out))
        (speed (or (plist-get clip :speed) 1)))
    (when (and (numberp in) (numberp out) (numberp speed) (> speed 0))
      (/ (- out in) (float speed)))))

(defun etaf-video-studio--stage-grid (aspect viewport-width viewport-rows)
  "Return the aspect-preserving canvas fitting WIDTH pixels and ROWS lines.
ASPECT is the source's (WIDTH . HEIGHT); VIEWPORT-WIDTH and VIEWPORT-ROWS
are the preview region's budget after allocating the editor and clip list."
  (let* ((metrics (ignore-errors (etaf-display-metrics)))
         (cell-width (max 1 (or (plist-get metrics :char-width)
                                (frame-char-width))))
         (cell-height (max 1 (or (plist-get metrics :line-height)
                                 (frame-char-height))))
         (reserved-ch 6)
         (reserved-rows 6)
         (center-ch (max 16 (- (floor viewport-width cell-width) reserved-ch)))
         (available-rows (max 3 (- viewport-rows reserved-rows)))
         (aspect (if (and (consp aspect) (numberp (car aspect)) (numberp (cdr aspect))
                          (> (car aspect) 0) (> (cdr aspect) 0))
                     aspect (cons 16 9)))
         (by-width (max 12 (1- center-ch)))
         (rows-for-width (max 3 (round (/ (* by-width cell-width (cdr aspect))
                                          (* cell-height (car aspect))))))
         (columns (if (> rows-for-width available-rows)
                      (max 12 (round (/ (* available-rows cell-height (car aspect))
                                       (* cell-width (cdr aspect)))))
                    by-width))
         (rows (min available-rows
                    (max 3 (round (/ (* columns cell-width (cdr aspect))
                                     (* cell-height (car aspect))))))))
    (cons columns rows)))

(defun etaf-video-studio--pane-tabs (_state _layout)
  "Return the same named navigation controls at every viewport size."
  (cl-loop for key in '(projects clips preview properties captions record publish tasks)
           collect (list :key key :ref (intern (format "video-studio-tab-%s" key))
                         :label (alist-get key etaf-video-studio--tab-keys))))

;;; Small shared components

(etaf-define-component etaf-video-studio--section-title
    (&key icon title action-label on-action disabled action-ref)
  "Render one section caption with an optional ghost action button."
  :view
  (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
        :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :background-color (etaf-video-studio-color :panel2)
        :border-bottom (etaf-video-studio--border (etaf-video-studio-color :line))
    ;; Icons take their colour from an enclosing box: `etaf-ui-icon' writes
    ;; its :color into the glyph face, which holds only concrete colours,
    ;; while the box lowers the deferred Theme token and follows a toggle.
    (box :height '(lh 1) :color (etaf-video-studio-color :muted)
      (etaf-ui-icon :name (or icon 'list) :set 'svg :size 0.9 :min-width 2))
    (box :height '(lh 1) :font-weight 'bold :color (etaf-video-studio-color :ink)
      (text (expr title)))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
    (etaf-button :if action-label :label action-label :variant 'ghost
                 :disabled disabled :ref action-ref :on-press on-action)))

(etaf-define-component etaf-video-studio--fact
    (&key label value value-color)
  "Render a label and a right-aligned value in one standard row."
  :view
  (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
        :gap '((lh 0) (ch 1))
    (box :width '(ch 8) :height '(lh 1) :overflow 'hidden
         :color (etaf-video-studio-color :muted)
      (text (expr label)))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
         :overflow 'hidden :text-align 'right
         :color (or value-color (etaf-video-studio-color :ink))
      (text (expr value)))))

(etaf-define-component etaf-video-studio--placeholder
    (&key title description action-label on-action)
  "Render an empty-state block inside a pane."
  :view
  (etaf-empty :title title :description description
              :action-label action-label :on-action on-action))

(etaf-define-component etaf-video-studio--pager (&key kind count page)
  "Keep every entry reachable without displacing the editor below its list."
  :render
  (let ((pages (max 1 (ceiling count etaf-video-studio--page-size))))
    (etaf-view
     (flex :flex-direction 'row :width 'stretch :height '(lh 1)
           :align-items 'center :gap '((lh 0) (ch 1))
       (box :flex-grow 1 :flex-basis '(ch 0) :color (etaf-video-studio-color :muted)
         (text (expr (format "%d 项 · %d / %d 页" count (1+ page) pages))))
       (etaf-button :label "上一页" :variant 'ghost :disabled (= page 0)
                    :ref (intern (format "video-studio-%s-prev" kind))
                    :on-press (lambda () (etaf-video-studio-page-list kind -1)))
       (etaf-button :label "下一页" :variant 'ghost :disabled (>= (1+ page) pages)
                    :ref (intern (format "video-studio-%s-next" kind))
                    :on-press (lambda () (etaf-video-studio-page-list kind 1)))))))

;;; Projects and the ordered clip sequence

(etaf-define-component etaf-video-studio--project-row
    (&key project selected on-press)
  "Render one project row with its revision badge."
  :view
  (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
        :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0
        :ref (intern (format "video-studio-project-%s" (plist-get project :id)))
        :background-color (etaf-video-studio-color (if selected :accent-soft :panel))
        :hover-style (unless selected
                       (list :background-color (etaf-video-studio-color :hover)))
        :on-press on-press
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
         :overflow 'hidden :font-weight (if selected 'bold 'normal)
         :color (etaf-video-studio-color (if selected :accent :ink))
      (text (expr (or (plist-get project :title) "未命名"))))
    (etaf-badge :text (format "r%s" (or (plist-get project :revision) 0))
                :variant 'neutral)))

(etaf-define-component etaf-video-studio--clip-row
    (&key clip index selected on-press)
  "Render one clip row: order, source name, trimmed length and rate."
  :view
  (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
        :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0
        :ref (intern (format "video-studio-clip-%d" index))
        :background-color (etaf-video-studio-color (if selected :accent-soft :panel))
        :hover-style (unless selected
                       (list :background-color (etaf-video-studio-color :hover)))
        :on-press on-press
    (box :width '(ch 3) :height '(lh 1) :text-align 'right
         :color (etaf-video-studio-color (if selected :accent :dim))
      (text (expr (number-to-string (1+ index)))))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
         :overflow 'hidden :font-weight (if selected 'bold 'normal)
         :color (etaf-video-studio-color (if selected :accent :ink))
      (text (expr (etaf-video-studio--basename (plist-get clip :file)))))
    (box :height '(lh 1) :color (etaf-video-studio-color :muted)
      (text (expr (etaf-video-studio--seconds
                   (etaf-video-studio--clip-duration clip)))))
    (etaf-badge :if (or (/= 1 (or (plist-get clip :speed) 1))
                        (/= 1 (or (plist-get clip :gain) 1)))
                :text (format "%sx%s" (etaf-video-studio--seconds (or (plist-get clip :speed) 1))
                              (let ((gain (or (plist-get clip :gain) 1)))
                                (if (= gain 1) "" (format " %s" (etaf-video-studio--seconds gain)))))
                :variant 'info)))

(etaf-define-component etaf-video-studio--projects
    (&key app state)
  "Render the project list, the create form and the open action."
  :render
  (let* ((projects (plist-get state :projects))
         (project (plist-get state :project))
         (current (plist-get project :id))
         (new-title (etaf-video-studio--app-new-title-ref app))
         (pending (> (or (plist-get state :pending) 0) 0)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :row-gap '(lh 0)
           :background-color (etaf-video-studio-color :bg)
       (etaf-video-studio--section-title
        :icon 'list :title (format "项目 (%d)" (length projects))
        :action-label "刷新" :action-ref 'video-studio-refresh
        :on-action (lambda () (etaf-video-studio-refresh)))
       (box :height '(lh 1))
       (flex :for (entry (etaf-video-studio--page-items app 'projects)) :key (plist-get entry :id)
             :flex-direction 'column :width 'stretch
         (etaf-video-studio--project-row
          :project entry :selected (equal current (plist-get entry :id))
          :on-press (lambda () (etaf-video-studio-open-project entry))))
       (etaf-video-studio--pager :if projects :kind 'projects :count (length projects)
                                 :page (etaf-video-studio--page app 'projects))
       (box :height '(lh 1))
       (box :height '(lh 1) :color (etaf-video-studio-color :muted)
         (text "给新项目起个名字"))
       (flex :flex-direction 'row :width 'stretch :align-items 'center
             :gap '((lh 0) (ch 2))
         (flex :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
           (etaf-text-input :bind new-title :width 'stretch :hide-label t :placeholder "例如：我的第一个教程"
                            :ref 'video-studio-new-title
                            :on-submit (lambda (text)
                                         (etaf-video-studio-create-project text))))
         (etaf-button :label "新建" :variant 'primary :disabled pending
                      :ref 'video-studio-create
                      :on-press (lambda ()
                                  (etaf-video-studio-create-project
                                   (etaf-value new-title)))))))))

(etaf-define-component etaf-video-studio--clips
    (&key app state)
  "Render the clip list with the import and selection actions."
  :render
  (let* ((clips (etaf-video-studio--app-clips app))
         (selected (plist-get state :clip-index))
         (project (plist-get state :project))
         (pending (> (or (plist-get state :pending) 0) 0)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch
           :background-color (etaf-video-studio-color :bg)
       (etaf-video-studio--section-title
        :icon 'video :title (format "片段 (%d)" (length clips))
        :action-label "导入" :action-ref 'video-studio-import
        :disabled (or pending (null project))
        :on-action (lambda () (call-interactively #'etaf-video-studio-import-files)))
       (etaf-video-studio--placeholder
        :if (null project)
        :title "未打开项目" :description "从上面的项目列表选择一个")
       (etaf-video-studio--placeholder
        :if (and project (null clips))
        :title "还没有素材" :description "录制或导入一段视频"
        :action-label "导入素材"
        :on-action (lambda () (call-interactively #'etaf-video-studio-import-files)))
       (etaf-video-studio--clip-row
        :for (clip (etaf-video-studio--page-items app 'clips)) :key (plist-get clip :id)
        :clip clip :index (cl-position clip clips :test #'equal)
        :selected (equal selected (cl-position clip clips :test #'equal))
        :on-press (lambda ()
                    (etaf-video-studio-select-clip
                     (cl-position clip clips :test #'equal))))
       (etaf-video-studio--pager :if clips :kind 'clips :count (length clips)
                                 :page (etaf-video-studio--page app 'clips))
       (box :height '(lh 1))
       (flex :flex-direction 'row :width 'stretch :justify-content 'end
             :gap '((lh 0) (ch 1))
         (etaf-button :label "撤销" :variant 'ghost :disabled (or pending (not (plist-get project :undo)))
                      :ref 'video-studio-undo
                      :on-press (lambda () (etaf-video-studio-undo)))
         (etaf-button :label "重做" :variant 'ghost :disabled (or pending (not (plist-get project :redo)))
                      :ref 'video-studio-redo
                      :on-press (lambda () (etaf-video-studio-redo))))))))

;;; Preview pane

(etaf-define-component etaf-video-studio--preview
    (&key app state width height)
  "Render the native video stage and its controls."
  :render
  (let* ((stage (plist-get state :stage))
         (preview (plist-get state :preview))
         (project (plist-get state :project))
         (viewport (ignore-errors (etaf-runtime-viewport)))
         (viewport-width (or (car-safe viewport) 800))
         (viewport-rows (or (cdr-safe viewport) 30))
         (stage-audio (etaf-video-studio--app-stage-audio-ref app))
         (grid (etaf-video-studio--stage-grid
                (plist-get stage :aspect) (or width viewport-width)
                (or height (- viewport-rows 11))))
         (columns (car grid))
         (rows (cdr grid))
         (playing (plist-get state :stage-playing)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :row-gap '(lh 1)
           :padding '((lh 0) (ch 1))
           :background-color (etaf-video-studio-color :bg)
       (etaf-video-studio--section-title
        :icon 'video :title "预览"
        :action-label (if (eq (plist-get stage :kind) 'preview) "查看素材"
                        (if preview "查看成片" "回到片段"))
        :action-ref 'video-studio-stage-source
        :on-action (lambda ()
                     (if (and preview (not (eq (plist-get stage :kind) 'preview)))
                         (etaf-video-studio-stage-preview-output)
                       (etaf-video-studio-stage-selected-clip))))
       (etaf-video-studio--placeholder
        :if (null stage)
        :title (if (etaf-video-studio--app-clips app) "选择片段开始剪辑" "添加你的第一段素材")
        :description "导入已有视频，或录制一个窗口。原文件保持不变。"
        :action-label "导入视频"
        :on-action (lambda () (call-interactively #'etaf-video-studio-import-files)))
       (etaf-button :if (null stage) :label "录制窗口或屏幕" :variant 'secondary
                    :ref 'video-studio-empty-record :on-press #'etaf-video-studio-show-record)
       (flex :if stage :flex-direction 'row :justify-content 'center
             :width 'stretch :height (list 'lh (max 1 rows))
             :overflow 'hidden :background-color (etaf-video-studio-color :stage)
         (etaf-video :key (plist-get stage :key)
                     :src (plist-get stage :file)
                     :mode 'image :columns columns :rows rows
                     :autoplay nil :audio stage-audio :volume 85
                     :position 'static :handle (plist-get stage :handle)
                     :on-press (lambda ()
                                 (etaf-video-studio-toggle-playback))))
       (box :if stage :height '(lh 1) :width 'stretch
         (etaf-range :value (etaf-video-studio--app-stage-time-ref app)
                     :min 0 :max (max 0.001 (or (plist-get stage :duration) 1))
                     :key-step 1 :label "定位视频" :ref 'video-studio-seek
                     :fill-ref 'video-studio-seek-fill
                     :on-commit #'etaf-video-studio-seek-to))
       (flex :if stage :flex-direction 'row :width 'stretch :align-items 'center
             :gap '((lh 0) (ch 1))
         (etaf-button :label "−5 秒" :variant 'ghost :ref 'video-studio-back
                      :on-press #'etaf-video-studio-seek-backward)
         (etaf-button :label (if playing "暂停" "播放") :variant 'secondary
                      :ref 'video-studio-stage-play
                      :on-press (lambda () (etaf-video-studio-toggle-playback)))
         (etaf-button :label "+5 秒" :variant 'ghost :ref 'video-studio-forward
                      :on-press #'etaf-video-studio-seek-forward)
         (box :height '(lh 1)
              :color (etaf-video-studio-color (if (etaf-value stage-audio) :accent :muted))
           (etaf-ui-icon :name (if (etaf-value stage-audio) 'volume 'volume-mute)
                         :set 'svg :size 0.9 :min-width 3
                         :ref 'video-studio-stage-audio
                         :help-echo "预览声音 (m)"
                         :on-press (lambda () (etaf-video-studio-toggle-stage-audio))))
         (etaf-badge :text (if (eq (plist-get stage :kind) 'preview) "成片" "素材")
                     :variant 'info)
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
         (box :height '(lh 1) :color (etaf-video-studio-color :muted)
           (text :ref 'video-studio-position :id "video-studio-position"
                 (expr (or (plist-get state :stage-position) "—"))))
       (box :if stage :height '(lh 1) :overflow 'hidden
            :color (etaf-video-studio-color
                    (if (etaf-video-studio--stage-stale-p state) :warning :dim))
         (text (expr (etaf-video-studio--stage-caption state))))
       (flex :if (null stage) :flex-direction 'column :width 'stretch
         (etaf-video-studio--section-title
          :icon 'settings :title "快捷动作"
          :action-label "生成成片预览" :action-ref 'video-studio-empty-preview
          :disabled (or (null project) (null (etaf-video-studio--app-clips app))
                        (> (or (plist-get state :pending) 0) 0))
          :on-action (lambda () (etaf-video-studio-render-preview)))
         (etaf-video-studio--fact :label "当前版本"
                                  :value (if project
                                             (format "r%s" (plist-get project :revision))
                                           "—"))
         (etaf-video-studio--fact :label "时间轴"
                                  :value (etaf-video-studio--clock
                                          (plist-get project :duration)))))))))

;;; Properties pane

(etaf-define-component etaf-video-studio--inspector-heading (&key title note)
  "Render an unboxed group caption inside the inspector."
  :view
  (flex :width 'stretch :height '(lh 2) :align-items 'center
    (text :font-weight 'bold (expr title))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
    (text :color (etaf-video-studio-color :muted) (expr (or note "")))))

(etaf-define-component etaf-video-studio--inspector-time
    (&key label value field-ref action-label action-ref on-action disabled)
  "Align one native time input with its caption and action."
  :view
  (flex :width 'stretch :align-items 'center :column-gap '(ch 1)
    (box :width '(ch 6) :color (etaf-video-studio-color :muted) (text (expr label)))
    (etaf-text-input :bind value :width '(ch 24) :hide-label t
                     :label (concat label "（秒）") :ref field-ref)
    (etaf-button :label action-label :ref action-ref :on-press on-action
                 :width '(ch 20) :text-align 'center :variant 'secondary
                 :disabled disabled)))

(etaf-define-component etaf-video-studio--properties (&key app state height)
  "Render the single-frame inspector with a fixed header and scrolling body."
  :render
  (let* ((clip (plist-get state :clip))
         (index (plist-get state :clip-index))
         (pending (> (or (plist-get state :pending) 0) 0))
         (count (length (etaf-video-studio--app-clips app)))
         (height (or height 40))
         (can-mark (and (not pending)
                        (eq (plist-get (plist-get state :stage) :kind) 'clip))))
    (etaf-view
     (etaf-panel :ref 'video-studio-inspector :width 'stretch
                  :height (list 'lh height) :padding '((lh 0) (ch 0))
                  :item-gap '(lh 0) :border-radius '(px 16) :overflow 'hidden
       (flex :height '(lh 3) :width 'stretch :align-items 'center :column-gap '(ch 2)
             :padding '((lh 1) (ch 3)) :background-color (etaf-video-studio-color :panel2)
             :border-bottom (etaf-video-studio--border (etaf-video-studio-color :line))
         (box :height '(lh 1) :color (etaf-video-studio-color :accent)
           (etaf-ui-icon :name 'play :set 'svg :size 1 :min-width 2))
         (text :font-weight 'bold "片段剪辑")
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
         (text :color (etaf-video-studio-color :muted)
           (expr (format "%02d / %02d" (if index (1+ index) 0) count))))
       (box :ref 'video-studio-inspector-body :height (list 'lh (max 1 (- height 6)))
            :width 'stretch :overflow 'scroll
         (column :padding '((lh 1) (ch 3)) :item-gap '(lh 0)
           (etaf-video-studio--placeholder :if (null clip)
                                          :title "未选择片段" :description "在片段列表中选择一个")
           (column :if clip :item-gap '(lh 0)
             (box :height '(lh 1) :overflow 'hidden :help-echo (plist-get clip :file)
                  :font-weight 'bold
               (text (expr (etaf-video-studio--basename (plist-get clip :file)))))
             (flex :width 'stretch :height '(lh 2) :align-items 'center
               (text :color (etaf-video-studio-color :muted)
                 (expr (format "时长 %s 秒" (etaf-video-studio--seconds
                                           (etaf-video-studio--clip-duration clip)))))
               (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
               (text :color (etaf-video-studio-color :muted) "原视频保持不变"))
             (box :height '(lh 1) :border-bottom (etaf-video-studio--border (etaf-video-studio-color :line)))
             (etaf-video-studio--inspector-heading :title "裁切" :note "时间单位：秒")
             (etaf-video-studio--inspector-time
              :label "入点" :value (etaf-video-studio--app-trim-in-ref app)
              :field-ref 'video-studio-trim-in :action-label "取当前播放位置"
              :action-ref 'video-studio-mark-in :disabled (not can-mark)
              :on-action (lambda () (etaf-video-studio--draft-mark app 'in)))
             (box :height '(lh 1))
             (etaf-video-studio--inspector-time
              :label "出点" :value (etaf-video-studio--app-trim-out-ref app)
              :field-ref 'video-studio-trim-out :action-label "取当前播放位置"
              :action-ref 'video-studio-mark-out :disabled (not can-mark)
              :on-action (lambda () (etaf-video-studio--draft-mark app 'out)))
             (box :height '(lh 1))
             (flex :width 'stretch :align-items 'center
               (text :color (etaf-video-studio-color :muted) "保留入点与出点之间的内容")
               (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
               (etaf-button :label "应用裁切" :width '(ch 20) :text-align 'center
                            :variant 'primary :disabled pending
                            :ref 'video-studio-trim-apply :on-press #'etaf-video-studio-apply-trim))
             (box :height '(lh 2) :border-bottom (etaf-video-studio--border (etaf-video-studio-color :line)))
             (etaf-video-studio--inspector-heading :title "分割")
             (etaf-video-studio--inspector-time
              :label "位置" :value (etaf-video-studio--app-split-ref app)
              :field-ref 'video-studio-split-at :action-label "分割片段"
              :action-ref 'video-studio-split-apply :disabled pending
              :on-action #'etaf-video-studio-apply-split)
             (box :height '(lh 2) :border-bottom (etaf-video-studio--border (etaf-video-studio-color :line)))
             (etaf-video-studio--inspector-heading :title "播放调整")
             (flex :width 'stretch :align-items 'center :column-gap '(ch 1)
               (box :width '(ch 6) :color (etaf-video-studio-color :muted) (text "速度"))
               (etaf-select :value (etaf-video-studio--app-speed-ref app)
                            :on-change (lambda (value) (etaf-video-studio--select-playback app 'speed value))
                            :disabled pending :label "播放速度" :hide-label t :presentation 'dropdown
                            :ref 'video-studio-speed :width '(ch 20)
                            :options '((0.5 . "0.5×") (1 . "1.0×") (2 . "2.0×") (4 . "4.0×"))))
             (box :height '(lh 1))
             (flex :width 'stretch :align-items 'center :column-gap '(ch 1)
               (box :width '(ch 6) :color (etaf-video-studio-color :muted) (text "音量"))
               (etaf-select :value (etaf-video-studio--app-gain-ref app)
                            :on-change (lambda (value) (etaf-video-studio--select-playback app 'gain value))
                            :disabled pending :label "音量百分比" :hide-label t :presentation 'dropdown
                            :ref 'video-studio-gain :width '(ch 20)
                            :options '((0.5 . "50%") (0.7 . "70%") (1 . "100%") (1.5 . "150%"))))
             (box :height '(lh 2) :padding '((lh 1) (ch 0)) :color (etaf-video-studio-color :muted)
               (text "选择后生效，可撤销")))))
       (flex :height '(lh 3) :width 'stretch :align-items 'center :column-gap '(ch 2)
             :padding '((lh 1) (ch 3))
             :border-top (etaf-video-studio--border (etaf-video-studio-color :line))
         (etaf-button :label "↑ 上移" :variant 'ghost :padding '((lh 0) (ch 0))
                      :disabled (or pending (not index) (<= index 0))
                      :ref 'video-studio-move-up :on-press #'etaf-video-studio-move-clip-up)
         (etaf-button :label "↓ 下移" :variant 'ghost :padding '((lh 0) (ch 0))
                      :disabled (or pending (not index) (>= (1+ (or index 0)) count))
                      :ref 'video-studio-move-down :on-press #'etaf-video-studio-move-clip-down)
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
         (etaf-button :label "删除片段" :variant 'ghost :padding '((lh 0) (ch 0))
                      :color (etaf-video-studio-color :danger)
                      :disabled (or pending (null clip)) :help-echo "删除此片段；可以撤销"
                      :ref 'video-studio-remove-clip :on-press #'etaf-video-studio-remove-selected-clip))))))

;;; Captions pane

(etaf-define-component etaf-video-studio--caption-row
    (&key caption index selected on-press)
  "Render one caption row with its final-timeline window."
  :view
  (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
        :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0
        :ref (intern (format "video-studio-caption-%d" index))
        :background-color (etaf-video-studio-color (if selected :accent-soft :panel))
        :hover-style (unless selected
                       (list :background-color (etaf-video-studio-color :hover)))
        :on-press on-press
    (box :height '(lh 1) :color (etaf-video-studio-color :muted)
      (text (expr (format "%s–%s"
                          (etaf-video-studio--clock (plist-get caption :start))
                          (etaf-video-studio--clock (plist-get caption :end))))))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
         :overflow 'hidden :font-weight (if selected 'bold 'normal)
         :color (etaf-video-studio-color (if selected :accent :ink))
      (text (expr (or (plist-get caption :text) ""))))))

(etaf-define-component etaf-video-studio--captions
    (&key app state)
  "Render the caption list and the add/update/delete form."
  :render
  (let* ((captions (etaf-video-studio--app-captions app))
         (project (plist-get state :project))
         (selected (plist-get state :caption-index))
         (editing (plist-get state :caption-edit-id))
         (pending (> (or (plist-get state :pending) 0) 0)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :row-gap '(lh 0)
           :padding '((lh 0) (ch 1))
           :background-color (etaf-video-studio-color :bg)
       (etaf-video-studio--section-title
        :icon 'lyrics :title (format "字幕 (%d)" (length captions))
        :action-label (if editing "新建" "清空表单")
        :action-ref 'video-studio-caption-reset
        :on-action (lambda () (etaf-video-studio-clear-caption-form)))
       (etaf-video-studio--placeholder
        :if (and project (null captions))
        :title "还没有说明文字" :description "用下方表单在成片时间上添加")
       (etaf-video-studio--caption-row
        :for (caption (etaf-video-studio--page-items app 'captions)) :key (plist-get caption :id)
        :caption caption
        :index (cl-position caption captions :test #'equal)
        :selected (equal selected (cl-position caption captions :test #'equal))
        :on-press (lambda ()
                    (etaf-video-studio-select-caption
                     (cl-position caption captions :test #'equal))))
       (etaf-video-studio--pager :if captions :kind 'captions :count (length captions)
                                 :page (etaf-video-studio--page app 'captions))
       (box :height '(lh 1))
       (etaf-video-studio--section-title
        :icon 'lyrics :title (if editing "编辑说明" "新建说明"))
       (flex :flex-direction 'row :width 'stretch :align-items 'center
             :gap '((lh 0) (ch 1))
         (etaf-text-input :bind (etaf-video-studio--app-caption-start-ref app)
                          :width '(ch 7) :hide-label t :placeholder "开始秒"
                          :ref 'video-studio-caption-start)
         (etaf-text-input :bind (etaf-video-studio--app-caption-end-ref app)
                          :width '(ch 7) :hide-label t :placeholder "结束秒"
                          :ref 'video-studio-caption-end))
       (etaf-text-input :bind (etaf-video-studio--app-caption-text-ref app)
                        :width 'stretch :hide-label t :placeholder "字幕文字" :ref 'video-studio-caption-text
                        :on-submit (lambda (_text) (etaf-video-studio-add-caption)))
       (flex :flex-direction 'row :width 'stretch :justify-content 'end
             :gap '((lh 0) (ch 1))
         (etaf-button :label "删除" :variant 'ghost :disabled (or pending (null selected))
                      :ref 'video-studio-caption-delete
                      :on-press (lambda () (etaf-video-studio-delete-caption)))
         (etaf-button :label (if editing "更新说明" "添加说明") :variant 'primary
                      :disabled (or pending (null project))
                      :ref 'video-studio-caption-add
                      :on-press (lambda () (etaf-video-studio-add-caption))))))))

;;; Record pane

(etaf-define-component etaf-video-studio--target-row
    (&key target index selected on-press)
  "Render one recording target row."
  :view
  (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
        :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0
        :ref (intern (format "video-studio-target-%d" index))
        :background-color (etaf-video-studio-color (if selected :accent-soft :panel))
        :hover-style (unless selected
                       (list :background-color (etaf-video-studio-color :hover)))
        :on-press on-press
    (box :width '(ch 20) :height '(lh 1) :overflow 'hidden
         :font-weight (if selected 'bold 'normal)
         :color (etaf-video-studio-color (if selected :accent :ink))
      (text (expr (or (plist-get target :title) (plist-get target :name) "目标"))))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
         :overflow 'hidden :color (etaf-video-studio-color :muted)
      (text (expr (format "%sx%s" (plist-get target :width) (plist-get target :height)))))))

(etaf-define-component etaf-video-studio--record
    (&key app state)
  "Render the target inventory, the recording settings and the toggle."
  :render
  (let* ((targets (plist-get state :record-targets))
         (selected (plist-get state :record-target-index))
         (task (plist-get state :record-task))
         (recording (and task t))
         (pending (> (or (plist-get state :pending) 0) 0))
         (project (plist-get state :project)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :row-gap '(lh 0)
           :padding '((lh 0) (ch 1))
           :background-color (etaf-video-studio-color :bg)
       (etaf-video-studio--section-title
        :icon 'video :title (format "录制目标 (%d)" (length targets))
        :action-label "刷新" :action-ref 'video-studio-targets-refresh
        :on-action (lambda () (etaf-video-studio-refresh-targets)))
       (etaf-video-studio--placeholder
        :if (null targets)
        :title "还没有目标" :description "刷新后选择窗口或屏幕")
       (etaf-video-studio--target-row
        :for (target (etaf-video-studio--page-items app 'record)) :key (or (plist-get target :id) (plist-get target :name))
        :target target :index (cl-position target targets :test #'equal)
        :selected (equal selected (cl-position target targets :test #'equal))
        :on-press (lambda ()
                    (etaf-video-studio-select-target
                     (cl-position target targets :test #'equal))))
       (etaf-video-studio--pager :if targets :kind 'record :count (length targets)
                                 :page (etaf-video-studio--page app 'record))
       (box :height '(lh 1))
       (flex :flex-direction 'row :width 'stretch :align-items 'center
             :gap '((lh 0) (ch 1))
         (etaf-select :bind (etaf-video-studio--app-record-audio-ref app)
                      :label "声音" :presentation 'dropdown :ref 'video-studio-record-audio
                      :options '(("none" . "不录") ("system" . "系统") ("microphone" . "麦克风")
                                 ("both" . "系统+麦克风")))
         (flex :width '(ch 10)
           (etaf-text-input :bind (etaf-video-studio--app-record-duration-ref app)
                            :hide-label t :placeholder "录制上限（秒）" :ref 'video-studio-record-duration)))
       (flex :flex-direction 'row :width 'stretch :align-items 'center
             :justify-content 'end :gap '((lh 0) (ch 2))
         (etaf-badge :if recording :text "录制中" :variant 'danger)
         (etaf-button :label (if recording "停止录制" "开始录制")
                      :variant (if recording 'primary 'secondary)
                      :disabled (or pending (null project)
                                    (and (null recording) (null selected)))
                      :ref 'video-studio-record-toggle
                      :on-press (lambda () (etaf-video-studio-toggle-record))))
       (box :height '(lh 1) :color (etaf-video-studio-color :muted)
         (text "上限单位为秒；停止后自动导入。"))
       (etaf-video-studio--fact
        :if task
        :label "任务"
        :value (format "%s · %s" (plist-get task :status) (plist-get task :id)))))))

;;; Publish pane

(etaf-define-component etaf-video-studio--publish
    (&key app state)
  "Render export status, the publish form and the confirm step."
  :render
  (let* ((project (plist-get state :project))
         (preview (plist-get state :publish-preview))
         (export (etaf-video-studio--app-screen-export app))
         (pending (> (or (plist-get state :pending) 0) 0))
         (revision (plist-get project :revision))
         (confirmed (and preview (equal (plist-get preview :revision) revision))))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :row-gap '(lh 0)
           :padding '((lh 0) (ch 1))
           :background-color (etaf-video-studio-color :bg)
       (etaf-video-studio--section-title
        :icon 'send :title "导出与发布"
        :action-label (if export "重新导出" "后台导出")
        :action-ref 'video-studio-render-screen
        :disabled (or pending (null project) (null (etaf-video-studio--app-clips app)))
        :on-action (lambda () (etaf-video-studio-render-screen)))
       (etaf-video-studio--fact
        :label "正式成片"
        :value (if export
                   (format "r%s 已完成" (plist-get export :revision))
                 "尚未导出")
        :value-color (if export (etaf-video-studio-color :ok)
                       (etaf-video-studio-color :muted)))
       (etaf-video-studio--fact
        :if export
        :label "成片文件"
        :value (etaf-video-studio--basename (plist-get export :output)))
       (etaf-button :if export :label "在文件夹中显示成片" :variant 'secondary
                    :ref 'video-studio-reveal-export :on-press #'etaf-video-studio-show-export)
       (box :height '(lh 1))
       (etaf-select :bind (etaf-video-studio--app-publish-target-ref app)
                    :label "目标"
                    :options '(("telegram" . "Telegram") ("share" . "公开链接")))
       (etaf-text-input :bind (etaf-video-studio--app-publish-chat-ref app)
                        :width 'stretch :hide-label t :placeholder "Telegram 会话 ID（仅 Telegram 需要）"
                        :ref 'video-studio-publish-chat)
       (etaf-text-input :bind (etaf-video-studio--app-publish-text-ref app)
                        :width 'stretch :hide-label t :placeholder "发布文案（默认项目标题）"
                        :ref 'video-studio-publish-text)
       (flex :flex-direction 'row :width 'stretch :align-items 'center
             :gap '((lh 0) (ch 1))
         (flex :width '(ch 14)
           (etaf-text-input :bind (etaf-video-studio--app-publish-topic-ref app)
                            :hide-label t :placeholder "话题 ID" :ref 'video-studio-publish-topic))
         (etaf-button :label "预览发布" :variant 'secondary
                      :disabled (or pending (null export))
                      :ref 'video-studio-publish-preview
                      :on-press (lambda () (etaf-video-studio-publish-preview))))
       (box :height '(lh 1))
       (flex :if preview :flex-direction 'column :width 'stretch :row-gap '(lh 0)
         (etaf-video-studio--fact :label "目标"
                                  :value (format "%s %s" (plist-get preview :target)
                                                 (or (plist-get preview :chat) "")))
         (etaf-video-studio--fact :label "版本"
                                  :value (format "r%s" (plist-get preview :revision)))
         (etaf-video-studio--fact :label "可见"
                                  :value (if (equal (plist-get preview :visibility) "public-link")
                                             "公开链接" "指定会话"))
         (etaf-video-studio--fact :label "文案"
                                  :value (or (plist-get preview :text) "—"))
         (flex :flex-direction 'row :width 'stretch :justify-content 'end
               :gap '((lh 0) (ch 1))
           (etaf-button :label "放弃预览" :variant 'ghost
                        :ref 'video-studio-publish-reset
                        :on-press (lambda () (etaf-video-studio-publish-reset)))
           (etaf-button :label "确认发布" :variant 'primary :disabled (or pending (not confirmed))
                        :ref 'video-studio-publish-confirm
                        :on-press (lambda () (etaf-video-studio-publish-confirm)))))
       (box :if (and preview (not confirmed)) :height '(lh 1)
            :color (etaf-video-studio-color :warning)
         (text "项目已变，请重新预览再确认"))
       (box :height '(lh 1) :color (etaf-video-studio-color :dim)
         (text "确认前不会上传。公开链接对所有人可见。"))))))

;;; Tasks pane

(etaf-define-component etaf-video-studio--task-row
    (&key task index selected on-press)
  "Render one task row with status, profile and time."
  :view
  (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
        :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0
        :ref (intern (format "video-studio-task-%d" index))
        :background-color (etaf-video-studio-color (if selected :accent-soft :panel))
        :hover-style (unless selected
                       (list :background-color (etaf-video-studio-color :hover)))
        :on-press on-press
    (etaf-badge :text (etaf-video-studio--task-status-label (plist-get task :status))
                :variant (etaf-video-studio--status-variant (plist-get task :status)))
    (box :height '(lh 1) :color (etaf-video-studio-color :muted)
      (text (expr (format "%s r%s"
                          (pcase (plist-get task :kind)
                            ("render" (if (equal (plist-get task :profile) "preview") "预览" "导出"))
                            ("record" "录屏") ("publish" "发布") (_ "任务"))
                          (or (plist-get task :revision) "—")))))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
         :overflow 'hidden :color (etaf-video-studio-color :ink)
      (text (expr (or (and (plist-get task :output)
                           (etaf-video-studio--basename (plist-get task :output)))
                      (plist-get task :message) (plist-get task :id) ""))))))

(etaf-define-component etaf-video-studio--tasks
    (&key app state)
  "Render the task list with retry and cancel actions."
  :render
  (let* ((tasks (etaf-video-studio--app-tasks app))
         (selected (plist-get state :task-index))
         (pending (> (or (plist-get state :pending) 0) 0))
         (render (cl-find-if (lambda (task)
                               (and (equal (plist-get task :kind) "render")
                                    (member (plist-get task :status)
                                            etaf-video-studio--active-statuses)))
                             tasks)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :row-gap '(lh 0)
           :padding '((lh 0) (ch 1))
           :background-color (etaf-video-studio-color :bg)
       (etaf-video-studio--section-title
        :icon 'clock :title (format "任务 (%d)" (length tasks))
        :action-label "刷新" :action-ref 'video-studio-tasks-refresh
        :on-action (lambda () (etaf-video-studio-refresh)))
       (etaf-video-studio--placeholder
        :if (null tasks)
        :title "还没有任务" :description "导出、录制或发布后在这里查看")
       (etaf-video-studio--task-row
        :for (task (etaf-video-studio--page-items app 'tasks)) :key (plist-get task :id)
        :task task :index (cl-position task tasks :test #'equal)
        :selected (equal selected (cl-position task tasks :test #'equal))
        :on-press (lambda ()
                    (etaf-video-studio-select-task
                     (cl-position task tasks :test #'equal))))
       (etaf-video-studio--pager :if tasks :kind 'tasks :count (length tasks)
                                 :page (etaf-video-studio--page app 'tasks))
       (box :height '(lh 1))
       (etaf-button :if (etaf-video-studio--app-screen-export app)
                    :label "在文件夹中显示成片" :variant 'secondary
                    :ref 'video-studio-task-reveal :on-press #'etaf-video-studio-show-export)
       (box :height '(lh 1))
       (flex :flex-direction 'row :width 'stretch :justify-content 'end
             :gap '((lh 0) (ch 1))
         (etaf-button :label "续跑导出" :variant 'ghost
                      :disabled (or pending (null (plist-get state :project)))
                      :ref 'video-studio-render-resume
                      :on-press (lambda () (etaf-video-studio-task-retry)))
         (etaf-button :label "取消导出" :variant 'ghost :disabled (or pending (null render))
                      :ref 'video-studio-render-cancel
                      :on-press (lambda () (etaf-video-studio-cancel-render))))))))

;;; Header, footer and shell

(etaf-define-component etaf-video-studio--header
    (&key state)
  "Render the title row, the revision and the global actions."
  :render
  (let* ((project (plist-get state :project))
         (pending (plist-get state :pending)))
    (etaf-view
     (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
           :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
           :background-color (etaf-video-studio-color :panel2)
           :border-bottom (etaf-video-studio--border (etaf-video-studio-color :line))
       (box :height '(lh 1) :color (etaf-video-studio-color :accent)
         (etaf-ui-icon :name 'video :set 'svg :size 0.9 :min-width 2))
       (box :height '(lh 1) :font-weight 'bold :color (etaf-video-studio-color :ink)
         (text "视频工作台"))
       (box :if project :height '(lh 1) :color (etaf-video-studio-color :dim)
         (text "·"))
       (box :if project :height '(lh 1) :overflow 'hidden
            :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :color (etaf-video-studio-color :muted)
         (text (expr (format "%s · r%s · %s"
                             (plist-get project :title)
                             (plist-get project :revision)
                             (etaf-video-studio--clock (plist-get project :duration))))))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
       (etaf-badge :if (> (or pending 0) 0) :text (format "工作中 %s" pending)
                   :variant 'warning)
       (etaf-button :label "刷新" :variant 'ghost :ref 'video-studio-header-refresh
                    :on-press (lambda () (etaf-video-studio-refresh)))
       (etaf-button :label "主题" :variant 'ghost :ref 'video-studio-theme
                    :on-press (lambda () (etaf-video-studio-toggle-theme)))
       (etaf-button :label "帮助" :variant 'ghost :ref 'video-studio-help
                    :on-press (lambda () (call-interactively #'etaf-help)))))))

(etaf-define-component etaf-video-studio--footer
    (&key state)
  "Render the retained status line and the key hints."
  :render
  (let ((message (or (plist-get state :message) "就绪。")))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch
           :background-color (etaf-video-studio-color :panel2)
           :border-top (etaf-video-studio--border (etaf-video-studio-color :line))
       (flex :flex-direction 'row :height '(lh 1) :width 'stretch :align-items 'center
             :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
              :overflow 'hidden :color (etaf-video-studio-color :ink)
           (text :ref etaf-video-studio--status-ref :id "etaf-video-studio-status"
                 (expr message)))
         (box :height '(lh 1) :color (etaf-video-studio-color :dim)
           (text :ref 'video-studio-footer-position :id "video-studio-footer-position"
                 (expr (etaf-video-studio--footer-position-text state)))))
       (box :height '(lh 1) :padding '((lh 0) (ch 1))
            :overflow 'hidden :color (etaf-video-studio-color :dim)
         (text "SPC 播放 · i/o 入出点 · s 分割 · u 撤销 · ? 全部快捷键"))))))

(defun etaf-video-studio--stage-stale-p (state)
  "Whether STATE's rendered preview belongs to an older revision."
  (let ((stage (plist-get state :stage))
        (revision (plist-get (plist-get state :project) :revision)))
    (and stage (eq (plist-get stage :kind) 'preview)
         (not (equal (plist-get stage :revision) revision)))))

(defun etaf-video-studio--stage-caption (state)
  "Return the one-line caption under STATE's video stage."
  (let ((stage (plist-get state :stage)))
    (cond
     ((null stage) "")
     ((eq (plist-get stage :kind) 'preview)
      (if (etaf-video-studio--stage-stale-p state)
          (format "预览已过期：来自 r%s，按 v 重新生成 · %s"
                  (or (plist-get stage :revision) "?")
                  (etaf-video-studio--basename (plist-get stage :file)))
        (format "成片预览为当前版本 · %s"
                (etaf-video-studio--basename (plist-get stage :file)))))
     (t (format "素材预览 · %s"
                (etaf-video-studio--basename (plist-get stage :file)))))))

(defun etaf-video-studio--footer-position-text (state)
  "Return the footer's compact stage line for STATE."
  (or (plist-get state :stage-position) "无预览"))

(etaf-define-component etaf-video-studio--region (&key app kind width height)
  "Subscribe one region to only the snapshot fields it actually displays."
  :bindings
  ((projection
    (etaf-computed
     (lambda ()
       (let ((snapshot (etaf-value (etaf-video-studio--app-data-ref app)))
             (keys (pcase kind
                     ((or 'welcome 'projects) '(:projects :project :pages :pending))
                     ('header '(:project :pending))
                     ('toolbar '(:project :pending))
                     ('footer '(:message :stage-position))
                     ('preview '(:project :stage :preview :stage-playing :stage-position :pending))
                     ('properties '(:project :clip :clip-index :stage :pending))
                     ('clips '(:project :clip-index :pages :pending))
                     ('captions '(:project :caption-index :caption-edit-id :pages :pending))
                     ('record '(:project :record-targets :record-target-index :record-task :pages :pending))
                     ('publish '(:project :publish-preview :pending))
                     ('tasks '(:project :task-index :pages :pending)))))
         (cl-loop for key in keys append (list key (plist-get snapshot key)))))
     :test #'equal)))
  :render
  (let* ((cell (max 1 (or (plist-get (ignore-errors (etaf-display-metrics))
                                  :char-width)
                          (frame-char-width))))
         (content
         (etaf-node
          (intern (format "etaf-video-studio--%s" kind))
          (append (list :state (etaf-value projection))
                  (unless (memq kind '(header footer)) (list :app app))
                  (when (eq kind 'properties) (list :height height))
                  (when (eq kind 'preview)
                    (list :width (and width (- width (* 2 cell) 2))
                          :height (and height (- height 2)))))
          nil)))
    (if (memq kind '(preview clips captions record publish tasks))
        (etaf-node 'etaf-panel
                   (append (list :width 'stretch :padding '((lh 0.5) (ch 1))
                                 :item-gap '(lh 0))
                           (when height (list :height (list 'lh height))))
                   (list content))
      content)))

(etaf-define-component etaf-video-studio--welcome (&key app state)
  "Make the first useful action the centre of the empty workspace."
  :view
  (flex :flex-direction 'column :width 'stretch :align-items 'center
        :padding '((lh 1) (ch 2))
    (flex :flex-direction 'column :width '(ch 64) :max-width '(% 100)
          :padding '((lh 1) (ch 2)) :background-color (etaf-video-studio-color :panel)
      (box :height '(lh 1) :font-weight 'bold :color (etaf-video-studio-color :ink)
        (text "从一段素材，做成一支视频"))
      (box :height '(lh 1))
      (box :color (etaf-video-studio-color :muted)
        (text "新建项目 → 导入或录屏 → 剪辑与字幕 → 导出"))
      (box :height '(lh 1))
      (etaf-video-studio--projects :app app :state state)
      (box :height '(lh 1))
      (box :color (etaf-video-studio-color :muted)
        (text "修改自动保存；裁切和删除片段不会改动原视频。")))))

(etaf-define-component etaf-video-studio--toolbar (&key app state)
  "Keep the primary workflow visible without remembering shortcuts."
  :render
  (let* ((project (plist-get state :project))
         (clips (etaf-video-studio--app-clips app))
         (busy (> (or (plist-get state :pending) 0) 0)))
    (etaf-view
     (flex :flex-direction 'row :width 'stretch :height '(lh 1)
           :align-items 'center :gap '((lh 0) (ch 1))
       (etaf-button :label "导入素材" :variant 'secondary :ref 'video-studio-toolbar-import
                    :disabled (or busy (null project))
                    :on-press (lambda () (call-interactively #'etaf-video-studio-import-files)))
       (etaf-button :label "录屏" :variant 'ghost :ref 'video-studio-toolbar-record
                    :disabled (null project) :on-press #'etaf-video-studio-show-record)
       (etaf-button :label "撤销" :variant 'ghost :ref 'video-studio-toolbar-undo
                    :disabled (or busy (not (plist-get project :undo)))
                    :on-press #'etaf-video-studio-undo)
       (etaf-button :label "重做" :variant 'ghost :ref 'video-studio-toolbar-redo
                    :disabled (or busy (not (plist-get project :redo)))
                    :on-press #'etaf-video-studio-redo)
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
       (etaf-button :label "预览成片" :variant 'secondary :ref 'video-studio-render-preview
                    :disabled (or busy (null clips)) :on-press #'etaf-video-studio-render-preview)
       (etaf-button :label "导出视频" :variant 'primary :ref 'video-studio-toolbar-export
                    :disabled (or busy (null clips)) :on-press #'etaf-video-studio-render-screen)))))

(etaf-define-component etaf-video-studio--shell (&key app)
  "Render stable navigation above a height-budgeted editing workspace."
  :bindings ((theme (etaf-video-studio--app-theme-ref app))
             (data (etaf-computed
                    (lambda ()
                      (let ((snapshot (etaf-value (etaf-video-studio--app-data-ref app))))
                        (list :pane (plist-get snapshot :pane)
                              :project (and (plist-get snapshot :project) t)
                              :has-clips (and (etaf-video-studio--app-clips app) t))))
                    :test #'equal)))
  :setup
  (etaf-theme-provide theme)
  :render
  (let* ((state (etaf-value data))
         (viewport (etaf-runtime-viewport))
         (cell (max 1 (or (plist-get (ignore-errors (etaf-display-metrics))
                                   :char-width)
                          (frame-char-width))))
         (width (max (* 80 cell) (or (car viewport) 800)))
         (rows (max 28 (or (cdr viewport) 30)))
         (body-rows (- rows 12))
         (pane (or (plist-get state :pane) 'projects))
         (home (or (null (plist-get state :project)) (eq pane 'projects)))
         (split (and (not home) (>= width etaf-video-studio--aside-min-pixels)
                     (>= body-rows 22)))
         (timeline (and split (plist-get state :has-clips) (>= body-rows 28)))
         (aside (if (memq pane '(preview clips)) 'properties pane))
         (main-width (- width (if split (* 64 cell) 0))))
    (etaf-view
     (box :position 'relative :width (list 'px width) :height (list 'lh rows)
          :background-color (etaf-video-studio-color :bg)
          :color (etaf-video-studio-color :ink) :overflow 'hidden
          :region (list :id 'video-studio-workspace :label "工作台" :key ?w)
       (box :position 'absolute :left '(px 0) :top '(lh 0)
            :width (list 'px width) :height (list 'lh rows)
            :background-color (etaf-video-studio-color :bg))
       (box :position 'absolute :top '(lh 1) :left '(ch 2)
            :width (list 'px (- width (* 4 cell))) :height '(lh 1)
         (etaf-video-studio--region :app app :kind 'header))
       (box :position 'absolute :top '(lh 2) :left '(ch 1)
            :width (list 'px (- width (* 2 cell))) :height '(lh 3)
            :padding '((lh 1) (ch 1))
            :background-color (etaf-video-studio-color :panel)
         (etaf-video-studio--region :app app :kind 'toolbar))
       (box :position 'absolute :top '(lh 6) :left '(ch 2)
            :width (list 'px (- width (* 4 cell))) :height '(lh 1)
         (etaf-tabs :items (etaf-video-studio--pane-tabs state nil)
                    :active (if home 'projects pane)
                    :on-change (lambda (key) (etaf-video-studio-select-pane key))))
       (box :position 'absolute :top '(lh 8) :left '(px 0)
            :width (list 'px width) :height (list 'lh body-rows) :overflow 'hidden
         (etaf-video-studio--region :if home :app app :kind 'welcome)
         (box :if (not home) :position 'relative
              :width (list 'px main-width) :height (list 'lh body-rows)
              :region (list :id 'video-studio-preview :label "预览与片段" :key ?v)
           (box :if (or split (eq pane 'preview)) :position 'absolute
                :left '(ch 1) :top '(lh 0)
                :width (list 'px (- main-width (* 2 cell)))
                :height (list 'lh (- body-rows (if timeline 12 0)))
             (etaf-video-studio--region :app app :kind 'preview
                                       :width (- main-width (* 2 cell))
                                       :height (- body-rows (if timeline 12 0))))
           (box :if timeline :position 'absolute :top (list 'lh (- body-rows 11))
                :left '(ch 1) :width (list 'px (- main-width (* 2 cell)))
                :height '(lh 11) :overflow 'hidden
             (etaf-video-studio--region :app app :kind 'clips :height 11))
           (flex :if (and (not split) (not (eq pane 'preview)))
                 :flex-direction 'column :width 'stretch :align-items 'center
             (box :width '(ch 70) :max-width '(% 100)
               (etaf-video-studio--region :key pane :app app :kind pane :height body-rows))))
         (box :if split :position 'absolute :left (list 'px main-width) :top '(lh 0)
              :width '(ch 64) :height (list 'lh body-rows) :padding '((lh 0) (ch 1))
              :region (list :id 'video-studio-details :label "编辑区" :key ?d)
           (etaf-video-studio--region
            :key (if (and (eq pane 'clips) (not timeline)) 'clips aside)
            :app app :height body-rows
            :kind (if (and (eq pane 'clips) (not timeline)) 'clips aside))))
       (box :position 'absolute :left '(px 0) :top (list 'lh (- rows 4))
            :width (list 'px width) :height '(lh 4) :padding '((lh 1) (ch 2))
            :overflow 'hidden :background-color (etaf-video-studio-color :panel2)
         (etaf-video-studio--region :app app :kind 'footer))))))

(provide 'etaf-video-studio-views)
;;; etaf-video-studio-views.el ends here
