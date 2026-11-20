;;; etaf-ui-gui.el --- Native component example interaction checks -*- lexical-binding: t; -*-

;;; Commentary:
;; Loaded by scripts/run-gui-check.sh in an existing graphical Emacs server.
;; Exercise native command bindings and minibuffer input in the dedicated
;; example buffer. This is not an OS input-method or latency certification.

;;; Code:
(require 'etaf-ui)
(require 'cl-lib)
(defvar etaf-ui-gui-interactions nil)
(defvar etaf-ui-gui-steps nil)
(defvar etaf-ui-gui-original-keys nil)
(defvar etaf-ui-gui-expected-quit nil)
(defvar etaf-ui-gui-buffer "*ETAF UI Surfaces*")

(defun etaf-ui-gui-runtime ()
  (or (etaf-runtime-for-buffer etaf-ui-gui-buffer) (error "Fixture is unmounted")))
(defun etaf-ui-gui-control (label)
  (let ((runtime (etaf-ui-gui-runtime)))
    (car (cl-find-if
          (lambda (entry)
            (and (equal label (plist-get (cdr entry) :aria-label))
                 (etaf-host-ref-position runtime (car entry))))
          (etaf-runtime-host-props-entries runtime)))))
(defun etaf-ui-gui-expect (test format-string &rest args)
  (unless test (apply #'error format-string args)))
(defun etaf-ui-gui-focused (label)
  (etaf-ui-gui-expect
   (equal (etaf-focused-host-ref (etaf-ui-gui-runtime))
          (or (etaf-ui-gui-control label) (error "Missing control %s" label)))
   "Expected focus on %s" label))
(defun etaf-ui-gui-key (keys)
  (execute-kbd-macro (kbd keys)))
(defun etaf-ui-gui-tab-to (label)
  (let* ((runtime (etaf-ui-gui-runtime))
         (target (or (etaf-ui-gui-control label) (error "Missing control %s" label)))
         (limit (1+ (length (etaf-runtime-host-props-entries runtime)))))
    (while (and (> limit 0) (not (equal target (etaf-focused-host-ref runtime))))
      (etaf-ui-gui-key "TAB") (cl-decf limit))
    (etaf-ui-gui-focused label)))
(defun etaf-ui-gui-press (label)
  (etaf-ui-gui-tab-to label) (etaf-ui-gui-key "RET"))
(defun etaf-ui-gui-visible (label expected)
  (etaf-ui-gui-expect (eq (and (etaf-ui-gui-control label) t) expected)
                         "Visibility mismatch for %s" label))
(defun etaf-ui-gui-text (text)
  (etaf-ui-gui-expect (string-match-p (regexp-quote text)
                                    (buffer-substring-no-properties (point-min) (point-max)))
                         "Missing rendered text %s" text))
(defun etaf-ui-gui-input (text &optional cancel label)
  "Type TEXT into the field at LABEL and leave it; CANCEL discards the draft.
The field edits in place, so the text goes through the command loop and the
session ends with its submit or its cancel key."
  (let ((label (or label "名称")))
    (etaf-ui-gui-press label)
    (etaf-ui-gui-expect (etaf-text-input-active-p (etaf-ui-gui-runtime))
                        "Field session did not start")
    (execute-kbd-macro (vconcat text (kbd (if cancel "C-c C-k" "RET"))))
    (etaf-ui-gui-expect (not (etaf-text-input-active-p (etaf-ui-gui-runtime)))
                        "Field session stayed active")
    (etaf-ui-gui-focused label)))
(defun etaf-ui-gui-mouse-position (position)
  "Send a complete native pointer click to visible buffer POSITION."
  (redisplay t)
  (let ((data (posn-at-point position (selected-window))))
    (etaf-ui-gui-expect (and data (pos-visible-in-window-p position)) "Mouse target offscreen")
    (execute-kbd-macro (vector (list 'down-mouse-1 data) (list 'mouse-1 data)))))

(defun etaf-ui-gui-mouse (label)
  (let ((ref (or (etaf-ui-gui-control label) (error "Missing mouse target %s" label))))
    (etaf-ui-gui-mouse-position (etaf-host-ref-position (etaf-ui-gui-runtime) ref))))

(defun etaf-ui-gui-next-step ()
  (when etaf-ui-gui-steps
    (let* ((step (pop etaf-ui-gui-steps))
           (label (car step)))
      (condition-case problem
          (progn
            (etaf-ui-gui-expect
             (and (not (active-minibuffer-window))
                  (equal (buffer-name (window-buffer (selected-window))) etaf-ui-gui-buffer))
             "Selected window drifted or another minibuffer is active")
            (with-current-buffer etaf-ui-gui-buffer
              (let ((command-errors nil) (etaf-ui-gui-expected-quit nil))
                (let ((command-error-function
                       (lambda (data _context _caller) (push data command-errors))))
                  (funcall (cdr step)))
                (etaf-ui-gui-expect
                 (or (not command-errors)
                     (and etaf-ui-gui-expected-quit
                          (= (length command-errors) 1)
                          (memq 'quit (get (caar command-errors) 'error-conditions))))
                 "Native command errors: %S" command-errors))
              (redisplay t))
            (push (list label 'passed) etaf-ui-gui-interactions)
            (if etaf-ui-gui-steps (run-at-time 0.15 nil #'etaf-ui-gui-next-step)
              (push '(complete passed) etaf-ui-gui-interactions)))
        ((error quit)
         (push (list label 'failed (error-message-string problem)) etaf-ui-gui-interactions)
         (setq etaf-ui-gui-steps nil))))))

;;;###autoload
(defun etaf-ui-gui-interactions-start ()
  "Run the example's interaction sequence in the existing graphical frame."
  (unless (display-graphic-p) (user-error "GUI checks require a graphical Emacs frame"))
  (when (active-minibuffer-window) (user-error "Finish the active minibuffer before GUI checks"))
  (when-let* ((runtime (etaf-runtime-for-buffer "*ETAF UI Surfaces*")))
    (etaf-unmount runtime))
  (setq etaf-ui-gui-buffer "*ETAF UI Surfaces*"
        etaf-ui-gui-interactions nil
        etaf-ui-gui-steps
        (list
         (cons "mount" (lambda ()
                         (etaf-ui-surfaces-open)
                         (setq etaf-ui-gui-original-keys
                               (mapcar (lambda (key) (key-binding (kbd key))) '("<escape>" "C-g")))
                         (etaf-ui-gui-text "准备就绪")))
         (cons "dropdown-keyboard-open" (lambda () (etaf-ui-gui-press "操作") (etaf-ui-gui-focused "编辑偏好")))
         (cons "dropdown-down" (lambda () (etaf-ui-gui-key "<down>") (etaf-ui-gui-focused "复制工作空间")))
         (cons "dropdown-skip-disabled-wrap" (lambda () (etaf-ui-gui-key "TAB") (etaf-ui-gui-focused "编辑偏好")))
         (cons "dropdown-backtab" (lambda () (etaf-ui-gui-key "<backtab>") (etaf-ui-gui-focused "复制工作空间")))
         (cons "dropdown-up" (lambda () (etaf-ui-gui-key "<up>") (etaf-ui-gui-focused "编辑偏好")))
         (cons "dropdown-select" (lambda () (etaf-ui-gui-press "复制工作空间") (etaf-ui-gui-text "已复制工作空间") (etaf-ui-gui-visible "编辑偏好" nil) (etaf-ui-gui-focused "操作")))
         (cons "dropdown-escape" (lambda () (etaf-ui-gui-press "操作") (etaf-ui-gui-key "<escape>") (etaf-ui-gui-visible "编辑偏好" nil) (etaf-ui-gui-focused "操作")))
         (cons "menu-dialog-handoff" (lambda () (etaf-ui-gui-press "操作") (etaf-ui-gui-key "RET") (etaf-ui-gui-visible "编辑偏好" nil) (etaf-ui-gui-focused "名称")))
         (cons "native-chinese-input" (lambda () (etaf-ui-gui-input "中文交互验收") (etaf-ui-gui-text "中文交互验收")))
         (cons "native-input-cancel" (lambda () (etaf-ui-gui-input "未提交草稿" t) (etaf-ui-gui-text "中文交互验收") (etaf-ui-gui-expect (not (string-match-p "未提交草稿" (buffer-string))) "Cancelled draft published")))
         (cons "dialog-checkbox" (lambda () (etaf-ui-gui-press "接收通知") (etaf-ui-gui-text "[ ] 接收通知")))
         (cons "dialog-focus-cycle" (lambda () (etaf-ui-gui-tab-to "关闭") (etaf-ui-gui-key "TAB") (etaf-ui-gui-focused "名称") (etaf-ui-gui-key "<backtab>") (etaf-ui-gui-focused "关闭")))
         (cons "dialog-close-return-menu-trigger" (lambda () (etaf-ui-gui-key "RET") (etaf-ui-gui-visible "名称" nil) (etaf-ui-gui-focused "操作") (etaf-ui-gui-text "通知已关闭")))
         (cons "dialog-direct-open-complete" (lambda () (etaf-ui-gui-press "偏好设置") (etaf-ui-gui-press "完成") (etaf-ui-gui-visible "名称" nil) (etaf-ui-gui-focused "偏好设置") (etaf-ui-gui-text "偏好已更新")))
         (cons "dialog-escape" (lambda () (etaf-ui-gui-press "偏好设置") (etaf-ui-gui-key "<escape>") (etaf-ui-gui-focused "偏好设置")))
         (cons "help-open-close" (lambda () (etaf-ui-gui-press "帮助") (etaf-ui-gui-focused "知道了") (etaf-ui-gui-key "RET") (etaf-ui-gui-visible "知道了" nil) (etaf-ui-gui-focused "帮助")))
         (cons "help-escape" (lambda () (etaf-ui-gui-press "帮助") (etaf-ui-gui-key "<escape>") (etaf-ui-gui-focused "帮助")))
         (cons "mouse-dropdown-open" (lambda () (etaf-ui-gui-mouse "操作") (etaf-ui-gui-visible "编辑偏好" t)))
         (cons "mouse-disabled-item" (lambda () (etaf-ui-gui-mouse "删除（不可用）") (etaf-ui-gui-visible "编辑偏好" t)))
         (cons "mouse-menu-dialog" (lambda () (etaf-ui-gui-mouse "编辑偏好") (etaf-ui-gui-focused "名称")))
         (cons "mouse-checkbox" (lambda () (etaf-ui-gui-mouse "接收通知") (etaf-ui-gui-text "[x] 接收通知")))
         (cons "mouse-dialog-close" (lambda () (etaf-ui-gui-mouse "关闭") (etaf-ui-gui-visible "名称" nil) (etaf-ui-gui-focused "操作")))
         (cons "mouse-help" (lambda () (etaf-ui-gui-mouse "帮助") (etaf-ui-gui-mouse "知道了") (etaf-ui-gui-focused "帮助")))
         (cons "shortcuts-restored" (lambda () (etaf-ui-gui-expect (equal etaf-ui-gui-original-keys (mapcar (lambda (key) (key-binding (kbd key))) '("<escape>" "C-g"))) "Dismissal keys leaked")))
         (cons "unmount-with-open-dialog" (lambda () (etaf-ui-gui-press "偏好设置") (etaf-unmount (etaf-ui-gui-runtime)) (etaf-ui-gui-expect (not (etaf-runtime-for-buffer (current-buffer))) "Runtime survived unmount")))
         (cons "remount-interaction" (lambda () (etaf-ui-surfaces-open) (etaf-ui-gui-press "操作") (etaf-ui-gui-key "<escape>") (etaf-ui-gui-focused "操作") (etaf-ui-gui-text "准备就绪")))))
  (switch-to-buffer (get-buffer-create "*ETAF UI Surfaces*"))
  (run-at-time 0.1 nil #'etaf-ui-gui-next-step)
  'scheduled)

(defun etaf-ui-gui-activate (label)
  "Focus LABEL through the public API and execute native Return."
  (let ((target (or (etaf-ui-gui-control label) (error "Missing control %s" label))))
    (etaf-focus (etaf-ui-gui-runtime) target)
    (etaf-ui-gui-key "RET")))

(defun etaf-ui-gui-reveal (label)
  "Reveal LABEL through the mounted application's public scrolling API."
  (let* ((runtime (etaf-ui-gui-runtime))
         (ref (car (cl-find-if
                    (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
                    (etaf-runtime-host-props-entries runtime)))))
    (unless ref (error "Missing control %s" label))
    (etaf-scroll-into-view runtime ref))
  (etaf-ui-gui-visible label t))

(defun etaf-ui-gui-selected (label)
  "Require the visible control LABEL to expose its selected state."
  (let* ((runtime (etaf-ui-gui-runtime))
         (ref (etaf-ui-gui-control label))
         (selected (and ref (plist-get (etaf-runtime-host-props-for runtime ref)
                                       :aria-selected))))
    (etaf-ui-gui-expect selected "Control is not selected: %s" label)))

(defun etaf-ui-gallery-gui-search (query)
  "Replace the Gallery's live query with QUERY through native input."
  (etaf-ui-gui-activate "搜索组件名称或用途")
  (execute-kbd-macro (vconcat (kbd "C-a C-SPC C-e C-w") query (kbd "RET")))
  (etaf-ui-gui-expect (not (etaf-text-input-active-p (etaf-ui-gui-runtime)))
                      "Search session stayed active"))

(defun etaf-ui-gallery-gui-window-gestures ()
  "Move and resize the sample window through public drag gestures."
  (etaf-ui-gallery-gui-search "etaf-window")
  (etaf-ui-gui-reveal "Resize right")
  (let* ((runtime (etaf-ui-gui-runtime))
         (entries (etaf-runtime-host-props-entries runtime))
         (panel (car (cl-find-if (lambda (e) (eq (plist-get (cdr e) :role) 'dialog)) entries)))
         (title (car (cl-find-if (lambda (e) (and (eq (plist-get (cdr e) :role) 'heading)
                                                  (plist-get (cdr e) :on-drag))) entries)))
         (before (etaf-host-ref-size runtime panel))
         (handle (etaf-ui-gui-control "Resize right")))
    (etaf-ui-gui-expect (and before title handle) "Window gesture targets are absent")
    (etaf-drag-step runtime handle 3 0)
    (etaf-ui-gui-expect (> (car (etaf-host-ref-size runtime panel)) (car before))
                        "Window width did not grow")
    (let ((position (etaf-host-ref-position runtime panel)))
      (etaf-drag-step runtime title 2 1)
      (etaf-ui-gui-expect (not (equal position (etaf-host-ref-position runtime panel)))
                          "Window did not move"))
    (etaf-ui-gui-activate "恢复窗口")
    (etaf-ui-gui-expect (equal before (etaf-host-ref-size runtime panel))
                        "Window restore changed its intrinsic size")))

(defun etaf-ui-gallery-gui-interactions-start ()
  "Run the Gallery workflow in the existing graphical Emacs frame."
  (unless (display-graphic-p) (user-error "GUI checks require a graphical Emacs frame"))
  (when (active-minibuffer-window) (user-error "Finish the active minibuffer before GUI checks"))
  (when-let* ((runtime (etaf-runtime-for-buffer "*ETAF UI Gallery*")))
    (etaf-unmount runtime))
  (setq etaf-ui-gui-buffer "*ETAF UI Gallery*"
        etaf-ui-gui-interactions nil
        etaf-ui-gui-steps
        (list
         (cons "mount-gallery" (lambda () (etaf-ui-gallery-open) (etaf-refit) (etaf-ui-gui-text "组件总览")))
         (cons "search-chinese" (lambda () (etaf-ui-gallery-gui-search "日期") (etaf-ui-gui-text "日期输入")))
         (cons "search-empty" (lambda () (etaf-ui-gallery-gui-search "no-such-component") (etaf-ui-gui-text "没有找到组件") (etaf-ui-gui-activate "清空搜索")))
         (cons "tooltip-dismiss" (lambda () (etaf-ui-gallery-gui-search "etaf-tooltip") (etaf-ui-gui-activate "显示提示") (etaf-ui-gui-text "Tab 切换控件，Enter") (etaf-ui-gui-key "<escape>") (etaf-ui-gui-focused "显示提示")))
         (cons "popover-dismiss" (lambda () (etaf-ui-gallery-gui-search "etaf-popover") (etaf-ui-gui-activate "打开气泡") (etaf-ui-gui-visible "关闭气泡" t) (etaf-ui-gui-key "<escape>") (etaf-ui-gui-focused "打开气泡")))
         (cons "toast-dismiss" (lambda () (etaf-ui-gallery-gui-search "etaf-toast") (etaf-ui-gui-activate "显示通知") (etaf-ui-gui-text "保存完成") (etaf-ui-gui-key "<escape>")))
         (cons "dropdown-select" (lambda () (etaf-ui-gallery-gui-search "etaf-dropdown-menu") (etaf-ui-gui-activate "操作菜单") (etaf-ui-gui-activate "复制内容") (etaf-ui-gui-text "copy")))
         (cons "context-select" (lambda () (etaf-ui-gallery-gui-search "etaf-context-menu") (etaf-ui-gui-activate "更多操作") (etaf-ui-gui-activate "检查属性") (etaf-ui-gui-text "inspect")))
         (cons "drawer-close" (lambda () (etaf-ui-gallery-gui-search "etaf-drawer") (etaf-ui-gui-activate "展开抽屉") (etaf-ui-gui-text "组件详情") (etaf-ui-gui-activate "关闭抽屉") (etaf-ui-gui-focused "展开抽屉")))
         (cons "dialog-open" (lambda () (etaf-ui-gallery-gui-search "etaf-dialog") (etaf-ui-gui-activate "打开对话框") (etaf-ui-gui-focused "示例项目名称")))
         (cons "dialog-chinese-input" (lambda () (etaf-ui-gui-input "中文创作计划" nil "示例项目名称") (etaf-ui-gui-text "中文创作计划")))
         (cons "dialog-create" (lambda () (etaf-ui-gui-activate "创建项目") (etaf-ui-gui-text "已创建：中文创作计划") (etaf-ui-gui-focused "打开对话框")))
         (cons "dialog-cancel" (lambda () (etaf-ui-gui-activate "打开对话框") (etaf-ui-gui-activate "取消") (etaf-ui-gui-visible "示例项目名称" nil) (etaf-ui-gui-focused "打开对话框")))
         (cons "dialog-outside-click" (lambda () (etaf-ui-gui-activate "打开对话框") (etaf-ui-gui-mouse "示例项目名称") (etaf-ui-gui-visible "取消" t) (etaf-ui-gui-mouse-position (point-min)) (etaf-ui-gui-visible "取消" nil) (etaf-ui-gui-focused "打开对话框")))
         (cons "key-help-search-and-outside-click"
               (lambda ()
                 (etaf-ui-gallery-gui-search "etaf-key-help")
                 (let ((windows (window-list)))
                   (etaf-ui-gui-activate "查看快捷键")
                   (etaf-ui-gui-expect (equal windows (window-list)) "Help changed the window tree")
                   (etaf-ui-gui-mouse "搜索快捷键或操作")
                   (etaf-ui-gui-visible "关闭帮助" t)
                   (etaf-ui-gui-key "?")
                   (etaf-ui-gui-text "查看快捷键")
                   (etaf-ui-gui-key "<escape>")
                   (etaf-ui-gui-visible "关闭帮助" t)
                   (etaf-ui-gui-mouse-position (point-min))
                   (etaf-ui-gui-visible "关闭帮助" nil)
                   (etaf-ui-gui-focused "查看快捷键"))))
         (cons "checkbox-toggle" (lambda () (etaf-ui-gallery-gui-search "etaf-checkbox") (etaf-ui-gui-activate "接收通知") (etaf-ui-gui-text "接收通知 = t")))
         (cons "radio-select" (lambda () (etaf-ui-gallery-gui-search "etaf-radio") (etaf-ui-gui-activate "宽松")))
         (cons "select-chips" (lambda () (etaf-ui-gallery-gui-search "etaf-select") (etaf-ui-gui-activate "开发") (etaf-ui-gui-selected "开发")))
         (cons "select-dropdown" (lambda () (etaf-ui-gui-activate "语言") (etaf-ui-gui-activate "English") (etaf-ui-gui-text "English")))
         (cons "segmented-select" (lambda () (etaf-ui-gallery-gui-search "etaf-segmented") (etaf-ui-gui-activate "周") (etaf-ui-gui-selected "周")))
         (cons "taskbar-select" (lambda () (etaf-ui-gallery-gui-search "etaf-taskbar") (etaf-ui-gui-activate "预览") (etaf-ui-gui-selected "预览")))
         (cons "workspace-select" (lambda () (etaf-ui-gallery-gui-search "etaf-workspace-bar") (etaf-ui-gui-activate "工作区 2") (etaf-ui-gui-selected "工作区 2")))
         (cons "switch-toggle" (lambda () (etaf-ui-gallery-gui-search "etaf-switch") (etaf-ui-gui-activate "实时预览") (etaf-ui-gui-text "预览已关闭")))
         (cons "number-input-edit-and-step"
               (lambda ()
                 (etaf-ui-gallery-gui-search "etaf-number-input")
                 (etaf-ui-gui-activate "列数")
                 (execute-kbd-macro (vconcat (kbd "C-a C-SPC C-e C-w") "7" (kbd "RET")))
                 (etaf-ui-gui-activate "Increase 列数")
                 (let* ((bounds (etaf-host-ref-bounds (etaf-ui-gui-runtime) (etaf-ui-gui-control "列数")))
                        (text (buffer-substring-no-properties (car bounds) (cdr bounds))))
                   (etaf-ui-gui-expect (string-match-p "\\_<8\\_>" text) "NumberInput did not accept 7 then step to 8"))))
         (cons "date-input-edit"
               (lambda ()
                 (etaf-ui-gallery-gui-search "etaf-date-picker")
                 (etaf-ui-gui-activate "计划日期")
                 (execute-kbd-macro (vconcat (kbd "C-a C-SPC C-e C-w") "2026-12-25" (kbd "RET")))
                 (etaf-ui-gui-text "2026-12-25")))
         (cons "slider-keyboard"
               (lambda ()
                 (etaf-ui-gallery-gui-search "etaf-slider")
                 (etaf-focus (etaf-ui-gui-runtime) (etaf-ui-gui-control "预览缩放"))
                 (etaf-ui-gui-key "<right>")
                 (etaf-ui-gui-text "70")))
         (cons "range-keyboard" (lambda () (etaf-ui-gallery-gui-search "etaf-range") (etaf-focus (etaf-ui-gui-runtime) (etaf-ui-gui-control "音量示例")) (etaf-ui-gui-key "<right>") (etaf-ui-gui-text "当前 61%")))
         (cons "splitter-keyboard"
               (lambda ()
                 (etaf-ui-gallery-gui-search "etaf-splitter")
                 (let* ((runtime (etaf-ui-gui-runtime))
                        (width (car (etaf-host-ref-size runtime 'example-split)))
                        (x (lambda ()
                             (save-excursion
                               (goto-char (etaf-host-ref-position runtime (etaf-ui-gui-control "Resize columns")))
                               (etaf-string-pixel-width
                                (buffer-substring (line-beginning-position) (point))))))
                        (before (funcall x)))
                   (etaf-focus runtime (etaf-ui-gui-control "Resize columns"))
                   (dotimes (_ 5) (etaf-ui-gui-key "<right>"))
                   (etaf-ui-gui-expect
                    (<= (abs (- (- (funcall x) before) (* 5 (frame-char-width))))
                        (1+ (/ width 100.0)))
                    "Splitter keyboard delta did not follow the live pane width"))))
         (cons "steps-select" (lambda () (etaf-ui-gallery-gui-search "etaf-steps") (etaf-ui-gui-activate "实现") (etaf-ui-gui-text "实现")))
         (cons "tag-dismiss" (lambda () (etaf-ui-gallery-gui-search "etaf-tag") (etaf-ui-gui-activate "Remove 草稿") (etaf-ui-gui-visible "Remove 草稿" nil) (etaf-ui-gui-visible "恢复标签" t)))
         (cons "list-select" (lambda () (etaf-ui-gallery-gui-search "etaf-list") (etaf-ui-gui-activate "组合界面") (etaf-ui-gui-text "当前选择：compose")))
         (cons "data-pagination" (lambda () (etaf-ui-gallery-gui-search "etaf-pagination") (etaf-ui-gui-activate "Next page") (etaf-ui-gui-text "第三项 · 第四项")))
         (cons "calendar-select" (lambda () (etaf-ui-gallery-gui-search "etaf-calendar") (etaf-ui-gui-text "October 2026") (etaf-ui-gui-activate "October 16") (etaf-ui-gui-selected "October 16")))
         (cons "tree-select" (lambda () (etaf-ui-gallery-gui-search "etaf-tree") (etaf-ui-gui-activate "基础控件") (etaf-ui-gui-text "当前节点：basic")))
         (cons "command-palette" (lambda () (etaf-ui-gallery-gui-search "etaf-command-palette") (etaf-ui-gui-activate "打开命令面板") (etaf-ui-gui-activate "新建项目") (etaf-ui-gui-text "已执行：new")))
         (cons "window-move-resize" #'etaf-ui-gallery-gui-window-gestures)
         (cons "tile-select" (lambda () (etaf-ui-gallery-gui-search "etaf-tile-grid") (etaf-ui-gui-activate "Cell 2,4") (etaf-ui-gui-text "选中第 3 行、第 5 列")))
         (cons "card-toggle" (lambda () (etaf-ui-gallery-gui-search "etaf-playing-card") (etaf-ui-gui-activate "A of hearts") (etaf-ui-gui-activate "A of hearts")))
         (cons "media-open-close" (lambda () (etaf-ui-gallery-gui-search "etaf-media-viewer") (etaf-ui-gui-activate "查看图片") (etaf-ui-gui-text "山与光") (etaf-ui-gui-key "<escape>") (etaf-ui-gui-focused "查看图片")))
         (cons "usage-copy" (lambda () (etaf-ui-gallery-gui-search "etaf-checkbox") (etaf-ui-gui-activate "查看用法：etaf-checkbox") (let ((interprogram-cut-function nil)) (etaf-ui-gui-reveal "复制示例：etaf-checkbox") (etaf-ui-gui-activate "复制示例：etaf-checkbox")) (etaf-ui-gui-expect (string-match-p "require 'etaf-ui" (current-kill 0 t)) "Missing runnable example")))
         (cons "usage-reference"
               (lambda ()
                 (etaf-scroll-into-view (etaf-ui-gui-runtime) 'gallery-reference-etaf-checkbox 'start)
                 (etaf-ui-gui-text "参数与默认值")
                 (etaf-ui-gui-text "next-boolean")
                 (etaf-ui-gui-text "even nil")
                 (etaf-ui-gui-reveal "接收通知")))
         (cons "theme-retains-state" (lambda () (etaf-ui-gui-activate "深色") (etaf-ui-gui-text "接收通知 = t") (etaf-ui-gui-activate "浅色")))
         (cons "reset-state-and-code" (lambda () (etaf-ui-gui-activate "重置示例") (etaf-ui-gui-text "接收通知 = nil") (etaf-ui-gui-visible "复制示例：etaf-checkbox" nil)))
         (cons "mouse-drawer-open" (lambda () (etaf-ui-gallery-gui-search "etaf-drawer") (etaf-ui-gui-mouse "展开抽屉") (etaf-ui-gui-text "组件详情")))
         (cons "mouse-drawer-close" (lambda () (etaf-ui-gui-mouse "关闭抽屉") (etaf-ui-gui-focused "展开抽屉")))
         (cons "overview-return" (lambda () (etaf-ui-gallery-gui-search "") (etaf-ui-gui-text "组件总览")))))
  (switch-to-buffer (get-buffer-create etaf-ui-gui-buffer))
  (run-at-time 0.1 nil #'etaf-ui-gui-next-step)
  'scheduled)

(defvar etaf-ui-gui-font-baseline nil)
(defvar etaf-ui-gui-font-samples nil)
(defvar etaf-ui-gui-font-tail-line nil)

(defun etaf-ui-gui-font-row-check (label &optional initialize)
  "Check physical row heights and the unchanged neighboring tail at LABEL.
INITIALIZE records the inherited reference row and tail position."
  (let* ((runtime (etaf-ui-gui-runtime))
         (window (selected-window))
         (reference (etaf-host-ref-position runtime 'font-reference))
         (tail (if initialize
                   (etaf-host-ref-position runtime 'font-tail)
                 (save-excursion
                   (goto-char (point-min))
                   (forward-line (1- etaf-ui-gui-font-tail-line))
                   (point))))
         reference-height tail-y heights)
    (redisplay t)
    (save-excursion
      (goto-char reference)
      (setq reference-height (line-pixel-height))
      (setq tail-y (cdr (posn-x-y (or (posn-at-point tail window)
                                     (error "Font fixture tail is offscreen")))))
      (goto-char (window-start window))
      (while (and (< (point) (point-max))
                  (pos-visible-in-window-p (point) window))
        (push (line-pixel-height) heights)
        (forward-line 1)))
    (when initialize
      (setq etaf-ui-gui-font-baseline (cons reference-height tail-y)
            etaf-ui-gui-font-tail-line (line-number-at-pos tail)))
    (etaf-ui-gui-expect etaf-ui-gui-font-baseline "Missing font row baseline")
    (etaf-ui-gui-expect
     (cl-every (lambda (height) (<= height (car etaf-ui-gui-font-baseline))) heights)
     "Control glyph expanded a physical row: standard=%s observed=%S"
     (car etaf-ui-gui-font-baseline) (delete-dups (copy-sequence heights)))
    (etaf-ui-gui-expect (= tail-y (cdr etaf-ui-gui-font-baseline))
                        "Unchanged neighboring tail moved: %s -> %s"
                        (cdr etaf-ui-gui-font-baseline) tail-y)
    (push (list label :row-heights (delete-dups heights) :tail-y tail-y)
          etaf-ui-gui-font-samples)))

;;;###autoload
(defun etaf-ui-font-gui-interactions-start ()
  "Verify native control markers on the configured Emacs physical row grid."
  (unless (display-graphic-p) (user-error "Font checks require a graphical frame"))
  (when (active-minibuffer-window) (user-error "Finish the active minibuffer first"))
  (setq etaf-ui-gui-buffer "*ETAF UI Font Acceptance*"
        etaf-ui-gui-interactions nil
        etaf-ui-gui-font-baseline nil
        etaf-ui-gui-font-tail-line nil
        etaf-ui-gui-font-samples nil)
  (when-let* ((runtime (etaf-runtime-for-buffer etaf-ui-gui-buffer)))
    (etaf-unmount runtime))
  (let ((checked (etaf-ref nil)) (enabled (etaf-ref nil))
        (radio (etaf-ref 'one)) (choice (etaf-ref 'one))
        (tab (etaf-ref 'one)) (dialog (etaf-ref nil)))
    (setq etaf-ui-gui-steps
          (list
           (cons "font-mount"
                 (lambda ()
                   (etaf-mount
                    etaf-ui-gui-buffer
                    (etaf-view
                     (column :width '(vw 100) :height '(vh 100)
                             :background-color (etaf-theme-token :ui-bg "#FFFDF8")
                             :color (etaf-theme-token :ui-fg "#21252B")
                       (etaf-label :ref 'font-reference :text "Standard row")
                       (etaf-checkbox :bind checked :label "Checkbox")
                       (etaf-switch :bind enabled :label "Switch")
                       (etaf-radio :bind radio :label "Radio"
                                   :options '((one . "One") (two . "Two")))
                       (etaf-select :bind choice :label "Select" :presentation 'dropdown
                                    :options '((one . "First choice") (two . "Second choice")))
                       (etaf-tabs :active tab :items '((:key one :label "First tab")
                                                       (:key two :label "Second tab"))
                                  :on-change (lambda (next) (etaf-set-value tab next)))
                       (etaf-button :label "Open dialog"
                                    :on-press (lambda () (etaf-set-value dialog t)))
                       (etaf-label :ref 'font-tail :text "Unchanged neighboring row")
                       (etaf-dialog :open dialog :title "Standard title"
                                    :width '(ch 40) :height '(lh 6) :backdrop nil
                                    :on-close (lambda () (etaf-set-value dialog nil))
                         (etaf-label :text "Standard body")))))
                   (etaf-ui-gui-font-row-check "mount" t)))
           (cons "font-checkbox-keyboard"
                 (lambda () (etaf-ui-gui-activate "Checkbox")
                   (etaf-ui-gui-text "[x] Checkbox")
                   (etaf-ui-gui-font-row-check "checkbox-keyboard")))
           (cons "font-checkbox-mouse"
                 (lambda () (etaf-ui-gui-mouse "Checkbox")
                   (etaf-ui-gui-text "[ ] Checkbox")
                   (etaf-ui-gui-font-row-check "checkbox-mouse")))
           (cons "font-switch"
                 (lambda () (etaf-ui-gui-activate "Switch")
                   (etaf-ui-gui-text "[x] Switch")
                   (etaf-ui-gui-font-row-check "switch")))
           (cons "font-radio"
                 (lambda () (etaf-ui-gui-activate "Two")
                   (etaf-ui-gui-text "(o) Two")
                   (etaf-ui-gui-font-row-check "radio")))
           (cons "font-select-open"
                 (lambda () (etaf-ui-gui-activate "Select")
                   (etaf-ui-gui-selected "First choice")
                   (etaf-ui-gui-font-row-check "select-open")))
           (cons "font-select-choice"
                 (lambda () (etaf-ui-gui-activate "Second choice")
                   (etaf-ui-gui-text "Second choice")
                   (etaf-ui-gui-font-row-check "select-choice")))
           (cons "font-tab"
                 (lambda () (etaf-ui-gui-activate "Second tab")
                   (etaf-ui-gui-selected "Second tab")
                   (etaf-ui-gui-font-row-check "tab")))
           (cons "font-dialog-open"
                 (lambda () (etaf-ui-gui-activate "Open dialog")
                   (etaf-ui-gui-text "Standard title")
                   (etaf-ui-gui-font-row-check "dialog-open")))
           (cons "font-dialog-close"
                 (lambda () (etaf-ui-gui-activate "Close")
                   (etaf-ui-gui-font-row-check "dialog-close"))))))
  (switch-to-buffer (get-buffer-create etaf-ui-gui-buffer))
  (run-at-time 0.1 nil #'etaf-ui-gui-next-step)
  'scheduled)
