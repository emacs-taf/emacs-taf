;;; etaf-ext-gui-verify.el --- Real graphical Emacs GUI verification for etaf-ext ecosystem -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Automated real-GUI verification runner exercising the pure `etaf-ext' engine
;; together with native extension packages (`etaf-translate', `etaf-hints',
;; `etaf-highlight') and standalone `etaf-devtools' across light/dark themes
;; and wide/narrow viewports, capturing real macOS screenshots.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-posframe)
(require 'etaf-ext)
(require 'etaf-hints)
(require 'etaf-highlight)
(require 'etaf-translate)
(require 'etaf-devtools)

(defvar etaf-ext-gui--out-dir nil
  "Directory receiving verification screenshots and report JSON.")

(defvar etaf-ext-gui--results nil
  "Accumulated check records for the verification report.")

(defun etaf-ext-gui--settle (&optional seconds)
  "Allow Emacs redisplay, timers and Ebox refit tasks to settle."
  (let ((deadline (+ (float-time) (or seconds 0.35))))
    (while (< (float-time) deadline)
      (redisplay t)
      (sit-for 0.04 t)))
  (redisplay t))

(defun etaf-ext-gui--capture (filename &optional include-posframe)
  "Capture this Emacs process's visible frame to FILENAME inside out-dir."
  (etaf-ext-gui--settle 0.30)
  (let* ((path (expand-file-name filename etaf-ext-gui--out-dir))
         (pid (number-to-string (emacs-pid)))
         (jxa
          (format
           "ObjC.import('CoreGraphics');
var pid = %s;
var wins = ObjC.deepUnwrap(ObjC.castRefToObject(
  $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
var cands = wins.filter(function(w) {
  var b = w.kCGWindowBounds;
  return w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0 &&
         w.kCGWindowAlpha > 0 && b && b.Width > 200 && b.Height > 120;
});
cands.sort(function(a, b) {
  return (b.kCGWindowBounds.Width * b.kCGWindowBounds.Height) -
         (a.kCGWindowBounds.Width * a.kCGWindowBounds.Height);
});
if (!cands.length) { throw new Error('No Emacs window for PID ' + pid); }
var w = cands[0];
var b = w.kCGWindowBounds;
[w.kCGWindowNumber, Math.round(b.X), Math.round(b.Y), Math.round(b.Width), Math.round(b.Height)].join(',');"
           pid))
         (raw (string-trim
               (with-output-to-string
                 (let ((status (call-process "osascript" nil standard-output nil
                                             "-l" "JavaScript" "-e" jxa)))
                   (unless (eql status 0)
                     (error "osascript window lookup failed (%s)" status))))))
         (parts (split-string raw ","))
         (wid (nth 0 parts))
         (rect (format "%s,%s,%s,%s"
                       (nth 1 parts) (nth 2 parts) (nth 3 parts) (nth 4 parts)))
         (args (if include-posframe
                   (list "-R" rect "-x" path)
                 (list "-l" wid "-o" "-x" path)))
         (rc (apply #'call-process "/usr/sbin/screencapture" nil nil nil args)))
    (unless (and (eql rc 0) (file-exists-p path) (> (file-attribute-size (file-attributes path)) 1024))
      (error "screencapture failed for %s (exit=%s)" path rc))
    path))

(defun etaf-ext-gui--record (name pass &rest extra)
  "Record verification step NAME with boolean PASS and EXTRA plist fields."
  (push (append (list :name name :pass (if pass t :false)) extra)
        etaf-ext-gui--results)
  (unless pass
    (error "GUI verification failed at %s: %S" name extra)))

(defun etaf-ext-gui--check-overflow (buf &optional check-vertical)
  "Return horizontal (and optionally vertical) pixel metrics vs window body."
  (let* ((win (get-buffer-window buf t))
         (body-px (and (window-live-p win) (window-body-width win t)))
         (body-h (and (window-live-p win) (window-body-height win t)))
         (max-px 0)
         (total-h 0))
    (when (and (buffer-live-p buf) (window-live-p win))
      (with-current-buffer buf
        (setq total-h
              (or (cdr (window-text-pixel-size win (point-min) (point-max) nil nil t))
                  0))
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((eol (line-end-position))
                   (sz (window-text-pixel-size win (line-beginning-position) eol nil nil t))
                   (w (car sz)))
              (when (> w max-px) (setq max-px w)))
            (forward-line 1)))))
    (list :max-px max-px :body-px (or body-px 0)
          :total-h total-h :body-h (or body-h 0)
          :overflow-p (or (and body-px (> max-px (+ body-px 4)))
                          (and check-vertical body-h (> total-h body-h))))))

(defun etaf-ext-gui--set-theme (mode)
  "Switch Emacs graphical frame cleanly to `light', `dark' or `slate-dark' MODE."
  (mapc #'disable-theme custom-enabled-themes)
  (pcase mode
    ('slate-dark
     (load-theme 'modus-vivendi t)
     (set-face-attribute 'default nil :background "#263238" :foreground "#eceff1")
     (set-face-attribute 'link nil :foreground "#64b5f6")
     (set-face-attribute 'shadow nil :foreground "#9aaab2")
     (when (boundp 'enable-theme-functions)
       (run-hook-with-args 'enable-theme-functions 'modus-vivendi)))
    ('dark
     (set-face-attribute 'default nil :background 'unspecified :foreground 'unspecified)
     (load-theme 'modus-vivendi t))
    (_
     (set-face-attribute 'default nil :background 'unspecified :foreground 'unspecified)
     (load-theme 'modus-operandi t)))
  (etaf-ext-gui--settle 0.35))

(defun etaf-ext-gui--resize (cols rows)
  "Resize selected graphical frame to COLS by ROWS and wait for refit."
  (set-frame-size (selected-frame) cols rows)
  (etaf-ext-gui--settle 0.45))

(defun etaf-ext-gui--find-text-host (tree substr)
  "Return first text Host ID in TREE containing SUBSTR."
  (let ((found nil))
    (cl-labels ((walk (node)
                  (when (and (not found) (listp node))
                    (when (and (eq (plist-get node :tag) 'text)
                               (stringp (plist-get node :text))
                               (string-search substr (plist-get node :text)))
                      (setq found (plist-get node :id)))
                    (dolist (c (plist-get node :children)) (walk c)))))
      (dolist (r tree) (walk r)))
    found))

(defun etaf-ext-gui--build-article-view (clicks-ref theme-ref)
  "Build a realistic ETAF demo article View for multi-package testing."
  (etaf-define-component etaf-ext-gui--article (&key clicks theme)
    :setup (progn (etaf-theme-provide theme) nil)
    :render
    (let* ((th (etaf-value theme))
           (bg (plist-get th :ui-bg))
           (panel (plist-get th :ui-panel-bg))
           (fg (plist-get th :ui-fg))
           (muted (plist-get th :ui-muted-fg))
           (border (plist-get th :ui-border))
           (accent (plist-get th :ui-accent))
           (log (etaf-value clicks)))
      (etaf-node
       'column
       (list :width 'stretch :background-color bg :color fg
             :padding '((lh 1) (ch 3)) :item-gap '(lh 1))
       (list
        (etaf-node
         'flex (list :width 'stretch :justify-content 'space-between
                     :align-items 'center
                     :border-bottom (list '(px 1) 'solid border)
                     :padding '((lh 0) (ch 0) (lh 1) (ch 0)))
         (list
          (etaf-node 'text (list :id "article-title" :font-weight 'bold :color accent)
                     '("ETAF Modular Extensions — Multi-Package Coexistence"))
          (etaf-node 'text (list :color muted)
                     (list (format "交互记录: %s" (or log "待触发"))))))
        (etaf-node
         'column (list :width 'stretch :background-color panel
                       :border (list '(px 1) 'solid border)
                       :padding '((lh 1) (ch 2)) :item-gap '(lh 1))
         (list
          (etaf-node 'text (list :id "lead-para" :class "prose-lead" :color fg)
                     '("A pure extension engine keeps zero bundled plugins while independent packages compose seamlessly over the same ETAF Host tree."))
          (etaf-node 'text (list :id "second-para" :class "prose-body" :color fg)
                     '("Here etaf-translate, etaf-highlight, etaf-hints, and etaf-devtools run together on one document without coupling to each other."))))
        (etaf-node
         'flex (list :width 'stretch :gap '((lh 0) (ch 2)) :align-items 'center)
         (list
          (etaf-view
           (etaf-button :id "btn-upvote" :label "赞同文章" :variant 'primary :pointer 'hand
                        :on-press (lambda () (etaf-set-value clicks "已赞同文章"))))
          (etaf-view
           (etaf-button :id "btn-bookmark" :label "加入书签" :variant 'secondary :pointer 'hand
                        :on-press (lambda () (etaf-set-value clicks "已加入书签"))))
          (etaf-view
           (etaf-button :id "btn-export" :label "导出笔记" :variant 'ghost :pointer 'hand
                        :on-press (lambda () (etaf-set-value clicks "已导出笔记"))))))))))
  (etaf-view (etaf-ext-gui--article :clicks clicks-ref :theme theme-ref)))

(defun etaf-ext-gui--make-article-theme ()
  "Build clean `etaf-ui-theme-tokens' for the demo article from active frame."
  (let* ((dark (eq (etaf-appearance) 'dark))
         (bg (if dark "#14181E" "#FFFFFF"))
         (fg (if dark "#E2E8F0" "#1E293B"))
         (panel (if dark "#1C222B" "#F8FAFC"))
         (border (if dark "#334155" "#CBD5E1"))
         (muted (if dark "#94A3B8" "#475569"))
         (accent (if dark "#60A5FA" "#2563EB")))
    (etaf-ui-theme-tokens
     (list :bg bg :fg fg :panel panel :border border :muted muted
           :accent accent :accent-fg "#FFFFFF"))))

(defun etaf-ext-gui-run (out-dir)
  "Execute full real-GUI verification suite saving screenshots to OUT-DIR."
  (unless (display-graphic-p)
    (error "etaf-ext-gui-run requires a graphical Emacs frame"))
  (setq etaf-ext-gui--out-dir (expand-file-name out-dir)
        etaf-ext-gui--results nil)
  (make-directory etaf-ext-gui--out-dir t)
  (when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
  (when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
  (set-frame-parameter (selected-frame) 'title "ETAF-EXT-GUI-VERIFY")
  (select-frame-set-input-focus (selected-frame))
  (let* ((tmp-db (make-temp-file "etaf-ext-gui-" nil ".sqlite3"))
         (etaf-ext-storage-file tmp-db)
         (etaf-ext-use-posframe t)
         (etaf-translate-enable-disk-cache nil)
         (etaf-translate-state-file nil)
         (etaf-translate-use-posframe t)
         (etaf-translate-function-backend
          (lambda (text _src _tgt _gloss)
            (cond
             ((string-search "pure extension engine" text)
              "纯粹的扩展引擎不内置任何业务插件，所有独立扩展包在同一棵 ETAF Host 树上无缝叠加组合。")
             ((string-search "etaf-translate, etaf-highlight" text)
              "这里 etaf-translate、etaf-highlight、etaf-hints 与 etaf-devtools 四个独立包同时运行且彼此零耦合。")
             (t (concat "【译】" text)))))
         (clicks-ref (etaf-ref nil))
         (theme-ref nil)
         (art-buf nil)
         (art-rt nil)
         (mgr-buf nil)
         (theme-hook nil))
    (unwind-protect
        (progn
          (etaf-ext-mode 1)
          (etaf-ext-gui--set-theme 'light)
          (etaf-ext-gui--resize 132 36)
          (setq theme-ref (etaf-ref (etaf-ext-gui--make-article-theme)))
          (setq theme-hook (lambda (&rest _)
                             (etaf-set-value theme-ref (etaf-ext-gui--make-article-theme))))
          (add-hook 'enable-theme-functions theme-hook)

          (setq art-buf
                (etaf-app-open
                 "*ETAF 多包扩展演示*"
                 (etaf-ext-gui--build-article-view clicks-ref theme-ref)
                 :mode-line t
                 :meta '(:app etaf-web :kind document
                              :uri "https://etaf.top/guide/modular-ext"
                              :title "ETAF 模块化扩展架构")
                 :background (lambda () (plist-get (etaf-value theme-ref) :ui-bg))
                 :foreground (lambda () (plist-get (etaf-value theme-ref) :ui-fg))))
          (setq art-rt (etaf-runtime-for-buffer art-buf))
          (etaf-ext-gui--settle 0.35)

          ;; Activate independent packages: translate + highlight + hints
          (let* ((tree (etaf-runtime-host-tree art-rt))
                 (p1 (etaf-ext-gui--find-text-host tree "pure extension engine"))
                 (p2 (etaf-ext-gui--find-text-host tree "etaf-translate, etaf-highlight")))
            (etaf-translate-enable art-rt :engine 'function :mode 'bilingual-stacked
                                   :style 'left-bar :source-lang "en" :target-lang "zh-CN")
            (etaf-highlight-apply art-rt p1 2 23 :color 'yellow
                                  :note "独立包架构：零内置插件，按需组合")
            (etaf-highlight-apply art-rt p2 5 66 :color 'green)
            (let ((codes (etaf-hints-start art-rt)))
              (etaf-ext-gui--settle 0.35)
              (let* ((ov (etaf-ext-gui--check-overflow art-buf))
                     (shot (etaf-ext-gui--capture "01-coexist-light.png")))
                (etaf-ext-gui--record
                 "coexist-light"
                 (and (>= (length codes) 3)
                      (not (plist-get ov :overflow-p))
                      (not (null (buffer-local-value 'mode-line-format art-buf))))
                 :screenshot shot :codes-count (length codes) :overflow ov))

              ;; Dark mode
              (etaf-ext-gui--set-theme 'dark)
              (let ((shot (etaf-ext-gui--capture "02-coexist-dark.png")))
                (etaf-ext-gui--record
                 "coexist-dark"
                 (eq (etaf-appearance) 'dark)
                 :screenshot shot))

              ;; Activate 2nd hint ("加入书签")
              (let ((res (etaf-hints-input (car (nth 1 codes)) art-rt)))
                (etaf-ext-gui--settle 0.25)
                (etaf-ext-gui--record
                 "hints-activate-button"
                 (and (eq res :activated)
                      (equal (etaf-value clicks-ref) "已加入书签")
                      (null (etaf-hints-active-codes art-rt)))
                 :clicked (etaf-value clicks-ref)))

              ;; Open standalone etaf-devtools alongside all active extensions!
              (etaf-devtools-open art-rt)
              (etaf-ext-gui--settle 0.45)
              (let ((shot (etaf-ext-gui--capture "03-coexist-with-devtools-dark.png")))
                (etaf-ext-gui--record
                 "coexist-devtools"
                 t
                 :screenshot shot))
              (etaf-devtools-close)

              ;; ONE Pure Mode toggle wipes ALL extensions (translate + highlight + hints) cleanly!
              (etaf-ext-pure-mode-toggle art-rt)
              (etaf-ext-gui--settle 0.35)
              (let* ((txt (with-current-buffer art-buf
                            (buffer-substring-no-properties (point-min) (point-max))))
                     (shot (etaf-ext-gui--capture "04-pure-mode-dark.png")))
                (etaf-ext-gui--record
                 "pure-mode-clean"
                 (and (etaf-ext-pure-mode-p art-rt)
                      (not (string-search "独立包架构" txt))
                      (not (string-search "纯粹的扩展引擎" txt))
                      (string-search "pure extension engine" txt))
                 :screenshot shot))
              (etaf-ext-pure-mode-toggle art-rt)
              (etaf-ext-gui--settle 0.25)))

          ;; Manager UI across ultrawide slate-dark, wide dark/light, compact, narrow & floating popup!
          (setq mgr-buf (etaf-ext-manage art-rt))
          (etaf-ext-gui--set-theme 'slate-dark)
          (etaf-ext-gui--resize 192 44)
          (let* ((ov (etaf-ext-gui--check-overflow mgr-buf t))
                 (shot (etaf-ext-gui--capture "05-manager-ultrawide-slate.png")))
            (etaf-ext-gui--record
             "manager-ultrawide-slate"
             (and (buffer-live-p mgr-buf)
                  (not (plist-get ov :overflow-p)))
             :screenshot shot :overflow ov))

          ;; Zero-jitter verification: switching selection via `j' must keep exact pixel X/Y of cards!
          (let* ((win (get-buffer-window mgr-buf t))
                 (measure-left-xy
                  (lambda (substr)
                    (with-current-buffer mgr-buf
                      (save-excursion
                        (goto-char (point-min))
                        (let ((best nil))
                          (while (search-forward substr nil t)
                            (let ((xy (posn-x-y (posn-at-point (match-beginning 0) win))))
                              (when (and xy (or (null best) (< (car xy) (car best))))
                                (setq best xy))))
                          (when best (list (car best) (cdr best))))))))
                 (p1-before (funcall measure-left-xy "沉浸式翻译"))
                 (p2-before (funcall measure-left-xy "快捷跳转")))
            (select-window win)
            (with-current-buffer mgr-buf
              (let ((unread-command-events nil))
                (execute-kbd-macro (kbd "j"))))
            (etaf-ext-gui--settle 0.25)
            (let ((p1-after (funcall measure-left-xy "沉浸式翻译"))
                  (p2-after (funcall measure-left-xy "快捷跳转")))
              (etaf-ext-gui--record
               "manager-selection-zero-jitter"
               (and p1-before p2-before
                    (equal p1-before p1-after)
                    (equal p2-before p2-after))
               :card1-before p1-before :card1-after p1-after
               :card2-before p2-before :card2-after p2-after))
            (select-window win)
            (with-current-buffer mgr-buf
              (let ((unread-command-events nil))
                (execute-kbd-macro (kbd "k"))))
            (etaf-ext-gui--settle 0.20))

          (etaf-ext-gui--set-theme 'dark)
          (etaf-ext-gui--resize 132 36)
          (let* ((ov (etaf-ext-gui--check-overflow mgr-buf t))
                 (shot (etaf-ext-gui--capture "06-manager-wide-dark.png")))
            (etaf-ext-gui--record
             "manager-wide-dark"
             (not (plist-get ov :overflow-p))
             :screenshot shot :overflow ov))

          (etaf-ext-gui--set-theme 'light)
          (select-window (get-buffer-window mgr-buf t))
          (execute-kbd-macro (kbd "j"))
          (etaf-ext-gui--settle 0.25)
          (let* ((ov (etaf-ext-gui--check-overflow mgr-buf t))
                 (shot (etaf-ext-gui--capture "07-manager-wide-light.png")))
            (etaf-ext-gui--record
             "manager-wide-light"
             (not (plist-get ov :overflow-p))
             :screenshot shot :overflow ov))

          (etaf-ext-gui--set-theme 'slate-dark)
          (etaf-ext-gui--resize 96 32)
          (let* ((ov (etaf-ext-gui--check-overflow mgr-buf t))
                 (shot (etaf-ext-gui--capture "08-manager-compact-slate.png")))
            (etaf-ext-gui--record
             "manager-compact-slate"
             (not (plist-get ov :overflow-p))
             :screenshot shot :overflow ov))

          (etaf-ext-gui--set-theme 'light)
          (etaf-ext-gui--resize 64 28)
          (let* ((ov (etaf-ext-gui--check-overflow mgr-buf t))
                 (shot (etaf-ext-gui--capture "09-manager-narrow-light.png")))
            (etaf-ext-gui--record
             "manager-narrow-light"
             (not (plist-get ov :overflow-p))
             :screenshot shot :overflow ov))

          (etaf-app-close mgr-buf)
          (etaf-ext-gui--record "manager-quit-clean" (not (buffer-live-p mgr-buf)))

          ;; Verify centered floating posframe manager (`etaf-ext-manage-popup')
          (switch-to-buffer art-buf)
          (etaf-ext-gui--set-theme 'slate-dark)
          (etaf-ext-gui--resize 148 40)
          (let ((panel (etaf-ext-manage-popup art-rt)))
            (etaf-ext-gui--settle 0.45)
            (let ((shot (etaf-ext-gui--capture "10-manager-popup-posframe.png" t)))
              (etaf-ext-gui--record
               "manager-popup-posframe"
               (and panel (etaf-posframe-live-p panel))
               :screenshot shot))
            ;; Second call toggles popup closed cleanly
            (let ((res2 (etaf-ext-manage-popup art-rt)))
              (etaf-ext-gui--record "manager-popup-close-clean"
                                    (and (null res2)
                                         (not (etaf-posframe-live-p panel))))))

          (let ((report-path (expand-file-name "gui-verify-report.json" etaf-ext-gui--out-dir)))
            (with-temp-file report-path
              (insert (json-encode (list :status "PASS"
                                         :checks (vconcat (nreverse etaf-ext-gui--results))))))))
      (ignore-errors (etaf-devtools-close))
      (when theme-hook
        (remove-hook 'enable-theme-functions theme-hook))
      (when (and mgr-buf (buffer-live-p mgr-buf))
        (ignore-errors (etaf-app-close mgr-buf)))
      (when (and art-buf (buffer-live-p art-buf))
        (ignore-errors (etaf-app-close art-buf)))
      (dolist (f (list tmp-db (concat tmp-db "-wal") (concat tmp-db "-shm")))
        (when (file-exists-p f)
          (ignore-errors (delete-file f)))))))

(provide 'etaf-ext-gui-verify)
;;; etaf-ext-gui-verify.el ends here
