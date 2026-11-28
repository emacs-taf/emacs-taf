;;; etaf-video-player-views.el --- Video player presentation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The shell is one ETAF layout: a column that stretches to the viewport,
;; with a responsive body row that adds the playlist and the details pane
;; when the published viewport is wide enough.  Panes flow in their parent
;; instead of being positioned at character offsets, and the canvas Component
;; sits in a stage Host the application measures once per layout change.
;; Playback sources are read by their leaf Host bindings, never by the
;; shell's structural render.
;;
;; Every pane picks its color from the four-step depth scale of
;; `etaf-video-player-theme': the page shell paints `:bg', cards paint
;; `:surface', the header, transport and footer paint `:panel2', and controls
;; paint `:panel3'.  The stage stays `:bg' with a near-black canvas so the
;; letterbox frames the picture in both appearances.

;;; Code:
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-video-player-theme)

(defconst etaf-video-player--sidebar-width '(ch 30)
  "Width of the playlist column.")
(defconst etaf-video-player--sidebar-min-pixels 700
  "Published viewport width from which the playlist column is shown.")
(defconst etaf-video-player--aside-width '(ch 28)
  "Width of the details column.")
(defconst etaf-video-player--aside-min-pixels 1000
  "Published viewport width from which the details column is shown.
The published viewport is logical pixels: 150 character columns measure
about 1040, so this threshold shows the aside from roughly 143 columns.
The playlist threshold (700) shows its column from roughly 100 columns.")
(defconst etaf-video-player--bar-rows 4
  "Rows reserved for the transport panel.")
(defconst etaf-video-player--chrome-rows 6
  "Non-canvas rows: the header, the transport and the hint footer.")

(defconst etaf-video-player--stage-ref 'etaf-video-player-stage
  "Host reference of the video stage, measured after each layout change.")

(defun etaf-video-player--view-value (value)
  "Read a display VALUE or source inside its consuming Host."
  (if (or (etaf-ref-p value) (etaf-computed-p value)) (etaf-value value) value))

(defun etaf-video-player--border (color)
  "Return a one-pixel solid border in COLOR."
  (list '(px 1) 'solid color))

(defun etaf-video-player--hover-surface ()
  "Return the shared hover surface."
  (list :background-color (etaf-video-player-color :hover)))

(etaf-define-component etaf-video-player--view-header
    (&key title status-ref status on-toggle-theme on-help position left top width height)
  "Render the title, the retained status and the header buttons in one row."
  :view
  (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
        :width (or width 'stretch) :height (or height '(lh 1)) :align-items 'center
        :gap '((lh 0) (ch 2)) :padding '((lh 0) (ch 2))
        :background-color (etaf-video-player-color :panel2)
        :border-bottom (etaf-video-player--border (etaf-video-player-color :line))
    (etaf-ui-icon :name 'video :set 'svg :size 0.9 :min-width 2
                  :color (etaf-video-player-color :accent))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :overflow 'hidden
      (text :color (etaf-video-player-color :ink)
        (expr (or title "未选择来源"))))
    (box :height '(lh 1) :font-size 1.0 :color (etaf-video-player-color :muted)
      (text :ref status-ref :id (symbol-name status-ref)
        (expr (etaf-video-player--view-value status))))
    (etaf-button :ref 'video-theme :label "明暗" :variant 'ghost
                 :help-echo "切换明暗主题 (T)" :on-press on-toggle-theme)
    (etaf-button :ref 'video-help :label "?" :variant 'ghost
                 :help-echo "列出全部键位 (?)" :on-press on-help)))

