;;; etaf-devtools-view.el --- ETAF UI presentation for etaf-devtools -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Renders the `etaf-devtools' interface using public `etaf' and `etaf-ui'
;; components only.  Faithfully reproduces the approved visual design:
;; zero `:font-size' overrides, theme-derived colours, 1px hairline borders,
;; 3px left selection rail, restrained hover feedback, pure-text 4-layer Box
;; Model diagram, ECSS provenance with strikethrough overrides and WCAG contrast
;; badges, live in-place ref editing, Braille Perf sparkline, Focus/Keys
;; diagnostics and 3-tier responsive layout (`wide' / `medium' / `narrow').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-devtools-core)
(require 'etaf-devtools-overlay)
(require 'etaf-devtools-target)
(require 'etaf-devtools-model)

(declare-function etaf-devtools-inspect "etaf-devtools-ui" (&optional runtime))
(declare-function etaf-devtools-toggle-dock "etaf-devtools-ui" ())

;;;; Tree flattening & filtering helpers (pure functions)

(defun etaf-devtools--node-matches-query-p (node query)
  "Return non-nil when tree NODE matches case-insensitive search QUERY."
  (if (string-empty-p query)
      t
    (let ((q (downcase query))
          (kind (plist-get node :kind)))
      (pcase kind
        ('component
         (or (string-match-p (regexp-quote q)
                             (downcase (symbol-name (or (plist-get node :name) 'comp))))
             (let ((key (plist-get node :key)))
               (and key (string-match-p (regexp-quote q)
                                        (downcase (etaf-devtools--safe-print key 40)))))
             (let ((ps (plist-get node :props-summary)))
               (and (stringp ps) (string-match-p (regexp-quote q) (downcase ps))))))
        ('host
         (let ((tag (symbol-name (or (plist-get node :tag) 'host)))
               (did (or (plist-get node :dom-id) ""))
               (cls (mapconcat #'identity (or (plist-get node :classes) nil) " "))
               (ref (if-let* ((r (plist-get node :ref))) (format "%s" r) ""))
               (txt (or (plist-get node :text-preview) "")))
           (cond
            ((string-prefix-p "#" q)
             (string-match-p (regexp-quote (substring q 1)) (downcase did)))
            ((string-prefix-p "." q)
             (string-match-p (regexp-quote (substring q 1)) (downcase cls)))
            (t
             (or (string-match-p (regexp-quote q) (downcase tag))
                 (string-match-p (regexp-quote q) (downcase did))
                 (string-match-p (regexp-quote q) (downcase cls))
                 (string-match-p (regexp-quote q) (downcase ref))
                 (string-match-p (regexp-quote q) (downcase txt)))))))))))

(defun etaf-devtools--subtree-matches-p (node query mode)
  "Return non-nil when NODE or a visible descendant matches QUERY in MODE."
  (let ((visible (or (eq mode 'full) (eq (plist-get node :kind) 'component))))
    (or (and visible (etaf-devtools--node-matches-query-p node query))
        (cl-some (lambda (kid) (etaf-devtools--subtree-matches-p kid query mode))
                 (plist-get node :children)))))

(defun etaf-devtools--flatten-tree (tree mode expanded query)
  "Flatten TREE into display rows for MODE (`full' or `components').
