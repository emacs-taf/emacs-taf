;;; -*- lexical-binding: t; -*-
;;; etaf-bili-views.el --- Cover-led library composed from the UI catalog

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Cards, SearchField, Tabs, Badge, Skeleton, Empty, Alert and Drawer own
;; their UI semantics.  Application components arrange them in a bounded
;; cover grid.  Animation belongs to each Component scope and never delays
;; a request or recreates a player.

;;; Code:
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-bili-theme)

(defun etaf-bili--clock (seconds)
  "Format SECONDS without losing an hour prefix."
  (let ((seconds (max 0 (round (or seconds 0)))))
    (if (>= seconds 3600)
        (format "%d:%02d:%02d" (/ seconds 3600) (/ (% seconds 3600) 60) (% seconds 60))
      (format "%02d:%02d" (/ seconds 60) (% seconds 60)))))

(defun etaf-bili--count (value)
  "Format numeric view count VALUE compactly; retain already formatted text."
  (let ((number (if (numberp value) value
                  (and (stringp value) (string-match-p "\\`[0-9]+\\'" value)
                       (string-to-number value)))))
    (cond ((and number (>= number 100000000)) (format "%.1f 亿" (/ number 100000000.0)))
          ((and number (>= number 10000)) (format "%.1f 万" (/ number 10000.0)))
          (number (number-to-string number))
          (t (or value "—")))))

(defun etaf-bili--layout (viewport)
  "Return the content grid for VIEWPORT (pixel width, rows, cell width/height).
At least 64 columns and 28 lines are needed.  Smaller windows clip the same
minimum layout instead of shrinking type or overlapping controls."
  (let* ((cw (or (nth 2 viewport) 7)) (lh (or (nth 3 viewport) 16))
         (pixels (max (* 64 cw) (or (nth 0 viewport) (* 100 cw))))
         (lines (max 28 (or (nth 1 viewport) 36)))
         (budget (- (floor pixels cw) 4))
         (body (- lines 11))
         (target-rows (if (>= body 29) 2 1))
         (row-budget (1- (floor (1+ body) target-rows)))
         ;; A cover keeps its 16:9 shape, so the visible rows bound how wide a
         ;; card is worth drawing.  The fit then adds a column while one more
         ;; still clears a readable card, instead of stopping at a fixed count
         ;; and leaving the deck short on both sides.
         (comfort (max 30 (+ 4 (floor (/ (* (max 5 (- row-budget 6)) lh 16.0)
                                         (* cw 9))))))
         (fit (etaf-fit-columns budget (min 42 comfort) 30))
         (across (plist-get fit :across))
         (card-width (plist-get fit :item))
         (columns (+ (* across card-width) (* 3 (1- across))))
         (cover-columns (- card-width 4))
         (cover-rows (max 5 (ceiling (/ (* cover-columns cw 9.0) (* lh 16)))))
         (card-height (+ cover-rows 6))
         (down (max 1 (floor (1+ body) (1+ card-height)))))
    (list :width pixels :rows lines :columns budget :grid-columns columns :across across
          :left (max 0 (+ (/ (- pixels (* budget cw)) 2)
                          (* (plist-get fit :offset) cw)))
          :card-width card-width :cover-columns cover-columns
          :cover-rows cover-rows :card-height card-height
          :capacity (* across down) :body body :cell-width cw :cell-height lh)))

