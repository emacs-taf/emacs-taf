;;; etaf-bili-views.el --- Gallery views composed from the UI catalog -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure gallery components matching the approved visual design:
;; - Responsive 1-to-4-column bordered cover cards (no duplicate play labels,
;;   bottom-right duration badge, top-left multi-part/resume badge, disciplined
;;   title-only hover preserving child semantic colors)
;; - Header with BV/URL direct search field, truncated account menu chip, theme
;; - Expanded channel tabs (signed-in feeds + public feeds) & context filter bar
;; - Persistent mini-player footer for background audio-only listening
;; - Non-destructive Toast notifications that never wipe the gallery

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-bili-theme)
(require 'etaf-bili-service)

(defun etaf-bili--clock (seconds)
  "Format SECONDS as `MM:SS' or `H:MM:SS'."
  (let ((seconds (max 0 (round (or seconds 0)))))
    (if (>= seconds 3600)
        (format "%d:%02d:%02d" (/ seconds 3600) (/ (% seconds 3600) 60) (% seconds 60))
      (format "%02d:%02d" (/ seconds 60) (% seconds 60)))))

(defun etaf-bili--count (value)
  "Format numeric count VALUE compactly; retain already formatted text."
  (let ((number (if (numberp value) value
                  (and (stringp value) (string-match-p "\\`[0-9]+\\'" value)
                       (string-to-number value)))))
    (cond ((and number (>= number 100000000)) (format "%.1f 亿" (/ number 100000000.0)))
          ((and number (>= number 10000)) (format "%.1f 万" (/ number 10000.0)))
          (number (number-to-string number))
          ((and (stringp value) (not (string-empty-p value))) value)
          (t "—"))))

(defun etaf-bili--truncate (text max-cols)
  "Truncate TEXT to at most MAX-COLS display columns with an ellipsis."
  (let ((str (or text "")))
    (if (<= (string-width str) max-cols)
        str
      (let ((limit (max 1 (1- max-cols)))
            (acc "")
            (w 0)
            (i 0)
            (len (length str)))
        (while (and (< i len)
                    (let ((cw (char-width (aref str i))))
                      (<= (+ w cw) limit)))
          (setq w (+ w (char-width (aref str i)))
                acc (concat acc (substring str i (1+ i)))
                i (1+ i)))
        (concat acc "…")))))

(defun etaf-bili--border (color)
  "Return a 1-pixel solid border spec in COLOR."
  (list '(px 1) 'solid color))

(defun etaf-bili--layout (viewport &optional has-filter)
  "Return the content grid for VIEWPORT (pixel width, rows, cell width/height).
At least 64 columns and 28 lines are needed.  HAS-FILTER reserves two extra
rows for the secondary ranking/search/fav filter strip and its breathing gap."
  (let* ((cw (or (nth 2 viewport) 7))
         (lh (or (nth 3 viewport) 16))
         (pixels (max (* 64 cw) (or (nth 0 viewport) (* 100 cw))))
         (lines (max 28 (or (nth 1 viewport) 36)))
         (budget (- (floor pixels cw) 4))
         ;; Top air (1) + Header (3) + Nav (1) + Gap (1) + Footer (3) = 9;
         ;; optional Filter (1) + Gap (1) = +2.
         (chrome (+ 9 (if has-filter 2 0)))
         (body (max 12 (- lines chrome)))
         (target-rows (if (>= body 29) 2 1))
         (row-budget (1- (floor (1+ body) target-rows)))
         (comfort (max 30 (floor (/ (* (max 5 (- row-budget 5)) lh 16.0)
                                    (* cw 9)))))
         (fit (etaf-fit-columns budget (min 46 comfort) 30))
         (across (plist-get fit :across))
         (card-width (plist-get fit :item))
         (columns (+ (* across card-width) (* 3 (1- across))))
         ;; Full-bleed top cover fills the card width cleanly.
         (cover-columns card-width)
         (max-cover-rows (max 5 (- body 6)))
         (cover-rows (min max-cover-rows
                          (max 5 (ceiling (/ (* cover-columns cw 9.0) (* lh 16))))))
         (card-height (+ cover-rows 5))
         (down (max 1 (floor (1+ body) (1+ card-height)))))
    (list :width pixels :rows lines :raw-rows (or (nth 1 viewport) lines)
          :columns budget :grid-columns columns :across across
          :left (max 0 (+ (/ (- pixels (* budget cw)) 2)
                          (* (plist-get fit :offset) cw)))
          :card-width card-width :cover-columns cover-columns
          :cover-rows cover-rows :card-height card-height
          :capacity (* across down) :body body :cell-width cw :cell-height lh
          :has-filter (and has-filter t))))

(etaf-define-component etaf-bili--loading-indicator ()
  "One scoped animation for a pending operation, not a clock per card."
  :bindings ((frame (etaf-animation-frames '("·" "··" "···" "··") :interval 0.18)))
  :view
  (box :width '(ch 4) :height '(lh 1) :color (etaf-bili-color :accent)
    (text :ref 'bili-loading-frame (expr (etaf-value frame)))))

(etaf-define-component etaf-bili--cover (&key file columns rows cell-width cell-height)
  "Contain the decoded FILE at its native aspect, never stretch it to cells."
  :render
  (let* ((source (and file (etaf-value file)))
         (path (and (consp source) (plist-get source :file)))
         (size (and path (plist-get source :size)))
         (ratio (and size (> (cdr size) 0) (/ (float (car size)) (cdr size))))
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
    (&key row index selection cover resume-sec columns image-rows height
          cell-width cell-height on-play on-select on-author)
  "Full-bleed top cover card with airy padded info footer.
Follows strict hover discipline: no container-wide hover over nested badges
or mixed-color children; subtle foreground hover sits only on the title and
clickable author name."
  :bindings
  ((selected (etaf-computed (lambda () (= index (etaf-value selection)))))
   (wash (etaf-transition (lambda () (if (etaf-value selected) 1.0 0.0))
                          :duration 0.16 :easing 'ease-out)))
  :render
  (let* ((is-sel (etaf-value selected))
         (dur-str (etaf-bili--clock (plist-get row :duration)))
         (dur-w (+ (string-width dur-str) 2))
         (cov-w columns)
         (parts (plist-get row :videos))
         (is-resume (and (numberp resume-sec) (> resume-sec 5)))
         (badge-text (cond
                      (is-resume
                       (format "续播 %s" (etaf-bili--clock resume-sec)))
                      ((and (numberp parts) (> parts 1))
                       (format "%dP" parts))
                      ((plist-get row :rcmd-reason)
                       (etaf-bili--truncate (plist-get row :rcmd-reason) 10))
                      (t nil)))
         (date-str (or (plist-get row :date) ""))
         (short-date (if (>= (length date-str) 10) (substring date-str 5 10) date-str))
         (meta-right (if (string-empty-p short-date)
                         (etaf-bili--count (plist-get row :views))
                       (format "%s · %s"
                               (etaf-bili--count (plist-get row :views))
                               short-date)))
         (mid (plist-get row :mid))
         (author (or (plist-get row :author) ""))
         (bg (etaf-animation-interpolate
              (etaf-bili-color :surface) (etaf-bili-color :accent-soft)
              (* 0.125 (round (* 8 (etaf-value wash)))))))
    (etaf-view
     (column :width (list 'ch columns) :height (list 'lh height)
             :padding '((lh 0) (ch 0)) :item-gap '(lh 0)
             :border (etaf-bili--border (etaf-bili-color (if is-sel :accent :line)))
             :background-color bg :overflow 'hidden
             :ref (intern (format "bili-card-%d" index))
             :role 'button :tab-index 0
             :aria-label (plist-get row :title)
             :aria-selected is-sel
             :on-focus (lambda () (funcall on-select index))
             :on-press (lambda () (funcall on-play index))
       ;; Full-bleed cover stage
       (box :position 'relative :height (list 'lh image-rows) :width 'stretch
         (etaf-bili--cover :file cover :columns cov-w :rows image-rows
                           :cell-width cell-width :cell-height cell-height)
         (box :if badge-text :position 'absolute :left '(ch 1) :top '(lh 0)
              :background-color (if is-resume (etaf-bili-color :accent) "#111620")
              :color "#FFFFFF"
              :padding '((lh 0) (ch 1)) :height '(lh 1)
           (text :font-weight 'bold (expr badge-text)))
         (box :position 'absolute :left (list 'ch (max 0 (- cov-w dur-w 1)))
              :top (list 'lh (1- image-rows))
              :background-color "#111620" :color "#F4F7FC"
              :padding '((lh 0) (ch 1)) :height '(lh 1)
           (text (expr dur-str))))
       ;; Padded text footer: 1 full row of air above title & below metadata
       (column :width 'stretch :height '(lh 5)
               :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
         (box :height '(lh 2) :width 'stretch :overflow 'hidden
              :color (etaf-bili-color :ink)
              :font-weight (if is-sel 'bold 'normal)
              :pointer (unless is-sel 'hand)
              :hover-style (unless is-sel (list :color (etaf-bili-color :accent)))
           (text (expr (plist-get row :title))))
         (flex :height '(lh 1) :width 'stretch :align-items 'center
               :justify-content 'space-between :gap '((lh 0) (ch 1))
           (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :overflow 'hidden
                :wrap-mode 'none
                :color (etaf-bili-color (if is-sel :accent :muted))
                :pointer (when (and mid (> mid 0) on-author) 'hand)
                :hover-style (when (and mid (> mid 0) on-author)
                               (list :color (etaf-bili-color :accent)))
                :help-echo (when (and mid (> mid 0)) (format "查看 UP %s 的投稿" author))
                :on-press (when (and mid (> mid 0) on-author)
                            (lambda () (funcall on-author mid author)))
             (text (expr author)))
           (box :flex-shrink 0 :height '(lh 1) :color (etaf-bili-color :dim)
             (text (expr meta-right)))))))))

(etaf-define-component etaf-bili--skeleton-card (&key columns image-rows height)
  "Reserve the exact same full-bleed card geometry while loading."
  :view
  (column :width (list 'ch columns) :height (list 'lh height)
          :padding '((lh 0) (ch 0)) :item-gap '(lh 0)
          :border (etaf-bili--border (etaf-bili-color :line))
          :background-color (etaf-bili-color :surface) :overflow 'hidden
    (etaf-skeleton :width (list 'ch columns) :height (list 'lh image-rows))
    (column :width 'stretch :height '(lh 5) :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
      (etaf-skeleton :width (list 'ch (max 8 (- columns 6))))
      (etaf-skeleton :width (list 'ch (max 6 (/ columns 2)))))))

(etaf-define-component etaf-bili--header
    (&key query account on-account on-submit on-theme width compact)
  "Header row with SearchField (keywords or BV/URL), account chip and theme."
  :view
  (let ((acc-label (if account
                       (format "● %s ▾" (etaf-bili--truncate account (if compact 8 12)))
                     (if compact "登录" "未登录 · 扫码登录"))))
    (flex :width (list 'ch width) :height '(lh 3) :align-items 'center
          :gap '((lh 0) (ch 2))
          :region '(:id search :label "搜索视频" :key "s" :enter bili-search)
      (row :item-gap '(ch 1) :cross-align 'center :flex-shrink 0
        (etaf-ui-icon :name 'video :set 'svg :min-width 2 :color (etaf-bili-color :accent))
        (etaf-label :text "B 站" :variant 'strong))
      (etaf-search-field :ref 'bili-search :bind query :icon t
                         :placeholder (if compact
                                          "搜索视频或粘贴 BV 号 (/)"
                                        "搜索视频、UP 主，或直接粘贴 BV 号 / 链接直达播放 (/)")
                         :on-submit on-submit)
      (etaf-button :ref 'bili-account
                   :label acc-label
                   :variant (if account 'ghost 'secondary)
                   :aria-label (if account (format "账号菜单 %s" account) "登录哔哩哔哩")
                   :on-press on-account)
      (etaf-button :ref 'bili-theme :label (if compact "明暗" "切换主题")
                   :variant 'ghost :on-press on-theme))))

(etaf-define-component etaf-bili--navigation
    (&key mode status loading play-loading account on-mode on-refresh width compact)
  "Borderless pill channel strip aligned flush with the card grid."
  :render
  (let* ((active-mode (etaf-value mode))
         (busy (or (etaf-value loading) (etaf-value play-loading)))
         (items (if account
                    (if compact
                        '((:key rcmd :label "推荐" :ref bili-rcmd)
                          (:key popular :label "热门" :ref bili-popular)
                          (:key ranking :label "排行" :ref bili-ranking)
                          (:key dynamic :label "动态" :ref bili-dynamic)
                          (:key toview :label "稍后" :ref bili-toview)
                          (:key history :label "历史" :ref bili-history)
                          (:key fav :label "收藏" :ref bili-fav)
                          (:key search :label "搜索" :ref bili-results))
                      '((:key rcmd :label "推荐" :ref bili-rcmd)
                        (:key popular :label "热门" :ref bili-popular)
                        (:key ranking :label "排行" :ref bili-ranking)
                        (:key dynamic :label "动态" :ref bili-dynamic)
                        (:key toview :label "稍后再看" :ref bili-toview)
                        (:key history :label "历史" :ref bili-history)
                        (:key fav :label "收藏" :ref bili-fav)
                        (:key search :label "搜索结果" :ref bili-results)))
                  '((:key popular :label "发现热门" :ref bili-popular)
                    (:key ranking :label "全站排行" :ref bili-ranking)
                    (:key search :label "搜索结果" :ref bili-results))))
         (status-full (or (etaf-value status) ""))
         (status-w (max 10 (min 28 (- width (if account (if compact 46 68) 44)))))
         (status-shown (etaf-bili--truncate status-full status-w)))
    (etaf-node
     'flex
     (list :width (list 'ch width) :height '(lh 1) :align-items 'center
           :gap '((lh 0) (ch 2))
           :region '(:id navigation :label "频道" :key "n" :enter bili-popular))
     (list
      (etaf-node
       'row (list :role 'tablist :focus-group 'horizontal :item-gap '(ch 1))
       (mapcar
        (lambda (item)
          (let* ((key (plist-get item :key))
                 (lbl (plist-get item :label))
                 (ref (plist-get item :ref))
                 (sel (equal key active-mode)))
            (etaf-node
             'box
             (append
              (list :role 'tab :tab-index 0 :height '(lh 1)
                    :padding '((lh 0) (ch 1))
                    :color (etaf-bili-color (if sel :accent :muted))
                    :font-weight (if sel 'bold 'normal)
                    :background-color (when sel (etaf-bili-color :accent-soft))
                    :pointer (unless sel 'hand)
                    :hover-style (unless sel
                                   (list :color (etaf-bili-color :ink)
                                         :background-color (etaf-bili-color :hover)))
                    :aria-selected sel
                    :aria-label lbl
                    :on-press (lambda () (funcall on-mode key)))
              (when ref (list :ref ref)))
             (list (etaf-node 'text nil (list lbl))))))
        items))
      (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0)) nil)
      (when busy (etaf-node 'etaf-bili--loading-indicator nil nil))
      (etaf-node 'box (list :height '(lh 1) :flex-shrink 0 :help-echo status-full
                            :color (etaf-bili-color :dim))
                 (list (etaf-node 'text nil (list status-shown))))
      (etaf-node 'etaf-button
                 (list :ref 'bili-refresh :label "刷新" :variant 'ghost
                       :on-press on-refresh)
                 nil)))))

(etaf-define-component etaf-bili--filter-bar
    (&key mode ranking-rid search-order fav-folders fav-folder-id space-name
          width on-rid on-order on-fav-folder on-leave-space)
  "Borderless 1-row filter pill strip aligned flush with the card grid."
  :view
  (let ((cur-mode (etaf-value mode)))
    (cond
     ((eq cur-mode 'ranking)
      (let ((active-rid (etaf-value ranking-rid)))
        (flex :width (list 'ch width) :height '(lh 1) :align-items 'center
              :gap '((lh 0) (ch 1))
          (text :color (etaf-bili-color :dim) "分区：")
          (box :for (pair etaf-bili-ranking-partitions) :key (car pair)
               :height '(lh 1) :padding '((lh 0) (ch 1))
               :role 'button :tab-index 0
               :color (etaf-bili-color (if (= (car pair) active-rid) :accent :muted))
               :font-weight (if (= (car pair) active-rid) 'bold 'normal)
               :background-color (when (= (car pair) active-rid) (etaf-bili-color :accent-soft))
               :pointer (unless (= (car pair) active-rid) 'hand)
               :hover-style (unless (= (car pair) active-rid)
                              (list :color (etaf-bili-color :ink)
                                    :background-color (etaf-bili-color :hover)))
               :on-press (let ((rid (car pair)))
                           (lambda () (funcall on-rid rid)))
            (text (cdr pair))))))
     ((eq cur-mode 'search)
      (let ((active-ord (etaf-value search-order)))
        (flex :width (list 'ch width) :height '(lh 1) :align-items 'center
              :gap '((lh 0) (ch 1))
          (text :color (etaf-bili-color :dim) "排序：")
          (box :for (pair etaf-bili-search-orders) :key (car pair)
               :height '(lh 1) :padding '((lh 0) (ch 1))
               :role 'button :tab-index 0
               :color (etaf-bili-color (if (equal (car pair) active-ord) :accent :muted))
               :font-weight (if (equal (car pair) active-ord) 'bold 'normal)
               :background-color (when (equal (car pair) active-ord) (etaf-bili-color :accent-soft))
               :pointer (unless (equal (car pair) active-ord) 'hand)
               :hover-style (unless (equal (car pair) active-ord)
                              (list :color (etaf-bili-color :ink)
                                    :background-color (etaf-bili-color :hover)))
               :on-press (let ((ord (car pair)))
                           (lambda () (funcall on-order ord)))
            (text (cdr pair))))))
     ((eq cur-mode 'fav)
      (let ((folders (etaf-value fav-folders))
            (active-id (etaf-value fav-folder-id)))
        (when folders
          (flex :width (list 'ch width) :height '(lh 1) :align-items 'center
                :gap '((lh 0) (ch 1))
            (text :color (etaf-bili-color :dim) "收藏夹：")
            (box :for (f (seq-take folders 5)) :key (plist-get f :id)
                 :height '(lh 1) :padding '((lh 0) (ch 1))
                 :role 'button :tab-index 0
                 :color (etaf-bili-color (if (equal (plist-get f :id) active-id) :accent :muted))
                 :font-weight (if (equal (plist-get f :id) active-id) 'bold 'normal)
                 :background-color (when (equal (plist-get f :id) active-id)
                                     (etaf-bili-color :accent-soft))
                 :pointer (unless (equal (plist-get f :id) active-id) 'hand)
                 :hover-style (unless (equal (plist-get f :id) active-id)
                                (list :color (etaf-bili-color :ink)
                                      :background-color (etaf-bili-color :hover)))
                 :on-press (let ((fid (plist-get f :id)))
                             (lambda () (funcall on-fav-folder fid)))
              (text (format "%s (%d)"
                            (etaf-bili--truncate (plist-get f :title) 12)
                            (or (plist-get f :count) 0))))))))
     ((eq cur-mode 'space)
      (flex :width (list 'ch width) :height '(lh 1) :align-items 'center
            :gap '((lh 0) (ch 2))
        (etaf-button :label "← 返回列表" :variant 'ghost :on-press on-leave-space)
        (text :color (etaf-bili-color :accent) :font-weight 'bold
          (format "UP 主空间：%s" (or space-name ""))))))))

(etaf-define-component etaf-bili--toast-banner
    (&key toast ui-store width height center bottom-offset on-dismiss)
  "Non-destructive calm floating toast capsule centered inside WIDTH."
  :view
  (let ((data (if ui-store
                  (etaf-store-get ui-store :toast)
                (and toast (etaf-value toast)))))
    (when data
      (let* ((kind (plist-get data :kind))
             (msg (etaf-bili--truncate (or (plist-get data :message) "") 44))
             (act-lbl (plist-get data :action-label))
             (act-fn (plist-get data :action-fn))
             (bg (if (eq kind 'error) (etaf-bili-color :danger-bg) (etaf-bili-color :panel2)))
             (bd (if (eq kind 'error) (etaf-bili-color :danger) (etaf-bili-color :line)))
             (fg (if (eq kind 'error) (etaf-bili-color :danger) (etaf-bili-color :accent)))
             (dot (if (eq kind 'error) "!" "●"))
             (area-w (or width 80))
             (toast-w (min (max 20 (- area-w 4))
                           (+ 10 (string-width msg)
                              (if (and act-lbl act-fn) (+ 4 (string-width act-lbl)) 0))))
             (left-ch (if center
                          (max 2 (/ (- area-w toast-w) 2))
                        (max 2 (- area-w toast-w 2))))
             (top-lh (max 1 (- (or height 30) (or bottom-offset 5)))))
        (flex :position 'absolute :left (list 'ch left-ch) :top (list 'lh top-lh)
              :z-index 900 :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
              :padding '((lh 0) (ch 2))
              :background-color bg :border (etaf-bili--border bd)
          (text :color fg :font-weight 'bold dot)
          (text :color (etaf-bili-color :ink) msg)
          (when (and act-lbl act-fn)
            (etaf-button :label act-lbl :variant 'ghost :on-press act-fn))
          (etaf-button :label "×" :variant 'ghost :on-press on-dismiss))))))

(provide 'etaf-bili-views)
;;; etaf-bili-views.el ends here
