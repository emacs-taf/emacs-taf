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

(etaf-ui-icon-set-register
 'etaf-youtube-brand
 '(:kind svg :viewbox (0 0 24 24) :inset 0
   :paths ((youtube . "<rect x='1' y='4' width='22' height='16' rx='5' fill='currentColor' stroke='none'/><path d='M10 8L17 12L10 16Z' fill='white' stroke='none'/>")
           (home . "<path d='M3 11L12 3L21 11M5 9V21H10V14H14V21H19V9' fill='none' stroke='currentColor' stroke-width='1.7' stroke-linejoin='round'/>")
           (shorts . "<path d='M15 2L6 7A4 4 0 0 0 6 14L8 15L5 17A3 3 0 0 0 8 22L18 16A4 4 0 0 0 18 9L16 8L18 7A3 3 0 0 0 15 2Z' fill='none' stroke='currentColor' stroke-width='1.5'/><path d='M10 9L15 12L10 15Z' fill='currentColor' stroke='none'/>")
           (subscriptions . "<path d='M7 3H17M5 6H19' stroke='currentColor' stroke-width='1.6'/><rect x='3' y='9' width='18' height='12' rx='2' fill='none' stroke='currentColor' stroke-width='1.6'/><path d='M10 12L15 15L10 18Z' fill='currentColor' stroke='none'/>")
           (history . "<path d='M4 8A9 9 0 1 1 3 14M3 3V9H9M12 7V12L16 15' fill='none' stroke='currentColor' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'/>")
           (playlists . "<path d='M3 5H21M3 10H21M3 15H12M3 20H12' stroke='currentColor' stroke-width='1.7'/><path d='M16 14L22 18L16 22Z' fill='currentColor' stroke='none'/>")
           (watch-later . "<circle cx='12' cy='12' r='9' fill='none' stroke='currentColor' stroke-width='1.7'/><path d='M12 6V12L17 15' fill='none' stroke='currentColor' stroke-width='1.7'/>")
           (liked . "<path d='M7 10L12 3C15 3 14 7 13 9H19C21 9 21 11 20 14L18 21H7ZM3 10H7V21H3Z' fill='none' stroke='currentColor' stroke-width='1.5' stroke-linejoin='round'/>")
           (live . "<circle cx='12' cy='12' r='2' fill='currentColor' stroke='none'/><path d='M7 7A7 7 0 0 0 7 17M17 7A7 7 0 0 1 17 17M4 4A11 11 0 0 0 4 20M20 4A11 11 0 0 1 20 20' fill='none' stroke='currentColor' stroke-width='1.5'/>"))
   :fallback ((youtube . ">") (home . "H") (shorts . "S")
              (subscriptions . "=") (history . "C") (playlists . "L")
              (watch-later . "W") (liked . "+") (live . "O"))))

(defvar etaf-youtube-search-ref 'etaf-youtube-search-field
  "Ref of the top bar search field, used by the application's focus key.")

(defvar etaf-youtube-caption-ref 'etaf-youtube-caption
  "Ref of the subtitle band Host above the transport controls.")

(defconst etaf-youtube-region-shell 'etaf-youtube-region-shell
  "Region id of the whole application shell.")

(defconst etaf-youtube-region-sidebar 'etaf-youtube-region-sidebar
  "Region id of the navigation sidebar, expanded or as the icon rail.")

(defconst etaf-youtube-region-content 'etaf-youtube-region-content
  "Region id of the scrollable content area.")

(defconst etaf-youtube-region-comments 'etaf-youtube-region-comments
  "Region id of the watch page comment section.")

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

(defun etaf-youtube--thumbnail-size (image columns rows)
  "Fit IMAGE inside COLUMNS by ROWS without stretching portrait artwork."
  (let* ((size (and image (display-graphic-p) (image-size image t)))
         (cell (etaf-youtube--display-cell (etaf-display-metrics))))
    (if (not (and size (> (car size) 0) (> (cdr size) 0)))
        (cons columns rows)
      (let ((scale (min (/ (* columns (car cell)) (float (car size)))
                        (/ (* rows (cdr cell)) (float (cdr size))))))
        (cons (max 1 (floor (/ (* scale (car size)) (car cell))))
              (max 1 (floor (/ (* scale (cdr size)) (cdr cell)))))))))

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