(etaf-define-component etaf-bili--loading-indicator ()
  "One scoped animation for a pending operation, not a clock per card."
  :bindings ((frame (etaf-animation-frames '("·" "··" "···" "··") :interval 0.18)))
  :view
  (box :width '(ch 4) :height '(lh 1) :color (etaf-bili-color :accent)
    (text :ref 'bili-loading-frame (expr (etaf-value frame)))))

(etaf-define-component etaf-bili--cover (&key file columns rows cell-width cell-height)
  "Contain the decoded FILE at its native aspect, never stretch it to cells.
FILE is a ref holding (:file PATH :size (WIDTH . HEIGHT)); the application
reads dimensions once, outside rendering.  Insets absorb partial image rows."
  :render
  (let* ((source (and file (etaf-value file)))
         (path (and (consp source) (plist-get source :file)))
         (size (and path (plist-get source :size)))
         (ratio (and size (/ (float (car size)) (cdr size))))
         (image-columns (and ratio (max 1 (min columns (floor (/ (* rows cell-height ratio) cell-width))))))
         (image-height (and ratio (max 1 (round (/ (* image-columns cell-width) ratio)))))
         (image-rows (and image-height (ceiling (float image-height) cell-height)))
         (inset (and image-height (cons 0 (- (* image-rows cell-height) image-height)))))
    (etaf-view
     (flex :width (list 'ch columns) :height (list 'lh rows) :overflow 'hidden
           :align-items 'center :justify-content 'center
           :background-color (etaf-bili-color :panel2)
       (image :if path :src path :columns image-columns :rows image-rows :inset inset)
       (etaf-ui-icon :if (not path) :name 'video :set 'svg :min-width 3
                     :color (etaf-bili-color :dim))))))

(etaf-define-component etaf-bili--video-card
    (&key row index selection cover columns image-rows height cell-width cell-height on-play on-select)
  "Compose a cover, title, metadata and a play action on a catalog Card."
  :bindings
  ((selected (etaf-computed (lambda () (= index (etaf-value selection)))))
   (wash (etaf-transition (lambda () (if (etaf-value selected) 1.0 0.0))
                         :duration 0.16 :easing 'ease-out)))
  :view
  (etaf-card :width (list 'ch columns) :height (list 'lh height)
             :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
             :border '((px 0) none) :overflow 'hidden
             :ref (intern (format "bili-card-%d" index))
             :role 'button :tab-index 0
             :aria-label (plist-get row :title)
             :aria-selected (etaf-value selected)
             :on-focus (lambda () (funcall on-select index))
             :on-press (lambda () (funcall on-play index))
             :hover-style (unless (etaf-value selected)
                            (list :background-color (etaf-bili-color :hover)))
             :background-color
             (etaf-animation-interpolate
              (etaf-bili-color :surface) (etaf-bili-color :accent-soft)
              (* 0.125 (round (* 8 (etaf-value wash)))))
    (column :width 'stretch :item-gap '(lh 0)
      (box :position 'relative :height (list 'lh image-rows) :width 'stretch
        (etaf-bili--cover :file cover :columns (- columns 4) :rows image-rows
                          :cell-width cell-width :cell-height cell-height)
        (box :position 'absolute :left '(ch 1) :top (list 'lh (1- image-rows))
          (etaf-badge :text (etaf-bili--clock (plist-get row :duration)) :variant 'neutral)))
      (box :height '(lh 2) :width 'stretch :overflow 'hidden
           :padding-block '(lh 0) :color (etaf-bili-color :ink)
        (text (expr (plist-get row :title))))
      (flex :height '(lh 1) :align-items 'center :justify-content 'space-between
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :overflow 'hidden
          (etaf-label :text (plist-get row :author) :variant 'muted))
        (etaf-label :text (concat (etaf-bili--count (plist-get row :views)) " 播放")
                    :variant 'muted))
      (flex :height '(lh 1) :align-items 'center :justify-content 'space-between
        (etaf-label :text (plist-get row :date) :variant 'muted)
        (etaf-button :label "播放" :variant 'ghost
                     :ref (intern (format "bili-play-%d" index))
                     :aria-selected (etaf-value selected)
                     :on-press (lambda () (funcall on-play index)))))))

(etaf-define-component etaf-bili--skeleton-card (&key columns image-rows height)
  "Reserve the same geometry as a video card while loading."
  :view
  (etaf-card :width (list 'ch columns) :height (list 'lh height)
             :padding '((lh 1) (ch 2)) :border '((px 0) none) :item-gap '(lh 0)
    (column :item-gap '(lh 1)
      (etaf-skeleton :width (list 'ch (- columns 4)) :height (list 'lh image-rows))
      (etaf-skeleton :width (list 'ch (- columns 7)))
      (etaf-skeleton :width (list 'ch (/ columns 2))))))

(etaf-define-component etaf-bili--header
    (&key query account on-account on-submit on-theme width compact)
  "A three-row header with the SearchField and the account chip.
ACCOUNT is the signed-in name or nil; the chip shows it, or asks for a sign-in
when nobody is signed in, and ON-ACCOUNT opens the sign-in panel."
  :view
  (flex :width (list 'ch width) :height '(lh 3) :align-items 'center
        :gap '((lh 0) (ch 3)) :region '(:id search :label "搜索视频" :key "s" :enter bili-search)
    (row :item-gap '(ch 1) :cross-align 'center
      (etaf-ui-icon :name 'video :set 'svg :min-width 2 :color (etaf-bili-color :accent))
      (etaf-label :text "B 站" :variant 'strong))
    (etaf-search-field :ref 'bili-search :bind query :icon t
                       :placeholder "搜索视频、UP 主或关键词"
                       :on-submit on-submit)
    (etaf-button :ref 'bili-account
                 :label (if account (format "账号 %s" account)
                          (if compact "登录" "未登录 · 扫码登录"))
                 :variant (if account 'ghost 'secondary)
                 :aria-label (if account (format "已登录 %s" account) "登录哔哩哔哩")
                 :on-press on-account)
    (etaf-button :ref 'bili-theme :label (if compact "明暗" "切换主题")
                 :variant 'ghost :on-press on-theme)))

(etaf-define-component etaf-bili--navigation
    (&key mode status loading on-mode on-refresh width)
  "Catalog tabs plus live feedback, spaced independently of the header."
  :view
  (flex :width (list 'ch width) :height '(lh 3) :align-items 'center
        :gap '((lh 0) (ch 2))
        :region '(:id navigation :label "频道" :key "n" :enter bili-popular)
    (etaf-tabs :active mode
               :items '((:key popular :label "发现热门" :ref bili-popular)
                        (:key ranking :label "全站排行" :ref bili-ranking)
                        (:key search :label "搜索结果" :ref bili-results))
               :on-change on-mode)
    (box :flex-grow 1 :flex-basis '(ch 0))
    (etaf-bili--loading-indicator :if (etaf-value loading))
    (box :width (list 'ch (min 24 (max 8 (- width 50)))) :height '(lh 1) :overflow 'hidden
      (etaf-label :text (etaf-value status) :variant 'muted))
    (etaf-button :ref 'bili-refresh :label "刷新" :variant 'ghost :on-press on-refresh)))

(provide 'etaf-bili-views)