(etaf-define-component etaf-video-player--view-track-row
    (&key position title subtitle duration active on-press)
  "Render one two-line playlist item with a stable full-row target."
  :view
  (flex :position 'relative :width 'stretch :height '(lh 2)
        :align-items 'center :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0 :ref (intern (format "video-track-%d" position))
        :help-echo (format "播放第 %d 个：%s" (1+ position) title)
        :on-press on-press
        :hover-style (unless active (etaf-video-player--hover-surface))
        :background-color (etaf-video-player-color (if active :accent-soft :surface))
    (box :if active :position 'absolute :left '(px 0) :top '(lh 0)
         :width '(px 2) :height '(lh 2) :background-color (etaf-video-player-color :accent))
    (box :width '(ch 2) :height '(lh 1) :text-align 'center
         :color (etaf-video-player-color (if active :accent :dim))
      (text (expr (number-to-string (1+ position)))))
    (flex :flex-direction 'column :height '(lh 2) :min-width '(ch 0)
          :flex-grow 1 :flex-basis '(ch 0)
      (box :height '(lh 1) :overflow 'hidden :font-weight (if active 'bold 'normal)
           :color (etaf-video-player-color (if active :accent :ink))
        (text (expr title)))
      (box :height '(lh 1) :overflow 'hidden :font-size 1.0
           :color (etaf-video-player-color :dim)
        (text (expr subtitle))))
    (box :width '(ch 5) :height '(lh 1) :text-align 'right :font-size 1.0
         :color (etaf-video-player-color :muted)
      (text (expr duration)))))

