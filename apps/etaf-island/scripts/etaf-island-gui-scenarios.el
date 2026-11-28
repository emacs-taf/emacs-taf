;;; -*- lexical-binding: t; -*-
;;; etaf-island-gui-scenarios.el --- Graphical appearance and interaction acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-island)
(require 'emacs-gui-verifier)

(declare-function etaf-posframe-live-p "etaf-posframe" (panel))

(defun etaf-island-gui--size (width rows)
  "Resize the verification frame to WIDTH pixels and ROWS text lines."
  (let ((chrome (- (frame-pixel-height) (window-body-height nil t))))
    (set-frame-parameter nil 'fullscreen nil)
    (set-frame-size nil width (+ chrome (* rows (frame-char-height))) t)))

(defun etaf-island-gui--buffer-text (buffer)
  "Return BUFFER text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-island-gui--seed-protocol-activities ()
  "Publish representative multi-app activities via `etaf-activity-publish'."
  (etaf-activity-publish
   'gui-ncm
   (list :app 'etaf-ncm :kind 'media :state 'active :priority 85
         :title "富士山下"
         :subtitle "陈奕迅 · 「谁能凭爱意要富士山私有」"
         :compact "富士山下"
         :meter (lambda (n)
                  (cl-loop for i below n
                           collect (+ 0.2 (* 0.7 (abs (sin (+ i 0.8)))))))
         :progress '(:value 134 :max 259 :unit seconds)
         :open #'ignore
         :actions (list (list :id 'prev :label "|< p" :fn #'ignore)
                        (list :id 'toggle :label "|| 暂停 k" :primary t :fn #'ignore)
                        (list :id 'next :label ">| n" :fn #'ignore))))
  (etaf-activity-publish
   'gui-pomodoro
   (list :app 'etaf-pomodoro :kind 'timer :state 'active :priority 90
         :title "深度专注"
         :subtitle "本轮 25:00 · 专注进行中"
         :compact "专注 18:42"
         :progress '(:value 378 :max 1500)
         :open #'ignore
         :actions (list (list :id 'toggle :label "暂停" :primary t :fn #'ignore)
                        (list :id 'extend :label "+5 分" :fn #'ignore))))
  (etaf-activity-publish
   'gui-bili
   (list :app 'etaf-bili :kind 'task :state 'active :priority 70
         :icon "↓" :title "B站视频缓存"
         :subtitle "Emacs ETAF 架构实战 · 1080P"
         :compact "68%"
         :progress '(:value 68 :max 100)
         :open #'ignore))
  (etaf-activity-publish
   'gui-inbox
   (list :app 'etaf-telega :kind 'inbox :state 'active :priority 60
         :title "未读收件箱"
         :subtitle "最新：Emacs China 群 · 2 分钟前"
         :compact "Telegram 3 · RSS 12"
         :open #'ignore))
  (etaf-activity-publish
   'gui-agenda
   (list :app 'etaf-agenda :kind 'schedule :state 'active :priority 55
         :title "今日日程"
         :subtitle "21:00 代码评审"
         :compact "剩 2 项"
         :open #'ignore)))

(defun etaf-island-gui--clear-protocol ()
  "Clear seeded protocol activities and notifications."
  (dolist (id '(gui-ncm gui-pomodoro gui-bili gui-inbox gui-agenda))
    (etaf-activity-remove id))
  (etaf-notify-clear))

(defun etaf-island-gui-run (directory)
  "Run ETAF Island GUI visual and keyboard verification into fresh DIRECTORY."
  (unless (display-graphic-p) (error "A graphical frame is required"))
  (let ((size (cons (frame-pixel-width) (frame-pixel-height)))
        (fullscreen (frame-parameter nil 'fullscreen))
        (etaf-animation-enabled t)
        (etaf-animation-paused nil)
        session buffer panel)
    (unwind-protect
        (cl-labels
            ((text () (etaf-island-gui--buffer-text buffer))
             (key-action (id keys predicate &optional screenshot)
               (etaf-gui-verifier-action-create
                :id id :screenshot screenshot
                :execute (lambda (_context)
                           (switch-to-buffer buffer)
                           (execute-kbd-macro (kbd keys)))
                :settled-p (lambda (_context) (funcall predicate)))))
          (etaf-island-gui--seed-protocol-activities)
          (etaf-gui-verifier-run
           (etaf-gui-verifier-scenario-create
            :name "etaf-island"
            :claim "Pure-protocol Dynamic Island across compact capsule, pulse card, expanded hub, dark/light palettes and headerless posframe"
            :initialize
            (lambda (context)
              (etaf-island-gui--size 1040 34)
              (setq session (etaf-island-create :appearance 'dark :mode 'compact :tab 'activities)
                    buffer (etaf-island-open session))
              (switch-to-buffer buffer)
              (etaf-gui-verifier-context-select-buffer context buffer)
              (message nil))
            :invariants
            (lambda (_context)
              (delq nil
                    (list
                     (etaf-gui-verifier-assert
                      "Original Emacs mode-line is preserved"
                      (with-current-buffer buffer (not (null mode-line-format))))
                     (etaf-gui-verifier-assert
                      "No horizontal overflow in standard wide window"
                      (if (not (eq (current-buffer) buffer))
                          t
                        (let ((w (window-body-width nil t))
                              (rendered (car (window-text-pixel-size
                                              nil (point-min) (point-max)))))
                          (or (< w 600) (<= rendered (+ w 4)))))))))
            :actions
            (list
             (etaf-gui-verifier-action-create
              :id "dark-compact-wide" :screenshot t
              :execute (lambda (_context) (etaf-island-gui--size 1040 30))
              :settled-p (lambda (_context) (string-match-p "展开 ▾" (text))))
             (key-action
              "dark-expanded-activities" "SPC"
              (lambda () (and (eq (plist-get (etaf-island-state session) :mode) 'expanded)
                              (string-match-p "富士山下" (text))))
              t)
             (etaf-gui-verifier-action-create
              :id "dark-alert-pulse" :screenshot t
              :execute (lambda (_context)
                         (etaf-island-set-mode session 'compact)
                         (etaf-island-notify
                          "编译与验收已通过 · etaf-ext"
                          :app 'compile
                          :detail "make check 完成：6/6 行为测试通过 · 70 项 API 校验通过"
                          :variant 'success
                          :group 'compile
                          :action-label "查看 *compilation*"
                          :on-action #'ignore
                          :ttl 8.0
                          :session session))
              :settled-p (lambda (_context)
                           (and (eq (plist-get (etaf-island-state session) :mode) 'alert)
                                (string-match-p "编译与验收已通过" (text)))))
             (key-action
              "light-expanded-events" "2 t"
              (lambda () (and (eq (plist-get (etaf-island-state session) :appearance) 'light)
                              (eq (plist-get (etaf-island-state session) :tab) 'events)
                              (string-match-p "清空全部" (text))))
              t)
             (key-action
              "light-expanded-quick" "3"
              (lambda () (and (eq (plist-get (etaf-island-state session) :tab) 'quick)
                              (string-match-p "Emacs 原生传感器" (text))))
              t)
             (etaf-gui-verifier-action-create
              :id "floating-posframe" :screenshot nil
              :execute (lambda (context)
                         (etaf-island-gui--size 1040 30)
                         (etaf-island-toggle-appearance session)
                         (etaf-island-set-mode session 'compact)
                         (let ((demo (get-buffer-create "*ETAF Island Host Buffer*")))
                           (with-current-buffer demo
                             (erase-buffer)
                             (insert ";; 常规编辑缓冲：验证顶部极简 1 行 etaf-posframe 灵动岛\n\n")
                             (dotimes (i 18)
                               (insert (format "(defun demo-fn-%02d (x) (+ x %d))\n" i i)))
                             (goto-char (point-min)))
                           (switch-to-buffer demo)
                           (etaf-gui-verifier-context-select-buffer context demo)
                           (setq panel (etaf-island-show session))))
              :settled-p (lambda (_context)
                           (and (featurep 'etaf-posframe)
                                panel
                                (etaf-posframe-live-p panel)))
              :assertions
              (lambda (_context)
                (list
                 (etaf-gui-verifier-assert
                  "Floating headerless posframe capsule is live over regular editing buffer"
                  (and panel (etaf-posframe-live-p panel))))))))
           directory)
          'ok)
      (ignore-errors (etaf-island-hide))
      (etaf-island-gui--clear-protocol)
      (when (buffer-live-p (get-buffer "*ETAF Island Host Buffer*"))
        (kill-buffer "*ETAF Island Host Buffer*"))
      (when (buffer-live-p buffer) (etaf-app-close buffer))
      (set-frame-size nil (car size) (cdr size) t)
      (set-frame-parameter nil 'fullscreen fullscreen))))

(provide 'etaf-island-gui-scenarios)
;;; etaf-island-gui-scenarios.el ends here