Each row is a plist `(:kind :id :depth :has-children :expanded :node)'."
  (let ((rows nil)
        (searching (not (string-empty-p (string-trim (or query ""))))))
    (cl-labels ((walk (nodes depth)
                  (dolist (node nodes)
                    (let* ((kind (plist-get node :kind))
                           (id (plist-get node :id))
                           (kids (plist-get node :children))
                           (show-self (or (eq mode 'full) (eq kind 'component))))
                      (if (not show-self)
                          (walk kids depth)
                        (when (or (not searching)
                                  (etaf-devtools--subtree-matches-p node query mode))
                          (let* ((uid (etaf-devtools--node-uid kind id))
                                 (visible-kids
                                  (if (eq mode 'full)
                                      kids
                                    (cl-some (lambda (k)
                                               (etaf-devtools--subtree-matches-p k "" 'components))
                                             kids)))
                                 (has-kids (and visible-kids t))
                                 (is-exp (or searching
                                             (and (hash-table-p expanded)
                                                  (gethash uid expanded)))))
                            (push (list :kind kind :id id :depth depth
                                        :has-children has-kids :expanded is-exp
                                        :node node)
                                  rows)
                            (when (and has-kids is-exp)
                              (walk kids (1+ depth))))))))))
      (walk tree 0))
    (nreverse rows)))

(defun etaf-devtools--step-selection (session delta)
  "Move selected tree row in SESSION by DELTA (+1 or -1)."
  (let* ((rows (etaf-devtools--flatten-tree
                (etaf-value (etaf-devtools-session-tree-ref session))
                (etaf-value (etaf-devtools-session-tree-mode-ref session))
                (etaf-value (etaf-devtools-session-expanded-ref session))
                (etaf-value (etaf-devtools-session-search-ref session))))
         (sk (etaf-value (etaf-devtools-session-selected-kind-ref session)))
         (sid (etaf-value (etaf-devtools-session-selected-id-ref session))))
    (when rows
      (let* ((cur (or (cl-position-if
                       (lambda (r)
                         (and (eq (plist-get r :kind) sk)
                              (eql (plist-get r :id) sid)))
                       rows)
                      0))
             (next-idx (max 0 (min (1- (length rows)) (+ cur delta))))
             (target (nth next-idx rows)))
        (etaf-devtools--session-select-node
         session (plist-get target :kind) (plist-get target :id))))))

;;;; Reusable visual primitives (strict hover & typography discipline)

(defun etaf-devtools--chip (label active pal on-press &optional variant-color help)
  "Render a crisp single-row border-framed control chip without hover on active."
  (let* ((fg (if active (or variant-color (plist-get pal :accent)) (plist-get pal :muted)))
         (bg (if active
                 (cond
                  ((equal variant-color (plist-get pal :ok)) (plist-get pal :ok-soft))
                  ((equal variant-color (plist-get pal :warn)) (plist-get pal :warn-soft))
                  (t (plist-get pal :accent-soft)))
               (plist-get pal :surface)))
         (bdr (if active (or variant-color (plist-get pal :accent)) (plist-get pal :line-soft))))
    (etaf-view
     (box :padding '((lh 0) (ch 1))
          :background-color bg
          :border-top-width '(px 1) :border-top-style 'solid :border-top-color bdr
          :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color bdr
          :border-left-width '(px 1) :border-left-style 'solid :border-left-color bdr
          :border-right-width '(px 1) :border-right-style 'solid :border-right-color bdr
          :flex-shrink 0
          :tab-index 0
          :aria-label label
          :aria-selected active
          :help-echo help
          :pointer (unless active 'hand)
          :hover-style (unless active (list :background-color (plist-get pal :hover)))
          :on-press on-press
          (text :color fg :font-weight (if active 'bold 'normal) (expr label))))))

(defun etaf-devtools--action-btn (label pal on-press &optional help primary)
  "Render a crisp inline button with proper hover behavior."
  (let ((bg (if primary (plist-get pal :accent) (plist-get pal :surface2)))
        (fg (if primary (plist-get pal :accent-fg) (plist-get pal :ink)))
        (bdr (if primary (plist-get pal :accent) (plist-get pal :line))))
    (etaf-view
     (box :padding '((lh 0) (ch 1))
          :background-color bg
          :border-top-width '(px 1) :border-top-style 'solid :border-top-color bdr
          :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color bdr
          :border-left-width '(px 1) :border-left-style 'solid :border-left-color bdr
          :border-right-width '(px 1) :border-right-style 'solid :border-right-color bdr
          :flex-shrink 0
          :tab-index 0
          :aria-label label
          :help-echo help
          :pointer 'hand
          :hover-style (unless primary (list :background-color (plist-get pal :hover)))
          :on-press on-press
          (text :color fg :font-weight (if primary 'bold 'normal) (expr label))))))

;;;; Top bar & Tab bar

(defun etaf-devtools--header-view (session pal layout)
  "Render top target bar matching the approved visual design."
  (let* ((target (etaf-value (etaf-devtools-session-target-ref session)))
         (targets (etaf-value (etaf-devtools-session-targets-ref session)))
         (pinned (etaf-value (etaf-devtools-session-pinned-ref session)))
         (hl (etaf-value (etaf-devtools-session-highlight-ref session)))
         (picking (etaf-value (etaf-devtools-session-picker-active-ref session)))
         (dock (etaf-value (etaf-devtools-session-dock-ref session)))
         (compact (eq layout 'narrow))
         (tname (if target
                    (etaf-devtools--truncate (etaf-devtools--runtime-label target) (if compact 15 22))
                  "无 ETAF 目标"))
         (dock-label (pcase dock
                       ('right (if compact "切窗" "右侧 d"))
                       ('bottom (if compact "切窗" "底部 d"))
                       (_ (if compact "切窗" "浮窗 d")))))
    (etaf-view
     (flex :flex-direction 'row
           :width 'stretch
           :padding '((lh 0) (ch 1))
           :background-color (plist-get pal :surface)
           :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line)
           :column-gap '(ch 1)
           :align-items 'center
          (box :padding '((lh 0) (ch 1))
               :background-color (plist-get pal :surface2)
               :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :line)
               :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line)
               :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :line)
               :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :line)
               :flex-shrink 0
               :tab-index 0
               :aria-label "切换调试目标"
               :pointer (when (> (length targets) 1) 'hand)
               :hover-style (when (> (length targets) 1)
                              (list :background-color (plist-get pal :hover)))
               :help-echo "点击循环切换已挂载的 ETAF 目标 buffer"
               :on-press (lambda ()
                           (when (> (length targets) 1)
                             (let* ((idx (or (cl-position target targets :test #'eq) 0))
                                    (next (nth (mod (1+ idx) (length targets)) targets)))
                               (etaf-devtools--session-set-target session next t))))
               (text :color (plist-get pal :ink) :font-weight 'bold
                     (expr (if (> (length targets) 1) (format "%s ▾" tname) tname))))
          (expr (unless compact
                  (etaf-devtools--chip
                   (if pinned "Pin ●" "Pin") pinned pal
                   (lambda ()
                     (etaf-update-value (etaf-devtools-session-pinned-ref session) #'not))
                   (plist-get pal :accent)
                   "锁定当前目标或自动跟随活跃 ETAF buffer (p)")))
          (box :flex-basis '(ch 0) :flex-grow 1)
          (box :padding '((lh 0) (ch 1))
               :background-color (if picking (plist-get pal :accent) (plist-get pal :accent-soft))
               :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :accent)
               :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :accent)
               :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :accent)
               :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :accent)
               :flex-shrink 0
               :tab-index 0
               :aria-label "进入元素拾取器"
               :aria-selected picking
               :pointer (unless picking 'hand)
               :help-echo "进入元素拾取器 (i)"
               :on-press (lambda () (etaf-devtools-inspect target))
               (text :color (if picking (plist-get pal :accent-fg) (plist-get pal :accent))
                     :font-weight 'bold
                     (expr (if compact "拾取" "拾取 i"))))
          (expr (unless compact
                  (etaf-devtools--chip
                   "闪框 h" hl pal
                   (lambda ()
                     (when target
                       (let ((next (not hl)))
                         (etaf-devtools--set-highlight-updates target next)
                         (etaf-set-value (etaf-devtools-session-highlight-ref session) next))))
                   (plist-get pal :ok)
                   "开关重绘热区闪框 (h)")))
          (expr (etaf-devtools--chip
                 dock-label nil pal
                 (lambda () (etaf-devtools-toggle-dock))
                 nil
                 "切换右侧停靠 / 底部停靠 / 浮动 Posframe (d)"))))))

(defun etaf-devtools--tabs-view (session pal layout)
  "Render 6-tab navigation strip with zero hover on active tab."
  (let* ((active (etaf-value (etaf-devtools-session-tab-ref session)))
         (compact (eq layout 'narrow))
         (items (if compact
                    '((tree . "1 树") (styles . "2 样") (state . "3 态")
                      (perf . "4 能") (keys . "5 键") (runtime . "6 运"))
                  '((tree . "1 Tree") (styles . "2 Styles") (state . "3 State")
                    (perf . "4 Perf") (keys . "5 Keys") (runtime . "6 Runtime")))))
    (etaf-view
     (row :width 'stretch
          :padding '((lh 0) (ch 1))
          :background-color (plist-get pal :bg)
          :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line)
          :item-gap (if compact '(ch 0) '(ch 1))
          :focus-group 'horizontal
          (expr
           (mapcar
            (lambda (item)
              (let* ((tid (car item))
                     (label (cdr item))
                     (sel (eq tid active)))
                (etaf-view
                 (box :key tid
                      :padding '((lh 0) (ch 1))
                      :background-color (if sel (plist-get pal :accent-soft) (plist-get pal :bg))
                      :border-bottom-width (if sel '(px 1) '(px 0))
                      :border-bottom-style (if sel 'solid 'none)
                      :border-bottom-color (plist-get pal :accent)
                      :flex-shrink 0
                      :tab-index 0
                      :aria-label label
                      :aria-selected sel
                      :pointer (unless sel 'hand)
                      :hover-style (unless sel (list :background-color (plist-get pal :hover)))
                      :on-press (lambda ()
                                  (etaf-set-value (etaf-devtools-session-tab-ref session) tid)
                                  (etaf-set-value (etaf-devtools-session-narrow-detail-ref session) nil)
                                  (when (eq tid 'keys) (etaf-devtools--refresh-focus session))
                                  (when (eq tid 'perf) (etaf-devtools--refresh-perf session)))
                      (text :color (if sel (plist-get pal :accent) (plist-get pal :muted))
                            :font-weight (if sel 'bold 'normal)
                            (expr label))))))
            items))))))

;;;; Panel 1: Tree view

(defun etaf-devtools--tree-row-view (session row pal sel-kind sel-id layout pane-cols)
  "Render one single-line flattened tree ROW with 3px left rail on selection."
  (let* ((kind (plist-get row :kind))
         (id (plist-get row :id))
         (depth (plist-get row :depth))
         (has-kids (plist-get row :has-children))
         (expanded (plist-get row :expanded))
         (node (plist-get row :node))
         (selected (and (eq kind sel-kind) (eql id sel-id)))
         (indent (make-string (* depth 2) ?\s))
         (arrow (cond ((not has-kids) "  ")
                      (expanded "▾ ")
                      (t "▸ ")))
         (is-comp (eq kind 'component))
         (head (if is-comp
                   (format "<%s>" (plist-get node :name))
                 (symbol-name (or (plist-get node :tag) 'host))))
         (meta
          (if is-comp
              (let ((key (plist-get node :key))
                    (ps (plist-get node :props-summary)))
                (concat (format " #%d" id)
                        (if key (format " key:%s" (etaf-devtools--safe-print key 14)) "")
                        (if (and ps (not (string-empty-p ps)) (not (eq layout 'narrow)))
                            (format " %s" ps)
                          "")))
            (let ((cls (plist-get node :classes))
                  (did (plist-get node :dom-id))
                  (ref (plist-get node :ref))
                  (txt (plist-get node :text-preview)))
              (concat (if cls (concat "." (mapconcat #'identity cls ".")) "")
                      (if did (format "#%s" did) "")
                      (if (and ref (not did)
                               (not (and (consp ref) (eq (car ref) 'etaf-host))))
                          (format " :ref %s" ref) "")
                      (if txt (format " %s" txt) "")))))
         (extra
          (if is-comp
              (let ((rc (or (plist-get node :render-count) 1)))
                (when (> rc 1) (format " ×%d" rc)))
            (let ((pres (plist-get node :presentations))
                  (geo (plist-get node :geometry)))
              (cond
               (pres (format " [pres: %s]" (mapconcat #'symbol-name pres ",")))
               ((and selected geo)
                (format " %d×%dL"
                        (or (plist-get geo :width) 0)
                        (or (plist-get geo :height) 0)))
               (t nil)))))
         (used (+ 3 (* depth 2) 2 (string-width head) (if extra (string-width extra) 0)))
         (meta-budget (max 0 (- pane-cols used 1)))
         (meta-fit (if (and (> meta-budget 2) (not (string-empty-p meta)))
                       (etaf-devtools--truncate meta meta-budget)
                     ""))
         (head-col (if is-comp (plist-get pal :accent)
                     (if selected (plist-get pal :ink) (plist-get pal :kw)))))
    (etaf-view
     (flex :key (format "%s:%s" kind id)
           :flex-direction 'row
           :width 'stretch
           :padding '((lh 0) (ch 1))
           :background-color (if selected (plist-get pal :select) (plist-get pal :bg))
           :border-left-width (if selected '(px 3) '(px 0))
           :border-left-style (if selected 'solid 'none)
           :border-left-color (plist-get pal :accent)
           :tab-index 0
           :aria-selected selected
           :aria-label (format "%s%s" head meta)
           :on-press (lambda ()
                       (etaf-devtools--session-select-node
                        session kind id nil (eq layout 'narrow)))
           (text :color (plist-get pal :dim) (expr indent))
           (box :flex-shrink 0
                :pointer (when has-kids 'hand)
                :on-press (when has-kids
                            (lambda ()
                              (etaf-devtools--session-toggle-expand session kind id)))
                (text :color (plist-get pal :dim) (expr arrow)))
           (box :flex-basis '(ch 0) :flex-grow 1 :overflow 'hidden
                :pointer (unless selected 'hand)
                :hover-style (unless selected (list :background-color (plist-get pal :hover)))
                (row :item-gap '(ch 0)
                     (text :color head-col
                           :font-weight (if (or selected is-comp) 'bold 'normal)
                           (expr head))
                     (expr (when (not (string-empty-p meta-fit))
                             (etaf-view
                              (text :color (if selected (plist-get pal :ink) (plist-get pal :muted))
                                    (expr meta-fit)))))
                     (expr (when extra
                             (etaf-view
                              (text :color (if (and (not is-comp) (string-match-p "pres" extra))
                                               (plist-get pal :warn)
                                             (if selected (plist-get pal :ok) (plist-get pal :dim)))
                                    (expr extra)))))))))))

(defun etaf-devtools--tree-pane-view (session pal layout height-rows pane-cols)
  "Render Tree toolbar + scrollable node list."
  (let* ((mode (etaf-value (etaf-devtools-session-tree-mode-ref session)))
         (query (etaf-value (etaf-devtools-session-search-ref session)))
         (tree (etaf-value (etaf-devtools-session-tree-ref session)))
         (expanded (etaf-value (etaf-devtools-session-expanded-ref session)))
         (sel-kind (etaf-value (etaf-devtools-session-selected-kind-ref session)))
         (sel-id (etaf-value (etaf-devtools-session-selected-id-ref session)))
         (rows (etaf-devtools--flatten-tree tree mode expanded query))
         (comp-active (eq mode 'components))
         (full-active (eq mode 'full)))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
             (flex :flex-direction 'row
                   :width 'stretch
                   :padding '((lh 0) (ch 1))
                   :column-gap '(ch 1)
                   :align-items 'center
                  (row :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :line)
                       :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line)
                       :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :line)
                       :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :line)
                       :flex-shrink 0
                       (box :padding '((lh 0) (ch 1))
                            :background-color (if comp-active (plist-get pal :select) (plist-get pal :surface))
                            :tab-index 0
                            :aria-selected comp-active
                            :pointer (unless comp-active 'hand)
                            :hover-style (unless comp-active (list :background-color (plist-get pal :hover)))
                            :on-press (lambda ()
                                        (etaf-set-value (etaf-devtools-session-tree-mode-ref session) 'components))
                            (text :color (if comp-active (plist-get pal :ink) (plist-get pal :muted))
                                  :font-weight (if comp-active 'bold 'normal)
                                  "组件"))
                       (box :padding '((lh 0) (ch 1))
                            :background-color (if full-active (plist-get pal :select) (plist-get pal :surface))
                            :tab-index 0
                            :aria-selected full-active
                            :pointer (unless full-active 'hand)
                            :hover-style (unless full-active (list :background-color (plist-get pal :hover)))
                            :on-press (lambda ()
                                        (etaf-set-value (etaf-devtools-session-tree-mode-ref session) 'full))
                            (text :color (if full-active (plist-get pal :ink) (plist-get pal :muted))
                                  :font-weight (if full-active 'bold 'normal)
                                  "完整树")))
                  (box :flex-basis '(ch 0) :flex-grow 1
                       :padding '((lh 0) (ch 1))
                       :background-color (plist-get pal :surface)
                       :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :line)
                       :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line)
                       :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :line)
                       :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :line)
                       (etaf-text-input
                        :ref 'dt-tree-search
                        :bind (etaf-devtools-session-search-ref session)
                        :variant 'plain
                        :hide-label t
                        :rows 1
                        :placeholder (if (eq layout 'narrow)
                                         "/ 过滤节点..."
                                       "/ 搜组件、#id、.class 或文本..."))))
             (box :width 'stretch
                  :height (list 'lh (max 4 height-rows))
                  :overflow 'scroll
                  :focus-group 'vertical
                  (expr
                   (if rows
                       (mapcar (lambda (r)
                                 (etaf-devtools--tree-row-view
                                  session r pal sel-kind sel-id layout pane-cols))
                               rows)
                     (list
                      (etaf-view
                       (box :padding '((lh 1) (ch 2))
                            (text :color (plist-get pal :muted)
                                  (expr (if tree "没有匹配当前过滤条件的节点"
                                          "当前没有已挂载的 ETAF 应用；打开任意 ETAF 应用后将自动连接")))))))))))))

;;;; Panel 2: Pure-text 4-layer Box Model & ECSS Cascade Provenance

(defun etaf-devtools--box-model-view (metrics geo visible-p pal)
  "Render pure-text 4-layer Box Model diagram faithful to approved SVG."
  (let* ((m (plist-get metrics :margin))
         (b (plist-get metrics :border))
         (pad (plist-get metrics :padding))
         (bb (plist-get metrics :border-box))
         (cb (plist-get metrics :content-box))
         (mt (or (plist-get m :top) 0))
         (mb (or (plist-get m :bottom) 0))
         (ml (or (plist-get m :left) 0))
         (mr (or (plist-get m :right) 0))
         (bt (or (plist-get b :top) 0))
         (bl (or (plist-get b :left) 0))
         (pt (or (plist-get pad :top) 0))
         (pb (or (plist-get pad :bottom) 0))
         (pl (or (plist-get pad :left) 0))
         (pr (or (plist-get pad :right) 0))
         (bw (or (plist-get bb :width) (plist-get geo :width) 0))
         (bh (or (plist-get bb :height) (plist-get geo :height) 0))
         (cw (or (plist-get cb :width) bw))
         (ch (or (plist-get cb :height) bh))
         (lkind (or (plist-get metrics :layout-kind) 'flow))
         (gap (or (plist-get metrics :gap) 0))
         (scroll (or (plist-get metrics :scroll) 0))
         (vh (or (plist-get metrics :viewport-height) ch)))
    (etaf-view
     (column :width 'stretch
             :padding '((lh 0) (ch 1))
             :item-gap '(lh 0)
             ;; Outer: margin box
             (box :width 'stretch
                  :background-color (plist-get pal :box-margin)
                  :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :line)
                  :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line)
                  :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :line)
                  :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :line)
                  :padding '((lh 0) (ch 1))
                  (flex :flex-direction 'row :width 'stretch
                        (text :color (plist-get pal :warn) :font-weight 'bold "margin")
                        (box :flex-basis '(ch 0) :flex-grow 1 :text-align 'center
                             (text :color (if (> mt 0) (plist-get pal :warn) (plist-get pal :muted))
                                   (expr (format "%dL" mt))))
                        (text :color (plist-get pal :dim) "      "))
                  (flex :flex-direction 'row :width 'stretch :column-gap '(ch 1) :align-items 'center
                        (text :color (plist-get pal :muted) (expr (format "%3d" ml)))
                        ;; Border box
                        (box :flex-basis '(ch 0) :flex-grow 1
                             :background-color (plist-get pal :box-border)
                             :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :accent)
                             :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :accent)
                             :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :accent)
                             :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :accent)
                             :padding '((lh 0) (ch 1))
                             (row :width 'stretch
                                  (text :color (plist-get pal :accent)
                                        (expr (format "border %dpx/%dL" bl bt))))
                             ;; Padding box
                             (box :width 'stretch
                                  :background-color (plist-get pal :box-padding)
                                  :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :ok)
                                  :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :ok)
                                  :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :ok)
                                  :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :ok)
                                  :padding '((lh 0) (ch 1))
                                  (flex :flex-direction 'row :width 'stretch
                                        (text :color (plist-get pal :ok) "padding")
                                        (box :flex-basis '(ch 0) :flex-grow 1 :text-align 'center
                                             (text :color (plist-get pal :ok) (expr (format "%dL" pt))))
                                        (text :color (plist-get pal :dim) "       "))
                                  (flex :flex-direction 'row :width 'stretch :column-gap '(ch 1) :align-items 'center
                                        (text :color (plist-get pal :ok) (expr (format "%2d" pl)))
                                        ;; Content box
                                        (box :flex-basis '(ch 0) :flex-grow 1
                                             :background-color (plist-get pal :box-content)
                                             :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :accent)
                                             :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :accent)
                                             :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :accent)
                                             :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :accent)
                                             :text-align 'center
                                             (text :color (plist-get pal :ink) :font-weight 'bold
                                                   (expr (format "%dpx × %dL" cw ch))))
                                        (text :color (plist-get pal :ok) (expr (format "%2d" pr))))
                                  (box :width 'stretch :text-align 'center
                                       (text :color (plist-get pal :ok) (expr (format "%dL" pb))))))
                        (text :color (plist-get pal :muted) (expr (format "%3d" mr))))
                  (box :width 'stretch :text-align 'center
                       (text :color (if (> mb 0) (plist-get pal :warn) (plist-get pal :muted))
                             :font-weight (if (> mb 0) 'bold 'normal)
                             (expr (format "%dL" mb)))))
             ;; Metrics summary strip
             (row :width 'stretch :padding '((lh 0) (ch 0)) :item-gap '(ch 1)
                  (text :color (plist-get pal :muted) "边框盒")
                  (text :color (plist-get pal :ink) :font-weight 'bold (expr (format "%dpx × %dL" bw bh)))
                  (text :color (plist-get pal :muted)
                        (expr (format "· %s · gap %s · scroll %d/%d ·" lkind gap scroll vh)))
                  (text :color (if visible-p (plist-get pal :ok) (plist-get pal :warn))
                        :font-weight 'bold
                        (expr (if visible-p "visible" "clipped"))))))))

(defun etaf-devtools--decl-row-view (decl pal bg-ref)
  "Render one ECSS declaration row with swatch, strikethrough and WCAG check."
  (let* ((prop (plist-get decl :property))
         (val (plist-get decl :value))
         (preview (or (plist-get decl :value-preview) (etaf-devtools--safe-print val 44)))
         (winner (plist-get decl :winner))
         (is-hex (etaf-devtools--hex-color-p val))
         (contrast (when (and is-hex (eq prop :color) (etaf-devtools--hex-color-p bg-ref))
                     (etaf-ui-color-contrast val bg-ref))))
    (etaf-view
     (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
          (expr (when is-hex
                  (etaf-view
                   (text :color val :background-color val "  "))))
          (text :color (if winner (plist-get pal :kw) (plist-get pal :dim))
                :text-decoration-line (unless winner 'line-through)
                (expr (symbol-name prop)))
          (text :color (if winner (plist-get pal :ink) (plist-get pal :dim))
                :text-decoration-line (unless winner 'line-through)
                (expr (etaf-devtools--truncate preview 36)))
          (expr (when (not winner)
                  (etaf-view (text :color (plist-get pal :dim) "[已覆盖]"))))
          (expr (when contrast
                  (let ((ok-c (>= contrast 4.5)))
                    (etaf-view
                     (text :color (if ok-c (plist-get pal :ok) (plist-get pal :warn))
                           :font-weight 'bold
                           (expr (format "WCAG %.1f %s" contrast (if ok-c "✓" "!"))))))))))))

(defun etaf-devtools--styles-inspector-view (session pal height-rows)
  "Render selected Host breadcrumb, Box Model, ECSS rules and computed styles."
  (let* ((rt (etaf-value (etaf-devtools-session-target-ref session)))
         (host (etaf-value (etaf-devtools-session-host-snap-ref session)))
         (comp (etaf-value (etaf-devtools-session-comp-snap-ref session)))
         (only-spec (etaf-value (etaf-devtools-session-style-only-specified-ref session))))
    (if (not host)
        (etaf-view
         (box :padding '((lh 1) (ch 2))
              (text :color (plist-get pal :muted) "选中一个 Host 或 Component 查看盒模型与样式层叠")))
      (let* ((hid (plist-get host :id))
             (style (plist-get host :style))
             (vals (plist-get style :values))
             (bg-eff (or (plist-get vals :background-color) (plist-get pal :bg)))
             (rules (plist-get style :matched-rules))
             (metrics (plist-get host :box-metrics))
             (geo (plist-get host :geometry))
             (visible-p (plist-get host :visible-p))
             (comp-name (or (plist-get host :owner-component-name)
                            (and comp (plist-get comp :name))))
             (comp-file (and comp (plist-get comp :source-file))))
        (etaf-view
         (column :width 'stretch :item-gap '(lh 0)
                 ;; Breadcrumb + action strip
                 (flex :flex-direction 'row
                       :width 'stretch
                       :padding '((lh 0) (ch 1))
                       :background-color (plist-get pal :surface)
                       :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :line)
                       :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line-soft)
                       :column-gap '(ch 1)
                       :align-items 'center
                      (box :flex-basis '(ch 0) :flex-grow 1 :overflow 'hidden
                           (text :color (plist-get pal :accent) :font-weight 'bold
                                 (expr (etaf-devtools--truncate (etaf-devtools--host-label host) 38))))
                      (expr (when comp-name
                              (etaf-devtools--action-btn
                               "源码 g" pal
                               (lambda ()
                                 (etaf-devtools--jump-to-component comp-name comp-file))
                               "跳转到 Component 定义源码")))
                      (expr (etaf-devtools--action-btn
                             "定位 v" pal
                             (lambda ()
                               (when (and rt (etaf-runtime-mounted-p rt))
                                 (when-let* ((ref (plist-get host :ref)))
                                   (ignore-errors (etaf-scroll-into-view rt ref)))
                                 (etaf-devtools--overlay-highlight-host rt hid t)))
                             "滚动并高亮目标 Host"))
                      (expr (when (plist-get host :has-press-p)
                              (etaf-devtools--action-btn
                               "点击 a" pal
                               (lambda ()
                                 (when (and rt (etaf-runtime-mounted-p rt))
                                   (etaf-runtime-trigger-host-press rt hid)))
                               "派发此 Host 的 :on-press 回调"))))
                 ;; Scrollable inspector body
                 (box :width 'stretch
                      :height (list 'lh (max 5 height-rows))
                      :overflow 'scroll
                      (column :width 'stretch :item-gap '(lh 0)
                              (expr (when metrics
                                      (etaf-devtools--box-model-view metrics geo visible-p pal)))
                              ;; ECSS Rules Header
                              (flex :flex-direction 'row :width 'stretch
                                    :padding '((lh 0) (ch 1))
                                    :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :line-soft)
                                    :column-gap '(ch 1) :align-items 'center
                                    (text :color (plist-get pal :ink) :font-weight 'bold "ECSS 层叠溯源")
                                    (box :flex-basis '(ch 0) :flex-grow 1)
                                   (expr (etaf-devtools--chip
                                          (if only-spec "仅显式" "全部计算") nil pal
                                          (lambda ()
                                            (etaf-update-value
                                             (etaf-devtools-session-style-only-specified-ref session)
                                             #'not))
                                          nil "切换显示仅显式声明或全部计算属性")))
                              ;; Matched rules
                              (expr
                               (if rules
                                   (mapcar
                                    (lambda (rule)
                                      (let* ((inline-p (plist-get rule :inline))
                                             (sel (plist-get rule :selector))
                                             (spec (plist-get rule :specificity))
                                             (owner (plist-get rule :owner-component-name))
                                             (decls (plist-get rule :declarations)))
                                        (etaf-view
                                         (column :padding '((lh 0) (ch 1))
                                                 (row :item-gap '(ch 1)
                                                      (text :color (plist-get pal :accent) :font-weight 'bold
                                                            (expr (if inline-p "Inline 声明" (or sel "rule"))))
                                                      (text :color (plist-get pal :dim)
                                                            (expr (if inline-p
                                                                "(行内优先)"
                                                              (format "spec %S%s"
                                                                      spec
                                                                      (if owner (format " · scope %s" owner) ""))))))
                                                 (expr (mapcar (lambda (d)
                                                                 (etaf-devtools--decl-row-view d pal bg-eff))
                                                               decls))))))
                                    rules)
                                 (list
                                  (etaf-view
                                   (box :padding '((lh 0) (ch 2))
                                        (text :color (plist-get pal :dim) "无显式规则命中（全部继承或取默认值）"))))))
                              ;; Computed properties section
                              (expr
                               (when (not only-spec)
                                 (let ((entries nil))
                                   (cl-loop for (k v) on vals by #'cddr do
                                            (when v (push (cons k v) entries)))
                                   (etaf-view
                                    (column :padding '((lh 0) (ch 1))
                                            :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :line-soft)
                                            (text :color (plist-get pal :muted) :font-weight 'bold
                                                  (expr (format "计算样式 (%d 项非空)" (length entries))))
                                            (expr
                                             (mapcar
                                              (lambda (kv)
                                                (etaf-view
                                                 (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                                      (text :color (plist-get pal :kw) (expr (symbol-name (car kv))))
                                                      (text :color (plist-get pal :ink)
                                                            (expr (etaf-devtools--safe-print (cdr kv) 48))))))
                                              (nreverse entries))))))))))))))))

;;;; Panel 3: State & Reactivity (with Live In-Place Ref Edit)

(defun etaf-devtools--binding-row-view (session b pal editing-name edit-err)
  "Render one Component binding row with in-place ref editing."
  (let* ((name (plist-get b :name))
         (kind (plist-get b :kind))
         (val (plist-get b :value))
         (preview (or (plist-get b :value-preview) "nil"))
         (editable (plist-get b :editable-p))
         (is-editing (eq name editing-name))
         (ver (plist-get b :version))
         (subs (plist-get b :sub-count))
         (deps (plist-get b :deps))
         (subs-list (plist-get b :subs))
         (badge (pcase kind
                  ('ref (format "[ref v%d · %d subs]" (or ver 0) (or subs 0)))
                  ('computed (format "[computed v%d · %d deps]" (or ver 0) (or (plist-get b :dep-count) 0)))
                  ('resource (format "[resource: %s]" (plist-get b :status)))
                  ('data-controller (format "[data: %s · %s]" (plist-get b :status) (plist-get b :total)))
                  (_ "[value]")))
         (badge-col (pcase kind
                      ('ref (plist-get pal :accent))
                      ('computed (plist-get pal :kw))
                      ('resource (if (eq (plist-get b :status) 'error)
                                     (plist-get pal :danger) (plist-get pal :ok)))
                      ('data-controller (plist-get pal :ok))
                      (_ (plist-get pal :dim)))))
    (etaf-view
     (column :key name
             :width 'stretch
             :padding '((lh 0) (ch 1))
             :background-color (if is-editing (plist-get pal :select) (plist-get pal :bg))
             :border-top-width (if is-editing '(px 1) '(px 0))
             :border-top-style (if is-editing 'solid 'none)
             :border-top-color (plist-get pal :accent)
             :border-bottom-width (if is-editing '(px 1) '(px 0))
             :border-bottom-style (if is-editing 'solid 'none)
             :border-bottom-color (plist-get pal :accent)
             (flex :flex-direction 'row :width 'stretch :column-gap '(ch 1) :align-items 'center
                   (text :color (plist-get pal :ink) :font-weight 'bold (expr (symbol-name name)))
                   (text :color badge-col (expr badge))
                   (expr
                    (if is-editing
                        (etaf-view
                         (flex :flex-direction 'row :flex-basis '(ch 0) :flex-grow 1 :column-gap '(ch 1) :align-items 'center
                               (box :flex-basis '(ch 0) :flex-grow 1
                                    :padding '((lh 0) (ch 1))
                                    :background-color (plist-get pal :surface)
                                    :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :accent)
                                    :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :accent)
                                    :border-left-width '(px 1) :border-left-style 'solid :border-left-color (plist-get pal :accent)
                                    :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :accent)
                                    (etaf-text-input
                                     :ref 'dt-ref-editor
                                     :variant 'plain
                                     :hide-label t
                                     :rows 1
                                     :bind (etaf-devtools-session-edit-draft-ref session)
                                     :submit-on-return t
                                     :on-submit (lambda (_v)
                                                  (etaf-devtools--session-commit-edit-binding session))
                                     :on-cancel (lambda ()
                                                  (etaf-devtools--session-cancel-edit-binding session))))
                               (expr (etaf-devtools--action-btn
                                      "应用" pal
                                      (lambda () (etaf-devtools--session-commit-edit-binding session))
                                      "写入新值到 etaf-ref" t))
                               (expr (etaf-devtools--action-btn
                                      "取消" pal
                                      (lambda () (etaf-devtools--session-cancel-edit-binding session))
                                      "取消编辑"))))
                      (etaf-view
                       (flex :flex-direction 'row :flex-basis '(ch 0) :flex-grow 1 :column-gap '(ch 1) :align-items 'center
                             (text :color (plist-get pal :muted) "=")
                             (box :flex-basis '(ch 0) :flex-grow 1 :overflow 'hidden
                                  (text :color (plist-get pal :ink)
                                        (expr (etaf-devtools--truncate preview 36))))
                             (expr (when (and editable (memq val '(nil t)))
                                     (etaf-devtools--action-btn
                                      "切换" pal
                                      (lambda ()
                                        (etaf-devtools--session-toggle-bool-binding session name val))
                                      "快速翻转布尔值")))
                             (expr (when editable
                                     (etaf-devtools--action-btn
                                      "编辑" pal
                                      (lambda ()
                                        (etaf-devtools--session-begin-edit-binding session name preview))
                                      "原地修改该 etaf-ref 的值"))))))))
             (expr (when (and is-editing edit-err)
                     (etaf-view (text :color (plist-get pal :danger) (expr (format "错误: %s" edit-err))))))
             (expr (when (or deps subs-list)
                     (etaf-view
                      (text :color (plist-get pal :dim)
                            (expr (format "  ↳ %s%s"
                                    (if deps (format "依赖: %s  " (mapconcat #'identity deps ", ")) "")
                                    (if subs-list (format "下游: %s" (mapconcat #'identity subs-list ", ")) "")))))))))))

(defun etaf-devtools--state-pane-view (session pal height-rows)
  "Render State & Reactivity panel for the selected Component instance."
  (let* ((comp (etaf-value (etaf-devtools-session-comp-snap-ref session)))
         (edit-name (etaf-value (etaf-devtools-session-edit-binding-ref session)))
         (edit-err (etaf-value (etaf-devtools-session-edit-error-ref session))))
    (if (not comp)
        (etaf-view
         (box :padding '((lh 1) (ch 2))
              (text :color (plist-get pal :muted)
                    "当前未选中 Component 实例（在 Tree 中选中任意组件或其子 Host 即可查看状态）")))
      (let ((cname (plist-get comp :name))
            (cid (plist-get comp :id))
            (cfile (plist-get comp :source-file))
            (rc (or (plist-get comp :render-count) 1))
            (props (plist-get comp :props))
            (bindings (plist-get comp :bindings))
            (ctx (plist-get comp :context))
            (lrefs (plist-get comp :local-refs)))
        (etaf-view
         (column :width 'stretch :item-gap '(lh 0)
                 (flex :flex-direction 'row :width 'stretch
                       :padding '((lh 0) (ch 1))
                       :background-color (plist-get pal :surface)
                       :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line-soft)
                       :column-gap '(ch 1) :align-items 'center
                       (text :color (plist-get pal :accent) :font-weight 'bold (expr (format "<%s>" cname)))
                       (text :color (plist-get pal :muted) (expr (format "#%d · 渲染 %d 次" cid rc)))
                       (box :flex-basis '(ch 0) :flex-grow 1 :overflow 'hidden
                            (text :color (plist-get pal :dim)
                                  (expr (if cfile (file-name-nondirectory cfile) ""))))
                       (expr (etaf-devtools--action-btn
                              "源码 g" pal
                              (lambda () (etaf-devtools--jump-to-component cname cfile))
                              "跳转到 Component 定义")))
                 (box :width 'stretch :height (list 'lh (max 6 height-rows))
                      :overflow 'scroll
                      (column :width 'stretch :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
                              ;; Props
                              (text :color (plist-get pal :muted) :font-weight 'bold
                                    (expr (format "Props (%d)" (length props))))
                              (expr
                               (if props
                                   (mapcar (lambda (pr)
                                             (etaf-view
                                              (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                                   (text :color (plist-get pal :kw) (expr (format ":%s" (plist-get pr :name))))
                                                   (text :color (plist-get pal :ink)
                                                         (expr (etaf-devtools--truncate (plist-get pr :value-preview) 48))))))
                                           props)
                                 (list (etaf-view (text :color (plist-get pal :dim) "  (无声明 props)")))))
                              ;; Bindings
                              (box :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                                   (text :color (plist-get pal :muted) :font-weight 'bold
                                         (expr (format "Bindings 响应式状态 (%d · 支持原地修改 ref)" (length bindings)))))
                              (expr
                               (if bindings
                                   (mapcar (lambda (b)
                                             (etaf-devtools--binding-row-view session b pal edit-name edit-err))
                                           bindings)
                                 (list (etaf-view (text :color (plist-get pal :dim) "  (无 :bindings 或 :setup 状态)")))))
                              ;; Context
                              (expr
                               (when ctx
                                 (etaf-view
                                  (column :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                                          (text :color (plist-get pal :muted) :font-weight 'bold
                                                (expr (format "Context (%d)" (length ctx))))
                                          (expr
                                           (mapcar (lambda (c)
                                                     (etaf-view
                                                      (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                                           (text :color (plist-get pal :kw) (expr (format "%S" (plist-get c :key))))
                                                           (text :color (plist-get pal :dim)
                                                                 (expr (etaf-devtools--truncate (plist-get c :value-preview) 44))))))
                                                   ctx))))))
                              ;; Local refs
                              (expr
                               (when lrefs
                                 (etaf-view
                                  (column :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                                          (text :color (plist-get pal :muted) :font-weight 'bold
                                                (expr (format "Local Refs (%d)" (length lrefs))))
                                          (expr
                                           (mapcar (lambda (lr)
                                                     (let ((hid (plist-get lr :host-id)))
                                                       (etaf-view
                                                        (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                                             (text :color (plist-get pal :kw) (expr (format "%S" (plist-get lr :name))))
                                                             (text :color (if hid (plist-get pal :ok) (plist-get pal :dim))
                                                                   (expr (if hid (format "→ Host #%d" hid) "(未挂载)")))))))
                                                   lrefs))))))))))))))

;;;; Panel 4: Perf & Flush Timeline

(defun etaf-devtools--perf-pane-view (session pal height-rows)
  "Render Flush history, Braille trend chart and `etaf-performance' stages."
  (let* ((flushes (etaf-value (etaf-devtools-session-flush-history-ref session)))
         (recording (etaf-value (etaf-devtools-session-recording-ref session)))
         (ops (etaf-value (etaf-devtools-session-perf-ops-ref session)))
         (total (length flushes))
         (inc-count (cl-count-if (lambda (f) (not (eq (plist-get f :strategy) 'full))) flushes))
         (inc-pct (if (> total 0) (round (* 100.0 (/ (float inc-count) total))) 100))
         (series (reverse (mapcar (lambda (f) (or (plist-get f :lines) 0))
                                  (cl-subseq flushes 0 (min 40 total))))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
             (flex :flex-direction 'row :width 'stretch
                   :padding '((lh 0) (ch 1))
                   :background-color (plist-get pal :surface)
                   :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line-soft)
                   :column-gap '(ch 1) :align-items 'center
                   (expr (etaf-devtools--chip
                          (if recording "● 停止录制 r" "○ 深度录制 r") recording pal
                          (lambda () (etaf-devtools--session-toggle-recording session))
                          (plist-get pal :danger)
                          "开启/停止 etaf-performance 阶段耗时录制 (r)"))
                   (expr (etaf-devtools--action-btn
                          "清空" pal
                          (lambda ()
                            (etaf-set-value (etaf-devtools-session-flush-history-ref session) nil)
                            (etaf-performance-clear)
                            (etaf-set-value (etaf-devtools-session-perf-ops-ref session) nil))
                          "清空当前 Flush 与性能记录"))
                   (expr (etaf-devtools--action-btn
                          "复制报告" pal
                          (lambda ()
                            (etaf-performance-copy-report)
                            (etaf-set-value (etaf-devtools-session-status-msg-ref session) "已复制性能报告到剪贴板"))
                          "复制 etaf-performance 报告"))
                   (box :flex-basis '(ch 0) :flex-grow 1)
                   (text :color (plist-get pal :muted)
                         (expr (format "Flush %d · 增量 %d%%" total inc-pct))))
             (box :width 'stretch :height (list 'lh (max 6 height-rows))
                  :overflow 'scroll
                  (column :width 'stretch :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
                          ;; Braille sparkline when >= 2 samples
                          (expr
                           (when (>= (length series) 2)
                             (etaf-view
                              (box :padding '((lh 0) (ch 0) (lh 1) (ch 0))
                                   (etaf-braille-chart
                                    :label (format "Flush 改写行数 (峰 %d · 现 %d 行)"
                                                   (apply #'max series)
                                                   (car (last series)))
                                    :values series
                                    :width 44
                                    :height 4)))))
                          ;; Recorded deep operations
                          (expr
                           (when ops
                             (etaf-view
                              (column :padding '((lh 0) (ch 0) (lh 1) (ch 0))
                                      (text :color (plist-get pal :ink) :font-weight 'bold
                                            (expr (format "深度性能记录 (%d 条 · 50ms 交互门槛)" (length ops))))
                                      (expr
                                       (mapcar
                                        (lambda (op)
                                          (let* ((ms (or (etaf-performance-operation-elapsed op) 0.0))
                                                 (gc (or (etaf-performance-operation-gc-count op) 0))
                                                 (over (> ms 50.0))
                                                 (stages (etaf-performance-operation-stage-summary op)))
                                            (etaf-view
                                             (column :padding '((lh 0) (ch 1))
                                                     (row :item-gap '(ch 1)
                                                          (text :color (if over (plist-get pal :danger) (plist-get pal :ok))
                                                                :font-weight 'bold
                                                                (expr (format "%6.2fms" ms)))
                                                          (text :color (plist-get pal :ink)
                                                                (expr (format "%s %s"
                                                                        (etaf-performance-operation-kind op)
                                                                        (or (etaf-performance-operation-label op) ""))))
                                                          (text :color (if (> gc 0) (plist-get pal :warn) (plist-get pal :dim))
                                                                (expr (format "GC:%d" gc))))
                                                     (expr
                                                      (when stages
                                                        (etaf-view
                                                         (text :color (plist-get pal :dim)
                                                               (expr (format "  ↳ %s"
                                                                       (mapconcat
                                                                        (lambda (s)
                                                                          (format "%s %.2fms"
                                                                                  (plist-get s :category)
                                                                                  (or (plist-get s :duration-ms) 0.0)))
                                                                        stages " · ")))))))))))
                                        (cl-subseq ops 0 (min 15 (length ops)))))))))
                          ;; Flush stream
                          (text :color (plist-get pal :muted) :font-weight 'bold "实时 Flush / Commit 流")
                          (expr
                           (if flushes
                               (mapcar
                                (lambda (f)
                                  (let* ((strat (plist-get f :strategy))
                                         (full-p (eq strat 'full)))
                                    (etaf-view
                                     (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                          (text :color (plist-get pal :dim) (expr (plist-get f :time)))
                                          (text :color (plist-get pal :accent) (expr (format "#%d" (plist-get f :rev))))
                                          (text :color (if full-p (plist-get pal :warn) (plist-get pal :ok))
                                                :font-weight (if full-p 'bold 'normal)
                                                (expr (format "%-5s" strat)))
                                          (text :color (plist-get pal :ink)
                                                (expr (format "%d 行 (%d 段)" (plist-get f :lines) (plist-get f :edits))))
                                          (text :color (plist-get pal :dim)
                                                (expr (format "+%d ~%d -%d"
                                                        (plist-get f :new)
                                                        (plist-get f :updated)
                                                        (plist-get f :retired))))))))
                                (cl-subseq flushes 0 (min 40 total)))
                             (list
                              (etaf-view
                               (text :color (plist-get pal :dim)
                                     "  操作目标应用后将在此实时记录每次增量 Flush")))))))))))

;;;; Panel 5: Keys, Focus & Regions

(defun etaf-devtools--keys-pane-view (session pal height-rows)
  "Render Focus stops, Regions topology and active Key scope diagnostics."
  (let* ((rt (etaf-value (etaf-devtools-session-target-ref session)))
         (finfo (etaf-value (etaf-devtools-session-focus-snap-ref session))))
    (if (not finfo)
        (etaf-view
         (box :padding '((lh 1) (ch 2))
              (text :color (plist-get pal :muted) "点击刷新或切换到目标应用查看焦点与键位作用域")))
      (let ((fid (plist-get finfo :focused-host-id))
            (fref (plist-get finfo :focused-host-ref))
            (in-act (plist-get finfo :input-active-p))
            (scheme (plist-get finfo :direction-scheme))
            (stops (plist-get finfo :stops))
            (regions (plist-get finfo :regions))
            (groups (plist-get (plist-get finfo :help) :groups)))
        (etaf-view
         (column :width 'stretch :item-gap '(lh 0)
                 (flex :flex-direction 'row :width 'stretch
                       :padding '((lh 0) (ch 1))
                       :background-color (plist-get pal :surface)
                       :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (plist-get pal :line-soft)
                       :column-gap '(ch 1) :align-items 'center
                       (text :color (plist-get pal :muted) "焦点:")
                       (text :color (plist-get pal :accent) :font-weight 'bold
                             (expr (if fid
                                       (format "Host #%d%s" fid
                                               (if (and fref (not (and (consp fref) (eq (car fref) 'etaf-host))))
                                                   (format " (%s)" fref) ""))
                                     "无焦点")))
                       (text :color (plist-get pal :dim) (expr (format "· 输入会话:%s · 方向:%s" (if in-act "活跃" "否") scheme)))
                       (box :flex-basis '(ch 0) :flex-grow 1)
                       (expr (etaf-devtools--action-btn
                              "刷新" pal (lambda () (etaf-devtools--refresh-focus session)) "刷新焦点快照")))
                 (box :width 'stretch :height (list 'lh (max 6 height-rows))
                      :overflow 'scroll
                      (column :width 'stretch :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
                              ;; Focus stops
                              (text :color (plist-get pal :ink) :font-weight 'bold
                                    (expr (format "Tab Focus Stops (%d · 点击测试聚焦)" (length stops))))
                              (expr
                               (if stops
                                   (cl-loop for st in stops for idx from 1 collect
                                            (let ((row-idx idx)
                                                  (hid (plist-get st :host-id))
                                                  (ref (plist-get st :ref))
                                                  (cur (plist-get st :focused-p)))
                                              (etaf-view
                                               (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                                    :background-color (if cur (plist-get pal :select) (plist-get pal :bg))
                                                    :pointer (unless cur 'hand)
                                                    :hover-style (unless cur (list :background-color (plist-get pal :hover)))
                                                    :on-press (lambda ()
                                                                (when (and rt (etaf-runtime-mounted-p rt) ref)
                                                                  (ignore-errors (etaf-focus rt ref))
                                                                  (etaf-devtools--refresh-focus session))
                                                                (etaf-devtools--session-select-node session 'host hid t))
                                                    (text :color (plist-get pal :dim) (expr (format "%2d." row-idx)))
                                                    (text :color (if cur (plist-get pal :accent) (plist-get pal :ink))
                                                          :font-weight (if cur 'bold 'normal)
                                                          (expr (format "%s #%d" (plist-get st :tag) hid)))
                                                    (text :color (plist-get pal :muted)
                                                          (expr (or (plist-get st :label)
                                                                    (and ref
                                                                         (not (and (consp ref) (eq (car ref) 'etaf-host)))
                                                                         (format ":ref %s" ref))
                                                                    "")))
                                                    (expr (when-let* ((fg (plist-get st :focus-group)))
                                                            (etaf-view (text :color (plist-get pal :kw) (expr (format "[group:%s]" fg))))))))))
                                 (list (etaf-view (text :color (plist-get pal :dim) "  (当前作用域无可聚焦控件)")))))
                              ;; Regions
                              (box :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                                   (text :color (plist-get pal :ink) :font-weight 'bold
                                         (expr (format "Declared Regions (%d)" (length regions)))))
                              (expr
                               (if regions
                                   (mapcar (lambda (reg)
                                             (etaf-view
                                              (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                                   (text :color (plist-get pal :accent) :font-weight 'bold
                                                         (expr (format "%s" (plist-get reg :id))))
                                                   (text :color (plist-get pal :ink) (expr (or (plist-get reg :label) "")))
                                                   (text :color (plist-get pal :kw)
                                                         (expr (if-let* ((k (plist-get reg :key)))
                                                                   (if (characterp k)
                                                                       (format "[M-g %c]" k)
                                                                     (format "[M-g %s]" k))
                                                                 "")))
                                                   (text :color (plist-get pal :dim)
                                                         (expr (format "enter:%S" (plist-get reg :enter)))))))
                                           regions)
                                 (list (etaf-view (text :color (plist-get pal :dim) "  (未声明 :region)")))))
                              ;; Effective Keys
                              (box :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                                   (text :color (plist-get pal :ink) :font-weight 'bold "生效键位作用域 (:keys)"))
                              (expr
                               (mapcar
                                (lambda (grp)
                                  (etaf-view
                                   (column :padding '((lh 0) (ch 1))
                                           (text :color (plist-get pal :muted) :font-weight 'bold
                                                 (expr (or (plist-get grp :title) "Keys")))
                                           (expr
                                            (mapcar (lambda (ent)
                                                      (etaf-view
                                                       (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                                            (text :color (plist-get pal :kw) :font-weight 'bold
                                                                  (expr (format "%-8s" (or (plist-get ent :key) ""))))
                                                            (text :color (plist-get pal :ink)
                                                                  (expr (or (plist-get ent :label) ""))))))
                                                    (cl-subseq (or (plist-get grp :entries) nil)
                                                               0 (min 14 (length (or (plist-get grp :entries) nil)))))))))
                                groups))))))))))

;;;; Panel 6: Runtime Targets, QA Acceptance Tools & Logs

(defun etaf-devtools--runtime-pane-view (session pal height-rows)
  "Render multi-target Runtime list, QA viewport presets and diagnostics log."
  (let* ((target (etaf-value (etaf-devtools-session-target-ref session)))
         (targets (etaf-value (etaf-devtools-session-targets-ref session)))
         (preset (etaf-value (etaf-devtools-session-viewport-preset-ref session)))
         (logs (etaf-value (etaf-devtools-session-logs-ref session)))
         (presets '((wide . "宽屏") (ordinary . "常规") (compact . "窄屏")
                    (short . "矮屏") (auto . "恢复窗口"))))
    (etaf-view
     (column :item-gap '(lh 0)
             (box :height (list 'lh (max 8 height-rows))
                  :overflow 'scroll
                  (column :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
                          (text :color (plist-get pal :ink) :font-weight 'bold
                                (expr (format "已挂载 ETAF Runtimes (%d)" (length targets))))
                          (expr
                           (if targets
                               (mapcar
                                (lambda (rt)
                                  (let* ((sel (eq rt target))
                                         (vp (condition-case nil (etaf-runtime-viewport rt) (error nil)))
                                         (rev (etaf-runtime-revision rt)))
                                    (etaf-view
                                     (row :padding '((lh 0) (ch 1)) :item-gap '(ch 1)
                                          :background-color (if sel (plist-get pal :select) (plist-get pal :bg))
                                          :border-left-width (if sel '(px 3) '(px 0))
                                          :border-left-style (if sel 'solid 'none)
                                          :border-left-color (plist-get pal :accent)
                                          :pointer (unless sel 'hand)
                                          :hover-style (unless sel (list :background-color (plist-get pal :hover)))
                                          :on-press (lambda ()
                                                      (etaf-devtools--session-set-target session rt t))
                                          (text :color (if sel (plist-get pal :accent) (plist-get pal :ink))
                                                :font-weight (if sel 'bold 'normal)
                                                (expr (etaf-devtools--runtime-label rt)))
                                          (text :color (plist-get pal :muted)
                                                (expr (if vp (format "%dpx × %dL" (car vp) (cdr vp)) "")))
                                          (text :color (plist-get pal :dim) (expr (format "rev:%d" rev)))))))
                                targets)
                             (list (etaf-view (text :color (plist-get pal :dim) "  (当前无其他挂载中的 ETAF Runtime)")))))
                          ;; QA viewport presets
                          (box :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                               (text :color (plist-get pal :ink) :font-weight 'bold "一键视口验收模拟 (etaf-runtime-refit)"))
                          (row :padding '((lh 0) (ch 0)) :item-gap '(ch 1)
                               (expr
                                (mapcar
                                 (lambda (pr)
                                   (etaf-devtools--chip
                                    (cdr pr) (eq preset (car pr)) pal
                                    (lambda () (etaf-devtools--session-apply-viewport session (car pr)))
                                    (plist-get pal :accent)))
                                 presets))
                               (expr (etaf-devtools--action-btn
                                      "强制 Flush" pal
                                      (lambda ()
                                        (when (and target (etaf-runtime-mounted-p target))
                                          (etaf-runtime-flush target)
                                          (etaf-devtools--refresh-target session t)))
                                      "结算目标待提交更新")))
                          ;; Event log
                          (box :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                               (text :color (plist-get pal :ink) :font-weight 'bold "事件与诊断日志"))
                          (expr
                           (if logs
                               (etaf-view (etaf-log :rows (cl-subseq logs 0 (min 30 (length logs)))))
                             (etaf-view (text :color (plist-get pal :dim) "  (暂无事件)"))))))))))

;;;; Main responsive shell component

(etaf-define-component etaf-devtools-root (&key session)
  :bindings ((theme-tokens (etaf-computed
                            (lambda ()
                              (ignore (etaf-value etaf-devtools--theme-generation))
                              (etaf-devtools--theme-tokens)))))
  :setup (etaf-theme-provide theme-tokens)
  :view
  (expr
   (let* ((_gen (etaf-value etaf-devtools--theme-generation))
          (pal (etaf-devtools--palette))
          (vp (etaf-viewport))
          (vp-px (or (car vp) 640))
          (vp-rows (max 14 (or (cdr vp) 28)))
          (metrics (etaf-display-metrics))
          (ch-px (max 6 (or (plist-get metrics :char-width) 8)))
          (cols (/ vp-px ch-px))
          (layout (cond ((>= cols 106) 'wide)
                        ((>= cols 64) 'medium)
                        (t 'narrow)))
          (tab (etaf-value (etaf-devtools-session-tab-ref session)))
          (narrow-detail (etaf-value (etaf-devtools-session-narrow-detail-ref session)))
          (status (etaf-value (etaf-devtools-session-status-msg-ref session)))
          (body-rows (max 8 (- vp-rows (if (string-empty-p status) 4 5))))
          (target (etaf-value (etaf-devtools-session-target-ref session)))
          (host (etaf-value (etaf-devtools-session-host-snap-ref session)))
          (comp (etaf-value (etaf-devtools-session-comp-snap-ref session))))
     (etaf-view
      (column :background-color (plist-get pal :bg)
              :color (plist-get pal :ink)
              :width 'stretch
              :help '("1-6 切换面板 · i 元素拾取 · h 重绘闪框 · r 深度录制 · d 切换停靠/浮窗"
                      "j/k 上下选节点 · m 切换组件/完整树 · g 跳转源码 · v 定位高亮 · p 钉住目标")
              :on-dismiss (lambda ()
                            (cond
                             ((etaf-value (etaf-devtools-session-edit-binding-ref session))
                              (etaf-devtools--session-cancel-edit-binding session))
                             ((not (string-empty-p (etaf-value (etaf-devtools-session-search-ref session))))
                              (etaf-set-value (etaf-devtools-session-search-ref session) ""))
                             ((and (eq layout 'narrow) narrow-detail)
                              (etaf-set-value (etaf-devtools-session-narrow-detail-ref session) nil))
                             (t nil)))
              :keys
              `(("1" ,(lambda () (etaf-set-value (etaf-devtools-session-tab-ref session) 'tree)
                                 (etaf-set-value (etaf-devtools-session-narrow-detail-ref session) nil)) "Tree 面板")
                ("2" ,(lambda () (etaf-set-value (etaf-devtools-session-tab-ref session) 'styles)) "Styles 面板")
                ("3" ,(lambda () (etaf-set-value (etaf-devtools-session-tab-ref session) 'state)) "State 面板")
                ("4" ,(lambda () (etaf-set-value (etaf-devtools-session-tab-ref session) 'perf)
                                 (etaf-devtools--refresh-perf session)) "Perf 面板")
                ("5" ,(lambda () (etaf-set-value (etaf-devtools-session-tab-ref session) 'keys)
                                 (etaf-devtools--refresh-focus session)) "Keys 与焦点面板")
                ("6" ,(lambda () (etaf-set-value (etaf-devtools-session-tab-ref session) 'runtime)) "Runtime 面板")
                ("i" ,(lambda () (etaf-devtools-inspect target)) "元素拾取器")
                ("h" ,(lambda ()
                        (when target
                          (let ((next (not (etaf-devtools--highlight-enabled-p target))))
                            (etaf-devtools--set-highlight-updates target next)
                            (etaf-set-value (etaf-devtools-session-highlight-ref session) next))))
                     "重绘热区闪框")
                ("r" ,(lambda () (etaf-devtools--session-toggle-recording session)) "深度性能录制")
                ("m" ,(lambda ()
                        (etaf-update-value (etaf-devtools-session-tree-mode-ref session)
                                           (lambda (cur) (if (eq cur 'full) 'components 'full))))
                     "切换组件/完整树")
                ("p" ,(lambda () (etaf-update-value (etaf-devtools-session-pinned-ref session) #'not)) "钉住/跟随目标")
                ("d" ,(lambda () (etaf-devtools-toggle-dock)) "切换停靠与浮窗")
                ("j" ,(lambda () (etaf-devtools--step-selection session 1)) "下一个节点")
                ("k" ,(lambda () (etaf-devtools--step-selection session -1)) "上一个节点")
                ("g" ,(lambda ()
                        (when-let* ((cname (or (and comp (plist-get comp :name))
                                               (and host (plist-get host :owner-component-name)))))
                          (etaf-devtools--jump-to-component cname (and comp (plist-get comp :source-file)))))
                     "跳转组件源码")
                ("v" ,(lambda ()
                        (when (and target (etaf-runtime-mounted-p target) host)
                          (when-let* ((ref (plist-get host :ref)))
                            (ignore-errors (etaf-scroll-into-view target ref)))
                          (etaf-devtools--overlay-highlight-host target (plist-get host :id) t)))
                     "滚入视口并高亮")
                ("a" ,(lambda ()
                        (when (and target (etaf-runtime-mounted-p target) host
                                   (plist-get host :has-press-p))
                          (etaf-runtime-trigger-host-press target (plist-get host :id))))
                     "触发节点点击")
                ("R" ,(lambda () (etaf-devtools--refresh-target session t)) "手动刷新快照")
                ("W" ,(lambda ()
                        (let* ((order '(wide ordinary compact short auto))
                               (cur (etaf-value (etaf-devtools-session-viewport-preset-ref session)))
                               (idx (or (cl-position cur order) 0))
                               (next (nth (mod (1+ idx) (length order)) order)))
                          (etaf-devtools--session-apply-viewport session next)))
                     "循环模拟目标视口")
                ("RET" ,(lambda ()
                          (when (and (eq layout 'narrow) (eq tab 'tree) (not narrow-detail))
                            (etaf-set-value (etaf-devtools-session-narrow-detail-ref session) t))) "查看详情"))
              (expr (etaf-devtools--header-view session pal layout))
              (expr (etaf-devtools--tabs-view session pal layout))
              ;; Main workspace area adapted by layout tier & active tab
              (expr
               (pcase tab
                 ('tree
                  (pcase layout
                    ('wide
                     (let ((tree-cols (max 36 (/ (* cols 45) 100))))
                       (etaf-view
                        (flex :flex-direction 'row :width 'stretch :column-gap '(ch 0)
                              (box :flex-basis '(ch 0) :flex-grow 45
                                   :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :line)
                                   (expr (etaf-devtools--tree-pane-view session pal layout (- body-rows 2) tree-cols)))
                              (box :flex-basis '(ch 0) :flex-grow 55
                                   (expr (etaf-devtools--styles-inspector-view session pal (- body-rows 2))))))))
                    ('medium
                     (let* ((top-h (max 5 (/ (* body-rows 41) 100)))
                            (bot-h (max 6 (- body-rows top-h 3))))
                       (etaf-view
                        (column :width 'stretch :item-gap '(lh 0)
                                (expr (etaf-devtools--tree-pane-view session pal layout top-h cols))
                                (expr (etaf-devtools--styles-inspector-view session pal bot-h))))))
                    (_ ; narrow master-detail
                     (if narrow-detail
                         (etaf-view
                          (column :width 'stretch
                                  (row :width 'stretch :padding '((lh 0) (ch 1)) :background-color (plist-get pal :surface2)
                                       (expr (etaf-devtools--action-btn
                                              "← 返回树 ESC" pal
                                              (lambda ()
                                                (etaf-set-value (etaf-devtools-session-narrow-detail-ref session) nil))
                                              "返回节点树")))
                                  (expr (etaf-devtools--styles-inspector-view session pal (- body-rows 3)))))
                       (etaf-devtools--tree-pane-view session pal layout (- body-rows 2) cols)))))
                 ('styles
                  (etaf-devtools--styles-inspector-view session pal (- body-rows 2)))
                 ('state
                  (if (eq layout 'wide)
                      (let ((tree-cols (max 36 (/ (* cols 44) 100))))
                        (etaf-view
                         (flex :flex-direction 'row :width 'stretch :column-gap '(ch 0)
                               (box :flex-basis '(ch 0) :flex-grow 44
                                    :border-right-width '(px 1) :border-right-style 'solid :border-right-color (plist-get pal :line)
                                    (expr (etaf-devtools--tree-pane-view session pal layout (- body-rows 2) tree-cols)))
                               (box :flex-basis '(ch 0) :flex-grow 56
                                    (expr (etaf-devtools--state-pane-view session pal (- body-rows 2)))))))
                    (etaf-devtools--state-pane-view session pal (- body-rows 2))))
                 ('perf
                  (etaf-devtools--perf-pane-view session pal (- body-rows 2)))
                 ('keys
                  (etaf-devtools--keys-pane-view session pal (- body-rows 2)))
                 ('runtime
                  (etaf-devtools--runtime-pane-view session pal (- body-rows 2)))
                 (_
                  (etaf-devtools--tree-pane-view session pal layout (- body-rows 2) cols))))
              ;; Optional transient status bar line
              (expr
               (when (and status (not (string-empty-p status)))
                 (etaf-view
                  (row :width 'stretch
                       :padding '((lh 0) (ch 1))
                       :background-color (plist-get pal :surface)
                       :border-top-width '(px 1) :border-top-style 'solid :border-top-color (plist-get pal :line-soft)
                       (text :color (plist-get pal :muted)
                             (expr (etaf-devtools--truncate status (max 24 (- cols 4))))))))))))))

(defun etaf-devtools--root-view (session)
  "Construct root ETAF View for SESSION."
  (etaf-view (etaf-devtools-root :session session)))

(provide 'etaf-devtools-view)
;;; etaf-devtools-view.el ends here
