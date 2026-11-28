;;; etaf-web-live.el --- Tier 3 Web IR to ETAF/Ebox interactive projector -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Projects distilled live Web IR snapshots from `etaf-web-cdp' into native
;; ETAF + `etaf-ui' layouts and interactive controls, dispatching user actions
;; (click, fill/submit, toggle, select, tab switch, scroll) back to the live
;; Chromium page and applying pushed DOM updates incrementally.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-web-cache)
(require 'etaf-web-adapter)
(require 'etaf-web-cdp)
(require 'etaf-web-views)

(defconst etaf-web-live--wide-breakpoint 104
  "Viewport width in columns at or above which live sidebars dock left.")

(defconst etaf-web-live--default-sidebar-cols 28
  "Default docked sidebar width in columns for Tier 3 live views.")

(defconst etaf-web-live--min-sidebar-cols 18
  "Minimum docked sidebar width in columns for Tier 3 live views.")

;;; ---------------------------------------------------------------------------
;;; Input ref cache & helpers
;;; ---------------------------------------------------------------------------

(defun etaf-web-live--ensure-input-refs (st ir &optional sync-existing)
  "Pre-allocate writable `etaf-ref' cells for all input nodes in IR outside render.
When SYNC-EXISTING is non-nil (e.g. after a submitted action refreshed the live
DOM), also reconcile existing refs with the live DOM's returned `:value'."
  (let ((tbl (plist-get st :input-refs))
        (regions (and (listp ir) (plist-get ir :regions))))
    (cl-labels
        ((walk (node)
           (when (listp node)
             (when (equal (plist-get node :type) "input")
               (let* ((wid (plist-get node :wid))
                      (val (or (plist-get node :value) ""))
                      (existing (and wid (gethash wid tbl))))
                 (cond
                  ((and wid (not existing))
                   (puthash wid
                            (etaf-ref val
                                      :name (intern (format "live-input-%S" wid)))
                            tbl))
                  ((and existing sync-existing
                        (not (equal (etaf-value existing) val)))
                   (etaf-set-value existing val)))))
             (dolist (child (plist-get node :children))
               (walk child)))))
      (dolist (key '(:topbar :sidebar :main :modal))
        (walk (plist-get regions key))))))

(defun etaf-web-live--input-ref (st wid)
  "Return pre-allocated writable `etaf-ref' for live input WID, or nil."
  (and wid (gethash wid (plist-get st :input-refs))))

(defun etaf-web-live--border (key fallback &optional px)
  "Build solid Theme border token of PX pixels for KEY."
  (let ((w (or px 1)))
    (etaf-theme-token key fallback (lambda (c) (list (list 'px w) 'solid c)))))

;;; ---------------------------------------------------------------------------
;;; Recursive Web IR -> ETAF/Ebox projector
;;; ---------------------------------------------------------------------------

(defun etaf-web-live--project-table (node st narrow)
  "Project Web IR table NODE into a bordered ETAF column table."
  (let* ((headers (plist-get node :headers))
         (rows (plist-get node :rows))
         (on-act (plist-get st :on-act))
         (fg-tok (etaf-theme-token :ui-fg "#dcdfe4"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#8b99a4"))
         (accent-tok (etaf-theme-token :ui-accent "#61afef"))
         (border (etaf-web-live--border :ui-border "#36444c" 1))
         (col-count (max 1 (length (or headers (car rows))))))
    (etaf-node
     'column (list :width 'stretch :border border)
     (delq
      nil
      (append
       (when (and headers (not narrow))
         (list
          (etaf-node
           'flex (list :width 'stretch :column-gap '(ch 2)
                       :padding '((lh 0) (ch 1))
                       :border-bottom border)
           (cl-loop for h in headers
                    for idx from 0
                    collect (etaf-node
                             'box (if (or (= col-count 1) (= idx 1))
                                      (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 12))
                                    (list :width '(ch 14) :flex-shrink 0))
                             (list (etaf-node 'text (list :font-weight 'bold :color muted-tok)
                                              (list (or h "")))))))))
       (cl-loop
        for row in rows
        for ridx from 0
        collect
        (if narrow
            (etaf-node
             'column (list :key (format "ltbl-r-%d" ridx)
                           :width 'stretch :padding '((lh 0) (ch 1))
                           :border-bottom border)
             (cl-loop
              for cell in row
              for cidx from 0
              for kind = (plist-get cell :kind)
              for txt = (or (plist-get cell :text) "")
              for wid = (plist-get cell :wid)
              unless (string-empty-p txt)
              collect
              (cond
               ((and (equal kind "link") wid)
                (etaf-view
                 (etaf-button :label txt :variant 'ghost :color accent-tok
                              :padding '((lh 0) (ch 0))
                              :on-press (let ((w wid))
                                          (lambda () (funcall on-act "click" :wid w))))))
               ((and (equal kind "button") wid)
                (etaf-view
                 (etaf-button :label txt :variant 'secondary
                              :padding '((lh 0) (ch 1))
                              :on-press (let ((w wid))
                                          (lambda () (funcall on-act "click" :wid w))))))
               (t
                (etaf-node 'text (list :color (if (= cidx 0) fg-tok muted-tok))
                           (list txt))))))
          (etaf-node
           'flex (list :key (format "ltbl-r-%d" ridx)
                       :width 'stretch :align-items 'center :column-gap '(ch 2)
                       :padding '((lh 0) (ch 1))
                       :border-bottom border)
           (cl-loop
            for cell in row
            for cidx from 0
            for kind = (plist-get cell :kind)
            for txt = (or (plist-get cell :text) "")
            for wid = (plist-get cell :wid)
            for box-props = (if (or (= col-count 1) (= cidx 1))
                                (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 12))
                              (list :width '(ch 14) :flex-shrink 0))
            collect
            (etaf-node
             'box box-props
             (list
              (cond
               ((and (equal kind "link") wid)
                (etaf-view
                 (etaf-button :label txt :variant 'ghost :color accent-tok
                              :padding '((lh 0) (ch 0))
                              :on-press (let ((w wid))
                                          (lambda () (funcall on-act "click" :wid w))))))
               ((and (equal kind "button") wid)
                (etaf-view
                 (etaf-button :label txt :variant 'secondary
                              :padding '((lh 0) (ch 1))
                              :on-press (let ((w wid))
                                          (lambda () (funcall on-act "click" :wid w))))))
               (t
                (etaf-node 'text (list :color (if (= cidx 0) fg-tok muted-tok))
                           (list txt)))))))))))))))

(defun etaf-web-live--project-node (node st narrow depth &optional in-topbar)
  "Recursively project a single Web IR NODE into an ETAF View node."
  (when (and (listp node) (< depth 16))
    (let* ((type (plist-get node :type))
           (on-act (plist-get st :on-act))
           (fg-tok (etaf-theme-token :ui-fg "#dcdfe4"))
           (muted-tok (etaf-theme-token :ui-muted-fg "#8b99a4"))
           (accent-tok (etaf-theme-token :ui-accent "#61afef"))
           (cyan-tok (etaf-theme-token :ui-info-fg "#56b6c2"))
           (panel-bg (etaf-theme-token :ui-panel-bg "#1a2227"))
           (border (etaf-web-live--border :ui-border "#36444c" 1))
           (quote-bar (etaf-web-live--border :ui-info-border "#56b6c2" 2)))
      (pcase type
        ("heading"
         (let ((txt (or (plist-get node :text) ""))
               (wid (plist-get node :wid)))
           (unless (string-empty-p txt)
             (if wid
                 (etaf-view
                  (etaf-button :label txt :variant 'ghost
                               :font-weight 'bold :color accent-tok
                               :padding '((lh 0) (ch 0))
                               :on-press (lambda () (funcall on-act "click" :wid wid))))
               (etaf-node 'text (list :font-weight 'bold :color fg-tok)
                          (list txt))))))
        ("text"
         (let ((txt (or (plist-get node :text) "")))
           (unless (string-empty-p txt)
             (etaf-node 'text (list :color fg-tok) (list txt)))))
        ("quote"
         (let ((txt (or (plist-get node :text) "")))
           (unless (string-empty-p txt)
             (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 2))
                                   :border-left quote-bar)
                        (list (etaf-node 'text (list :color muted-tok) (list txt)))))))
        ("code"
         (let ((txt (or (plist-get node :text) "")))
           (unless (string-empty-p txt)
             (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 1))
                                   :background-color panel-bg :border border)
                        (list (etaf-node 'text (list :color cyan-tok) (list txt)))))))
        ("link"
         (let ((txt (or (plist-get node :text) ""))
               (wid (plist-get node :wid))
               (active (plist-get node :active)))
           (unless (string-empty-p txt)
             (etaf-view
              (etaf-button :label txt
                           :variant 'ghost
                           :font-weight (if active 'bold 'normal)
                           :color (if active accent-tok fg-tok)
                           :padding '((lh 0) (ch 0))
                           :on-press (lambda ()
                                       (when wid
                                         (funcall on-act "click" :wid wid))))))))
        ("button"
         (let ((txt (or (plist-get node :text) "按钮"))
               (wid (plist-get node :wid))
               (disabled (plist-get node :disabled))
               (primary (plist-get node :primary)))
           (etaf-view
            (etaf-button :label txt
                         :variant (cond (in-topbar 'ghost)
                                        (primary 'primary)
                                        (t 'secondary))
                         :color (when in-topbar muted-tok)
                         :disabled (and disabled t)
                         :padding (if in-topbar '((lh 0) (ch 0)) '((lh 0) (ch 1)))
                         :on-press (lambda ()
                                     (when wid
                                       (funcall on-act "click" :wid wid)))))))
         ("input"
          (let* ((wid (plist-get node :wid))
                 (kind (or (plist-get node :kind) "text"))
                 (lbl (or (plist-get node :label) ""))
                 (ph (or (plist-get node :placeholder) lbl "输入内容，RET 提交"))
                 (val (or (plist-get node :value) ""))
                 (disabled (plist-get node :disabled))
                 (ref-cell (etaf-web-live--input-ref st wid)))
            (if (equal kind "search")
                (etaf-web--plain-input-view
                 :bind ref-cell
                 :value (unless ref-cell val)
                 :key (format "live-search-%S" wid)
                 :label (if (string-empty-p lbl) "搜索" lbl)
                 :width (if narrow 'stretch '(ch 34))
                 :placeholder (if (string-empty-p ph) "搜索…" ph)
                 :icon 'search
                 :disabled (and disabled t)
                 :on-submit (lambda (text)
                              (funcall on-act "fill" :wid wid :value text :submit t))
                 :on-clear (lambda ()
                             (funcall on-act "fill" :wid wid :value "" :submit nil)))
              (etaf-web--plain-input-view
               :bind ref-cell
               :value (unless ref-cell val)
               :key (format "live-field-%S" wid)
               :label (if (string-empty-p lbl) "输入" lbl)
               :placeholder ph
               :rows (if (equal kind "textarea") 3 1)
               :width (if narrow 'stretch '(ch 36))
               :disabled (and disabled t)
               :on-submit (lambda (text)
                            (funcall on-act "fill" :wid wid :value text :submit t))))))
        ((or "checkbox" "switch")
         (let ((wid (plist-get node :wid))
               (lbl (or (plist-get node :label) "选项"))
               (checked (and (plist-get node :checked) t))
               (disabled (and (plist-get node :disabled) t)))
           (if (equal type "switch")
               (etaf-view
                (etaf-switch :checked checked :label lbl :disabled disabled
                             :on-change (lambda (_next)
                                          (funcall on-act "toggle" :wid wid))))
             (etaf-view
              (etaf-checkbox :checked checked :label lbl :disabled disabled
                             :on-change (lambda (_next)
                                          (funcall on-act "toggle" :wid wid)))))))
        ("select"
         (let* ((wid (plist-get node :wid))
                (lbl (or (plist-get node :label) "选择"))
                (cur (or (plist-get node :value) ""))
                (raw-opts (plist-get node :options))
                (seen-lbl (make-hash-table :test #'equal))
                (opts (delq nil
                            (mapcar (lambda (o)
                                      (let ((v (or (plist-get o :value) ""))
                                            (l (or (plist-get o :label) "")))
                                        (when (and (not (string-empty-p l))
                                                   (not (gethash l seen-lbl)))
                                          (puthash l t seen-lbl)
                                          (cons v l))))
                                    raw-opts)))
                (eff-val (if (assoc cur opts) cur (caar opts))))
           (when opts
             (etaf-view
              (etaf-select :label lbl
                           :value eff-val
                           :options opts
                           :disabled (and (plist-get node :disabled) t)
                           :on-change (lambda (chosen)
                                        (funcall on-act "select" :wid wid :value chosen)))))))
        ("tabs"
         (let* ((raw-items (plist-get node :items))
                (seen-lbl (make-hash-table :test #'equal))
                (items (delq nil
                             (mapcar (lambda (it)
                                       (let ((w (plist-get it :wid))
                                             (l (or (plist-get it :label) "")))
                                         (when (and w (not (string-empty-p l))
                                                    (not (gethash l seen-lbl)))
                                           (puthash l t seen-lbl)
                                           (list :key w :label l))))
                                     raw-items)))
                (active-it (cl-find-if (lambda (it) (plist-get it :active)) raw-items))
                (active-key (or (and active-it (plist-get active-it :wid))
                                (and items (plist-get (car items) :key)))))
           (when (and (>= (length items) 2) active-key)
             (etaf-view
              (etaf-tabs :framed nil
                         :items items
                         :active active-key
                         :on-change (lambda (chosen-wid)
                                      (funcall on-act "click" :wid chosen-wid)))))))
        ("table"
         (etaf-web-live--project-table node st narrow))
        ("image"
         (let ((alt (or (plist-get node :alt) "图片")))
           (etaf-node 'text (list :color muted-tok) (list (format "[图: %s]" alt)))))
        ("row"
         (let ((kids (delq nil
                           (mapcar (lambda (c)
                                     (etaf-web-live--project-node c st narrow (1+ depth) in-topbar))
                                   (plist-get node :children)))))
           (when kids
             (etaf-node
              'flex
              (append
               (list :width 'stretch :align-items 'center
                     :column-gap '(ch 2) :row-gap '(lh 0) :flex-wrap 'wrap)
               (when (plist-get node :bordered)
                 (list :border border :padding '((lh 0) (ch 1)))))
              kids))))
        ("column"
         (let ((kids (delq nil
                           (mapcar (lambda (c)
                                     (etaf-web-live--project-node c st narrow (1+ depth) in-topbar))
                                   (plist-get node :children)))))
           (when kids
             (etaf-node
              'column
              (append
               (list :width 'stretch :item-gap '(lh 1))
               (when (plist-get node :bordered)
                 (list :border border :padding '((lh 0) (ch 1)))))
              kids))))
        (_ nil)))))

;;; ---------------------------------------------------------------------------
;;; Top-level live view (design-t3-live-and-narrow.png)
;;; ---------------------------------------------------------------------------

(defun etaf-web-live--render-view (st rctx)
  "Render Tier 3 Live CDP Page Controller ST for render context RCTX."
  (let* ((vw (max 44 (or (plist-get rctx :width) 96)))
         (cw (max 1.0 (float (or (plist-get rctx :char-width)
                                 (car (etaf-web--cell-metrics))))))
         (vw-px (or (plist-get rctx :width-px) (round (* vw cw))))
         (narrow (< vw etaf-web-live--wide-breakpoint))
         (ir (etaf-value (plist-get st :ir)))
         (rev (or (etaf-value (plist-get st :rev)) 0))
         (busy (etaf-value (plist-get st :busy)))
         (collapsed (etaf-value (plist-get st :collapsed-ref)))
         (drawer-open (plist-get st :drawer-open-ref))
         (sidebar-width-ref (plist-get st :sidebar-width-ref))
         (regions (and (listp ir) (plist-get ir :regions)))
         (topbar (and regions (plist-get regions :topbar)))
         (sidebar (and regions (plist-get regions :sidebar)))
         (main (and regions (plist-get regions :main)))
         (modal (and regions (plist-get regions :modal)))
         (canvas-ratio (or (and (listp ir) (plist-get ir :canvasRatio)) 0))
         (challenge (and (listp ir) (plist-get ir :challenge)))
         (controls (or (and (listp ir) (plist-get ir :controlCount)) 0))
         (scroll-h (or (and (listp ir) (plist-get ir :scrollHeight)) 0))
         (vp-h (or (and (listp ir) (plist-get ir :viewportHeight)) 800))
         (url (or (and (listp ir) (plist-get ir :url)) (plist-get st :url)))
         (on-act (plist-get st :on-act))
         (on-toggle-sidebar (plist-get st :on-toggle-sidebar))
         (open-external (plist-get st :open-external))
         (on-reader (plist-get st :on-reader))
         (sidebar-bg (etaf-theme-token :web-sidebar-bg "#1e272c"))
         (fg-tok (etaf-theme-token :ui-fg "#d8e1e6"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#8496a0"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#5c6e78"))
         (accent-tok (etaf-theme-token :ui-accent "#63c5da"))
         (warn-fg (etaf-theme-token :ui-warning-fg "#e5c07b"))
         (border (etaf-web-live--border :web-border-soft "#eaeef2" 1))
         (warn-bar (etaf-web-live--border :ui-warning-border "#e5c07b" 3))
         (dock-sidebar (and sidebar (not narrow) (not collapsed)))
         (min-px (round (* etaf-web-live--min-sidebar-cols cw)))
         (max-px (max (+ min-px (round (* 6 cw))) (round (* 0.42 vw-px))))
         (default-px (round (* etaf-web-live--default-sidebar-cols cw)))
         (clamped-px (max min-px (min (or (etaf-value sidebar-width-ref) default-px) max-px)))
         (topbar-view (and topbar (etaf-web-live--project-node topbar st narrow 0 t)))
         (sidebar-view (and sidebar (etaf-web-live--project-node sidebar st narrow 0)))
         (main-view (and main (etaf-web-live--project-node main st narrow 0)))
         (modal-view (and modal (etaf-web-live--project-node modal st narrow 0)))
         (main-pane
          (etaf-node
           'box
           (list :ref 'web-scroll :id "web-scroll"
                 :width (if dock-sidebar '(ch 0) 'stretch)
                 :flex-grow 1
                 :flex-basis (if dock-sidebar '(ch 0) '(lh 0))
                 :min-width '(ch 0)
                 :height 'stretch
                 :min-height '(lh 0)
                 :overflow 'scroll
                 :role 'region
                 :tab-index 0
                 :aria-label "动态页面正文")
           (list
            (etaf-node
             'column (list :width 'stretch :height 'auto
                           :padding (if narrow '((lh 1) (ch 1)) '((lh 1) (ch 3)))
                           :item-gap '(lh 1))
             (delq
              nil
              (list
               ;; Inline sidebar toggle when collapsed or narrow
               (when (and sidebar-view (not dock-sidebar))
                 (etaf-node
                  'flex (list :width 'stretch :align-items 'center :column-gap '(ch 1))
                  (list
                   (etaf-view
                    (etaf-button :label "≡ 侧栏" :variant 'ghost
                                 :color accent-tok :padding '((lh 0) (ch 1))
                                 :help-echo "打开页面侧栏 (s)"
                                 :on-press on-toggle-sidebar))
                   (etaf-node 'text (list :color muted-tok) (list "动态模式")))))
               ;; T4 Escalation Warning when Canvas/Challenge dominates
               (when (or (>= canvas-ratio 0.45) challenge)
                 (etaf-node
                  'column (list :width 'stretch :padding '((lh 1) (ch 2))
                                :background-color sidebar-bg
                                :border-top border :border-right border
                                :border-bottom border :border-left warn-bar
                                :item-gap '(lh 0))
                  (list
                   (etaf-node 'text (list :font-weight 'bold :color warn-fg)
                              (list (if challenge
                                        "该页包含人机验证或访问检查"
                                      "该页以画布或富媒体为主")))
                   (etaf-node 'text (list :color muted-tok)
                              (list (if challenge
                                        "请移交真实像素浏览器完成验证，不要在脚本中绕过。"
                                      (format "Canvas/媒体占比约 %d%%，文本投影体验有限，建议移交像素浏览器。"
                                              (round (* 100 canvas-ratio))))))
                   (etaf-node
                    'flex (list :column-gap '(ch 2) :flex-wrap 'wrap)
                    (list
                     (etaf-view
                      (etaf-button :label "外部/像素浏览器打开 (o)" :variant 'secondary
                                   :color accent-tok :padding '((lh 0) (ch 1))
                                   :on-press (lambda () (funcall open-external url))))
                     (etaf-view
                      (etaf-button :label "切回阅读模式 (m)" :variant 'ghost
                                   :color muted-tok :padding '((lh 0) (ch 0))
                                   :on-press on-reader)))))))
               ;; Projected page body
               (or main-view
                   (etaf-view (etaf-empty :title "页面尚未生成可见内容"
                                          :description "可按 r 重新同步，或按 o 移交外部浏览器。")))
               ;; Subtle live sync footer bar
               (etaf-node
                'flex (list :width 'stretch :align-items 'center
                            :justify-content 'space-between
                            :column-gap '(ch 2) :row-gap '(lh 0) :flex-wrap 'wrap
                            :padding-top '(lh 1)
                            :border-top border)
                (list
                 (etaf-node 'text (list :color dim-tok)
                            (list (format "CDP 实时同步 · rev %d · %d 控件%s"
                                          rev controls (if busy " · 同步中…" ""))))
                 (etaf-node
                  'flex (list :column-gap '(ch 2) :flex-wrap 'wrap)
                  (delq
                   nil
                   (list
                    (when (> scroll-h (+ vp-h 80))
                      (etaf-view
                       (etaf-button :label "向下加载" :variant 'ghost
                                    :color accent-tok :padding '((lh 0) (ch 0))
                                    :on-press (lambda ()
                                                (funcall on-act "scroll" :delta-y 700)))))
                    (etaf-view
                     (etaf-button :label "同步" :variant 'ghost
                                  :color accent-tok :padding '((lh 0) (ch 0))
                                  :on-press (lambda () (funcall on-act "snapshot"))))
                    (etaf-view
                     (etaf-button :label "阅读模式" :variant 'ghost
                                  :color muted-tok :padding '((lh 0) (ch 0))
                                  :on-press on-reader))
                    (etaf-view
                     (etaf-button :label "外部打开" :variant 'ghost
                                  :color accent-tok :padding '((lh 0) (ch 0))
                                  :on-press (lambda ()
                                              (funcall open-external url))))))))))))))))
    (etaf-node
     'flex (list :flex-direction 'column
                 :width 'stretch
                 :height 'stretch
                 :flex-grow 1
                 :flex-basis '(lh 0)
                 :min-height '(lh 0)
                 :overflow 'hidden)
     (delq
      nil
      (list
       ;; Projected page topbar (same theme canvas, quiet 1px bottom hairline)
       (when topbar-view
         (etaf-node 'box (list :width 'stretch :flex-shrink 0
                               :border-bottom border :padding '((lh 0) (ch 2)))
                    (list topbar-view)))
       ;; Full-height body: docked resizable sidebar + main OR single-column main
       (if dock-sidebar
           (etaf-node
            'flex (list :flex-direction 'row
                        :width 'stretch
                        :height 'stretch
                        :flex-grow 1
                        :flex-basis '(lh 0)
                        :min-height '(lh 0)
                        :overflow 'hidden)
            (list
             (etaf-node
              'flex (list :flex-direction 'column
                          :width (list 'px clamped-px)
                          :flex-shrink 0
                          :height 'stretch
                          :min-height '(lh 0)
                          :overflow 'hidden)
              (list
               (etaf-node
                'flex (list :width 'stretch :flex-shrink 0
                            :align-items 'center :justify-content 'space-between
                            :padding '((lh 1) (ch 2)))
                (list
                 (etaf-node 'text (list :font-weight 'bold :color fg-tok)
                            (list "侧栏"))
                 (etaf-node 'box (list :flex-shrink 0)
                            (list (etaf-ui-icon 'sidebar :set 'svg :min-width 2
                                                :color dim-tok
                                                :aria-label "折叠侧栏"
                                                :help-echo "折叠页面侧栏 (s)"
                                                :on-press on-toggle-sidebar)))))
               (etaf-node
                'box (list :ref 'live-sidebar-scroll
                           :width 'stretch
                           :flex-grow 1
                           :flex-basis '(lh 0)
                           :min-height '(lh 0)
                           :overflow 'scroll)
                (list (etaf-node 'column (list :width 'stretch :height 'auto
                                               :padding '((lh 0) (ch 2)))
                                 (list sidebar-view))))))
             (etaf-view
              (etaf-pane-resizer
               :ref 'live-pane-resizer
               :size clamped-px
               :min min-px
               :max max-px
               :on-change (lambda (next-px)
                            (etaf-set-value sidebar-width-ref next-px))))
             main-pane))
         main-pane)
       ;; Narrow sidebar drawer (automatically suppressed when sidebar docks)
       (when sidebar-view
         (etaf-view
          (etaf-drawer :open (and (not dock-sidebar) (etaf-value drawer-open))
                       :title "页面侧栏"
                       :placement 'left
                       :width '(ch 32)
                       :modal t
                       :on-close (lambda () (etaf-set-value drawer-open nil))
                       (expr sidebar-view))))
       ;; Projected modal dialog
       (when modal-view
         (etaf-view
          (etaf-dialog :open t
                       :title "页面弹窗"
                       :width '(ch 56)
                       :backdrop t
                       :on-close (lambda () (funcall on-act "snapshot"))
                       (expr modal-view)))))))))

;;; ---------------------------------------------------------------------------
;;; Opener (used by `live' mode and auto-escalation from JS-only shells)
;;; ---------------------------------------------------------------------------

(defun etaf-web-live--open (ctx)
  "Open URL in Tier 3 Live CDP mode using CTX; return canceller function."
  (let* ((url (plist-get ctx :url))
         (buf (plist-get ctx :buffer))
         (on-stage (plist-get ctx :on-stage))
         (on-ready (plist-get ctx :on-ready))
         (on-error (plist-get ctx :on-error))
         (open-external (plist-get ctx :open-external))
         (on-reader (plist-get ctx :on-reader))
         (on-hydrated (plist-get ctx :on-hydrated))
         (on-url-change (plist-get ctx :on-url-change))
         (sidebar-width-ref (or (plist-get ctx :sidebar-width-px)
                                (etaf-ref nil :name 'live-sidebar-width)))
         (collapsed-ref (etaf-ref nil :name 'live-collapsed))
         (drawer-open-ref (etaf-ref nil :name 'live-drawer-open))
         (tab-id (etaf-web-cdp--new-tab-id))
         (disposed nil)
         (ready-sent nil)
         (window-metrics
          (lambda ()
            (let* ((win (and (buffer-live-p buf) (get-buffer-window buf t)))
                   (live (window-live-p win))
                   (w (if live (window-body-width win) 96))
                   (cell-w (car (etaf-web--cell-metrics)))
                   (px (if live (window-body-width win t) (* w cell-w)))
                   (cw (if (and live (> w 0) (> px 0))
                           (/ (float px) w)
                         (float cell-w))))
              (list w px cw))))
         (toggle-sidebar
          (lambda ()
            (interactive)
            (let ((vw (nth 0 (funcall window-metrics))))
              (if (< vw etaf-web-live--wide-breakpoint)
                  (etaf-set-value drawer-open-ref (not (etaf-value drawer-open-ref)))
                (etaf-set-value collapsed-ref (not (etaf-value collapsed-ref)))))))
         (step-sidebar
          (lambda (delta-cols)
            (let* ((m (funcall window-metrics))
                   (vw (nth 0 m))
                   (vw-px (nth 1 m))
                   (cw (nth 2 m))
                   (min-px (round (* etaf-web-live--min-sidebar-cols cw)))
                   (max-px (max (+ min-px (round (* 6 cw)))
                                (round (* 0.42 vw-px))))
                   (cur (or (etaf-value sidebar-width-ref)
                            (round (* etaf-web-live--default-sidebar-cols cw))))
                   (next (max min-px (min max-px (+ cur (round (* delta-cols cw)))))))
              (when (>= vw etaf-web-live--wide-breakpoint)
                (etaf-set-value collapsed-ref nil)
                (etaf-set-value sidebar-width-ref next)))))
         (st (list :url url
                   :tab-id tab-id
                   :ir (etaf-ref nil :name 'live-ir)
                   :rev (etaf-ref 0 :name 'live-rev)
                   :busy (etaf-ref nil :name 'live-busy)
                   :collapsed-ref collapsed-ref
                   :drawer-open-ref drawer-open-ref
                   :sidebar-width-ref sidebar-width-ref
                   :on-toggle-sidebar toggle-sidebar
                   :input-refs (make-hash-table :test #'eql)
                   :open-external open-external
                   :on-reader on-reader)))
    (cl-labels
        ((apply-snapshot (rev ir)
           (when (and (not disposed) (listp ir))
             (etaf-web-live--ensure-input-refs st ir t)
             (let ((next-url (plist-get ir :url))
                   (title (or (plist-get ir :title)
                              (car (etaf-web--url-parts url)))))
               (when (and (stringp next-url) (not (string-empty-p next-url)))
                 (plist-put st :url next-url)
                 (when (and ready-sent (functionp on-url-change))
                   (funcall on-url-change next-url title)))
               (etaf-batch
                 (etaf-set-value (plist-get st :ir) ir)
                 (etaf-set-value (plist-get st :rev) (or rev 1))
                 (etaf-set-value (plist-get st :busy) nil))
               (unless ready-sent
                 (setq ready-sent t)
                 (funcall
                  on-ready
                  (etaf-web--make-page-controller
                   :tier 't3
                   :adapter nil
                   :mode-label "动态"
                   :own-scroll t
                   :url (or next-url url)
                   :title title
                   :render (lambda (rctx) (etaf-web-live--render-view st rctx))
                   :keys (list (list "s" toggle-sidebar "切换侧栏")
                               (list "[" (lambda () (interactive) (funcall step-sidebar -4))
                                     "缩窄侧栏")
                               (list "]" (lambda () (interactive) (funcall step-sidebar 4))
                                     "加宽侧栏"))
                   :on-reload (lambda () (do-act "snapshot"))
                   :dispose (lambda ()
                              (unless disposed
                                (setq disposed t)
                                (etaf-web-cdp--close-tab tab-id)))))))))
         (do-act (kind &rest args)
           (unless disposed
             (etaf-set-value (plist-get st :busy) t)
             (if (equal kind "snapshot")
                 (etaf-web-cdp--snapshot
                  tab-id
                  (lambda (res err)
                    (unless disposed
                      (etaf-set-value (plist-get st :busy) nil)
                      (if err
                          (message "实时同步失败：%s" err)
                        (apply-snapshot (plist-get res :rev)
                                        (plist-get res :ir))))))
               (etaf-web-cdp--act
                tab-id kind
                :wid (plist-get args :wid)
                :value (plist-get args :value)
                :submit (plist-get args :submit)
                :delta-y (plist-get args :delta-y)
                :callback
                (lambda (res err)
                  (unless disposed
                    (etaf-set-value (plist-get st :busy) nil)
                    (if err
                        (message "页面操作失败：%s" err)
                      (when-let* ((snap (plist-get res :snapshot)))
                        (apply-snapshot (plist-get snap :rev)
                                        (plist-get snap :ir)))))))))))
      (plist-put st :on-act #'do-act)
      (when on-stage (funcall on-stage 'live "动态连接" 0.35))
      (etaf-web-cdp--open-tab
       tab-id url
       (lambda (msg)
         (when ready-sent
           (apply-snapshot (plist-get msg :rev) (plist-get msg :ir))))
       (lambda (res err)
         (unless disposed
           (if err
               (funcall on-error
                        (list :kind 'live
                              :message (format "动态模式连接失败: %s" err)
                              :url url
                              :has-cache nil))
             (let ((html (plist-get res :html))
                   (ir (plist-get res :ir)))
               (if (and (functionp on-hydrated)
                        (stringp html)
                        (not (string-empty-p html))
                        (funcall on-hydrated html ir))
                   (progn
                     (setq disposed t)
                     (etaf-web-cdp--close-tab tab-id))
                 (apply-snapshot (plist-get res :rev) ir))))))
       1280 900 (and (functionp on-hydrated) t))
      (lambda ()
        (unless disposed
          (setq disposed t)
          (etaf-web-cdp--close-tab tab-id))))))

(provide 'etaf-web-live)
;;; etaf-web-live.el ends here
