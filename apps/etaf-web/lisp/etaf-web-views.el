;;; etaf-web-views.el --- Emacs-native browser shell views for etaf-web -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentational views for the `etaf-web' Emacs-native browser shell (design v2):
;; - Inherits the active Emacs theme's frame background with zero tinted chrome
;;   slabs, zero input boxes and zero bottom footer bar.
;; - Always a single constant-height 1lh top row separated by a 1px hairline
;;   (zero vertical jitter across idle, loading, editing, error and narrow):
;;   - Left (fixed width): `后退' `前进' `刷新' (loading: `刷新' → `停止' with
;;     identical 4ch width; disabled actions stay visible in muted color);
;;     narrow (< 72ch): `‹' `›' `⟳' (loading: `×').
;;   - Middle: full URL ALWAYS visible including scheme (`https://` muted +
;;     bold host + muted path), editable inline in-place without height change.
;;   - Right (retained Host `:ref web-status'): pure text stage + percent +
;;     elapsed while loading (`渲染中 38% · 2.4s`, narrow `38%`), `缓存` or
;;     empty when ready, `失败` on error.
;; - Error view rendered directly on frame background with a thin danger left
;;   accent bar and plain text actions (`[重试 (r)]', `[外部浏览器 (o)]',
;;   `[返回上页 (B)]', `[查看旧缓存]').
;;
;; All colors come from Theme tokens (`etaf-ui-theme-tokens'), type size always
;; follows the user's Emacs face, and zero I/O occurs inside render functions.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-md)
(require 'etaf-web-cache)

(defconst etaf-web--narrow-breakpoint 72
  "Viewport width in columns below which header actions fold compactly.")

(defconst etaf-web--min-measure 36
  "Minimum reading column width in character cells.")

(defconst etaf-web--max-measure 78
  "Default desktop reading column width in character cells.")

;;; ---------------------------------------------------------------------------
;;; Theme palette (derives from active Emacs theme in `auto' mode)
;;; ---------------------------------------------------------------------------

(defun etaf-web--blend-color (fg bg ratio)
  "Return hex color blending FG toward BG by RATIO (0.0 = BG, 1.0 = FG)."
  (let ((c1 (ignore-errors (color-name-to-rgb fg)))
        (c2 (ignore-errors (color-name-to-rgb bg))))
    (if (and c1 c2)
        (apply #'color-rgb-to-hex
               (append (cl-mapcar (lambda (a b) (+ (* ratio a) (* (- 1.0 ratio) b)))
                                  c1 c2)
                       '(2)))
      fg)))

(defun etaf-web--face-color (face attr fallback)
  "Return valid color string for FACE ATTR on the selected frame, or FALLBACK."
  (let ((val (ignore-errors (face-attribute face attr nil 'default))))
    (if (and (stringp val)
             (not (string-empty-p val))
             (not (string-prefix-p "unspecified" val)))
        val
      fallback)))

(defun etaf-web--palette (mode)
  "Return semantic color plist for theme MODE (`auto', `dark', `light', `sepia').
In `auto' mode, colors are derived directly from the active Emacs theme's faces
so the shell blends seamlessly with the user's frame background."
  (let ((dark-p (eq (etaf-appearance) 'dark)))
    (pcase mode
      ('light
       '(:bg "#ffffff" :fg "#1f2328" :panel "#ffffff" :track "#eef1f4"
         :border "#d1d9e0" :muted "#59636e" :dim "#818b98"
         :accent "#0969da" :accent-fg "#ffffff" :accent-soft "#ddf4ff"
         :success "#1a7f37" :success-bg "#dafbe1" :success-border "#aceebb"
         :warning "#9a6700" :warning-bg "#fff8c5" :warning-border "#d4a72c"
         :danger "#d1242f" :danger-bg "#ffebe9" :danger-border "#d1242f"
         :info "#0969da" :info-bg "#ddf4ff" :info-border "#54aeff"))
      ('sepia
       '(:bg "#f5ecd9" :fg "#3b3024" :panel "#f5ecd9" :track "#e9dcc2"
         :border "#d8c9ab" :muted "#7a6a53" :dim "#9a8a72"
         :accent "#b3541e" :accent-fg "#ffffff" :accent-soft "#efddc4"
         :success "#3f6212" :success-bg "#e2ecd0" :success-border "#a3be7c"
         :warning "#92400e" :warning-bg "#f7e6c4" :warning-border "#c99a5b"
         :danger "#9f1239" :danger-bg "#f5d6cf" :danger-border "#9f1239"
         :info "#b3541e" :info-bg "#efddc4" :info-border "#d49c74"))
      ('dark
       '(:bg "#191a1c" :fg "#e6edf3" :panel "#191a1c" :track "#25272b"
         :border "#303338" :muted "#9198a1" :dim "#6e7681"
         :accent "#4493f8" :accent-fg "#ffffff" :accent-soft "#152c4d"
         :success "#3fb950" :success-bg "#12261e" :success-border "#2ea043"
         :warning "#d29922" :warning-bg "#272115" :warning-border "#d29922"
         :danger "#f85149" :danger-bg "#2a1518" :danger-border "#f85149"
         :info "#4493f8" :info-bg "#152c4d" :info-border "#4493f8"))
      (_
       (let* ((bg (etaf-web--face-color 'default :background
                                        (if dark-p "#232b30" "#ffffff")))
              (fg (etaf-web--face-color 'default :foreground
                                        (if dark-p "#dcdfe4" "#1f2328")))
              (muted (etaf-web--face-color 'shadow :foreground
                                           (if dark-p "#8b99a4" "#59636e")))
              (border (etaf-web--blend-color fg bg 0.22))
              (raw-accent (etaf-web--face-color 'link :foreground
                                                (if dark-p "#61afef" "#0969da")))
              (accent (if (equal (downcase raw-accent) (downcase fg))
                          (etaf-web--face-color 'font-lock-function-name-face :foreground
                                                (if dark-p "#61afef" "#0969da"))
                        raw-accent))
              (danger (etaf-web--face-color 'error :foreground
                                            (if dark-p "#e06c75" "#d1242f")))
              (success (etaf-web--face-color 'success :foreground
                                             (if dark-p "#98c379" "#1a7f37")))
              (warning (etaf-web--face-color 'warning :foreground
                                             (if dark-p "#e5c07b" "#9a6700")))
              (track (etaf-web--face-color 'hl-line :background
                                           (if dark-p "#313b42" "#eef1f4")))
              (soft (etaf-web--face-color 'region :background
                                          (if dark-p "#2b3842" "#ddf4ff")))
              (dim (etaf-web--blend-color fg bg 0.40)))
         (list :bg bg :fg fg :panel bg :track track
               :border border :muted muted :dim dim
               :accent accent :accent-fg "#ffffff"
               :accent-soft soft
               :success success :success-bg bg :success-border success
               :warning warning :warning-bg bg :warning-border warning
               :danger danger :danger-bg bg :danger-border danger
               :info accent :info-bg bg :info-border accent))))))

(defun etaf-web--theme-tokens (mode)
  "Return `etaf-ui-theme-tokens' plist for browser MODE."
  (etaf-ui-theme-tokens (etaf-web--palette mode)))

(defun etaf-web--border-token (key fallback &optional px)
  "Return a solid border token of width PX (default 1) from Theme KEY."
  (let ((w (or px 1)))
    (etaf-theme-token key fallback (lambda (c) (list (list 'px w) 'solid c)))))

;;; ---------------------------------------------------------------------------
;;; String formatting helpers (middle truncation & pure-text status string)
;;; ---------------------------------------------------------------------------

(defun etaf-web--middle-truncate (text max-cols)
  "Middle-truncate TEXT to fit within MAX-COLS display columns."
  (let ((s (or text "")))
    (cond
     ((<= max-cols 1) "")
     ((<= (string-width s) max-cols) s)
     ((<= max-cols 4) (truncate-string-to-width s max-cols 0 nil "…"))
     (t
      (let* ((budget (- max-cols 1))
             (head-w (/ budget 2))
             (tail-w (- budget head-w))
             (head (truncate-string-to-width s head-w 0 nil))
             (rev (reverse s))
             (tail (reverse (truncate-string-to-width rev tail-w 0 nil))))
        (concat head "…" tail))))))

(defun etaf-web--status-text (phase stage-label elapsed progress cached narrow
                                    &optional _spin-idx)
  "Format right-hand status string (pure text, zero graphic progress bar)."
  (pcase phase
    ('loading
     (let ((pct (round (* 100.0 (max 0.0 (min 1.0 (or progress 0.0)))))))
       (if narrow
           (format "%d%%" pct)
         (format "%s %d%% · %.1fs"
                 (or stage-label "加载中")
                 pct
                 (max 0.0 (or elapsed 0.0))))))
    ('error
     (if narrow "✕" "失败"))
    (_
     (if narrow
         ""
       (if cached "缓存" "")))))

;;; ---------------------------------------------------------------------------
;;; Constant-height 1lh top bar, loading skeleton & error block
;;; ---------------------------------------------------------------------------

(defun etaf-web--header-view (session width narrow)
  "Render constant-height 1lh top bar for SESSION at viewport WIDTH.
Layout: [后退 前进 刷新/停止] │ [full URL incl. https://] [text status].
Narrow (<72ch): [‹ › ⟳/×] │ [https://host/…tail] [38%]."
  (let* ((url (etaf-value (plist-get session :url)))
         (phase (etaf-value (plist-get session :phase)))
         (loading-p (eq phase 'loading))
         (stage-label (etaf-value (plist-get session :stage-label)))
         (progress (etaf-value (plist-get session :progress-display)))
         (cached (etaf-value (plist-get session :cached)))
         (can-back (etaf-value (plist-get session :can-back)))
         (can-forward (etaf-value (plist-get session :can-forward)))
         (editing (etaf-value (plist-get session :address-editing)))
         (chrome-gen (etaf-value (plist-get session :chrome-gen)))
         (draft (plist-get session :address-draft))
         (callbacks (plist-get session :callbacks))
         (parts (etaf-web--url-display-parts url))
         (scheme (nth 0 parts))
         (host (nth 1 parts))
         (path (nth 2 parts))
         (left-reserve (if narrow 10 21))
         (right-reserve (cond
                         (editing (if narrow 10 31))
                         (loading-p (if narrow 6 22))
                         (narrow 4)
                         (t 10)))
         (addr-budget (max 12 (- width left-reserve right-reserve)))
         (prefix-w (+ (string-width scheme) (string-width host)))
         (path-shown (if (> (+ prefix-w (string-width path)) addr-budget)
                         (etaf-web--middle-truncate
                          path (max 4 (- addr-budget prefix-w)))
                       path))
         (elapsed (if (and loading-p (plist-get session :started-at))
                      (- (float-time) (plist-get session :started-at))
                    0.0))
         (status-str (etaf-web--status-text
                      phase stage-label elapsed progress cached narrow))
         (status-color (pcase phase
                         ('loading (etaf-theme-token :ui-accent "#61afef"))
                         ('error (etaf-theme-token :ui-danger-fg "#e06c75"))
                         (_ (etaf-theme-token :ui-muted-fg "#8b99a4"))))
         (border-line (etaf-web--border-token :ui-border "#3b474f" 1))
         (fg-tok (etaf-theme-token :ui-fg "#dcdfe4"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#8b99a4"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#55626c"))
         (sep-tok (etaf-theme-token :ui-border "#3b474f"))
         (danger-tok (etaf-theme-token :ui-danger-fg "#e06c75")))
    (etaf-node
     'flex
     (list :ref 'web-header :id "web-header"
           :width 'stretch
           :align-items 'center
           :column-gap '(ch 1)
           :padding '((lh 0) (ch 1))
           :border-bottom border-line)
     (list
      ;; Left: fixed-order, fixed-width actions (disabled stays muted, never hidden).
      (etaf-node
       'flex
       (list :key (format "web-actions-%d" chrome-gen)
             :align-items 'center :column-gap '(ch 1) :flex-shrink 0)
       (list
        (etaf-view
         (etaf-button
          :label (if narrow "‹" "后退")
          :variant 'ghost :ref 'web-back
          :disabled (not can-back)
          :pointer (when can-back 'hand)
          :color (if can-back fg-tok dim-tok)
          :aria-label "后退" :help-echo "后退 (M-← / B)"
          :padding '((lh 0) (ch 0))
          :on-press (plist-get callbacks :back)))
        (etaf-view
         (etaf-button
          :label (if narrow "›" "前进")
          :variant 'ghost :ref 'web-forward
          :disabled (not can-forward)
          :pointer (when can-forward 'hand)
          :color (if can-forward fg-tok dim-tok)
          :aria-label "前进" :help-echo "前进 (M-→ / F)"
          :padding '((lh 0) (ch 0))
          :on-press (plist-get callbacks :forward)))
        (if loading-p
            (etaf-view
             (etaf-button
              :label (if narrow "×" "停止")
              :variant 'ghost :ref 'web-stop
              :pointer 'hand
              :color danger-tok
              :aria-label "停止加载" :help-echo "停止加载 (x)"
              :padding '((lh 0) (ch 0))
              :on-press (plist-get callbacks :stop)))
          (etaf-view
           (etaf-button
            :label (if narrow "⟳" "刷新")
            :variant 'ghost :ref 'web-reload
            :pointer 'hand
            :color fg-tok
            :aria-label "刷新" :help-echo "重新抓取当前页 (r)"
            :padding '((lh 0) (ch 0))
            :on-press (plist-get callbacks :reload))))))
      (etaf-node 'box (list :flex-shrink 0)
                 (list (etaf-node 'text (list :color sep-tok) (list "│"))))
      ;; Middle: full URL (ALWAYS showing scheme + host + path) or inline editor.
      (if editing
          (etaf-node
           'box
           (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 10)
                 :on-focus-enter (plist-get callbacks :address-focus-return))
           (list
            (etaf-view
             (etaf-text-input
              :bind draft
              :label "地址栏"
              :hide-label t
              :rows 1
              :width 'stretch
              :variant 'plain
              :placeholder "输入完整网址或本地 HTML 路径…"
              :submit-on-return t
              :ref 'web-address-input
              :completion-functions (list (plist-get callbacks :address-capf))
              :on-submit (plist-get callbacks :address-submit)
              :on-cancel (plist-get callbacks :address-cancel)))))
        (etaf-node
         'flex
         (list :key (format "web-address-%d" chrome-gen)
               :ref 'web-address :id "web-address"
               :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 10)
               :align-items 'center
               :role 'button :tab-index 0 :pointer 'hand
               :aria-label (format "地址 %s" url)
               :help-echo "按 g / C-l 或点击编辑地址"
               :on-press (plist-get callbacks :focus-address))
         (delq nil
               (list
                (unless (string-empty-p scheme)
                  (etaf-node 'box (list :flex-shrink 0)
                             (list (etaf-node 'text (list :color muted-tok)
                                              (list scheme)))))
                (unless (string-empty-p host)
                  (etaf-node 'box (list :flex-shrink 0)
                             (list (etaf-node 'text (list :font-weight 'bold :color fg-tok)
                                              (list host)))))
                (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
                           (list (etaf-node 'text (list :color muted-tok)
                                            (list path-shown))))))))
      ;; Right: same-row pure-text status slot (retained Host updated in-place).
      (etaf-node
       'box
       (list :flex-shrink 0)
       (list
        (if editing
            (etaf-node 'text (list :color muted-tok)
                       (list (if narrow
                                 "RET · ESC"
                               "RET 打开 · TAB 补全 · ESC 取消")))
          (etaf-node 'text
                     (list :ref 'web-status :id "web-status"
                           :color status-color)
                     (list status-str)))))))))

(defun etaf-web--loading-skeleton-view (session measure)
  "Render fresh-page loading skeleton centered inside MEASURE on frame bg."
  (let* ((url (etaf-value (plist-get session :url)))
         (stage (etaf-value (plist-get session :stage-label)))
         (muted-tok (etaf-theme-token :ui-muted-fg "#8b99a4"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#55626c"))
         (title-w (min measure (max 16 (/ (* measure 45) 100))))
         (line1-w (min measure (max 20 (/ (* measure 92) 100))))
         (line2-w (min measure (max 20 (/ (* measure 84) 100))))
         (line3-w (min measure (max 16 (/ (* measure 68) 100)))))
    (etaf-node
     'column
     (list :width 'stretch :cross-align 'center
           :padding '((lh 2) (ch 2)))
     (list
      (etaf-node
       'column
       (list :width (list 'ch measure) :item-gap '(lh 1))
       (list
        (etaf-node 'text (list :color muted-tok)
                   (list (format "正在加载 %s" (etaf-web--middle-truncate url measure))))
        (etaf-node 'text (list :color dim-tok)
                   (list (format "当前阶段：%s（Emacs 保持响应，按 x 停止）"
                                 (or stage "准备中"))))
        (etaf-view (etaf-skeleton :width (list 'ch title-w) :height '(lh 1)))
        (etaf-view (etaf-skeleton :width (list 'ch line1-w) :height '(lh 1)))
        (etaf-view (etaf-skeleton :width (list 'ch line2-w) :height '(lh 1)))
        (etaf-view (etaf-skeleton :width (list 'ch line3-w) :height '(lh 1)))))))))

(defun etaf-web--error-card-view (session measure)
  "Render Emacs-plain error block on frame background with left danger accent."
  (let* ((err (etaf-value (plist-get session :error-info)))
         (msg (or (plist-get err :message) "未知加载错误"))
         (url (or (plist-get err :url) (etaf-value (plist-get session :url)) ""))
         (has-cache (plist-get err :has-cache))
         (can-back (etaf-value (plist-get session :can-back)))
         (callbacks (plist-get session :callbacks))
         (danger-fg (etaf-theme-token :ui-danger-fg "#e06c75"))
         (danger-bar (etaf-web--border-token :ui-danger-border "#e06c75" 2))
         (accent-tok (etaf-theme-token :ui-accent "#61afef"))
         (fg-tok (etaf-theme-token :ui-fg "#dcdfe4"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#8b99a4"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#55626c"))
         (card-w (min measure (max 34 measure))))
    (etaf-node
     'column
     (list :width 'stretch :cross-align 'center
           :padding '((lh 2) (ch 2)))
     (list
      (etaf-node
       'column
       (list :width (list 'ch card-w)
             :padding '((lh 0) (ch 2))
             :item-gap '(lh 1)
             :border-left danger-bar)
       (list
        (etaf-node 'text (list :font-weight 'bold :color danger-fg)
                   (list "无法加载页面"))
        (etaf-node 'text (list :color fg-tok)
                   (list (format "原因：%s" msg)))
        (etaf-node 'text (list :color muted-tok)
                   (list (format "地址：%s" url)))
        (etaf-node 'text (list :color dim-tok)
                   (list "按 r 重试，按 o 在系统浏览器打开，或按 B / M-← 返回上页。"))
        (etaf-node
         'flex
         (list :width 'stretch :column-gap '(ch 2) :row-gap '(lh 1) :flex-wrap 'wrap)
         (delq nil
               (list
                (etaf-view
                 (etaf-button :label "[重试 (r)]" :variant 'ghost
                              :pointer 'hand
                              :color accent-tok
                              :padding '((lh 0) (ch 0))
                              :ref 'web-error-retry
                              :on-press (plist-get callbacks :reload)))
                (etaf-view
                 (etaf-button :label "[外部浏览器 (o)]" :variant 'ghost
                              :pointer 'hand
                              :color fg-tok
                              :padding '((lh 0) (ch 0))
                              :ref 'web-error-browser
                              :on-press (plist-get callbacks :open-external)))
                (when can-back
                  (etaf-view
                   (etaf-button :label "[返回上页 (B)]" :variant 'ghost
                                :pointer 'hand
                                :color fg-tok
                                :padding '((lh 0) (ch 0))
                                :ref 'web-error-back
                                :on-press (plist-get callbacks :back))))
                (when has-cache
                  (etaf-view
                   (etaf-button :label "[查看旧缓存]" :variant 'ghost
                                :pointer 'hand
                                :color muted-tok
                                :padding '((lh 0) (ch 0))
                                :ref 'web-error-cached
                                :on-press (plist-get callbacks :load-cached)))))))))))))

(defun etaf-web--body-viewport (child)
  "Return CHILD as the scrollable page viewport.
The toolbar is a sibling above it, so scrolling the page cannot move the
toolbar, and no scroll hook or per-frame repaint is involved."
  (etaf-node 'box
             (list :ref 'web-scroll :id "web-scroll"
                   :width 'stretch
                   :height 'stretch
                   :min-height '(lh 0)
                   :overflow 'scroll
                   :role 'region
                   :tab-index 0
                   :aria-label "网页正文")
             (list (etaf-node 'column (list :width 'stretch :height 'auto)
                              (list child)))))

(defun etaf-web--body-view (session measure)
  "Render main content area for SESSION inside MEASURE columns.
Wraps `etaf-md-view' under a `:key' tied to `:md-gen' so installing a new
document cleanly remounts `etaf-md-app' with fresh `:bindings' (never stuck on
the previous page), while in-tab loading keeps the previous key and stays
in-place with zero vertical jitter."
  (let ((phase (etaf-value (plist-get session :phase)))
        (md-session (etaf-value (plist-get session :md-session)))
        (md-gen (etaf-value (plist-get session :md-gen))))
    (etaf-web--body-viewport
     (pcase phase
       ('error
        (etaf-web--error-card-view session measure))
       ('loading
        (if md-session
            (etaf-node 'box (list :key md-gen :width 'stretch)
                       (list (etaf-md-view md-session)))
          (etaf-web--loading-skeleton-view session measure)))
       (_
        (if md-session
            (etaf-node 'box (list :key md-gen :width 'stretch)
                       (list (etaf-md-view md-session)))
          (etaf-web--loading-skeleton-view session measure)))))))

(etaf-define-component etaf-web--browser-app (&key session keys)
  "Root Component of an `etaf-web' browser buffer."
  :bindings ((mode (plist-get session :theme-mode))
             (tokens (etaf-computed
                      (lambda () (etaf-web--theme-tokens (etaf-value mode)))
                      :name 'etaf-web-theme-tokens)))
  :setup
  (progn
    (etaf-theme-provide tokens)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme tokens :mode mode
                            :modes '((light . "亮") (auto . "随")
                                     (dark . "暗") (sepia . "纸")))))
  :render
  (let* ((vw (max 44 (or (etaf-value (plist-get session :viewport-width)) 96)))
         (narrow (< vw etaf-web--narrow-breakpoint))
         (measure (min etaf-web--max-measure (max etaf-web--min-measure (- vw 4))))
         (editing (etaf-value (plist-get session :address-editing)))
         (callbacks (plist-get session :callbacks))
         (cur-mode (etaf-value mode))
         (bg-tok (unless (eq cur-mode 'auto)
                   (etaf-theme-token :ui-bg "#191a1c")))
         (fg-tok (etaf-theme-token :ui-fg "#dcdfe4")))
    (etaf-node
     'column
     (append (list :width '(vw 100)
                   :height '(vh 100)
                   :min-height '(lh 0)
                   :keys keys
                   :color fg-tok
                   :aria-label "ETAF Web 浏览器")
             (when bg-tok
               (list :background-color bg-tok))
             (when editing
               (list :on-dismiss (plist-get callbacks :address-dismiss))))
     (list
      (etaf-web--header-view session vw narrow)
      (etaf-web--body-view session measure)))))

(provide 'etaf-web-views)
;;; etaf-web-views.el ends here
