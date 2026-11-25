;;; etaf-translate-ui.el --- Floating control panel and quick-translate popup -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Minimalist interactive UI built on `etaf' and `etaf-ui':
;; 1. `etaf-translate-panel': slim 6-row top-right floating control panel
;;    (toggle/refresh, progress, mode, 3 bilingual styles, languages + engine,
;;    optional site auto/never memory).
;; 2. `etaf-translate-at-point': pure-translation floating popup usable in any
;;    ETAF or ordinary Emacs buffer (translates active region or word at point,
;;    never repeats original text, auto-fits height up to 60% of frame height,
;;    and scrolls cleanly for long selections).
;;
;; Prefers `etaf-posframe' on graphical frames with native `:theme ''auto'
;; following, and gracefully falls back to a native ETAF side window otherwise.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)
(require 'etaf-translate-core)
(require 'etaf-translate-cache)
(require 'etaf-translate-rules)
(require 'etaf-translate-engine)
(require 'etaf-translate-render)
(require 'etaf-translate-session)

(declare-function etaf-posframe-show "etaf-posframe" (view &rest options))
(declare-function etaf-posframe-hide "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-live-p "etaf-posframe" (panel))
(declare-function etaf-posframe-refresh "etaf-posframe" (&optional panel))

;;;; Customization and shared UI state

(defcustom etaf-translate-use-posframe t
  "When non-nil, show panels and popups via `etaf-posframe' when available."
  :type 'boolean
  :group 'etaf-translate)

(defconst etaf-translate--panel-buffer-name " *ETAF Translate Panel*"
  "Fallback buffer name when `etaf-posframe' is unavailable.")

(defconst etaf-translate--popup-buffer-name " *ETAF Translate Popup*"
  "Fallback buffer name for quick-translate popup.")

(defvar etaf-translate--active-panel nil
  "Currently open control panel descriptor plist, or nil.")

(defvar etaf-translate--active-popup nil
  "Currently open quick-translate popup descriptor plist, or nil.")

(defconst etaf-translate--lang-choices
  '(("auto" . "自动")
    ("zh-CN" . "简体中文")
    ("zh-TW" . "繁體中文")
    ("en" . "英语")
    ("ja" . "日语")
    ("ko" . "韩语")
    ("fr" . "法语")
    ("de" . "德语")
    ("ru" . "俄语"))
  "Concise display labels for common language codes.")

(defun etaf-translate--ui-posframe-ready-p ()
  "Return non-nil when `etaf-posframe' can display floating child frames."
  (and etaf-translate-use-posframe
       (display-graphic-p)
       (require 'etaf-posframe nil t)
       (fboundp 'etaf-posframe-show)))

(defun etaf-translate--panel-for-runtime-p (runtime)
  "Return non-nil when the currently open control panel targets RUNTIME."
  (and etaf-translate--active-panel
       (eq (plist-get etaf-translate--active-panel :runtime) runtime)
       (etaf-translate--panel-live-p etaf-translate--active-panel)))

(defun etaf-translate--lang-label (code)
  "Return concise display label for language CODE."
  (let ((key (if (symbolp code) (symbol-name code) (or code "auto"))))
    (or (cdr (assoc key etaf-translate--lang-choices)) key)))

(defun etaf-translate--engine-short-label (engine)
  "Return a concise display label for ENGINE fitting compact controls."
  (let* ((full (etaf-translate--engine-label engine))
         (short (if (string= full "OpenAI Compatible") "OpenAI" full)))
    (truncate-string-to-width short 14 nil nil "…")))

(defun etaf-translate--site-rule-status (site)
  "Return `auto', `never' or nil for SITE's persisted preference."
  (when site
    (etaf-translate--ensure-state-loaded)
    (let ((entry (cdr (assoc (downcase site) etaf-translate--persisted-site-rules))))
      (cond
       ((plist-get entry :never-translate) 'never)
       ((plist-get entry :auto-translate) 'auto)
       (t nil)))))

(etaf-define-component etaf-translate--themed-root (&key theme render)
  "Root wrapper component providing THEME tokens to fallback panel subtrees."
  :setup (progn (etaf-theme-provide theme) nil)
  :render (etaf-view (expr (funcall render))))

(etaf-define-component etaf-translate--panel-component
    (&key target-rt status-ref sync-fn)
  "Reactive control panel component that tracks STATUS-REF inside render.
Mounted directly inside `etaf-posframe--surface' so it inherits live
`:theme ''auto' tokens while re-rendering whenever STATUS-REF changes."
  :render
  (etaf-view
   (expr (etaf-translate--panel-content-view target-rt status-ref sync-fn))))

(etaf-define-component etaf-translate--popup-component
    (&key state-ref engine-ref max-body-rows on-retranslate)
  "Reactive quick-translate popup component tracking STATE-REF and ENGINE-REF."
  :render
  (etaf-view
   (expr (etaf-translate--popup-content-view
          state-ref engine-ref max-body-rows on-retranslate))))

;;;; Control Panel (etaf-translate-panel)

(defun etaf-translate--panel-live-p (desc)
  "Return non-nil when control panel descriptor DESC is still visible."
  (when desc
    (let ((pf (plist-get desc :posframe))
          (buf (plist-get desc :buffer)))
      (or (and pf (fboundp 'etaf-posframe-live-p) (etaf-posframe-live-p pf))
          (and buf (buffer-live-p buf))))))

(defun etaf-translate--panel-close-current ()
  "Close the currently open control panel if any."
  (when-let* ((desc etaf-translate--active-panel))
    (setq etaf-translate--active-panel nil)
    (when-let* ((listener (plist-get desc :listener)))
      (remove-hook 'etaf-translate-status-change-functions listener))
    (when-let* ((watcher (plist-get desc :window-watcher)))
      (remove-hook 'window-buffer-change-functions watcher)
      (remove-hook 'window-selection-change-functions watcher))
    (when-let* ((theme-hook (plist-get desc :theme-hook)))
      (when (boundp 'enable-theme-functions)
        (remove-hook 'enable-theme-functions theme-hook))
      (when (boundp 'disable-theme-functions)
        (remove-hook 'disable-theme-functions theme-hook)))
    (let ((posframe (plist-get desc :posframe))
          (buf (plist-get desc :buffer)))
      (when (and posframe (fboundp 'etaf-posframe-live-p)
                 (etaf-posframe-live-p posframe))
        (ignore-errors (etaf-posframe-hide posframe)))
      (when (and buf (buffer-live-p buf))
        (when-let* ((win (get-buffer-window buf t)))
          (ignore-errors (delete-window win)))
        (when-let* ((rt (etaf-runtime-for-buffer buf)))
          (ignore-errors (etaf-unmount rt)))
        (ignore-errors (kill-buffer buf))))))

(defun etaf-translate--panel-make-window-watcher (target-rt)
  "Return a hook function that auto-closes the panel upon switching away."
  (let ((target-buf (and target-rt (etaf-runtime-buffer target-rt))))
    (lambda (&rest _args)
      (when-let* ((desc etaf-translate--active-panel))
        (when (eq (plist-get desc :runtime) target-rt)
          (unless (or (active-minibuffer-window)
                      (frame-parent (selected-frame)))
            (let ((cur-buf (window-buffer (selected-window)))
                  (panel-buf (plist-get desc :buffer)))
              (unless (or (eq cur-buf target-buf)
                          (and panel-buf (eq cur-buf panel-buf)))
                (etaf-translate--panel-close-current)))))))))

(defun etaf-translate-panel-close ()
  "Close the open `etaf-translate' control panel if visible."
  (etaf-translate--panel-close-current))

(defun etaf-translate--panel-pick-language (target-rt which sync-fn)
  "Prompt for WHICH (`source' or `target') language on TARGET-RT and sync."
  (let* ((st (etaf-translate-status target-rt))
         (choices (if (eq which 'source)
                      etaf-translate--lang-choices
                    (cdr etaf-translate--lang-choices)))
         (picked (completing-read
                  (if (eq which 'source) "源语言: " "目标语言: ")
                  (mapcar #'car choices) nil nil))
         (src (if (eq which 'source)
                  (if (string= picked "auto") 'auto picked)
                (plist-get st :source-lang)))
         (tgt (if (eq which 'target) picked (plist-get st :target-lang))))
    (when (and (stringp picked) (not (string-empty-p picked)))
      (etaf-translate--set-pref
       (if (eq which 'source) :source-lang :target-lang)
       (if (eq which 'source) src tgt))
      (when (plist-get st :active)
        (etaf-translate-set-languages src tgt target-rt))
      (funcall sync-fn))))

(defun etaf-translate--panel-pick-engine (target-rt sync-fn)
  "Prompt for translation engine or named profile on TARGET-RT and run SYNC-FN."
  (let* ((st (etaf-translate-status target-rt))
         (choices (etaf-translate--engine-choices))
         (picked (intern (completing-read
                          "翻译引擎 / Profile: "
                          (mapcar (lambda (c) (symbol-name (car c))) choices)
                          nil t))))
    (etaf-translate--set-pref :engine picked)
    (when (plist-get st :active)
      (etaf-translate-set-engine picked target-rt))
    (funcall sync-fn)))

(defun etaf-translate--panel-content-view (target-rt status-ref sync-fn)
  "Return the slim 6-row theme-token-driven View for `etaf-translate-panel'."
  (let* ((st (etaf-value status-ref))
         (active (plist-get st :active))
         (site (plist-get st :site))
         (mode (plist-get st :mode))
         (style (plist-get st :style))
         (engine (plist-get st :engine))
         (src (plist-get st :source-lang))
         (tgt (plist-get st :target-lang))
         (total (max 0 (or (plist-get st :total) 0)))
         (tr (max 0 (or (plist-get st :translated) 0)))
         (fail (max 0 (or (plist-get st :failed) 0)))
         (prog-max (max 1 total))
         (prog-val (if active (min tr prog-max) 0))
         (prog-pct (round (/ (* 100.0 prog-val) prog-max)))
         (site-pref (etaf-translate--site-rule-status site))
         (site-label (and site (truncate-string-to-width site 18 nil nil "…")))
         (bg (etaf-theme-token :ui-panel-bg "#1b2226"))
         (fg (etaf-theme-token :ui-panel-fg "#ffffff"))
         (muted (etaf-theme-token :ui-muted-fg "#9fa2a3"))
         (track-bg (etaf-theme-token :ui-accent-soft-bg "#243340"))
         (accent (etaf-theme-token :ui-accent "#6CB6FF"))
         (fill-bg (cond
                   ((> fail 0) (etaf-theme-token :ui-danger-fg "#f87171"))
                   ((and active (>= tr total) (> total 0))
                    (etaf-theme-token :ui-success-fg "#4FB477"))
                   (t accent)))
         (border-top (etaf-theme-token
                      :ui-panel-border "#3f4548"
                      (lambda (c) (list '(px 1) 'solid c))))
         (engine-short (etaf-translate--engine-short-label engine))
         (engine-full (etaf-translate--engine-label engine))
         (do-toggle (lambda ()
                      (when (etaf-runtime-mounted-p target-rt)
                        (etaf-translate-toggle target-rt)
                        (funcall sync-fn))))
         (do-refresh (lambda ()
                       (when (etaf-runtime-mounted-p target-rt)
                         (etaf-translate-refresh target-rt)
                         (funcall sync-fn))))
         (do-para (lambda ()
                    (when (etaf-runtime-mounted-p target-rt)
                      (etaf-translate-paragraph target-rt)
                      (funcall sync-fn))))
         (do-cycle-mode (lambda ()
                          (when (etaf-runtime-mounted-p target-rt)
                            (etaf-translate-mode-cycle target-rt)
                            (funcall sync-fn))))
         (do-cycle-style (lambda ()
                           (when (etaf-runtime-mounted-p target-rt)
                             (let* ((ring etaf-translate--valid-styles)
                                    (tail (cdr (memq style ring)))
                                    (next (or (car tail) (car ring))))
                               (etaf-translate--set-pref :style next)
                               (when active
                                 (etaf-translate-set-style next target-rt))
                               (funcall sync-fn)))))
         (do-close (lambda () (etaf-translate-panel-close))))
    (etaf-node
     'column
     (list :width 'stretch
           :background-color bg
           :color fg
           :padding '((lh 1) (ch 2))
           :item-gap '(lh 0)
           :focus-scope 'modal
           :on-dismiss do-close
           :keys (list (list "t" do-toggle "开关翻译")
                       (list "R" do-refresh "清空缓存重译")
                       (list "p" do-para "翻译光标所在段")
                       (list "m" do-cycle-mode "循环切换模式")
                       (list "s" do-cycle-style "切换双语样式")
                       (list "e" (lambda ()
                                   (etaf-translate--panel-pick-engine target-rt sync-fn))
                             "切换翻译引擎")
                       (list "r" (lambda ()
                                   (etaf-translate-retry-failed target-rt)
                                   (funcall sync-fn))
                             "重试失败项")
                       (list "q" do-close "关闭面板")))
     (delq
      nil
      (list
       ;; Row 1: Title + Status Badge + Close button
       (etaf-node
        'flex
        (list :width 'stretch :justify-content 'space-between :align-items 'center)
        (list
         (etaf-node
          'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
          (list (etaf-node 'text '(:font-weight bold) '("沉浸式翻译"))
                (etaf-view
                 (etaf-badge
                  :text (if active
                            (format "已译 %d/%d" tr total)
                          "待开启")
                  :variant (cond
                            ((> fail 0) 'danger)
                            (active 'info)
                            (t 'neutral))))))
         (etaf-view
          (etaf-button :label "[×]" :variant 'ghost :pointer 'hand
                       :padding '((lh 0) (ch 0)) :color muted
                       :on-press do-close))))
       (etaf-view (etaf-divider :orientation 'horizontal))

       ;; Row 2: Primary CTA + Refresh (+ Retry when failed) + Progress bar
       (etaf-node
        'column (list :width 'stretch :item-gap '(lh 0))
        (list
         (etaf-node
          'flex (list :width 'stretch :justify-content 'space-between
                      :align-items 'center)
          (delq
           nil
           (list
            (etaf-node
             'flex (list :gap '((lh 0) (ch 1)))
             (delq
              nil
              (list
               (etaf-view
                (etaf-button
                 :label (if active "恢复原文 (t)" "翻译当前页 (t)")
                 :variant 'primary :pointer 'hand
                 :on-press do-toggle))
               (etaf-view
                (etaf-button
                 :label (if active "重译 (R)" "单段 (p)")
                 :variant 'secondary :pointer 'hand
                 :on-press (if active do-refresh do-para)))
               (when (> fail 0)
                 (etaf-view
                  (etaf-button
                   :label (format "重试 (%d)" fail)
                   :variant 'secondary :pointer 'hand
                   :on-press (lambda ()
                               (etaf-translate-retry-failed target-rt)
                               (funcall sync-fn))))))))
            (when active
              (etaf-node 'text (list :color muted)
                         (list (format "%d%%" prog-pct)))))))
         (etaf-node
          'box (list :width 'stretch :height '(lh 1) :background-color track-bg)
          (list
           (etaf-node
            'box (list :width (list '% prog-pct) :height '(lh 1)
                       :background-color fill-bg)
            nil)))))
       (etaf-view (etaf-divider :orientation 'horizontal))

       ;; Row 3: Mode segmented
       (etaf-node
        'flex (list :width 'stretch :align-items 'center :gap '((lh 0) (ch 1)))
        (list
         (etaf-node 'text (list :color muted) '("模式"))
         (etaf-view
          (etaf-segmented
           :value mode
           :options '((bilingual-stacked . "双语对照")
                      (replace . "原地替换"))
           :on-change (lambda (m)
                        (etaf-translate--set-pref :mode m)
                        (when active
                          (etaf-translate-set-mode m target-rt))
                        (funcall sync-fn))))))

       ;; Row 4: Style segmented (3 distinct editorial styles)
       (etaf-node
        'flex (list :width 'stretch :align-items 'center :gap '((lh 0) (ch 1)))
        (list
         (etaf-node 'text (list :color muted) '("样式"))
         (etaf-view
          (etaf-segmented
           :value style
           :options '((left-bar . "细线")
                      (muted . "极简")
                      (tinted . "轻底"))
           :on-change (lambda (s)
                        (etaf-translate--set-pref :style s)
                        (when active
                          (etaf-translate-set-style s target-rt))
                        (funcall sync-fn))))))

       ;; Row 5: Language + Engine combined on one compact row
       (etaf-node
        'flex (list :width 'stretch :justify-content 'space-between
                    :align-items 'center :gap '((lh 0) (ch 1)))
        (list
         (etaf-node
          'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
          (list
           (etaf-node 'text (list :color muted) '("语言"))
           (etaf-view
            (etaf-button :label (format "%s ▾" (etaf-translate--lang-label src))
                         :variant 'secondary :pointer 'hand
                         :on-press (lambda ()
                                     (etaf-translate--panel-pick-language
                                      target-rt 'source sync-fn))))
           (etaf-node 'text (list :color accent) '("→"))
           (etaf-view
            (etaf-button :label (format "%s ▾" (etaf-translate--lang-label tgt))
                         :variant 'secondary :pointer 'hand
                         :on-press (lambda ()
                                     (etaf-translate--panel-pick-language
                                      target-rt 'target sync-fn))))))
         (etaf-node
          'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
          (list
           (etaf-node 'text (list :color muted) '("引擎"))
           (etaf-view
            (etaf-button :label (format "%s ▾" engine-short)
                         :help-echo engine-full
                         :variant 'secondary :pointer 'hand
                         :on-press (lambda ()
                                     (etaf-translate--panel-pick-engine
                                      target-rt sync-fn))))))))

       ;; Row 6: Site memory (only when page has a hostname or app site)
       (when site
         (etaf-view (etaf-divider :orientation 'horizontal)))
       (when site
         (etaf-node
          'flex (list :width 'stretch :align-items 'center :gap '((lh 0) (ch 1)))
          (list
           (etaf-node 'text (list :color muted) '("站点"))
           (etaf-node 'text (list :font-weight 'bold :help-echo site)
                      (list site-label))
           (etaf-view
            (etaf-button
             :label (if (eq site-pref 'auto) "[✓] 自动翻译" "[ ] 自动翻译")
             :variant (if (eq site-pref 'auto) 'primary 'secondary)
             :aria-selected (eq site-pref 'auto)
             :pointer 'hand
             :on-press (lambda ()
                         (if (eq site-pref 'auto)
                             (etaf-translate-forget-site site)
                           (etaf-translate-remember-site site 'auto))
                         (funcall sync-fn))))
           (etaf-view
            (etaf-button
             :label (if (eq site-pref 'never) "[✓] 永不翻译" "永不翻译")
             :variant (if (eq site-pref 'never) 'primary 'ghost)
             :aria-selected (eq site-pref 'never)
             :pointer 'hand
             :on-press (lambda ()
                         (if (eq site-pref 'never)
                             (etaf-translate-forget-site site)
                           (etaf-translate-remember-site site 'never))
                         (funcall sync-fn)))))))

       ;; Footer: Compact key hint legend
       (etaf-node
        'box (list :width 'stretch :padding-top '(lh 1)
                   :border-top border-top)
        (list
         (etaf-node
          'text (list :color muted)
          '("t 开关 · m 切模式 · s 切样式 · e 换引擎 · q 关闭")))))))))

(defun etaf-translate--panel-build-view (target-rt status-ref sync-fn &optional theme-ref)
  "Return reactive ETAF View for `etaf-translate-panel' bound to TARGET-RT.
Always wraps inside `etaf-translate--panel-component' so `etaf-posframe-show'
does not eagerly evaluate `status-ref' outside reactive tracking."
  (let ((panel-node (etaf-node 'etaf-translate--panel-component
                               (list :target-rt target-rt
                                     :status-ref status-ref
                                     :sync-fn sync-fn)
                               nil)))
    (if theme-ref
        (etaf-node 'etaf-translate--themed-root
                   (list :theme theme-ref :render (lambda () panel-node))
                   nil)
      panel-node)))

;;;###autoload
(defun etaf-translate-panel (&optional runtime)
  "Toggle the floating `etaf-translate' control panel for mounted RUNTIME.
Anchored to the active window's top-right via `etaf-posframe' with live
`:theme ''auto' following when available on graphical frames, otherwise mounts
an ETAF side window.  Calling again while open for the same Runtime closes it;
switching away to another buffer or app dismisses it automatically."
  (interactive)
  (let ((rt (etaf-translate--require-runtime runtime)))
    (if (and etaf-translate--active-panel
             (eq (plist-get etaf-translate--active-panel :runtime) rt)
             (etaf-translate--panel-live-p etaf-translate--active-panel))
        (progn
          (etaf-translate--panel-close-current)
          nil)
      (let* ((ui-tick 0)
             (make-snap (lambda (&optional st)
                          (cons :ui-tick
                                (cons (cl-incf ui-tick)
                                      (copy-sequence (or st (etaf-translate-status rt)))))))
             (status-ref (etaf-ref (funcall make-snap)))
             (use-pf (etaf-translate--ui-posframe-ready-p))
             (theme-ref (unless use-pf (etaf-ref (etaf-ext-theme))))
             (pf-holder nil)
             (refresh-pf (lambda ()
                           (when (and pf-holder
                                      (fboundp 'etaf-posframe-live-p)
                                      (fboundp 'etaf-posframe-refresh)
                                      (etaf-posframe-live-p pf-holder))
                             (etaf-posframe-refresh pf-holder))))
             (sync-fn (lambda ()
                        (when (etaf-runtime-mounted-p rt)
                          (etaf-set-value status-ref (funcall make-snap))
                          (funcall refresh-pf))))
             (listener (lambda (changed-rt st)
                         (when (eq changed-rt rt)
                           (etaf-set-value status-ref (funcall make-snap st))
                           (funcall refresh-pf))))
             (watcher (etaf-translate--panel-make-window-watcher rt))
             (view (etaf-translate--panel-build-view rt status-ref sync-fn theme-ref)))
        (etaf-translate--panel-close-current)
        (add-hook 'etaf-translate-status-change-functions listener)
        (add-hook 'window-buffer-change-functions watcher)
        (add-hook 'window-selection-change-functions watcher)
        (if use-pf
            (let ((pf (etaf-posframe-show
                       view
                       :key 'etaf-translate-panel
                       :at '(window-top-right 1 -1)
                       :width 62
                       :height 20
                       :resizable nil
                       :theme 'auto
                       :focusable t
                       :focus-on-open t)))
              (setq pf-holder pf)
              (setq etaf-translate--active-panel
                    (list :runtime rt :posframe pf :listener listener
                          :window-watcher watcher :backend 'posframe))
              (when (fboundp 'etaf-posframe-refresh)
                (etaf-posframe-refresh pf))
              pf)
          (let* ((buf (get-buffer-create etaf-translate--panel-buffer-name))
                 (theme-hook (lambda (&rest _)
                               (when theme-ref
                                 (etaf-set-value theme-ref (etaf-ext-theme))))))
            (when (boundp 'enable-theme-functions)
              (add-hook 'enable-theme-functions theme-hook))
            (when (boundp 'disable-theme-functions)
              (add-hook 'disable-theme-functions theme-hook))
            (etaf-mount buf view '(:viewport-width 520))
            (when (called-interactively-p 'interactive)
              (let ((win (display-buffer-in-side-window
                          buf '((side . right) (window-width . 64)))))
                (when (window-live-p win) (select-window win))))
            (setq etaf-translate--active-panel
                  (list :runtime rt :buffer buf :listener listener
                        :window-watcher watcher :theme-hook theme-hook
                        :backend 'buffer))
            buf))))))

;;;; Quick-translate popup (etaf-translate-at-point)

(defun etaf-translate--popup-close-current ()
  "Close the active quick-translate popup and cancel any in-flight request."
  (when-let* ((desc etaf-translate--active-popup))
    (setq etaf-translate--active-popup nil)
    (when-let* ((watcher (plist-get desc :window-watcher)))
      (remove-hook 'window-buffer-change-functions watcher)
      (remove-hook 'window-selection-change-functions watcher))
    (when-let* ((cancel (plist-get desc :cancel)))
      (when (functionp cancel) (ignore-errors (funcall cancel))))
    (let ((posframe (plist-get desc :posframe))
          (buf (plist-get desc :buffer)))
      (when (and posframe (fboundp 'etaf-posframe-live-p)
                 (etaf-posframe-live-p posframe))
        (ignore-errors (etaf-posframe-hide posframe)))
      (when (and buf (buffer-live-p buf))
        (when-let* ((win (get-buffer-window buf t)))
          (ignore-errors (delete-window win)))
        (when-let* ((rt (etaf-runtime-for-buffer buf)))
          (ignore-errors (etaf-unmount rt)))
        (ignore-errors (kill-buffer buf))))))

(defun etaf-translate--popup-make-window-watcher (source-buf)
  "Return a hook function auto-closing the popup when leaving SOURCE-BUF."
  (lambda (&rest _args)
    (when-let* ((desc etaf-translate--active-popup))
      (unless (or (active-minibuffer-window)
                  (frame-parent (selected-frame)))
        (let ((cur-buf (window-buffer (selected-window)))
              (popup-buf (plist-get desc :buffer)))
          (unless (or (eq cur-buf source-buf)
                      (and popup-buf (eq cur-buf popup-buf)))
            (etaf-translate--popup-close-current)))))))

(defun etaf-translate-popup-close ()
  "Close the active quick-translate popup if visible."
  (etaf-translate--popup-close-current))

(defun etaf-translate--extract-text-at-point ()
  "Return normalized active region text, or the word/symbol at point."
  (cond
   ((use-region-p)
    (etaf-translate--join-wrapped-lines
     (buffer-substring-no-properties (region-beginning) (region-end))))
   ((thing-at-point 'word t)
    (string-trim (thing-at-point 'word t)))
   ((thing-at-point 'symbol t)
    (string-trim (thing-at-point 'symbol t)))
   (t "")))

(defun etaf-translate--popup-paragraph-nodes (result fg)
  "Build clean paragraph View nodes for translated RESULT using FG ink."
  (let ((paras (split-string (string-trim (or result "")) "\n+" t)))
    (if (<= (length paras) 1)
        (list (etaf-node 'text (list :color fg) (list (or result ""))))
      (list
       (etaf-node
        'column (list :width 'stretch :item-gap '(lh 1))
        (mapcar (lambda (p)
                  (etaf-node 'box (list :width 'stretch :wrap-mode 'word :color fg)
                             (list (etaf-node 'text nil (list p)))))
                paras))))))

(defun etaf-translate--popup-content-view
    (state-ref engine-ref max-body-rows on-retranslate)
  "Return the pure-translation View for `etaf-translate-at-point'.
Displays only the translated text (never repeating the source text already
visible beside point), auto-sizing up to MAX-BODY-ROWS with scrolling for long
selections, followed by a single compact action bar."
  (let* ((st (etaf-value state-ref))
         (eng (etaf-value engine-ref))
         (phase (plist-get st :phase))
         (result (plist-get st :text))
         (err-msg (plist-get st :error))
         (bg (etaf-theme-token :ui-panel-bg "#1b2226"))
         (fg (etaf-theme-token :ui-panel-fg "#ffffff"))
         (muted (etaf-theme-token :ui-muted-fg "#9fa2a3"))
         (danger (etaf-theme-token :ui-danger-fg "#f87171"))
         (border-top (etaf-theme-token
                      :ui-panel-border "#3f4548"
                      (lambda (c) (list '(px 1) 'solid c))))
         (do-copy (lambda ()
                    (when (and (stringp result) (not (string-empty-p result)))
                      (kill-new result)
                      (message "etaf-translate: 已复制译文"))))
         (do-engine (lambda ()
                      (let* ((choices (etaf-translate--engine-choices))
                             (picked (intern
                                      (completing-read
                                       "切换快译引擎: "
                                       (mapcar (lambda (c) (symbol-name (car c))) choices)
                                       nil t))))
                        (funcall on-retranslate picked))))
         (do-scroll (lambda (delta)
                      (when-let* ((rt (etaf-current-runtime)))
                        (ignore-errors (etaf-scroll-by rt 'popup-body delta)))))
         (do-close (lambda () (etaf-translate-popup-close)))
         (body-children
          (cond
           ((eq phase 'loading)
            (list (etaf-node 'text (list :color muted) '("译文中…"))))
           ((eq phase 'error)
            (list (etaf-node 'text (list :color danger)
                             (list (format "翻译失败：%s" (or err-msg "未知错误"))))))
           (t (etaf-translate--popup-paragraph-nodes result fg)))))
    (etaf-node
     'column
     (list :width 'stretch
           :background-color bg
           :color fg
           :padding '((lh 1) (ch 2))
           :item-gap '(lh 1)
           :focus-scope 'modal
           :on-dismiss do-close
           :keys (list (list "c" do-copy "复制译文")
                       (list "e" do-engine "切换引擎")
                       (list "j" (lambda () (funcall do-scroll 2)) "向下滚动")
                       (list "k" (lambda () (funcall do-scroll -2)) "向上滚动")
                       (list "SPC" (lambda () (funcall do-scroll 6)) "向下翻页")
                       (list "DEL" (lambda () (funcall do-scroll -6)) "向上翻页")
                       (list "q" do-close "关闭浮窗")))
     (list
      ;; Pure translated body: auto-sized up to max-body-rows, scrollable beyond
      (etaf-node
       'box (list :width 'stretch
                  :ref 'popup-body
                  :max-height (list 'lh max-body-rows)
                  :overflow 'scroll
                  :wrap-mode 'word)
       body-children)
      ;; Single compact footer row
      (etaf-node
       'flex (list :width 'stretch :justify-content 'space-between
                   :align-items 'center :padding-top '(lh 1)
                   :border-top border-top)
       (list
        (etaf-node
         'flex (list :gap '((lh 0) (ch 1)))
         (list
          (etaf-view (etaf-button :label "复制 (c)" :variant 'secondary
                                  :pointer 'hand :on-press do-copy))
          (etaf-view (etaf-button :label "换引擎 (e)" :variant 'ghost
                                  :pointer 'hand :on-press do-engine))))
        (etaf-node 'text (list :color muted)
                   (list (format "%s · q / ESC 关闭"
                                 (etaf-translate--engine-short-label eng))))))))))

(defun etaf-translate--popup-build-view
    (state-ref engine-ref max-body-rows on-retranslate &optional theme-ref)
  "Return reactive ETAF View for the quick-translate popup."
  (let ((popup-node (etaf-node 'etaf-translate--popup-component
                               (list :state-ref state-ref
                                     :engine-ref engine-ref
                                     :max-body-rows max-body-rows
                                     :on-retranslate on-retranslate)
                               nil)))
    (if theme-ref
        (etaf-node 'etaf-translate--themed-root
                   (list :theme theme-ref :render (lambda () popup-node))
                   nil)
      popup-node)))

;;;###autoload
(defun etaf-translate-at-point (&optional text engine)
  "Translate TEXT (or active region / word at point) in a pure-translation popup.
Works in any ETAF or ordinary Emacs buffer.  Never repeats the original text;
auto-sizes height to fit the translation up to 60% of the frame height and
enables vertical scrolling when a long selection exceeds that budget."
  (interactive)
  (let* ((source-buf (current-buffer))
         (source-text (string-trim (or text (etaf-translate--extract-text-at-point) "")))
         (rt (or (etaf-current-runtime) (etaf-runtime-for-buffer source-buf)))
         (policy (etaf-translate-resolve-policy rt))
         (eng-name (or engine (plist-get policy :engine)))
         (src (plist-get policy :source-lang))
         (tgt (plist-get policy :target-lang))
         (glossary (plist-get policy :glossary))
         (cache (etaf-translate-default-cache))
         (top-frame (let ((f (selected-frame)))
                      (while (frame-parent f) (setq f (frame-parent f)))
                      f))
         (frame-rows (max 16 (frame-height top-frame)))
         ;; Reserve 6 chrome rows and a 0.78 CJK line-height factor so the
         ;; footer stays pinned inside the 60% posframe budget even when CJK
         ;; fallback glyphs are slightly taller than Latin line height.
         (budget-rows (max 10 (floor (* 0.6 frame-rows))))
         (max-body-rows (max 5 (floor (* (- budget-rows 6) 0.78)))))
    (when (string-empty-p source-text)
      (signal 'etaf-translate-error (list "No text at point to translate")))
    (etaf-translate--engine-require eng-name)
    (etaf-translate--popup-close-current)
    (let* ((state-ref (etaf-ref (list :phase 'loading :text nil :error nil)))
           (engine-ref (etaf-ref eng-name))
           (use-pf (etaf-translate--ui-posframe-ready-p))
           (theme-ref (unless use-pf (etaf-ref (etaf-ext-theme))))
           (watcher (etaf-translate--popup-make-window-watcher source-buf))
           (desc nil)
           (refresh-pf (lambda ()
                         (when-let* ((pf (plist-get desc :posframe)))
                           (when (and (fboundp 'etaf-posframe-live-p)
                                      (fboundp 'etaf-posframe-refresh)
                                      (etaf-posframe-live-p pf))
                             (etaf-posframe-refresh pf))))))
      (letrec
          ((run-translate
            (lambda (chosen-engine)
              (when-let* ((old-c (plist-get desc :cancel)))
                (when (functionp old-c) (ignore-errors (funcall old-c))))
              (etaf-set-value engine-ref chosen-engine)
              (let* ((spec (etaf-translate--engine-require chosen-engine))
                     (ckey (etaf-translate-cache-key
                            source-text src tgt chosen-engine
                            (etaf-translate-glossary-hash glossary)))
                     (hit (etaf-translate-cache-get cache ckey)))
                (if hit
                    (progn
                      (etaf-set-value state-ref (list :phase 'ready :text hit :error nil))
                      (funcall refresh-pf))
                  (etaf-set-value state-ref (list :phase 'loading :text nil :error nil))
                  (let ((cancel
                         (funcall
                          (plist-get spec :translate)
                          (list :units (list source-text)
                                :source-lang src
                                :target-lang tgt
                                :glossary glossary
                                :prompt-style (plist-get policy :prompt-style))
                          (lambda (res)
                            (let ((tr (etaf-translate-normalize-spacing (or (car res) ""))))
                              (etaf-translate-cache-put cache ckey tr)
                              (etaf-set-value state-ref
                                              (list :phase 'ready :text tr :error nil))
                              (funcall refresh-pf)))
                          (lambda (msg)
                            (etaf-set-value state-ref
                                            (list :phase 'error :text nil :error msg))
                            (funcall refresh-pf)))))
                    (when desc (plist-put desc :cancel cancel))))))))
        (let ((view (etaf-translate--popup-build-view
                     state-ref engine-ref max-body-rows
                     run-translate theme-ref)))
          (add-hook 'window-buffer-change-functions watcher)
          (add-hook 'window-selection-change-functions watcher)
          (if use-pf
              (let ((pf (etaf-posframe-show
                         view
                         :key 'etaf-translate-popup
                         :at 'point
                         :width 58
                         :height '(fraction 0.6)
                         :resizable nil
                         :theme 'auto
                         :focusable t
                         :focus-on-open t)))
                (setq desc (list :posframe pf :backend 'posframe
                                 :state state-ref :window-watcher watcher))
                (setq etaf-translate--active-popup desc)
                (funcall run-translate eng-name)
                (funcall refresh-pf)
                pf)
            (let ((buf (get-buffer-create etaf-translate--popup-buffer-name)))
              (etaf-mount buf view '(:viewport-width 480))
              (when (called-interactively-p 'interactive)
                (display-buffer-in-side-window
                 buf '((side . bottom) (window-height . 10))))
              (setq desc (list :buffer buf :backend 'buffer
                               :state state-ref :window-watcher watcher))
              (setq etaf-translate--active-popup desc)
              (funcall run-translate eng-name)
              buf)))))))

(provide 'etaf-translate-ui)
;;; etaf-translate-ui.el ends here