(etaf-define-component etaf-video-player--view-playlist
    (&key count entries active summary on-press position left top width height)
  "Render the playlist column inside the responsive body row."
  :view
  (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
        :width (or width etaf-video-player--sidebar-width) :height (or height 'stretch)
        :flex-direction 'column :overflow 'hidden
        :background-color (etaf-video-player-color :surface)
        :border-right (etaf-video-player--border (etaf-video-player-color :line))
    (flex :height '(lh 2) :align-items 'center :gap '((lh 0) (ch 1))
          :padding '((lh 0) (ch 2))
      (etaf-ui-icon :name 'sidebar :set 'svg :size 0.9 :min-width 2
                    :color (etaf-video-player-color :muted))
      (box :height '(lh 1) :font-weight 'bold (text "播放列表"))
      (etaf-badge :text (number-to-string count) :variant 'neutral))
    (flex :flex-direction 'column :width 'stretch :flex-shrink 0
      (etaf-video-player--view-track-row :for (entry entries) :key (car entry)
       :position (car entry) :title (plist-get (cdr entry) :title)
       :subtitle (plist-get (cdr entry) :subtitle) :duration (plist-get (cdr entry) :duration)
       :active (= (car entry) active) :on-press (lambda () (funcall on-press (car entry)))))
    (box :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (box :height '(lh 1) :padding '((lh 0) (ch 2)) :font-size 1.0
         :color (etaf-video-player-color :dim)
      (text (expr summary)))))

(etaf-define-component etaf-video-player--view-fact-rows
    (&key rows)
  "Render (LABEL . VALUE) rows with values aligned to the trailing edge."
  :view
  (flex :flex-direction 'column :width 'stretch
    (flex :for (row rows) :key (car row) :height '(lh 1) :align-items 'center
          :justify-content 'space-between
      (box :height '(lh 1)
        (text :color (etaf-video-player-color :muted) (expr (car row))))
      (box :height '(lh 1) :text-align 'right
        (text :color (etaf-video-player-color :ink) (expr (cdr row)))))))

(etaf-define-component etaf-video-player--view-section
    (&key icon title rows)
  "Render a titled group of fact rows under a shared icon."
  :view
  (flex :flex-direction 'column :width 'stretch
    (flex :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
      (etaf-ui-icon :name icon :set 'svg :size 0.9 :min-width 2
                    :color (etaf-video-player-color :muted))
      (box :height '(lh 1) :font-weight 'bold :font-size 1.0
           :color (etaf-video-player-color :muted) (text (expr title))))
    (box :height '(lh 1))
    (etaf-video-player--view-fact-rows :rows rows)))

(etaf-define-component etaf-video-player--view-details
    (&key title source facts playback canvas on-toggle-theme
          position left top width height)
  "Render source information and retained playback settings."
  :view
  (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
        :width (or width etaf-video-player--aside-width) :height (or height 'stretch)
        :flex-direction 'column :overflow 'hidden :padding '((lh 1) (ch 2))
        :background-color (etaf-video-player-color :surface)
        :border-left (etaf-video-player--border (etaf-video-player-color :line))
    (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
      (text (expr title)))
    (box :height '(lh 1) :overflow 'hidden :font-size 1.0
         :color (etaf-video-player-color :muted) (text (expr source)))
    (box :height '(lh 1))
    (etaf-divider)
    (box :height '(lh 1))
    (etaf-video-player--view-section :icon 'info :title "视频信息" :rows facts)
    (box :height '(lh 1))
    (etaf-divider)
    (box :height '(lh 1))
    (etaf-video-player--view-section :icon 'settings :title "播放设置" :rows playback)
    (box :height '(lh 1))
    (etaf-divider)
    (box :height '(lh 1))
    (etaf-video-player--view-section :icon 'image :title "画布" :rows canvas)
    (box :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (etaf-button :ref 'video-theme :label "明暗主题" :variant 'ghost
                 :help-echo "切换明暗配色 (T)" :on-press on-toggle-theme)))

(etaf-define-component etaf-video-player--view-control
    (&key icon label help on-press value ref)
  "Compose a shared SVG icon and optional caption at standard line height."
  :view
  (flex :width 'max-content :height '(lh 1) :align-items 'center
        :gap '((lh 0) (ch 1))
    (etaf-ui-toggle-icon :value (or value nil) :off icon :on icon :set 'svg :size 0.9
                         :min-width 3 :color (etaf-video-player-color :muted)
                         :on-color (etaf-video-player-color :accent)
                         :ref ref :help-echo help :on-press on-press)
    (box :if label :height '(lh 1) :font-size 1.0 :color (etaf-video-player-color :dim)
      (text (expr label)))))

(etaf-define-component etaf-video-player--view-progress
    (&key time-ref duration-ref time duration progress progress-fill-ref on-seek)
  "Render a controlled timeline with leaf-bound clocks and fill."
  :view
  (flex :position 'relative :width 'stretch :height '(lh 1)
        :gap '((lh 0) (ch 2)) :align-items 'center
    (box :width '(ch 6) :height '(lh 1) :text-align 'right :font-size 1.0
         :color (etaf-video-player-color :muted)
      (text :ref time-ref :id (symbol-name time-ref)
        (expr (etaf-video-player--view-value time))))
    (flex :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
      ;; One-pixel rule: a native-style player reads the meter as a hairline
      ;; inside a full-height hit row, not as a slider bar (same as etaf-ncm).
      (etaf-range :min 0 :max 100 :value progress :bar-height 8
                  :fill-ref progress-fill-ref :ref 'etaf-video-player-progress
                  :label "播放进度，点击或拖动跳转"
                  :color (etaf-video-player-color :accent)
                  :track-color (etaf-video-player-color :panel3) :on-commit on-seek))
    (box :width '(ch 6) :height '(lh 1) :text-align 'right :font-size 1.0
         :color (etaf-video-player-color :muted)
      (text :ref duration-ref :id (symbol-name duration-ref)
        (expr (etaf-video-player--view-value duration))))))

(etaf-define-component etaf-video-player--view-transport-buttons
    (&key playing on-toggle on-previous on-next on-forward on-backward compact)
  "Keep transport targets stable in both wide and narrow bars."
  :view
  (flex :height '(lh 1) :width 'stretch :align-items 'center :justify-content 'center
        :gap (if compact '((lh 0) (ch 2)) '((lh 0) (ch 3)))
    (etaf-video-player--view-control :icon 'previous :ref 'video-previous
      :help "上一条 (<)" :on-press on-previous)
    (etaf-video-player--view-control :icon 'chevron-left :ref 'video-backward
      :help "后退五秒 (b)" :on-press on-backward)
    (flex :width '(ch 4) :height '(lh 1) :align-items 'center :justify-content 'center
          :background-color (etaf-video-player-color :accent)
      (etaf-ui-toggle-icon :value playing :off 'play :on 'pause :set 'svg :size 0.9
                           :min-width 4 :color "#FFFFFF" :on-color "#FFFFFF"
                           :ref 'video-play
                           :help-echo "播放 / 暂停 (SPC)" :on-press on-toggle))
    (etaf-video-player--view-control :icon 'chevron-right :ref 'video-forward
      :help "前进五秒 (f)" :on-press on-forward)
    (etaf-video-player--view-control :icon 'next :ref 'video-next
      :help "下一条 (>)" :on-press on-next)))

(etaf-define-component etaf-video-player--view-volume
    (&key audio volume volume-text volume-ref on-toggle-audio on-volume compact)
  "Compose mute, a controlled volume range and its retained percentage."
  :view
  (flex :position 'relative :height '(lh 1) :align-items 'center :justify-content 'end
        :gap '((lh 0) (ch 1))
    (etaf-ui-toggle-icon :value audio :off 'volume-mute :on 'volume
                         :set 'svg :size 0.9 :min-width 3 :ref 'video-audio
                         :color (etaf-video-player-color :muted)
                         :on-color (etaf-video-player-color :muted)
                         :help-echo "声音开关 (a)" :on-press on-toggle-audio)
    (flex :width (if compact '(ch 8) '(ch 12)) :height '(lh 1)
      (etaf-range :min 0 :max 100 :value volume :step 1 :bar-height 8
                  :ref 'etaf-video-player-volume :fill-ref 'video-volume-fill
                  :label "音量，点击或拖动调节"
                  :color (etaf-video-player-color :accent)
                  :track-color (etaf-video-player-color :panel3) :on-commit on-volume))
    (box :width '(ch 4) :height '(lh 1) :text-align 'right :font-size 1.0
         :color (etaf-video-player-color :muted)
      (text :ref volume-ref :id (symbol-name volume-ref)
        (expr volume-text)))))

(etaf-define-component etaf-video-player--view-transport
    (&key playing-ref time duration time-ref duration-ref volume-ref volume-text audio-ref
          progress progress-fill-ref speed loop shuffle volume
          on-toggle on-previous on-next on-forward on-backward on-seek
          on-cycle-speed on-toggle-loop on-toggle-shuffle on-toggle-audio on-volume compact
          position left top width height)
  "Render a fixed-height transport with independently retained controls.
The first row is the timeline: elapsed clock, scrubber, total clock.  The
second row centres the transport targets and parks speed, loop, shuffle and
volume on the trailing edge."
  :view
  (box :position (or position 'relative) :left (or left '(px 0)) :top (or top '(lh 0))
       :width (or width 'stretch) :height (or height (list 'lh etaf-video-player--bar-rows))
       :padding '((lh 1) (ch 3)) :background-color (etaf-video-player-color :panel2)
       :border-top (etaf-video-player--border (etaf-video-player-color :line))
    (flex :flex-direction 'column :height '(lh 2) :width 'stretch :gap '((lh 0) (ch 0))
      (etaf-video-player--view-progress :time time :time-ref time-ref
        :duration duration :duration-ref duration-ref
        :progress progress :progress-fill-ref progress-fill-ref :on-seek on-seek)
      (flex :height '(lh 1) :width 'stretch :align-items 'center
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
        (etaf-video-player--view-transport-buttons :playing playing-ref :compact compact
          :on-toggle on-toggle :on-previous on-previous :on-next on-next
          :on-forward on-forward :on-backward on-backward)
        (flex :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :justify-content 'end :align-items 'center :gap '((lh 0) (ch 2))
          (etaf-button :ref 'video-speed :variant 'ghost
            :label (format "%gx" (etaf-video-player--view-value speed))
            :help-echo "播放速度 (+ / -)" :on-press on-cycle-speed)
          (etaf-ui-toggle-icon :if (not compact)
                               :value (not (eq (etaf-video-player--view-value loop) 'none))
                               :off 'repeat :on (if (eq (etaf-video-player--view-value loop) 'one)
                                                    'repeat-one 'repeat)
                               :set 'svg :size 0.9 :min-width 3 :ref 'video-loop
                               :color (etaf-video-player-color :dim)
                               :on-color (etaf-video-player-color :accent)
                               :help-echo "循环方式 (l)" :on-press on-toggle-loop)
          (etaf-video-player--view-control :if (not compact) :icon 'shuffle
            :value shuffle :ref 'video-shuffle
            :help "随机播放 (s)" :on-press on-toggle-shuffle)
          (etaf-video-player--view-volume :audio audio-ref :volume volume
            :volume-ref volume-ref :volume-text volume-text
            :on-toggle-audio on-toggle-audio :on-volume on-volume :compact compact))))))

(etaf-define-component etaf-video-player--view-footer
    (&key hints position left top width height)
  "Render the fixed bottom hint row."
  :view
  (box :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
       :width (or width 'stretch) :height (or height '(lh 1))
       :text-align 'center :overflow 'hidden :font-size 1.0
       :background-color (etaf-video-player-color :panel2)
       :color (etaf-video-player-color :dim)
    (text (expr hints))))

(provide 'etaf-video-player-views)
;;; etaf-video-player-views.el ends here
