;;; etaf-island-app.el --- Floating capsule, full keyboard nav and global mode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Connects `etaf-island' sessions to two hosts: a headerless, non-resizable,
;; non-scrollable, draggable top-center `etaf-posframe' capsule that reshapes
;; in place without frame destruction (`etaf-island-show' / `etaf-island-focus'
;; / `etaf-island-toggle'), and a standalone buffer (`etaf-island-open')
;; preserving Emacs's mode-line, plus global `etaf-island-mode' listening to
;; `etaf-notify-functions' and `etaf-activity-change-functions'.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-island-theme)
(require 'etaf-island-sensors)
(require 'etaf-island-model)
(require 'etaf-island-views)

(declare-function etaf-posframe-show "etaf-posframe" (view &rest options))
(declare-function etaf-posframe-hide "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-live-p "etaf-posframe" (panel))
(declare-function etaf-posframe-refresh "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-reshape "etaf-posframe" (panel &rest options))
(declare-function etaf-posframe-focus "etaf-posframe" (panel))
(declare-function etaf-posframe-unfocus "etaf-posframe" (panel))
(declare-function etaf-posframe-panel-frame "etaf-posframe" (panel))

(defconst etaf-island--buffer-name "*ETAF Island*"
  "Buffer name used by `etaf-island-open'.")

(defvar etaf-island--default-session nil
  "Shared default session used by interactive commands and `etaf-island-mode'.")

(defvar etaf-island--panel nil
  "Active `etaf-posframe' panel handle, or nil when hidden.")

(defvar etaf-island--panel-session nil
  "Session currently mounted in `etaf-island--panel'.")

(defvar etaf-island--panel-mode nil
  "Last mode geometry synced onto `etaf-island--panel'.")

(defvar etaf-island--panel-dims nil
  "Last `(WIDTH . HEIGHT)' synced onto `etaf-island--panel'.")

(defvar etaf-island--panel-appearance nil
  "Last appearance polarity synced onto `etaf-island--panel'.")

(defvar etaf-island--panel-anchor nil
  "Last custom anchor synced onto `etaf-island--panel'.")

(defvar etaf-island--panel-scope nil
  "Reactive Scope syncing `etaf-island--panel' geometry when state changes.")

(defun etaf-island--ensure-session (&optional session)
  "Return SESSION or initialize and return `etaf-island--default-session'."
  (or session
      etaf-island--default-session
      (setq etaf-island--default-session
            (etaf-island-create :appearance 'auto))))

(defun etaf-island--collapse-floating (session)
  "Collapse SESSION to compact mode and restore host focus if floating."
  (when (and session
             (not (eq (etaf-untracked (etaf-value (plist-get session :mode))) 'compact)))
    (etaf-island-set-mode session 'compact))
  (when (and etaf-island--panel
             (eq etaf-island--panel-session session)
             (fboundp 'etaf-posframe-unfocus))
    (etaf-posframe-unfocus etaf-island--panel)))

;;;; Full Keyboard Navigation & Action Dispatch

(defun etaf-island--selected-activity (session)
  "Return the currently selected visible activity in SESSION, or nil."
  (let* ((part (etaf-island--partition-activities (etaf-activity-list)))
         (ordered (plist-get part :ordered))
         (idx (etaf-island--clamp-index
               (etaf-untracked (etaf-value (plist-get session :selection)))
               (length ordered))))
    (nth idx ordered)))

(defun etaf-island--selected-note (session)
  "Return the currently selected visible notification in SESSION, or nil."
  (let* ((shown (etaf-island--visible-notes (etaf-notify-list)))
         (idx (etaf-island--clamp-index
               (etaf-untracked (etaf-value (plist-get session :selection)))
               (length shown))))
    (nth idx shown)))

(defun etaf-island--activate-selected (session &optional after-open)
  "Execute the primary action of SESSION's currently selected item."
  (let ((mode (etaf-untracked (etaf-value (plist-get session :mode))))
        (tab (etaf-untracked (etaf-value (plist-get session :tab)))))
    (pcase mode
      ('compact
       (etaf-island-set-mode session 'expanded))
      ('alert
       (let* ((alert (etaf-untracked (etaf-value (plist-get session :active-alert))))
              (actions (and alert (plist-get alert :actions)))
              (primary (or (cl-find-if (lambda (a) (plist-get a :primary)) actions)
                           (car actions))))
         (if (and primary (functionp (plist-get primary :fn)))
             (progn
               (when (functionp after-open) (funcall after-open))
               (etaf-island--safe-call (plist-get primary :fn))
               (etaf-island-dismiss-notification session (plist-get alert :id)))
           (etaf-island-select-tab session 'events))))
      (_
       (pcase tab
         ('events
          (when-let* ((note (etaf-island--selected-note session)))
            (let* ((nid (plist-get note :id))
                   (actions (plist-get note :actions))
                   (primary (or (cl-find-if (lambda (a) (plist-get a :primary)) actions)
                                (car actions))))
              (when (and primary (functionp (plist-get primary :fn)))
                (when (functionp after-open) (funcall after-open))
                (etaf-island--safe-call (plist-get primary :fn)))
              (etaf-island-dismiss-notification session nid))))
         ('quick
          (let* ((items (etaf-island--quick-items session))
                 (idx (etaf-island--clamp-index
                       (etaf-untracked (etaf-value (plist-get session :selection)))
                       (length items)))
                 (item (nth idx items)))
            (pcase (plist-get item :kind)
              ('launcher
               (etaf-island--launch-app (plist-get item :entry) after-open))
              ('sensor
               (etaf-island--toggle-sensor session (plist-get item :id))))))
         (_
          (if-let* ((act (etaf-island--selected-activity session)))
              (let* ((actions (plist-get act :actions))
                     (primary (or (cl-find-if (lambda (a) (plist-get a :primary)) actions)
                                  (cl-find 'toggle actions :key (lambda (a) (plist-get a :id)))
                                  (car actions)))
                     (open-fn (plist-get act :open)))
                (cond
                 ((and primary (functionp (plist-get primary :fn)))
                  (etaf-island--safe-call (plist-get primary :fn)))
                 ((functionp open-fn)
                  (when (functionp after-open) (funcall after-open))
                  (etaf-island--safe-call open-fn))))
            (etaf-island-select-tab session 'quick))))))))

(defun etaf-island--open-selected (session &optional after-open)
  "Open the source application of the selected (or primary) activity."
  (let* ((sel (etaf-island--selected-activity session))
         (sel-open (and sel (plist-get sel :open))))
    (cond
     ((functionp sel-open)
      (when (functionp after-open) (funcall after-open))
      (etaf-island--safe-call sel-open))
     (t
      (when (functionp after-open) (funcall after-open))
      (etaf-island--invoke-primary-kind nil 'open)))))

(defun etaf-island--space-command (session &optional collapse-fn)
  "Handle SPC: expand from compact, toggle active media/timer, or collapse."
  (let ((mode (etaf-untracked (etaf-value (plist-get session :mode))))
        (tab (etaf-untracked (etaf-value (plist-get session :tab)))))
    (cond
     ((eq mode 'compact)
      (etaf-island-set-mode session 'expanded))
     ((eq mode 'alert)
      (etaf-island-select-tab session 'events))
     ((eq tab 'activities)
      (let* ((sel (etaf-island--selected-activity session))
             (sel-toggle (and sel (etaf-island--activity-has-action-p sel 'toggle))))
        (cond
         (sel-toggle
          (etaf-activity-invoke (plist-get sel :id) 'toggle))
         ((or (cl-some (lambda (a) (etaf-island--activity-has-action-p a 'toggle))
                       (etaf-activity-list 'media))
              (cl-some (lambda (a) (etaf-island--activity-has-action-p a 'toggle))
                       (etaf-activity-list 'timer)))
          (or (etaf-island--invoke-primary-kind 'media 'toggle)
              (etaf-island--invoke-primary-kind 'timer 'toggle)))
         (t
          (if (functionp collapse-fn)
              (funcall collapse-fn)
            (etaf-island-set-mode session 'compact))))))
     (t
      (if (functionp collapse-fn)
          (funcall collapse-fn)
        (etaf-island-set-mode session 'compact))))))

(defun etaf-island--step-selection (session delta)
  "Move SESSION's keyboard selection by DELTA, expanding first when compact."
  (let ((mode (etaf-untracked (etaf-value (plist-get session :mode))))
        (tab (etaf-untracked (etaf-value (plist-get session :tab)))))
    (if (eq mode 'expanded)
        (etaf-island--move-selection
         session delta (etaf-island--tab-item-count session tab))
      (etaf-island-set-mode session 'expanded))))

(defun etaf-island--direction-handler (session)
  "Return an ETAF `:on-direction' handler for SESSION."
  (lambda (dir)
    (pcase dir
      ('down  (etaf-island--step-selection session 1) 'handled)
      ('up    (etaf-island--step-selection session -1) 'handled)
      ('left  (etaf-island--cycle-tab session -1) 'handled)
      ('right (etaf-island--cycle-tab session 1) 'handled)
      (_      'release))))

(defun etaf-island--keys (session &optional close-fn collapse-fn)
  "Return scoped root `:keys' bindings for SESSION.
Arrow keys, Tab and Escape are handled natively by ETAF `:on-direction' and
`:on-dismiss'; `h/j/k/l' are bound here unless `etaf-direction-scheme' is `vim'."
  (let ((collapse (or collapse-fn
                      (lambda () (etaf-island-set-mode session 'compact))))
        (vim-p (eq (bound-and-true-p etaf-direction-scheme) 'vim)))
    (append
     (unless vim-p
       (list
        (list "j" (lambda () (etaf-island--step-selection session 1)) "下一项")
        (list "k" (lambda () (etaf-island--step-selection session -1)) "上一项")
        (list "h" (lambda () (etaf-island--cycle-tab session -1)) "上一页签")
        (list "l" (lambda () (etaf-island--cycle-tab session 1)) "下一页签")))
     (list
      (list "1" (lambda () (etaf-island-select-tab session 'activities)) "实时活动页")
      (list "2" (lambda () (etaf-island-select-tab session 'events)) "通知流页")
      (list "3" (lambda () (etaf-island-select-tab session 'quick)) "快捷入口页")
      (list "RET" (lambda () (etaf-island--activate-selected session collapse)) "执行主动作")
      (list "<return>" (lambda () (etaf-island--activate-selected session collapse)) "执行主动作")
      (list "SPC" (lambda () (etaf-island--space-command session collapse)) "暂停/继续或展开收起")
      (list "[" (lambda () (etaf-island--invoke-primary-kind 'media 'prev)) "上一首")
      (list "]" (lambda () (etaf-island--invoke-primary-kind 'media 'next)) "下一首")
      (list "p" (lambda () (etaf-island--invoke-primary-kind 'media 'prev)) "上一首")
      (list "n" (lambda () (etaf-island--invoke-primary-kind 'media 'next)) "下一首")
      (list "o" (lambda () (etaf-island--open-selected session collapse)) "打开所属应用")
      (list "d" (lambda ()
                  (let ((mode (etaf-untracked (etaf-value (plist-get session :mode))))
                        (tab (etaf-untracked (etaf-value (plist-get session :tab)))))
                    (if (and (eq mode 'expanded) (eq tab 'events))
                        (when-let* ((note (etaf-island--selected-note session)))
                          (etaf-island-dismiss-notification session (plist-get note :id)))
                      (etaf-island-dismiss-notification session))))
            "忽略通知")
      (list "c" (lambda () (etaf-island-clear-notifications session)) "清空全部事件")
      (list "0" (lambda () (etaf-island-reset-position session)) "浮窗居中复位")
      (list "t" (lambda () (etaf-island-toggle-appearance session)) "切换暗/亮色"))
     (when close-fn
       (list (list "q" close-fn "隐藏或关闭"))))))

;;;###autoload
(defun etaf-island-view (&optional session interactive standalone)
  "Return the ETAF View for SESSION, defaulting to the shared session.
When INTERACTIVE is non-nil (default t), install scoped keyboard shortcuts.
When STANDALONE is non-nil, center the capsule inside an app canvas."
  (let* ((sess (etaf-island--ensure-session session))
         (use-keys (if (null interactive) nil t))
         (collapse-fn (if standalone
                          (lambda () (etaf-island-set-mode sess 'compact))
                        (lambda () (etaf-island--collapse-floating sess))))
         (close-fn (if standalone
                       (lambda () (etaf-app-close (current-buffer)))
                     #'etaf-island-hide)))
    (etaf-view
     (etaf-island--root
      :session sess
      :standalone standalone
      :on-dismiss collapse-fn
      :on-direction (when use-keys (etaf-island--direction-handler sess))
      :on-open-after (unless standalone collapse-fn)
      :keys (when use-keys
              (etaf-island--keys sess close-fn collapse-fn))))))

;;;###autoload
(defun etaf-island-open (&optional session)
  "Open ETAF Island in its own buffer preserving Emacs's mode-line.
Returns the mounted buffer."
  (interactive)
  (let* ((sess (etaf-island--ensure-session session))
         (view (etaf-island-view sess t t))
         (bg (lambda ()
               (etaf-value etaf-island--theme-epoch)
               (plist-get (etaf-island--tokens
                           (etaf-value (plist-get sess :appearance)))
                          :island-bg)))
         (fg (lambda ()
               (etaf-value etaf-island--theme-epoch)
               (plist-get (etaf-island--tokens
                           (etaf-value (plist-get sess :appearance)))
                          :island-fg))))
    (etaf-app-open etaf-island--buffer-name view
                   :state sess
                   :meta '(:app etaf-island :kind tool :title "ETAF 灵动岛")
                   :background bg
                   :foreground fg
                   :cursor nil
                   :mode-line t
                   :display (called-interactively-p 'interactive))))

;;;; Floating Posframe Host (Single Persistent Frame, In-Place Reshape & Drag)

(defun etaf-island--panel-dimensions (mode)
  "Return `(WIDTH . HEIGHT)' budget for floating capsule MODE."
  (let* ((acts (etaf-activity-list))
         (notes (etaf-notify-list))
         (has-live (or (cl-some (lambda (a)
                                  (let ((k (plist-get a :kind))
                                        (s (plist-get a :state)))
                                    (or (and (memq k '(timer task)) (eq s 'active))
                                        (and (eq k 'media) (memq s '(active paused)))
                                        (eq k 'inbox))))
                                acts)
                       notes))
         (has-sched (cl-find 'schedule acts :key (lambda (a) (plist-get a :kind)))))
    (pcase mode
      ('compact (cons (cond (has-live 72)
                            (has-sched 44)
                            (t 28))
                      1))
      ('alert   (cons 70 14))
      (_        (cons 82 42)))))

(defun etaf-island--panel-at (sess)
  "Return `:at' placement for SESS (top-center, or user-dragged center anchor)."
  (let ((custom (etaf-untracked (etaf-value (plist-get sess :custom-anchor)))))
    (if (and (consp custom) (numberp (car custom)) (numberp (cdr custom)))
        (let ((cx (car custom))
              (top-y (cdr custom)))
          (lambda (info)
            (let* ((pw (or (plist-get info :parent-frame-width) 800))
                   (ph (or (plist-get info :parent-frame-height) 600))
                   (fw (or (plist-get info :posframe-width) 200))
                   (fh (or (plist-get info :posframe-height) 20))
                   (x (max 0 (min (round (- cx (/ fw 2.0))) (max 0 (- pw fw)))))
                   (y (max 0 (min (round top-y) (max 0 (- ph fh))))))
              (cons x y))))
      '(frame-top-center 1 0))))

(defun etaf-island--on-panel-dragged (sess x y panel)
  "Record PANEL's new horizontal center and top Y into SESS after user drag."
  (when-let* ((frame (and (fboundp 'etaf-posframe-panel-frame)
                          (etaf-posframe-panel-frame panel))))
    (let ((cx (+ x (/ (float (frame-pixel-width frame)) 2.0))))
      (setq etaf-island--panel-anchor (cons cx y))
      (setf (etaf-value (plist-get sess :custom-anchor)) (cons cx y)))))

(defun etaf-island--stop-panel-scope ()
  "Dispose any active reactive Scope watching floating panel geometry."
  (when etaf-island--panel-scope
    (ignore-errors (etaf-scope-stop etaf-island--panel-scope))
    (setq etaf-island--panel-scope nil)))

(defun etaf-island--sync-panel (sess &optional focus-action)
  "Show or reshape in place the single floating top-center capsule for SESS.
FOCUS-ACTION may be `focus', `unfocus', or nil (preserve focus discipline)."
  (let* ((mode (etaf-untracked (etaf-value (plist-get sess :mode))))
         (dims (etaf-island--panel-dimensions mode))
         (app (etaf-untracked (etaf-value (plist-get sess :appearance))))
         (anchor (etaf-untracked (etaf-value (plist-get sess :custom-anchor))))
         (at (etaf-island--panel-at sess))
         (tok (etaf-island--tokens app))
         (surface (plist-get tok :island-surface))
         (panel-theme (append (list :ui-bg surface
                                    :ui-surface surface
                                    :ui-panel-bg surface
                                    :ui-panel-border (plist-get tok :island-border)
                                    :bg surface
                                    :surface surface)
                              tok))
         (prev-mode etaf-island--panel-mode)
         (live (and etaf-island--panel
                    (eq etaf-island--panel-session sess)
                    (fboundp 'etaf-posframe-live-p)
                    (etaf-posframe-live-p etaf-island--panel))))
    (setq etaf-island--panel-session sess
          etaf-island--panel-mode mode
          etaf-island--panel-dims dims
          etaf-island--panel-appearance app
          etaf-island--panel-anchor anchor)
    (if (and live (fboundp 'etaf-posframe-reshape))
        (let ((focus-opts
               (cond
                ((eq focus-action 'focus) (list :focus-on-open t))
                ((eq focus-action 'unfocus) (list :focus-on-open nil))
                ((and (eq mode 'expanded) (not (eq prev-mode 'expanded)))
                 (list :focus-on-open t))
                ((and (not (eq mode 'expanded)) (eq prev-mode 'expanded))
                 (list :focus-on-open nil))
                (t nil))))
          (apply #'etaf-posframe-reshape
                 etaf-island--panel
                 :width (car dims)
                 :height (cdr dims)
                 :at at
                 :border (list :width 1 :color (plist-get tok :island-border))
                 :theme panel-theme
                 focus-opts))
      (let ((view (etaf-island-view sess t nil)))
        (setq etaf-island--panel
              (etaf-posframe-show
               view
               :key 'etaf-island
               :at at
               :width (car dims)
               :height (cdr dims)
               :resizable nil
               :draggable t
               :scrollable nil
               :focusable t
               :focus-on-open (or (eq focus-action 'focus) (eq mode 'expanded))
               :on-escape (lambda (_p) (etaf-island--collapse-floating sess))
               :on-blur (lambda (_p)
                          (when (eq (etaf-untracked (etaf-value (plist-get sess :mode)))
                                    'expanded)
                            (etaf-island-set-mode sess 'compact)))
               :on-move (lambda (x y p) (etaf-island--on-panel-dragged sess x y p))
               :border (list :width 1 :color (plist-get tok :island-border))
               :theme panel-theme))))
    etaf-island--panel))

(defun etaf-island--watch-panel (sess)
  "Watch SESS mode, anchor, theme and auto-hide to reshape the capsule in place."
  (etaf-island--stop-panel-scope)
  (let ((scope (etaf-effect-scope :detached t :name 'island-panel)))
    (setq etaf-island--panel-scope scope)
    (etaf-scope-run
     scope
     (lambda ()
       (etaf-watch-effect
        (lambda ()
          (let* ((mode (etaf-value (plist-get sess :mode)))
                 (tab (etaf-value (plist-get sess :tab)))
                 (app (etaf-value (plist-get sess :appearance)))
                 (anchor (etaf-value (plist-get sess :custom-anchor)))
                 (acts (etaf-value (etaf-activity-ref)))
                 (notes (etaf-value (etaf-notify-ref)))
                 (auto-hide (etaf-value (plist-get sess :auto-hide-idle)))
                 (_epoch (etaf-value etaf-island--theme-epoch))
                 (dims (etaf-island--panel-dimensions mode)))
            (ignore tab)
            (when (and etaf-island--panel
                       (fboundp 'etaf-posframe-live-p)
                       (etaf-posframe-live-p etaf-island--panel))
              (cond
               ((and auto-hide (eq mode 'compact) (null acts) (null notes))
                (run-at-time 0 nil #'etaf-island-hide))
               ((or (not (eq mode etaf-island--panel-mode))
                    (not (equal dims etaf-island--panel-dims))
                    (not (eq app etaf-island--panel-appearance))
                    (not (equal anchor etaf-island--panel-anchor)))
                (run-at-time 0 nil
                             (lambda ()
                               (when (and etaf-island--panel
                                          (fboundp 'etaf-posframe-live-p)
                                          (etaf-posframe-live-p etaf-island--panel))
                                 (let* ((cmode (etaf-untracked (etaf-value (plist-get sess :mode))))
                                        (cdims (etaf-island--panel-dimensions cmode))
                                        (capp (etaf-untracked (etaf-value (plist-get sess :appearance))))
                                        (canchor (etaf-untracked (etaf-value (plist-get sess :custom-anchor)))))
                                   (if (or (not (eq cmode etaf-island--panel-mode))
                                           (not (equal cdims etaf-island--panel-dims))
                                           (not (eq capp etaf-island--panel-appearance))
                                           (not (equal canchor etaf-island--panel-anchor)))
                                       (etaf-island--sync-panel sess)
                                     (etaf-posframe-refresh etaf-island--panel)))))))
               (t
                (run-at-time 0 nil
                             (lambda ()
                               (when (and etaf-island--panel
                                          (fboundp 'etaf-posframe-live-p)
                                          (etaf-posframe-live-p etaf-island--panel))
                                 (etaf-posframe-refresh etaf-island--panel))))))))))))))

;;;###autoload
(defun etaf-island-show (&optional session)
  "Show ETAF Island in a headerless draggable top-center `etaf-posframe' capsule.
Signals `etaf-island-error' when `etaf-posframe' is unavailable."
  (interactive)
  (unless (require 'etaf-posframe nil t)
    (signal 'etaf-island-error
            (list "etaf-posframe is required for floating island panels")))
  (let ((sess (etaf-island--ensure-session session)))
    (etaf-island--sync-panel sess)
    (etaf-island--watch-panel sess)
    etaf-island--panel))

;;;###autoload
(defun etaf-island-focus (&optional session)
  "Smart keyboard summon for ETAF Island.
If hidden or compact, expands and focuses the floating island for full
keyboard operation.  If already expanded, collapses back to the compact
capsule and returns focus to the editor."
  (interactive)
  (unless (require 'etaf-posframe nil t)
    (signal 'etaf-island-error
            (list "etaf-posframe is required for floating island panels")))
  (let* ((sess (etaf-island--ensure-session session))
         (live (and etaf-island--panel
                    (fboundp 'etaf-posframe-live-p)
                    (etaf-posframe-live-p etaf-island--panel)))
         (cur-mode (etaf-untracked (etaf-value (plist-get sess :mode)))))
    (if (and live (eq cur-mode 'expanded))
        (progn
          (etaf-island-set-mode sess 'compact)
          (etaf-island--sync-panel sess 'unfocus)
          nil)
      (etaf-island-set-mode sess 'expanded)
      (etaf-island--sync-panel sess 'focus)
      (etaf-island--watch-panel sess)
      etaf-island--panel)))

;;;###autoload
(defun etaf-island-hide ()
  "Hide the active floating ETAF Island panel, if any."
  (interactive)
  (etaf-island--stop-panel-scope)
  (when (and etaf-island--panel (fboundp 'etaf-posframe-hide))
    (prog1 (etaf-posframe-hide etaf-island--panel)
      (setq etaf-island--panel nil
            etaf-island--panel-mode nil
            etaf-island--panel-dims nil
            etaf-island--panel-appearance nil
            etaf-island--panel-anchor nil
            etaf-island--panel-session nil))))

;;;###autoload
(defun etaf-island-toggle (&optional session)
  "Toggle the floating ETAF Island panel on or off."
  (interactive)
  (if (and etaf-island--panel
           (fboundp 'etaf-posframe-live-p)
           (etaf-posframe-live-p etaf-island--panel))
      (progn (etaf-island-hide) nil)
    (etaf-island-show session)))

;;;###autoload
(cl-defun etaf-island-notify (title &key app detail (variant 'info) action-label
                                    on-action (ttl 5.0) group actions session)
  "Publish notification TITLE via `etaf-notify' and pulse SESSION.
Supports either ACTIONS list or single ACTION-LABEL/ON-ACTION convenience pair."
  (let* ((sess (etaf-island--ensure-session session))
         (merged-actions
          (or actions
              (when (and action-label on-action)
                (list (list :id 'primary :label action-label :primary t
                            :fn on-action)))))
         (entry (etaf-notify title :app app :detail detail :variant variant
                             :ttl ttl :group group :actions merged-actions)))
    (etaf-island--pulse-alert sess entry)
    entry))

;;;; Global Mode: Connect ETAF Protocol & Native Sensors

(defun etaf-island--on-protocol-notify (entry)
  "Pulse the default Island session when `etaf-notify' publishes ENTRY."
  (let ((sess (etaf-island--ensure-session)))
    (etaf-island--pulse-alert sess entry)
    (when (and (display-graphic-p)
               (not (and etaf-island--panel
                         (fboundp 'etaf-posframe-live-p)
                         (etaf-posframe-live-p etaf-island--panel)))
               (require 'etaf-posframe nil t))
      (ignore-errors (etaf-island-show sess)))))

(defun etaf-island--on-protocol-activity (event _id _entry)
  "Auto-open the floating capsule when an activity arrives while auto-hidden."
  (when (and (eq event 'publish)
             (display-graphic-p)
             (not (and etaf-island--panel
                       (fboundp 'etaf-posframe-live-p)
                       (etaf-posframe-live-p etaf-island--panel)))
             (require 'etaf-posframe nil t))
    (ignore-errors (etaf-island-show))))

(defvar etaf-island-mode)

(defun etaf-island--startup-show ()
  "Show the floating ETAF Island capsule once Emacs finishes frame setup."
  (remove-hook 'window-setup-hook #'etaf-island--startup-show)
  (when (and etaf-island-mode
             (display-graphic-p)
             (or (not etaf-island-auto-hide-idle)
                 (etaf-activity-list)
                 (etaf-notify-list))
             (require 'etaf-posframe nil t))
    (ignore-errors (etaf-island-show))))

;;;###autoload
(define-minor-mode etaf-island-mode
  "Global minor mode turning ETAF Island into the active protocol shell.
Installs native Emacs sensors (`compilation' and `org-clock'), subscribes to
`etaf-notify-functions' and `etaf-activity-change-functions', and displays the
floating top-center capsule on graphical displays unless idle-hidden."
  :global t
  :group 'etaf-island
  (if etaf-island-mode
      (progn
        (etaf-island--ensure-session)
        (add-hook 'etaf-notify-functions #'etaf-island--on-protocol-notify)
        (add-hook 'etaf-activity-change-functions #'etaf-island--on-protocol-activity)
        (etaf-island--sensors-enable)
        (when (and (display-graphic-p)
                   (or (not etaf-island-auto-hide-idle)
                       (etaf-activity-list)
                       (etaf-notify-list))
                   (require 'etaf-posframe nil t))
          (if after-init-time
              (ignore-errors (etaf-island-show))
            (add-hook 'window-setup-hook #'etaf-island--startup-show))))
    (remove-hook 'window-setup-hook #'etaf-island--startup-show)
    (remove-hook 'etaf-notify-functions #'etaf-island--on-protocol-notify)
    (remove-hook 'etaf-activity-change-functions #'etaf-island--on-protocol-activity)
    (etaf-island--sensors-disable)
    (etaf-island-hide)))

(provide 'etaf-island-app)
;;; etaf-island-app.el ends here
