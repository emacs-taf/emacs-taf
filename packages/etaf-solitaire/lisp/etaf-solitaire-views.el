;;; -*- lexical-binding: t; -*-
;;; etaf-solitaire-views.el --- Verdant's native card table

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-ui)
(require 'etaf-solitaire-model)
(require 'etaf-solitaire-theme)
(declare-function etaf-solitaire-close "etaf-solitaire" (&optional instance))
(defvar etaf-solitaire-appearance)

(etaf-define-component etaf-solitaire--theme-switch (&key appearance override)
  :view
  (etaf-button :label (if (eq (etaf-value appearance) 'dark) "浅色" "暗色")
    :ref 'solitaire-theme :variant 'ghost :help-echo "切换亮暗主题 · T"
    :on-press (lambda () (etaf-set-value override
                                        (if (eq (etaf-value appearance) 'dark) 'light 'dark)))))

(etaf-define-component etaf-solitaire--card (&key session table selected token (lines 5) address)
  :bindings ((card-token (etaf-prop :token))
             (rank (etaf-computed (lambda () (etaf-solitaire--rank (etaf-value card-token)))
                                  :test #'equal))
             (moves (etaf-computed (lambda () (plist-get (etaf-value table) :moves)) :test #'equal))
             (source (etaf-computed (lambda () (cl-find (etaf-value card-token) (etaf-value moves)
                                                        :key (lambda (item) (plist-get item :source)) :test #'equal))))
             (target
              (etaf-computed
               (lambda ()
                 (let ((card (etaf-value card-token)))
                   ;; Covered cards cannot accept a move and need not track
                   ;; the live selection until their token turns face-up.
                   (unless (equal card "🂠")
                     (let ((chosen (etaf-value selected)))
                       (and chosen
                            (cl-some (lambda (item)
                                       (and (equal chosen (plist-get item :source))
                                            (equal card (plist-get item :target))))
                                     (etaf-value moves)))))))))
             (highlighted
              (etaf-computed
               (lambda () (and (not (equal (etaf-value card-token) "🂠"))
                               (or (equal (etaf-value card-token) (etaf-value selected))
                                   (etaf-value target))
                               t))))
             (press (lambda () (etaf-solitaire--press session selected (etaf-value table)
                                                     (etaf-value card-token)))))
  :view
  (etaf-playing-card :rank (etaf-value rank) :suit (etaf-solitaire--suit token)
    :face-down (equal token "🂠") :empty (or (null token) (equal token "🂿")
                                                  (and (etaf-solitaire--suit token) (= (length token) 1)))
    :lines lines :columns 9 :ref (or address (intern (concat "solitaire-card-" token)))
    :selected (etaf-value highlighted)
    :disabled (or (not (eq (etaf-gamekit-status session) 'ready))
                  (not (or (etaf-value source) (etaf-value target))))
    :on-press press))

(etaf-define-component etaf-solitaire--pile (&key session table selected index compact)
  :bindings ((cards (etaf-computed (lambda () (nth index (plist-get (etaf-value table) :columns))) :test #'equal)))
  :view
  (column :width '(ch 9)
    (etaf-label :text (format "%02d" (1+ index)) :variant 'muted :height (if compact '(lh 1) '(lh 2)))
    (etaf-solitaire--card :if (null (etaf-value cards)) :session session :table table :selected selected
      :token "🂿" :address (intern (format "solitaire-empty-%d" index)))
    (etaf-solitaire--card :for (i (number-sequence 0 (1- (length (etaf-value cards))))) :key i
      :session session :table table :selected selected :token (nth i (etaf-value cards))
      :address (if (equal (nth i (etaf-value cards)) "🂠")
                   (intern (format "solitaire-back-%d-%d" index i))
                 (intern (concat "solitaire-card-" (nth i (etaf-value cards)))))
      :lines (if (= i (1- (length (etaf-value cards)))) 5 1))))

(etaf-define-component etaf-solitaire--board (&key session table selected cursor compact)
  :bindings ((waste (etaf-computed (lambda () (plist-get (etaf-value table) :waste)) :test #'equal))
             (current (etaf-computed (lambda () (if (member (etaf-value selected) (etaf-value waste))
                                                    (etaf-value selected)
                                                  (nth (% (etaf-value cursor) (max 1 (length (etaf-value waste))))
                                                       (etaf-value waste)))))))
  :view
  (column :ref 'solitaire-board :width '(ch 75) :item-gap (if compact '(lh 0) '(lh 1))
    (row :item-gap '(ch 2) :cross-align 'start
      (column :width '(ch 9) :item-gap (if compact '(lh 0) '(lh 1))
        (etaf-label :text "牌库" :variant 'muted)
        (etaf-playing-card :face-down t :ref 'solitaire-draw :label "浏览下一张可用牌 · D"
          :disabled (null (etaf-value waste))
          :on-press (lambda () (etaf-batch (setf (etaf-value selected) nil) (cl-incf (etaf-value cursor)))))
        (etaf-label :text (format "%d 张" (plist-get (etaf-value table) :stock-count)) :variant 'muted))
      (column :width '(ch 9) :item-gap (if compact '(lh 0) '(lh 1))
        (etaf-label :text "待用牌" :variant 'muted)
        (etaf-solitaire--card :session session :table table :selected selected :token (etaf-value current)
          :address 'solitaire-waste)
        (etaf-label :text "D 下一张" :variant 'muted))
      (column :width '(ch 9) :item-gap (if compact '(lh 0) '(lh 1))
        (etaf-label :text "已归位" :variant 'muted)
        (etaf-label :text (format "%02d / 52" (plist-get (etaf-value table) :home))
          :color (etaf-solitaire--color :ui-accent) :variant 'strong)
        (etaf-label :text "步数" :variant 'muted)
        (etaf-label :text (format "%03d" (or (etaf-gamekit-view session :action_count) 0)) :variant 'strong))
      (column :for (i '(0 1 2 3)) :key i :width '(ch 9) :item-gap (if compact '(lh 0) '(lh 1))
        (etaf-label :text (nth i '("黑桃" "红心" "梅花" "方块")) :variant 'muted)
        (etaf-solitaire--card :session session :table table :selected selected
          :token (nth i (plist-get (etaf-value table) :foundations))
          :address (intern (format "solitaire-foundation-%d" i)))))
    (etaf-divider)
    (row :item-gap '(ch 2) :cross-align 'start :role 'region :aria-label "七列牌桌" :focus-group 'grid
      (etaf-solitaire--pile :for (i '(0 1 2 3 4 5 6)) :key i
        :session session :table table :selected selected :index i :compact compact))))

(etaf-define-component etaf-solitaire--hints (&key session table selected)
  :bindings ((moves (etaf-computed
                     (lambda () (let ((all (plist-get (etaf-value table) :moves)))
                                  (if (etaf-value selected)
                                      (cl-remove-if-not (lambda (move) (equal (plist-get move :source) (etaf-value selected))) all)
                                    all))) :test #'equal)))
  :view
  (etaf-panel :title "下一步" :width '(ch 24) :ref 'solitaire-hints :role 'region
    (etaf-label :text (if (etaf-value selected) (concat "已选 " (etaf-value selected)) "选择一张明牌")
      :variant 'strong :color (etaf-solitaire--color :ui-accent))
    (etaf-label :text "点击牌面，再点击高亮位置。也可以直接选择下面的合法移动。" :wrap-mode 'word)
    (column :item-gap '(lh 1)
      (etaf-button :for (move (cl-subseq (etaf-value moves) 0 (min 5 (length (etaf-value moves)))))
        :key (plist-get move :id) :ref (intern (format "solitaire-move-%d" (plist-get move :id)))
        :label (format "%s  →  %s" (plist-get move :source) (plist-get move :target)) :variant 'secondary
        :disabled (not (eq (etaf-gamekit-status session) 'ready))
        :on-press (lambda () (etaf-solitaire--send session selected "act" (list :action (plist-get move :id))))))
    (etaf-label :if (null (etaf-value moves)) :text "没有可用移动，可撤销或开始新局。" :variant 'muted :wrap-mode 'word)
    (etaf-divider)
    (etaf-label :text "K+ KLONDIKE" :variant 'strong)
    (etaf-label :text "K+ 合并了重复翻牌：牌库可浏览所有当前可用牌，移动规则由 OpenSpiel 判断。"
      :wrap-mode 'word :variant 'muted)))

(etaf-define-component etaf-solitaire--app (&key session)
  :bindings ((appearance-override (etaf-ref (unless (eq etaf-solitaire-appearance 'auto)
                                              etaf-solitaire-appearance)))
             (appearance (etaf-appearance-mode appearance-override))
             (theme (etaf-computed (lambda () (if (eq (etaf-value appearance) 'dark)
                                                   etaf-solitaire--dark-theme etaf-solitaire--light-theme)) :test #'equal))
             (observation (etaf-computed (lambda () (etaf-gamekit-view session)) :test #'equal))
             (table (etaf-computed (lambda () (etaf-solitaire--table (etaf-value observation))) :test #'equal))
             (selected (etaf-ref nil)) (cursor (etaf-ref 0)) (hints (etaf-ref nil))
             (wide (etaf-computed
                    (lambda ()
                      (>= (or (car (etaf-viewport)) 0)
                          (* 106 (or (plist-get (ignore-errors (etaf-display-metrics))
                                                :char-width)
                                     (frame-char-width)))))))
             (compact (etaf-computed (lambda () (< (or (cdr (etaf-viewport)) 44) 42))))
             (dismiss-selection (lambda () (setf (etaf-value selected) nil)))
             ;; Selection changes republish root props, not these commands.
             (keys (list
                    (list "d" (lambda () (etaf-batch (setf (etaf-value selected) nil) (cl-incf (etaf-value cursor)))) "下一张待用牌")
                    (list "u" (lambda () (when (eq t (etaf-gamekit-view session :can_undo))
                                           (etaf-solitaire--send session selected "undo"))) "撤销")
                    (list "y" (lambda () (when (eq t (etaf-gamekit-view session :can_redo))
                                           (etaf-solitaire--send session selected "redo"))) "重做")
                    (list "h" (lambda () (setf (etaf-value selected) (plist-get (car (plist-get (etaf-value table) :moves)) :source))) "提示")
                    (list "n" (lambda () (etaf-solitaire--send session selected "reset" (list :seed (random most-positive-fixnum)))) "新局")
                    (list "C-s" (lambda () (etaf-solitaire--snapshot session selected "save")) "保存")
                    (list "C-o" (lambda () (etaf-solitaire--snapshot session selected "load")) "读取")
                    (list "<f1>" #'etaf-help "游戏说明")
                    (list "t" (lambda () (etaf-set-value appearance-override
                                                        (if (eq (etaf-value appearance) 'dark) 'light 'dark))) "切换亮暗主题")
                    (list "q" (lambda () (etaf-solitaire-close session)) "退出"))))
  :setup (etaf-theme-provide theme)
  :view
  (flex :width 'stretch :height 'stretch :min-width '(ch 79) :min-height '(lh 30)
    :flex-direction 'column :align-items 'center :aria-label "纸牌接龙"
    :help '("四个收集位按同一花色从 A 到 K 排列。牌桌上按红黑交替、点数递减排列；空列接 K。"
            "这是 OpenSpiel 的 K+ Klondike 变体，不是 Windows 规则复刻。重复翻牌折叠为可用的待用牌；点击明牌，再点击高亮目标。"
            "提示选择一条合法移动的起点，不保证最优解。撤销与重做保持隐藏牌的随机结果。"
            "牌面保持固定尺寸。窄窗口把辅助面板收进“合法移动”；不足 79 列 × 30 行时保留牌桌并裁切或滚动。")
    :background-color (etaf-solitaire--color :ui-bg) :color (etaf-solitaire--color :ui-fg)
    :on-dismiss (and (etaf-value selected) dismiss-selection)
    :keys keys
    (box :flex-grow 2 :flex-basis '(lh 0) :min-height '(lh 0))
    (column :ref 'solitaire-root :flex-shrink 0 :width 'stretch :max-width '(ch 106) :padding '((lh 1) (ch 2))
      :item-gap (if (etaf-value compact) '(lh 0) '(lh 1))
      (flex :width 'stretch :justify-content 'space-between :align-items 'center
        (column
          (etaf-label :text "VERDANT / 纸牌接龙" :variant 'strong :color (etaf-solitaire--color :ui-accent))
          (etaf-label :if (not (etaf-value compact)) :text (if (etaf-value wide) "K+ Klondike · 慢一点，理清每一手" "K+ Klondike") :variant 'muted))
        (row :item-gap '(ch 1) :focus-group 'horizontal :role 'region :aria-label "游戏操作"
          (etaf-button :label "新局" :ref 'solitaire-new
            :on-press (lambda () (etaf-solitaire--send session selected "reset" (list :seed (random most-positive-fixnum)))))
          (etaf-button :label "撤销" :ref 'solitaire-undo :variant 'secondary
            :disabled (not (eq t (etaf-gamekit-view session :can_undo)))
            :on-press (lambda () (etaf-solitaire--send session selected "undo")))
          (etaf-button :label "重做" :ref 'solitaire-redo :variant 'ghost
            :disabled (not (eq t (etaf-gamekit-view session :can_redo)))
            :on-press (lambda () (etaf-solitaire--send session selected "redo")))
          (etaf-button :label "保存" :ref 'solitaire-save :variant 'ghost
            :on-press (lambda () (etaf-solitaire--snapshot session selected "save")))
          (etaf-button :label "读取" :ref 'solitaire-load :variant 'ghost
            :on-press (lambda () (etaf-solitaire--snapshot session selected "load")))
          (etaf-solitaire--theme-switch :appearance appearance
                                         :override appearance-override)
          (etaf-button :label "说明" :ref 'solitaire-help :variant 'ghost
            :on-press #'etaf-help)))
      (etaf-divider)
      (etaf-label :if (null (etaf-value table)) :text "正在发牌…" :variant 'muted)
      (flex :if (etaf-value table) :width 'stretch :gap '((lh 0) (ch 3))
        :justify-content (if (etaf-value wide) 'flex-start 'center) :align-items 'flex-start
        (etaf-solitaire--board :session session :table table :selected selected :cursor cursor :compact (etaf-value compact))
        (etaf-solitaire--hints :if (etaf-value wide) :session session :table table :selected selected))
      (flex :width 'stretch :justify-content 'space-between
        (etaf-label :ref 'solitaire-selection :text (if (etaf-value selected)
                               (format "已选 %s · 点击高亮目标完成移动" (etaf-value selected))
                             "选牌 → 放到高亮位置 · Tab / 方向键导航，Enter 确认") :variant 'muted)
        (etaf-button :if (not (etaf-value wide)) :label "合法移动" :ref 'solitaire-show-hints :variant 'secondary
          :on-press (lambda () (setf (etaf-value hints) t))))
      (etaf-label :if (eq t (etaf-gamekit-view session :terminal))
        :text (if (= (or (plist-get (etaf-value table) :home) 0) 52) "全部归位。漂亮的一局！" "本局结束。可以撤销继续探索，或开始新局。")
        :variant 'strong :color (etaf-solitaire--color :ui-accent))
      (etaf-alert :if (etaf-gamekit-last-error session) :title "操作未完成" :message (etaf-gamekit-last-error session) :variant 'danger)
      (etaf-divider)
      (etaf-label :text "? / F1 查看快捷键与玩法" :variant 'muted)
      (etaf-dialog :open hints :title "合法移动" :width '(ch 34) :compact t
        :on-close (lambda () (setf (etaf-value hints) nil))
        (etaf-solitaire--hints :session session :table table :selected selected)))
    (box :flex-grow 3 :flex-basis '(lh 0) :min-height '(lh 0))))

(defun etaf-solitaire--view (session)
  "Build this application's presentation through public framework APIs."
  (etaf-view (etaf-solitaire--app :session session)))

(defun etaf-solitaire-view (session)
  "Return SESSION's reactive View for embedding in a host such as etaf-desktop.

The caller owns SESSION's display and lifecycle; release it with
`etaf-gamekit-close'."
  (etaf-solitaire--view session))

(provide 'etaf-solitaire-views)
;;; etaf-solitaire-views.el ends here
