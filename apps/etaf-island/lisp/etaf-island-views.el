;;; etaf-island-views.el --- Pure-protocol ETAF views for ETAF Island -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure ETAF Views implementing the v2 `etaf-island' product design across idle
;; capsule, multi-activity compact capsule, live `etaf-notify' pulse card and
;; three-tab expanded hub (`activities', `events', `quick').  Zero hardcoded
;; demo data, generous top/bottom breathing padding, sleek hairline progress
;; bars, friendly localized source names, zero-jitter `1ch' keyboard selection
;; and demand-driven animation ticking (0% idle repaints).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-island-theme)
(require 'etaf-island-sensors)
(require 'etaf-island-model)

(defconst etaf-island--spectrum-glyphs "▁▂▃▄▅▆▇█"
  "Eight-level block glyphs for real audio spectrum bars.")

(defconst etaf-island--core-launchers
  (list
   (list :id 'pomodoro :lib "etaf-pomodoro" :fn 'etaf-pomodoro-open
         :icon "●" :title "番茄专注" :desc "开启 25 分钟实时计时")
   (list :id 'ncm :lib "etaf-ncm" :fn 'etaf-ncm-open
         :icon "♪" :title "网易云音乐" :desc "同步歌词与实时频谱")
   (list :id 'agenda :lib "etaf-agenda" :fn 'etaf-agenda-open
         :icon "◷" :title "今日日程" :desc "查看待办并速记任务")
   (list :id 'ext :lib "etaf-ext" :fn 'etaf-ext-manage
         :icon "⚙" :title "扩展中心" :desc "管理翻译、高亮与跳转")
   (list :id 'telega :lib "etaf-telega" :fn 'etaf-telega-open
         :icon "◆" :title "Telegram" :desc "查看未读并快速回复")
   (list :id 'bili :lib "etaf-bili" :fn 'etaf-bili-open
         :icon "▸" :title "哔哩哔哩" :desc "视频观影与后台听音频"))
  "Core ETAF ecosystem launchers shown as a 2x3 grid on Tab 3.")

(defun etaf-island--truncate (text max-cols)
  "Truncate TEXT to at most MAX-COLS display columns with an ellipsis."
  (let ((s (or text "")))
    (if (<= (string-width s) max-cols)
        s
      (truncate-string-to-width s max-cols nil nil "…"))))

(defun etaf-island--sample-meter (meter-fn width active-p)
  "Sample METER-FN for WIDTH bars, returning a block-glyph string or nil."
  (when (functionp meter-fn)
    (if (not active-p)
        (make-string width ?▁)
      (let ((levels (condition-case nil (funcall meter-fn width) (error nil))))
        (when (and (listp levels) levels)
          (let* ((glyphs etaf-island--spectrum-glyphs)
                 (top (1- (length glyphs))))
            (apply #'string
                   (cl-loop for i below width
                            for raw = (or (nth i levels) 0.0)
                            for clamped = (max 0.0 (min 1.0 (float raw)))
                            collect (aref glyphs (round (* clamped top)))))))))))

(defun etaf-island--tone-fg (tone tokens)
  "Resolve semantic TONE symbol to calm foreground colour in TOKENS."
  (pcase tone
    ('success (plist-get tokens :island-focus))
    ('warning (plist-get tokens :island-warn))
    ('danger  (plist-get tokens :island-danger))
    ('info    (plist-get tokens :island-accent))
    (_        (plist-get tokens :island-muted))))

;;;; Shared Selectable Item Ordering (Single Source of Truth for View + Keys)

(defun etaf-island--partition-activities (activities)
  "Partition ACTIVITIES into `(:medias :mids :summaries :ordered :overflow)'."
  (let* ((all-media (cl-remove-if-not (lambda (a) (eq (plist-get a :kind) 'media)) activities))
         (all-mid (cl-remove-if-not (lambda (a) (memq (plist-get a :kind) '(timer task status)))
                                    activities))
         (all-sum (cl-remove-if-not (lambda (a) (memq (plist-get a :kind) '(inbox schedule)))
                                    activities))
         (medias (cl-subseq all-media 0 (min 1 (length all-media))))
         (mids (cl-subseq all-mid 0 (min 4 (length all-mid))))
         (sums (cl-subseq all-sum 0 (min 2 (length all-sum))))
         (ordered (append medias mids sums))
         (overflow (max 0 (- (length activities) (length ordered)))))
    (list :medias medias :mids mids :summaries sums
          :ordered ordered :overflow overflow)))

(defun etaf-island--visible-notes (notes)
  "Return up to 4 most recent NOTES so Tab 2 keeps fixed bounded height."
  (cl-subseq notes 0 (min 4 (length notes))))

(defun etaf-island--launcher-available-p (entry)
  "Return non-nil when launcher ENTRY is loaded or discoverable on `load-path'."
  (or (fboundp (plist-get entry :fn))
      (and (stringp (plist-get entry :lib))
           (locate-library (plist-get entry :lib)))))

(defun etaf-island--launch-app (item &optional after-fn)
  "Require ITEM's library if needed, invoke its command and run AFTER-FN."
  (let ((lib (plist-get item :lib))
        (fn (plist-get item :fn)))
    (condition-case err
        (progn
          (unless (fboundp fn)
            (require (intern lib)))
          (if (fboundp fn)
              (progn
                (when (functionp after-fn) (funcall after-fn))
                (call-interactively fn))
            (message "ETAF Island: 未安装 %s" (plist-get item :title))))
      (error (message "ETAF Island: 无法打开 %s (%s)"
                      (plist-get item :title)
                      (error-message-string err))))))

(defun etaf-island--quick-items (session)
  "Return ordered selectable descriptors for Tab 3 (`quick') in SESSION."
  (append
   (mapcar (lambda (entry) (list :kind 'launcher :entry entry))
           etaf-island--core-launchers)
   (list (list :kind 'sensor :id 'compile :session session)
         (list :kind 'sensor :id 'org-clock :session session)
         (list :kind 'sensor :id 'auto-hide :session session)
         (list :kind 'sensor :id 'reset-pos :session session))))

(defun etaf-island--tab-item-count (session tab)
  "Return selectable item count on TAB for SESSION."
  (pcase tab
    ('events (length (etaf-island--visible-notes (etaf-notify-list))))
    ('quick (length (etaf-island--quick-items session)))
    (_ (length (plist-get (etaf-island--partition-activities (etaf-activity-list))
                          :ordered)))))

;;;; Reusable Calm Primitives

(defun etaf-island--btn (label on-press variant tokens &optional ref compact-p)
  "Build a calm borderless button (`primary', `ctrl' or `ghost').
When COMPACT-P is non-nil, uses tighter 1ch horizontal padding."
  (let* ((bg (pcase variant
               ('primary (plist-get tokens :island-accent-fill))
               ('ctrl    (plist-get tokens :island-ctrl))
               (_        nil)))
         (ink (pcase variant
                ('primary (plist-get tokens :island-accent-fg))
                ('ctrl    (plist-get tokens :island-fg))
                (_        (plist-get tokens :island-muted))))
         (hover (plist-get tokens :island-hover)))
    (etaf-node
     'box
     (append
      (list :flex-shrink 0
            :padding (if (or compact-p (eq variant 'ghost))
                         '((lh 0) (ch 1))
                       '((lh 0) (ch 2)))
            :role 'button :tab-index 0 :aria-label label
            :pointer 'hand
            :on-press (lambda () (etaf-island--safe-call on-press)))
      (when ref (list :ref ref))
      (when bg (list :background-color bg))
      (unless (eq variant 'primary)
        (list :hover-style (list :background-color hover))))
     (list (etaf-node 'text
                      (list :color ink
                            :font-weight (if (eq variant 'primary) 'bold 'normal))
                      (list label))))))

(defun etaf-island--segment-tab (label on-press active-p tokens &optional ref)
  "Build a zero-jitter borderless segment tab."
  (let* ((bg (when active-p (plist-get tokens :island-ctrl)))
         (ink (if active-p (plist-get tokens :island-fg)
                (plist-get tokens :island-muted)))
         (hover (plist-get tokens :island-hover)))
    (etaf-node
     'box
     (append
      (list :flex-shrink 0 :padding '((lh 0) (ch 2))
            :role 'tab :tab-index 0
            :aria-selected (and active-p t) :aria-label label)
      (when ref (list :ref ref))
      (when bg (list :background-color bg))
      (unless active-p
        (list :pointer 'hand
              :hover-style (list :background-color hover)
              :on-press on-press)))
     (list (etaf-node 'text
                      (list :color ink
                            :font-weight (if active-p 'bold 'normal))
                      (list label))))))

(defun etaf-island--switch (on-p on-press tokens &optional ref)
  "Build a quiet borderless switch (`● 开' / `○ 关')."
  (let ((bg (if on-p (plist-get tokens :island-focus-soft)
              (plist-get tokens :island-ctrl)))
        (fg (if on-p (plist-get tokens :island-focus)
              (plist-get tokens :island-dim))))
    (etaf-node
     'box
     (append
      (list :flex-shrink 0 :background-color bg :padding '((lh 0) (ch 1))
            :role 'switch :pointer 'hand
            :aria-label (if on-p "关闭" "开启")
            :on-press on-press)
      (when ref (list :ref ref)))
     (list (etaf-node 'text (list :color fg)
                      (list (if on-p "● 开" "○ 关")))))))

(defun etaf-island--hairline-bar (fraction cols color-key tokens &optional left-lbl right-lbl)
  "Render a sleek hairline `━'/`─' progress strip of COLS cells at FRACTION (0..1)."
  (let* ((ratio (max 0.0 (min 1.0 (float (or fraction 0.0)))))
         (total (max 6 cols))
         (filled (round (* ratio total)))
         (rest (- total filled))
         (bar-color (plist-get tokens color-key))
         (track (plist-get tokens :island-track))
         (dim (plist-get tokens :island-dim)))
    (etaf-node
     'flex (list :width 'stretch :align-items 'center :gap '((lh 0) (ch 1)))
     (delq
      nil
      (list
       (when left-lbl
         (etaf-node 'text (list :color dim) (list left-lbl)))
       (etaf-node
        'flex (list :flex-grow 1 :flex-shrink 1 :align-items 'center :overflow 'hidden)
        (delq
         nil
         (list
          (when (> filled 0)
            (etaf-node 'text (list :color bar-color)
                       (list (make-string filled ?━))))
          (when (> rest 0)
            (etaf-node 'text (list :color track)
                       (list (make-string rest ?─)))))))
       (when right-lbl
         (etaf-node 'text (list :color dim) (list right-lbl))))))))

(defun etaf-island--progress-bar (progress cols tokens color-key)
  "Render a sleek hairline progress strip for PROGRESS plist across COLS cells."
  (let* ((val (or (plist-get progress :value) 0))
         (max-v (max 1 (or (plist-get progress :max) 100)))
         (indet (plist-get progress :indeterminate))
         (ratio (if indet 0.38 (/ (float val) (float max-v))))
         (left-lbl (plist-get progress :left-label))
         (right-lbl (plist-get progress :right-label)))
    (etaf-island--hairline-bar ratio cols color-key tokens left-lbl right-lbl)))

(defun etaf-island--selection-bar (selected-p tokens)
  "Return a constant-width `1ch' left selection slot (`▎' or blank) for 0px jitter."
  (etaf-node 'box (list :flex-shrink 0)
             (list
              (etaf-node 'text
                         (list :color (if selected-p
                                          (plist-get tokens :island-accent)
                                        (plist-get tokens :island-card)))
                         (list (if selected-p "▎" " "))))))

(defun etaf-island--drag-grip (tokens &optional floating-p)
  "Return a subtle `⋮⋮' drag grip when FLOATING-P is non-nil."
  (when floating-p
    (etaf-node 'box (list :flex-shrink 0
                          :help-echo "按住拖动移动灵动岛位置；按 0 回到顶部居中")
               (list (etaf-node 'text (list :color (plist-get tokens :island-dim))
                                '("⋮⋮"))))))

;;;; State A & B: Compact 1-Row Capsule

(defun etaf-island--slot-divider (tokens)
  "Return a subtle vertical divider text node."
  (etaf-node 'text (list :color (plist-get tokens :island-border-soft)) '("│")))

(defun etaf-island--compact-bar-node (session activities notes clock-str _meter-tick tokens floating-p)
  "Build the sleek 1-row compact capsule from live ACTIVITIES and NOTES."
  (let* ((timer (cl-find 'timer activities :key (lambda (a) (plist-get a :kind))))
         (media (cl-find 'media activities :key (lambda (a) (plist-get a :kind))))
         (task  (cl-find 'task activities :key (lambda (a) (plist-get a :kind))))
         (inbox (cl-find 'inbox activities :key (lambda (a) (plist-get a :kind))))
         (sched (cl-find 'schedule activities :key (lambda (a) (plist-get a :kind))))
         (note-n (length notes))
         (has-live (or (and timer (eq (plist-get timer :state) 'active))
                       (and media (memq (plist-get media :state) '(active paused)))
                       (and task (eq (plist-get task :state) 'active))
                       inbox (> note-n 0)))
         (fg (plist-get tokens :island-fg))
         (muted (plist-get tokens :island-muted))
         (dim (plist-get tokens :island-dim))
         (accent (plist-get tokens :island-accent))
         (spec-col (plist-get tokens :island-spectrum))
         (ok (plist-get tokens :island-focus))
         (warn (plist-get tokens :island-warn))
         (slots nil))
    (if (not has-live)
        ;; State A: Quiet idle capsule (clock + optional schedule)
        (progn
          (push (etaf-node
                 'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                 (list (etaf-node 'text (list :color ok) '("●"))
                       (etaf-node 'text (list :color fg :font-weight 'bold)
                                  (list clock-str))))
                slots)
          (if sched
              (progn
                (push (etaf-island--slot-divider tokens) slots)
                (push (etaf-node 'text (list :color muted)
                                 (list (etaf-island--truncate
                                        (or (plist-get sched :compact)
                                            (plist-get sched :title))
                                        22)))
                      slots))
            (push (etaf-node 'text (list :color dim) '("· 空闲")) slots)))
      ;; State B: Multi-activity arbitrated capsule
      (when (and timer (eq (plist-get timer :state) 'active))
        (push (etaf-node
               'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
               (list (etaf-node 'text (list :color ok) '("●"))
                     (etaf-node 'text (list :color fg :font-weight 'bold)
                                (list (etaf-island--truncate
                                       (or (plist-get timer :compact)
                                           (plist-get timer :title))
                                       13)))))
              slots))
      (when (and media (memq (plist-get media :state) '(active paused)))
        (when slots (push (etaf-island--slot-divider tokens) slots))
        (let* ((playing (eq (plist-get media :state) 'active))
               (title (etaf-island--truncate
                       (or (plist-get media :compact) (plist-get media :title)) 12))
               (spec (etaf-island--sample-meter (plist-get media :meter) 6 playing)))
          (push (etaf-node
                 'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                 (delq
                  nil
                  (list (etaf-node 'text (list :color (if playing accent muted))
                                   (list (format "♪ %s" title)))
                        (when spec
                          (etaf-node 'text (list :color (if playing spec-col dim))
                                     (list spec))))))
                slots)))
      (when (and task (eq (plist-get task :state) 'active))
        (when slots (push (etaf-island--slot-divider tokens) slots))
        (let* ((icon (or (plist-get task :icon) "↓"))
               (raw (etaf-island--truncate
                     (or (plist-get task :compact) (plist-get task :title)) 10))
               (label (if (string-prefix-p icon raw)
                          raw
                        (format "%s %s" icon raw))))
          (push (etaf-node 'text (list :color muted) (list label))
                slots)))
      (when (or inbox (> note-n 0))
        (when slots (push (etaf-island--slot-divider tokens) slots))
        (let ((lbl (cond
                    ((> note-n 0) (format "◆ %d 未读" note-n))
                    (inbox (format "◆ %s"
                                   (etaf-island--truncate
                                    (or (plist-get inbox :compact)
                                        (plist-get inbox :title))
                                    10))))))
          (push (etaf-node 'text (list :color warn) (list lbl)) slots))))
    (etaf-node
     'flex
     (list :class "island-compact"
           :width 'stretch :height '(lh 1)
           :align-items 'center :justify-content 'space-between
           :padding '((lh 0) (ch 2))
           :gap '((lh 0) (ch 1))
           :background-color (plist-get tokens :island-surface))
     (list
      (etaf-node
       'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
       (delq nil (cons (etaf-island--drag-grip tokens floating-p)
                       (nreverse slots))))
      (etaf-node
       'box (list :ref 'island-expand :role 'button :tab-index 0
                  :aria-label "展开灵动岛"
                  :help-echo "展开灵动岛（或按 C-c e i）"
                  :flex-shrink 0
                  :padding '((lh 0) (ch 1))
                  :pointer 'hand
                  :hover-style (list :background-color (plist-get tokens :island-hover))
                  :on-press (lambda () (etaf-island-set-mode session 'expanded)))
       (list (etaf-node 'text (list :color muted)
                        (list (if has-live "展开 ▾" "▾")))))))))

;;;; State C: Live Event Pulse Card

(etaf-define-component etaf-island--alert-card (&key session tokens alert)
  "Render a calm live `etaf-notify' pulse card with hairline TTL."
  :bindings
  ((ttl-target (etaf-ref 1.0 :name 'island-alert-ttl-target))
   (ttl-shown (etaf-transition
               ttl-target :duration (max 0.1 (or (plist-get alert :ttl) 5.0))
               :easing 'linear :name 'island-alert-ttl
               :on-complete
               (lambda ()
                 (let ((aid (plist-get alert :id)))
                   (when (and aid (> (or (plist-get alert :ttl) 0) 0))
                     (let ((cur (etaf-untracked
                                 (etaf-value (plist-get session :active-alert)))))
                       (when (and cur (equal aid (plist-get cur :id))
                                  (eq (etaf-untracked
                                       (etaf-value (plist-get session :mode)))
                                      'alert))
                         (etaf-island-set-mode session 'compact)))))))))
  :setup
  (when (> (or (plist-get alert :ttl) 0) 0)
    (setf (etaf-value ttl-target) 0.0))
  :render
  (let* ((variant (or (plist-get alert :variant) 'info))
         (vc (etaf-island--variant-colors tokens variant))
         (vfg (nth 0 vc))
         (vbg (nth 1 vc))
         (vlbl (nth 2 vc))
         (aid (plist-get alert :id))
         (app-lbl (etaf-island--app-label (plist-get alert :app)))
         (cnt (or (plist-get alert :count) 1))
         (detail (or (plist-get alert :detail) ""))
         (actions (plist-get alert :actions))
         (ttl (or (plist-get alert :ttl) 0))
         (ratio (etaf-animation-quantize (etaf-value ttl-shown) 0.02))
         (fg (plist-get tokens :island-fg))
         (muted (plist-get tokens :island-muted))
         (dim (plist-get tokens :island-dim))
         (tone-key (pcase variant
                     ('success :island-focus)
                     ('warning :island-warn)
                     ('danger :island-danger)
                     (_ :island-accent))))
    (etaf-node
     'column (list :class "island-alert" :width 'stretch
                   :padding '((lh 1) (ch 2))
                   :item-gap '(lh 1)
                   :background-color (plist-get tokens :island-surface))
     (delq
      nil
      (list
       ;; Header + detail block
       (etaf-node
        'column (list :width 'stretch :item-gap '(lh 0))
        (delq
         nil
         (list
          (etaf-node
           'flex (list :width 'stretch :justify-content 'space-between
                       :align-items 'center :gap '((lh 0) (ch 1)))
           (list
            (etaf-node
             'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
             (delq
              nil
              (list
               (etaf-node 'box (list :background-color vbg :padding '((lh 0) (ch 1)))
                          (list (etaf-node 'text (list :color vfg)
                                           (list (format "● %s" vlbl)))))
               (etaf-node 'text (list :color fg :font-weight 'bold)
                          (list (etaf-island--truncate
                                 (or (plist-get alert :title) "") 38)))
               (when (> cnt 1)
                 (etaf-node 'box (list :background-color (plist-get tokens :island-ctrl)
                                       :padding '((lh 0) (ch 1)))
                            (list (etaf-node 'text (list :color muted)
                                             (list (format "×%d" cnt)))))))))
            (etaf-node 'text (list :color dim)
                       (list (if app-lbl
                                 (format "%s · %s" app-lbl (or (plist-get alert :time) ""))
                               (or (plist-get alert :time) ""))))))
          (unless (string-empty-p detail)
            (etaf-node 'text (list :color muted)
                       (list (etaf-island--truncate detail 62)))))))
       ;; Action strip
       (etaf-node
        'flex (list :width 'stretch :align-items 'center :gap '((lh 0) (ch 2)))
        (append
         (cl-loop for act in actions
                  for idx from 0
                  collect
                  (let ((fn (plist-get act :fn))
                        (primary (or (plist-get act :primary) (= idx 0))))
                    (etaf-island--btn
                     (plist-get act :label)
                     (lambda ()
                       (etaf-island--safe-call fn)
                       (etaf-island-dismiss-notification session aid))
                     (if primary 'primary 'ctrl)
                     tokens
                     (when (= idx 0) 'island-alert-action))))
         (list
          (etaf-island--btn
           "忽略 d"
           (lambda () (etaf-island-dismiss-notification session aid))
           'ctrl tokens 'island-alert-dismiss)
          (etaf-island--btn
           "展开全部 SPC"
           (lambda () (etaf-island-select-tab session 'events))
           'ghost tokens 'island-alert-all))))
       ;; Sleek hairline TTL strip
       (when (> ttl 0)
         (etaf-island--hairline-bar ratio 66 tone-key tokens)))))))

;;;; State D: Expanded Hub — Tab 1 (实时活动)

(defun etaf-island--media-card (act meter-tick selected-p tokens &optional on-open-after)
  "Render the full-width hero media card for live activity ACT."
  (ignore meter-tick)
  (let* ((aid (plist-get act :id))
         (playing (eq (plist-get act :state) 'active))
         (title (or (plist-get act :title) ""))
         (sub (or (plist-get act :subtitle) ""))
         (app-lbl (etaf-island--app-label (plist-get act :app)))
         (prog (plist-get act :progress))
         (actions (plist-get act :actions))
         (open-fn (plist-get act :open))
         (spec (etaf-island--sample-meter (plist-get act :meter) 8 playing))
         (fg (plist-get tokens :island-fg))
         (muted (plist-get tokens :island-muted))
         (dim (plist-get tokens :island-dim))
         (accent (plist-get tokens :island-accent))
         (accent-soft (plist-get tokens :island-accent-soft))
         (spec-col (plist-get tokens :island-spectrum))
         (bg (if selected-p
                 (plist-get tokens :island-card-selected)
               (plist-get tokens :island-card)))
         (bdr (if selected-p
                  (plist-get tokens :island-border)
                (plist-get tokens :island-border-soft))))
    (etaf-node
     'flex
     (list :key aid :width 'stretch
           :background-color bg
           :border (list '(px 1) 'solid bdr)
           :padding '((lh 1) (ch 1))
           :gap '((lh 0) (ch 1)))
     (list
      (etaf-island--selection-bar selected-p tokens)
      (etaf-node
       'column (list :flex-grow 1 :flex-shrink 1
                     :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                     :item-gap '(lh 1))
       (delq
        nil
        (list
         ;; Top row: icon + friendly title/subtitle + live spectrum
         (etaf-node
          'flex (list :width 'stretch :justify-content 'space-between
                      :align-items 'center :gap '((lh 0) (ch 2)))
          (delq
           nil
           (list
            (etaf-node
             'flex (list :flex-grow 1 :flex-shrink 1 :align-items 'center
                         :gap '((lh 0) (ch 2)))
             (list
              (etaf-node 'box (list :flex-shrink 0 :background-color accent-soft
                                    :padding '((lh 0) (ch 1)))
                         (list (etaf-node 'text (list :color accent :font-weight 'bold)
                                          (list (or (plist-get act :icon) "♪")))))
              (etaf-node
               'column (list :flex-grow 1 :flex-shrink 1 :item-gap '(lh 0))
               (delq
                nil
                (list
                 (etaf-node
                  'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                  (delq
                   nil
                   (list
                    (etaf-node 'text (list :color fg :font-weight 'bold) (list title))
                    (when app-lbl
                      (etaf-node 'text (list :color dim)
                                 (list (format "· %s" app-lbl)))))))
                 (unless (string-empty-p sub)
                   (etaf-node 'text (list :color muted)
                              (list (etaf-island--truncate sub 48)))))))))
            (when spec
              (etaf-node 'text (list :color (if playing spec-col dim))
                         (list spec))))))
         ;; Sleek hairline progress strip
         (when prog
           (let* ((val (or (plist-get prog :value) 0))
                  (max-v (max 1 (or (plist-get prog :max) 1)))
                  (unit (plist-get prog :unit))
                  (enriched
                   (if (eq unit 'seconds)
                       (append prog
                               (list :left-label (etaf-island--format-clock val)
                                     :right-label (etaf-island--format-clock max-v)))
                     prog)))
             (etaf-island--progress-bar enriched 56 tokens :island-accent)))
         ;; Transport controls + open link
         (when (or actions open-fn)
           (etaf-node
            'flex (list :width 'stretch :justify-content 'space-between
                        :align-items 'center :gap '((lh 0) (ch 1)))
            (delq
             nil
             (list
              (etaf-node
               'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
               (mapcar (lambda (a)
                         (etaf-island--btn
                          (plist-get a :label)
                          (plist-get a :fn)
                          (if (plist-get a :primary) 'primary 'ctrl)
                          tokens nil t))
                       actions))
              (when open-fn
                (etaf-node
                 'box (list :flex-shrink 0 :padding '((lh 0) (ch 1))
                            :pointer 'hand :role 'button :tab-index 0
                            :hover-style (list :background-color (plist-get tokens :island-hover))
                            :on-press (lambda ()
                                        (when (functionp on-open-after) (funcall on-open-after))
                                        (etaf-island--safe-call open-fn)))
                 (list (etaf-node 'text (list :color accent) '("打开 ↗"))))))))))))))))

(defun etaf-island--compact-activity-card (act selected-p tokens &optional on-open-after)
  "Render a half-width card for `timer', `task' or `status' ACT."
  (let* ((aid (plist-get act :id))
         (kind (plist-get act :kind))
         (tone (or (plist-get act :tone)
                   (if (eq kind 'timer) 'success 'info)))
         (tfg (etaf-island--tone-fg tone tokens))
         (fg (plist-get tokens :island-fg))
         (muted (plist-get tokens :island-muted))
         (accent (plist-get tokens :island-accent))
         (prog (plist-get act :progress))
         (actions (plist-get act :actions))
         (open-fn (plist-get act :open))
         (compact (plist-get act :compact))
         (bg (if selected-p
                 (plist-get tokens :island-card-selected)
               (plist-get tokens :island-card)))
         (bdr (if selected-p
                  (plist-get tokens :island-border)
                (plist-get tokens :island-border-soft))))
    (etaf-node
     'flex
     (list :key aid :flex-grow 1 :flex-shrink 1
           :background-color bg
           :border (list '(px 1) 'solid bdr)
           :padding '((lh 1) (ch 1))
           :gap '((lh 0) (ch 1)))
     (list
      (etaf-island--selection-bar selected-p tokens)
      (etaf-node
       'column (list :flex-grow 1 :flex-shrink 1
                     :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                     :item-gap '(lh 0))
       (delq
        nil
        (list
         ;; Top row: icon + title + right readout
         (etaf-node
          'flex (list :width 'stretch :justify-content 'space-between
                      :align-items 'center :gap '((lh 0) (ch 1)))
          (delq
           nil
           (list
            (etaf-node
             'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
             (list
              (etaf-node 'text (list :color tfg)
                         (list (or (plist-get act :icon)
                                   (if (eq kind 'timer) "●" "↓"))))
              (etaf-node 'text (list :color fg :font-weight 'bold)
                         (list (etaf-island--truncate (plist-get act :title) 18)))))
            (when compact
              (etaf-node 'text (list :color tfg :font-weight 'bold)
                         (list (etaf-island--truncate compact 12)))))))
         ;; Sleek hairline progress bar
         (when prog
           (etaf-island--progress-bar
            prog 30 tokens (if (eq kind 'timer) :island-focus :island-accent)))
         ;; Friendly subtitle
         (when-let* ((sub (plist-get act :subtitle)))
           (unless (string-empty-p sub)
             (etaf-node 'text (list :color muted)
                        (list (etaf-island--truncate sub 30)))))
         ;; Bottom single-row actions + open
         (when (or actions open-fn)
           (etaf-node
            'flex (list :width 'stretch :justify-content 'space-between
                        :align-items 'center :gap '((lh 0) (ch 1))
                        :padding '((lh 1) (ch 0) (lh 0) (ch 0)))
            (delq
             nil
             (list
              (etaf-node
               'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
               (mapcar (lambda (a)
                         (etaf-island--btn
                          (plist-get a :label)
                          (plist-get a :fn)
                          (if (plist-get a :primary) 'ctrl 'ghost)
                          tokens nil t))
                       actions))
              (when open-fn
                (etaf-node
                 'box (list :flex-shrink 0 :padding '((lh 0) (ch 1))
                            :pointer 'hand :role 'button :tab-index 0
                            :hover-style (list :background-color (plist-get tokens :island-hover))
                            :on-press (lambda ()
                                        (when (functionp on-open-after) (funcall on-open-after))
                                        (etaf-island--safe-call open-fn)))
                 (list (etaf-node 'text (list :color accent) '("打开 ↗"))))))))))))))))

(defun etaf-island--summary-cell (act first-p selected-p tokens &optional on-open-after)
  "Render one keyboard-selectable cell in the bottom `inbox' / `schedule' strip."
  (let* ((kind (plist-get act :kind))
         (tfg (if (eq kind 'inbox) (plist-get tokens :island-warn)
                (plist-get tokens :island-accent)))
         (fg (plist-get tokens :island-fg))
         (dim (plist-get tokens :island-dim))
         (open-fn (plist-get act :open))
         (bg (when selected-p (plist-get tokens :island-card-selected))))
    (etaf-node
     'flex
     (append
      (list :key (plist-get act :id) :flex-grow 1 :flex-shrink 1
            :padding '((lh 1) (ch 1)) :gap '((lh 0) (ch 1)))
      (when bg (list :background-color bg))
      (unless first-p
        (list :border-left (list '(px 1) 'solid (plist-get tokens :island-border-soft))))
      (when open-fn
        (list :pointer 'hand
              :help-echo "点击或按 RET / o 打开所属应用"
              :on-press (lambda ()
                          (when (functionp on-open-after) (funcall on-open-after))
                          (etaf-island--safe-call open-fn)))))
     (list
      (etaf-island--selection-bar selected-p tokens)
      (etaf-node
       'column (list :flex-grow 1 :flex-shrink 1
                     :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                     :item-gap '(lh 0))
       (delq
        nil
        (list
         (etaf-node
          'flex (list :width 'stretch :justify-content 'space-between
                      :align-items 'center :gap '((lh 0) (ch 1)))
          (list
           (etaf-node
            'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
            (list (etaf-node 'text (list :color tfg)
                             (list (or (plist-get act :icon)
                                       (if (eq kind 'inbox) "◆" "◷"))))
                  (etaf-node 'text (list :color fg :font-weight 'bold)
                             (list (etaf-island--truncate (plist-get act :title) 20)))))
           (when-let* ((cmp (plist-get act :compact)))
             (etaf-node 'text (list :color tfg)
                        (list (etaf-island--truncate cmp 14))))))
         (when-let* ((sub (plist-get act :subtitle)))
           (unless (string-empty-p sub)
             (etaf-node 'text (list :color dim)
                        (list (etaf-island--truncate sub 32))))))))))))

(defun etaf-island--activities-pane (session activities sel-idx meter-tick tokens &optional on-open-after)
  "Render Tab 1 (`实时活动') purely from live ACTIVITIES with keyboard selection."
  (if (null activities)
      (etaf-node
       'column (list :width 'stretch :padding '((lh 2) (ch 2))
                     :cross-align 'center :item-gap '(lh 1))
       (list
        (etaf-view
         (etaf-empty :title "当前无进行中的实时活动"
                     :description "打开网易云、番茄钟、日程、Telegram 或开始编译后将自动同步到这里。"))
        (etaf-island--btn
         "前往快捷入口 →"
         (lambda () (etaf-island-select-tab session 'quick))
         'ctrl tokens)))
    (let* ((part (etaf-island--partition-activities activities))
           (medias (plist-get part :medias))
           (mids (plist-get part :mids))
           (sums (plist-get part :summaries))
           (ordered (plist-get part :ordered))
           (overflow (plist-get part :overflow))
           (clamped (etaf-island--clamp-index sel-idx (length ordered)))
           (sel-id (plist-get (nth clamped ordered) :id))
           (dim (plist-get tokens :island-dim)))
      (etaf-node
       'column (list :width 'stretch :padding '((lh 1) (ch 0)) :item-gap '(lh 1))
       (delq
        nil
        (append
         (mapcar (lambda (m)
                   (etaf-island--media-card
                    m meter-tick (equal (plist-get m :id) sel-id) tokens on-open-after))
                 medias)
         (when mids
           (cl-loop for i from 0 below (length mids) by 2
                    collect
                    (etaf-node
                     'flex (list :width 'stretch :align-items 'stretch :gap '((lh 0) (ch 2)))
                     (mapcar (lambda (a)
                               (etaf-island--compact-activity-card
                                a (equal (plist-get a :id) sel-id) tokens on-open-after))
                             (cl-subseq mids i (min (+ i 2) (length mids)))))))
         (when sums
           (list
            (etaf-node
             'flex (list :width 'stretch
                         :background-color (plist-get tokens :island-card)
                         :border (list '(px 1) 'solid (plist-get tokens :island-border-soft)))
             (cl-loop for s in sums
                      for idx from 0
                      collect (etaf-island--summary-cell
                               s (= idx 0) (equal (plist-get s :id) sel-id)
                               tokens on-open-after)))))
         (when (> overflow 0)
           (list (etaf-node 'text (list :color dim)
                            (list (format "另有 %d 项后台活动正在运行" overflow)))))))))))

;;;; State D: Expanded Hub — Tab 2 (通知流)

(defun etaf-island--events-pane (session notes sel-idx tokens &optional on-open-after)
  "Render Tab 2 (`通知流') purely from `etaf-notify-ref' with keyboard selection."
  (let ((fg (plist-get tokens :island-fg))
        (muted (plist-get tokens :island-muted))
        (dim (plist-get tokens :island-dim))
        (accent (plist-get tokens :island-accent)))
    (if (null notes)
        (etaf-node
         'column (list :width 'stretch :padding '((lh 2) (ch 2)) :cross-align 'center)
         (list
          (etaf-view
           (etaf-empty :title "暂无未读事件"
                       :description "编译完成、番茄提醒、消息推送与扩展告警会自动汇聚到这里。"))))
      (let* ((shown (etaf-island--visible-notes notes))
             (overflow (max 0 (- (length notes) (length shown))))
             (clamped (etaf-island--clamp-index sel-idx (length shown))))
        (etaf-node
         'column (list :width 'stretch :padding '((lh 1) (ch 0)) :item-gap '(lh 1))
         (delq
          nil
          (append
           (list
            (etaf-node
             'flex (list :width 'stretch :justify-content 'space-between :align-items 'center)
             (list
              (etaf-node 'text (list :color dim)
                         (list (format "共 %d 条事件（同源通知自动合并）" (length notes))))
              (etaf-node
               'box (list :ref 'island-events-clear :flex-shrink 0
                          :padding '((lh 0) (ch 1)) :pointer 'hand :role 'button :tab-index 0
                          :hover-style (list :background-color (plist-get tokens :island-hover))
                          :on-press (lambda () (etaf-island-clear-notifications session)))
               (list (etaf-node 'text (list :color accent) '("清空全部 c")))))))
           (cl-loop
            for note in shown
            for idx from 0
            collect
            (let* ((nid (plist-get note :id))
                   (selected-p (= idx clamped))
                   (vc (etaf-island--variant-colors tokens (plist-get note :variant)))
                   (vfg (nth 0 vc))
                   (vlbl (nth 2 vc))
                   (cnt (or (plist-get note :count) 1))
                   (app-lbl (etaf-island--app-label (plist-get note :app)))
                   (detail (or (plist-get note :detail) ""))
                   (actions (plist-get note :actions))
                   (bg (if selected-p
                           (plist-get tokens :island-card-selected)
                         (plist-get tokens :island-card)))
                   (bdr (if selected-p
                            (plist-get tokens :island-border)
                          (plist-get tokens :island-border-soft))))
              (etaf-node
               'flex
               (list :key nid :width 'stretch
                     :background-color bg
                     :border (list '(px 1) 'solid bdr)
                     :padding '((lh 1) (ch 1))
                     :gap '((lh 0) (ch 1)))
               (list
                (etaf-island--selection-bar selected-p tokens)
                (etaf-node
                 'column (list :flex-grow 1 :flex-shrink 1
                               :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                               :item-gap '(lh 0))
                 (delq
                  nil
                  (list
                   (etaf-node
                    'flex (list :width 'stretch :justify-content 'space-between
                                :align-items 'center :gap '((lh 0) (ch 1)))
                    (list
                     (etaf-node
                      'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                      (delq
                       nil
                       (list
                        (etaf-node 'text (list :color vfg) (list (format "● %s" vlbl)))
                        (etaf-node 'text (list :color fg :font-weight 'bold)
                                   (list (etaf-island--truncate
                                          (or (plist-get note :title) "") 38)))
                        (when (> cnt 1)
                          (etaf-node 'box (list :background-color (plist-get tokens :island-ctrl)
                                                :padding '((lh 0) (ch 1)))
                                     (list (etaf-node 'text (list :color muted)
                                                      (list (format "×%d" cnt)))))))))
                     (etaf-node 'text (list :color dim)
                                (list (if app-lbl
                                          (format "%s · %s" app-lbl (or (plist-get note :time) ""))
                                        (or (plist-get note :time) ""))))))
                   (unless (string-empty-p detail)
                     (etaf-node 'text (list :color muted)
                                (list (etaf-island--truncate detail 62))))
                   (etaf-node
                    'flex (list :width 'stretch :align-items 'center :gap '((lh 0) (ch 1))
                                :padding '((lh 1) (ch 0) (lh 0) (ch 0)))
                    (append
                     (mapcar (lambda (a)
                               (let ((fn (plist-get a :fn)))
                                 (etaf-island--btn
                                  (plist-get a :label)
                                  (lambda ()
                                    (when (functionp on-open-after) (funcall on-open-after))
                                    (etaf-island--safe-call fn)
                                    (etaf-island-dismiss-notification session nid))
                                  (if (plist-get a :primary) 'primary 'ctrl)
                                  tokens nil t)))
                             actions)
                     (list
                      (etaf-island--btn
                       "忽略 d"
                       (lambda () (etaf-island-dismiss-notification session nid))
                       'ghost tokens nil t)))))))))))
           (when (> overflow 0)
             (list (etaf-node 'text (list :color dim)
                              (list (format "另有 %d 条更早事件" overflow))))))))))))

;;;; State D: Expanded Hub — Tab 3 (快捷入口与原生传感器)

(defun etaf-island--toggle-sensor (session sensor-id)
  "Toggle SENSOR-ID (`compile', `org-clock', `auto-hide', `reset-pos')."
  (pcase sensor-id
    ('compile
     (setq etaf-island-sense-compilation (not etaf-island-sense-compilation))
     (setf (etaf-value (plist-get session :sense-compile))
           etaf-island-sense-compilation)
     (unless etaf-island-sense-compilation
       (etaf-activity-remove 'emacs-compile)))
    ('org-clock
     (setq etaf-island-sense-org-clock (not etaf-island-sense-org-clock))
     (setf (etaf-value (plist-get session :sense-org-clock))
           etaf-island-sense-org-clock)
     (etaf-island--sync-org-clock))
    ('auto-hide
     (setq etaf-island-auto-hide-idle (not etaf-island-auto-hide-idle))
     (setf (etaf-value (plist-get session :auto-hide-idle))
           etaf-island-auto-hide-idle))
    ('reset-pos
     (etaf-island-reset-position session))))

(defun etaf-island--quick-pane (session sel-idx tokens &optional on-open-after)
  "Render Tab 3 (`快捷入口') with complete 2x3 launcher grid and sensor rows."
  (let* ((fg (plist-get tokens :island-fg))
         (muted (plist-get tokens :island-muted))
         (dim (plist-get tokens :island-dim))
         (accent (plist-get tokens :island-accent))
         (card (plist-get tokens :island-card))
         (card-sel (plist-get tokens :island-card-selected))
         (bdr (plist-get tokens :island-border))
         (bdr-soft (plist-get tokens :island-border-soft))
         (hover (plist-get tokens :island-hover))
         (launchers etaf-island--core-launchers)
         (lcount (length launchers))
         (total (+ lcount 4))
         (clamped (etaf-island--clamp-index sel-idx total))
         (sense-comp (etaf-value (plist-get session :sense-compile)))
         (sense-clk (etaf-value (plist-get session :sense-org-clock)))
         (auto-hide (etaf-value (plist-get session :auto-hide-idle)))
         (custom-pos (etaf-value (plist-get session :custom-anchor))))
    (etaf-node
     'column (list :width 'stretch :padding '((lh 1) (ch 0)) :item-gap '(lh 1))
     (list
      ;; Section 1: 2x3 Ecosystem Quick Launch Grid
      (etaf-node
       'column (list :width 'stretch :item-gap '(lh 0))
       (list
        (etaf-node 'text (list :color dim)
                   '("快速唤醒（j/k 选中 · RET 直接启动）"))
        (etaf-node
         'column (list :width 'stretch :item-gap '(lh 1)
                       :padding '((lh 0) (ch 0)))
         (cl-loop
          for i from 0 below lcount by 2
          collect
          (etaf-node
           'flex (list :width 'stretch :gap '((lh 0) (ch 2)))
           (cl-loop
            for offset from 0 below 2
            for idx = (+ i offset)
            when (< idx lcount)
            collect
            (let* ((entry (nth idx launchers))
                   (selected-p (= idx clamped))
                   (avail (etaf-island--launcher-available-p entry)))
              (etaf-node
               'flex
               (list :key (plist-get entry :id)
                     :flex-grow 1 :flex-shrink 1
                     :background-color (if selected-p card-sel card)
                     :border (list '(px 1) 'solid (if selected-p bdr bdr-soft))
                     :padding '((lh 0) (ch 1))
                     :gap '((lh 0) (ch 1))
                     :pointer 'hand :role 'button :tab-index 0
                     :help-echo (format "启动 %s（点击或按 RET）" (plist-get entry :title))
                     :on-press (lambda () (etaf-island--launch-app entry on-open-after)))
               (list
                (etaf-island--selection-bar selected-p tokens)
                (etaf-node
                 'column (list :flex-grow 1 :flex-shrink 1 :item-gap '(lh 0))
                 (list
                  (etaf-node 'text (list :color (if avail fg dim) :font-weight 'bold)
                             (list (format "%s %s"
                                           (plist-get entry :icon)
                                           (plist-get entry :title))))
                  (etaf-node 'text (list :color (if avail muted dim))
                             (list (plist-get entry :desc))))))))))))))
      ;; Section 2: Native Emacs Sensors & Behavior Switches
      (etaf-node
       'column (list :width 'stretch :item-gap '(lh 0))
       (list
        (etaf-node 'text (list :color dim) '("Emacs 原生传感器与浮窗行为（RET 切换）"))
        (etaf-node
         'column (list :width 'stretch :background-color card
                       :border (list '(px 1) 'solid bdr-soft)
                       :item-gap '(lh 0))
         (list
          ;; Row 0: Compilation sensor
          (let ((sel (= clamped (+ lcount 0))))
            (etaf-node
             'flex (list :width 'stretch :justify-content 'space-between
                         :align-items 'center :padding '((lh 0) (ch 1))
                         :background-color (if sel card-sel card))
             (list
              (etaf-node 'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                         (list (etaf-island--selection-bar sel tokens)
                               (etaf-node 'text (list :color fg :font-weight 'bold)
                                          '("编译与构建监听"))
                               (etaf-node 'text (list :color dim)
                                          '("编译结束自动脉冲提醒"))))
              (etaf-island--switch
               sense-comp
               (lambda () (etaf-island--toggle-sensor session 'compile))
               tokens))))
          ;; Row 1: Org Clock sensor
          (let ((sel (= clamped (+ lcount 1))))
            (etaf-node
             'flex (list :width 'stretch :justify-content 'space-between
                         :align-items 'center :padding '((lh 0) (ch 1))
                         :background-color (if sel card-sel card)
                         :border-top (list '(px 1) 'solid bdr-soft))
             (list
              (etaf-node 'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                         (list (etaf-island--selection-bar sel tokens)
                               (etaf-node 'text (list :color fg :font-weight 'bold)
                                          '("Org Clock 计时"))
                               (etaf-node 'text (list :color dim)
                                          '("Org 计时自动同步上岛"))))
              (etaf-island--switch
               sense-clk
               (lambda () (etaf-island--toggle-sensor session 'org-clock))
               tokens))))
          ;; Row 2: Auto-hide when idle
          (let ((sel (= clamped (+ lcount 2))))
            (etaf-node
             'flex (list :width 'stretch :justify-content 'space-between
                         :align-items 'center :padding '((lh 0) (ch 1))
                         :background-color (if sel card-sel card)
                         :border-top (list '(px 1) 'solid bdr-soft))
             (list
              (etaf-node 'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                         (list (etaf-island--selection-bar sel tokens)
                               (etaf-node 'text (list :color fg :font-weight 'bold)
                                          '("空闲自动隐藏"))
                               (etaf-node 'text (list :color dim)
                                          '("无活动无未读时自动收起"))))
              (etaf-island--switch
               auto-hide
               (lambda () (etaf-island--toggle-sensor session 'auto-hide))
               tokens))))
          ;; Row 3: Floating position & reset
          (let ((sel (= clamped (+ lcount 3))))
            (etaf-node
             'flex (list :width 'stretch :justify-content 'space-between
                         :align-items 'center :padding '((lh 0) (ch 1))
                         :background-color (if sel card-sel card)
                         :border-top (list '(px 1) 'solid bdr-soft))
             (list
              (etaf-node 'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                         (list (etaf-island--selection-bar sel tokens)
                               (etaf-node 'text (list :color fg :font-weight 'bold)
                                          '("浮窗位置"))
                               (etaf-node 'text (list :color dim)
                                          (list (if custom-pos
                                                    "已拖动至自定义位置 · 按 0 回到顶部居中"
                                                  "顶部居中 · 按住顶栏可任意拖动")))))
              (etaf-node
               'box (list :flex-shrink 0 :padding '((lh 0) (ch 1))
                          :pointer 'hand :role 'button :tab-index 0
                          :hover-style (list :background-color hover)
                          :on-press (lambda () (etaf-island-reset-position session)))
               (list (etaf-node 'text (list :color accent) '("居中复位 0")))))))))))))))

;;;; Root Component (Demand-driven ticking, zero idle repaints)

(etaf-define-component etaf-island--root (&key session keys on-dismiss on-direction on-open-after standalone)
  "Root Component of ETAF Island consuming ETAF activity and notify refs."
  :bindings
  ((meter-tick (etaf-ref 0 :name 'island-meter-tick))
   (clock-str (etaf-ref (format-time-string "%H:%M") :name 'island-clock))
   (tokens (etaf-computed
            (lambda ()
              (etaf-value etaf-island--theme-epoch)
              (etaf-island--tokens
               (etaf-value (plist-get session :appearance)))))))
  :setup
  (progn
    (etaf-theme-provide tokens)
    ;; Demand-driven tick: ONLY mutates refs when an active activity has a live
    ;; `:meter' or when the minute string changes — zero idle repaints!
    (etaf-animation-tick
     (lambda (_dt _elapsed)
       (let ((acts (etaf-untracked (etaf-value (etaf-activity-ref))))
             (now-hhmm (format-time-string "%H:%M")))
         (unless (equal now-hhmm (etaf-untracked (etaf-value clock-str)))
           (setf (etaf-value clock-str) now-hhmm))
         (when (cl-some (lambda (a)
                          (and (eq (plist-get a :state) 'active)
                               (functionp (plist-get a :meter))))
                        acts)
           (setf (etaf-value meter-tick)
                 (1+ (etaf-untracked (etaf-value meter-tick)))))))
     :interval 0.14 :name 'island-demand-tick))
  :render
  (let* ((mode (etaf-value (plist-get session :mode)))
         (tab (etaf-value (plist-get session :tab)))
         (sel-idx (etaf-value (plist-get session :selection)))
         (custom-pos (etaf-value (plist-get session :custom-anchor)))
         (activities (etaf-value (etaf-activity-ref)))
         (notes (etaf-value (etaf-notify-ref)))
         (alert (etaf-value (plist-get session :active-alert)))
         (alert-gen (etaf-value (plist-get session :alert-generation)))
         (mtick (etaf-value meter-tick))
         (clk (etaf-value clock-str))
         (tok (etaf-value tokens))
         (floating-p (not standalone))
         (shell-w (pcase mode
                    ('compact (cond ((or (cl-some (lambda (a)
                                                    (not (eq (plist-get a :kind) 'schedule)))
                                                  activities)
                                         notes)
                                     '(ch 72))
                                    (activities '(ch 44))
                                    (t '(ch 28))))
                    ('alert '(ch 70))
                    (_ '(ch 82))))
         (body
          (pcase mode
            ('compact
             (etaf-island--compact-bar-node
              session activities notes clk mtick tok floating-p))
            ('alert
             (if alert
                 (etaf-view
                  (etaf-island--alert-card
                   :key alert-gen :session session :tokens tok :alert alert))
               (etaf-island--compact-bar-node
                session activities notes clk mtick tok floating-p)))
            (_
             ;; Expanded hub with generous 1lh top & bottom outer breathing padding!
             (etaf-node
              'column (list :width 'stretch
                            :padding '((lh 1) (ch 2))
                            :item-gap '(lh 0))
              (list
               ;; Top Header Strip: drag grip + zero-jitter segment tabs + utility controls
               (etaf-node
                'flex (list :class "island-tabs" :width 'stretch
                            :justify-content 'space-between :align-items 'center
                            :padding '((lh 0) (ch 0) (lh 1) (ch 0))
                            :border-bottom (list '(px 1) 'solid
                                                 (plist-get tok :island-border-soft)))
                (list
                 (etaf-node
                  'flex (list :role 'tablist :align-items 'center :gap '((lh 0) (ch 1)))
                  (delq
                   nil
                   (list
                    (etaf-island--drag-grip tok floating-p)
                    (etaf-island--segment-tab
                     (if activities (format "实时活动 %d" (length activities)) "实时活动")
                     (lambda () (etaf-island-select-tab session 'activities))
                     (eq tab 'activities) tok 'island-tab-activities)
                    (etaf-island--segment-tab
                     (if notes (format "通知流 %d" (length notes)) "通知流")
                     (lambda () (etaf-island-select-tab session 'events))
                     (eq tab 'events) tok 'island-tab-events)
                    (etaf-island--segment-tab
                     "快捷入口"
                     (lambda () (etaf-island-select-tab session 'quick))
                     (eq tab 'quick) tok 'island-tab-quick))))
                 (etaf-node
                  'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                  (delq
                   nil
                   (list
                    (etaf-node 'text (list :color (plist-get tok :island-dim)) (list clk))
                    (when (and floating-p custom-pos)
                      (etaf-node
                       'box (list :ref 'island-center-reset :role 'button :tab-index 0
                                  :help-echo "居中复位 (0)"
                                  :padding '((lh 0) (ch 1)) :pointer 'hand
                                  :hover-style (list :background-color (plist-get tok :island-hover))
                                  :on-press (lambda () (etaf-island-reset-position session)))
                       (list (etaf-node 'text (list :color (plist-get tok :island-accent))
                                        '("⌖")))))
                    (etaf-node
                     'box (list :ref 'island-collapse :role 'button :tab-index 0
                                :padding '((lh 0) (ch 1)) :pointer 'hand
                                :background-color (plist-get tok :island-ctrl)
                                :hover-style (list :background-color (plist-get tok :island-hover))
                                :on-press (lambda ()
                                            (if (functionp on-dismiss)
                                                (funcall on-dismiss)
                                              (etaf-island-set-mode session 'compact))))
                     (list (etaf-node 'text (list :color (plist-get tok :island-muted))
                                      '("收起")))))))))
               ;; Active Tab Body
               (pcase tab
                 ('events (etaf-island--events-pane session notes sel-idx tok on-open-after))
                 ('quick (etaf-island--quick-pane session sel-idx tok on-open-after))
                 (_ (etaf-island--activities-pane
                     session activities sel-idx mtick tok on-open-after)))
               ;; Quiet Keyboard Legend Footer (with full 1lh breathing below it!)
               (etaf-node
                'flex (list :width 'stretch :justify-content 'space-between
                            :align-items 'center
                            :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                            :border-top (list '(px 1) 'solid
                                              (plist-get tok :island-border-soft)))
                (list
                 (etaf-node
                  'text (list :color (plist-get tok :island-dim))
                  (list (pcase tab
                          ('events "j/k 选事件 · RET 主动作 · d 忽略 · c 清空 · h/l 切页 · ESC 收起 · q 隐藏")
                          ('quick "j/k 移动 · RET 启动/切换 · t 暗/亮色 · 0 居中 · h/l 切页 · ESC 收起")
                          (_ "j/k 选卡片 · RET 主动作 · SPC 播停 · [/] 切歌 · o 打开 · h/l 切页 · ESC 收起")))))))))))
         (card
          (etaf-node
           'box (append
                 (list :ref 'island-shell
                       :class (format "island-shell is-%s" mode)
                       :width (if standalone (list 'min shell-w '(calc (- (% 100) (ch 2)))) 'stretch)
                       :overflow 'hidden
                       :background-color (plist-get tok :island-surface))
                 (when standalone
                   (list :border (list '(px 1) 'solid (plist-get tok :island-border)))))
           (list body))))
    (if standalone
        (etaf-node
         'column (list :ref 'island-root :width 'stretch :height 'stretch
                       :cross-align 'center :padding '((lh 1) (ch 2))
                       :item-gap '(lh 1)
                       :background-color (plist-get tok :island-bg)
                       :color (plist-get tok :island-fg)
                       :keys keys :on-dismiss on-dismiss :on-direction on-direction
                       :aria-label "ETAF 灵动岛"
                       :help '("j/k 或 ↑/↓ 选择卡片，RET 执行主动作，h/l 或 ←/→ 或 1/2/3 切换页签。"
                               "SPC 暂停/继续或收起，[/] 切歌，o 打开应用，d 忽略通知，c 清空，0 居中，t 切换暗/亮色，ESC 收起，q 隐藏。"))
         (list card))
      (etaf-node
       'box (list :ref 'island-root :width 'stretch
                  :background-color (plist-get tok :island-surface)
                  :color (plist-get tok :island-fg)
                  :on-wheel (lambda (_ev) t)
                  :keys keys :on-dismiss on-dismiss :on-direction on-direction
                  :aria-label "ETAF 灵动岛")
       (list card)))))

(provide 'etaf-island-views)
;;; etaf-island-views.el ends here
