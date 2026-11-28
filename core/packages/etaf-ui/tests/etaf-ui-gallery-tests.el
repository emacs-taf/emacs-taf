;;; -*- lexical-binding: t; -*-
;;; etaf-ui-gallery-tests.el --- Public component-gallery workflows

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-ui)

(defun etaf-ui-gallery-test--activate (runtime label)
  "Activate the public control named LABEL in RUNTIME."
  (let* ((entry (cl-find-if (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
                            (etaf-runtime-host-props-entries runtime)))
         (ref (car entry)))
    (unless ref (error "No Gallery control named %s" label))
    (etaf-scroll-into-view runtime ref)
    (etaf-focus runtime ref)
    (etaf-activate runtime)))

(defun etaf-ui-gallery-test--text (buffer)
  "Read BUFFER without its live display properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defmacro etaf-ui-gallery-test--with (bindings &rest body)
  "Mount one isolated wide Gallery using BINDINGS and run BODY."
  (declare (indent 1))
  `(let* ((,(car bindings) (etaf-ui-gallery-open (generate-new-buffer " *Gallery test*")))
          (,(cadr bindings) (etaf-runtime-for-buffer ,(car bindings))))
     (unwind-protect
         (with-current-buffer ,(car bindings)
           (etaf-runtime-refit ,(cadr bindings) (* 160 (frame-char-width)) 80)
           ,@body)
       (when (buffer-live-p ,(car bindings))
         (when (etaf-runtime-for-buffer ,(car bindings)) (etaf-unmount ,(cadr bindings)))
         (kill-buffer ,(car bindings))))))

(ert-deftest etaf-ui-gallery-browses-every-component-family ()
  "Every category opens and exposes individually named component specimens."
  (etaf-ui-gallery-test--with (buffer runtime)
    (dolist (group '(("基础与操作" etaf-button etaf-label etaf-ui-icon etaf-ui-toggle-icon etaf-avatar etaf-kbd etaf-divider)
                     ("输入与选择" etaf-text-input etaf-checkbox etaf-select etaf-search-field etaf-number-input etaf-radio etaf-switch etaf-segmented etaf-slider etaf-range etaf-date-picker)
                     ("导航与结构" etaf-panel etaf-card etaf-tabs etaf-accordion etaf-breadcrumb etaf-steps etaf-splitter etaf-pane-resizer)
                     ("数据与集合" etaf-table etaf-data-grid etaf-pagination etaf-list etaf-tree etaf-calendar etaf-timeline)
                     ("状态与反馈" etaf-badge etaf-tag etaf-progress etaf-alert etaf-statistic etaf-empty etaf-skeleton etaf-reactions)
                     ("菜单与浮层" etaf-menu etaf-dropdown-menu etaf-context-menu etaf-popover etaf-dialog etaf-key-help etaf-tooltip etaf-toast etaf-drawer etaf-command-palette)
                     ("窗口与工作区" etaf-resizable-panel etaf-window-controls etaf-window-chrome etaf-window etaf-taskbar etaf-workspace-bar etaf-launcher etaf-switcher)
                     ("媒体与网格" etaf-media-viewer etaf-tile-grid etaf-text-grid etaf-playing-card)))
      (ert-info ((car group))
        (etaf-ui-gallery-test--activate runtime (car group))
        (let ((labels (mapcar (lambda (entry) (plist-get (cdr entry) :aria-label))
                             (etaf-runtime-host-props-entries runtime))))
          (dolist (component (cdr group))
            (should (member (concat "查看用法：" (symbol-name component)) labels))))))))

(ert-deftest etaf-ui-gallery-sidebar-selection-keeps-labels-stationary ()
  "Sidebar highlights preserve each label's position, size and typeface."
  (etaf-ui-gallery-test--with (buffer runtime)
    (let ((labels '("组件总览" "基础与操作" "输入与选择" "导航与结构"
                    "数据与集合" "状态与反馈" "菜单与浮层" "窗口与工作区" "媒体与网格")))
      (cl-labels
          ((layout ()
             (mapcar
              (lambda (label)
                (let* ((entry (cl-find-if
                               (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
                               (etaf-runtime-host-props-entries runtime)))
                       (bounds (etaf-host-ref-bounds runtime (car entry)))
                       (size (etaf-host-ref-size runtime (car entry))))
                  (save-excursion
                    (goto-char (car bounds))
                    (search-forward label (cdr bounds))
                    (list (- (current-column) (string-width label)) size
                          (plist-get (cdr entry) :font-weight)))))
              labels)))
        (let ((before (layout)))
          (dolist (palette '("深色" "浅色"))
            (etaf-ui-gallery-test--activate runtime palette)
            (dolist (label labels)
              (etaf-ui-gallery-test--activate runtime label)
              (let* ((after (layout))
                     (entry (cl-find-if
                             (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
                             (etaf-runtime-host-props-entries runtime)))
                     (props (cdr entry)))
                (should (equal before after))
                (should (plist-get props :aria-selected))
                (should (stringp (plist-get props :background-color)))
                (should-not (plist-get props :hover-style))))))))))

(ert-deftest etaf-ui-gallery-overview-keeps-preview-content-whole ()
  "Overview cards let multi-row previews grow instead of cropping their cells."
  (etaf-ui-gallery-test--with (buffer runtime)
    (dolist (columns '(200 160 100 80))
      (etaf-runtime-refit runtime (* columns (frame-char-width)) 80)
      (dolist (label '("林" "陈"))
        (let* ((entry (cl-find-if
                       (lambda (entry) (equal label (plist-get (cdr entry) :aria-label)))
                       (etaf-runtime-host-props-entries runtime)))
               (bounds (etaf-host-ref-bounds runtime (car entry)))
               (bottom-row (and bounds (line-number-at-pos (1- (cdr bounds)))))
               (caption-row (save-excursion
                              (goto-char (point-min))
                              (search-forward "Button · Label · Icon · Avatar · Kbd")
                              (line-number-at-pos))))
          (ert-info ((format "%s in %s columns" label columns))
            (should (< bottom-row caption-row))))))))

(ert-deftest etaf-ui-gallery-compact-picker-opens-component-families ()
  "The compact category picker reaches the same live specimens as the sidebar."
  (etaf-ui-gallery-test--with (buffer runtime)
    (etaf-runtime-refit runtime (* 80 (frame-char-width)) 30)
    (dolist (choice '(("菜单与浮层" . "查看用法：etaf-key-help")
                      ("基础与操作" . "查看用法：etaf-button")))
      (etaf-ui-gallery-test--activate runtime "组件分类")
      (etaf-ui-gallery-test--activate runtime (car choice))
      (let* ((labels (mapcar (lambda (entry) (plist-get (cdr entry) :aria-label))
                            (etaf-runtime-host-props-entries runtime)))
             (present (not (null (member (cdr choice) labels)))))
        (should present)))))

(ert-deftest etaf-ui-gallery-preserves-state-across-browsing-and-theme ()
  "State survives category changes and scoped Theme switches; reset restores it."
  (etaf-ui-gallery-test--with (buffer runtime)
    (etaf-ui-gallery-test--activate runtime "基础与操作")
    (etaf-ui-gallery-test--activate runtime "主要操作")
    (should (string-match-p "已点击 1 次" (etaf-ui-gallery-test--text buffer)))
    (etaf-ui-gallery-test--activate runtime "输入与选择")
    (etaf-ui-gallery-test--activate runtime "深色")
    (etaf-ui-gallery-test--activate runtime "基础与操作")
    (should (string-match-p "已点击 1 次" (etaf-ui-gallery-test--text buffer)))
    (etaf-ui-gallery-test--activate runtime "重置示例")
    (should (string-match-p "已点击 0 次" (etaf-ui-gallery-test--text buffer)))))

(ert-deftest etaf-ui-gallery-copies-runnable-examples ()
  "Copied examples are complete public-API programs, not display-only snippets."
  (let ((interprogram-cut-function nil) (kill-ring nil))
    (etaf-ui-gallery-test--with (buffer runtime)
      (dolist (group '("基础与操作" "输入与选择" "导航与结构" "数据与集合"
                       "状态与反馈" "菜单与浮层" "窗口与工作区" "媒体与网格"))
        (etaf-ui-gallery-test--activate runtime group)
        (let ((labels
               (delq nil (mapcar
                          (lambda (entry)
                            (let ((label (plist-get (cdr entry) :aria-label)))
                              (and (stringp label) (string-prefix-p "查看用法：" label) label)))
                          (etaf-runtime-host-props-entries runtime)))))
          (dolist (label labels)
            (ert-info (label)
              (etaf-ui-gallery-test--activate runtime label)
              (let* ((name (substring label (length "查看用法：")))
                     (reference (intern (concat "gallery-reference-" name))))
                (etaf-scroll-into-view runtime reference 'start)
                (let ((text (etaf-ui-gallery-test--text buffer)))
                  (should (string-match-p (regexp-quote (concat name " (&key")) text))
                  (should (string-match-p "参数与默认值" text))
                  (should (string-match-p "Host 透传契约" text))))
              (etaf-ui-gallery-test--activate runtime (concat "复制示例：" (substring label (length "查看用法："))))
              (let ((source (current-kill 0 t)))
                (should (string-prefix-p ";;; -*- lexical-binding: t; -*-" source))
                (unwind-protect
                    (save-window-excursion
                      (with-temp-buffer
                        (insert source)
                        (let ((lexical-binding t)) (eval-buffer)))
                      (let* ((example (get-buffer "*ETAF UI Example*"))
                             (mounted (and example (etaf-runtime-for-buffer example))))
                        (should (not (null mounted)))))
                  (when-let* ((example (get-buffer "*ETAF UI Example*")))
                    (when-let* ((mounted (etaf-runtime-for-buffer example))) (etaf-unmount mounted))
                    (kill-buffer example))))
              (etaf-ui-gallery-test--activate runtime label))))))))

(ert-deftest etaf-ui-gallery-isolates-mounts-and-unrelated-buffers ()
  "Two Galleries share no state; nonempty unrelated buffers are preserved."
  (etaf-ui-gallery-test--with (first runtime)
    (etaf-ui-gallery-test--activate runtime "基础与操作")
    (etaf-ui-gallery-test--activate runtime "主要操作")
    (etaf-ui-gallery-test--with (second other)
      (etaf-ui-gallery-test--activate other "基础与操作")
      (should (string-match-p "已点击 0 次" (etaf-ui-gallery-test--text second)))
      (should (string-match-p "已点击 1 次" (etaf-ui-gallery-test--text first))))
    (with-temp-buffer
      (insert "Keep my work")
      (should-error (etaf-ui-gallery-open (current-buffer)) :type 'user-error)
      (should (equal "Keep my work" (buffer-string))))))

(defun etaf-ui-gallery-test--type (runtime label text)
  "Replace the input LABEL in RUNTIME with TEXT through native editing."
  (etaf-ui-gallery-test--activate runtime label)
  (let ((active (etaf-text-input-active-p runtime))) (should active))
  (execute-kbd-macro (vconcat (kbd "C-a C-SPC C-e C-w") text (kbd "RET"))))

(ert-deftest etaf-ui-gallery-searches-symbols-chinese-and-clears-empty-results ()
  "Live search spans categories, accepts Chinese, and recovers from no matches."
  (save-window-excursion
    (etaf-ui-gallery-test--with (buffer runtime)
      (switch-to-buffer buffer)
      (etaf-ui-gallery-test--type runtime "搜索组件名称或用途" "ETAF-DATE-PICKER")
      (should (string-match-p "日期输入" (etaf-ui-gallery-test--text buffer)))
      (etaf-ui-gallery-test--type runtime "搜索组件名称或用途" "日期")
      (should (string-match-p "etaf-calendar" (etaf-ui-gallery-test--text buffer)))
      (etaf-ui-gallery-test--type runtime "搜索组件名称或用途" "no-such-component")
      (should (string-match-p "没有找到组件" (etaf-ui-gallery-test--text buffer)))
      (etaf-ui-gallery-test--activate runtime "清空搜索")
      (should (string-match-p "组件总览" (etaf-ui-gallery-test--text buffer)))
      (etaf-ui-gallery-test--activate runtime "浏览基础与操作")
      (etaf-ui-gallery-test--type runtime "搜索组件名称或用途" "etaf-dialog")
      (should (string-match-p "打开对话框" (etaf-ui-gallery-test--text buffer))))))

(ert-deftest etaf-ui-gallery-splitter-uses-its-live-pane-width ()
  "A divider gesture moves the example by the same pixels after resizing."
  (save-window-excursion
    (etaf-ui-gallery-test--with (buffer runtime)
      (switch-to-buffer buffer)
      (etaf-ui-gallery-test--type runtime "搜索组件名称或用途" "etaf-splitter")
      (cl-labels ((divider ()
                   (car (cl-find-if
                         (lambda (entry) (equal "Resize columns" (plist-get (cdr entry) :aria-label)))
                         (etaf-runtime-host-props-entries runtime))))
                  (x ()
                    (save-excursion
                      (goto-char (etaf-host-ref-position runtime (divider)))
                      (etaf-string-pixel-width
                       (buffer-substring (line-beginning-position) (point))))))
        (dolist (columns '(80 160 220))
          (etaf-runtime-refit runtime (* columns (frame-char-width)) 40)
          (etaf-ui-gallery-test--activate runtime "重置示例")
          (let* ((target (divider))
                 (before (x))
                 (width (car (etaf-host-ref-size runtime 'etaf-splitter)))
                 (delta (* 5 (frame-char-width))))
            (etaf-drag-step runtime target 5 0)
            (let ((moved (- (x) before)))
              (ert-info ((format "%s columns: expected %s px, moved %s" columns delta moved))
                ;; Splitter positions panes at whole percentage points.
                (should (<= (abs (- moved delta)) (1+ (/ width 100.0))))))))))))

(ert-deftest etaf-ui-gallery-reference-explains-value-and-callback-contracts ()
  "Scrolled reference text distinguishes defaults, units and callback payloads."
  (save-window-excursion
    (etaf-ui-gallery-test--with (buffer runtime)
      (switch-to-buffer buffer)
      (etaf-runtime-refit runtime (* 96 (frame-char-width)) 32)
      (dolist (case '(("etaf-checkbox" "next-boolean" "explicit :checked and :on-change, even nil")
                      ("etaf-number-input" "integer-or-nil" "in-place text field" "unbounded")
                      ("etaf-range" "functions (number)" "no :bind prop" "one twentieth")
                      ("etaf-accordion" "next-open-keys" "not (key)" "default t")
                      ("etaf-calendar" "default (2026 1)" "not the current month" "(year month day)")
                      ("etaf-splitter" "function (gesture)" "in pixels, not a ratio")))
        (etaf-ui-gallery-test--type runtime "搜索组件名称或用途" (car case))
        (etaf-ui-gallery-test--activate runtime (concat "查看用法：" (car case)))
        (etaf-scroll-into-view runtime (intern (concat "gallery-reference-" (car case))) 'start)
        (let (offset pages)
          (while (not (equal offset (etaf-scroll-offset runtime 'gallery-scroll)))
            (setq offset (etaf-scroll-offset runtime 'gallery-scroll))
            (push (etaf-ui-gallery-test--text buffer) pages)
            (etaf-scroll-by runtime 'gallery-scroll 12))
          ;; The panel paints vertical borders inside the scanned pages, so a
          ;; phrase that wraps crosses a box glyph as well as a newline.
          (let ((text (replace-regexp-in-string
                       "[ \t\n│]+" " " (string-join (nreverse pages) "\n")))
                (case-fold-search nil))
            (dolist (phrase (cdr case))
              (ert-info ((format "%s: %s" (car case) phrase))
                (should (string-match-p (regexp-quote phrase) text)))))))
      (etaf-ui-gallery-test--activate runtime "重置示例")
      (let* ((labels (mapcar (lambda (entry) (plist-get (cdr entry) :aria-label))
                            (etaf-runtime-host-props-entries runtime)))
             (copy-visible (member "复制示例：etaf-splitter" labels)))
        (should-not copy-visible)))))

(ert-deftest etaf-ui-gallery-dialog-submits-chinese-and-cancels ()
  "A specimen's modal accepts Chinese, submits once, and returns focus on cancel."
  (save-window-excursion
    (etaf-ui-gallery-test--with (buffer runtime)
      (switch-to-buffer buffer)
      (etaf-ui-gallery-test--type runtime "搜索组件名称或用途" "etaf-dialog")
      (etaf-ui-gallery-test--activate runtime "打开对话框")
      (etaf-ui-gallery-test--type runtime "示例项目名称" "中文创作计划")
      (etaf-ui-gallery-test--activate runtime "创建项目")
      (should (string-match-p "已创建：中文创作计划" (etaf-ui-gallery-test--text buffer)))
      (etaf-ui-gallery-test--activate runtime "打开对话框")
      (etaf-ui-gallery-test--activate runtime "取消")
      (let* ((focused (etaf-focused-host-ref runtime))
             (label (plist-get (etaf-runtime-host-props-for runtime focused) :aria-label)))
        (should (equal label "打开对话框")))
      (should (string-match-p "已创建：中文创作计划" (etaf-ui-gallery-test--text buffer))))))

(ert-deftest etaf-ui-gallery-paginates-and-reopens-after-unmount ()
  "Paging changes visible local data; reopening an unmounted Gallery resets it."
  (save-window-excursion
    (etaf-ui-gallery-test--with (buffer runtime)
      (switch-to-buffer buffer)
      (etaf-ui-gallery-test--type runtime "搜索组件名称或用途" "etaf-pagination")
      (etaf-ui-gallery-test--activate runtime "Next page")
      (should (string-match-p "第三项 · 第四项" (etaf-ui-gallery-test--text buffer)))
      (etaf-ui-gallery-test--activate runtime "重置示例")
      (should (string-match-p "第一项 · 第二项" (etaf-ui-gallery-test--text buffer)))
      (etaf-unmount runtime)
      (etaf-ui-gallery-open buffer)
      (setq runtime (etaf-runtime-for-buffer buffer))
      (should (string-match-p "组件总览" (etaf-ui-gallery-test--text buffer)))
      (etaf-unmount runtime)
      (etaf-mount buffer (etaf-view (etaf-label :text "Other application")))
      (setq runtime (etaf-runtime-for-buffer buffer))
      (should-error (etaf-ui-gallery-open buffer) :type 'user-error)
      (should (string-match-p "Other application" (etaf-ui-gallery-test--text buffer))))))

(provide 'etaf-ui-gallery-tests)
;;; etaf-ui-gallery-tests.el ends here