(defun etaf-youtube--display-copy (text)
  "Keep one space between Chinese and Latin letters or digits in TEXT."
  (replace-regexp-in-string
   "\\([A-Za-z0-9]\\)\\([一-鿿]\\)" "\\1 \\2"
   (replace-regexp-in-string "\\([一-鿿]\\)\\([A-Za-z0-9]\\)" "\\1 \\2"
                             (or text ""))))

(defun etaf-youtube--clip-pixels (text pixels)
  "Return TEXT shortened so it fits PIXELS display pixels.
TEXT is cut on character boundaries and trailing blanks are removed."
  (setq text (etaf-youtube--display-copy text))
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
  (let ((text (replace-regexp-in-string "[\n\r]+" " "
                                       (etaf-youtube--display-copy text)))
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

(defun etaf-youtube--card-rows (items columns)
  "Group ITEMS into landscape and portrait rows fitting COLUMNS.
Each entry retains its original index so visual grouping cannot change which
video an activation opens.  Order within each kind follows the backend."
  (let* ((entries (cl-loop for item in items for index from 0
                           collect (cons index item)))
         (short-p (lambda (entry)
                    (member (plist-get (cdr entry) :kind) '(short "short"))))
         (rows nil))
    (dolist (portrait '(nil t))
      (let* ((group (seq-filter (lambda (entry)
                                  (eq (not (null (funcall short-p entry))) portrait))
                                entries))
             (count (max 1 (min (if portrait 6 4)
                                (/ (+ columns 3) (if portrait 26 43)))))
             (width (max 18 (/ (- columns (* 3 (1- count))) count)))
             (first t))
        (dolist (row (etaf-youtube--chunk group count))
          (push (list :entries row :columns width :portrait portrait
                      :heading (and portrait first)) rows)
          (setq first nil))))
    (nreverse rows)))

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
         ;; Navigation uses border-box widths, including its own padding.
         (content-columns (- columns (cond (sidebar-visible 24)
                                           (rail-visible 6)
                                           (t 0)))))
    (etaf-view (flex :flex-direction 'column :width '(vw 100) :height '(vh 100)
          :background-color (plist-get c :bg)
          :color (plist-get c :ink)
          :overflow 'hidden
          :region (list :id etaf-youtube-region-shell :label "应用" :key ?a)
          :keys (list
                 (list "SPC" 'etaf-youtube-toggle-playback-command "播放 / 暂停")
                 (list "f" 'etaf-youtube-seek-forward-command "快进 5 秒")
                 (list "b" 'etaf-youtube-seek-backward-command "快退 5 秒")
                 (list "]" 'etaf-youtube-volume-up-command "音量 +5")
                 (list "[" 'etaf-youtube-volume-down-command "音量 -5")
                 (list "m" 'etaf-youtube-mute-command "静音")
                 (list "s" 'etaf-youtube-sidebar-command "折叠 / 展开侧栏")
                 (list "t" 'etaf-youtube-theater-command "影院模式")
                 (list "d" 'etaf-youtube-theme-command "切换外观")
                 (list "r" 'etaf-youtube-refresh-command "刷新")
                 (list "u" 'etaf-youtube-back-command "返回")
                 (list "RET" 'etaf-youtube-activate-command "打开选中项")
                 (list "/" 'etaf-youtube-focus-search "搜索")
                 (list "C-c s" 'etaf-youtube-focus-sidebar-command "焦点：侧栏")
                 (list "C-c c" 'etaf-youtube-focus-content-command "焦点：内容")
                 (list "C-c m" 'etaf-youtube-focus-comments-command "焦点：评论"))
      (etaf-youtube-topbar :model model :colors c :columns columns)
      (flex :flex-direction 'row :flex-grow 1 :flex-basis '(lh 0)
            :min-height '(lh 0) :overflow 'hidden
        (etaf-youtube-sidebar :model model :colors c :columns columns
                              :active sidebar-visible)
        (etaf-youtube-sidebar-rail :model model :colors c
                                   :active rail-visible)
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(px 0)
             :height 'stretch :min-height '(lh 0) :overflow 'scroll
             :ref 'etaf-youtube-content
             :region (list :id etaf-youtube-region-content :label "内容" :key ?c
                           :neighbors (list :left etaf-youtube-region-sidebar))
          (etaf-youtube-watch :if (eq view 'watch)
                              :model model :colors c
                              :columns content-columns)
          (etaf-youtube-list :if (not (eq view 'watch))
                             :model model :colors c
                             :columns content-columns
                             :metrics (etaf-value metrics)))
      (etaf-youtube-toast :if (etaf-value message)
                          :message (etaf-value message)
                          :colors c
                          :columns columns))))))

(etaf-define-component etaf-youtube-topbar (&key model colors columns)
  "Render the application's brand, search field and account controls."
  :bindings ((query (plist-get model :query))
             (account (plist-get model :account))
             (mode (plist-get model :theme-mode)))
  :render
  (let* ((small (<= columns 72))
         ;; Equal end slots keep search centered, independent of account names.
         (side-width (cond ((<= columns 48) '(ch 6))
                           (small '(ch 10)) (t '(ch 20)))))
    (etaf-view
     (flex :ref 'etaf-youtube-topbar :role 'banner :aria-label "YouTube 顶栏"
           :flex-direction 'row :height '(lh 5) :flex-shrink 0
           :box-sizing 'border-box :align-items 'center
           :column-gap (list 'ch (if small 1 2))
           :padding (list '(lh 0) (list 'ch (if small 1 2)))
           :background-color (plist-get colors :bg)
       (flex :flex-direction 'row :align-items 'center :column-gap '(ch 1)
             :width side-width :flex-shrink 0
         (etaf-button :variant 'ghost :aria-label "切换侧栏"
                      :help-echo "展开或收起侧栏"
                      :padding '((lh 0.5) (ch 1))
                      :on-press (lambda () (etaf-youtube-toggle-sidebar model))
           (etaf-ui-icon :name 'menu :set 'svg :color (plist-get colors :ink)))
         (etaf-button :variant 'ghost :aria-label "首页"
                      :padding '((lh 0) (ch 0))
                      :on-press (lambda () (etaf-youtube-locate model 'home))
           (flex :flex-direction 'row :align-items 'center :column-gap '(ch 1)
             (etaf-ui-icon :name 'youtube :set 'etaf-youtube-brand
                           :color (plist-get colors :accent) :min-width 3)
             (text :if (not small) :color (plist-get colors :ink)
                   :font-weight 'bold "YouTube"))))
       (flex :flex-direction 'row :justify-content 'center
             :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         (etaf-search-field
          :bind query :ref etaf-youtube-search-ref
          :placeholder "搜索" :icon t
          :width 'stretch :max-width '(ch 64)
          :on-submit (lambda (text)
                       (etaf-youtube--write model :query (or text ""))
                       (etaf-youtube-search model (or text "")))))
       (flex :flex-direction 'row :align-items 'center
             :justify-content 'flex-end :column-gap '(ch 1)
             :width side-width :flex-shrink 0
         (etaf-button :if (not small) :variant 'ghost :aria-label "刷新"
                      :help-echo "刷新当前页面" :padding '((lh 0.5) (ch 1))
                      :on-press (lambda () (etaf-youtube-refresh model))
           (etaf-ui-icon :name 'refresh :set 'svg :color (plist-get colors :ink)))
         (etaf-button :if (> columns 48) :variant 'ghost :aria-label "切换外观"
                      :help-echo (if (eq (etaf-value mode) 'dark)
                                     "切换到浅色外观" "切换到深色外观")
                      :padding '((lh 0.5) (ch 1))
                      :on-press (lambda () (etaf-youtube-cycle-theme model))
           (etaf-ui-icon :name 'settings :set 'svg :color (plist-get colors :ink)))
         (etaf-youtube-account :account (etaf-value account) :colors colors))))))

(etaf-define-component etaf-youtube-account (&key account colors)
  "Render a compact circular account avatar, or a sign-in hint."
  :render
  (if (and account (plist-get account :signed_in))
      (etaf-view
       (etaf-avatar :name (plist-get account :name)
                    :initials (etaf-youtube--avatar-initials (plist-get account :name))
                    :size '(ch 4) :lines 2 :background (plist-get colors :link)))
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
          :box-sizing 'border-box :flex-shrink 0 :height 'stretch
          :overflow 'scroll :padding '((lh 1) (ch 1))
          :background-color (plist-get colors :bg)
          :row-gap '(lh 0)
          :region (list :id etaf-youtube-region-sidebar :label "侧栏" :key ?l
                        :neighbors (list :right etaf-youtube-region-content))
          :if active
      (etaf-youtube-sidebar-items :model model :colors colors :current current)
      (box :height '(lh 1) :flex-shrink 0)
      (etaf-divider :flex-shrink 0)
      (box :flex-shrink 0 :padding '((lh 1) (ch 2))
        (text :color (plist-get colors :ink) :font-weight 'bold "你"))
      (etaf-youtube-sidebar-items :model model :colors colors :current current
                                  :personal t)))))

(etaf-define-component etaf-youtube-sidebar-rail (&key model colors active)
  "Render the compact icon rail used below the sidebar breakpoint."
  :view
  (flex :flex-direction 'column :width '(ch 6) :align-items 'center
        :box-sizing 'border-box :flex-shrink 0 :height 'stretch
        :overflow 'scroll :padding '((lh 1) (ch 0))
        :background-color (plist-get colors :bg)
        :row-gap '(lh 1)
        :region (list :id etaf-youtube-region-sidebar :label "侧栏" :key ?l
                      :neighbors (list :right etaf-youtube-region-content))
        :if active
    (etaf-youtube-rail-button :for (entry '(("首页" . home) ("Shorts" . shorts)
                                            ("订阅内容" . subscriptions)
                                            ("历史" . history) ("播放列表" . playlists)))
                              :key (cdr entry)
                              :label (car entry)
                              :view (cdr entry)
                              :model model :colors colors)))

(etaf-define-component etaf-youtube-rail-button (&key label view model colors)
  "Render one accessible, selected-state-aware SVG navigation button."
  :bindings ((route (plist-get model :route)))
  :render
  (let ((active (eq view (plist-get (etaf-value route) :view))))
    (etaf-view
     (etaf-button :variant 'ghost :aria-label label :help-echo label
                  :aria-selected active :border-radius '(px 8)
                  :bgcolor (when active (plist-get colors :selected))
                  :padding '((lh 0) (ch 1))
                  :on-press (lambda () (etaf-youtube-locate model view))
       (flex :height '(lh 2) :align-items 'center :justify-content 'center
         (etaf-ui-icon :name view :set 'etaf-youtube-brand
                       :color (plist-get colors :ink) :min-width 3))))))

(etaf-define-component etaf-youtube-sidebar-items
    (&key model colors current personal)
  "Render MODEL's navigation entries, PERSONAL for the account lists."
  :view
  (flex :flex-direction 'column :row-gap '(lh 0) :flex-shrink 0
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
    (etaf-view
     (etaf-button :variant 'ghost :aria-label label :aria-selected active
                  :width 'stretch :border-radius '(px 8)
                  :padding '((lh 0) (ch 2))
                  :bgcolor (when active (plist-get colors :selected))
                  :color (plist-get colors :ink)
                  :on-press (lambda () (etaf-youtube-locate model view))
       (flex :flex-direction 'row :height '(lh 2) :align-items 'center
             :column-gap '(ch 2)
         (etaf-ui-icon :name view :set 'etaf-youtube-brand
                       :color (plist-get colors :ink) :min-width 2)
         (text :font-weight (if active 'bold 'normal) (expr label)))))))

(etaf-define-component etaf-youtube-toast (&key message colors columns)
  "Render MESSAGE as a floating status line."
  :render
  (let ((variant (plist-get message :variant)))
    (etaf-view (box :padding '((lh 0) (ch 2))
         :background-color (pcase variant
                             ('danger (plist-get colors :danger-bg))
                             ('success (plist-get colors :ok))
                             (_ (plist-get colors :panel3)))
         :color (if (eq variant 'success) "#FFFFFF" (plist-get colors :ink))
         :position 'absolute :left '(ch 2)
         :top '(calc (- (vh 100) (lh 3))) :z-index 20
         :border-radius '(px 8)
      (text (expr (etaf-youtube--clip (or (plist-get message :text) "")
                                      (max 10 (- columns 8)))))))))

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
         (padding (if (< columns 70) 2 3))
         (inner (- columns (* 2 padding)))
         (rows (etaf-youtube--card-rows items inner)))
    (etaf-view (flex :flex-direction 'column :width 'stretch
          :padding (list '(lh 1) (list 'ch padding)) :row-gap '(lh 2)
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
            (let* ((width (plist-get row :columns))
                   (portrait (plist-get row :portrait))
                   (cell (etaf-youtube--display-cell metrics))
                   (height (if portrait
                               (max 4 (round (/ (* width (car cell) 16.0)
                                                (* 9.0 (cdr cell)))))
                             (etaf-youtube--image-rows width metrics))))
              (etaf-view
               (flex :flex-direction 'column :row-gap '(lh 1)
                 (flex :if (and (not (eq view 'shorts)) (plist-get row :heading))
                       :flex-direction 'row
                       :column-gap '(ch 1) :align-items 'center
                   (etaf-ui-icon :name 'shorts :set 'etaf-youtube-brand
                                 :color (plist-get colors :accent))
                   (text :color (plist-get colors :ink) :font-weight 'bold "Shorts"))
                 (flex :flex-direction 'row :column-gap '(ch 3)
                       :align-items 'flex-start
                   (expr
                    (mapcar
                     (lambda (entry)
                       (let ((item (cdr entry)))
                         (etaf-view
                          (etaf-youtube-card :model model :colors colors
                                             :item item :columns width
                                             :image-rows height
                                             :key (plist-get item :id)
                                             :index (car entry)))))
                     (plist-get row :entries))))))))
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
    (flex :if (not (and (eq view 'home) (plist-get payload :filters)))
          :flex-direction 'row :align-items 'center :column-gap '(ch 2)
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
  "Render one filter chip using the catalog button interaction."
  :render
  (let ((selected (plist-get chip :selected)))
    (etaf-view
     (etaf-button :variant 'ghost :aria-label (or (plist-get chip :title) "")
                  :aria-selected (and selected t) :border-radius '(px 6)
                  :padding '((lh 0) (ch 2))
                  :bgcolor (if selected (plist-get colors :ink)
                             (plist-get colors :panel3))
                  :color (if selected (plist-get colors :bg) (plist-get colors :ink))
                  :on-press (lambda () (etaf-youtube-apply-chip model chip))
       (flex :height '(lh 2) :align-items 'center
         (text (expr (or (plist-get chip :title) ""))))))))

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
         (image-size (etaf-youtube--thumbnail-size image columns image-rows))
         (portrait (member (plist-get item :kind) '(short "short")))
         (has-author (not (string-empty-p (or (plist-get item :author) ""))))
         (avatar (and has-author (not portrait)))
         (text-columns (max 10 (- columns (if avatar 6 1))))
         (pixels (* (1- text-columns)
                    (car (etaf-youtube--display-cell (etaf-display-metrics)))))
         (title-lines (etaf-youtube--caption-lines (plist-get item :title) pixels 2))
         (author (or (plist-get item :author) ""))
         (meta (string-join
                (seq-remove #'string-empty-p
                            (list (or (plist-get item :views) "")
                                  (or (plist-get item :published) ""))) " · "))
         (duration (plist-get item :duration))
         (kind (plist-get item :kind))
         (badge (cond ((or (plist-get item :live)
                           (and (stringp duration)
                                (string-match-p "LIVE\\|直播" duration))) "直播")
                      ((or (member kind '(short "short"))
                           (equal duration "Shorts")) "Shorts")
                      ((and duration (not (equal duration ""))
                            (not (member kind '(channel "channel"))))
                       (etaf-youtube--seconds duration)))))
    (etaf-view
     (etaf-button :variant 'ghost :aria-label (or (plist-get item :title) "")
                  :aria-selected active :width (list 'ch columns)
                  :padding '((lh 0) (ch 0)) :border-radius '(px 8)
                  :overflow 'hidden
                  :bgcolor (when active (plist-get colors :selected))
                  :on-press (lambda () (etaf-youtube-press-item model index))
       (flex :flex-direction 'column :row-gap '(lh 1)
         (box :position 'relative :width (list 'ch columns)
              :height (list 'lh image-rows) :overflow 'hidden
              :background-color (plist-get colors :panel3)
           (flex :if image :flex-direction 'row :justify-content 'center
                 :align-items 'center :height (list 'lh image-rows)
             (image :src image :columns (car image-size) :rows (cdr image-size)))
           (box :if (not image) :width 'stretch :height 'stretch
                :text-align 'center
                :padding-top (list 'lh (max 0 (/ (- image-rows 1) 2)))
                :color (plist-get colors :dim)
             (text (expr (cond ((member kind '(channel "channel")) "频道")
                              ((member kind '(playlist "playlist")) "播放列表")
                              (t "视频")))))
           (box :if badge :position 'absolute :z-index 1
                :left (list 'ch (max 0 (- columns (string-width (or badge "")) 2)))
                :top (list 'lh (1- image-rows)) :padding-inline '(ch 0.5)
                :background-color (plist-get colors :badge)
                :color (plist-get colors :badge-ink) :border-radius '(px 3)
             (text (expr (or badge "")))))
         (flex :flex-direction 'row :column-gap '(ch 1)
               :padding '((lh 0) (ch 0.5)) :align-items 'flex-start
           (etaf-avatar :if avatar :name author
                        :initials (etaf-youtube--avatar-initials author)
                        :size '(ch 4) :lines 2
                        :background (plist-get colors :avatar-bg))
           (flex :flex-direction 'column :width (list 'ch text-columns)
             (box :height '(lh 2) :overflow 'hidden
               (text :color (plist-get colors :ink) :font-weight 'bold
                     (expr (string-join title-lines "\n"))))
             (text :if (and has-author (not portrait))
                   :color (plist-get colors :muted)
                   (expr (etaf-youtube--clip-pixels author pixels)))
             (text :color (plist-get colors :muted)
                   (expr (etaf-youtube--clip-pixels meta pixels))))))))))

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
         (usable (max 24 (- columns 6)))
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
         (viewport (etaf-viewport))
         (available (cdr-safe viewport))
         ;; A short window shrinks the canvas so the subtitle band and the
         ;; transport row stay on screen; the aspect height still wins when
         ;; there is room for it.
         (rows (let ((aspect (etaf-youtube--image-rows columns nil)))
                 (if (and (numberp available) (> available 0))
                     (max 6 (min aspect (- available 8)))
                   aspect)))
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
        (flex :flex-direction 'row :align-items 'center
              :column-gap (if (> columns 96) '(ch 2) '(ch 1))
              :flex-wrap 'wrap :row-gap '(lh 0)
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
          (box :width (if (> columns 96) '(ch 16) '(ch 12))
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
          :region (list :id etaf-youtube-region-comments :label "评论" :key ?m)
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
