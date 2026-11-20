;;; -*- lexical-binding: t; -*-
;;; etaf-mario-views.el --- HUD, canvas and controlled dialogs

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The canvas is a column of Text Hosts, one per text row, each addressed by a
;; stable ref so the loop can publish changed rows without republishing the
;; application.  The HUD numbers are Text Hosts for the same reason; only
;; phase changes, the power badge and dialog state repaint whole subtrees.

;;; Code:

(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-mario-theme)
(require 'etaf-mario-session)
(require 'etaf-mario-art)
(require 'etaf-mario-levels)

(declare-function etaf-mario--start-game "etaf-mario-app" (session))
(declare-function etaf-mario--resume "etaf-mario-app" (session))
(declare-function etaf-mario--pause "etaf-mario-app" (session))
(declare-function etaf-mario--restart "etaf-mario-app" (session))
(declare-function etaf-mario--next-level "etaf-mario-app" (session))
(declare-function etaf-mario--to-title "etaf-mario-app" (session))
(declare-function etaf-mario--choose-level "etaf-mario-app" (session level))
(declare-function etaf-mario--set-setting "etaf-mario-app" (session key value))
(declare-function etaf-mario--set-appearance "etaf-mario-app" (session value))
(declare-function etaf-mario--toggle-theme "etaf-mario-app" (session))
(declare-function etaf-mario--close-settings "etaf-mario-app" (session))
(declare-function etaf-mario--close-select "etaf-mario-app" (session))
(declare-function etaf-mario--select-dialog "etaf-mario-app" (session &optional open))
(declare-function etaf-mario--settings "etaf-mario-app" (session))
(declare-function etaf-mario--toggle-settings "etaf-mario-app" (session))
(declare-function etaf-mario--press-jump "etaf-mario-app" (session))
(declare-function etaf-mario--press-run "etaf-mario-app" (session))
(declare-function etaf-mario--pause-or-resume "etaf-mario-app" (session))
(declare-function etaf-mario--direction "etaf-mario-app" (session direction))
(declare-function etaf-mario--session-level-label "etaf-mario-app" (session))
(declare-function etaf-mario--session-unlocked-label "etaf-mario-app" (session))
(declare-function etaf-mario-open "etaf-mario" (&optional level))
(declare-function etaf-mario-close "etaf-mario" (&optional buffer-or-name))

(etaf-define-component etaf-mario--hud (&key session)
  "Show the running counters of SESSION above the canvas."
  :bindings ((phase (etaf-mario--session-phase-ref session))
             (appearance (etaf-mario--session-appearance-ref session))
             (power (etaf-mario--session-power-ref session))
             (level (etaf-mario--session-level-ref session))
             (cols (etaf-computed
                    (lambda ()
                      (let ((width (car (etaf-viewport))))
                        (if (and width (numberp width) (> width 0))
                            (floor (/ (float width) (frame-char-width)))
                          (or (etaf-mario--session-cols session) 80))))
                    :test #'equal))
             (wide (etaf-computed (lambda () (>= (etaf-value cols) 100)) :test #'eq))
             (compact (etaf-computed (lambda () (< (etaf-value cols) 78)) :test #'eq)))
  :view
  (flex :width 'stretch :height '(lh 1) :padding '((lh 0) (ch 1))
    :justify-content 'space-between :align-items 'center
    (row :item-gap '(ch 2)
      (row :item-gap '(ch 1)
        (text :font-size 0.7 :font-weight 'bold :color (etaf-mario--color :mario-hud-muted)
          "MARIO")
        (text :ref 'etaf-mario-hud-score :font-weight 'bold :font-size 0.9
          (expr (format "%06d" (etaf-mario-world-score (etaf-mario--session-world session))))))
      (row :item-gap '(ch 1)
        (text :font-size 0.75 :color (etaf-mario--color :mario-coin) "●")
        (text :ref 'etaf-mario-hud-coins :font-weight 'bold :font-size 0.8
          (expr (format "×%02d" (etaf-mario-world-coins (etaf-mario--session-world session))))))
      (row :if (not (etaf-value compact)) :item-gap '(ch 1)
        (text :font-size 0.7 :font-weight 'bold :color (etaf-mario--color :mario-hud-muted) "WORLD")
        (text :font-size 0.9 :font-weight 'bold (expr (etaf-value level))))
      (row :item-gap '(ch 1)
        (text :font-size 0.7 :font-weight 'bold :color (etaf-mario--color :mario-hud-muted) "TIME")
        (text :ref 'etaf-mario-hud-time :font-weight 'bold :font-size 0.9
          (expr (format "%03d" (etaf-mario-world-time (etaf-mario--session-world session)))))))
    (row :item-gap '(ch 2)
      (etaf-badge :text (pcase (etaf-value power)
                          ('star "星星")
                          ('fire "火焰")
                          ('big "超级")
                          (_ "小马里奥"))
        :variant (pcase (etaf-value power)
                   ('star 'warning)
                   ('fire 'danger)
                   ('big 'success)
                   (_ 'neutral)))
      (row :item-gap '(ch 0)
        (text :font-size 0.75 :color (etaf-mario--color :mario-life) "♥")
        (text :ref 'etaf-mario-hud-lives :font-weight 'bold :font-size 0.8
          (expr (format "×%d" (etaf-mario-world-lives (etaf-mario--session-world session))))))
      (row :if (etaf-value wide) :item-gap '(ch 1) :focus-group 'horizontal
        (etaf-button :label "说明 F1" :variant 'ghost :tab-index 1
          :on-press (lambda () (etaf-mario--pause session) (etaf-help)))
        (etaf-button :label "暂停 P" :variant 'ghost :tab-index 2
          :on-press (lambda () (etaf-mario--pause session)))
        (etaf-button :label "设置 S" :variant 'ghost :tab-index 3
          :on-press (lambda () (etaf-mario--settings session))))
      (etaf-button :if (and (not (etaf-value wide)) (eq (etaf-value phase) 'playing))
        :label "菜单" :variant 'ghost :tab-index 1
        :on-press (lambda () (etaf-mario--pause session))))))

(etaf-define-component etaf-mario--canvas (&key session)
  "Draw SESSION's retained canvas rows."
  :bindings ((revision (etaf-mario--session-revision session))
             (size (etaf-mario--session-size-ref session)))
  :view
  (box :width (list 'ch (max 1 (car (etaf-value size))))
    :height (list 'lh (max 1 (cdr (etaf-value size))))
    :overflow 'hidden :wrap-mode 'none
    (box :for (row (progn (etaf-value revision)
                          (etaf-mario--session-frame session)))
      :key (car row) :height '(lh 1)
      (text :ref (car row) (expr (cdr row))))))

(etaf-define-component etaf-mario--footer (&key session)
  "Show hints and the latest event below SESSION's canvas."
  :bindings ((message (etaf-mario--session-message-ref session))
             (best (etaf-mario--session-best-ref session))
             (cols (etaf-computed
                    (lambda ()
                      (let ((width (car (etaf-viewport))))
                        (if (and width (numberp width) (> width 0))
                            (floor (/ (float width) (frame-char-width)))
                          (or (etaf-mario--session-cols session) 80))))
                    :test #'equal))
             (wide (etaf-computed (lambda () (>= (etaf-value cols) 84)) :test #'eq)))
  :view
  (flex :width 'stretch :height '(lh 1) :padding '((lh 0) (ch 1))
    :justify-content 'space-between :align-items 'center
    (row :item-gap '(ch 2)
      (text :font-size 0.75 :color (etaf-mario--color :ui-muted-fg)
        (expr (if (etaf-value wide)
                  "← → 移动   Z 跳跃   X 加速 / 火球   ↓ 下蹲   P 暂停   R 重来"
                "← → 移动 · Z 跳跃 · P 暂停")))
      (etaf-label :if (etaf-value message) :text (etaf-value message)
        :variant 'strong :color (etaf-mario--color :ui-accent)))
    (row :item-gap '(ch 1)
      (text :if (etaf-value wide) :font-size 0.75
        :color (etaf-mario--color :ui-muted-fg)
        (expr (format "最高分 %06d" (etaf-value best))))
      (etaf-button :label "说明" :variant 'ghost :tab-index -1
        :on-press (lambda () (etaf-mario--pause session) (etaf-help)))
      (etaf-button :label "主题" :variant 'ghost :tab-index -1
        :on-press (lambda () (etaf-mario--toggle-theme session))))))

(etaf-define-component etaf-mario--dialog-title (&key session keys on-direction)
  "Show SESSION's title menu while its phase is `title'."
  :bindings ((phase (etaf-mario--session-phase-ref session)))
  :view
  (etaf-dialog :open (eq (etaf-value phase) 'title) :title "超级马里奥"
    :keys keys :on-direction on-direction
    :width '(ch 44) :compact t :close-label nil
    :on-close (lambda () (etaf-mario--to-title session))
    (column :width 'stretch :item-gap '(lh 1)
      (text :font-size 0.75 :color (etaf-mario--color :ui-muted-fg)
        "ETAF 文本平台跳跃 · 四个关卡")
      (etaf-divider)
      (etaf-button :label "开始游戏" :ref 'mario-start
        :on-press (lambda () (etaf-mario--start-game session)))
      (etaf-button :label "选择关卡" :variant 'secondary :ref 'mario-select
        :on-press (lambda () (etaf-mario--select-dialog session t)))
      (etaf-button :label "操作说明 F1" :variant 'ghost :ref 'mario-help
        :on-press #'etaf-help)
      (etaf-button :label "设置 S" :variant 'ghost :ref 'mario-settings
        :on-press (lambda () (etaf-mario--settings session)))
      (etaf-button :label "退出 Q" :variant 'ghost :ref 'mario-quit
        :on-press (lambda () (etaf-mario-close)))
      (etaf-divider)
      (text :font-size 0.75 :color (etaf-mario--color :ui-muted-fg)
        (expr (format "最高分 %06d · 已通到 %s"
                      (or (etaf-mario--session-best session) 0)
                      (etaf-mario--session-unlocked-label session)))))))

(etaf-define-component etaf-mario--dialog-pause (&key session keys on-direction)
  "Show SESSION's pause menu while its phase is `paused'."
  :bindings ((phase (etaf-mario--session-phase-ref session)))
  :view
  (etaf-dialog :open (eq (etaf-value phase) 'paused) :title "暂停"
    :keys keys :on-direction on-direction
    :width '(ch 38) :compact t :close-label nil
    :on-close (lambda () (etaf-mario--resume session))
    (column :width 'stretch :item-gap '(lh 1)
      (etaf-button :label "继续游戏" :ref 'mario-resume
        :on-press (lambda () (etaf-mario--resume session)))
      (etaf-button :label "重新开始" :variant 'secondary
        :on-press (lambda () (etaf-mario--restart session)))
      (etaf-button :label "操作说明" :variant 'ghost :on-press #'etaf-help)
      (etaf-button :label "设置" :variant 'ghost
        :on-press (lambda () (etaf-mario--settings session)))
      (etaf-divider)
      (etaf-button :label "返回标题" :variant 'ghost
        :on-press (lambda () (etaf-mario--to-title session)))
      (etaf-button :label "退出游戏" :variant 'ghost
        :on-press (lambda () (etaf-mario-close))))))

(etaf-define-component etaf-mario--dialog-settings (&key session keys on-direction)
  "Show SESSION's settings while its phase is `settings'."
  :bindings ((phase (etaf-mario--session-phase-ref session))
             (appearance (etaf-mario--session-appearance-ref session)))
  :view
  (etaf-dialog :open (eq (etaf-value phase) 'settings) :title "设置"
    :keys keys :on-direction on-direction
    :width '(ch 46) :compact t :close-label nil
    :on-close (lambda () (etaf-mario--close-settings session))
    (column :width 'stretch :item-gap '(lh 1)
      (etaf-label :text "画面帧率" :variant 'strong)
      (etaf-segmented :value (plist-get (etaf-mario--session-settings session) :frame-rate)
        :options '((30 . "30 帧") (60 . "60 帧"))
        :on-change (lambda (value) (etaf-mario--set-setting session :frame-rate value)))
      (etaf-label :text "跳跃手感" :variant 'strong)
      (etaf-segmented :value (plist-get (etaf-mario--session-settings session) :jump-feel)
        :options '((normal . "标准") (high . "高跳") (low . "低跳"))
        :on-change (lambda (value) (etaf-mario--set-setting session :jump-feel value)))
      (etaf-label :text "界面主题" :variant 'strong)
      (etaf-segmented :value (etaf-value appearance)
        :options '((light . "浅色") (dark . "深色"))
        :on-change (lambda (value) (etaf-mario--set-appearance session value)))
      (etaf-divider)
      (etaf-button :label "关闭" :variant 'secondary
        :on-press (lambda () (etaf-mario--close-settings session))))))

(etaf-define-component etaf-mario--dialog-select (&key session keys on-direction)
  "Show SESSION's level picker while its phase is `select'."
  :bindings ((phase (etaf-mario--session-phase-ref session)))
  :view
  (etaf-dialog :open (eq (etaf-value phase) 'select) :title "选择关卡"
    :keys keys :on-direction on-direction
    :width '(ch 46) :compact t :close-label nil
    :on-close (lambda () (etaf-mario--close-select session))
    (column :width 'stretch :item-gap '(lh 1)
      (etaf-button :for (level (number-sequence 0 (1- (length etaf-mario-levels))))
        :key level
        :label (let* ((definition (nth level etaf-mario-levels))
                      (unlocked (<= level
                                    (or (plist-get (etaf-mario--session-progress session) :unlocked)
                                        0))))
                  (format "%s%s" (plist-get definition :name)
                          (if unlocked "" " · 未解锁")))
        :variant (if (= level (etaf-mario-world-index (etaf-mario--session-world session))) 'primary 'secondary)
        :disabled (not (<= level
                           (or (plist-get (etaf-mario--session-progress session) :unlocked) 0)))
        :on-press (lambda () (etaf-mario--choose-level session level)))
      (etaf-divider)
      (etaf-button :label "关闭" :variant 'ghost
        :on-press (lambda () (etaf-mario--close-select session))))))

(etaf-define-component etaf-mario--dialog-status (&key session keys on-direction)
  "Show SESSION's level clear, game over or victory dialog."
  :bindings ((phase (etaf-mario--session-phase-ref session)))
  :view
  (etaf-dialog :open (memq (etaf-value phase) '(cleared victory gameover))
    :keys keys :on-direction on-direction
    :title (pcase (etaf-value phase)
             ('victory "通关")
             ('cleared "过关")
             (_ "游戏结束"))
    :width '(ch 42) :compact t :close-label nil
    :on-close (lambda ()
                (if (eq (etaf-value phase) 'gameover)
                    (etaf-mario--restart session)
                  (etaf-mario--next-level session)))
    (column :width 'stretch :item-gap '(lh 1)
      (text :font-size 1.3 :font-weight 'bold
        (expr (pcase (etaf-value phase)
                ('victory "四个关卡全部通关")
                ('cleared (format "%s 过关" (etaf-mario--session-level-label session)))
                (_ "生命用尽"))))
      (etaf-label :text (format "得分 %06d · 金币 %02d · 剩余生命 %d"
                                (etaf-mario-world-score (etaf-mario--session-world session))
                                (etaf-mario-world-coins (etaf-mario--session-world session))
                                (etaf-mario-world-lives (etaf-mario--session-world session)))
        :variant 'muted)
      (etaf-divider)
      (etaf-button :if (eq (etaf-value phase) 'gameover)
        :label "再来一次" :ref 'mario-retry
        :on-press (lambda () (etaf-mario--restart session)))
      (etaf-button :if (not (eq (etaf-value phase) 'gameover))
        :label (if (or (eq (etaf-value phase) 'victory)
                       (>= (etaf-mario-world-index (etaf-mario--session-world session))
                           (1- (length etaf-mario-levels))))
                   "返回标题"
                 "下一关")
        :ref 'mario-continue
        :on-press (lambda () (etaf-mario--next-level session)))
      (etaf-button :label "返回标题" :variant 'ghost
        :on-press (lambda () (etaf-mario--to-title session))))))

(etaf-define-component etaf-mario--app (&key session)
  "Compose the whole Mario application around SESSION."
  :bindings ((appearance (etaf-mario--session-appearance-ref session))
             (theme (etaf-computed
                     (lambda ()
                       (if (eq (etaf-value appearance) 'dark)
                           etaf-mario--dark-theme
                         etaf-mario--light-theme))
                     :test #'equal))
             (phase (etaf-mario--session-phase-ref session))
             (keys (list
                    (list "z" (lambda () (etaf-mario--press-jump session)) "跳跃")
                    (list "x" (lambda () (etaf-mario--press-run session)) "加速或火球")
                    (list "p" (lambda () (etaf-mario--pause-or-resume session)) "暂停或继续")
                    (list "r" (lambda () (etaf-mario--restart session)) "重开")
                    (list "s" (lambda () (etaf-mario--toggle-settings session)) "设置")
                    (list "t" (lambda () (etaf-mario--toggle-theme session)) "亮暗主题")
                    (list "<f1>" #'etaf-help "规则与按键")
                    (list "q" (lambda () (etaf-mario-close)) "退出")))
             (direction (lambda (dir) (etaf-mario--direction session dir))))
  :setup (etaf-theme-provide theme)
  :view
  (flex :width 'stretch :height 'stretch :overflow 'hidden
    :flex-direction 'column
    :justify-content 'center
    :color (etaf-mario--color :ui-fg)
    :aria-label "超级马里奥"
    :help '("方向键左右移动，Z 跳跃（按住更高），X 加速并在拿到火焰花后发射火球。踩扁板栗仔，踩乌龟得到龟壳；蘑菇变大，星星短暂无敌。")
    :keys keys
    :on-direction direction
    (column :width 'stretch :flex-shrink 0
      (etaf-mario--hud :session session)
      (etaf-mario--canvas :session session)
      (etaf-mario--footer :session session))
    (etaf-mario--dialog-title :session session :keys keys :on-direction #'etaf-mario--dialog-direction)
    (etaf-mario--dialog-pause :session session :keys keys :on-direction #'etaf-mario--dialog-direction)
    (etaf-mario--dialog-settings :session session :keys keys :on-direction #'etaf-mario--dialog-direction)
    (etaf-mario--dialog-select :session session :keys keys :on-direction #'etaf-mario--dialog-direction)
    (etaf-mario--dialog-status :session session :keys keys :on-direction #'etaf-mario--dialog-direction)))

(defun etaf-mario--dialog-direction (_direction)
  "Release direction keys so a dialog's own focus navigation handles them.
The game's direction handler moves the player; while a controlled dialog is
open the game is paused, so arrows must move between that dialog's controls
instead of being swallowed by the game."
  'release)

(defun etaf-mario--view (session)
  "Return SESSION's reactive View."
  (etaf-view (etaf-mario--app :session session)))

(provide 'etaf-mario-views)
;;; etaf-mario-views.el ends here
