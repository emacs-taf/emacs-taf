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
(require 'image)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc)
(require 'etaf-md)
(require 'etaf-web-cache)
(require 'etaf-web-adapter)

(declare-function image-size "image.c" (spec &optional pixels frame))

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

(defun etaf-web--hex-color (color)
  "Convert COLOR (hex or Emacs named color) to `#RRGGBB', or return COLOR."
  (if (and (stringp color)
           (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" color))
      color
    (let ((rgb (and (stringp color) (ignore-errors (color-name-to-rgb color)))))
      (if rgb
          (apply #'color-rgb-to-hex (append rgb '(2)))
        color))))

(defun etaf-web--face-color (face attr fallback)
  "Return valid `#RRGGBB' color for FACE ATTR on the selected frame, or FALLBACK."
  (let ((val (ignore-errors (face-attribute face attr nil 'default))))
    (if (and (stringp val)
             (not (string-empty-p val))
             (not (string-prefix-p "unspecified" val)))
        (etaf-web--hex-color val)
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
  "Return `etaf-ui-theme-tokens' plist for browser MODE.
Explicitly derives input, search, hover, selection, soft-border, divider and
sidebar surface tokens from the active palette so controls stay legible and
harmonious in both light and dark themes."
  (let* ((pal (etaf-web--palette mode))
         (bg (plist-get pal :bg))
         (fg (plist-get pal :fg))
         (accent (plist-get pal :accent))
         (border (plist-get pal :border))
         (dark-p (pcase mode
                   ('dark t)
                   ((or 'light 'sepia) nil)
                   (_ (eq (etaf-appearance) 'dark))))
         (sidebar-bg (if dark-p
                         (etaf-web--blend-color "#000000" bg 0.16)
                       (etaf-web--blend-color fg bg 0.03)))
         (code-bg (if dark-p
                      (etaf-web--blend-color "#000000" bg 0.16)
                    (etaf-web--blend-color fg bg 0.04)))
         (hover-bg (if dark-p
                       (etaf-web--blend-color "#ffffff" bg 0.055)
                     (etaf-web--blend-color fg bg 0.045)))
         (selected-bg (if dark-p
                          (etaf-web--blend-color accent bg 0.18)
                        (etaf-web--blend-color accent bg 0.10)))
         (op-bg (if dark-p
                    (etaf-web--blend-color "#000000" bg 0.15)
                  (etaf-web--blend-color accent bg 0.045)))
         (border-soft (if dark-p
                          (etaf-web--blend-color fg bg 0.11)
                        (etaf-web--blend-color fg bg 0.09)))
         (dot-purple (if dark-p "#b48ead" "#8250df"))
         (dot-teal (if dark-p "#56b6c2" "#1b7c83")))
    (append
     (list :ui-input-bg bg
           :ui-input-border border
           :ui-search-bg bg
           :ui-search-fg fg
           :ui-divider-bg border
           :ui-accent-soft-bg selected-bg
           :web-sidebar-bg sidebar-bg
           :web-code-bg code-bg
           :web-hover-bg hover-bg
           :web-selected-bg selected-bg
           :web-op-bg op-bg
           :web-border-soft border-soft
           :web-dot-purple dot-purple
           :web-dot-teal dot-teal)
     (etaf-ui-theme-tokens pal))))

;;; ---------------------------------------------------------------------------
;;; Shared ordinary flat input & embedded Markdown block renderer
;;; ---------------------------------------------------------------------------

(cl-defun etaf-web--plain-input-view
    (&key bind value on-change ref key (label "输入") (placeholder "")
          (width 'stretch) (rows 1) disabled on-submit on-clear on-cancel
          keymap icon)
  "Render an ordinary flat outlined text input aligned with frame theme.
When ICON (an `etaf-ui-icon' symbol such as `search') is given for a single-line
field, wraps a quiet leading icon, plain input and optional inline clear icon
inside one crisp 1px outlined box matching the active frame canvas."
  (let* ((cur (or (if bind (etaf-value bind) value) ""))
         (non-empty (and (stringp cur) (not (string-empty-p cur))))
         (can-clear (and (eql rows 1) non-empty (not disabled)
                         (or on-clear bind on-change)))
         (use-shell (and icon (eql rows 1)))
         (muted-tok (etaf-theme-token :ui-muted-fg "#8b99a4"))
         (dim-tok (etaf-theme-token :ui-disabled-fg "#6e7681"))
         (border-tok (etaf-theme-token :ui-border "#36444c"
                                       (lambda (c) (list '(px 1) 'solid c))))
         (do-clear (lambda ()
                     (cond
                      (bind (etaf-set-value bind ""))
                      ((functionp on-change) (funcall on-change "")))
                     (when (functionp on-clear)
                       (funcall on-clear))))
         (field-props
          (append
           (list :label label
                 :hide-label t
                 :placeholder placeholder
                 :rows rows
                 :width 'stretch
                 :variant (if use-shell 'plain 'outlined)
                 :submit-on-return (eql rows 1))
           (when disabled (list :disabled t))
           (if bind
               (list :bind bind)
             (append (list :value cur)
                     (when on-change (list :on-change on-change))))
           (when ref (list :ref ref))
           (when on-submit (list :on-submit on-submit))
           (when on-cancel (list :on-cancel on-cancel))
           (when keymap (list :keymap keymap))))
         (input-node (etaf-node 'etaf-text-input field-props nil))
         (key-prop (when key (list :key key))))
    (cond
     (use-shell
      (etaf-node
       'flex (append key-prop
                     (list :width width
                           :align-items 'center
                           :column-gap '(ch 1)
                           :padding '((lh 0) (ch 1))
                           :border border-tok))
       (delq
        nil
        (list
         (etaf-node 'box (list :key 'icon :flex-shrink 0)
                    (list (etaf-ui-icon icon :set 'svg :min-width 1
                                        :color dim-tok)))
         (etaf-node 'box (list :key 'field :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 6))
                    (list input-node))
         (when can-clear
           (etaf-node 'box (list :key 'clear :flex-shrink 0)
                      (list (etaf-ui-icon 'close :set 'svg :min-width 1
                                          :color muted-tok
                                          :aria-label "清空"
                                          :help-echo "清空输入"
                                          :on-press do-clear))))))))
     ((eql rows 1)
      ;; Keep a stable flex wrapper whether empty or non-empty so toggling the
      ;; trailing clear button never unmounts `etaf-text-input' mid-edit.
      (etaf-node
       'flex (append key-prop
                     (list :width width :align-items 'center :column-gap '(ch 1)))
       (delq
        nil
        (list
         (etaf-node 'box (list :key 'field :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 6))
                    (list input-node))
         (when can-clear
           (etaf-node
            'box (list :key 'clear :flex-shrink 0)
            (list
             (etaf-view
              (etaf-button
               :label "×"
               :variant 'ghost
               :color muted-tok
               :padding '((lh 0) (ch 0))
               :aria-label "清空"
               :help-echo "清空输入"
               :on-press do-clear)))))))))
     ((and (eq width 'stretch) (null key))
      input-node)
     (t
      (etaf-node 'box (append key-prop (list :width width)) (list input-node))))))

(defun etaf-web--markdown-palette (mode)
  "Build `etaf-doc-markdown' semantic color alist derived from browser MODE."
  (let* ((pal (etaf-web--palette mode))
         (bg (plist-get pal :bg))
         (fg (plist-get pal :fg))
         (dark-p (pcase mode
                   ('dark t)
                   ((or 'light 'sepia) nil)
                   (_ (eq (etaf-appearance) 'dark))))
         (panel (if dark-p
                    (etaf-ui-color-mix bg "#000000" 0.14)
                  (etaf-ui-color-mix bg fg 0.04)))
         (panel2 (if dark-p
                     (etaf-ui-color-mix bg fg 0.07)
                   (etaf-ui-color-mix bg fg 0.07)))
         (quote-bg (if dark-p
                       (etaf-ui-color-mix bg "#000000" 0.08)
                     (etaf-ui-color-mix bg fg 0.02)))
         (accent (plist-get pal :accent))
         (accent-soft (if dark-p
                          (etaf-ui-color-mix bg accent 0.18)
                        (plist-get pal :accent-soft)))
         (border (plist-get pal :border))
         (ok (plist-get pal :success))
         (warn (plist-get pal :warning))
         (danger (plist-get pal :danger))
         (important (if dark-p "#a371f7" "#8250df")))
    (list (cons :bg bg)
          (cons :ink fg)
          (cons :muted (plist-get pal :muted))
          (cons :faint (plist-get pal :dim))
          (cons :heading (if dark-p (etaf-ui-color-mix fg "#ffffff" 0.18) fg))
          (cons :accent accent)
          (cons :accent-soft accent-soft)
          (cons :panel panel)
          (cons :panel2 panel2)
          (cons :code-bg panel)
          (cons :border border)
          (cons :quote-bg quote-bg)
          (cons :quote-bar (etaf-ui-color-mix border accent 0.45))
          (cons :table-header panel)
          (cons :table-stripe quote-bg)
          (cons :heading-rule border)
          (cons :ok ok)
          (cons :ok-soft (etaf-ui-color-mix bg ok 0.14))
          (cons :warn warn)
          (cons :warn-soft (etaf-ui-color-mix bg warn 0.14))
          (cons :danger danger)
          (cons :danger-soft (etaf-ui-color-mix bg danger 0.14))
          (cons :important important)
          (cons :important-soft (etaf-ui-color-mix bg important 0.14)))))

(defun etaf-web--inline-plain-text (inlines)
  "Extract plain text from parsed `etaf-doc-markdown-parse' INLINES."
  (mapconcat
   (lambda (n)
     (cond
      ((stringp n) n)
      ((listp n)
       (or (and (stringp (plist-get n :text)) (plist-get n :text))
           (and (listp (plist-get n :children))
                (etaf-web--inline-plain-text (plist-get n :children)))
           ""))
      (t "")))
   inlines ""))

(defun etaf-web--markdown-outline (doc)
  "Return outline list of `(LEVEL TEXT ID)' entries from parsed DOC."
  (let ((out nil))
    (dolist (blk (plist-get doc :children))
      (when (eq (plist-get blk :type) 'heading)
        (let ((lvl (or (plist-get blk :level) 1))
              (txt (string-trim (etaf-web--inline-plain-text (plist-get blk :children))))
              (id (plist-get blk :id)))
          (unless (string-empty-p txt)
            (push (list lvl txt id) out)))))
    (nreverse out)))

(defun etaf-web--embedded-media-view (kind node dir open-link max-cols)
  "Render embedded media NODE of KIND inside a sub-pane capped at MAX-COLS.
Resolves both relative paths under DIR and cached remote URLs inside
DIR/assets/, preserving natural or declared aspect ratios without distortion."
  (let* ((raw-url (or (plist-get node :url) ""))
         (raw-alt (string-trim (or (plist-get node :alt) "")))
         (alt (if (string-empty-p raw-alt) "图片" raw-alt))
         (decl-w (and (numberp (plist-get node :width))
                      (> (plist-get node :width) 0)
                      (plist-get node :width)))
         (decl-h (and (numberp (plist-get node :height))
                      (> (plist-get node :height) 0)
                      (plist-get node :height)))
         (remote (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" raw-url))
         (local-path
          (cond
           ((and (not remote) dir (not (string-empty-p raw-url)))
            (expand-file-name raw-url dir))
           ((and (string-prefix-p "file://" raw-url))
            (expand-file-name (substring raw-url 7)))
           ((and remote dir (etaf-web--http-url-p raw-url))
            (when-let* ((rel (etaf-web--existing-asset-for-url
                              raw-url (expand-file-name "assets" dir))))
              (expand-file-name rel dir)))
           (t nil)))
         (accent-tok (etaf-theme-token :ui-accent "#61afef"))
         (muted-tok (etaf-theme-token :ui-muted-fg "#8b99a4"))
         (border-tok (etaf-theme-token :web-border-soft "#eaeef2"
                                       (lambda (c) (list '(px 1) 'solid c)))))
    (cond
     ((and (not (eq kind 'inline-image))
           local-path (file-readable-p local-path)
           (display-graphic-p))
      (let* ((natural (ignore-errors (image-size (create-image local-path) t)))
             (nat-w (and natural (numberp (car natural)) (> (car natural) 0)
                         (float (car natural))))
             (nat-h (and natural (numberp (cdr natural)) (> (cdr natural) 0)
                         (float (cdr natural))))
             (tgt-w (cond
                     ((and decl-w nat-w) (min (float decl-w) nat-w))
                     (decl-w (float decl-w))
                     (nat-w nat-w)
                     (t 360.0)))
             (tgt-h (cond
                     ((and decl-h nat-h) (min (float decl-h) nat-h))
                     ((and decl-w nat-w nat-h) (* tgt-w (/ nat-h nat-w)))
                     (decl-h (float decl-h))
                     (nat-h nat-h)
                     (t 200.0)))
             (cell (etaf-web--cell-metrics))
             (cw (max 1.0 (float (car cell))))
             (ch (max 1.0 (float (cdr cell))))
             (cap-cols (max 16 (- (or max-cols 76) 2)))
             (cap-rows 26)
             (cols (max 8 (min cap-cols (round (/ tgt-w cw)))))
             (rows (max 2 (round (/ (* cols cw tgt-h) (max 1.0 (* tgt-w ch)))))))
        (when (> rows cap-rows)
          (setq rows cap-rows
                cols (max 8 (min cap-cols
                                 (round (/ (* rows ch tgt-w)
                                           (max 1.0 (* tgt-h cw))))))))
        (etaf-node
         'column (list :width 'stretch :item-gap '(lh 0))
         (delq nil
               (list
                (etaf-node
                 'box (append
                       (list :border border-tok)
                       (when (and open-link (not (string-empty-p raw-url)))
                         (list :role 'button :tab-index 0 :pointer 'hand
                               :help-echo (format "%s（按 RET 打开原图）" alt)
                               :on-press (lambda () (funcall open-link raw-url)))))
                 (list
                  (etaf-node 'image
                             (list :src local-path
                                   :columns cols
                                   :rows rows
                                   :adapter 'auto)
                             nil)))
                (unless (or (string-empty-p alt) (equal alt "图片"))
                  (etaf-node 'text (list :color muted-tok) (list alt))))))))
     (t
      (etaf-node
       'text
       (append (list :color accent-tok)
               (when (and open-link (not (string-empty-p raw-url)))
                 (list :role 'link :tab-index 0 :pointer 'hand
                       :help-echo raw-url
                       :on-press (lambda () (funcall open-link raw-url)))))
       (list (format "[图: %s]" alt)))))))

(defun etaf-web--container-attr (attrs key)
  "Extract double-quoted KEY attribute value from container ATTRS string."
  (when (and (stringp attrs)
             (string-match
              (format "\\(?:\\`\\|[ \t]\\)%s=\"\\(\\(?:\\\\.\\|[^\"\\\\]\\)*\\)\""
                      (regexp-quote key))
              attrs))
    (replace-regexp-in-string
     "\\\\\\(.\\)" "\\1" (match-string 1 attrs) t)))

(defun etaf-web--normalize-embedded-containers (markdown)
  "Convert `:::' container blocks in MARKDOWN for `etaf-doc-markdown-parse'.
Normalizes callouts (`:::note|tip|important|warning|caution'), `:::details',
`:::columns'/`:::col'/`:::card', `:::tabs' (`@tab'), `:::steps'/`:::step', and
`:::timeline'/`:::event' into native GFM alerts, blockquotes, and headings so
raw `:::' fences never leak inside Tier 2 Docs or Discourse split panes."
  (let ((lines (split-string (or markdown "") "\n"))
        (out nil)
        (in-code nil)
        (stack nil))
    (cl-labels
        ((quoted-p ()
           (cl-some (lambda (f) (plist-get f :quote)) stack))
         (emit-line (s)
           (if (quoted-p)
               (push (if (string-empty-p s) ">" (concat "> " s)) out)
             (push s out))))
      (dolist (line lines)
        (cond
         ((string-match-p "^[ \t]*\\(?:```\\|~~~\\)" line)
          (setq in-code (not in-code))
          (emit-line line))
         ((and (not in-code)
               (string-match
                "^:::\\([a-z]+\\)\\(?:[ \t]+{\\(.*\\)}\\)?[ \t]*$"
                line))
          (let* ((kind (downcase (match-string 1 line)))
                 (attrs (match-string 2 line))
                 (title (etaf-web--container-attr attrs "title"))
                 (href (etaf-web--container-attr attrs "href"))
                 (date (etaf-web--container-attr attrs "date")))
            (pcase kind
              ((or "note" "tip" "important" "warning" "caution")
               (push (list :kind 'alert :quote t) stack)
               (push (format "> [!%s]" (upcase kind)) out)
               (when (and title (not (string-empty-p title)))
                 (push (format "> **%s**" title) out)
                 (push ">" out)))
              ("details"
               (push (list :kind 'details :quote t) stack)
               (push (format "> **▸ %s**"
                             (if (and title (not (string-empty-p title)))
                                 title
                               "详情"))
                     out)
               (push ">" out))
              ((or "columns" "col" "timeline")
               (push (list :kind (intern kind) :quote nil) stack))
              ("tabs"
               (push (list :kind 'tabs :quote nil) stack))
              ("steps"
               (push (list :kind 'steps :quote nil :step-n 0) stack))
              ("step"
               (let* ((parent (cl-find-if (lambda (f) (eq (plist-get f :kind) 'steps))
                                          stack))
                      (n (if parent
                             (let ((next (1+ (or (plist-get parent :step-n) 0))))
                               (plist-put parent :step-n next)
                               next)
                           1)))
                 (push (list :kind 'step :quote nil) stack)
                 (push "" out)
                 (emit-line (if (and title (not (string-empty-p title)))
                                (format "#### %d. %s" n title)
                              (format "#### Step %d" n)))
                 (push "" out)))
              ("card"
               (push (list :kind 'card :quote t) stack)
               (when (and title (not (string-empty-p title)))
                 (push (if (and href (not (string-empty-p href)))
                           (format "> **[%s](%s)**" title href)
                         (format "> **%s**" title))
                       out)
                 (push ">" out)))
              ("event"
               (push (list :kind 'event :quote t) stack)
               (let ((hdr (cond
                           ((and date (not (string-empty-p date))
                                 title (not (string-empty-p title)))
                            (format "%s · %s" date title))
                           ((and title (not (string-empty-p title))) title)
                           ((and date (not (string-empty-p date))) date)
                           (t nil))))
                 (when hdr
                   (push (format "> **%s**" hdr) out)
                   (push ">" out))))
              (_
               (push (list :kind 'other :quote nil) stack)))))
         ((and (not in-code)
               (eq (plist-get (car stack) :kind) 'tabs)
               (string-match "^@tab[ \t]+\\(.+\\)$" line))
          (let ((label (string-trim (match-string 1 line))))
            (push "" out)
            (emit-line (format "#### %s" label))
            (push "" out)))
         ((and (not in-code) stack (string-match-p "^:::[ \t]*$" line))
          (let ((popped (pop stack)))
            (when (plist-get popped :quote)
              (push "" out))))
         (t
          (emit-line line)))))
    (mapconcat #'identity (nreverse out) "\n")))

(defun etaf-web--parse-embedded-markdown (markdown)
  "Parse MARKDOWN for embedded Docs/Discourse views using the `etaf' dialect."
  (etaf-doc-markdown-parse (etaf-web--normalize-embedded-containers markdown) 'etaf))

(cl-defun etaf-web--render-markdown-blocks
    (doc &key theme-mode dir open-link (line-grid t) (max-cols 80) show-title)
  "Render parsed `etaf-doc-markdown-parse' DOC into an embedded column View.
Unlike `etaf-md-view', carries zero `:width (vw 100)' assumption so it fits
cleanly inside split panes and cards with exact parent-column symmetry."
  (let* ((mode (or theme-mode 'auto))
         (pal (etaf-web--markdown-palette mode))
         (bg (unless (eq mode 'auto) (cdr (assq :bg pal))))
         (env (list :palette pal
                    :background bg
                    :width max-cols
                    :line-grid (and line-grid t)
                    :link-hover nil
                    :heading-underline nil
                    :open-link (or open-link #'ignore)
                    :render-media (lambda (kind node _e)
                                    (etaf-web--embedded-media-view
                                     kind node dir open-link max-cols))
                    :alert-labels '((note . "笔记") (tip . "提示")
                                    (important . "重要") (warning . "警告")
                                    (caution . "小心"))
                    :features (plist-get doc :features)))
         (meta (plist-get doc :meta))
         (meta-title (cdr (assoc "title" meta)))
         (blocks (plist-get doc :children))
         (footnotes (plist-get doc :footnotes))
         (first-is-h1 (and blocks
                           (eq (plist-get (car blocks) :type) 'heading)
                           (eql (plist-get (car blocks) :level) 1)))
         (accent-tok (cdr (assq :accent pal)))
         (border-line (list '(px 1) 'solid (cdr (assq :border pal))))
         (rendered-blocks
          (delq nil
                (mapcar
                 (lambda (blk)
                   (when-let* ((v (etaf-doc-markdown-view-block blk env)))
                     (let ((id (and (eq (plist-get blk :type) 'heading)
                                    (plist-get blk :id))))
                       (if (and (stringp id) (not (string-empty-p id)))
                           (etaf-node 'box
                                      (list :ref (intern (format "etaf-md-heading-%s" id))
                                            :width 'stretch)
                                      (list v))
                         v))))
                 blocks)))
         (footnote-views
          (when footnotes
            (append
             (list (etaf-node 'etaf-divider (list :orientation 'horizontal :label "脚注") nil))
             (etaf-doc-markdown-view-blocks footnotes env t)))))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 1) :color (cdr (assq :ink pal)))
     (append
      (when (and show-title meta-title (not (string-empty-p meta-title))
                 (not first-is-h1))
        (list (etaf-node 'box
                         (list :width 'stretch
                               :border-bottom border-line
                               :padding '((lh 0) (ch 0)))
                         (list (etaf-node 'text
                                          (list :font-weight 'bold :color accent-tok)
                                          (list meta-title))))))
      rendered-blocks
      footnote-views))))

(defun etaf-web--cell-metrics ()
  "Return `(CHAR-WIDTH . LINE-HEIGHT)' of the active ETAF canvas."
  (let ((m (ignore-errors (etaf-display-metrics))))
    (cons (max 1 (or (plist-get m :char-width) 8))
          (max 1 (or (plist-get m :line-height) 16)))))

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
                                    &optional _spin-idx mode-label)
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
       (cond
        ((and (stringp mode-label) (not (string-empty-p mode-label)))
         mode-label)
        (cached "缓存")
        (t ""))))))

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
         (progress (or (plist-get session :progress-display) 0.0))
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
         (page (etaf-value (plist-get session :page)))
         (mode-label (and (listp page) (plist-get page :mode-label)))
         (status-str (etaf-web--status-text
                      phase stage-label elapsed progress cached narrow
                      nil mode-label))
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
           :flex-shrink 0
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
      ;; Right: pure text status slot or specialized mode selector.
      (etaf-node
       'box (list :flex-shrink 0)
       (list
        (cond
         (editing
          (etaf-node 'text (list :color muted-tok)
                     (list (if narrow
                               "RET · ESC"
                             "RET 打开 · TAB 补全 · ESC 取消"))))
         ((and (eq phase 'ready)
               (not narrow)
               (stringp mode-label)
               (not (string-empty-p mode-label))
               (functionp (plist-get callbacks :set-mode)))
          (etaf-view
           (etaf-button
            :label (format "%s ▾" mode-label)
            :variant 'ghost
            :ref 'web-mode-button
            :color muted-tok
            :pointer 'hand
            :padding '((lh 0) (ch 0))
            :aria-label (format "渲染模式 %s" mode-label)
            :help-echo "切换渲染模式 (m)"
            :on-press (plist-get callbacks :set-mode))))
         (t
          (etaf-node 'text
                     (list :ref 'web-status :id "web-status"
                           :color status-color)
                     (list status-str))))))))))

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
The toolbar is a fixed sibling above it, so scrolling the page cannot move the
toolbar, and no scroll hook or per-frame repaint is involved."
  (etaf-node 'box
             (list :ref 'web-scroll :id "web-scroll"
                   :width 'stretch
                   :flex-grow 1
                   :flex-basis '(lh 0)
                   :min-height '(lh 0)
                   :overflow 'scroll
                   :role 'region
                   :tab-index 0
                   :aria-label "网页正文")
             (list (etaf-node 'column (list :width 'stretch :height 'auto)
                              (list child)))))

(defun etaf-web--render-page-content (session page md-session md-gen ctx)
  "Render active PAGE controller or fallback MD-SESSION under key MD-GEN."
  (cond
   ((and (listp page) (functionp (plist-get page :render)))
    (etaf-node 'box (list :key md-gen :width 'stretch)
               (list (funcall (plist-get page :render) ctx))))
   (md-session
    (etaf-node 'box (list :key md-gen :width 'stretch)
               (list (etaf-md-view md-session))))
   (t
    (etaf-web--loading-skeleton-view session (plist-get ctx :measure)))))

(defun etaf-web--body-view (session width height width-px char-width measure narrow theme-mode)
  "Render main content area for SESSION at current viewport metrics.
Delegates to the active Page Controller's `:render' function (or `etaf-md-view')
under a `:key' tied to `:md-gen'.  Page Controllers declaring `:own-scroll t'
receive the full fixed body viewport so multi-pane views can scroll each pane
independently and paint full-height dividers."
  (let* ((phase (etaf-value (plist-get session :phase)))
         (page (etaf-value (plist-get session :page)))
         (md-session (etaf-value (plist-get session :md-session)))
         (md-gen (etaf-value (plist-get session :md-gen)))
         (own-scroll (and (not (eq phase 'error))
                          (listp page)
                          (plist-get page :own-scroll)
                          (functionp (plist-get page :render))))
         (ctx (list :width width
                    :height height
                    :width-px width-px
                    :char-width char-width
                    :measure measure
                    :narrow narrow
                    :theme theme-mode
                    :session session)))
    (if own-scroll
        (etaf-node
         'flex
         (list :flex-direction 'column
               :width 'stretch
               :flex-grow 1
               :flex-basis '(lh 0)
               :min-height '(lh 0)
               :overflow 'hidden)
         (list
          (etaf-node 'flex
                     (list :key md-gen
                           :flex-direction 'column
                           :width 'stretch
                           :height 'stretch
                           :flex-grow 1
                           :flex-basis '(lh 0)
                           :min-height '(lh 0)
                           :overflow 'hidden)
                     (list (funcall (plist-get page :render) ctx)))))
      (etaf-web--body-viewport
       (pcase phase
         ('error
          (etaf-web--error-card-view session measure))
         ('loading
          (if (or page md-session)
              (etaf-web--render-page-content session page md-session md-gen ctx)
            (etaf-web--loading-skeleton-view session measure)))
         (_
          (etaf-web--render-page-content session page md-session md-gen ctx)))))))

(etaf-define-component etaf-web--browser-app (&key session keys)
  "Root Component of an `etaf-web' browser buffer."
  :bindings ((mode (plist-get session :theme-mode))
             (rev (plist-get session :theme-rev))
             (tokens (etaf-computed
                      (lambda ()
                        (when rev (etaf-value rev))
                        (etaf-web--theme-tokens (etaf-value mode)))
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
         (vh (max 8 (or (etaf-value (plist-get session :viewport-height)) 24)))
         (cw (max 1.0 (float (or (etaf-value (plist-get session :char-width))
                                 (car (etaf-web--cell-metrics))))))
         (vw-px (or (etaf-value (plist-get session :viewport-px))
                    (round (* vw cw))))
         (narrow (< vw etaf-web--narrow-breakpoint))
         (measure (min etaf-web--max-measure (max etaf-web--min-measure (- vw 4))))
         (editing (etaf-value (plist-get session :address-editing)))
         (callbacks (plist-get session :callbacks))
         (page (etaf-value (plist-get session :page)))
         (page-keys (and (listp page) (plist-get page :keys)))
         (all-keys (if page-keys (append page-keys keys) keys))
         (cur-mode (etaf-value mode))
         (bg-tok (unless (eq cur-mode 'auto)
                   (etaf-theme-token :ui-bg "#191a1c")))
         (fg-tok (etaf-theme-token :ui-fg "#dcdfe4")))
    (etaf-node
     'flex
     (append (list :flex-direction 'column
                   :width '(vw 100)
                   :height (list 'lh vh)
                   :min-height '(lh 0)
                   :overflow 'hidden
                   :keys all-keys
                   :on-direction (plist-get callbacks :direction)
                   :color fg-tok
                   :aria-label "ETAF Web 浏览器")
             (when bg-tok
               (list :background-color bg-tok))
             (when editing
               (list :on-dismiss (plist-get callbacks :address-dismiss))))
     (list
      (etaf-web--header-view session vw narrow)
      (etaf-web--body-view session vw (max 4 (1- vh)) vw-px cw measure narrow cur-mode)))))

(provide 'etaf-web-views)
;;; etaf-web-views.el ends here
