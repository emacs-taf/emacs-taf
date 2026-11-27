;;; etaf-ext-ui.el --- Extension Manager UI for etaf-ext -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Interactive Extension Manager (`etaf-ext-manage' full-buffer workspace and
;; `etaf-ext-manage-popup' centered floating posframe) built on `etaf' and
;; `etaf-ui'.
;;
;; Design characteristics:
;; - Centered max-width 124ch card workspace on ultrawide screens (fluid on
;;   standard/compact windows, single-column list <-> detail stack on narrow)
;; - Three-tier theme-derived elevation (`canvas' < `surface' < `surface2')
;;   with crisp 1px borders and zero `:font-size' shrinking
;; - Framed extension cards with monogram badges, live ON/OFF switches and
;;   full 2-line wrapped descriptions
;; - Elevated inspector card with 4-cell metadata strip, per-app policy bar,
;;   semantic permission tags and hairline-separated command keybinding table
;; - Preserves user theme mode-line (`:mode-line t') and strict hover discipline

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext-core)
(require 'etaf-ext-store)
(require 'etaf-ext-runtime)
(require 'etaf-ext-keys)

(declare-function etaf-posframe-show "etaf-posframe" (view &rest options))
(declare-function etaf-posframe-hide "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-live-p "etaf-posframe" (panel))

(defconst etaf-ext--manage-buffer-name "*ETAF 扩展管理*"
  "Buffer name for the full-buffer extension manager.")

(defconst etaf-ext--manage-max-cols 124
  "Maximum character column width of the centered manager workspace shell.")

(defvar etaf-ext--manage-popup-state nil
  "Descriptor plist for the currently open floating manager posframe, or nil.")

(defconst etaf-ext--perm-labels
  '((read-tree . "读取页面树")
    (decorate  . "文本装饰")
    (companion . "伴生面板")
    (override  . "覆写节点")
    (overlay   . "悬浮层")
    (interact  . "语义交互")
    (inspect   . "盒模型检查")
    (storage   . "独立存储")
    (keys      . "快捷键层")
    (popup     . "浮窗面板")
    (notify    . "通知"))
  "Human-readable Chinese labels for `etaf-ext-known-permissions'.")

(defconst etaf-ext--perm-variants
  '((read-tree . neutral)
    (decorate  . info)
    (companion . info)
    (override  . warning)
    (overlay   . info)
    (interact  . warning)
    (inspect   . neutral)
    (storage   . neutral)
    (keys      . neutral)
    (popup     . info)
    (notify    . neutral))
  "Semantic tone variants for permission capsules.")

(defun etaf-ext--ui-perm-label (perm)
  "Return human-readable label for permission symbol PERM."
  (or (cdr (assq perm etaf-ext--perm-labels))
      (symbol-name perm)))

(defun etaf-ext--ui-perm-variant (perm)
  "Return semantic variant for permission symbol PERM."
  (or (cdr (assq perm etaf-ext--perm-variants)) 'neutral))

(defun etaf-ext--ui-resolve-target (preferred)
  "Return a live non-manager target Runtime, preferring PREFERRED."
  (cond
   ((and preferred
         (etaf-runtime-mounted-p preferred)
         (not (eq (plist-get (etaf-runtime-meta preferred) :app)
                  'etaf-ext-manager)))
    preferred)
   (t
    (cl-find-if
     (lambda (rt)
       (and (etaf-runtime-mounted-p rt)
            (not (eq (plist-get (etaf-runtime-meta rt) :app)
                     'etaf-ext-manager))))
     (etaf-runtime-list)))))

(defun etaf-ext--ui-infer-target-app (target-rt)
  "Return application symbol declared in TARGET-RT's `:meta :app', or nil."
  (when (and target-rt (etaf-runtime-mounted-p target-rt))
    (plist-get (etaf-runtime-meta target-rt) :app)))

(defun etaf-ext--ui-ext-status (id target-rt)
  "Return status plist `(:code :label :dot :tone :active-count :on-target)'."
  (let* ((enabled (etaf-ext-enabled-p id))
         (susp (etaf-ext-suspended-p id))
         (errs (etaf-ext-errors id))
         (active-rts (etaf-ext-active-runtimes id))
         (active-n (length active-rts))
         (on-target (and target-rt (memq target-rt active-rts) t)))
    (cond
     (susp
      (list :code 'suspended :label "已熔断" :dot "●" :tone 'danger
            :active-count active-n :on-target nil :error-count (length errs)))
     ((not enabled)
      (list :code 'disabled :label "已禁用" :dot "○" :tone 'neutral
            :active-count active-n :on-target nil :error-count (length errs)))
     ((> active-n 0)
      (list :code 'active
            :label (if on-target "运行中" (format "运行 %d 页" active-n))
            :dot "●" :tone 'success
            :active-count active-n :on-target on-target :error-count (length errs)))
     (t
      (list :code 'enabled :label "就绪" :dot "○" :tone 'info
            :active-count 0 :on-target nil :error-count (length errs))))))

(defun etaf-ext--ui-matches-query-p (id query &optional target-rt)
  "Return non-nil when extension ID's manifest or bindings match search QUERY."
  (if (or (null query) (string-empty-p (string-trim query)))
      t
    (let* ((q (downcase (string-trim query)))
           (info (etaf-ext-info id))
           (bindings (ignore-errors (etaf-ext-command-bindings target-rt id))))
      (or (string-search q (downcase (symbol-name id)))
          (string-search q (downcase (or (plist-get info :name) "")))
          (string-search q (downcase (or (plist-get info :description) "")))
          (cl-some (lambda (b)
                     (or (string-search q (downcase (or (plist-get b :effective-key) "")))
                         (string-search q (downcase (or (plist-get b :dispatch-key) "")))
                         (string-search q (downcase (or (plist-get b :suggested-key) "")))
                         (string-search q (downcase (or (plist-get b :label) "")))))
                   bindings)))))

(defun etaf-ext--ui-filtered-ids (filter query target-rt)
  "Return registered extension IDs matching FILTER and QUERY for TARGET-RT."
  (cl-remove-if-not
   (lambda (id)
     (and (etaf-ext--ui-matches-query-p id query target-rt)
          (let ((st (etaf-ext--ui-ext-status id target-rt)))
            (pcase filter
              ('all t)
              ('enabled (etaf-ext-enabled-p id))
              ('active (> (plist-get st :active-count) 0))
              ('errors (or (eq (plist-get st :code) 'suspended)
                           (> (plist-get st :error-count) 0)))
              (_ t)))))
   (etaf-ext-list)))

(defun etaf-ext--ui-format-matches (matches)
  "Format extension `:matches' plist into a concise human-readable line."
  (let ((apps (plist-get matches :apps))
        (kinds (plist-get matches :kinds))
        (uri-re (plist-get matches :uri-regexp))
        (buf-re (plist-get matches :buffer-regexp))
        (pred (plist-get matches :predicate))
        parts)
    (push (cond
           ((or (null apps) (eq apps t)) "全部 ETAF 应用")
           (t (format "应用: %s" (mapconcat #'symbol-name apps ", "))))
          parts)
    (when kinds
      (push (format "类型: %s" (mapconcat #'symbol-name kinds ", ")) parts))
    (when uri-re
      (push (format "URI: %s" uri-re) parts))
    (when buf-re
      (push (format "Buffer: %s" buf-re) parts))
    (when pred
      (push "自定义谓词" parts))
    (mapconcat #'identity (nreverse parts) " · ")))

(defun etaf-ext--ui-target-label (target-rt)
  "Return concise display label for TARGET-RT."
  (if (and target-rt (etaf-runtime-mounted-p target-rt))
      (let* ((meta (etaf-runtime-meta target-rt))
             (app (plist-get meta :app))
             (title (plist-get meta :title))
             (buf (etaf-runtime-buffer target-rt))
             (bname (and (buffer-live-p buf) (buffer-name buf)))
             (raw (cond
                   ((and (stringp title) (not (string-empty-p title))) title)
                   (bname bname)
                   (app (symbol-name app))
                   (t "当前页面"))))
        (truncate-string-to-width raw 28 nil nil "…"))
    "无活跃目标页"))

(defun etaf-ext--ui-monogram (id info theme)
  "Return `(GLYPH BG FG BORDER)' for extension ID and manifest INFO in THEME."
  (let* ((name (or (plist-get info :name) (symbol-name id)))
         (icon (plist-get info :icon))
         (tone (plist-get info :tone))
         (glyph (cond
                 ((and (stringp icon) (not (string-empty-p icon))) icon)
                 ((and (stringp name) (> (length name) 0))
                  (upcase (substring name 0 1)))
                 (t (upcase (substring (symbol-name id) 0 1))))))
    (if tone
        (pcase-let ((`(,bg ,fg ,bdr)
                     (etaf-ext--ui-tone-colors
                      (if (eq tone 'accent) 'info tone) theme)))
          (list glyph bg fg bdr))
      (list glyph (plist-get theme :ext-surface2)
            (plist-get theme :ext-accent) (plist-get theme :ext-border)))))

(defun etaf-ext--ui-tone-colors (tone theme)
  "Return `(BG FG SOFT-BORDER)' for semantic TONE in THEME."
  (pcase tone
    ('success (list (plist-get theme :ext-success-soft)
                    (plist-get theme :ext-success)
                    (plist-get theme :ext-success-border)))
    ('warning (list (plist-get theme :ext-warning-soft)
                    (plist-get theme :ext-warning)
                    (plist-get theme :ext-warning-border)))
    ('danger  (list (plist-get theme :ext-danger-soft)
                    (plist-get theme :ext-danger)
                    (plist-get theme :ext-danger-border)))
    ('info    (list (plist-get theme :ext-accent-soft)
                    (plist-get theme :ext-accent)
                    (plist-get theme :ext-accent-border)))
    (_        (list (plist-get theme :ext-surface2)
                    (plist-get theme :ext-muted)
                    (plist-get theme :ext-border-soft)))))

(defun etaf-ext--ui-pill (label tone theme &optional bold-p bordered-p)
  "Build a calm semantic pill with LABEL in TONE (borderless by default)."
  (pcase-let ((`(,bg ,fg ,bdr) (etaf-ext--ui-tone-colors tone theme)))
    (etaf-node
     'box
     (append
      (list :flex-shrink 0
            :background-color bg
            :padding '((lh 0) (ch 1)))
      (when (and bordered-p bdr)
        (list :border (list '(px 1) 'solid bdr))))
     (list (etaf-node 'text
                      (list :color fg :font-weight (if bold-p 'bold 'normal))
                      (list label))))))

(defun etaf-ext--ui-segment-btn (label on-press active-p theme &optional accent-p)
  "Build a zero-jitter borderless segmented tab or policy option.
Active and inactive states share identical padding, zero border and normal
weight so switching tabs never shifts surrounding controls by even 1px."
  (let* ((fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (surface2 (plist-get theme :ext-surface2))
         (accent (plist-get theme :ext-accent))
         (accent-soft (plist-get theme :ext-accent-soft))
         (hover (plist-get theme :ext-hover))
         (bg (when active-p (if accent-p accent-soft surface2)))
         (ink (cond ((and active-p accent-p) accent)
                    (active-p fg)
                    (t muted))))
    (etaf-node
     'box
     (append
      (list :flex-shrink 0 :padding '((lh 0) (ch 2)) :role 'button :tab-index 0
            :aria-label label :aria-selected (and active-p t))
      (when bg (list :background-color bg))
      (when (and on-press (not active-p))
        (list :on-press on-press :pointer 'hand
              :hover-style (list :background-color hover))))
     (list (etaf-node 'text (list :color ink) (list label))))))

(defun etaf-ext--ui-action-btn (label on-press variant theme &optional active-p)
  "Build a calm action button respecting 4-tier hover discipline.
VARIANT is `primary', `accent', `surface', `surface2', `canvas', or `ghost'.
When ACTIVE-P is non-nil, renders in resting selected state with no hover."
  (let* ((fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (surface (plist-get theme :ext-surface))
         (surface2 (plist-get theme :ext-surface2))
         (canvas (plist-get theme :ext-canvas))
         (bdr-soft (plist-get theme :ext-border-soft))
         (accent (plist-get theme :ext-accent))
         (accent-fill (or (plist-get theme :ext-accent-fill) accent))
         (accent-fg (plist-get theme :ext-accent-fg))
         (accent-soft (plist-get theme :ext-accent-soft))
         (hover (plist-get theme :ext-hover))
         (style
          (pcase variant
            ('primary  (list accent-fill accent-fg nil t nil))
            ('accent   (list accent-soft accent nil nil
                             (unless active-p (etaf-ui-color-mix accent-soft fg 0.08))))
            ('surface  (list surface fg bdr-soft nil hover))
            ('surface2 (list surface2 fg nil nil (etaf-ui-color-mix surface2 fg 0.07)))
            ('canvas   (list canvas muted bdr-soft nil hover))
            (_         (list nil muted nil nil hover)))))
    (pcase-let ((`(,bg ,ink ,border-col ,bold-p ,hbg) style))
      (etaf-node
       'box
       (append
        (list :flex-shrink 0
              :padding (if (eq variant 'ghost) '((lh 0) (ch 1)) '((lh 0) (ch 2)))
              :role 'button :tab-index 0
              :aria-label label :aria-selected (and active-p t))
        (when bg (list :background-color bg))
        (when border-col (list :border (list '(px 1) 'solid border-col)))
        (when (and on-press (not active-p))
          (append (list :on-press on-press :pointer 'hand)
                  ;; Never wash tinted primary CTA into neutral grey on hover.
                  (when (and hbg (not (eq variant 'primary)))
                    (list :hover-style (list :background-color hbg))))))
       (list (etaf-node 'text
                        (list :color ink :font-weight (if bold-p 'bold 'normal))
                        (list label)))))))

(defun etaf-ext--ui-switch (enabled on-press theme)
  "Build a quiet borderless ON/OFF switch pill (`● 开' / `○ 关')."
  (let* ((bg (if enabled (plist-get theme :ext-success-soft)
               (plist-get theme :ext-surface2)))
         (fg (if enabled (plist-get theme :ext-success)
               (plist-get theme :ext-dim)))
         (lbl (if enabled "● 开" "○ 关")))
    (etaf-node
     'box
     (list :flex-shrink 0
           :background-color bg
           :padding '((lh 0) (ch 1))
           :role 'switch
           :aria-label (if enabled "禁用扩展" "启用扩展")
           :pointer 'hand
           :on-press on-press)
     (list (etaf-node 'text (list :color fg) (list lbl))))))

;;;; Sub-views

(defun etaf-ext--ui-header (engine-on pure-p target-rt ids-all active-on-target
                                      short-p narrow-p popup-p bump theme)
  "Render calm, restrained top header inside the centered workspace shell."
  (let* ((fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (dim (plist-get theme :ext-dim))
         (ok (plist-get theme :ext-success))
         (target-lbl (etaf-ext--ui-target-label target-rt)))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0))
     (delq
      nil
      (list
       (etaf-node
        'flex (list :width 'stretch :justify-content 'space-between
                    :align-items 'center :flex-wrap 'wrap :gap '((lh 0) (ch 1)))
        (list
         ;; Left: Brand (omitted in posframe since frame chrome shows title) + quiet dot
         (etaf-node
          'flex (list :align-items 'center :gap '((lh 0) (ch 2)))
          (delq
           nil
           (list
            (unless popup-p
              (etaf-node 'text (list :font-weight 'bold :color fg)
                         '("ETAF 扩展中心")))
            (etaf-node
             'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
             (list (etaf-node 'text (list :color (if engine-on ok dim))
                              (list (if engine-on "●" "○")))
                   (etaf-node 'text (list :color muted)
                              (list (if engine-on "引擎运行中" "引擎已停用")))))
            (when pure-p
              (etaf-ext--ui-pill "● 纯净模式" 'warning theme nil))
            (when popup-p
              (etaf-node 'text (list :color dim)
                         (list (format "目标 %s · %d 已装 · %d 活跃"
                                       target-lbl (length ids-all) active-on-target)))))))
         ;; Right: Quiet neutral controls (tinted only when Pure/Stopped is active)
         (etaf-node
          'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
          (delq
           nil
           (list
            (when target-rt
              (etaf-ext--ui-action-btn
               (if pure-p "退出纯净 P" "纯净模式 P")
               (lambda ()
                 (etaf-ext-pure-mode-toggle target-rt)
                 (funcall bump))
               (if pure-p 'accent 'surface) theme))
            (etaf-ext--ui-action-btn
             (if engine-on "引擎 ON E" "启用引擎 E")
             (lambda ()
               (etaf-ext-mode (if engine-on -1 1))
               (funcall bump))
             (if engine-on 'surface 'primary) theme)
            (unless narrow-p
              (etaf-ext--ui-action-btn "刷新 g" bump 'ghost theme)))))))
       ;; Subtitle row (omitted on short windows or inside posframe)
       (unless (or short-p popup-p)
         (etaf-node
          'flex (list :width 'stretch :justify-content 'space-between
                      :align-items 'center :gap '((lh 0) (ch 1)))
          (delq
           nil
           (list
            (etaf-node
             'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
             (list
              (etaf-node 'text (list :color dim) '("目标页面"))
              (etaf-node 'text (list :color muted) (list target-lbl))
              (etaf-node 'text (list :color dim)
                         (list (format "· %d 已装 · %d 当前页活跃"
                                       (length ids-all) active-on-target)))))
            (unless narrow-p
              (etaf-node 'text (list :color dim) '("按 ? 查看快捷键"))))))))))))

(defun etaf-ext--ui-toolbar (filter-ref query-ref ids-all shell-cols prompt-search-fn theme)
  "Render open, borderless filter strip and quiet search input."
  (let* ((cur (etaf-value filter-ref))
         (query (or (etaf-value query-ref) ""))
         (has-q (not (string-empty-p (string-trim query))))
         (total (length ids-all))
         (enabled-n (cl-count-if #'etaf-ext-enabled-p ids-all))
         (active-n (cl-count-if
                    (lambda (id) (> (length (etaf-ext-active-runtimes id)) 0))
                    ids-all))
         (err-n (cl-count-if
                 (lambda (id)
                   (or (etaf-ext-suspended-p id)
                       (> (length (etaf-ext-errors id)) 0)))
                 ids-all))
         (tabs (list (list 'all (format "全部 %d" total))
                     (list 'enabled (format "已启用 %d" enabled-n))
                     (list 'active (format "运行中 %d" active-n))
                     (list 'errors (format "异常 %d" err-n))))
         (surface (plist-get theme :ext-surface))
         (border-soft (plist-get theme :ext-border-soft))
         (sel-bdr (or (plist-get theme :ext-selected-border)
                      (plist-get theme :ext-accent)))
         (fg (plist-get theme :ext-fg))
         (dim (plist-get theme :ext-dim)))
    (etaf-node
     'flex
     (list :width 'stretch
           :border-bottom (list '(px 1) 'solid border-soft)
           :padding '((lh 0) (ch 0))
           :justify-content 'space-between
           :align-items 'center
           :flex-wrap 'wrap
           :gap '((lh 0) (ch 1)))
     (delq
      nil
      (list
       (etaf-node
        'flex (list :align-items 'center :flex-wrap 'wrap :gap '((lh 0) (ch 1)))
        (mapcar
         (lambda (tab)
           (let* ((key (nth 0 tab))
                  (label (nth 1 tab))
                  (sel (eq cur key)))
             (etaf-ext--ui-segment-btn
              label
              (unless sel (lambda () (etaf-set-value filter-ref key)))
              sel theme nil)))
         tabs))
       (when (>= shell-cols 82)
         (etaf-node
          'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
          (delq
           nil
           (list
            (etaf-node
             'box (list :width '(ch 32)
                        :background-color surface
                        :border (list '(px 1) 'solid (if has-q sel-bdr border-soft))
                        :padding '((lh 0) (ch 2))
                        :pointer 'hand
                        :on-press prompt-search-fn)
             (list
              (etaf-node 'text (list :color (if has-q fg dim))
                         (list (if has-q
                                   (format "/ %s" (truncate-string-to-width query 24 nil nil "…"))
                                 "/ 搜索名称、标识或快捷键…")))))
            (when has-q
              (etaf-ext--ui-action-btn
               "清除" (lambda () (etaf-set-value query-ref "")) 'ghost theme)))))))))))

(defun etaf-ext--ui-ext-card (id selected-p target-rt left-cols select-fn toggle-fn theme)
  "Render one airy, zero-jitter extension card for ID inside LEFT-COLS.
Selected and unselected states keep identical 1px border widths and padding
so moving selection never shifts text horizontally or vertically."
  (let* ((info (etaf-ext-info id))
         (name (plist-get info :name))
         (ver (plist-get info :version))
         (desc (or (plist-get info :description) "无描述"))
         (summary (truncate-string-to-width desc (max 18 (- left-cols 6)) nil nil "…"))
         (act (plist-get info :activation))
         (enabled (etaf-ext-enabled-p id))
         (st (etaf-ext--ui-ext-status id target-rt))
         (st-tone (plist-get st :tone))
         (st-fg (nth 1 (etaf-ext--ui-tone-colors st-tone theme)))
         (surface (plist-get theme :ext-surface))
         (sel-bg (plist-get theme :ext-selected))
         (sel-bdr (or (plist-get theme :ext-selected-border)
                      (plist-get theme :ext-border)))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (dim (plist-get theme :ext-dim))
         (border-soft (plist-get theme :ext-border-soft))
         (hover (plist-get theme :ext-hover))
         (card-bg (if selected-p sel-bg surface))
         (card-bdr (if selected-p sel-bdr border-soft))
         (mono (etaf-ext--ui-monogram id info theme))
         (act-lbl (pcase act
                    ('on-match "自动")
                    ('on-condition "条件")
                    (_ "命令"))))
    (etaf-node
     'column
     (list :key id
           :width 'stretch
           :background-color card-bg
           :border (list '(px 1) 'solid card-bdr)
           :padding '((lh 1) (ch 2))
           :item-gap '(lh 0))
     (list
      ;; Row 1: Borderless soft monogram + clickable title + quiet ON/OFF switch
      (etaf-node
       'flex (list :width 'stretch :justify-content 'space-between
                   :align-items 'center :gap '((lh 0) (ch 1)))
       (list
        (etaf-node
         'flex (list :flex-grow 1 :flex-shrink 1 :align-items 'center
                     :gap '((lh 0) (ch 1)))
         (list
          (etaf-node
           'box (list :flex-shrink 0
                      :background-color (nth 1 mono)
                      :padding '((lh 0) (ch 1)))
           (list (etaf-node 'text (list :color (nth 2 mono) :font-weight 'bold)
                            (list (nth 0 mono)))))
          (etaf-node
           'box (append
                 (list :flex-grow 1 :flex-shrink 1 :overflow 'hidden
                       :on-press (lambda () (funcall select-fn id)))
                 (unless selected-p
                   (list :pointer 'hand
                         :hover-style (list :background-color hover))))
           (list (etaf-node 'text (list :font-weight 'bold :color fg)
                            (list name))))))
        (etaf-ext--ui-switch enabled (lambda () (funcall toggle-fn id)) theme)))
      ;; Row 2: Concise single-line summary (full description shown in right inspector)
      (etaf-node
       'box (list :width 'stretch
                  :padding '((lh 0) (ch 0))
                  :on-press (lambda () (funcall select-fn id)))
       (list (etaf-node 'text (list :color muted) (list summary))))
      ;; Row 3: Quiet status dot + version/activation
      (etaf-node
       'flex (list :width 'stretch :justify-content 'space-between
                   :align-items 'center
                   :padding '((lh 0) (ch 0)))
       (list
        (etaf-node 'text (list :color st-fg)
                   (list (format "%s %s" (plist-get st :dot) (plist-get st :label))))
        (etaf-node 'text (list :color dim)
                   (list (format "v%s · %s" ver act-lbl)))))))))

(defun etaf-ext--ui-meta-cell (label value first-p theme)
  "Render one cell of the 4-column metadata strip."
  (let ((border-soft (plist-get theme :ext-border-soft))
        (dim (plist-get theme :ext-dim))
        (fg (plist-get theme :ext-fg)))
    (etaf-node
     'column
     (append
      (list :flex-grow 1 :flex-shrink 1 :padding '((lh 0) (ch 2)) :item-gap '(lh 0))
      (unless first-p
        (list :border-left (list '(px 1) 'solid border-soft))))
     (list
      (etaf-node 'text (list :color dim) (list label))
      (etaf-node 'text (list :color fg :font-weight 'bold) (list value))))))

(defun etaf-ext--ui-perm-chip (perm theme)
  "Render a quiet borderless permission chip for PERM.
Elevated write permissions use a subtle warm dot rather than a neon box."
  (let* ((variant (etaf-ext--ui-perm-variant perm))
         (label (etaf-ext--ui-perm-label perm))
         (bg (plist-get theme :ext-surface2))
         (muted (plist-get theme :ext-muted))
         (fg (plist-get theme :ext-fg))
         (warn (plist-get theme :ext-warning))
         (elevated-p (eq variant 'warning)))
    (etaf-node
     'box (list :flex-shrink 0 :background-color bg :padding '((lh 0) (ch 1)))
     (list
      (if elevated-p
          (etaf-node
           'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
           (list (etaf-node 'text (list :color warn) '("●"))
                 (etaf-node 'text (list :color fg) (list label))))
        (etaf-node 'text (list :color muted) (list label)))))))

(defun etaf-ext--ui-rebind-command (id cid label target-rt refresh-fn)
  "Interactively record and save a direct key binding for ID's command CID."
  (let* ((cur-frame (selected-frame))
         (parent (and (fboundp 'frame-parent) (frame-parent cur-frame)))
         (prompt (format "按下「%s」的新快捷键（C-g 取消）: " label))
         (seq nil))
    (unwind-protect
        (progn
          (when (and parent (frame-live-p parent))
            (select-frame-set-input-focus parent))
          (setq seq (condition-case nil
                        (read-key-sequence-vector prompt nil t)
                      (quit nil))))
      (when (and parent (frame-live-p cur-frame))
        (ignore-errors (select-frame-set-input-focus cur-frame))))
    (when (and (vectorp seq) (> (length seq) 0))
      (let* ((kdesc (key-description seq)))
        (unless (member kdesc '("C-g" "ESC" "<escape>"))
          (let ((conflict (etaf-ext-check-key-conflict kdesc target-rt id cid)))
            (cond
             ((and conflict (eq (plist-get conflict :kind) 'framework-reserved))
              (message "无法绑定：%s" (plist-get conflict :reason)))
             ((and conflict
                   (not (yes-or-no-p
                         (format "快捷键 %s 存在冲突（%s），仍要绑定吗？"
                                 kdesc (plist-get conflict :reason)))))
              (message "已取消改键"))
             (t
              (etaf-ext-set-key id cid kdesc)
              (message "已将「%s」绑定为 %s" label kdesc)
              (funcall refresh-fn)))))))))

(defun etaf-ext--ui-detail-card (id target-rt wide-p narrow-p back-fn refresh-fn theme)
  "Render the calm elevated inspector card for extension ID."
  (let* ((surface (plist-get theme :ext-surface))
         (surface2 (plist-get theme :ext-surface2))
         (canvas (plist-get theme :ext-canvas))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (dim (plist-get theme :ext-dim))
         (border-soft (plist-get theme :ext-border-soft))
         (hover (plist-get theme :ext-hover))
         (accent (plist-get theme :ext-accent))
         (accent-soft (plist-get theme :ext-accent-soft))
         (warning (plist-get theme :ext-warning))
         (danger (plist-get theme :ext-danger))
         (kbd-bg (plist-get theme :ext-kbd-bg)))
    (if (null id)
        (etaf-node
         'column (list :width 'stretch :background-color surface
                       :border (list '(px 1) 'solid border-soft)
                       :padding '((lh 2) (ch 3)))
         (list (etaf-view (etaf-empty :title "未选择扩展"
                                      :description "请在左侧卡片列表中选择一个扩展查看详情。"))))
      (let* ((info (etaf-ext-info id))
             (name (plist-get info :name))
             (ver (plist-get info :version))
             (desc (or (plist-get info :description) ""))
             (act (plist-get info :activation))
             (prio (plist-get info :priority))
             (perms (plist-get info :permissions))
             (cmds (plist-get info :commands))
             (matches (plist-get info :matches))
             (has-popup (plist-get info :has-popup))
             (enabled (etaf-ext-enabled-p id))
             (susp (etaf-ext-suspended-p id))
             (errs (etaf-ext-errors id))
             (st (etaf-ext--ui-ext-status id target-rt))
             (st-fg (nth 1 (etaf-ext--ui-tone-colors (plist-get st :tone) theme)))
             (on-target (plist-get st :on-target))
             (target-live (and target-rt (etaf-runtime-mounted-p target-rt)))
             (target-app (etaf-ext--ui-infer-target-app target-rt))
             (app-pol (and target-app (etaf-ext-app-policy id target-app)))
             (all-policies (etaf-ext-app-policies id))
             (mono (etaf-ext--ui-monogram id info theme))
             (act-full (pcase act
                         ('on-match "自动挂载")
                         ('on-condition "按条件自动")
                         (_ "按需命令")))
             (meta-items (list (cons "扩展标识" (symbol-name id))
                               (cons "激活方式" act-full)
                               (cons "执行优先级" (number-to-string prio))
                               (cons "活跃页面" (format "%d 页" (plist-get st :active-count))))))
        (etaf-node
         'column
         (list :width 'stretch
               :background-color surface
               :border (list '(px 1) 'solid border-soft)
               :padding (if narrow-p '((lh 1) (ch 2)) '((lh 1) (ch 3)))
               :item-gap '(lh 1))
         (delq
          nil
          (list
           ;; Back button on narrow screens
           (when narrow-p
             (etaf-node
              'flex (list :width 'stretch :justify-content 'space-between)
              (list (etaf-ext--ui-action-btn "← 返回列表 (b)" back-fn 'surface2 theme))))

           ;; Hero title + version + quiet status + description + primary actions
           (etaf-node
            'column (list :width 'stretch :item-gap '(lh 0))
            (delq
             nil
             (list
              (etaf-node
               'flex (list :width 'stretch :justify-content 'space-between
                           :align-items 'center :gap '((lh 0) (ch 1)))
               (list
                (etaf-node
                 'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                 (list
                  (etaf-node
                   'box (list :flex-shrink 0
                              :background-color (nth 1 mono)
                              :padding '((lh 0) (ch 1)))
                   (list (etaf-node 'text (list :color (nth 2 mono) :font-weight 'bold)
                                    (list (nth 0 mono)))))
                  (etaf-node 'text (list :font-weight 'bold :color fg) (list name))
                  (etaf-node 'text (list :color dim) (list (format "v%s" ver)))))
                (etaf-node 'text (list :color st-fg)
                           (list (format "%s %s" (plist-get st :dot) (plist-get st :label))))))
              (unless (string-empty-p desc)
                (etaf-node 'box '(:width stretch :wrap-mode word
                                         :padding ((lh 0) (ch 0) (lh 1) (ch 0)))
                           (list (etaf-node 'text (list :color muted) (list desc)))))
              ;; Primary Action Bar
              (etaf-node
               'flex (list :width 'stretch :flex-wrap 'wrap :gap '((lh 0) (ch 1)))
               (delq
                nil
                (list
                 (when (and target-live enabled (not susp))
                   (etaf-ext--ui-action-btn
                    (if on-target "从目标页卸载" "挂载到目标页")
                    (lambda ()
                      (if on-target
                          (etaf-ext-detach id target-rt)
                        (etaf-ext-attach id target-rt))
                      (funcall refresh-fn))
                    (if on-target 'surface2 'primary) theme))
                 (when (and has-popup target-live enabled (not susp))
                   (etaf-ext--ui-action-btn
                    "打开控制面板"
                    (lambda ()
                      (etaf-ext-open-popup id target-rt)
                      (funcall refresh-fn))
                    'surface2 theme))
                 (etaf-ext--ui-action-btn
                  (if enabled "禁用扩展 (SPC)" "启用扩展 (SPC)")
                  (lambda ()
                    (if enabled (etaf-ext-disable id) (etaf-ext-enable id))
                    (funcall refresh-fn))
                  (if enabled 'ghost 'primary) theme)
                 (when susp
                   (etaf-ext--ui-action-btn
                    "解除熔断 (R)"
                    (lambda () (etaf-ext-reset id) (funcall refresh-fn))
                    'primary theme))
                 (when (and (not susp) errs)
                   (etaf-ext--ui-action-btn
                    "清空错误日志"
                    (lambda () (etaf-ext-clear-errors id) (funcall refresh-fn))
                    'ghost theme))))))))

           ;; Circuit breaker alert when suspended
           (when susp
             (etaf-view
              (etaf-alert
               :title "熔断保护已触发"
               :message (format "扩展连续报错 %d 次，已自动暂停并清理其页面表现。按 R 或点击「解除熔断」可重新启用。"
                                etaf-ext-circuit-breaker-threshold)
               :variant 'danger)))

           ;; 4-cell Metadata Strip (borderless inset surface, 4 cols on wide, 2x2 on medium/narrow)
           (if wide-p
               (etaf-node
                'flex (list :width 'stretch :background-color surface2
                            :padding '((lh 0) (ch 1)))
                (cl-loop for item in meta-items
                         for idx from 0
                         collect (etaf-ext--ui-meta-cell
                                  (car item) (cdr item) (= idx 0) theme)))
             (etaf-node
              'column (list :width 'stretch :background-color surface2
                            :padding '((lh 0) (ch 1)) :item-gap '(lh 0))
              (list
               (etaf-node 'flex '(:width stretch)
                          (list (etaf-ext--ui-meta-cell
                                 (car (nth 0 meta-items)) (cdr (nth 0 meta-items)) t theme)
                                (etaf-ext--ui-meta-cell
                                 (car (nth 1 meta-items)) (cdr (nth 1 meta-items)) nil theme)))
               (etaf-node 'flex (list :width 'stretch
                                      :border-top (list '(px 1) 'solid border-soft))
                          (list (etaf-ext--ui-meta-cell
                                 (car (nth 2 meta-items)) (cdr (nth 2 meta-items)) t theme)
                                (etaf-ext--ui-meta-cell
                                 (car (nth 3 meta-items)) (cdr (nth 3 meta-items)) nil theme))))))

           ;; Match Scope & Per-App Policy (zero-jitter borderless segments)
           (etaf-node
            'column (list :width 'stretch :item-gap '(lh 0))
            (delq
             nil
             (list
              (etaf-node
               'flex (list :width 'stretch :justify-content 'space-between
                           :align-items 'center :gap '((lh 0) (ch 1)))
               (list
                (etaf-node 'text (list :color dim) '("适用范围与按应用策略"))
                (etaf-node 'text (list :color dim)
                           (list (format "默认：%s" (etaf-ext--ui-format-matches matches))))))
              (etaf-node
               'flex (list :width 'stretch :background-color surface2
                           :padding '((lh 0) (ch 2))
                           :justify-content 'space-between
                           :align-items 'center :flex-wrap 'wrap
                           :gap '((lh 0) (ch 1)))
               (if target-app
                   (list
                    (etaf-node
                     'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                     (list (etaf-node 'text (list :color muted) '("当前应用"))
                           (etaf-node 'text (list :color fg :font-weight 'bold)
                                      (list (symbol-name target-app)))))
                    (etaf-node
                     'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                     (list
                      (etaf-ext--ui-segment-btn
                       "默认规则"
                       (when app-pol
                         (lambda ()
                           (etaf-ext-set-app-policy id target-app nil)
                           (funcall refresh-fn)))
                       (null app-pol) theme t)
                      (etaf-ext--ui-segment-btn
                       "始终允许"
                       (unless (eq app-pol 'allow)
                         (lambda ()
                           (etaf-ext-set-app-policy id target-app 'allow)
                           (funcall refresh-fn)))
                       (eq app-pol 'allow) theme t)
                      (etaf-ext--ui-segment-btn
                       "禁止运行"
                       (unless (eq app-pol 'deny)
                         (lambda ()
                           (etaf-ext-set-app-policy id target-app 'deny)
                           (funcall refresh-fn)))
                       (eq app-pol 'deny) theme t))))
                 (list (etaf-node 'text (list :color dim)
                                  '("当前无具名目标应用，将遵循默认匹配规则")))))
              (when all-policies
                (etaf-node
                 'text (list :color dim)
                 (list (format "已保存策略: %s"
                               (mapconcat (lambda (p)
                                            (format "%s=%s" (car p)
                                                    (if (eq (cdr p) 'allow) "允许" "禁止")))
                                          all-policies " · "))))))))

           ;; Permissions section (quiet borderless chips)
           (etaf-node
            'column (list :width 'stretch :item-gap '(lh 0))
            (list
             (etaf-node 'text (list :color dim)
                        (list (format "声明权限 (%d)" (length perms))))
             (if perms
                 (etaf-node
                  'flex (list :width 'stretch :flex-wrap 'wrap :gap '((lh 0) (ch 1)))
                  (mapcar (lambda (p) (etaf-ext--ui-perm-chip p theme)) perms))
               (etaf-node 'text (list :color dim) '("无特殊权限")))))

           ;; Commands & Keybindings Table (conflict-aware live resolver + interactive rebinding)
           (when cmds
             (let* ((bindings (etaf-ext-command-bindings target-rt id))
                    (pst (etaf-ext--prefix-status target-rt))
                    (epfx (plist-get (car bindings) :prefix-key))
                    (pfx-summary
                     (pcase (plist-get pst :status)
                       ('active
                        (if epfx
                            (format "统一入口 %s %s · 策略 %s"
                                    (plist-get pst :key) epfx etaf-ext-keybinding-policy)
                          (format "统一入口 %s · 策略 %s"
                                  (plist-get pst :key) etaf-ext-keybinding-policy)))
                       ('conflict
                        (format "⚠ 前缀 %s 冲突 · 策略 %s"
                                (plist-get pst :key) etaf-ext-keybinding-policy))
                       (_
                        (format "统一前缀关闭 · 策略 %s" etaf-ext-keybinding-policy)))))
               (etaf-node
                'column (list :width 'stretch :item-gap '(lh 0))
                (list
                 (etaf-node
                  'flex (list :width 'stretch :justify-content 'space-between
                              :align-items 'center :gap '((lh 0) (ch 1)))
                  (list
                   (etaf-node 'text (list :color dim)
                              (list (format "命令与快捷键 (%d)" (length bindings))))
                   (etaf-node 'text (list :color (if (eq (plist-get pst :status) 'conflict)
                                                     warning dim))
                              (list pfx-summary))))
                 (etaf-node
                  'column (list :width 'stretch :background-color surface2
                                :item-gap '(lh 0))
                  (cl-loop
                   for rec in bindings
                   for idx from 0
                   collect
                   (let* ((cid (plist-get rec :cmd-id))
                          (lbl (plist-get rec :label))
                          (ekey (plist-get rec :effective-key))
                          (dkey (plist-get rec :dispatch-key))
                          (sugg (plist-get rec :suggested-key))
                          (ovr (plist-get rec :override))
                          (src (plist-get rec :source))
                          (kst (plist-get rec :status))
                          (conflict (plist-get rec :conflict))
                          (user-p (eq src 'user))
                          (key-text (or ekey dkey "未绑定"))
                          (key-bg (cond
                                   ((and ekey user-p) accent-soft)
                                   (ekey kbd-bg)
                                   (dkey canvas)
                                   (t nil)))
                          (key-fg (cond
                                   ((and ekey user-p) accent)
                                   (ekey fg)
                                   (dkey muted)
                                   (t dim))))
                     (etaf-node
                      'column
                      (append
                       (list :width 'stretch :item-gap '(lh 0)
                             :padding '((lh 0) (ch 2)))
                       (when (> idx 0)
                         (list :border-top (list '(px 1) 'solid border-soft))))
                      (delq
                       nil
                       (list
                        (etaf-node
                         'flex
                         (list :width 'stretch :justify-content 'space-between
                               :align-items 'center :gap '((lh 0) (ch 1)))
                         (list
                          (etaf-node
                           'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                           (delq
                            nil
                            (list
                             (etaf-node
                              'box (append
                                    (list :width '(ch 13) :flex-shrink 0
                                          :padding '((lh 0) (ch 1))
                                          :text-align 'center)
                                    (when key-bg (list :background-color key-bg)))
                              (list (etaf-node
                                     'text (list :color key-fg
                                                 :font-weight (if ekey 'bold 'normal))
                                     (list key-text))))
                             (etaf-node 'text (list :color fg) (list lbl))
                             (cond
                              ((eq kst 'conflict)
                               (etaf-ext--ui-pill "⚠ 冲突已跳过" 'warning theme))
                              ((and user-p ekey)
                               (etaf-ext--ui-pill "自定义" 'info theme))
                              ((eq ovr :unbound)
                               (etaf-ext--ui-pill "已解绑" 'neutral theme))
                              ((eq kst 'policy-skipped)
                               (etaf-ext--ui-pill "仅前缀" 'neutral theme))))))
                          (etaf-node
                           'flex (list :align-items 'center :gap '((lh 0) (ch 1))
                                       :flex-shrink 0)
                           (delq
                            nil
                            (list
                             (etaf-node
                              'box (list :flex-shrink 0
                                         :padding '((lh 0) (ch 1))
                                         :pointer 'hand
                                         :hover-style (list :background-color hover)
                                         :role 'button :tab-index 0
                                         :on-press (lambda ()
                                                     (etaf-ext--ui-rebind-command
                                                      id cid lbl target-rt refresh-fn)))
                              (list (etaf-node 'text (list :color muted) '("改键"))))
                             (when (or ovr ekey)
                               (etaf-node
                                'box (list :flex-shrink 0
                                           :padding '((lh 0) (ch 1))
                                           :pointer 'hand
                                           :hover-style (list :background-color hover)
                                           :role 'button :tab-index 0
                                           :on-press (lambda ()
                                                       (if ovr
                                                           (etaf-ext-reset-key id cid)
                                                         (etaf-ext-set-key id cid :unbound))
                                                       (funcall refresh-fn)))
                                (list (etaf-node 'text (list :color dim)
                                                 (list (if ovr "恢复" "解绑"))))))
                             (when (and target-live enabled (not susp))
                               (etaf-node
                                'box (list :flex-shrink 0
                                           :padding '((lh 0) (ch 1))
                                           :pointer 'hand
                                           :hover-style (list :background-color hover)
                                           :role 'button :tab-index 0
                                           :on-press (lambda ()
                                                       (etaf-ext-run-command id cid target-rt)
                                                       (funcall refresh-fn)))
                                (list (etaf-node 'text (list :color accent)
                                                 '("执行 ▸"))))))))))
                        (when (and (eq kst 'conflict) conflict)
                          (etaf-node
                           'box (list :width 'stretch :wrap-mode 'word
                                      :padding '((lh 0) (ch 0) (lh 0) (ch 14)))
                           (list
                            (etaf-node
                             'text (list :color warning)
                             (list (format "直达键 %s：%s"
                                           (or (and (stringp ovr) ovr) sugg "")
                                           (or (plist-get conflict :reason) "存在冲突")))))))))))))))))

           ;; Recent errors section
           (when errs
             (etaf-node
              'column (list :width 'stretch :item-gap '(lh 0))
              (cons
               (etaf-node 'text (list :font-weight 'bold :color danger)
                          (list (format "最近错误日志 (%d)" (length errs))))
               (mapcar
                (lambda (e)
                  (etaf-node
                   'box (list :width 'stretch :background-color canvas
                              :border-left (list '(px 2) 'solid danger)
                              :padding '((lh 0) (ch 2)))
                   (list
                    (etaf-node 'text (list :color fg)
                               (list (format "[%s · %s] %s"
                                             (plist-get e :time)
                                             (plist-get e :phase)
                                             (plist-get e :message)))))))
                (cl-subseq errs 0 (min 6 (length errs))))))))))))))

;;;; Manager Root Component

(defun etaf-ext--ui-viewport-metrics (win)
  "Return `(COLS ROWS EFF-ROWS)' for WIN accounting for CJK line height."
  (let* ((cols (max 44 (window-body-width win)))
         (rows (max 14 (window-body-height win)))
         (eff-rows
          (if (display-graphic-p (window-frame win))
              (let* ((body-px (max 1 (window-body-height win t)))
                     (rt (and (buffer-live-p (window-buffer win))
                              (etaf-runtime-for-buffer (window-buffer win))))
                     (dm (and rt (ignore-errors (etaf-display-metrics rt))))
                     (base-px (max 10 (or (plist-get dm :line-height) 14)))
                     ;; Empirical average mixed CJK/ASCII+border row height (~1.16x base).
                     (line-px (max base-px (ceiling (* 1.16 base-px)))))
                (max 14 (floor body-px line-px)))
            rows)))
    (list cols rows eff-rows)))

(etaf-define-component etaf-ext--manager-app
    (&key theme-ref tick-ref filter-ref query-ref selected-ref pane-ref
          viewport-ref target-ref popup-p on-close)
  "Reactive centered-card Extension Manager root component."
  :setup (progn (etaf-theme-provide theme-ref) nil)
  :render
  (let* ((_tick (etaf-value tick-ref))
         (theme (etaf-value theme-ref))
         (vp (etaf-value viewport-ref))
         (cols (nth 0 vp))
         (rows (nth 1 vp))
         (eff-rows (or (nth 2 vp) rows))
         (shell-cols (if popup-p
                         (max 44 (- cols 2))
                       (min etaf-ext--manage-max-cols (max 44 (- cols 4)))))
         (narrow-p (< shell-cols 76))
         (wide-p (>= shell-cols 106))
         (short-p (<= eff-rows 18))
         (centered-p (and (not popup-p) (> (- cols shell-cols) 8)))
         (target-rt (etaf-ext--ui-resolve-target (etaf-value target-ref)))
         (pure-p (and target-rt (etaf-ext-pure-mode-p target-rt)))
         (engine-on (bound-and-true-p etaf-ext-mode))
         (ids-all (etaf-ext-list))
         (active-on-target (if target-rt
                               (length (etaf-ext-active-for-runtime target-rt))
                             0))
         (filter (etaf-value filter-ref))
         (query (etaf-value query-ref))
         (ids (etaf-ext--ui-filtered-ids filter query target-rt))
         (sel-raw (etaf-value selected-ref))
         (sel (if (memq sel-raw ids) sel-raw (car ids)))
         (pane (if narrow-p (etaf-value pane-ref) 'split))
         (canvas (plist-get theme :ext-canvas))
         (fg (plist-get theme :ext-fg))
         (dim (plist-get theme :ext-dim))
         (border-soft (plist-get theme :ext-border-soft))
         (bump (lambda () (etaf-set-value tick-ref (1+ (etaf-value tick-ref)))))
         (select-fn (lambda (id)
                      (etaf-set-value selected-ref id)
                      (when narrow-p (etaf-set-value pane-ref 'detail))))
         (toggle-fn (lambda (id)
                      (if (etaf-ext-enabled-p id)
                          (etaf-ext-disable id)
                        (etaf-ext-enable id))
                      (funcall bump)))
         (attach-toggle-fn
          (lambda ()
            (when (and sel target-rt (etaf-runtime-mounted-p target-rt)
                       (etaf-ext-enabled-p sel) (not (etaf-ext-suspended-p sel)))
              (if (memq target-rt (etaf-ext-active-runtimes sel))
                  (etaf-ext-detach sel target-rt)
                (etaf-ext-attach sel target-rt))
              (funcall bump))))
         (prompt-search-fn
          (lambda ()
            (let ((q (read-string "筛选扩展（名称/标识/快捷键，留空清除）: "
                                  (or (etaf-value query-ref) ""))))
              (etaf-set-value query-ref (string-trim q)))))
         (step-sel (lambda (delta)
                     (when ids
                       (let* ((pos (or (cl-position sel ids) 0))
                              (next (max 0 (min (1- (length ids)) (+ pos delta)))))
                         (etaf-set-value selected-ref (nth next ids))))))
         (body-height (max 8 (- eff-rows (cond (popup-p 8) (short-p 5) (t 8)))))
         (left-cols (cond (narrow-p shell-cols)
                          (wide-p 42)
                          (t 34)))
         (vp-badge (if centered-p
                       (format "%d×%d · 居中 %dch" cols rows shell-cols)
                     (format "%d×%d" cols rows))))
    (etaf-node
     'column
     (list :width 'stretch
           :background-color canvas
           :color fg
           :cross-align 'center
           :padding (if (or short-p popup-p) '((lh 0) (ch 1)) '((lh 1) (ch 2) (lh 0) (ch 2)))
           :on-direction (lambda (dir)
                           (pcase dir
                             ('down (funcall step-sel 1))
                             ('up (funcall step-sel -1))
                             ('left (when narrow-p (etaf-set-value pane-ref 'list)))
                             ('right (when (and narrow-p sel) (etaf-set-value pane-ref 'detail)))))
           :keys
           (list
            (list "j" (lambda () (funcall step-sel 1)) "下一个扩展")
            (list "n" (lambda () (funcall step-sel 1)) "下一个扩展")
            (list "k" (lambda () (funcall step-sel -1)) "上一个扩展")
            (list "p" (lambda () (funcall step-sel -1)) "上一个扩展")
            (list "SPC" (lambda () (when sel (funcall toggle-fn sel))) "启用/禁用当前扩展")
            (list "RET" attach-toggle-fn "挂载/卸载到目标页")
            (list "/" prompt-search-fn "按关键词筛选扩展")
            (list "d" (lambda ()
                        (when sel
                          (if narrow-p
                              (etaf-set-value pane-ref 'detail)
                            (funcall toggle-fn sel))))
                  (if narrow-p "查看扩展详情" "启用/禁用当前扩展"))
            (list "b" (lambda () (etaf-set-value pane-ref 'list)) "返回列表")
            (list "P" (lambda ()
                        (when target-rt
                          (etaf-ext-pure-mode-toggle target-rt)
                          (funcall bump)))
                  "切换目标页纯净模式")
            (list "E" (lambda ()
                        (etaf-ext-mode (if (bound-and-true-p etaf-ext-mode) -1 1))
                        (funcall bump))
                  "开关全局扩展引擎")
            (list "R" (lambda ()
                        (when sel
                          (etaf-ext-reset sel)
                          (funcall bump)))
                  "重置选中扩展错误")
            (list "x" (lambda ()
                        (when target-rt
                          (etaf-ext-command-palette target-rt)
                          (funcall bump)))
                  "打开扩展命令面板")
            (list "g" bump "刷新列表")
            (list "q" (lambda ()
                        (if (and narrow-p (eq (etaf-value pane-ref) 'detail))
                            (etaf-set-value pane-ref 'list)
                          (funcall on-close)))
                  "关闭或返回")))
     (list
      ;; Centered Max-Width Shell
      (etaf-node
       'column
       (list :width (list 'ch shell-cols) :item-gap '(lh 1))
       (list
        ;; 1. Header Strip
        (etaf-ext--ui-header
         engine-on pure-p target-rt ids-all active-on-target
         short-p narrow-p popup-p bump theme)

        ;; 2. Filter & Search Toolbar Card
        (etaf-ext--ui-toolbar
         filter-ref query-ref ids-all shell-cols prompt-search-fn theme)

        ;; 3. Main Workspace (Two-column cards on wide/medium; Single-pane on narrow)
        (if narrow-p
            (if (eq pane 'detail)
                (etaf-node
                 'column (list :width 'stretch :height (list 'lh body-height)
                               :overflow 'auto)
                 (list (etaf-ext--ui-detail-card
                        sel target-rt nil t
                        (lambda () (etaf-set-value pane-ref 'list))
                        bump theme)))
              (etaf-node
               'column (list :width 'stretch :height (list 'lh body-height)
                             :overflow 'auto :item-gap '(lh 1))
               (if ids
                   (mapcar (lambda (id)
                             (etaf-ext--ui-ext-card
                              id (eq id sel) target-rt left-cols select-fn toggle-fn theme))
                           ids)
                 (list (etaf-view
                        (etaf-empty :title "暂无匹配扩展"
                                    :description "调整筛选标签或搜索词，或通过 etaf-ext-define 注册新扩展。"))))))
          (etaf-node
           'flex (list :width 'stretch :height (list 'lh body-height)
                       :align-items 'stretch
                       :gap (if wide-p '((lh 0) (ch 3)) '((lh 0) (ch 2))))
           (list
            ;; Left Column: Airy zero-jitter extension cards
            (etaf-node
             'column (list :width (list 'ch left-cols) :flex-shrink 0
                           :height (list 'lh body-height)
                           :overflow 'auto :item-gap '(lh 1))
             (append
              (if ids
                  (mapcar (lambda (id)
                            (etaf-ext--ui-ext-card
                             id (eq id sel) target-rt left-cols select-fn toggle-fn theme))
                          ids)
                (list (etaf-view
                       (etaf-empty :title "暂无匹配扩展"
                                   :description "调整筛选条件或按 / 清除搜索词。"))))
              (when (and (not short-p) (<= (length ids) 3))
                (list
                 (etaf-node
                  'box (list :width 'stretch :padding '((lh 0) (ch 1)))
                  (list
                   (etaf-node 'text (list :color dim)
                              '("提示：使用 etaf-ext-define 注册个人扩展"))))))))
            ;; Right Column: Elevated Inspector Card
            (etaf-node
             'column (list :flex-grow 1 :flex-shrink 1
                           :height (list 'lh body-height)
                           :overflow 'auto)
             (list (etaf-ext--ui-detail-card
                    sel target-rt wide-p nil #'ignore bump theme))))))

        ;; 4. Aligned Bottom Footer Strip
        (etaf-node
         'flex
         (list :width 'stretch
               :border-top (list '(px 1) 'solid border-soft)
               :padding '((lh 0) (ch 0))
               :justify-content 'space-between
               :align-items 'center)
         (list
          (etaf-node
           'text (list :color dim)
           (list (if narrow-p
                     "j/k 移动 · d 详情 · SPC 启停 · x 命令 · q 返回"
                   "j/k 切换 · SPC 启停 · RET 挂载/卸载 · x 命令面板 · / 搜索 · P 纯净 · E 引擎 · ? 帮助 · q 关闭")))
          (etaf-node
           'text (list :color dim)
           (list vp-badge))))))))))

;;;; Shared Session Builder

(defun etaf-ext--ui-make-session (target-runtime init-vp popup-p on-close)
  "Create reactive refs, listeners and root View for the extension manager."
  (let* ((origin-rt (or target-runtime
                        (etaf-current-runtime)
                        (etaf-runtime-for-buffer (current-buffer))))
         (target-rt (etaf-ext--ui-resolve-target origin-rt))
         (theme-ref (etaf-ref (etaf-ext-theme)))
         (tick-ref (etaf-ref 0))
         (filter-ref (etaf-ref 'all))
         (query-ref (etaf-ref ""))
         (selected-ref (etaf-ref (car (etaf-ext-list))))
         (pane-ref (etaf-ref 'list))
         (viewport-ref (etaf-ref init-vp))
         (target-ref (etaf-ref target-rt))
         (live-p t)
         (change-listener
          (lambda (&rest _args)
            (when live-p
              (etaf-set-value tick-ref (1+ (etaf-value tick-ref))))))
         (theme-listener
          (lambda (&rest _args)
            (when live-p
              (etaf-set-value theme-ref (etaf-ext-theme)))))
         (cleanup
          (lambda ()
            (setq live-p nil)
            (remove-hook 'etaf-ext-change-functions change-listener)
            (when (boundp 'enable-theme-functions)
              (remove-hook 'enable-theme-functions theme-listener))
            (when (boundp 'disable-theme-functions)
              (remove-hook 'disable-theme-functions theme-listener))))
         (view (etaf-view
                (etaf-ext--manager-app
                 :theme-ref theme-ref
                 :tick-ref tick-ref
                 :filter-ref filter-ref
                 :query-ref query-ref
                 :selected-ref selected-ref
                 :pane-ref pane-ref
                 :viewport-ref viewport-ref
                 :target-ref target-ref
                 :popup-p popup-p
                 :on-close on-close))))
    (add-hook 'etaf-ext-change-functions change-listener)
    (when (boundp 'enable-theme-functions)
      (add-hook 'enable-theme-functions theme-listener))
    (when (boundp 'disable-theme-functions)
      (add-hook 'disable-theme-functions theme-listener))
    (list :view view :theme-ref theme-ref :viewport-ref viewport-ref
          :cleanup cleanup)))

;;;; Public Entry Commands

(defun etaf-ext-manage (&optional target-runtime)
  "Open the interactive ETAF Extension Manager as a full buffer.
When TARGET-RUNTIME is nil, targets the current buffer's mounted Runtime so
per-page Pure Mode, attach/detach and per-app policies apply to that page."
  (interactive)
  (let* ((init-vp (if (frame-live-p (selected-frame))
                      (etaf-ext--ui-viewport-metrics (selected-window))
                    (list 124 34 28)))
         (buf-ref nil)
         (sess (etaf-ext--ui-make-session
                target-runtime init-vp nil
                (lambda ()
                  (when (and buf-ref (buffer-live-p buf-ref))
                    (etaf-app-close buf-ref)))))
         (theme-ref (plist-get sess :theme-ref))
         (viewport-ref (plist-get sess :viewport-ref))
         (cleanup (plist-get sess :cleanup)))
    (setq buf-ref
          (etaf-app-open
           etaf-ext--manage-buffer-name
           (plist-get sess :view)
           :mode-line t
           :meta '(:app etaf-ext-manager :kind tool :title "ETAF 扩展中心")
           :background (lambda () (plist-get (etaf-value theme-ref) :ext-canvas))
           :foreground (lambda () (plist-get (etaf-value theme-ref) :ext-fg))
           :on-fit (lambda (win)
                     (when (window-live-p win)
                       (let ((vp (etaf-ext--ui-viewport-metrics win)))
                         (unless (equal vp (etaf-value viewport-ref))
                           (etaf-set-value viewport-ref vp)))))
           :on-close cleanup))
    buf-ref))

(defun etaf-ext--manage-popup-close ()
  "Close the floating Extension Manager posframe if open."
  (when-let* ((st etaf-ext--manage-popup-state))
    (setq etaf-ext--manage-popup-state nil)
    (when-let* ((cleanup (plist-get st :cleanup)))
      (ignore-errors (funcall cleanup)))
    (when-let* ((panel (plist-get st :panel)))
      (when (and (fboundp 'etaf-posframe-live-p)
                 (etaf-posframe-live-p panel))
        (ignore-errors (etaf-posframe-hide panel))))))

(defun etaf-ext-manage-popup (&optional target-runtime)
  "Toggle the interactive ETAF Extension Manager in a centered floating posframe.
Falls back to `etaf-ext-manage' on non-graphic displays or when `etaf-posframe'
is unavailable."
  (interactive)
  (if (not (and etaf-ext-use-posframe
                (display-graphic-p)
                (require 'etaf-posframe nil t)
                (fboundp 'etaf-posframe-show)))
      (etaf-ext-manage target-runtime)
    (let ((existing (plist-get etaf-ext--manage-popup-state :panel)))
      (if (and existing
               (fboundp 'etaf-posframe-live-p)
               (etaf-posframe-live-p existing))
          (progn
            (etaf-ext--manage-popup-close)
            nil)
        (etaf-ext--manage-popup-close)
        (let* ((fw (max 80 (frame-width)))
               (fh (max 24 (frame-height)))
               (pw (min 126 (max 84 (- fw 10))))
               (ph (min 40 (max 28 (- fh 4))))
               (eff-h (max 20 (floor (* ph 0.84))))
               (sess (etaf-ext--ui-make-session
                      target-runtime (list pw ph eff-h) t
                      #'etaf-ext--manage-popup-close))
               (panel (etaf-posframe-show
                       (plist-get sess :view)
                       :key 'etaf-ext-manage-popup
                       :title "ETAF 扩展中心"
                       :at 'frame-center
                       :width pw
                       :height ph
                       :draggable t
                       :resizable t
                       :focusable t
                       :focus-on-open t
                       :theme 'auto)))
          (setq etaf-ext--manage-popup-state
                (list :panel panel :cleanup (plist-get sess :cleanup)))
          panel)))))

(provide 'etaf-ext-ui)
;;; etaf-ext-ui.el ends here
