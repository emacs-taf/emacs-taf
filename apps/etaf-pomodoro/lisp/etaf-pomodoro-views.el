;;; etaf-pomodoro-views.el --- Timer surfaces -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The timer paints one compact surface: a fixed four-row body for the clock or
;; the ring, one progress row, the action row, a divider and a footer.  Every
;; style occupies the same rows, so switching style inside a floating panel
;; does not change the panel's size.
;;
;; The surface paints no border and no outer padding of its own beyond one
;; padding cell: the host's frame is the card, and a second border here would
;; make the panel edge look thicker than the panel next to it.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-pomodoro-theme)
(require 'etaf-pomodoro-session)

(declare-function etaf-pomodoro-stop "etaf-pomodoro-app" ())

(defconst etaf-pomodoro--progress-columns 38
  "Columns of the progress line.")

(defun etaf-pomodoro--clock (seconds)
  "Format SECONDS as MM:SS."
  (format "%02d:%02d" (/ seconds 60) (% seconds 60)))

(defun etaf-pomodoro--status (left on)
  "Return the status line for LEFT seconds while ON."
  (format "%s · 剩余 %d 分钟" (if on "专注中" "已暂停") (ceiling left 60)))

(defun etaf-pomodoro--progress-line (fraction)
  "Return a progress line filled FRACTION of the way, one row high."
  (let* ((filled (max 0 (min etaf-pomodoro--progress-columns
                             (round (* etaf-pomodoro--progress-columns fraction)))))
         (rest (- etaf-pomodoro--progress-columns filled)))
    (etaf-view
     (flex :column-gap '(ch 0) :justify-content 'center :align-items 'center
           (text :font-size 0.65 :font-weight 'bold
                 :color (etaf-theme-token :ui-accent)
                 (expr (make-string filled 9473)))
           (text :font-size 0.65
                 :color (etaf-theme-token :ui-disabled-bg)
                 (expr (make-string rest 9472)))))))

(defun etaf-pomodoro--buttons (session)
  "Return the action row for SESSION."
  (etaf-view
   (flex :column-gap '(ch 1) :justify-content 'center :align-items 'center
        (etaf-button
         :label (if (etaf-value (etaf-pomodoro--session-running session))
                    "暂停" "开始")
         :variant 'primary
         :on-press (lambda () (etaf-pomodoro-toggle session)))
        (etaf-button :label "重置" :variant 'ghost
                     :on-press (lambda () (etaf-pomodoro-reset session)))
        (etaf-button :label "+5" :variant 'ghost
                     :on-press (lambda () (etaf-pomodoro-extend session)))
        (etaf-button :label "风格" :variant 'ghost
                     :on-press (lambda () (etaf-pomodoro-next-style session))))))

(defun etaf-pomodoro--ring-image (fraction palette)
  "Return an SVG ring filled FRACTION of the way round in PALETTE."
  (let* ((size 56)
         (center 28)
         (radius 22)
         (circumference (* 2 float-pi radius))
         (filled (* circumference (max 0.0 (min 1.0 fraction)))))
    (etaf-ui-svg-image
     (concat
      (etaf-ui-svg-circle center center radius
                          :fill "none"
                          :stroke (plist-get palette :ui-disabled-bg)
                          :stroke-width 4)
      (etaf-ui-svg-circle center center radius
                          :fill "none"
                          :stroke (plist-get palette :ui-accent)
                          :stroke-width 4
                          :stroke-linecap "round"
                          :stroke-dasharray
                          (format "%.2f %.2f" filled circumference)
                          :transform (format "rotate(-90 %d %d)" center center)))
     size size (list 0 0 size size))))

(defun etaf-pomodoro--minimal-body (left on)
  "Return the minimal style body for LEFT seconds while ON."
  (etaf-view
   (flex :flex-direction 'column :height '(lh 4) :justify-content 'center
         :align-items 'center
           (text :font-size 2 :font-weight 'bold
                 :color (etaf-theme-token :ui-panel-fg)
                 (expr (etaf-pomodoro--clock left)))
           (text :font-size 0.7
                 :color (etaf-theme-token :ui-muted-fg)
                 (expr (etaf-pomodoro--status left on))))))

(defun etaf-pomodoro--ring-body (left on fraction palette)
  "Return the ring style body for LEFT seconds, ON and FRACTION in PALETTE."
  (etaf-view
   (flex :height '(lh 4) :column-gap '(ch 2) :justify-content 'center
         :align-items 'center
        (image :src (etaf-pomodoro--ring-image fraction palette)
               :columns 8 :rows 4)
        (column :item-gap '(lh 0)
                (text :font-size 1.6 :font-weight 'bold
                      :color (etaf-theme-token :ui-panel-fg)
                      (expr (etaf-pomodoro--clock left)))
                (text :font-size 0.7
                      :color (etaf-theme-token :ui-muted-fg)
                      (expr (format "%d%% · %s"
                                    (round (* 100 fraction))
                                    (if on "专注中" "已暂停"))))))))

(defun etaf-pomodoro--card-body (left fraction)
  "Return the card style body for LEFT seconds and FRACTION."
  (etaf-view
   (flex :flex-direction 'column :height '(lh 4) :justify-content 'center
         :align-items 'center
           (flex :flex-direction 'column :padding '((lh 0) (ch 2))
                 :background-color (etaf-theme-token :ui-accent-soft-bg)
                 :border-radius '(px 6)
                 :align-items 'center
                   (flex :column-gap '(ch 1) :align-items 'center
                        (text :font-size 0.7
                              :color (etaf-theme-token :ui-accent)
                              "专注")
                        (text :font-size 1.5 :font-weight 'bold
                              :color (etaf-theme-token :ui-panel-fg)
                              (expr (etaf-pomodoro--clock left))))
                   (text :font-size 0.65
                         :color (etaf-theme-token :ui-muted-fg)
                         (expr (format "%d%%" (round (* 100 fraction)))))))))

(defun etaf-pomodoro--keys (session &optional quit)
  "Return the root keys of SESSION's surface.
The renderer's own map keeps scrolling and closes a floating panel, so these
keys only drive the timer.  QUIT adds `q' for the standalone application
window; a floating panel leaves `q' to the renderer, because a key of the
surface would consume it before the renderer could close the panel."
  (append
   (list (list "p" (lambda () (etaf-pomodoro-toggle session)) "暂停 / 继续")
         (list "r" (lambda () (etaf-pomodoro-reset session)) "重置")
         (list "+" (lambda () (etaf-pomodoro-extend session)) "加 5 分钟")
         (list "t" (lambda () (etaf-pomodoro-next-style session)) "换风格"))
   (when quit
     (list (list "q" (lambda () (interactive) (etaf-pomodoro-stop)) "关闭")))))

(etaf-define-component etaf-pomodoro--root (&key session keys)
  "Render SESSION's timer surface and own its tick.
KEYS become the root Host's keys, so a panel keeps the timer keys while the
renderer's own map keeps scrolling and closing."
  :bindings
  ((remaining (etaf-pomodoro--session-remaining session))
   (total (etaf-pomodoro--session-total session))
   (running (etaf-pomodoro--session-running session))
   (style (etaf-pomodoro--session-style session))
   (theme (etaf-computed
           (lambda () (etaf-pomodoro--tokens (etaf-appearance)))
           :test #'equal)))
  :setup
  (progn
    (etaf-theme-provide theme)
    (etaf-on-mounted (lambda () (etaf-pomodoro--start session)))
    (etaf-on-unmounted (lambda () (etaf-pomodoro-stop-session session))))
  :render
  (let* ((left (etaf-value remaining))
         (total-seconds (max 1 (etaf-value total)))
         (on (etaf-value running))
         (fraction (/ (float left) total-seconds))
         (mode (etaf-value style)))
    (etaf-view
     (flex :justify-content 'center :align-items 'flex-start
           :width 'stretch :height 'stretch
           :bgcolor (etaf-theme-token :ui-panel-bg)
           :keys keys
           :help '("空格键归渲染器，用于滚动；p 暂停、r 重置、+ 加时、t 换风格。"
                   "关闭浮动面板后面板停止计时；独立窗口里 q 关闭窗口。")
           (column :flex-basis '(ch 46) :max-width '(ch 46) :flex-shrink 1
                   :padding '((lh 0) (ch 1))
                   :color (etaf-theme-token :ui-panel-fg)
             (expr (pcase mode
                     ('ring (etaf-pomodoro--ring-body
                             left on fraction (etaf-value theme)))
                     ('card (etaf-pomodoro--card-body left fraction))
                     (_ (etaf-pomodoro--minimal-body left on))))
             (expr (etaf-pomodoro--progress-line fraction))
             (expr (etaf-pomodoro--buttons session))
             (etaf-divider)
             (flex :width 'stretch :justify-content 'space-between
                   :align-items 'center
                   (etaf-label :text (format "%d 分钟" (round total-seconds 60))
                               :variant 'muted)
                   (etaf-label :text "p 暂停 · r 重置 · t 风格"
                               :variant 'muted)))))))

(provide 'etaf-pomodoro-views)
;;; etaf-pomodoro-views.el ends here
