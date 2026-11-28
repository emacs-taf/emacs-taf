;;; etaf-export-ui.el --- Live vector export preview workspace and quick popup -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provides the interactive UI layer for `etaf-export':
;; 1. Live vector Export Preview workspace (`etaf-export--open-preview'), built
;;    on `etaf-app-open' (preserving the user's mode-line) with a centered live
;;    SVG paper preview on the left and reactive `etaf-segmented' controls on
;;    the right, collapsing cleanly to a single column on narrow windows and
;;    degrading gracefully to a structured layout card on text terminals.
;; 2. Compact reactive popup (`etaf-export--popup-view') used when opening the
;;    extension panel from `etaf-ext-manage', sharing persisted preferences and
;;    jumping cleanly into the full preview workspace.

;;; Code:

(require 'cl-lib)
(require 'image)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)
(require 'etaf-export-snapshot)
(require 'etaf-export-svg)
(require 'etaf-export-pdf)

(defvar etaf-export-default-page-mode)
(defvar etaf-export-default-theme)
(defvar etaf-export-page-numbers)
(defvar etaf-export-margin)
(defvar etaf-export-font-family)

(declare-function etaf-export-pdf "etaf-export")
(declare-function etaf-export-svg "etaf-export")
(declare-function etaf-posframe-refresh "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-live-p "etaf-posframe" (panel))

(defconst etaf-export--preview-buffer-name "*ETAF Export Preview*"
  "Buffer name for the interactive vector export preview workspace.")

(defconst etaf-export--pref-storage-key "prefs"
  "Isolated `etaf-ext' storage key for persisted export preferences.")

(defconst etaf-export--margin-presets '(16 28 40)
  "Standard margin presets in PDF points: compact, standard, relaxed.")

(defconst etaf-export--page-mode-ring '(a4 letter single)
  "Cycle order for interactive page-mode switching.")

(defun etaf-export--nearest-margin-preset (val)
  "Map numeric margin VAL to the closest preset in `etaf-export--margin-presets'."
  (let ((n (if (numberp val) (float val) 28.0)))
    (cond
     ((<= n 22.0) 16)
     ((>= n 34.0) 40)
     (t 28))))

(defun etaf-export--default-prefs ()
  "Return fresh export preferences plist derived from `defcustom' defaults."
  (list :page-mode (if (memq etaf-export-default-page-mode etaf-export--page-mode-ring)
                       etaf-export-default-page-mode
                     'a4)
        :theme (if (memq etaf-export-default-theme '(current light))
                   etaf-export-default-theme
                 'current)
        :margin (etaf-export--nearest-margin-preset etaf-export-margin)
        :page-numbers (and etaf-export-page-numbers t)))

(defun etaf-export--load-prefs (&optional ctx)
  "Load saved export preferences from CTX storage, falling back to defaults.
Must be called outside render (in commands or event handlers)."
  (let* ((base (etaf-export--default-prefs))
         (saved (when (and ctx (etaf-ext-context-p ctx))
                  (ignore-errors
                    (etaf-ext-storage-get ctx etaf-export--pref-storage-key nil)))))
    (if (and (listp saved) (keywordp (car saved)))
        (list :page-mode (let ((pm (plist-get saved :page-mode)))
                           (if (memq pm etaf-export--page-mode-ring)
                               pm
                             (plist-get base :page-mode)))
              :theme (let ((th (plist-get saved :theme)))
                       (if (memq th '(current light))
                           th
                         (plist-get base :theme)))
              :margin (etaf-export--nearest-margin-preset
                       (or (plist-get saved :margin) (plist-get base :margin)))
              :page-numbers (if (plist-member saved :page-numbers)
                                (and (plist-get saved :page-numbers) t)
                              (plist-get base :page-numbers)))
      base)))

(defun etaf-export--save-prefs (ctx prefs)
  "Persist PREFS to CTX storage when CTX is attached and live."
  (when (and ctx (etaf-ext-context-p ctx))
    (ignore-errors
      (etaf-ext-storage-set
       ctx etaf-export--pref-storage-key
       (list :page-mode (plist-get prefs :page-mode)
             :theme (plist-get prefs :theme)
             :margin (plist-get prefs :margin)
             :page-numbers (and (plist-get prefs :page-numbers) t))))))

(defun etaf-export--cycle-ring (cur ring)
  "Return the element after CUR in RING, wrapping to the head."
  (let ((tail (cdr (memq cur ring))))
    (or (car tail) (car ring))))

(defun etaf-export--page-mode-label (mode)
  "Return concise Chinese display label for pagination MODE."
  (pcase mode
    ('a4 "A4")
    ('letter "Letter")
    ('single "单页长图")
    (_ "A4")))

(defun etaf-export--theme-label (theme)
  "Return concise Chinese display label for export THEME."
  (pcase theme
    ('light "亮色打印")
    (_ "跟随主题")))

(defun etaf-export--notify-exported (ctx result)
  "Publish export completion notification with a quick open-file action."
  (let* ((fmt (upcase (symbol-name (or (plist-get result :format) 'pdf))))
         (pages (or (plist-get result :pages) 1))
         (file (plist-get result :file))
         (title (format "已导出 %s（%d 页）" fmt pages))
         (actions (when (and (stringp file) (not noninteractive))
                    (list (list :id 'open
                                :label "打开文件"
                                :fn (lambda () (etaf-export--open-file file)))))))
    (if (and ctx (etaf-ext-context-p ctx))
        (etaf-ext-notify ctx title :detail file :variant 'success :actions actions)
      (etaf-notify title :app 'etaf-export :detail file
                   :variant 'success :actions actions))))

;;;; Shared Themed Root Component

(etaf-define-component etaf-export--themed-root (&key theme render)
  "Root wrapper providing reactive THEME tokens to export UI subtrees."
  :setup (progn (etaf-theme-provide theme) nil)
  :render (etaf-view (expr (if (functionp render) (funcall render) render))))

;;;; Live Vector Export Preview Workspace

(defun etaf-export--preview-ensure-snapshot (session theme &optional force)
  "Return cached rendered snapshot for SESSION and THEME, capturing if needed."
  (let* ((rt (plist-get session :source-rt))
         (cache (plist-get session :snapshots))
         (hit (and (not force) (assq theme cache))))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (signal 'etaf-export-error (list "源 ETAF 页面已卸载，无法继续预览")))
    (if hit
        (cdr hit)
      (let ((snap (etaf-export--snapshot-runtime
                   rt :theme theme :font-family etaf-export-font-family)))
        (plist-put session :snapshots
                   (cons (cons theme snap)
                         (assq-delete-all theme (copy-alist cache))))
        snap))))

(defun etaf-export--preview-recompute (session &optional force-snap)
  "Recompute pagination and SVG pages for SESSION and publish into `:state-ref'."
  (let* ((state-ref (plist-get session :state-ref))
         (cur (etaf-value state-ref))
         (page-mode (plist-get cur :page-mode))
         (theme (plist-get cur :theme))
         (margin (plist-get cur :margin))
         (page-numbers (plist-get cur :page-numbers))
         (zoom (plist-get cur :zoom))
         (snap (etaf-export--preview-ensure-snapshot session theme force-snap))
         (rendered (etaf-export--render-svg-pages snap
                                                  :page-mode page-mode
                                                  :margin margin
                                                  :page-numbers page-numbers))
         (layout (plist-get rendered :layout))
         (svg-pages (plist-get rendered :svg-pages))
         (total (max 1 (length svg-pages)))
         (idx (max 1 (min total (or (plist-get cur :page-index) 1))))
         (doctor (etaf-export--doctor-report))
         (next (list :title (plist-get snap :title)
                     :page-mode page-mode
                     :theme theme
                     :margin margin
                     :page-numbers page-numbers
                     :zoom zoom
                     :page-index idx
                     :total-pages total
                     :layout layout
                     :svg-pages svg-pages
                     :lines (plist-get snap :line-count)
                     :images (length (plist-get snap :images))
                     :snap-lines (plist-get snap :lines)
                     :rsvg-ok (and (plist-get doctor :ready) t))))
    ;; Drop composed preview descriptor cache when page content changes
    (clrhash (plist-get session :desc-cache))
    (etaf-set-value state-ref next)
    next))

(defun etaf-export--preview-update (session key value)
  "Update preview option KEY to VALUE on SESSION, persisting and refreshing."
  (let* ((state-ref (plist-get session :state-ref))
         (cur (copy-sequence (etaf-value state-ref))))
    (setq cur (plist-put cur key value))
    (when (memq key '(:page-mode :margin))
      (setq cur (plist-put cur :page-index 1)))
    (etaf-set-value state-ref cur)
    (when (memq key '(:page-mode :theme :margin :page-numbers))
      (etaf-export--save-prefs (plist-get session :ctx) cur))
    (if (memq key '(:page-index :zoom))
        cur
      (etaf-export--preview-recompute session nil))))

(defun etaf-export--preview-step-page (session delta)
  "Move preview page index by DELTA within bounds."
  (let* ((cur (etaf-value (plist-get session :state-ref)))
         (idx (or (plist-get cur :page-index) 1))
         (total (max 1 (or (plist-get cur :total-pages) 1)))
         (next (max 1 (min total (+ idx delta)))))
    (when (/= next idx)
      (etaf-export--preview-update session :page-index next))))

(defun etaf-export--preview-export (session format)
  "Prompt for destination path and export SESSION's current settings in FORMAT."
  (let* ((rt (plist-get session :source-rt))
         (ctx (plist-get session :ctx))
         (st (etaf-value (plist-get session :state-ref)))
         (ext (if (eq format 'svg) "svg" "pdf")))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (user-error "源 ETAF 页面已关闭，无法导出"))
    (when (and (eq format 'pdf) (not (plist-get st :rsvg-ok)))
      (user-error "未检测到 rsvg-convert，请先安装：%s" (etaf-export--rsvg-install-hint)))
    (let* ((dest (etaf-export--prompt-output-path rt ext))
           (res (if (eq format 'svg)
                    (etaf-export-svg dest
                                     :runtime rt
                                     :page-mode (plist-get st :page-mode)
                                     :theme (plist-get st :theme)
                                     :page-numbers (plist-get st :page-numbers)
                                     :margin (plist-get st :margin))
                  (etaf-export-pdf dest
                                   :runtime rt
                                   :page-mode (plist-get st :page-mode)
                                   :theme (plist-get st :theme)
                                   :page-numbers (plist-get st :page-numbers)
                                   :margin (plist-get st :margin)))))
      (etaf-export--notify-exported ctx res)
      res)))

(defun etaf-export--preview-close (session)
  "Close the export preview workspace and return to the source buffer."
  (let ((src-buf (plist-get session :source-buf))
        (pbuf (get-buffer etaf-export--preview-buffer-name)))
    (when (and pbuf (etaf-app-buffer etaf-export--preview-buffer-name))
      (etaf-app-close pbuf))
    (when (and (buffer-live-p src-buf) (not noninteractive))
      (let ((win (get-buffer-window src-buf t)))
        (if win
            (select-window win)
          (switch-to-buffer src-buf))))))

(defun etaf-export--preview-text-lines (snap-lines start-row end-row max-lines max-cols)
  "Extract up to MAX-LINES readable preview strings for TTY fallback."
  (let ((vec (vconcat snap-lines))
        (out nil)
        (n (length snap-lines)))
    (cl-loop for i from (max 0 start-row) below (min n end-row)
             while (< (length out) max-lines)
             for ln = (aref vec i)
             for text = (mapconcat
                         (lambda (r)
                           (pcase (plist-get r :kind)
                             ('text (or (plist-get r :text) ""))
                             ('image "[矢量图/图像]")
                             ('space " ")
                             (_ "")))
                         (plist-get ln :runs) "")
             for trimmed = (string-trim-right text)
             when (not (string-empty-p (string-trim trimmed)))
             do (push (truncate-string-to-width trimmed max-cols nil nil "…") out))
    (or (nreverse out) '("（本页无可见文本行）"))))

(defun etaf-export--preview-stage-view (session st vp theme wide-p short-p)
  "Build the left/main vector paper preview stage View."
  (let* ((desk-bg (plist-get theme :ext-surface2))
         (panel-bg (plist-get theme :ext-panel))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (border (plist-get theme :ext-border))
         (dark (eq (plist-get theme :ext-mode) 'dark))
         (shadow (if dark "#000000" "#0f172a"))
         (cols (or (plist-get vp :cols) 110))
         (rows (or (plist-get vp :rows) 36))
         (cw (max 1 (or (plist-get vp :cw) 8)))
         (lh (max 1 (or (plist-get vp :lh) 18)))
         (idx (or (plist-get st :page-index) 1))
         (total (max 1 (or (plist-get st :total-pages) 1)))
         (layout (plist-get st :layout))
         (pages (plist-get layout :pages))
         (page-meta (nth (1- idx) pages))
         (page-svg (nth (1- idx) (plist-get st :svg-pages)))
         (page-w (float (or (plist-get layout :page-w) 595.28)))
         (page-h (float (or (and page-meta (plist-get page-meta :page-h))
                            (plist-get layout :page-h) 841.89)))
         (page-mode (plist-get st :page-mode))
         (theme-opt (plist-get st :theme))
         (zoom (or (plist-get st :zoom) 'fit-page))
         (stage-cols (max 24 (if wide-p (- cols 36 4) (- cols 4))))
         (chrome-rows (+ (if wide-p 4 10) (if short-p 1 3)))
         (stage-rows (max 10 (- rows chrome-rows)))
         (graphic-svg (and (display-graphic-p)
                           (fboundp 'image-type-available-p)
                           (image-type-available-p 'svg)
                           (stringp page-svg)))
         (caption (format "第 %d / %d 页 · %s（%d × %d pt）· %s"
                          idx total
                          (etaf-export--page-mode-label page-mode)
                          (round page-w) (round page-h)
                          (etaf-export--theme-label theme-opt))))
    (etaf-node
     'column
     (list :flex-basis (if wide-p '(ch 0) 'auto)
           :flex-grow (if wide-p 1 0)
           :width (if wide-p 'auto 'stretch)
           :background-color desk-bg
           :padding '((lh 1) (ch 2))
           :item-gap '(lh 0)
           :cross-align 'center)
     (delq
      nil
      (list
       (if graphic-svg
           (let* ((img-cols stage-cols)
                  (img-rows (if (eq zoom 'fit-width)
                                (let* ((sw (* img-cols cw))
                                       (pad-x (min 14.0 (* sw 0.04)))
                                       (avail-w (max 24.0 (- sw (* 2.0 pad-x))))
                                       (need-h (+ (* avail-w (/ page-h page-w)) 24.0)))
                                  (max stage-rows
                                       (min 240 (ceiling (/ need-h (float lh))))))
                              stage-rows))
                  (stage-w (* img-cols cw))
                  (stage-h (* img-rows lh))
                  (cache-key (list idx page-mode theme-opt
                                   (plist-get st :margin)
                                   (plist-get st :page-numbers)
                                   stage-w stage-h desk-bg border))
                  (desc-cache (plist-get session :desc-cache))
                  (desc (or (gethash cache-key desc-cache)
                            (progn
                              (when (>= (hash-table-count desc-cache) 16)
                                (clrhash desc-cache))
                              (puthash cache-key
                                       (etaf-export--preview-svg-descriptor
                                        page-svg page-w page-h
                                        stage-w stage-h
                                        desk-bg border shadow)
                                       desc-cache)))))
             (etaf-node 'image
                        (list :src desc :columns img-cols :rows img-rows)
                        nil))
         ;; Text-terminal / headless structured paper wireframe fallback
         (let* ((sr (or (and page-meta (plist-get page-meta :start-row)) 0))
                (er (or (and page-meta (plist-get page-meta :end-row)) 0))
                (card-w (max 28 (min 64 (- stage-cols 2))))
                (preview-lines (etaf-export--preview-text-lines
                                (plist-get st :snap-lines)
                                sr er (max 4 (- stage-rows 6)) (- card-w 6))))
           (etaf-node
            'column
            (list :width (list 'ch card-w)
                  :background-color panel-bg
                  :border (list '(px 1) 'solid border)
                  :padding '((lh 1) (ch 2))
                  :item-gap '(lh 0))
            (append
             (list
              (etaf-node 'text (list :color fg :font-weight 'bold)
                         (list (format "纸张预览（第 %d / %d 页）" idx total)))
              (etaf-node 'text (list :color muted)
                         (list (format "%s · %d × %d pt · 边距 %d pt · 行 %d–%d"
                                       (etaf-export--page-mode-label page-mode)
                                       (round page-w) (round page-h)
                                       (or (plist-get st :margin) 28)
                                       (1+ sr) (max (1+ sr) er))))
              (etaf-view (etaf-divider :orientation 'horizontal)))
             (mapcar (lambda (line-str)
                       (etaf-node 'text (list :color fg) (list line-str)))
                     preview-lines)))))
       (unless short-p
         (etaf-node 'box '(:padding-top (lh 1))
                    (list (etaf-node 'text (list :color muted) (list caption))))))))))

(defun etaf-export--preview-controls-view (session st theme wide-p short-p)
  "Build the right inspector sidebar (or compact top strip) View."
  (let* ((panel-bg (plist-get theme :ext-panel))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (border (plist-get theme :ext-border))
         (danger (plist-get theme :ext-danger))
         (danger-bg (plist-get theme :ext-danger-soft))
         (page-mode (plist-get st :page-mode))
         (theme-opt (plist-get st :theme))
         (margin (plist-get st :margin))
         (page-nums (plist-get st :page-numbers))
         (total (max 1 (or (plist-get st :total-pages) 1)))
         (lines (or (plist-get st :lines) 0))
         (imgs (or (plist-get st :images) 0))
         (layout (plist-get st :layout))
         (pw (round (or (plist-get layout :page-w) 595.28)))
         (ph (round (or (plist-get layout :page-h) 841.89)))
         (rsvg-ok (plist-get st :rsvg-ok))
         (single-p (eq page-mode 'single)))
    (if wide-p
        ;; Wide right inspector sidebar (36 ch fixed; compact single-row controls on short windows)
        (let ((ctrl-row
               (lambda (label short-label seg-view)
                 (if short-p
                     (etaf-node
                      'flex '(:width stretch :align-items center :gap ((lh 0) (ch 1)))
                      (list (etaf-node 'text (list :color muted) (list short-label))
                            seg-view))
                   (etaf-node
                    'column '(:width stretch :item-gap (lh 0))
                    (list (etaf-node 'text (list :color muted) (list label))
                          seg-view))))))
          (etaf-node
           'column
           (list :width '(ch 36) :flex-shrink 0
                 :background-color panel-bg
                 :border-left (list '(px 1) 'solid border)
                 :padding '((lh 1) (ch 2))
                 :item-gap (if short-p '(lh 0) '(lh 1)))
           (delq
            nil
            (list
             ;; Header + page count badge + stats
             (etaf-node
              'column '(:width stretch :item-gap (lh 0))
              (delq
               nil
               (list
                (etaf-node
                 'flex '(:width stretch :justify-content space-between :align-items center)
                 (list
                  (etaf-node 'text (list :color fg :font-weight 'bold) '("导出设置"))
                  (etaf-view
                   (etaf-badge
                    :text (if rsvg-ok (format "共 %d 页" total) "缺 rsvg-convert")
                    :variant (if rsvg-ok 'info 'danger)))))
                (unless short-p
                  (etaf-node 'text (list :color muted)
                             (list (format "%d 行 · %d 图 · %d×%d pt" lines imgs pw ph)))))))
             (etaf-view (etaf-divider :orientation 'horizontal))
             ;; 1. Page Mode
             (funcall ctrl-row "分页模式 (m)" "分页"
                      (etaf-view
                       (etaf-segmented
                        :value page-mode
                        :options '((a4 . "A4") (letter . "Letter") (single . "单页"))
                        :on-change (lambda (v) (etaf-export--preview-update session :page-mode v)))))
             ;; 2. Theme
             (funcall ctrl-row "导出配色 (t)" "配色"
                      (etaf-view
                       (etaf-segmented
                        :value theme-opt
                        :options '((current . "跟随主题") (light . "亮色打印"))
                        :on-change (lambda (v) (etaf-export--preview-update session :theme v)))))
             ;; 3. Margin
             (funcall ctrl-row "页边距 (b)" "边距"
                      (etaf-view
                       (etaf-segmented
                        :value margin
                        :options '((16 . "紧凑") (28 . "标准") (40 . "宽松"))
                        :on-change (lambda (v) (etaf-export--preview-update session :margin v)))))
             ;; 4. Page numbers
             (funcall ctrl-row
                      (if single-p "页脚页码（单页无页码）" "页脚页码 (#)")
                      "页码"
                      (etaf-view
                       (etaf-segmented
                        :value page-nums
                        :disabled single-p
                        :options '((t . "显示") (nil . "隐藏"))
                        :on-change (lambda (v) (etaf-export--preview-update session :page-numbers v)))))
             ;; Optional missing rsvg-convert banner
             (unless rsvg-ok
               (etaf-node
                'box (list :width 'stretch :background-color danger-bg
                           :padding '((lh 0) (ch 1)))
                (list (etaf-node
                       'text (list :color danger)
                       (list (format "缺 rsvg-convert，PDF 需安装：%s"
                                     (etaf-export--rsvg-install-hint)))))))
             (etaf-view (etaf-divider :orientation 'horizontal))
             ;; Actions (side-by-side on short windows so all controls stay visible)
             (if short-p
                 (etaf-node
                  'flex '(:width stretch :align-items center :gap ((lh 0) (ch 1))
                          :padding-top (lh 1))
                  (list
                   (etaf-view
                    (etaf-button
                     :label "导出 PDF" :variant 'primary
                     :disabled (not rsvg-ok)
                     :pointer (when rsvg-ok 'hand)
                     :on-press (lambda () (etaf-export--preview-export session 'pdf))))
                   (etaf-view
                    (etaf-button
                     :label "导出 SVG" :variant 'secondary :pointer 'hand
                     :on-press (lambda () (etaf-export--preview-export session 'svg))))
                   (etaf-view
                    (etaf-button
                     :label "重采" :variant 'ghost :pointer 'hand
                     :on-press (lambda () (etaf-export--preview-recompute session t))))))
               (etaf-node
                'column '(:width stretch :item-gap (lh 1))
                (list
                 (etaf-view
                  (etaf-button
                   :label "导出 PDF (e)" :variant 'primary
                   :disabled (not rsvg-ok)
                   :pointer (when rsvg-ok 'hand)
                   :on-press (lambda () (etaf-export--preview-export session 'pdf))))
                 (etaf-view
                  (etaf-button
                   :label "导出 SVG (s)" :variant 'secondary :pointer 'hand
                   :on-press (lambda () (etaf-export--preview-export session 'svg))))
                 (etaf-view
                  (etaf-button
                   :label "重新采集页面 (g)" :variant 'ghost :pointer 'hand
                   :on-press (lambda () (etaf-export--preview-recompute session t)))))))))))
      ;; Narrow compact top controls strip
      (etaf-node
       'column
       (list :width 'stretch :background-color panel-bg
             :border-bottom (list '(px 1) 'solid border)
             :padding '((lh 1) (ch 2))
             :item-gap '(lh 0))
       (delq
        nil
        (list
         (etaf-node
          'flex '(:width stretch :align-items center :gap ((lh 0) (ch 2)) :flex-wrap wrap)
          (list
           (etaf-node 'flex '(:align-items center :gap ((lh 0) (ch 1)))
                      (list
                       (etaf-node 'text (list :color muted) '("分页"))
                       (etaf-view
                        (etaf-segmented
                         :value page-mode
                         :options '((a4 . "A4") (letter . "Letter") (single . "单页"))
                         :on-change (lambda (v) (etaf-export--preview-update session :page-mode v))))))
           (etaf-node 'flex '(:align-items center :gap ((lh 0) (ch 1)))
                      (list
                       (etaf-node 'text (list :color muted) '("配色"))
                       (etaf-view
                        (etaf-segmented
                         :value theme-opt
                         :options '((current . "跟随主题") (light . "亮色打印"))
                         :on-change (lambda (v) (etaf-export--preview-update session :theme v))))))))
         (etaf-node
          'flex '(:width stretch :justify-content space-between :align-items center
                  :gap ((lh 0) (ch 1)) :padding-top (lh 1))
          (list
           (etaf-node 'flex '(:align-items center :gap ((lh 0) (ch 1)))
                      (list
                       (etaf-node 'text (list :color muted) '("边距"))
                       (etaf-view
                        (etaf-segmented
                         :value margin
                         :options '((16 . "紧凑") (28 . "标准") (40 . "宽松"))
                         :on-change (lambda (v) (etaf-export--preview-update session :margin v))))))
           (etaf-node 'flex '(:align-items center :gap ((lh 0) (ch 1)))
                      (list
                       (etaf-view
                        (etaf-button
                         :label "导出 SVG" :variant 'secondary :pointer 'hand
                         :on-press (lambda () (etaf-export--preview-export session 'svg))))
                       (etaf-view
                        (etaf-button
                         :label "导出 PDF" :variant 'primary
                         :disabled (not rsvg-ok)
                         :pointer (when rsvg-ok 'hand)
                         :on-press (lambda () (etaf-export--preview-export session 'pdf))))))))))))))

(etaf-define-component etaf-export--preview-component (&key session)
  "Reactive root component for the live vector Export Preview workspace."
  :render
  (let* ((st (etaf-value (plist-get session :state-ref)))
         (vp (etaf-value (plist-get session :viewport-ref)))
         (theme (etaf-value (plist-get session :theme-ref)))
         (cols (or (plist-get vp :cols) 110))
         (rows (or (plist-get vp :rows) 36))
         (wide-p (>= cols 92))
         (short-p (< rows 26))
         (panel-bg (plist-get theme :ext-panel))
         (bg (plist-get theme :ext-canvas))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (border (plist-get theme :ext-border))
         (idx (or (plist-get st :page-index) 1))
         (total (max 1 (or (plist-get st :total-pages) 1)))
         (zoom (or (plist-get st :zoom) 'fit-page))
         (title-max (max 12 (- cols 46)))
         (title (truncate-string-to-width (or (plist-get st :title) "未命名页面")
                                          title-max nil nil "…"))
         (can-prev (> idx 1))
         (can-next (< idx total))
         (do-close (lambda () (etaf-export--preview-close session)))
         (do-prev (lambda () (etaf-export--preview-step-page session -1)))
         (do-next (lambda () (etaf-export--preview-step-page session 1)))
         (do-zoom (lambda ()
                    (etaf-export--preview-update
                     session :zoom (if (eq zoom 'fit-page) 'fit-width 'fit-page))))
         (do-cycle-mode (lambda ()
                          (etaf-export--preview-update
                           session :page-mode
                           (etaf-export--cycle-ring
                            (plist-get st :page-mode) etaf-export--page-mode-ring))))
         (do-toggle-theme (lambda ()
                            (etaf-export--preview-update
                             session :theme
                             (if (eq (plist-get st :theme) 'current) 'light 'current))))
         (do-cycle-margin (lambda ()
                            (etaf-export--preview-update
                             session :margin
                             (etaf-export--cycle-ring
                              (plist-get st :margin) etaf-export--margin-presets))))
         (do-toggle-nums (lambda ()
                           (unless (eq (plist-get st :page-mode) 'single)
                             (etaf-export--preview-update
                              session :page-numbers
                              (not (plist-get st :page-numbers)))))))
    (etaf-node
     'column
     (list :width 'stretch
           :background-color bg
           :color fg
           :item-gap '(lh 0)
           :on-dismiss do-close
           :keys (list (list "n" do-next "下一页")
                       (list "]" do-next "下一页")
                       (list "p" do-prev "上一页")
                       (list "[" do-prev "上一页")
                       (list "z" do-zoom "切换整页/适宽")
                       (list "m" do-cycle-mode "切换分页模式")
                       (list "t" do-toggle-theme "切换导出配色")
                       (list "b" do-cycle-margin "切换页边距")
                       (list "#" do-toggle-nums "开关页脚页码")
                       (list "e" (lambda () (etaf-export--preview-export session 'pdf)) "导出 PDF")
                       (list "s" (lambda () (etaf-export--preview-export session 'svg)) "导出 SVG")
                       (list "g" (lambda () (etaf-export--preview-recompute session t)) "重新采集页面")
                       (list "q" do-close "关闭预览")))
     (delq
      nil
      (list
       ;; Top Header Bar (left-anchored title, right-anchored stable controls)
       (etaf-node
        'flex
        (list :width 'stretch :justify-content 'space-between :align-items 'center
              :background-color panel-bg
              :border-bottom (list '(px 1) 'solid border)
              :padding '((lh 0) (ch 2))
              :gap '((lh 0) (ch 2)))
        (list
         (etaf-node
          'flex '(:flex-basis (ch 0) :flex-grow 1 :align-items center :gap ((lh 0) (ch 2)))
          (list
           (etaf-node 'text (list :color fg :font-weight 'bold) '("导出预览"))
           (etaf-node 'text (list :color muted) (list title))))
         (etaf-node
          'flex '(:flex-shrink 0 :align-items center :gap ((lh 0) (ch 1)))
          (list
           (etaf-view
            (etaf-button :label "‹ 上页" :variant 'ghost
                         :disabled (not can-prev)
                         :pointer (when can-prev 'hand)
                         :on-press do-prev))
           (etaf-node 'text (list :color fg :font-weight 'bold)
                      (list (format "%d / %d" idx total)))
           (etaf-view
            (etaf-button :label "下页 ›" :variant 'ghost
                         :disabled (not can-next)
                         :pointer (when can-next 'hand)
                         :on-press do-next))
           (etaf-view
            (etaf-button :label (if (eq zoom 'fit-page) "整页 z" "适宽 z")
                         :variant 'secondary :pointer 'hand
                         :on-press do-zoom))
           (etaf-view
            (etaf-button :label "[×]" :variant 'ghost :pointer 'hand
                         :color muted :padding '((lh 0) (ch 0))
                         :on-press do-close))))))
       ;; Main Body (wide split row vs narrow vertical stack)
       (if wide-p
           (etaf-node
            'flex '(:width stretch :align-items stretch :gap ((lh 0) (ch 0)))
            (list
             (etaf-export--preview-stage-view session st vp theme t short-p)
             (etaf-export--preview-controls-view session st theme t short-p)))
         (etaf-node
          'column '(:width stretch :item-gap (lh 0))
          (list
           (etaf-export--preview-controls-view session st theme nil short-p)
           (etaf-export--preview-stage-view session st vp theme nil short-p))))
       ;; Bottom Shortcut Bar (dropped on short windows; concise on narrow)
       (unless short-p
         (etaf-node
          'box (list :width 'stretch :background-color panel-bg
                     :border-top (list '(px 1) 'solid border)
                     :padding '((lh 0) (ch 2)))
          (list
           (etaf-node
            'text (list :color muted)
            (list (if wide-p
                      "n/p 翻页 · z 缩放 · m 分页 · t 配色 · b 边距 · e 导 PDF · s 导 SVG · q 返回"
                    "n/p 翻页 · m 分页 · t 配色 · e PDF · s SVG · q 返回")))))))))))

(defun etaf-export--read-viewport (window &optional runtime)
  "Return viewport metrics plist (:cols :rows :cw :lh) for WINDOW and RUNTIME."
  (let* ((dm (and runtime (ignore-errors (etaf-display-metrics runtime))))
         (dm-cw (and dm (plist-get dm :char-width)))
         (dm-lh (and dm (plist-get dm :line-height)))
         (pixel-ok (and (numberp dm-cw) (> dm-cw 2) (numberp dm-lh) (> dm-lh 4)))
         (cw (if pixel-ok dm-cw 8))
         (lh (if pixel-ok dm-lh 18))
         (cols (if (window-live-p window)
                   (max 40 (window-body-width window))
                 110))
         (rows (if (window-live-p window)
                   (max 14 (window-body-height window))
                 36)))
    (list :cols cols :rows rows :cw cw :lh lh)))

(defun etaf-export--open-preview (runtime &optional ctx)
  "Open the live vector Export Preview workspace for mounted RUNTIME."
  (unless (and runtime (etaf-runtime-mounted-p runtime))
    (signal 'etaf-export-error (list "Current buffer is not a mounted ETAF page")))
  (let* ((src-buf (etaf-runtime-buffer runtime))
         (prefs (etaf-export--load-prefs ctx))
         (state-ref (etaf-ref (append (copy-sequence prefs)
                                      (list :zoom 'fit-page :page-index 1))))
         (vp-ref (etaf-ref (etaf-export--read-viewport (selected-window) runtime)))
         (theme-ref (etaf-ref (etaf-ext-theme)))
         (session (list :source-rt runtime
                        :source-buf src-buf
                        :ctx ctx
                        :snapshots nil
                        :desc-cache (make-hash-table :test #'equal)
                        :state-ref state-ref
                        :viewport-ref vp-ref
                        :theme-ref theme-ref))
         (theme-hook (lambda (&rest _)
                       (when (and (etaf-app-buffer etaf-export--preview-buffer-name)
                                  (etaf-ref-p theme-ref))
                         (ignore-errors
                           (etaf-set-value theme-ref (etaf-ext-theme))))))
         (root-view (etaf-node
                     'etaf-export--themed-root
                     (list :theme theme-ref
                           :render (lambda ()
                                     (etaf-node 'etaf-export--preview-component
                                                (list :session session) nil)))
                     nil)))
    (etaf-export--preview-recompute session nil)
    (let ((buf (etaf-app-open
                etaf-export--preview-buffer-name
                root-view
                :state session
                :cursor nil
                :mode-line t
                :background (lambda () (plist-get (etaf-value theme-ref) :ext-canvas))
                :foreground (lambda () (plist-get (etaf-value theme-ref) :ext-fg))
                :meta '(:app etaf-export-preview :kind tool :title "导出预览")
                :display (not noninteractive)
                :on-fit (lambda (win)
                          (let ((prt (etaf-runtime-for-buffer (current-buffer))))
                            (etaf-set-value vp-ref (etaf-export--read-viewport win (or prt runtime)))))
                :on-close (lambda ()
                            (when (boundp 'enable-theme-functions)
                              (remove-hook 'enable-theme-functions theme-hook))
                            (when (boundp 'disable-theme-functions)
                              (remove-hook 'disable-theme-functions theme-hook))))))
      (when (boundp 'enable-theme-functions)
        (add-hook 'enable-theme-functions theme-hook))
      (when (boundp 'disable-theme-functions)
        (add-hook 'disable-theme-functions theme-hook))
      buf)))

;;;; Compact Floating Popup (for Extension Manager `:popup')

(defun etaf-export--popup-estimate-pages (snap opts)
  "Compute page count for SNAP under OPTS without re-snapshotting."
  (if snap
      (length (plist-get (etaf-export--paginate
                          snap
                          (plist-get opts :page-mode)
                          (plist-get opts :margin)
                          (plist-get opts :page-numbers))
                         :pages))
    1))

(defun etaf-export--popup-run-export (ctx state-ref format)
  "Hide popup, prompt for output path and run FORMAT export."
  (let* ((rt (etaf-ext-ctx-runtime ctx))
         (st (etaf-value state-ref))
         (ext (if (eq format 'svg) "svg" "pdf")))
    (etaf-ext-hide-popup ctx)
    (let* ((dest (etaf-export--prompt-output-path rt ext))
           (res (if (eq format 'svg)
                    (etaf-export-svg dest
                                     :runtime rt
                                     :page-mode (plist-get st :page-mode)
                                     :theme (plist-get st :theme)
                                     :page-numbers (plist-get st :page-numbers)
                                     :margin (plist-get st :margin))
                  (etaf-export-pdf dest
                                   :runtime rt
                                   :page-mode (plist-get st :page-mode)
                                   :theme (plist-get st :theme)
                                   :page-numbers (plist-get st :page-numbers)
                                   :margin (plist-get st :margin)))))
      (etaf-export--notify-exported ctx res)
      res)))

(etaf-define-component etaf-export--popup-component
    (&key ctx state-ref theme-ref snap title)
  "Reactive compact floating export popup (in-place updates, zero flicker)."
  :render
  (let* ((st (etaf-value state-ref))
         (theme (etaf-value theme-ref))
         (page-mode (plist-get st :page-mode))
         (theme-opt (plist-get st :theme))
         (margin (plist-get st :margin))
         (page-nums (plist-get st :page-numbers))
         (pages (or (plist-get st :pages) 1))
         (rsvg-ok (plist-get st :rsvg-ok))
         (single-p (eq page-mode 'single))
         (bg (plist-get theme :ext-panel))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (danger (plist-get theme :ext-danger))
         (danger-bg (plist-get theme :ext-danger-soft))
         (set-opt (lambda (k v)
                    (let* ((next (plist-put (copy-sequence (etaf-value state-ref)) k v))
                           (pg (etaf-export--popup-estimate-pages snap next)))
                      (setq next (plist-put next :pages pg))
                      (etaf-export--save-prefs ctx next)
                      (etaf-ext-ctx-set-state ctx (list :opts next :theme-ref theme-ref))
                      (etaf-set-value state-ref next))))
         (do-close (lambda () (etaf-ext-hide-popup ctx)))
         (do-preview (lambda ()
                       (etaf-ext-hide-popup ctx)
                       (etaf-export--open-preview (etaf-ext-ctx-runtime ctx) ctx))))
    (etaf-node
     'column
     (list :width 'stretch :background-color bg :color fg
           :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
           :focus-scope 'modal
           :on-dismiss do-close
           :keys (list (list "p" (lambda ()
                                   (when rsvg-ok
                                     (etaf-export--popup-run-export ctx state-ref 'pdf)))
                             "导出 PDF")
                       (list "s" (lambda ()
                                   (etaf-export--popup-run-export ctx state-ref 'svg))
                             "导出 SVG")
                       (list "v" do-preview "打开预览")
                       (list "m" (lambda ()
                                   (funcall set-opt :page-mode
                                            (etaf-export--cycle-ring
                                             page-mode etaf-export--page-mode-ring)))
                             "切换分页")
                       (list "t" (lambda ()
                                   (funcall set-opt :theme
                                            (if (eq theme-opt 'current) 'light 'current)))
                             "切换配色")
                       (list "b" (lambda ()
                                   (funcall set-opt :margin
                                            (etaf-export--cycle-ring
                                             margin etaf-export--margin-presets)))
                             "切换页边距")
                       (list "#" (lambda ()
                                   (unless single-p
                                     (funcall set-opt :page-numbers (not page-nums))))
                             "开关页码")
                       (list "n" (lambda ()
                                   (unless single-p
                                     (funcall set-opt :page-numbers (not page-nums))))
                             "开关页码")
                       (list "q" do-close "关闭面板")))
     (delq
      nil
      (list
       ;; Header: title + page badge + close button
       (etaf-node
        'flex '(:width stretch :justify-content space-between :align-items center)
        (list
         (etaf-node
          'flex '(:align-items center :gap ((lh 0) (ch 1)))
          (list
           (etaf-node 'text (list :color fg :font-weight 'bold) '("页面导出"))
           (etaf-view
            (etaf-badge
             :text (if rsvg-ok (format "预计 %d 页" pages) "缺 rsvg-convert")
             :variant (if rsvg-ok 'info 'danger)))))
         (etaf-view
          (etaf-button :label "[×]" :variant 'ghost :pointer 'hand
                       :color muted :padding '((lh 0) (ch 0))
                       :on-press do-close))))
       (etaf-node 'text (list :color muted)
                  (list (format "目标：%s" title)))
       (etaf-view (etaf-divider :orientation 'horizontal))
       ;; 4 compact segmented rows
       (etaf-node
        'column '(:width stretch :item-gap (lh 0) :padding ((lh 0) (ch 0)))
        (list
         (etaf-node
          'flex '(:align-items center :gap ((lh 0) (ch 1)))
          (list
           (etaf-node 'text (list :color muted) '("分页"))
           (etaf-view
            (etaf-segmented
             :value page-mode
             :options '((a4 . "A4") (letter . "Letter") (single . "单页"))
             :on-change (lambda (v) (funcall set-opt :page-mode v))))))
         (etaf-node
          'flex '(:align-items center :gap ((lh 0) (ch 1)))
          (list
           (etaf-node 'text (list :color muted) '("配色"))
           (etaf-view
            (etaf-segmented
             :value theme-opt
             :options '((current . "跟随主题") (light . "亮色打印"))
             :on-change (lambda (v) (funcall set-opt :theme v))))))
         (etaf-node
          'flex '(:align-items center :gap ((lh 0) (ch 1)))
          (list
           (etaf-node 'text (list :color muted) '("边距"))
           (etaf-view
            (etaf-segmented
             :value margin
             :options '((16 . "紧凑") (28 . "标准") (40 . "宽松"))
             :on-change (lambda (v) (funcall set-opt :margin v))))))
         (etaf-node
          'flex '(:align-items center :gap ((lh 0) (ch 1)))
          (list
           (etaf-node 'text (list :color muted) '("页码"))
           (etaf-view
            (etaf-segmented
             :value page-nums
             :disabled single-p
             :options '((t . "显示") (nil . "隐藏"))
             :on-change (lambda (v) (funcall set-opt :page-numbers v))))))))
       (unless rsvg-ok
         (etaf-node
          'box (list :width 'stretch :background-color danger-bg
                     :padding '((lh 0) (ch 1)))
          (list (etaf-node
                 'text (list :color danger)
                 (list (format "缺 rsvg-convert（%s；SVG 可用）"
                               (etaf-export--rsvg-install-hint)))))))
       (etaf-view (etaf-divider :orientation 'horizontal))
       ;; Actions row
       (etaf-node
        'flex '(:width stretch :justify-content space-between :align-items center :gap ((lh 0) (ch 1)))
        (list
         (etaf-view
          (etaf-button :label "预览 (v)" :variant 'ghost :pointer 'hand
                       :on-press do-preview))
         (etaf-node
          'flex '(:align-items center :gap ((lh 0) (ch 1)))
          (list
           (etaf-view
            (etaf-button :label "导出 SVG (s)" :variant 'secondary :pointer 'hand
                         :on-press (lambda () (etaf-export--popup-run-export ctx state-ref 'svg))))
           (etaf-view
            (etaf-button :label "导出 PDF (p)" :variant 'primary
                         :disabled (not rsvg-ok)
                         :pointer (when rsvg-ok 'hand)
                         :on-press (lambda () (etaf-export--popup-run-export ctx state-ref 'pdf))))))))
       ;; Key hints
       (etaf-node 'box '(:padding-top (lh 1))
                  (list
                   (etaf-node 'text (list :color muted)
                              '("v 预览 · p 导 PDF · s 导 SVG · q 关闭")))))))))

(defun etaf-export--popup-view (ctx)
  "Build compact reactive popup View for `etaf-ext-open-popup' on CTX."
  (let* ((rt (etaf-ext-ctx-runtime ctx))
         (meta (etaf-ext-ctx-meta ctx))
         (buf (etaf-runtime-buffer rt))
         (title (truncate-string-to-width
                 (or (plist-get meta :title) (buffer-name buf)) 36 nil nil "…"))
         (prefs (etaf-export--load-prefs ctx))
         (snap (ignore-errors
                 (etaf-export--snapshot-runtime
                  rt :theme (plist-get prefs :theme)
                  :font-family etaf-export-font-family)))
         (pages (etaf-export--popup-estimate-pages snap prefs))
         (rsvg-ok (and (plist-get (etaf-export--doctor-report) :ready) t))
         (init (append (copy-sequence prefs)
                       (list :pages pages :rsvg-ok rsvg-ok)))
         (state-ref (etaf-ref init))
         (theme-ref (etaf-ref (etaf-ext-theme))))
    (etaf-ext-ctx-set-state ctx (list :opts init :theme-ref theme-ref))
    (etaf-node
     'etaf-export--themed-root
     (list :theme theme-ref
           :render (lambda ()
                     (etaf-node 'etaf-export--popup-component
                                (list :ctx ctx
                                      :state-ref state-ref
                                      :theme-ref theme-ref
                                      :snap snap
                                      :title title)
                                nil)))
     nil)))

(defun etaf-export--on-theme (ctx)
  "Sync live Emacs theme changes into any active export popup on CTX."
  (when-let* ((st (etaf-ext-ctx-state ctx))
              (tref (and (listp st) (plist-get st :theme-ref))))
    (when (etaf-ref-p tref)
      (etaf-set-value tref (etaf-ext-theme)))))

(defun etaf-export--on-detach (ctx)
  "Hide any open export popup cleanly on CTX detach."
  (ignore-errors (etaf-ext-hide-popup ctx)))

(provide 'etaf-export-ui)
;;; etaf-export-ui.el ends here
