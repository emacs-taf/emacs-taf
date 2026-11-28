;;; etaf-balatro-app.el --- Application host and keyboard bindings for ETAF Balatro -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Connects `etaf-balatro' sessions to an ETAF application buffer (`etaf-balatro-open')
;; preserving Emacs's native mode-line, hiding the stray text cursor, and
;; reactively repainting the canvas when Emacs switches themes (`load-theme').
;; Declares full scoped keyboard navigation for card selection, hand play,
;; cascade skip, targeted Tarots (`u' / `U'), Joker reordering, shop actions,
;; onboarding guide (`g'), smart Coach toggle (`G') and modals (`v' / `h').

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-balatro-theme)
(require 'etaf-balatro-engine)
(require 'etaf-balatro-model)
(require 'etaf-balatro-views)

(defconst etaf-balatro--buffer-name "*ETAF Balatro*"
  "Buffer name used by `etaf-balatro-open'.")

(defun etaf-balatro--reset-focus-to-root ()
  "Move ETAF focus back to `ante-root' in the current buffer when mounted.
Prevents a previously mouse-clicked button from hijacking keyboard Enter."
  (etaf-balatro--focus-ref 'balatro-root))

(defun etaf-balatro--digit-action (session digit)
  "Handle number key DIGIT (1..8) in SESSION based on current modal or phase."
  (cond
   ((eq (etaf-balatro--val session :modal) 'guide)
    (when (<= digit 4)
      (etaf-balatro-open-guide session (1- digit))))
   ((etaf-balatro--val session :modal) nil)
   (t
    (etaf-balatro--reset-focus-to-root)
    (let ((phase (etaf-balatro--val session :phase))
          (idx (1- digit)))
      (pcase phase
        ('playing (etaf-balatro-toggle-card session idx))
        ('shop (when (<= digit 4) (etaf-balatro-buy-shop-item session idx)))
        (_ nil))))))

(defun etaf-balatro--return-action (session)
  "Handle RET / `<return>' in SESSION: step guide, play, advance or restart."
  (cond
   ((eq (etaf-balatro--val session :modal) 'guide)
    (etaf-balatro-guide-step session 1))
   ((etaf-balatro--val session :modal)
    (etaf-balatro-toggle-modal session nil))
   (t
    (pcase (etaf-balatro--val session :phase)
      ('playing (etaf-balatro-play-hand session))
      ('shop (etaf-balatro-next-blind session))
      ((or 'victory 'gameover) (etaf-balatro-restart session))
      (_ nil)))))

(defun etaf-balatro--next-action (session)
  "Handle `n' in SESSION: advance onboarding guide or proceed to next blind."
  (cond
   ((eq (etaf-balatro--val session :modal) 'guide)
    (etaf-balatro-guide-step session 1))
   ((eq (etaf-balatro--val session :phase) 'shop)
    (etaf-balatro-next-blind session))
   (t nil)))

(defun etaf-balatro--prev-action (session)
  "Handle `p' / `<left>' in SESSION: step back inside onboarding guide."
  (when (eq (etaf-balatro--val session :modal) 'guide)
    (etaf-balatro-guide-step session -1)))

(defun etaf-balatro--space-action (session)
  "Handle SPC in SESSION: skip active cascade animation or cycle speed."
  (cond
   ((eq (etaf-balatro--val session :modal) 'guide)
    (etaf-balatro-guide-step session 1))
   ((etaf-balatro--val session :animating)
    (etaf-balatro-skip-animation session))
   (t
    (let* ((cur (etaf-balatro--val session :speed))
           (next (cond ((< cur 1.5) 2.0)
                       ((< cur 3.0) 4.0)
                       (t 1.0))))
      (etaf-balatro-set-speed session next)
      (etaf-balatro--set session :message
                      (format "连锁动画倍速已切换为 %s×"
                              (etaf-balatro--format-mult next)))))))

(defun etaf-balatro--keys (session &optional close-fn)
  "Return scoped root `:keys' declarations for SESSION and optional CLOSE-FN."
  (append
   (cl-loop for d from 1 to 8
            collect (list (number-to-string d)
                          (let ((n d))
                            (lambda () (etaf-balatro--digit-action session n)))
                          (if (<= d 4)
                              (format "选第 %d 张牌 / 买第 %d 件商品" d d)
                            (format "选第 %d 张手牌" d))))
   (list
    (list "RET" (lambda () (etaf-balatro--return-action session)) "出牌 / 进入下一关 / 指引下一步")
    (list "<return>" (lambda () (etaf-balatro--return-action session)))
    (list "SPC" (lambda () (etaf-balatro--space-action session)) "跳过动画 / 切倍速")
    (list "d" (lambda () (etaf-balatro-discard session)) "弃牌补牌")
    (list "s" (lambda () (etaf-balatro-cycle-sort session)) "切换点数/花色排序")
    (list "," (lambda () (etaf-balatro-move-joker session -1)) "小丑左移")
    (list "." (lambda () (etaf-balatro-move-joker session 1)) "小丑右移")
    (list "[" (lambda () (etaf-balatro-move-joker session -1)) "小丑左移")
    (list "]" (lambda () (etaf-balatro-move-joker session 1)) "小丑右移")
    (list "u" (lambda () (etaf-balatro-use-consumable session 0)) "使用消耗品 1")
    (list "U" (lambda () (etaf-balatro-use-consumable session 1)) "使用消耗品 2（塔罗需先选牌）")
    (list "r" (lambda () (etaf-balatro-reroll-shop session)) "刷新商店 ($5)")
    (list "x" (lambda () (etaf-balatro-sell-joker session)) "出售选中 Joker")
    (list "n" (lambda () (etaf-balatro--next-action session)) "下一关 / 指引下一页")
    (list "p" (lambda () (etaf-balatro--prev-action session)) "指引上一页")
    (list "v" (lambda () (etaf-balatro-toggle-modal session 'deck)) "查看 52 张牌库矩阵")
    (list "h" (lambda () (etaf-balatro-toggle-modal session 'hands)) "牌型倍率表")
    (list "g" (lambda () (etaf-balatro-open-guide session 0)) "打开 60 秒新手指引")
    (list "G" (lambda () (etaf-balatro-toggle-coach session)) "开关实战智能提示")
    (list "t" (lambda () (etaf-balatro-toggle-appearance session)) "切换跟随主题/深色/浅色")
    (list "N" (lambda () (etaf-balatro-restart session)) "新开一局")
    (list "<f1>" #'etaf-help "快捷键帮助"))
   (when close-fn
     (list (list "q" close-fn "关闭 ETAF Balatro")))))

(defun etaf-balatro--dismiss (session)
  "Handle Escape in SESSION: close modal, skip animation or clear selection."
  (cond
   ((etaf-balatro--val session :modal)
    (etaf-balatro-toggle-modal session nil)
    (etaf-balatro--reset-focus-to-root))
   ((etaf-balatro--val session :animating)
    (etaf-balatro-skip-animation session))
   ((etaf-balatro--val session :selected-ids)
    (etaf-balatro-clear-selection session))
   (t nil)))

;;;###autoload
(defun etaf-balatro-view (&optional session quit)
  "Return an embeddable ETAF View for SESSION.
QUIT non-nil adds a `q' key binding that closes the standalone window."
  (let* ((sess (or session (etaf-balatro-new-run :appearance 'auto)))
         (close-fn (when quit
                     (lambda ()
                       (etaf-balatro--stop-timeline sess)
                       (when-let* ((buf (etaf-app-buffer etaf-balatro--buffer-name)))
                         (etaf-app-close buf))))))
    (etaf-view (etaf-balatro--root :session sess
                                :keys (etaf-balatro--keys sess close-fn)
                                :on-dismiss (lambda () (etaf-balatro--dismiss sess))))))

;;;###autoload
(defun etaf-balatro-open (&optional seed)
  "Open ETAF Balatro in its own buffer preserving Emacs's mode-line.
Optional SEED is an integer for deterministic deals, or an existing session
created by `etaf-balatro-new-run'.  Returns the mounted buffer."
  (interactive)
  (let* ((sess (if (and (listp seed) (eq (plist-get seed :type) 'etaf-balatro-session))
                   seed
                 (etaf-balatro-new-run
                  :seed (when (integerp seed) seed)
                  :appearance 'auto)))
         (view (etaf-balatro-view sess t))
         ;; Track both session :appearance and host theme epoch reactively so
         ;; `etaf-app' repaints the buffer default face on `load-theme' or `t'.
         (bg (lambda ()
               (etaf-value etaf-balatro--theme-epoch)
               (plist-get (etaf-balatro--tokens
                           (etaf-value (plist-get sess :appearance)))
                          :balatro-bg)))
         (fg (lambda ()
               (etaf-value etaf-balatro--theme-epoch)
               (plist-get (etaf-balatro--tokens
                           (etaf-value (plist-get sess :appearance)))
                          :balatro-fg))))
    (etaf-app-open etaf-balatro--buffer-name view
                   :state sess
                   :background bg
                   :foreground fg
                   :cursor nil
                   :mode-line t
                   :on-close (lambda () (etaf-balatro--stop-timeline sess))
                   :display (called-interactively-p 'interactive))))

(provide 'etaf-balatro-app)
;;; etaf-balatro-app.el ends here
