;;; etaf-youtube-views.el --- Views of etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Views are pure projections of the model: they read refs, chunk them for the
;; live viewport and return structure.  No network call, storage access or
;; session mutation belongs here; every interaction goes through the public
;; model functions.  The layout adapts to the committed viewport: the sidebar
;; folds on narrow windows, the card grid chooses its column count from the
;; available character columns, and the watch page becomes one column below
;; the two-column breakpoint.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-youtube-theme)
(require 'etaf-youtube-model)

(defvar etaf-youtube-search-ref 'etaf-youtube-search-field
  "Ref of the top bar search field, used by the application's focus key.")

(defvar etaf-youtube-caption-ref 'etaf-youtube-caption
  "Ref of the subtitle band Host above the transport controls.")

;;; ---------------------------------------------------------------------------
;;; Layout helpers
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--display-cell (metrics)
  "Return METRICS's character cell as `(WIDTH . HEIGHT)' in pixels.
A batch or daemon frame can report a degenerate cell; the clamp keeps the
grid readable instead of turning every preview into a column of lines."
  (let ((width (or (and metrics (plist-get metrics :char-width)) 8))
        (height (or (and metrics (plist-get metrics :line-height)) 17)))
    (cons (max 6 (min 24 width))
          (max 12 (min 48 height)))))

(defun etaf-youtube--columns (viewport metrics)
  "Return VIEWPORT's width in character columns using METRICS."
  (let* ((pixels (car-safe viewport))
         (char-width (car (etaf-youtube--display-cell metrics))))
    ;; The upper clamp keeps an unusually wide display or a degenerate frame
    ;; metric from laying the application out at a thousand columns.
    (max 24 (min 320 (floor (/ (or pixels 800) char-width))))))

