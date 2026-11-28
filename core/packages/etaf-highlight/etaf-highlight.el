;;; etaf-highlight.el --- Universal highlighter & notes extension for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.2
;; Package-Requires: ((emacs "29.1") (etaf "0.3.10") (etaf-ui "0.3.6") (etaf-ext "0.1.0"))
;; Keywords: convenience, extensions, ui
;; URL: https://github.com/emacs-taf/etaf

;;; Commentary:

;; Standalone universal highlighter and persistent companion notes extension
;; built strictly on `etaf-ext''s public API.  Paints non-destructive character
;; span highlights via `etaf-ext-decorate', renders optional `etaf-ext-companion'
;; note cards below highlighted paragraphs, persists entries by page URI inside
;; isolated SQLite storage, auto-restores highlights on remount or navigation,
;; and coexists seamlessly with `etaf-translate', `etaf-hints' and `etaf-devtools'.
;;
;; Public API
;;
;; Load this package with (require 'etaf-highlight) after adding this repository,
;; ETAF, ETAF UI, ETAF Ext, Ebox and ECSS roots to `load-path'.  Only the
;; interfaces listed below are supported for use by other packages; unlisted
;; symbols are internal even without a double hyphen.  docs/manual.md contains
;; workflows.
;;
;; Function: etaf-highlight-register ()
;;;###autoload (autoload 'etaf-highlight-register "etaf-highlight" nil nil)
;; Register or re-register the `etaf-highlight' extension inside `etaf-ext'.
;;
;; Function: etaf-highlight-add (&optional color note runtime)
;;;###autoload (autoload 'etaf-highlight-add "etaf-highlight" nil t)
;; Interactive command highlighting the active region or text paragraph at point
;; on RUNTIME with optional COLOR (`yellow', `green', `blue', `pink') and NOTE.
;;
;; Function: etaf-highlight-apply (runtime host-id beg end &key (color 'yellow) note)
;;;###autoload (autoload 'etaf-highlight-apply "etaf-highlight" nil nil)
;; Programmatically persist and render a highlight on HOST-ID [BEG, END) of
;; mounted RUNTIME, returning the saved highlight record plist.
;;
;; Function: etaf-highlight-remove (&optional highlight-id runtime)
;;;###autoload (autoload 'etaf-highlight-remove "etaf-highlight" nil t)
;; Interactive command removing HIGHLIGHT-ID (or highlights on the paragraph at
;; point) from RUNTIME.
;;
;; Function: etaf-highlight-list (&optional runtime)
;;;###autoload (autoload 'etaf-highlight-list "etaf-highlight" nil t)
;; Interactive command opening the floating highlights list popup for RUNTIME.
;;
;; Function: etaf-highlight-entries (&optional runtime)
;;;###autoload (autoload 'etaf-highlight-entries "etaf-highlight" nil nil)
;; Return list of persisted highlight record plists for RUNTIME's current page.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)

(defconst etaf-highlight--colors '(yellow green blue pink)
  "Supported semantic highlight marker colors.")

(defconst etaf-highlight--color-labels
  '((yellow . "暖黄")
    (green  . "翠绿")
    (blue   . "晴蓝")
    (pink   . "浅绯"))
  "Human-readable Chinese labels for highlight colors.")

(defun etaf-highlight--page-key (ctx)
  "Return stable persistence key for CTX's current Runtime page."
  (let* ((meta (etaf-ext-ctx-meta ctx))
         (uri (plist-get meta :uri))
         (buf (etaf-runtime-buffer (etaf-ext-ctx-runtime ctx))))
    (cond
     ((and (stringp uri) (not (string-empty-p uri))) (concat "page:" uri))
     ((buffer-live-p buf) (concat "buf:" (buffer-name buf)))
     (t "page:default"))))

(defun etaf-highlight--face (color &optional theme)
  "Return a theme-adapted face plist for highlight COLOR."
  (let* ((th (or theme (etaf-ext-theme)))
         (dark (eq (plist-get th :ext-mode) 'dark))
         (bg-base (plist-get th :ext-bg))
         (fg-base (plist-get th :ext-fg))
         (tint-hex
          (pcase color
            ('green (if dark "#22C55E" "#86EFAC"))
            ('blue  (if dark "#3B82F6" "#93C5FD"))
            ('pink  (if dark "#EC4899" "#F9A8D4"))
            (_      (if dark "#EAB308" "#FDE047"))))
         (hl-bg (etaf-ui-color-mix bg-base tint-hex (if dark 0.30 0.45)))
         (hl-fg (etaf-ui-color-legible fg-base hl-bg 5.0))
         (ul-color (etaf-ui-color-legible tint-hex hl-bg 3.2)))
    (list :background hl-bg
          :foreground hl-fg
          :underline (list :color ul-color :style 'line))))

(defun etaf-highlight--accent-hex (color &optional theme)
  "Return legible border/accent hex color for highlight COLOR."
  (let* ((th (or theme (etaf-ext-theme)))
         (dark (eq (plist-get th :ext-mode) 'dark))
         (panel (plist-get th :ext-panel))
         (raw (pcase color
                ('green (if dark "#4ADE80" "#15803D"))
                ('blue  (if dark "#60A5FA" "#1D4ED8"))
                ('pink  (if dark "#F472B6" "#BE185D"))
                (_      (if dark "#FACC15" "#B45309")))))
    (etaf-ui-color-legible raw panel 4.5)))

(defun etaf-highlight--collect-texts (tree)
  "Collect `(HOST-ID . TEXT)' alist for all text Hosts in TREE."
  (let ((acc nil))
    (cl-labels ((walk (node)
                  (when (listp node)
                    (when (and (eq (plist-get node :tag) 'text)
                               (stringp (plist-get node :text)))
                      (push (cons (plist-get node :id) (plist-get node :text)) acc))
                    (dolist (child (plist-get node :children))
                      (walk child)))))
      (dolist (root tree) (walk root)))
    (nreverse acc)))

(defun etaf-highlight--resolve-entry (entry texts)
  "Resolve persisted highlight ENTRY against TEXTS alist.
Return `(HOST-ID BEG END)' or nil when no matching text Host exists."
  (let* ((saved-hid (plist-get entry :host-id))
         (anchor (plist-get entry :anchor))
         (beg (or (plist-get entry :beg) 0))
         (end (or (plist-get entry :end) 0))
         (direct (and (integerp saved-hid) (assq saved-hid texts))))
    (cond
     ((and direct
           (stringp (cdr direct))
           (<= 0 beg) (<= beg end) (<= end (length (cdr direct)))
           (or (null anchor)
               (string= (substring (cdr direct) beg end) anchor)))
      (list saved-hid beg end))
     ((and (stringp anchor) (not (string-empty-p anchor)))
      (cl-loop for (hid . txt) in texts
               for pos = (string-search anchor txt)
               when pos
               return (list hid pos (+ pos (length anchor)))))
     (t nil))))

(defun etaf-highlight--load-entries (ctx)
  "Read persisted highlight list for CTX's current page."
  (let ((raw (etaf-ext-storage-get ctx (etaf-highlight--page-key ctx) nil)))
    (if (proper-list-p raw) raw nil)))

(defun etaf-highlight--save-entries (ctx entries)
  "Persist ENTRIES list for CTX's current page."
  (let ((key (etaf-highlight--page-key ctx)))
    (if entries
        (etaf-ext-storage-set ctx key entries)
      (etaf-ext-storage-delete ctx key))
    (etaf-ext-ctx-set-state ctx entries)
    entries))

(defun etaf-highlight--delete-by-id (ctx hl-id)
  "Remove highlight HL-ID from CTX's current page and re-apply."
  (let* ((entries (etaf-highlight--load-entries ctx))
         (next (cl-remove-if (lambda (e) (equal (plist-get e :id) hl-id)) entries)))
    (etaf-highlight--save-entries ctx next)
    (etaf-highlight--apply-all ctx next)
    (length next)))

(defun etaf-highlight--note-card (ctx note-entries theme)
  "Build compact companion note card View for NOTE-ENTRIES on CTX."
  (let* ((panel (plist-get theme :ext-panel))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (first-color (plist-get (car note-entries) :color))
         (accent (etaf-highlight--accent-hex first-color theme))
         (card-bg (etaf-ui-color-mix panel accent 0.08)))
    (etaf-node
     'column
     (list :width 'stretch
           :background-color card-bg
           :border-left (list '(px 2) 'solid accent)
           :padding '((lh 0) (ch 1))
           :item-gap '(lh 0))
     (mapcar
      (lambda (entry)
        (let ((hl-id (plist-get entry :id))
              (note (plist-get entry :note))
              (col-lbl (or (cdr (assq (plist-get entry :color)
                                      etaf-highlight--color-labels))
                           "批注")))
          (etaf-node
           'flex (list :width 'stretch :justify-content 'space-between
                       :align-items 'center :gap '((lh 0) (ch 1)))
           (list
            (etaf-node
             'flex (list :flex-grow 1 :align-items 'center :gap '((lh 0) (ch 1)))
             (list
              (etaf-node 'box '(:flex-shrink 0)
                         (list (etaf-node 'text (list :color accent :font-weight 'bold)
                                          (list (format "✎ %s" col-lbl)))))
              (etaf-node 'text (list :color fg) (list note))))
            (etaf-view
             (etaf-button
              :label "[删除]" :variant 'ghost :pointer 'hand
              :color muted :padding '((lh 0) (ch 0))
              :on-press (lambda ()
                          (etaf-highlight--delete-by-id ctx hl-id))))))))
      note-entries))))

(defun etaf-highlight--apply-all (ctx &optional entries)
  "Reconcile all persisted highlights for CTX onto the live ETAF page."
  (let* ((list-entries (or entries (etaf-highlight--load-entries ctx)))
         (theme (etaf-ext-theme))
         (tree (etaf-ext-tree ctx))
         (texts (etaf-highlight--collect-texts tree))
         (span-map (make-hash-table :test #'eql))
         (note-map (make-hash-table :test #'eql)))
    (etaf-ext-ctx-set-state ctx list-entries)
    (etaf-ext-clear-presentations ctx)
    (dolist (entry list-entries)
      (when-let* ((resolved (etaf-highlight--resolve-entry entry texts)))
        (let* ((hid (nth 0 resolved))
               (beg (nth 1 resolved))
               (end (nth 2 resolved))
               (col (or (plist-get entry :color) 'yellow))
               (note (plist-get entry :note))
               (face (etaf-highlight--face col theme)))
          (push (cons (cons beg end) face) (gethash hid span-map))
          (when (and (stringp note) (not (string-empty-p note)))
            (push entry (gethash hid note-map))))))
    (let (dec-updates comp-updates)
      (maphash (lambda (hid spans)
                 (push (cons hid (list :spans (nreverse spans))) dec-updates))
               span-map)
      (maphash (lambda (hid notes)
                 (push (cons hid
                             (list :mode 'companion-after
                                   :view (etaf-highlight--note-card
                                          ctx (nreverse notes) theme)))
                       comp-updates))
               note-map)
      (when dec-updates
        (etaf-ext-decorate ctx (nreverse dec-updates)))
      (when comp-updates
        (etaf-ext-companion ctx (nreverse comp-updates)))
      (length list-entries))))

(defun etaf-highlight--add-record (ctx host-id beg end color note)
  "Insert and persist a highlight record on CTX, returning the created plist."
  (let* ((texts (etaf-highlight--collect-texts (etaf-ext-tree ctx)))
         (txt (cdr (assq host-id texts))))
    (unless (stringp txt)
      (signal 'etaf-ext-error (list "Text Host not found for highlight" host-id)))
    (let* ((len (length txt))
           (s (max 0 (min beg len)))
           (e (max s (min end len)))
           (e (if (= s e) len e))
           (anchor (substring-no-properties txt s e))
           (col (if (memq color etaf-highlight--colors) color 'yellow))
           (id (format "hl-%d-%d" (truncate (* 1000 (float-time))) (random 10000)))
           (record (list :id id
                         :host-id host-id
                         :anchor anchor
                         :beg s
                         :end e
                         :color col
                         :note (and (stringp note) (not (string-empty-p note))
                                    (substring-no-properties note))
                         :created (format-time-string "%Y-%m-%d %H:%M")))
           (entries (append (etaf-highlight--load-entries ctx) (list record))))
      (etaf-highlight--save-entries ctx entries)
      (etaf-highlight--apply-all ctx entries)
      record)))

(defun etaf-highlight--cmd-add (ctx &optional color note)
  "Highlight active region or text Host at point on CTX."
  (let* ((info (etaf-ext-host-text-at-point ctx))
         (hid (plist-get info :host-id))
         (txt (plist-get info :text))
         (rbeg (plist-get info :region-start))
         (rend (plist-get info :region-end)))
    (unless (and hid (stringp txt) (> (length txt) 0))
      (let ((first-txt (car (etaf-highlight--collect-texts (etaf-ext-tree ctx)))))
        (when first-txt
          (setq hid (car first-txt)
                txt (cdr first-txt)))))
    (if (not (and hid (stringp txt)))
        (progn
          (etaf-ext-notify ctx "划词高亮" :detail "当前光标位置未找到可高亮的文本段落")
          nil)
      (let ((beg (or rbeg 0))
            (end (or rend (length txt))))
        (prog1 (etaf-highlight--add-record ctx hid beg end (or color 'yellow) note)
          (etaf-ext-notify ctx "已添加高亮"
                           :detail (truncate-string-to-width
                                    (substring txt beg end) 32 nil nil "…")))))))

(defun etaf-highlight--cmd-note (ctx)
  "Prompt for a note and highlight the current selection or paragraph on CTX."
  (let ((note (if noninteractive
                  "快速批注"
                (read-string "批注内容: "))))
    (etaf-highlight--cmd-add ctx 'yellow note)))

(defun etaf-highlight--cmd-remove (ctx)
  "Remove highlights attached to the text Host at point on CTX."
  (let* ((info (etaf-ext-host-text-at-point ctx))
         (hid (plist-get info :host-id))
         (entries (etaf-highlight--load-entries ctx))
         (next (if hid
                   (cl-remove-if (lambda (e) (eql (plist-get e :host-id) hid)) entries)
                 (butlast entries))))
    (etaf-highlight--save-entries ctx next)
    (etaf-highlight--apply-all ctx next)
    (etaf-ext-notify ctx "划词高亮"
                     :detail (format "剩余 %d 条高亮" (length next)))
    next))

(defun etaf-highlight--popup-view (ctx)
  "Build floating highlights list View for CTX."
  (let* ((entries (etaf-highlight--load-entries ctx))
         (theme (etaf-ext-theme))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (panel (plist-get theme :ext-panel))
         (border (plist-get theme :ext-border)))
    (etaf-node
     'column
     (list :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 1))
     (list
      (etaf-node
       'flex (list :width 'stretch :justify-content 'space-between
                   :align-items 'center)
       (list
        (etaf-node 'text (list :font-weight 'bold :color fg)
                   (list (format "本页高亮与批注 (%d)" (length entries))))
        (etaf-view
         (etaf-button :label "[×]" :variant 'ghost :pointer 'hand
                      :padding '((lh 0) (ch 0)) :color muted
                      :on-press (lambda () (etaf-ext-hide-popup ctx))))))
      (etaf-view (etaf-divider :orientation 'horizontal))
      (if (null entries)
          (etaf-view (etaf-empty :title "暂无高亮"
                                 :description "运行 M-x etaf-highlight-add，或通过扩展分发器 / 命令面板高亮当前选区或段落。"))
        (etaf-node
         'column (list :width 'stretch :item-gap '(lh 1))
         (mapcar
          (lambda (e)
            (let* ((hl-id (plist-get e :id))
                   (hid (plist-get e :host-id))
                   (col (or (plist-get e :color) 'yellow))
                   (accent (etaf-highlight--accent-hex col theme))
                   (anchor (truncate-string-to-width (or (plist-get e :anchor) "") 44 nil nil "…"))
                   (note (plist-get e :note)))
              (etaf-node
               'column
               (list :key hl-id :width 'stretch :background-color panel
                     :border-left (list '(px 2) 'solid accent)
                     :border-bottom (list '(px 1) 'solid border)
                     :padding '((lh 0) (ch 1)) :item-gap '(lh 0))
               (delq
                nil
                (list
                 (etaf-node
                  'flex (list :width 'stretch :justify-content 'space-between
                              :align-items 'center :gap '((lh 0) (ch 1)))
                  (list
                   (etaf-node 'text (list :color fg) (list anchor))
                   (etaf-node
                    'flex (list :flex-shrink 0 :gap '((lh 0) (ch 1)))
                    (list
                     (etaf-view
                      (etaf-button
                       :label "定位" :variant 'ghost :pointer 'hand
                       :padding '((lh 0) (ch 0))
                       :on-press (lambda ()
                                   (ignore-errors (etaf-ext-scroll-to ctx hid 'center)))))
                     (etaf-view
                      (etaf-button
                       :label "删除" :variant 'ghost :pointer 'hand
                       :padding '((lh 0) (ch 0)) :color muted
                       :on-press (lambda ()
                                   (etaf-highlight--delete-by-id ctx hl-id)
                                   (etaf-ext-show-popup
                                    ctx (etaf-highlight--popup-view ctx)
                                    :title "本页高亮与批注" :width 56 :height 18))))))))
                 (when (and (stringp note) (not (string-empty-p note)))
                   (etaf-node 'text (list :color muted)
                              (list (format "批注: %s" note)))))))))
          entries)))))))

(defun etaf-highlight--cmd-list (ctx)
  "Open the highlights list floating popup on CTX."
  (etaf-ext-show-popup ctx (etaf-highlight--popup-view ctx)
                       :title "本页高亮与批注" :width 56 :height 18))

(defun etaf-highlight--badge (ctx)
  "Return compact mode-line badge when CTX's page has saved highlights."
  (let ((n (length (etaf-ext-ctx-state ctx))))
    (when (> n 0)
      (list :text (format "标%d" n) :variant 'info))))

;;;; Public API

;;;###autoload
(defun etaf-highlight-add (&optional color note runtime)
  "Highlight active region or text paragraph at point on RUNTIME."
  (interactive)
  (let* ((rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer))))
         (ctx (etaf-ext-attach 'etaf-highlight rt)))
    (when ctx
      (etaf-highlight--cmd-add ctx color note))))

(cl-defun etaf-highlight-apply (runtime host-id beg end &key (color 'yellow) note)
  "Programmatically apply a persisted highlight to HOST-ID [BEG, END) on RUNTIME."
  (let ((ctx (etaf-ext-attach 'etaf-highlight runtime)))
    (when ctx
      (etaf-highlight--add-record ctx host-id beg end color note))))

;;;###autoload
(defun etaf-highlight-remove (&optional highlight-id runtime)
  "Remove HIGHLIGHT-ID (or highlights at point) on RUNTIME."
  (interactive)
  (let* ((rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer))))
         (ctx (etaf-ext-attach 'etaf-highlight rt)))
    (when ctx
      (if highlight-id
          (etaf-highlight--delete-by-id ctx highlight-id)
        (etaf-highlight--cmd-remove ctx)))))

;;;###autoload
(defun etaf-highlight-list (&optional runtime)
  "Open the highlights list popup for RUNTIME."
  (interactive)
  (etaf-ext-run-command 'etaf-highlight 'list runtime))

(defun etaf-highlight-entries (&optional runtime)
  "Return persisted highlight entry plists for RUNTIME."
  (let* ((rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer))))
         (ctx (and rt (etaf-ext-attach 'etaf-highlight rt))))
    (when ctx
      (etaf-highlight--load-entries ctx))))

(defun etaf-highlight-register ()
  "Register the standalone `etaf-highlight' extension inside `etaf-ext'."
  (etaf-ext-define etaf-highlight
    :name "划词高亮与批注"
    :version "0.1.1"
    :icon "标"
    :tone 'success
    :prefix-hint "h"
    :description "对任意 ETAF 页面的文本片段着色高亮并附加批注卡片，独立持久化并自动还原，与沉浸式翻译无缝共存。"
    :activation 'on-match
    :matches (list :apps t
                   :predicate (lambda (_rt meta _buf)
                                (not (eq (plist-get meta :app) 'etaf-ext-manager))))
    :priority 60
    :debounce 0.1
    :permissions '(read-tree decorate companion interact storage keys popup notify)
    :commands '((highlight :subkey "h" :label "高亮当前选区或段落" :fn etaf-highlight--cmd-add)
                (note      :subkey "n" :label "添加带批注高亮" :fn etaf-highlight--cmd-note)
                (remove    :subkey "d" :label "清除当前段落高亮" :fn etaf-highlight--cmd-remove)
                (list      :subkey "l" :label "查看本页高亮列表" :fn etaf-highlight--cmd-list))
    :popup #'etaf-highlight--popup-view
    :badge #'etaf-highlight--badge
    :on-attach #'etaf-highlight--apply-all
    :on-commit #'etaf-highlight--apply-all
    :on-meta (lambda (ctx _meta) (etaf-highlight--apply-all ctx))
    :on-theme #'etaf-highlight--apply-all))

(etaf-highlight-register)

(provide 'etaf-highlight)
;;; etaf-highlight.el ends here
