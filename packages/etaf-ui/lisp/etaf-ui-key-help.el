;;; -*- lexical-binding: t; -*-
;;; etaf-ui-key-help.el --- Searchable modal keyboard reference

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Present ETAF's effective key snapshot with ordinary catalog controls.
;; Dialog owns occlusion and focus return; Text Input owns editing; this
;; component only filters and groups read-only descriptions.

;;; Code:
(require 'etaf-ui-surface)
(require 'etaf-ui-field)

(defun etaf-ui--key-help-matches-p (query &rest strings)
  "Return non-nil when QUERY occurs literally in any of STRINGS."
  (let ((case-fold-search t))
    (or (string-empty-p query)
        (cl-some (lambda (text)
                   (and text (string-match-p (regexp-quote query) text)))
                 strings))))

(defun etaf-ui--key-help-group (group query)
  "Return GROUP's filtered read-only View for QUERY, or nil."
  (let* ((title (plist-get group :title))
         (source (plist-get group :source))
         (entries (cl-remove-if-not
                   (lambda (entry)
                     (etaf-ui--key-help-matches-p
                      query title source (plist-get entry :key) (plist-get entry :label)))
                   (plist-get group :entries))))
    (when entries
      (etaf-view
       (column :key (concat title "\0" source) :width 'stretch :item-gap '(lh 0)
         (box :padding-bottom '(lh 0.5)
           (etaf-label :text (concat title " · " source) :variant 'strong
                      :color (etaf-ui--style-token :ui-accent)))
         (expr
          (mapcar
           (lambda (entry)
             (etaf-view
              (flex :key (plist-get entry :key)
                    :width 'stretch :flex-direction 'row :align-items 'center
                    :justify-content 'space-between :column-gap '(ch 2)
                (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  (etaf-label :text (plist-get entry :label)
                              :color (etaf-ui--style-token :ui-panel-fg)))
                (etaf-kbd :keys (list (plist-get entry :key))))))
           entries)))))))

(etaf-define-component etaf-ui--key-help-results (&key data query wide height content-ref)
  "Keep filtering separate from the live search field's editing span."
  :render
  (let* ((text (string-trim (etaf-value query)))
         (groups (plist-get data :groups))
         (application (delq nil
                            (mapcar (lambda (group)
                                      (unless (eq (plist-get group :kind) 'framework)
                                        (etaf-ui--key-help-group group text)))
                                    groups)))
         (framework (delq nil
                          (mapcar (lambda (group)
                                    (when (eq (plist-get group :kind) 'framework)
                                      (etaf-ui--key-help-group group text)))
                                  groups)))
         (notes (cl-remove-if-not
                 (lambda (note) (etaf-ui--key-help-matches-p text note))
                 (plist-get data :notes)))
         (controls (cl-remove-if-not
                    (lambda (label) (etaf-ui--key-help-matches-p text label))
                    (plist-get data :controls)))
         (extra
          (append
           (when notes
             (list (etaf-view
                    (column :width 'stretch :item-gap '(lh 1)
                      (etaf-label :text "使用说明" :variant 'strong
                                  :color (etaf-ui--style-token :ui-panel-fg))
                      (expr (mapcar (lambda (note)
                                      (etaf-view (etaf-label :text note
                                                            :color (etaf-ui--style-token :ui-panel-fg))))
                                    notes))))))
           (when controls
             (list (etaf-view
                    (column :width 'stretch
                      (etaf-label :text "界面控件" :variant 'strong
                                  :color (etaf-ui--style-token :ui-panel-fg))
                      (expr (mapcar (lambda (label)
                                      (etaf-view (etaf-label :text label :variant 'muted)))
                                    controls)))))))))
    (etaf-view
     (column :ref content-ref :aria-label "快捷键列表" :tab-index 0
             :width 'stretch :height (list 'lh height) :overflow 'scroll
             :scroll-anchor 'start
       (expr
        (if (not (or application framework extra))
            (etaf-view
             (column :padding '((lh 1) (ch 0))
               (etaf-label :text "没有匹配的快捷键" :variant 'strong
                           :color (etaf-ui--style-token :ui-panel-fg))
               (etaf-label :text "换个操作名称或按键试试。" :variant 'muted)))
          (if (and wide application framework)
              (etaf-view
               (flex :width 'stretch :flex-direction 'row :align-items 'flex-start
                     :column-gap '(ch 3)
                 (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                         :item-gap '(lh 1)
                   (expr application) (expr extra))
                 (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                         :item-gap '(lh 1)
                         :padding-left '(ch 3)
                         :border-left (etaf-ui--style-border
                                       (etaf-ui--style-token :ui-panel-border))
                   (expr framework)
                   (etaf-label :text "按打开帮助时的区域显示。" :variant 'muted)
                   (etaf-label :text "这里的条目不会触发应用操作。" :variant 'muted))))
            (etaf-view
             (column :width 'stretch :item-gap '(lh 1)
               (expr application) (expr framework) (expr extra))))))))))

(etaf-define-component etaf-key-help (&key data on-close)
  "Show read-only effective key DATA as a searchable in-buffer modal.
DATA follows `etaf-help-data'; ON-CLOSE is a zero-argument callback.  Search
only filters descriptions; no row dispatches an application command.
Wide windows use two columns, compact ones one scrolling column.  Escape
leaves a search edit first, then closes the dialog, preserving its caller."
  :bindings ((query (etaf-ref ""))
             (runtime (etaf-current-runtime))
             (search-ref (etaf-local-ref 'key-help-search))
             (content-ref (etaf-local-ref 'key-help-content)))
  :validate
  (progn
    (etaf-check-prop :data data (and (listp data) (stringp (plist-get data :title)))
                     "a keyboard help snapshot" 'etaf-key-help)
    (etaf-check-prop :on-close on-close (functionp on-close)
                     "a function" 'etaf-key-help))
  :render
  (let* ((viewport (etaf-viewport))
         (window (etaf-runtime-window-viewport runtime))
         ;; The dialog is drawn on the canvas, so its cell is the canvas's face.
         (cell (max 1 (car (etaf-ui--canvas-cell))))
         (pixels (or (car window) (car viewport) (* 80 cell)))
         (rows (or (cdr window) (cdr viewport) 32))
         (width (min 96 (max 24 (- (/ pixels cell) 4))))
         (height (max 12 (min 29 (- rows 4))))
         (wide (>= width 88))
         (body-height (max 3 (- height 12)))
         (search (lambda () (etaf-text-input-begin runtime search-ref)))
         (scroll (lambda (delta) (etaf-scroll-by runtime content-ref delta))))
    (etaf-view
     (etaf-dialog
      :open t :title "快捷键 · 只读" :width (list 'ch width)
      :height (list 'lh height) :compact t :close-label nil :on-close on-close
      :keys (list (list "/" search "搜索快捷键")
                  (list "C-v" (lambda () (funcall scroll body-height)) "向下翻页")
                  (list "M-v" (lambda () (funcall scroll (- body-height))) "向上翻页")
                  (list "<next>" (lambda () (funcall scroll body-height)) "向下翻页")
                  (list "<prior>" (lambda () (funcall scroll (- body-height))) "向上翻页"))
      :on-direction (lambda (direction)
                      (when (memq direction '(up down))
                        (funcall scroll (if (eq direction 'up) -1 1)))
                      'handled)
      (column :width 'stretch :item-gap '(lh 1) :padding '((lh 1) (ch 0))
        (etaf-label :text (if (equal (plist-get data :title) (plist-get data :scope))
                             (plist-get data :title)
                           (concat (plist-get data :title) " / " (plist-get data :scope)))
                    :variant 'muted)
        (etaf-text-input :bind query :ref search-ref :hide-label t
                         :label "搜索快捷键或操作" :placeholder "搜索快捷键或操作…  /"
                         :width 'stretch)
        (etaf-ui--key-help-results :data data :query query :wide wide
                                   :height body-height :content-ref content-ref))
      (slot :name 'footer
        (flex :width 'stretch :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :flex-direction 'row :justify-content 'space-between
              :align-items 'center :column-gap '(ch 2)
              :padding '((lh 1) (ch 0))
              :border-top (etaf-ui--style-border (etaf-ui--style-token :ui-panel-border))
          (etaf-label :text "/ 搜索 · ↑ ↓ 浏览" :variant 'muted)
          (etaf-button :label "Esc  关闭帮助" :aria-label "关闭帮助"
                       :variant 'secondary :on-press on-close)))))))

(unless etaf-help-view-function
  (setq etaf-help-view-function
        (lambda (data close)
          (etaf-node 'etaf-key-help (list :data data :on-close close) nil))))

(provide 'etaf-ui-key-help)
;;; etaf-ui-key-help.el ends here