(defun etaf-youtube--image-rows (columns metrics)
  "Return the 16:9 preview height in rows for COLUMNS character columns.
The result follows the display's real character metrics so a thumbnail keeps
its aspect ratio instead of being squashed."
  (pcase-let* ((`(,char-width . ,line-height) (etaf-youtube--display-cell metrics)))
    (max 4 (min 24 (round (/ (* columns char-width 9.0)
                             (* 16.0 line-height)))))))

(defun etaf-youtube--clip (text width)
  "Return TEXT clipped to WIDTH columns with an ellipsis.
CJK characters count as the two columns they occupy."
  (let ((text (replace-regexp-in-string "[\n\r]+" " " (or text ""))))
    (if (<= (string-width text) width)
        text
      (let ((result "") (index 0))
        (while (and (< index (length text))
                    (< (+ 1 (string-width result)) width))
          (setq result (concat result (char-to-string (aref text index)))
                index (1+ index)))
        (concat (string-trim-right result) "…")))))

(defun etaf-youtube--wrap (text width lines)
  "Return TEXT as at most LINES strings of WIDTH columns.
The last line carries an ellipsis when text is dropped."
  (let ((text (replace-regexp-in-string "[\n\r]+" " " (or text "")))
        (result nil)
        (current "")
        (index 0))
    (while (and (< index (length text)) (< (length result) lines))
      (let* ((char (char-to-string (aref text index)))
             (candidate (concat current char)))
        (if (and (not (string-empty-p current))
                 (> (string-width candidate) width))
            (progn
              (push current result)
              (setq current (if (string= char " ") "" char)))
          (setq current candidate))
        (setq index (1+ index))))
    (when (and (< (length result) lines) (not (string-empty-p current)))
      (push current result))
    (setq result (nreverse result))
    (when (and (< index (length text)) result)
      (setcar (last result) (etaf-youtube--clip (car (last result)) width)))
    result))

(defun etaf-youtube--clip-pixels (text pixels)
  "Return TEXT shortened so it fits PIXELS display pixels.
TEXT is cut on character boundaries and trailing blanks are removed."
  (if (or (string-empty-p text) (<= (etaf-string-pixel-width text) pixels))
      text
    (let ((result "")
          (index 0))
      (while (and (< index (length text))
                  (let ((candidate (concat result (char-to-string (aref text index)))))
                    (<= (etaf-string-pixel-width candidate) pixels)))
        (setq result (concat result (char-to-string (aref text index)))
              index (1+ index)))
      (string-trim-right result))))

(defun etaf-youtube--caption-lines (text pixels &optional lines)
  "Return TEXT as at most LINES subtitle lines fitting PIXELS pixels.
The wrap uses the renderer's own glyph measurement, unlike a column count
that assumes every CJK character occupies two ASCII cells, so a wide CJK
font cannot overflow a band whose height the caller already fixed.  Text
that does not fit ends its last line with an ellipsis."
  (let ((text (replace-regexp-in-string "[\n\r]+" " " (or text "")))
        (lines (or lines 2))
        (result nil)
        (current "")
        (index 0)
        (overflow nil))
    (while (and (< index (length text)) (not overflow))
      (let* ((char (char-to-string (aref text index)))
             (candidate (concat current char)))
        (if (and (not (string-empty-p current))
                 (> (etaf-string-pixel-width candidate) pixels))
            (if (>= (length result) (1- lines))
                (setq overflow t)
              (push current result)
              (setq current (if (string= char " ") "" char)
                    index (1+ index)))
          (setq current candidate
                index (1+ index)))))
    (setq result (nreverse result))
    (if overflow
        (append result
                (list (concat (etaf-youtube--clip-pixels
                               current (- pixels (etaf-string-pixel-width "…")))
                              "…")))
      (if (string-empty-p current) result (append result (list current))))))

(defun etaf-youtube--chunk (items size)
  "Return ITEMS split into lists of at most SIZE."
  (let ((result nil))
    (while items
      (push (seq-take items size) result)
      (setq items (seq-drop items size)))
    (nreverse result)))

(defun etaf-youtube--seconds (value)
  "Return VALUE as a duration in seconds.
VALUE is a number of seconds or a `M:SS' / `H:MM:SS' string, which some
renderer payloads use; anything else is zero."
  (let ((total
         (cond
          ((numberp value) (max 0 (floor value)))
          ((and (stringp value)
                (string-match "\\`\\([0-9]+\\):\\([0-9][0-9]?\\)\\(?::\\([0-9][0-9]?\\)\\)?\\'" value))
           (let ((first (string-to-number (match-string 1 value)))
                 (second (string-to-number (match-string 2 value)))
                 (third (and (match-string 3 value)
                             (string-to-number (match-string 3 value)))))
             (if third (+ (* first 3600) (* second 60) third)
               (+ (* first 60) second))))
          ((and (stringp value)
                (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" value))
           (floor (string-to-number value)))
          (t 0))))
    (if (>= total 3600)
        (format "%d:%02d:%02d" (/ total 3600) (/ (% total 3600) 60) (% total 60))
      (format "%d:%02d" (/ total 60) (% total 60)))))

(defun etaf-youtube--meta-line (item)
  "Return ITEM's author and view line."
  (let ((author (or (plist-get item :author) ""))
        (views (or (plist-get item :views) ""))
        (published (or (plist-get item :published) "")))
    (string-join (seq-remove #'string-empty-p (list author views published)) " · ")))

(defun etaf-youtube--avatar-initials (name)
  "Return NAME's short avatar initials."
  (let ((name (string-trim (or name ""))))
    (if (string-empty-p name)
        "?"
      (upcase (substring name 0 (min 2 (length name)))))))

;;; ---------------------------------------------------------------------------
;;; Shell
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-app (&key model)
  "Render the YouTube application for MODEL and own its lifecycle."
  :bindings ((mode (plist-get model :theme-mode))
             (palette (plist-get model :palette))
             (viewport (etaf-computed (lambda () (etaf-viewport))))
             (metrics (etaf-computed (lambda () (etaf-display-metrics))))
             (route (plist-get model :route))
             (sidebar (plist-get model :sidebar))
             (message (plist-get model :message))
             (colors (etaf-computed
                      (lambda ()
                        (etaf-youtube-colors (etaf-value mode))))))
  :setup
  (progn
    (etaf-theme-provide palette)
    (etaf-on-mounted
     (lambda ()
       (etaf-youtube--start-player-timer model)
       (when (eq 'idle (plist-get (etaf-youtube--read model :feed-status) :state))
         (etaf-youtube-refresh model))))
    (etaf-on-unmounted
     (lambda () (etaf-youtube-destroy model))))
  :render
  (let* ((columns (etaf-youtube--columns (etaf-value viewport)
                                         (etaf-value metrics)))
         (c (etaf-value colors))
         (view (plist-get (etaf-value route) :view))
         (narrow (<= columns 88))
         (sidebar-visible (and (etaf-value sidebar) (> columns 88)))
         (rail-visible (and narrow (etaf-value sidebar)))
         ;; The content views lay out for the box they are rendered into, so
         ;; the rail's six columns (plus its border) come out of `columns'
         ;; exactly like the expanded sidebar's twenty-six.
         (content-columns (- columns (cond (sidebar-visible 26)
                                           (rail-visible 7)
                                           (t 0)))))
    (etaf-view (flex :flex-direction 'column :width '(vw 100) :height '(vh 100)
          :background-color (plist-get c :bg)
          :color (plist-get c :ink)
          :overflow 'hidden
      (etaf-youtube-topbar :model model :colors c :columns columns)
      (flex :flex-direction 'row :flex-grow 1 :flex-basis '(lh 0)
            :min-height '(lh 0)
        (etaf-youtube-sidebar :model model :colors c :columns columns
                              :active sidebar-visible)
        (etaf-youtube-sidebar-rail :model model :colors c
                                   :active rail-visible)
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(px 0)
             :overflow 'scroll
             :ref 'etaf-youtube-content
          (etaf-youtube-watch :if (eq view 'watch)
                              :model model :colors c
                              :columns content-columns)
          (etaf-youtube-list :if (not (eq view 'watch))
                             :model model :colors c
                             :columns content-columns
                             :metrics (etaf-value metrics)))
      (etaf-youtube-toast :if (etaf-value message)
                          :message (etaf-value message)
                          :colors c))))))

(etaf-define-component etaf-youtube-topbar (&key model colors columns)
  "Render the application's brand, search field and account controls."
  :bindings ((query (plist-get model :query))
             (account (plist-get model :account))
             (mode (plist-get model :theme-mode)))
  :view
  (flex :flex-direction 'row :align-items 'center :column-gap '(ch 1)
        :padding (list (list 'lh 1) (list 'ch 2))
        :background-color (plist-get colors :bg)
        :border-bottom (list '(px 1) 'solid (plist-get colors :line))
        :sticky 'top
    (box :role 'button :tab-index 0 :aria-label "切换侧栏"
         :padding-inline '(ch 1)
         :color (plist-get colors :ink)
         :on-press (lambda () (etaf-youtube-toggle-sidebar model))
      (text "☰"))
    (box :role 'link :tab-index 0 :aria-label "首页"
         :padding-inline '(ch 1)
         :on-press (lambda () (etaf-youtube-locate model 'home))
      (flex :flex-direction 'row :align-items 'center :column-gap '(ch 1)
        (text :color (plist-get colors :accent) :font-weight 'bold "▶")
        (text :color (plist-get colors :ink) :font-weight 'bold "YouTube")))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(px 0))
    (etaf-search-field
     :bind query
     :ref etaf-youtube-search-ref
     :placeholder "搜索"
     :icon t
     :width (if (> columns 96) '(ch 48) '(ch 30))
     :on-submit (lambda (text)
                  (etaf-youtube--write model :query (or text ""))
                  (etaf-youtube-search model (or text ""))))
    (box :flex-grow 0)
    (box :role 'button :tab-index 0 :aria-label "切换外观"
         :padding-inline '(ch 1)
         :color (plist-get colors :muted)
         :on-press (lambda () (etaf-youtube-cycle-theme model))
      (text (expr (if (eq (etaf-value mode) 'dark) "日" "夜"))))
    (etaf-youtube-account :account (etaf-value account) :colors colors)))

(etaf-define-component etaf-youtube-account (&key account colors)
  "Render the signed-in account chip, or a sign-in hint."
  :render
  (if (and account (plist-get account :signed_in))
      (etaf-view
       (flex :flex-direction 'row :align-items 'center :column-gap '(ch 1)
         (box :width '(ch 3) :height '(lh 2) :text-align 'center
              :background-color (plist-get colors :accent)
              :color "#FFFFFF" :font-weight 'bold
           (text (expr (etaf-youtube--avatar-initials (plist-get account :name)))))
         (text :color (plist-get colors :ink)
               (expr (etaf-youtube--clip (or (plist-get account :name) "") 14)))))
    (etaf-view
     (box :role 'button :tab-index 0 :padding-inline '(ch 1)
          :color (plist-get colors :link)
          :help-echo "在浏览器中登录 YouTube 后重试"
          :on-press (lambda () (message "运行 pi-skill youtube login 登录"))
       (text "登录")))))

(etaf-define-component etaf-youtube-sidebar (&key model colors columns active)
  "Render the expanded navigation sidebar when ACTIVE."
  :bindings ((route (plist-get model :route)))
  :render
  (let ((current (plist-get (etaf-value route) :view)))
    (etaf-view (flex :flex-direction 'column :width '(ch 24)
          :padding '((lh 1) (ch 2))
          :background-color (plist-get colors :bg)
          :row-gap '(lh 0)
          :border-right (list '(px 1) 'solid (plist-get colors :line))
          :if active
      (etaf-youtube-sidebar-items :model model :colors colors :current current)
      (box :height '(lh 1))
      (text :color (plist-get colors :dim) :font-weight 'bold "你")
      (etaf-youtube-sidebar-items :model model :colors colors :current current
                                  :personal t)))))

(etaf-define-component etaf-youtube-sidebar-rail (&key model colors active)
  "Render the compact icon rail used below the sidebar breakpoint."
  :view
  (flex :flex-direction 'column :width '(ch 6) :align-items 'center
        :padding '((lh 1) (ch 1))
        :background-color (plist-get colors :bg)
        :row-gap '(lh 0)
        :border-right (list '(px 1) 'solid (plist-get colors :line))
        :if active
    (etaf-youtube-rail-button :for (entry '(("⌂" . home) ("⚡" . shorts)
                                            ("☰" . subscriptions)
                                            ("◷" . history) ("≣" . playlists)))
                              :key (cdr entry)
                              :label (car entry)
                              :view (cdr entry)
                              :model model :colors colors)))

(etaf-define-component etaf-youtube-rail-button (&key label view model colors)
  "Render one icon-rail button."
  :view
  (box :role 'button :tab-index 0 :aria-label (symbol-name view)
       :padding '((lh 0) (ch 1))
       :color (plist-get colors :ink)
       :hover-style (list :background-color (plist-get colors :hover))
       :on-press (lambda () (etaf-youtube-locate model view))
    (text (expr label))))

(etaf-define-component etaf-youtube-sidebar-items
    (&key model colors current personal)
  "Render MODEL's navigation entries, PERSONAL for the account lists."
  :view
  (flex :flex-direction 'column :row-gap '(lh 0)
    (etaf-youtube-sidebar-item
     :for (entry (if personal
                     '(("历史" . history) ("播放列表" . playlists)
                       ("稍后观看" . watch-later) ("喜欢的视频" . liked))
                   '(("首页" . home) ("Shorts" . shorts)
                     ("订阅内容" . subscriptions) ("直播" . live))))
     :key (cdr entry)
     :label (car entry)
     :view (cdr entry)
     :current current
     :model model
     :colors colors)))

(etaf-define-component etaf-youtube-sidebar-item
    (&key label view current model colors)
  "Render one navigation entry."
  :render
  (let ((active (eq view current)))
    (etaf-view (box :role 'button :tab-index 0 :aria-label label
         :aria-selected (and active t)
         :padding '((lh 0) (ch 2))
         :background-color (if active (plist-get colors :selected) nil)
         :color (if active (plist-get colors :ink) (plist-get colors :muted))
         :font-weight (if active 'bold 'normal)
         :hover-style (unless active
                        (list :background-color (plist-get colors :hover)))
         :on-press (lambda () (etaf-youtube-locate model view))
      (text (expr label))))))

(etaf-define-component etaf-youtube-toast (&key message colors)
  "Render MESSAGE as a floating status line."
  :render
  (let ((variant (plist-get message :variant)))
    (etaf-view (box :padding '((lh 0) (ch 2))
         :background-color (pcase variant
                             ('danger (plist-get colors :danger-bg))
                             ('success (plist-get colors :ok))
                             (_ (plist-get colors :panel3)))
         :color (if (eq variant 'success) "#FFFFFF" (plist-get colors :ink))
         :position 'absolute :left '(px 2) :top '(lh 1) :z-index 20
      (text (expr (etaf-youtube--clip (or (plist-get message :text) "") 60)))))))

;;; ---------------------------------------------------------------------------
;;; List pages
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-list (&key model colors columns metrics)
  "Render the current feed, search or channel list as a card grid."
  :bindings ((feed (plist-get model :feed))
             (status (plist-get model :feed-status))
             (more (plist-get model :feed-more))
             (route (plist-get model :route)))
  :render
  (let* ((payload (etaf-value feed))
         (items (plist-get payload :items))
         (state (plist-get (etaf-value status) :state))
         (view (plist-get (etaf-value route) :view))
         (per-row (max 1 (min 4 (floor (/ (- columns 8) 34)))))
         (card-columns (max 18 (floor (/ (- columns 8 per-row) per-row))))
         (image-rows (etaf-youtube--image-rows card-columns metrics))
         (rows (etaf-youtube--chunk items per-row))
         (index 0))
    (etaf-view (flex :flex-direction 'column :width 'stretch
          :padding '((lh 1) (ch 3)) :row-gap '(lh 1)
      (etaf-youtube-list-header :model model :colors colors :payload payload
                                :state state :view view)
      (flex :flex-direction 'column :row-gap '(lh 0) :if (eq state 'loading)
        (etaf-youtube-skeleton-row :columns columns :colors colors)
        (etaf-youtube-skeleton-row :columns columns :colors colors))
      (flex :flex-direction 'column :padding '((lh 2) (ch 1)) :row-gap '(lh 1)
            :if (eq state 'error)
        (text :color (plist-get colors :ink)
              (expr (or (plist-get (etaf-value status) :message) "加载失败")))
        (text :color (plist-get colors :muted)
              (expr (or (plist-get (etaf-value status) :hint) "")))
        (etaf-button :label "重试" :variant 'secondary
                     :on-press (lambda () (etaf-youtube-refresh model))))
      (flex :flex-direction 'column :padding '((lh 2) (ch 1)) :row-gap '(lh 1)
            :if (and (eq state 'ready) (null items))
        (text :color (plist-get colors :ink) "这里还没有内容")
        (text :color (plist-get colors :muted) "换个筛选条件，或先刷新一次"))
      (expr
       (when (and items (not (eq state 'loading)))
         (mapcar
          (lambda (row)
            (etaf-view
             (flex :flex-direction 'row :column-gap '(ch 2)
                   :align-items 'flex-start
               (expr
                (mapcar
                 (lambda (item)
                   (let ((this index))
                     (setq index (1+ index))
                     (etaf-view
                      (etaf-youtube-card :model model :colors colors
                                         :item item
                                         :columns card-columns
                                         :image-rows image-rows
                                         :index this))))
                 row)))))
          rows)))
      (flex :flex-direction 'row :padding '((lh 1) (ch 0))
            :if (and (plist-get payload :next) (not (eq state 'loading)))
        (etaf-button :label (if (plist-get (etaf-value more) :loading)
                                "加载中…"
                              "显示更多")
                     :variant 'secondary
                     :disabled (and (plist-get (etaf-value more) :loading) t)
                     :on-press (lambda () (etaf-youtube-load-more model))))))))

(etaf-define-component etaf-youtube-list-header
    (&key model colors payload state view)
  "Render the list title, chips and tabs of PAYLOAD."
  :view
  (flex :flex-direction 'column :row-gap '(lh 1)
    (flex :flex-direction 'row :align-items 'center :column-gap '(ch 2)
      (text :font-weight 'bold
            :color (plist-get colors :ink)
            (expr (or (and (plist-get payload :title)
                     (not (string-empty-p (plist-get payload :title)))
                     (plist-get payload :title))
                (pcase view
                  ('home "首页") ('shorts "Shorts")
                  ('subscriptions "订阅内容") ('history "观看历史")
                  ('playlists "播放列表") ('watch-later "稍后观看")
                  ('liked "喜欢的视频") ('live "直播")
                  ('search (format "搜索：%s" (etaf-youtube--read model :query)))
                  (_ "YouTube")))))
      (box :flex-grow 1 :flex-basis '(ch 0))
      (etaf-button :label "刷新" :variant 'ghost
                   :on-press (lambda () (etaf-youtube-refresh model))))
    (etaf-youtube-chips :if (plist-get payload :filters)
                        :model model :colors colors
                        :chips (plist-get payload :filters))
    (etaf-youtube-chips :if (plist-get payload :tabs)
                        :model model :colors colors
                        :chips (plist-get payload :tabs))))

(etaf-define-component etaf-youtube-chips (&key model colors chips)
  "Render selectable filter chips."
  :view
  (flex :flex-direction 'row :flex-wrap 'wrap :column-gap '(ch 1)
        :row-gap '(lh 0)
    (etaf-youtube-chip :for (chip chips)
                       :key (or (plist-get chip :title) "")
                       :model model :colors colors :chip chip)))

(etaf-define-component etaf-youtube-chip (&key model colors chip)
  "Render one filter chip."
  :render
  (let ((selected (plist-get chip :selected)))
    (etaf-view (box :role 'button :tab-index 0
         :aria-label (or (plist-get chip :title) "")
         :aria-selected (and selected t)
         :padding '((lh 0) (ch 2))
         :background-color (if selected
                               (plist-get colors :ink)
                             (plist-get colors :panel3))
         :color (if selected (plist-get colors :bg) (plist-get colors :ink))
         :hover-style (unless selected
                        (list :background-color (plist-get colors :hover)))
         :on-press (lambda () (etaf-youtube-apply-chip model chip))
      (text (expr (or (plist-get chip :title) "")))))))

(etaf-define-component etaf-youtube-skeleton-row (&key columns colors)
  "Render a placeholder row while a list loads."
  :render
  (let* ((per-row (max 1 (min 4 (floor (/ (- columns 8) 34)))))
         (card-columns (max 18 (floor (/ (- columns 8 per-row) per-row)))))
    (etaf-view (flex :flex-direction 'row :column-gap '(ch 2)
      (box :for (i (number-sequence 1 per-row)) :key i
           :width (list 'ch card-columns) :height '(lh 6)
           :background-color (plist-get colors :panel3))))))

(etaf-define-component etaf-youtube-card
    (&key model colors item columns image-rows index)
  "Render one media card for ITEM."
  :bindings ((selected (plist-get model :selected))
             (image-version (etaf-youtube-images-version (plist-get model :images))))
  :render
  (let* ((_ (etaf-value image-version))
         (active (= (etaf-value selected) index))
         (image (etaf-youtube-images-descriptor
                 (plist-get model :images) (plist-get item :thumbnail)))
         (title-lines (etaf-youtube--wrap (plist-get item :title) columns 2))
         (meta (etaf-youtube--meta-line item))
         (duration (plist-get item :duration))
         (kind (plist-get item :kind)))
    (etaf-view (box :role 'button :tab-index 0
         :aria-label (or (plist-get item :title) "")
         :aria-selected (and active t)
         :width (list 'ch columns)
         :flex-shrink 0
         :overflow 'hidden
         :background-color (if active (plist-get colors :selected) nil)
         :hover-style (unless active
                        (list :background-color (plist-get colors :hover)))
         :on-press (lambda () (etaf-youtube-press-item model index))
      (flex :flex-direction 'column :row-gap '(lh 0)
        (box :width (list 'ch columns) :height (list 'lh image-rows)
             :overflow 'hidden
             :background-color (plist-get colors :panel3)
          (image :if image :src image :columns columns :rows image-rows)
          (box :if (not image) :width 'stretch :height 'stretch
               :text-align 'center
               :padding-top (list 'lh (max 0 (/ (- image-rows 1) 2)))
               :color (plist-get colors :dim)
            (text (expr (if (eq kind 'channel) "频道"
                    (if (eq kind 'playlist) "播放列表" "视频"))))))
        (flex :flex-direction 'row :column-gap '(ch 1) :padding-top '(lh 0)
          (text :if (and duration (not (eq kind 'channel)))
                :color (plist-get colors :muted)
                (expr (etaf-youtube--seconds duration)))
          (text :color (plist-get colors :muted)
                (expr (etaf-youtube--clip meta (max 8 columns)))))
        (text :color (plist-get colors :ink) :font-weight 'bold
              (expr (or (car title-lines) "")))
        (text :if (cadr title-lines)
              :color (plist-get colors :ink) :font-weight 'bold
              (expr (or (cadr title-lines) ""))))))))

;;; ---------------------------------------------------------------------------
;;; Watch page
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-watch (&key model colors columns)
  "Render the watch page: player, details, comments and recommendations."
  :bindings ((video (plist-get model :video))
             (theater (plist-get model :theater)))
  :render
  (let* ((payload (etaf-value video))
         (theater-p (etaf-value theater))
         ;; The page pads three columns on each side; the two columns and
         ;; their gap must fit inside what remains.
         (usable (max 40 (- columns 6)))
         (two-column (and (not theater-p) (> usable 100)))
         (main-columns (if two-column (floor (* usable 0.66)) usable))
         (side-columns (if two-column (max 20 (- usable main-columns 3))
                         usable)))
    (etaf-view (flex :flex-direction 'column :row-gap '(lh 1)
          :padding '((lh 1) (ch 3))
      (flex :flex-direction 'row :column-gap '(ch 3)
            :align-items 'flex-start
            :width (list 'ch usable)
        (flex :flex-direction 'column :row-gap '(lh 1)
              :width (list 'ch main-columns) :flex-shrink 0
          (etaf-youtube-player :model model :colors colors
                               :columns main-columns)
          (etaf-youtube-video-header :model model :colors colors
                                     :video payload :columns main-columns)
          (etaf-youtube-video-actions :model model :colors colors
                                      :video payload :columns main-columns)
          (etaf-youtube-video-description :if payload
                                          :colors colors :video payload
                                          :columns main-columns)
          (etaf-youtube-comments :model model :colors colors
                                 :columns main-columns))
        (etaf-youtube-recommendations :if two-column
                                      :model model :colors colors
                                      :video payload
                                      :columns side-columns))
      (etaf-youtube-recommendations :if (not two-column)
                                    :model model :colors colors
                                    :video payload
                                    :columns usable)))))

(etaf-define-component etaf-youtube-player (&key model colors columns)
  "Render the video canvas with its transport controls."
  :bindings ((media (plist-get model :media))
             (media-status (plist-get model :media-status))
             (captions-on (plist-get model :captions-on))
             (playing (plist-get model :playing))
             (duration (plist-get model :duration))
             (display-position (plist-get model :display-position))
             (volume (plist-get model :volume))
             (speed (plist-get model :speed))
             (muted (plist-get model :muted))
             (quality (plist-get model :quality))
             (audio (etaf-computed
                     (lambda ()
                       (not (etaf-value (plist-get model :muted)))))))
  :render
  (let* ((source (etaf-youtube-media-src model))
         (state (plist-get (etaf-value media-status) :state))
         (rows (etaf-youtube--image-rows columns nil))
         (caption (etaf-youtube-caption-text model))
         (caption-pixels (* (max 4 (- columns 2))
                            (or (plist-get (etaf-display-metrics) :char-width) 8)))
         (caption-line (and caption
                            (car (etaf-youtube--caption-lines caption caption-pixels 1))))
         (bar-color (plist-get colors :accent)))
    (etaf-view (flex :flex-direction 'column :row-gap '(lh 0)
          :background-color "#000000"
      (etaf-video :if source
                  :src source
                  :handle etaf-youtube-player-handle
                  :mode 'image
                  :columns columns
                  :rows rows
                  :audio audio
                  :volume volume
                  :speed speed
                  :autoplay t
                  :on-press (lambda () (etaf-youtube-toggle-playback model)))
      (box :width (list 'ch columns) :height (list 'lh rows)
           :text-align 'center
           :padding-top (list 'lh (max 0 (/ (- rows 1) 2)))
           :background-color (plist-get colors :panel2)
           :if (and (not source) (eq state 'loading))
        (text :color (plist-get colors :muted) "正在解析播放源…"))
      (box :width (list 'ch columns) :height (list 'lh rows)
           :text-align 'center
           :padding-top (list 'lh (max 0 (/ (- rows 1) 2)))
           :background-color (plist-get colors :panel2)
           :if (and (not source) (not (eq state 'loading)))
        (text :color (plist-get colors :muted)
              (expr (or (plist-get (etaf-value media-status) :message)
                  "播放源不可用"))))
      ;; The subtitle band is the picture's last flow row, one line tall
      ;; while captions are enabled.  A fixed row keeps the controls below
      ;; it from moving when a cue starts, and it never overlaps the live
      ;; canvas, whose retained frame updates replace picture rows.
      (box :if (etaf-value captions-on)
           :ref etaf-youtube-caption-ref
           :width (list 'ch columns)
           :height '(lh 1)
           :background-color (plist-get colors :panel2)
           :color (plist-get colors :ink)
           :text-align 'center
           :overflow 'hidden
        (text (expr (or caption-line ""))))
      (flex :flex-direction 'column :padding '((lh 0) (ch 2))
            :background-color (plist-get colors :panel)
            :row-gap '(lh 0)
        (etaf-range :value (etaf-value display-position)
                    :min 0
                    :max (max 1 (or (etaf-value duration) 1))
                    :step 1
                    :key-step 5
                    :color bar-color
                    :track-color (plist-get colors :panel3)
                    :on-change (lambda (value)
                                 (etaf-youtube-scrub model value))
                    :on-commit (lambda (_value)
                                 (etaf-youtube-commit-scrub model)))
        (flex :flex-direction 'row :align-items 'center :column-gap '(ch 2)
          (etaf-button :label (if (etaf-value playing) "❚❚" "▶")
                       :variant 'ghost :aria-label "播放/暂停"
                       :on-press (lambda () (etaf-youtube-toggle-playback model)))
          (text :color (plist-get colors :muted)
                (expr (format "%s / %s"
                        (etaf-youtube--seconds (etaf-value display-position))
                        (etaf-youtube--seconds (etaf-value duration)))))
          (box :flex-grow 1 :flex-basis '(ch 0))
          (etaf-button :label (if (etaf-value muted) "🔇" "🔊")
                       :variant 'ghost :aria-label "静音"
                       :on-press (lambda () (etaf-youtube-toggle-mute model)))
          (box :width '(ch 16)
            (etaf-range :value (etaf-value volume)
                        :min 0 :max 100 :step 5
                        :color bar-color
                        :track-color (plist-get colors :panel3)
                        :on-commit (lambda (value)
                                     (etaf-youtube-set-volume model value))))
          (etaf-select :value (etaf-value speed)
                       :presentation 'dropdown
                       :hide-label t
                       :width '(ch 12)
                       :options '((0.5 . "0.5x") (1 . "1x") (1.25 . "1.25x")
                                  (1.5 . "1.5x") (2 . "2x"))
                       :on-change (lambda (value)
                                    (etaf-youtube-set-speed model value)))
          (etaf-select :value (etaf-value quality)
                       :presentation 'dropdown
                       :hide-label t
                       :width '(ch 14)
                       :options (mapcar (lambda (height)
                                          (cons height (format "%dp" height)))
                                        (etaf-youtube-quality-choices model))
                       :on-change (lambda (value)
                                    (etaf-youtube-set-quality model value)))
          (etaf-button :label (if (etaf-youtube--read model :theater)
                                  "默认视图" "影院模式")
                       :variant 'ghost
                       :on-press (lambda () (etaf-youtube-toggle-theater model)))
          (etaf-button :label (if (etaf-youtube--read model :captions-on)
                                  "关闭字幕" "字幕")
                       :variant 'ghost
                       :disabled (null (plist-get (etaf-value media)
                                                  :subtitles))
                       :on-press (lambda () (etaf-youtube-toggle-captions model)))))))))

(etaf-define-component etaf-youtube-video-header (&key model colors video columns)
  "Render the watch page title and channel line."
  :view
  (flex :flex-direction 'column :row-gap '(lh 0)
    (flex :flex-direction 'column :row-gap '(lh 0) :if video
      (text :font-weight 'bold :color (plist-get colors :ink)
            (expr (or (plist-get video :title) "")))
      (flex :flex-direction 'row :column-gap '(ch 1) :align-items 'center
        (box :width '(ch 3) :height '(lh 2) :text-align 'center
             :background-color (plist-get colors :accent)
             :color "#FFFFFF" :font-weight 'bold
          (text (expr (etaf-youtube--avatar-initials (plist-get video :author)))))
        (flex :flex-direction 'column
          (text :color (plist-get colors :ink) :font-weight 'bold
                (expr (or (plist-get video :author) "")))
          (text :color (plist-get colors :muted)
                (expr (or (plist-get video :subscribers) ""))))
        (box :flex-grow 1 :flex-basis '(ch 0))
        (text :color (plist-get colors :muted)
              (expr (or (plist-get video :views) "")))))
    (text :if (null video) :color (plist-get colors :muted) "正在读取视频…")))

(etaf-define-component etaf-youtube-video-actions (&key model colors video columns)
  "Render like, dislike, subscribe and save controls."
  :render
  (let ((liked (equal (plist-get video :like_status) "LIKE"))
        (disliked (equal (plist-get video :like_status) "DISLIKE"))
        (subscribed (plist-get video :subscribed))
        (likes (or (plist-get video :likes) "")))
    (etaf-view (flex :flex-direction 'row :column-gap '(ch 1) :align-items 'center
          :if video
      (etaf-button :label (format "%s %s" (if liked "已赞" "赞") likes)
                   :variant (if liked 'primary 'secondary)
                   :on-press
                   (lambda ()
                     (when (etaf-confirm-dialog
                            (format "在 YouTube 账号上点赞《%s》？"
                                    (etaf-youtube--clip
                                     (plist-get video :title) 30)))
                       (etaf-youtube-like model t))))
      (etaf-button :label "踩"
                   :variant (if disliked 'primary 'secondary)
                   :on-press
                   (lambda ()
                     (when (etaf-confirm-dialog "在 YouTube 账号上点踩？")
                       (etaf-youtube-dislike model t))))
      (etaf-button :label (if subscribed "已订阅" "订阅")
                   :variant (if subscribed 'secondary 'primary)
                   :on-press
                   (lambda ()
                     (when (etaf-confirm-dialog
                            (format "%s《%s》？"
                                    (if subscribed "退订" "订阅")
                                    (etaf-youtube--clip
                                     (plist-get video :author) 20)))
                       (etaf-youtube-subscribe model (not subscribed) t))))
      (etaf-button :label "保存"
                   :variant 'secondary
                   :on-press
                   (lambda ()
                     (when (etaf-confirm-dialog "保存到「稍后观看」？")
                       (etaf-youtube-save model nil t))))
      (box :flex-grow 1 :flex-basis '(ch 0))
      (text :color (plist-get colors :muted)
            (expr (or (plist-get video :published) "")))))))

(etaf-define-component etaf-youtube-video-description (&key colors video columns)
  "Render the collapsible description."
  :render
  (let* ((text (or (plist-get video :description) ""))
         (lines (etaf-youtube--wrap text (max 20 columns) 4)))
    (etaf-view (flex :flex-direction 'column :padding '((lh 1) (ch 2))
          :background-color (plist-get colors :panel2)
          :row-gap '(lh 0)
      (text :color (plist-get colors :ink) :font-weight 'bold
            (expr (or (plist-get video :views) "")))
      (expr (mapcar (lambda (line)
                      (etaf-view
                       (text :color (plist-get colors :ink) (expr line))))
                    lines))
      (text :color (plist-get colors :link) "…展开")))))

(etaf-define-component etaf-youtube-recommendations (&key model colors video columns)
  "Render the related videos rail."
  :render
  (let* ((related (plist-get video :related))
         (image-columns (max 10 (floor (/ columns 2.6))))
         (image-rows (etaf-youtube--image-rows image-columns nil)))
    (etaf-view (flex :flex-direction 'column :width (list 'ch columns) :row-gap '(lh 1)
      (text :color (plist-get colors :ink) :font-weight 'bold "接下来")
      (text :if (null related) :color (plist-get colors :muted)
            "没有相关推荐")
      (etaf-youtube-recommendation
       :for (item related)
       :key (plist-get item :id)
       :model model :colors colors :item item
       :columns columns :image-columns image-columns :image-rows image-rows)))))

(etaf-define-component etaf-youtube-recommendation
    (&key model colors item columns image-columns image-rows)
  "Render one related video row."
  :bindings ((image-version (etaf-youtube-images-version (plist-get model :images))))
  :render
  (let* ((_ (etaf-value image-version))
         (image (etaf-youtube-images-descriptor
                 (plist-get model :images) (plist-get item :thumbnail))))
    (etaf-view (flex :flex-direction 'row :column-gap '(ch 1) :align-items 'flex-start
          :role 'button :tab-index 0
          :on-press (lambda () (etaf-youtube-open-video model (plist-get item :id)))
      (box :width (list 'ch image-columns) :height (list 'lh image-rows)
           :overflow 'hidden :background-color (plist-get colors :panel3)
        (image :if image :src image :columns image-columns :rows image-rows))
      (flex :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0)
            :min-width '(px 0) :row-gap '(lh 0)
        (text :color (plist-get colors :ink) :font-weight 'bold
              (expr (car (etaf-youtube--wrap (plist-get item :title)
                                       (- columns image-columns 2) 2))))
        (text :color (plist-get colors :muted)
              (expr (etaf-youtube--clip (or (plist-get item :author) "")
                                  (- columns image-columns 2))))
        (text :color (plist-get colors :muted)
              (expr (or (plist-get item :views) ""))))))))

;;; ---------------------------------------------------------------------------
;;; Comments
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-comments (&key model colors columns)
  "Render the comment section of the watch page."
  :bindings ((comments (plist-get model :comments))
             (status (plist-get model :comments-status)))
  :render
  (let* ((payload (etaf-value comments))
         (state (plist-get (etaf-value status) :state))
         (items (plist-get payload :items))
         (count (or (plist-get payload :count) ""))
         (can-comment (plist-get payload :can_comment))
         (requires-channel (plist-get payload :requires_channel)))
    (etaf-view (flex :flex-direction 'column :row-gap '(lh 1)
          :padding-top '(lh 1)
      (text :color (plist-get colors :ink) :font-weight 'bold
            (expr (if (and (stringp count)
                           (string-match-p "\\`[0-9,]+\\'" count))
                      (format "%s 条评论" count)
                    (or count "评论"))))
      (text :if (eq state 'loading) :color (plist-get colors :muted)
            "正在读取评论…")
      (text :if (eq state 'error) :color (plist-get colors :muted)
            (expr (or (plist-get (etaf-value status) :message) "评论加载失败")))
      (flex :flex-direction 'column :padding '((lh 1) (ch 2))
            :background-color (plist-get colors :panel2)
            :if (and requires-channel (not can-comment))
        (text :color (plist-get colors :ink)
              "当前账号还没有 YouTube 频道，无法发表评论。")
        (text :color (plist-get colors :muted)
              "可在 youtube.com 创建频道后回来重试。"))
      (etaf-youtube-comment-composer :if (and (not requires-channel)
                                              (not (eq state 'loading)))
                                     :model model :colors colors
                                     :visible can-comment)
      (etaf-youtube-comment :for (item items)
                            :key (plist-get item :id)
                            :model model :colors colors
                            :comment item :columns columns)
      (text :if (and (eq state 'ready) (null items))
            :color (plist-get colors :muted) "还没有评论")))))

(etaf-define-component etaf-youtube-comment-composer (&key model colors visible)
  "Render the comment input and publish button."
  :bindings ((draft (plist-get model :comment-draft)))
  :view
  (flex :flex-direction 'row :column-gap '(ch 1) :align-items 'flex-start
    (etaf-text-input :bind draft
                     :placeholder (if visible "添加评论…" "评论已关闭")
                     :disabled (not visible)
                     :rows 2
                     :width 'stretch)
    (etaf-button :label "评论"
                 :variant 'primary
                 :disabled (not visible)
                 :on-press
                 (lambda ()
                   (let ((text (or (etaf-value draft) "")))
                     (when (and (not (string-empty-p (string-trim text)))
                                (etaf-confirm-dialog
                                 (format "以 YouTube 账号发布这条评论？\n%s"
                                         (etaf-youtube--clip text 60))))
                       (etaf-youtube--write model :comment-draft "")
                       (etaf-youtube-comment model text t)))))))

(etaf-define-component etaf-youtube-comment
    (&key model colors comment columns)
  "Render one comment row with its replies."
  :render
  (let* ((id (plist-get comment :id))
         (replies (etaf-youtube-replies model id))
         (reply-count (plist-get comment :reply_count)))
    (etaf-view
     (flex :flex-direction 'column :row-gap '(lh 0)
       (flex :flex-direction 'row :column-gap '(ch 1) :align-items 'flex-start
         (box :width '(ch 3) :height '(lh 2) :text-align 'center
              :background-color (plist-get colors :panel3)
              :color (plist-get colors :ink) :font-weight 'bold
           (text (expr (etaf-youtube--avatar-initials (plist-get comment :author)))))
         (flex :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0)
               :min-width '(px 0) :row-gap '(lh 0)
           (flex :flex-direction 'row :column-gap '(ch 1)
             (text :color (plist-get colors :ink) :font-weight 'bold
                   (expr (or (plist-get comment :author) "")))
             (text :color (plist-get colors :muted)
                   (expr (or (plist-get comment :published) ""))))
           (expr (mapcar (lambda (line)
                           (etaf-view
                            (text :color (plist-get colors :ink) (expr line))))
                         (etaf-youtube--wrap (plist-get comment :text)
                                             (max 20 (- columns 6)) 6)))
           (flex :flex-direction 'row :column-gap '(ch 2) :align-items 'center
             (text :color (plist-get colors :muted)
                   (expr (format "赞 %s" (or (plist-get comment :likes) ""))))
             (box :role 'button :tab-index 0 :padding-inline '(ch 1)
                  :color (plist-get colors :link)
                  :if (and (stringp reply-count)
                           (not (string-empty-p reply-count))
                           (not (equal reply-count "0")))
                  :on-press (lambda ()
                              (if replies
                                  (etaf-youtube-load-replies
                                   model id (etaf-youtube-replies-cursor model id))
                                (etaf-youtube-load-replies model id)))
               (text (expr (if replies
                                (format "更多回复 (%s)" reply-count)
                              (format "查看 %s 条回复" reply-count))))))))
       (flex :flex-direction 'column :padding-left '(ch 4) :row-gap '(lh 0)
             :if replies
         (expr
          (mapcar
           (lambda (reply)
             (etaf-view
              (flex :flex-direction 'column
                (flex :flex-direction 'row :column-gap '(ch 1)
                  (text :color (plist-get colors :ink) :font-weight 'bold
                        (expr (or (plist-get reply :author) "")))
                  (text :color (plist-get colors :muted)
                        (expr (or (plist-get reply :published) ""))))
                (expr (mapcar (lambda (line)
                                (etaf-view
                                 (text :color (plist-get colors :ink) (expr line))))
                              (etaf-youtube--wrap
                               (plist-get reply :text)
                               (max 20 (- columns 8)) 4))))))
           replies)))))))

;;; ---------------------------------------------------------------------------
;;; Entry
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-view (model)
  "Return the application View for MODEL."
  (etaf-view (etaf-youtube-app :model model)))

(provide 'etaf-youtube-views)
;;; etaf-youtube-views.el ends here
