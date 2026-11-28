;;; etaf-island-tests.el --- Public behavior tests for pure-protocol ETAF Island -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise `etaf-island' exclusively through public `etaf' and `etaf-island'
;; interfaces: pure-protocol activity rendering, real meter sampling, live
;; `etaf-notify' pulsing/grouping, keyboard navigation, zero demo data and
;; standalone mode-line preservation.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'etaf-island)

(defmacro etaf-island-test--clean (&rest body)
  "Run BODY with a clean activity and notification registry."
  `(let ((saved-acts (etaf-activity-list))
         (saved-notes (etaf-notify-list))
         (etaf-notify-functions nil)
         (etaf-activity-change-functions nil))
     (dolist (a saved-acts) (etaf-activity-remove (plist-get a :id)))
     (etaf-notify-clear)
     (unwind-protect
         (progn ,@body)
       (when (bound-and-true-p etaf-island-mode)
         (etaf-island-mode -1))
       (dolist (a (etaf-activity-list)) (etaf-activity-remove (plist-get a :id)))
       (etaf-notify-clear)
       (dolist (a saved-acts) (etaf-activity-publish (plist-get a :id) a)))))

(defun etaf-island-test--wait (predicate)
  "Process timers until PREDICATE returns non-nil, with a bounded deadline."
  (let ((deadline (+ (float-time) 2.5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(defun etaf-island-test--text (buffer)
  "Return plain text content of BUFFER."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest etaf-island-model-transitions-and-validation ()
  "Headless session validates arguments and tracks live protocol snapshots."
  (etaf-island-test--clean
   (should-error (etaf-island-create :mode 'bogus) :type 'etaf-island-error)
   (should-error (etaf-island-create :tab 'bogus) :type 'etaf-island-error)
   (should-error (etaf-island-create :appearance 'neon) :type 'etaf-island-error)
   (let ((session (etaf-island-create :appearance 'dark :mode 'compact)))
     (should (eq 'compact (plist-get (etaf-island-state session) :mode)))
     (should (null (plist-get (etaf-island-state session) :activities)))
     (etaf-activity-publish
      'test-music
      (list :app 'test-player :kind 'media :state 'active
            :title "富士山下" :subtitle "陈奕迅" :compact "富士山下"))
     (should (= 1 (length (plist-get (etaf-island-state session) :activities))))
     (etaf-island-select-tab session 'events)
     (should (eq 'expanded (plist-get (etaf-island-state session) :mode)))
     (should (eq 'events (plist-get (etaf-island-state session) :tab)))
     (should (eq 'light (etaf-island-toggle-appearance session))))))

(ert-deftest etaf-island-open-renders-protocol-activities-and-keeps-mode-line ()
  "Standalone buffer preserves mode-line, renders live protocol activities and runs publisher actions."
  (etaf-island-test--clean
   (let* ((toggled 0)
          (opened 0)
          (session (etaf-island-create :mode 'compact :appearance 'dark))
          (buffer (etaf-island-open session))
          (runtime (etaf-runtime-for-buffer buffer)))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (etaf-runtime-refit runtime 960 32)
           ;; Preserves Emacs mode-line and shows zero hardcoded demo content when idle.
           (with-current-buffer buffer
             (should mode-line-format))
           (let ((idle-text (etaf-island-test--text buffer)))
             (should-not (string-match-p "晴天" idle-text))
             (should-not (string-match-p "发送测试脉冲" idle-text)))
           ;; Publishing real activities updates compact capsule reactively.
           (etaf-activity-publish
            'ncm-live
            (list :app 'etaf-ncm :kind 'media :state 'active :priority 80
                  :title "富士山下" :subtitle "陈奕迅 · 谁能凭爱意要富士山私有"
                  :compact "富士山下"
                  :meter (lambda (n) (make-list n 0.6))
                  :progress '(:value 134 :max 259 :unit seconds)
                  :open (lambda () (cl-incf opened))
                  :actions (list (list :id 'toggle :label "暂停 k" :primary t
                                       :fn (lambda () (cl-incf toggled))))))
           (etaf-activity-publish
            'pomo-live
            (list :app 'etaf-pomodoro :kind 'timer :state 'active :priority 90
                  :title "深度专注" :subtitle "本轮 25:00" :compact "专注 18:42"
                  :progress '(:value 378 :max 1500)))
           (let ((compact-text (etaf-island-test--text buffer)))
             (should (string-match-p "专注 18:42" compact-text))
             (should (string-match-p "富士山下" compact-text))
             (should (string-match-p "展开 ▾" compact-text)))
           ;; Expand via SPC and inspect friendly labels & full keyboard nav.
           (execute-kbd-macro (kbd "SPC"))
           (should (eq 'expanded (plist-get (etaf-island-state session) :mode)))
           (let ((exp-text (etaf-island-test--text buffer)))
             (should (string-match-p "实时活动 2" exp-text))
             (should (string-match-p "富士山下" exp-text))
             (should (string-match-p "网易云音乐" exp-text))
             (should-not (string-match-p "etaf-ncm" exp-text))
             (should (string-match-p "深度专注" exp-text)))
           ;; Full keyboard navigation: SPC/RET activates selected card, j/k moves
           ;; selection, o opens source app, h/l/TAB/1/2/3 switches tabs, 0 resets
           ;; position, ESC collapses back to compact capsule.
           (should (= 0 (plist-get (etaf-island-state session) :selection)))
           (execute-kbd-macro (kbd "RET"))
           (should (= 1 toggled))
           (execute-kbd-macro (kbd "SPC"))
           (should (= 2 toggled))
           (execute-kbd-macro "j")
           (should (= 1 (plist-get (etaf-island-state session) :selection)))
           (execute-kbd-macro "k")
           (should (= 0 (plist-get (etaf-island-state session) :selection)))
           (execute-kbd-macro "o")
           (should (= 1 opened))
           (execute-kbd-macro "l")
           (should (eq 'events (plist-get (etaf-island-state session) :tab)))
           (execute-kbd-macro (kbd "<right>"))
           (should (eq 'quick (plist-get (etaf-island-state session) :tab)))
           (should (string-match-p "Emacs 原生传感器" (etaf-island-test--text buffer)))
           (execute-kbd-macro "h")
           (should (eq 'events (plist-get (etaf-island-state session) :tab)))
           (execute-kbd-macro "1")
           (should (eq 'activities (plist-get (etaf-island-state session) :tab)))
           (execute-kbd-macro "0")
           (should (null (plist-get (etaf-island-state session) :custom-anchor)))
           (execute-kbd-macro "t")
           (should (eq 'light (plist-get (etaf-island-state session) :appearance)))
           (execute-kbd-macro (kbd "<escape>"))
           (should (eq 'compact (plist-get (etaf-island-state session) :mode))))
       (when (buffer-live-p buffer)
         (etaf-app-close buffer))))))

(ert-deftest etaf-island-notification-pulses-runs-action-and-auto-collapses ()
  "Protocol `etaf-notify' pulses alert mode, executes action and auto-collapses."
  (etaf-island-test--clean
   (let* ((session (etaf-island-create :mode 'compact :appearance 'dark))
          (buffer (etaf-island-open session))
          (runtime (etaf-runtime-for-buffer buffer))
          (triggered 0))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (etaf-runtime-refit runtime 960 32)
           (etaf-island-notify "编译通过 · etaf-ext"
                               :app 'compile
                               :detail "6/6 测试通过"
                               :variant 'success
                               :group 'compile
                               :action-label "查看编译日志"
                               :on-action (lambda () (cl-incf triggered))
                               :ttl 0
                               :session session)
           (should (eq 'alert (plist-get (etaf-island-state session) :mode)))
           (let ((text (etaf-island-test--text buffer)))
             (should (string-match-p "编译通过" text))
             (should (string-match-p "查看编译日志" text)))
           (etaf-dispatch-event runtime 'island-alert-action 'press)
           (should (= 1 triggered))
           (should (eq 'compact (plist-get (etaf-island-state session) :mode)))
           ;; Short TTL auto-collapses back to compact mode via etaf-transition.
           (etaf-island-notify "短暂脉冲" :detail "自动收起" :variant 'info
                               :ttl 0.2 :session session)
           (should (eq 'alert (plist-get (etaf-island-state session) :mode)))
           (etaf-island-test--wait
            (lambda () (eq 'compact (plist-get (etaf-island-state session) :mode))))
           (etaf-island-clear-notifications session)
           (should (null (etaf-notify-list))))
       (when (buffer-live-p buffer)
         (etaf-app-close buffer))))))

(ert-deftest etaf-island-mode-connects-protocol-and-demand-driven-meter ()
  "`etaf-island-mode' hooks `etaf-notify-functions' and ticks only when a live meter runs."
  (etaf-island-test--clean
   (let* ((session (etaf-island-create :mode 'compact :appearance 'dark))
          (buffer (etaf-island-open session))
          (runtime (etaf-runtime-for-buffer buffer))
          (samples 0))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (etaf-runtime-refit runtime 960 28)
           (etaf-island-mode 1)
           (should (memq 'etaf-island--on-protocol-notify etaf-notify-functions))
           ;; Active activity with `:meter' drives demand tick.
           (etaf-activity-publish
            'meter-test
            (list :app 'etaf-ncm :kind 'media :state 'active
                  :title "频谱实测"
                  :meter (lambda (n)
                           (cl-incf samples)
                           (make-list n 0.7))))
           (etaf-island-test--wait (lambda () (>= samples 2)))
           (etaf-island-mode -1)
           (should-not (memq 'etaf-island--on-protocol-notify etaf-notify-functions))
           (etaf-app-close buffer)
           (should-not (buffer-live-p buffer)))
       (when (buffer-live-p buffer)
         (etaf-app-close buffer))))))

(provide 'etaf-island-tests)
;;; etaf-island-tests.el ends here
