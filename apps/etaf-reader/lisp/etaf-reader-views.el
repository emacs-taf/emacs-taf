;;; etaf-reader-views.el --- ETAF Views of etaf-reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Pure renderers: every function takes plain data read from the session's
;; refs and returns a View tree, so a ref write repaints the mounted reader.
;; Reading lines are laid out by the model; this layer splits a line into
;; styled segments (annotation fill, underline, wavy, selection, caret) and
;; paints them with the session's palette.
;;
;; The selection toolbar is an `etaf-popover' anchored cleanly below the last
;; selected line (or above the first line near the bottom of a column).  On a
;; new selection, choosing a color or style applies the annotation immediately
;; and keeps the toolbar open in edit mode (Scheme A) so the user can adjust
;; color, style, or attach a thought without re-selecting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-reader-theme)
(require 'etaf-reader-model)
(require 'etaf-reader-navigation)

(declare-function etaf-reader-search-command "etaf-reader-app")
(declare-function etaf-reader--direction "etaf-reader-app" (direction))
(declare-function etaf-reader-export-command "etaf-reader-app" ())
(declare-function etaf-reader--export-book-interactive "etaf-reader-app" (session book))
(declare-function etaf-reader-wheel-down-command "etaf-reader-app" ())
(declare-function etaf-reader-wheel-up-command "etaf-reader-app" ())
(declare-function etaf-reader-refresh-library "etaf-reader-model" (session))
(declare-function etaf-reader-open-book "etaf-reader-model" (session book &optional parser))

(defconst etaf-reader--wheel-keys
  '(("<wheel-down>" etaf-reader-wheel-down-command "向下阅读")
    ("<wheel-up>" etaf-reader-wheel-up-command "向上阅读")
    ("<mouse-5>" etaf-reader-wheel-down-command "向下阅读")
    ("<mouse-4>" etaf-reader-wheel-up-command "向上阅读"))
  "Wheel bindings attached to the main reading and shelf columns.
Keeping wheel keys off the root lets scrollable sidebars and the detail
panel retain Ebox's native smooth scrolling.")

(defconst etaf-reader--valid-color-keys
  '(:red :orange :yellow :green :blue :purple)
  "Valid palette keywords for annotation colors.")

(defun etaf-reader--color-key (color)
  "Return COLOR (a string like \"red\") as a valid palette keyword."
  (let ((key (and (stringp color) (not (string-empty-p color))
                  (intern (format ":%s" color)))))
    (if (memq key etaf-reader--valid-color-keys) key :yellow)))

(defun etaf-reader--fill-key (color)
  "Return the soft fill keyword of annotation COLOR."
  (let ((key (etaf-reader--color-key color)))
    (intern (format "%s-soft" (symbol-name key)))))

(defun etaf-reader--clip (string cells)
  "Return STRING clipped to CELLS character cells, ending in an ellipsis."
  (truncate-string-to-width (or string "") (max 1 cells) nil nil "…"))

;;; ---------------------------------------------------------------------------
;;; Line segments
;;; ---------------------------------------------------------------------------

(defun etaf-reader--segment-style (styles from to)
  "Return the run styles covering STYLES interval FROM..TO."
  (let ((result ""))
    (dolist (style styles)
      (when (and (< (or (nth 0 style) 0) to) (> (or (nth 1 style) 0) from))
        (setq result (concat result " " (or (nth 2 style) "")))))
    (string-trim result)))

(defun etaf-reader--line-segments (session line _theme)
  "Return the render segments of LINE in SESSION."
  (let* ((text (or (plist-get line :text) ""))
         (length (length text))
         (start (or (plist-get line :start) 0))
         (end (or (plist-get line :end) 0))
         (shift (- length (max 0 (- end start))))
         (selection (etaf-reader-selection session))
         (cursor (etaf-reader--read session :cursor))
         (annotations (etaf-reader--read session :annotations))
         (styles (plist-get line :styles))
         (boundaries (list 0 length))
         (spans nil))
    (cl-labels ((add (from to &rest props)
                  (when (< from to)
                    (push from boundaries)
                    (push to boundaries)
                    (push (append (list :from from :to to) props) spans))))
      (dolist (style styles)
        (push (max 0 (min length (nth 0 style))) boundaries)
        (push (max 0 (min length (nth 1 style))) boundaries))
      (dolist (annotation annotations)
        (let* ((a-start (max start (or (plist-get annotation :start) 0)))
               (a-end (min end (or (plist-get annotation :end) 0))))
          (when (< a-start a-end)
            (add (+ shift (- a-start start)) (+ shift (- a-end start))
                 :annotation annotation))))
      (when selection
        (let* ((s-start (max start (car selection)))
               (s-end (min end (cdr selection))))
          (when (< s-start s-end)
            (add (+ shift (- s-start start)) (+ shift (- s-end start))
                 :selection t))))
      (when (and cursor (equal (plist-get cursor :line) (plist-get line :key)))
        (let* ((caret-pos (+ shift (or (plist-get cursor :char) 0)))
               (position (max 0 (min (1- (max 1 length)) caret-pos))))
          (add position (min length (1+ position)) :caret t)))
      (let* ((sorted (sort (delete-dups (copy-sequence boundaries)) #'<))
             (segments nil)
             (items sorted))
        (while (cdr items)
          (let* ((from (car items))
                 (to (cadr items))
                 (middle (/ (+ from to) 2.0))
                 (covering (cl-remove-if-not
                            (lambda (span)
                              (and (<= (plist-get span :from) middle)
                                   (< middle (plist-get span :to)))) spans))
                 (annotation (seq-some (lambda (span) (plist-get span :annotation))
                                       covering))
                 (kind (and annotation (or (plist-get annotation :kind) "highlight")))
                 (color (and annotation (or (plist-get annotation :color) "yellow")))
                 (has-note (and annotation
                                (not (string-empty-p
                                      (string-trim (or (plist-get annotation :note) ""))))))
                 (style (etaf-reader--segment-style styles from to))
                 (caret (seq-some (lambda (span) (plist-get span :caret)) covering))
                 (selection-p (seq-some (lambda (span) (plist-get span :selection))
                                        covering))
                 (fill (cond (caret :accent)
                             (selection-p :sel)
                             ((equal kind "highlight")
                              (etaf-reader--fill-key color))))
                 (decoration (cond ((equal kind "underline") (etaf-reader--color-key color))
                                   ((equal kind "wavy") (etaf-reader--color-key color))
                                   ((equal kind "note") (etaf-reader--color-key color))
                                   ((and has-note (equal kind "highlight"))
                                    (etaf-reader--color-key color))))
                 (decoration-style (cond ((equal kind "wavy") 'wavy)
                                         ((or (equal kind "note")
                                              (and has-note (equal kind "highlight")))
                                          'dotted)))
                 (segment (list :text (substring text from to)
                                :bold (string-match-p "bold" style)
                                :italic (string-match-p "italic" style)
                                :caret caret
                                :fill fill
                                :decoration decoration
                                :decoration-style decoration-style
                                :color (when (eq (plist-get line :kind) 'quote)
                                         :quote)
                                :annotation annotation)))
            (push segment segments)
            (setq items (cdr items))))
        (etaf-reader--merge-segments (nreverse segments))))))

(defun etaf-reader--merge-segments (segments)
  "Merge adjacent SEGMENTS with identical rendering."
  (let ((result nil))
    (dolist (segment segments)
      (let ((previous (car result)))
        (if (and previous
                 (equal (plist-get previous :fill) (plist-get segment :fill))
                 (equal (plist-get previous :caret) (plist-get segment :caret))
                 (equal (plist-get previous :decoration) (plist-get segment :decoration))
                 (equal (plist-get previous :decoration-style)
                        (plist-get segment :decoration-style))
                 (equal (plist-get previous :bold) (plist-get segment :bold))
                 (equal (plist-get previous :italic) (plist-get segment :italic))
                 (equal (plist-get previous :color) (plist-get segment :color))
                 (equal (plist-get previous :annotation) (plist-get segment :annotation)))
            (plist-put previous :text
                       (concat (plist-get previous :text) (plist-get segment :text)))
          (push segment result))))
    (nreverse result)))

(defun etaf-reader--line-content (session line theme)
  "Return LINE's styled text and source coordinates for SESSION.
Caller-owned string properties travel through ETAF's public text boundary;
no buffer writes or separate paint layer are involved.  One nonempty Text
Host per slot also keeps blank and final-page slots addressable."
  (let ((kind (plist-get line :kind)) pieces)
    (dolist (segment (etaf-reader--line-segments session line theme))
      ;; Replace U+3000 ideographic spaces with regular spaces at display time:
      ;; preserves 1:1 character length/offsets while avoiding missing-glyph
      ;; cyan underlines on fonts that omit U+3000.
      (let ((text (subst-char-in-string ?\u3000 ?\s
                                        (copy-sequence (plist-get segment :text))))
            face)
        (when (or (eq kind 'heading) (plist-get segment :bold))
          (setq face (plist-put face :weight 'bold)))
        (when (plist-get segment :italic)
          (setq face (plist-put face :slant 'italic)))
        (when-let* ((fill (plist-get segment :fill)))
          (setq face (plist-put face :background (etaf-reader-color fill theme))))
        (cond
         ((plist-get segment :caret)
          (setq face (plist-put face :foreground "#FFFFFF")))
         ((or (plist-get segment :color) (eq kind 'hr))
          (setq face (plist-put face :foreground
                                (etaf-reader-color (or (plist-get segment :color) :dim)
                                                   theme)))))
        (when-let* ((decoration (plist-get segment :decoration)))
          (setq face
                (plist-put face :underline
                           (list :color (etaf-reader-color decoration theme)
                                 :style (pcase (plist-get segment :decoration-style)
                                          ('wavy 'wave) ('dotted 'dots) (_ 'line))))))
        (when face (put-text-property 0 (length text) 'face face text))
        (when-let* ((annotation (plist-get segment :annotation)))
          (let* ((note (string-trim (or (plist-get annotation :note) "")))
                 (tip (if (string-empty-p note)
                          "点击查看或编辑标注"
                        (format "想法：%s（点击编辑）"
                                (etaf-reader--clip (etaf-reader--single-line note) 48)))))
            (add-text-properties 0 (length text)
                                 (list 'reader-annotation (plist-get annotation :id)
                                       'help-echo tip)
                                 text)))
        (push text pieces)))
    (let ((text (apply #'concat (nreverse pieces))))
      (when (string-empty-p text) (setq text " "))
      (when (plist-get line :key)
        (put-text-property 0 (length text) 'reader-line (plist-get line :key) text))
      text)))

(defun etaf-reader--line-image (session line)
  "Return LINE's picture as (:src :columns :rows), or nil when unavailable.
Import extracts each chapter's images beside its chapters, so a block's :src
is a path inside the book's cache directory."
  (let* ((src (plist-get line :src))
         (book (etaf-reader--read session :book))
         (id (plist-get book :id))
         (path (and src id
                    (expand-file-name src (etaf-reader--cache-book-directory id)))))
    (when (and path (file-readable-p path))
      (let* ((metrics (etaf-reader--read session :metrics))
             (columns (min 40 (max 16 (or (plist-get metrics :columns) 40))))
             (max-rows (max 4 (min 24 (- (or (plist-get metrics :rows) 20) 2))))
             (pixels (ignore-errors (image-size (create-image path) t)))
             ;; The cover's cell is the canvas's: the `ch' and `lh' sizes
             ;; below resolve against it, so the art keeps its aspect there.
             (char-width (max 1 (or (plist-get (ignore-errors (etaf-display-metrics))
                                               :char-width)
                                    (frame-char-width))))
             (char-height (max 1 (or (plist-get (ignore-errors (etaf-display-metrics))
                                                :line-height)
                                     (frame-char-height))))
             (rows (if pixels
                       (max 1 (min max-rows (round (/ (* columns char-width (cdr pixels))
                                                      (* (car pixels) char-height)))))
                     (min max-rows 8))))
        (list :src path :columns columns :rows rows)))))

(defun etaf-reader--view-line (session line theme)
  "Return one fixed, retained line slot for LINE.
An image line paints the extracted picture instead of its placeholder text;
every other line keeps the retained Text Host so page turns patch instead of
rebuilding."
  (let* ((slot (or (plist-get line :slot) 0))
         (id (format "reader-text-%d" slot))
         (image (and (eq (plist-get line :kind) 'img)
                     (etaf-reader--line-image session line))))
    (if image
        (etaf-node
         'box
         (list :key slot :id (format "reader-line-%d" slot)
               :width 'stretch :height (list 'lh (plist-get image :rows))
               :overflow 'hidden :wrap-mode 'none)
         (list (etaf-node 'image (list :src (plist-get image :src)
                                       :columns (plist-get image :columns)
                                       :rows (plist-get image :rows))
                          nil)))
      (etaf-node
       'box
       (list :key slot :id (format "reader-line-%d" slot)
             :width 'stretch :height '(lh 1) :overflow 'hidden :wrap-mode 'none)
       (list (etaf-node 'text (list :ref (intern id) :id id)
                        (list (etaf-reader--line-content session line theme))))))))

(defun etaf-reader--sidebar-bar-text (theme percent &optional columns)
  "Return a single-line propertized progress bar for THEME at PERCENT.
COLUMNS defaults to 22 cells.  Used by both the initial sidebar view and
the retained fast-path page-turn updater."
  (let* ((width (max 4 (or columns 22)))
         (clamped (max 0.0 (min 100.0 (float (or percent 0)))))
         (filled (round (* clamped width 0.01)))
         (rest (- width filled))
         (left (make-string filled ?━))
         (right (make-string rest ?─)))
    (when (> filled 0)
      (put-text-property 0 filled 'face
                         (list :foreground (etaf-reader-color :accent theme))
                         left))
    (when (> rest 0)
      (put-text-property 0 rest 'face
                         (list :foreground (etaf-reader-color :line theme))
                         right))
    (concat left right)))

;;; ---------------------------------------------------------------------------
;;; Selection toolbar (Scheme A: immediate apply + stay in edit mode)
;;; ---------------------------------------------------------------------------

(defun etaf-reader--toolbar-line (session)
  "Return the toolbar's start line index, or nil."
  (let ((toolbar (etaf-reader--read session :toolbar)))
    (and toolbar (plist-get toolbar :line))))

(defun etaf-reader--toolbar-button (label color help on-press
                                          &optional selected aria-label)
  "Return one compact button of the annotation toolbar."
  (etaf-view
   (etaf-button :label label :variant 'ghost :pointer 'hand
                :padding '((lh 0) (ch 0))
                :color color :aria-label (or aria-label label)
                :aria-selected (and selected t)
                :help-echo help :on-press on-press)))

(defun etaf-reader--view-toolbar (session)
  "Return the compact floating selection/annotation toolbar popover, or nil."
  (let* ((toolbar (etaf-reader--read session :toolbar))
         (theme (etaf-reader--read session :theme)))
    (when toolbar
      (let* ((start-line (plist-get toolbar :line))
             (end-line (max start-line (or (plist-get toolbar :end-line) start-line)))
             (top (etaf-reader--read session :line))
             (metrics (etaf-reader--read session :metrics))
             (rows (max 1 (or (plist-get metrics :rows) 20)))
             (visible-count (max 1 (etaf-reader--visible-line-count session top)))
             (annotation (plist-get toolbar :annotation))
             (active-color (or (and annotation (plist-get annotation :color))
                               (etaf-reader--read session :last-color)
                               "yellow"))
             (active-kind (or (and annotation (plist-get annotation :kind))
                              (etaf-reader--read session :last-kind)
                              "highlight"))
             (closing (lambda () (etaf-reader-clear-selection session)))
             ;; Scheme A: applying a color or style on a new selection creates
             ;; the annotation immediately and keeps the toolbar open in edit
             ;; mode so the user can adjust color/style or write a thought.
             (apply-mark
              (lambda (kind color)
                (etaf-reader-guard
                 session
                 (lambda ()
                   (if annotation
                       (etaf-reader-mark-annotation session (plist-get annotation :id)
                                                    kind color)
                     (let ((id (etaf-reader-annotate session kind color)))
                       (when id
                         (etaf-reader-show-annotation-toolbar session id))))))))
             (choose-color
              (lambda (color)
                (funcall apply-mark
                         (if annotation
                             (or (plist-get annotation :kind) "highlight")
                           (or (etaf-reader--read session :last-kind) "highlight"))
                         color)))
             (copy
              (lambda ()
                (etaf-reader-guard
                 session
                 (lambda ()
                   (kill-new (if annotation
                                 (or (plist-get annotation :quote) "")
                               (etaf-reader-selection-text session)))
                   (etaf-reader-message session "已复制")
                   (funcall closing)))))
             (search
              (lambda ()
                (etaf-reader-guard
                 session
                 (lambda ()
                   (let ((query (if annotation
                                    (or (plist-get annotation :quote) "")
                                  (etaf-reader-selection-text session))))
                     (when (and query (not (string-empty-p query)))
                       (funcall closing)
                       (etaf-reader-search-book
                        session (substring query 0 (min 40 (length query))))))))))
             (note
              (lambda ()
                (etaf-reader-write-note session
                                        (and annotation (plist-get annotation :id)))))
             (remove
              (lambda ()
                (etaf-reader-guard
                 session
                 (lambda ()
                   (when annotation
                     (etaf-reader-annotation-delete session (plist-get annotation :id))))))))
        (when (and (>= start-line top) (< (- start-line top) visible-count))
          (let* ((start-slot (- start-line top))
                 (end-slot (min (1- visible-count) (max start-slot (- end-line top))))
                 (end-row (% end-slot rows))
                 ;; Open below the LAST selected line whenever 6+ rows remain
                 ;; below it, else open above the FIRST selected line so the
                 ;; toolbar never obscures multi-line selections.
                 (below-p (< (+ end-row 6) rows))
                 (anchor-slot (if below-p end-slot start-slot))
                 (placement (if below-p 'bottom-start 'top-start))
                 (pop-width (min 38 (max 30 (- (or (etaf-reader--read session :window-columns) 80) 4)))))
            (etaf-view
             (etaf-popover
                 :open t
                 :anchor (format "reader-line-%d" anchor-slot)
                 :placement placement
                 :width (list 'ch pop-width)
                 :on-close closing
               (column :width 'stretch :item-gap '(lh 0)
                 ;; Row 1: 6 color dots + 3 styles
                 (flex :width 'stretch :height '(lh 1) :align-items 'center
                       :gap '((lh 0) (ch 1))
                   (flex :align-items 'center :gap '((lh 0) (ch 1))
                     (expr (mapcar
                            (lambda (color-sym)
                              (let* ((color (symbol-name color-sym))
                                     (selected (equal color active-color)))
                                (etaf-reader--toolbar-button
                                 (if selected "◉" "●")
                                 (etaf-reader-color (etaf-reader--color-key color) theme)
                                 (format "用 %s 色标注" color)
                                 (lambda () (funcall choose-color color))
                                 selected
                                 (format "用 %s 色标注" color))))
                            (etaf-reader-annotation-color-keys))))
                   (box :flex-grow 1)
                   (expr (etaf-reader--toolbar-button
                          "高亮"
                          (if (and annotation (equal active-kind "highlight"))
                              (etaf-reader-color :accent-text theme)
                            (etaf-reader-color :ink theme))
                          "高亮显示"
                          (lambda () (funcall apply-mark "highlight" active-color))
                          (and annotation (equal active-kind "highlight"))))
                   (expr (etaf-reader--toolbar-button
                          "直线"
                          (if (and annotation (equal active-kind "underline"))
                              (etaf-reader-color :accent-text theme)
                            (etaf-reader-color :ink theme))
                          "直线下划线"
                          (lambda () (funcall apply-mark "underline" active-color))
                          (and annotation (equal active-kind "underline"))))
                   (expr (etaf-reader--toolbar-button
                          "波浪"
                          (if (and annotation (equal active-kind "wavy"))
                              (etaf-reader-color :accent-text theme)
                            (etaf-reader-color :ink theme))
                          "波浪下划线"
                          (lambda () (funcall apply-mark "wavy" active-color))
                          (and annotation (equal active-kind "wavy")))))
                 ;; Hairline divider
                 (box :width 'stretch :height '(lh 1)
                      :border-bottom (etaf-reader--line theme :line))
                 ;; Row 2: actions
                 (flex :width 'stretch :height '(lh 1) :align-items 'center
                       :gap '((lh 0) (ch 2))
                   (expr (etaf-reader--toolbar-button
                          "复制" (etaf-reader-color :ink theme) "复制选中文字" copy))
                   (expr (etaf-reader--toolbar-button
                          "写想法" (etaf-reader-color :ink theme) "为这段写想法" note))
                   (expr (etaf-reader--toolbar-button
                          "搜索" (etaf-reader-color :ink theme) "在本书中搜索" search))
                   (expr (etaf-reader--toolbar-button
                          "取消" (etaf-reader-color :muted theme) "关闭标注工具条" closing))
                   (box :flex-grow 1)
                   (expr (when annotation
                           (etaf-reader--toolbar-button
                            "删除" (etaf-reader-color :red theme)
                            "删除这条标注" remove)))))))))))))

;;; ---------------------------------------------------------------------------
;;; Reader
;;; ---------------------------------------------------------------------------

(defun etaf-reader--view-reader-chapter (session theme row offset current)
  "Return SESSION's sidebar entry for chapter ROW at OFFSET, CURRENT or not."
  (let* ((title (etaf-reader--single-line (or (plist-get row :title) "未命名")))
         (label (format "第 %d 章 %s" (1+ offset) title)))
    (etaf-view
     (etaf-button :key offset
                  :ref (when current 'reader-toc-current)
                  :variant 'ghost :width 'stretch :height '(lh 1)
                  :padding '((lh 0) (ch 0))
                  :label label
                  :aria-label label
                  :aria-selected (and current t)
                  :on-press (lambda () (etaf-reader-open-chapter session offset 0))
       (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
         (box :width '(px 2) :height '(lh 1) :flex-shrink 0
              :background-color (if current
                                    (etaf-reader-color :accent theme)
                                  (etaf-reader-color :sidebar theme)))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :overflow 'hidden :wrap-mode 'none
              (text :font-weight (if current 'bold 'normal)
                    :color (if current (etaf-reader-color :accent-text theme)
                             (etaf-reader-color :muted theme))
                    (expr (etaf-reader--clip title 21)))))))))

(defun etaf-reader--view-reader-sidebar (session theme chapter)
  "Return SESSION's full-height scrollable reading sidebar for CHAPTER."
  (let* ((book (etaf-reader--read session :book))
         (chapters (etaf-reader--read session :chapters))
         (title (or (plist-get book :title) "未命名"))
         (author (etaf-reader--book-author book))
         (total (length chapters))
         (index (or (plist-get chapter :index) 0))
         (suffix (format " · 共 %d 章" total))
         (author-line (concat (etaf-reader--clip
                               author (max 4 (- 22 (string-width suffix))))
                              suffix))
         (percent (etaf-reader-percent session))
         (percent-str (etaf-reader-percent-text session)))
    (etaf-view
     (flex :flex-direction 'column :width '(ch 26) :height 'stretch
           :flex-shrink 0 :overflow 'hidden
           :background-color (etaf-reader-color :sidebar theme)
           :border-right (etaf-reader--line theme :line)
           :padding '((lh 1) (ch 1) (lh 1) (ch 1)) :gap '((lh 0) (ch 0))
       ;; Book header (pinned; bottom border aligns flush with running head)
       (flex :flex-direction 'column :width 'stretch :height '(lh 2) :flex-shrink 0
             :padding '((lh 0) (ch 1)) :gap '((lh 0) (ch 0))
             :border-bottom (etaf-reader--line theme :line)
         (box :height '(lh 1) :overflow 'hidden :wrap-mode 'none
              (text :font-weight 'bold (expr (etaf-reader--clip title 22))))
         (box :height '(lh 1) :overflow 'hidden :wrap-mode 'none
              (text :color (etaf-reader-color :muted theme)
                    (expr author-line))))
       (box :height '(lh 1) :flex-shrink 0)
       ;; TOC heading (pinned)
       (flex :width 'stretch :height '(lh 1) :flex-shrink 0
             :align-items 'center :padding '((lh 0) (ch 1))
         (text :font-weight 'bold :color (etaf-reader-color :dim theme) "目录")
         (box :flex-grow 1)
         (text :color (etaf-reader-color :dim theme)
               (expr (format "%d/%d" (1+ index) total))))
       ;; Full-height scrollable chapter list (non-shrinking inner column)
       (flex :flex-direction 'column :ref 'reader-toc-scroll :id "reader-toc-scroll"
             :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
             :overflow 'scroll :gap '((lh 0) (ch 0))
             :aria-label "章节目录"
         (column :width 'stretch :flex-shrink 0 :item-gap '(lh 0)
           (expr (cl-loop for row in chapters
                          for offset from 0
                          collect (etaf-reader--view-reader-chapter
                                   session theme row offset (= offset index))))))
       ;; Progress & full TOC footer (pinned to bottom)
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
             :gap '((lh 0) (ch 0))
         (box :width 'stretch :height '(lh 1)
              :border-bottom (etaf-reader--line theme :line))
         (flex :width 'stretch :height '(lh 1) :align-items 'center
               :padding '((lh 0) (ch 1))
           (text :font-weight 'bold :color (etaf-reader-color :dim theme) "全书进度")
           (box :flex-grow 1)
           (text :ref 'reader-sidebar-pct :id "reader-sidebar-pct"
                 :color (etaf-reader-color :muted theme)
                 (expr percent-str)))
         (box :width 'stretch :height '(lh 1) :overflow 'hidden :wrap-mode 'none
              :padding '((lh 0) (ch 1))
           (text :ref 'reader-sidebar-bar :id "reader-sidebar-bar"
                 (expr (etaf-reader--sidebar-bar-text theme percent 22))))
         (etaf-button :label "全部目录" :variant 'secondary :width 'stretch
                      :on-press (lambda () (etaf-reader-show-pane session 'toc))
           (box :width 'stretch :text-align 'center (text "全部目录"))))))))

(defun etaf-reader--view-reader (session)
  "Return the reading View of SESSION."
  (let* ((theme (etaf-reader--read session :theme))
         (metrics (etaf-reader--read session :metrics))
         (layout (plist-get metrics :layout))
         (spread (max 1 (or (plist-get metrics :spread) 1)))
         (rows (max 1 (or (plist-get metrics :rows) 20)))
         (columns (max 16 (or (plist-get metrics :columns) 40)))
         (lines (etaf-reader--read session :lines))
         (total (length lines))
         (top (min (etaf-reader--read session :line) (max 0 total)))
         (packed (etaf-reader--pack-columns session lines top rows spread))
         (slices (plist-get packed :slices))
         (sidebar-shown (and (etaf-reader--read session :sidebar)
                             (not (eq layout 'narrow))))
         ;; Reserve 2ch display-safe slack so margins never trigger overflow.
         (available (- (or (etaf-reader--read session :window-columns) 160)
                       (if sidebar-shown 26 0)
                       2))
         (body-columns (+ (* spread (+ columns 5)) (* (1- spread) 2)))
         (body-margin (max 0 (/ (- available body-columns) 2)))
         (chapter (etaf-reader--read session :chapter))
         (chapter-title (etaf-reader--single-line (or (plist-get chapter :title) "")))
         (chapter-index (1+ (or (plist-get chapter :index) 0)))
         (chapter-count (length (etaf-reader--read session :chapters)))
         (book (etaf-reader--read session :book))
         (toolbar-open (not (null (etaf-reader--read session :toolbar)))))
    (etaf-view
     ;; Arrows reach the page wherever point rests, not only inside the body.
     (flex :flex-direction 'row :width 'stretch :height 'stretch
           :on-direction #'etaf-reader--direction
           :background-color (etaf-reader-color :bg theme)
           :color (etaf-reader-color :ink theme) :gap '((lh 0) (ch 0))
       (expr (when sidebar-shown
               (etaf-reader--view-reader-sidebar session theme chapter)))
       (flex :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
             :height 'stretch :gap '((lh 0) (ch 0))
             :keys etaf-reader--wheel-keys
         ;; Running head (row 1 aligns baseline-to-baseline with sidebar title)
         (flex :width 'stretch :height '(lh 3) :flex-shrink 0
               :padding '((lh 1) (ch 2) (lh 0) (ch 2))
               :align-items 'flex-start :gap '((lh 0) (ch 1))
               :border-bottom (etaf-reader--line theme :line)
           (etaf-button :label "书库" :variant 'ghost
                        :on-press (lambda () (etaf-reader-show-shelf session)))
           (flex :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0)
                 :min-width '(ch 0) :justify-content 'center :gap '((lh 0) (ch 0))
             (box :height '(lh 1) :overflow 'hidden :wrap-mode 'none :font-weight 'bold
               (text (expr (or (plist-get book :title) ""))))
             (flex :width 'stretch :height '(lh 1) :align-items 'center
                   :gap '((lh 0) (ch 0))
               (box :flex-shrink 1 :min-width '(ch 0) :overflow 'hidden :wrap-mode 'none
                 (text :color (etaf-reader-color :muted theme)
                       (expr chapter-title)))
               (box :flex-shrink 0
                 (text :color (etaf-reader-color :dim theme)
                       (expr (format "%s第 %d/%d 章"
                                     (if (string-empty-p chapter-title) "" " · ")
                                     chapter-index chapter-count))))))
           (etaf-button :if (and (not (eq layout 'narrow)) (>= available 76))
                        :label "侧栏" :variant 'ghost
                        :aria-selected (and sidebar-shown t)
                        :on-press (lambda () (etaf-reader--toggle-sidebar session)))
           (etaf-button :label "目录" :variant 'ghost
                        :on-press (lambda () (etaf-reader-show-pane session 'toc)))
           (etaf-button :if (and (not (eq layout 'narrow)) (>= available 76))
                        :label "笔记" :variant 'ghost
                        :on-press (lambda () (etaf-reader-show-pane session 'notes)))
           (etaf-button :if (and (eq layout 'wide) (>= available 96))
                        :label "搜索" :variant 'ghost
                        :on-press
                        (lambda ()
                          (let ((query (etaf-call-with-input
                                        (lambda () (read-string "搜索全书：")))))
                            (unless (string-empty-p (string-trim query))
                              (etaf-reader--remember-position session)
                              (etaf-reader-search-book session (string-trim query))
                              (etaf-reader-show-pane session 'search)))))
           (etaf-menu :label "更多"
                      :items '((:key settings :label "阅读设置")
                               (:key notes :label "笔记与划线")
                               (:key bookmarks :label "书签列表")
                               (:key add-bookmark :label "收藏这一页")
                               (:key search :label "搜索结果")
                               (:key back :label "返回跳转前")
                               (:key sidebar :label "切换侧栏")
                               (:key help :label "快捷键"))
                      :on-select (lambda (key)
                                   (pcase key
                                     ('add-bookmark (etaf-reader-add-bookmark session))
                                     ('back (etaf-reader-jump-back session))
                                     ('sidebar (etaf-reader--toggle-sidebar session))
                                     (_ (etaf-reader-show-pane session key))))))
         ;; Body (horizontally centered for both 1-column and 2-column layouts)
         (flex :ref 'reader-body :id "reader-body"
               :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
               :min-height '(lh 0) :align-items 'stretch
               :pointer 'text :on-drag (plist-get session :drag-handler)
               :gap (list '(lh 0) (list 'ch (if (> spread 1) 2 0)))
           (box :width (list 'ch body-margin) :flex-shrink 0)
           (expr
            (cl-loop
             for slice in slices
             for col-index from 0
             collect
             (etaf-node
              'column
              (list :key (or (plist-get (car slice) :slot) col-index)
                    :width (list 'ch (+ columns 5)) :flex-shrink 0
                    :item-gap '(lh 0) :padding '((lh 1) (ch 2)))
              (if (or toolbar-open
                      (cl-some (lambda (line) (eq (plist-get line :kind) 'img)) slice))
                  ;; Individual line anchors exist while a toolbar or picture needs them.
                  (mapcar (lambda (line)
                            (etaf-reader--view-line session line theme))
                          slice)
                (let ((id (format "reader-column-%d" col-index)))
                  (list
                   (etaf-node
                    'box (list :width 'stretch :height (list 'lh rows)
                               :overflow 'hidden :wrap-mode 'none)
                    (list (etaf-node
                           'text (list :ref (intern id) :id id)
                           (list (mapconcat
                                  (lambda (line)
                                    (etaf-reader--line-content session line theme))
                                  slice "\n")))))))))))
           (box :width (list 'ch body-margin) :flex-shrink 0))
         ;; Status line
         (flex :width 'stretch :height '(lh 2) :flex-shrink 0
               :padding '((lh 0) (ch 2))
               :align-items 'center :gap '((lh 0) (ch 2))
               :border-top (list '(px 1) 'solid (etaf-reader-color :line theme))
           (box :height '(lh 1) :flex-shrink 0 :color (etaf-reader-color :muted theme)
             (text :ref 'reader-page :id "reader-page"
                   (expr (concat (etaf-reader--page-label session) " · "
                                 (etaf-reader-percent-text session)))))
           (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
                :overflow 'hidden :wrap-mode 'none :text-align 'center
                :color (etaf-reader-color :dim theme)
             (text (expr (or (etaf-reader--read session :message)
                             (if (eq layout 'wide)
                                 "空格 翻页 · 拖拽 / v 选择 · s 搜索 · c 目录 · a 笔记 · o 设置 · d 侧栏"
                               "空格 翻页 · v 选择 · o 设置")))))))))))

;;; ---------------------------------------------------------------------------
;;; Shelf & Library shell (Dalibre-inspired native Emacs layout)
;;; ---------------------------------------------------------------------------

(defconst etaf-reader--cover-rows 7
  "Default text lines a shelf cover occupies.")

(defconst etaf-reader--cover-columns 12
  "Character columns a shelf cover occupies.")

(defun etaf-reader--line (theme key)
  "Return a one pixel border line in THEME's KEY color."
  (list '(px 1) 'solid (etaf-reader-color key theme)))

(defconst etaf-reader--cover-tints
  '((:accent-soft :accent-text) (:green-soft :green) (:orange-soft :orange)
    (:purple-soft :purple) (:red-soft :red) (:panel2 :muted))
  "Fill and ink of a generated cover, paired by tone.
A book without an extracted cover still reads as a book front, and every
tone comes from the current palette.")

(defun etaf-reader--cover-path (book)
  "Return BOOK's cached cover file name, or nil.
The View only builds the name; a missing file is the image Host's
placeholder, not a render-time disk check."
  (let ((cover (plist-get book :cover)))
    (unless (or (null cover) (string-empty-p cover))
      (expand-file-name cover (etaf-reader--cache-book-directory (plist-get book :id))))))

(defun etaf-reader--cover-tint (theme title)
  "Return (FILL . INK) for a generated cover of TITLE."
  (let* ((index (mod (cl-loop for character across (or title "")
                              sum (logand character 255))
                     (length etaf-reader--cover-tints)))
         (pair (nth index etaf-reader--cover-tints)))
    (cons (etaf-reader-color (car pair) theme)
          (etaf-reader-color (cadr pair) theme))))

(defun etaf-reader--book-percent (session book)
  "Return BOOK's progress percent from SESSION's cached states."
  (or (plist-get (etaf-reader-book-state session (plist-get book :id)) :percent)
      0))

(defun etaf-reader--shelf-title (session)
  "Return the shelf's current view title."
  (let ((format (etaf-reader--read session :facet-format))
        (author (etaf-reader--read session :facet-author)))
    (cond (format format)
          (author author)
          (t (pcase (etaf-reader--read session :filter)
               ('reading "在读") ('unread "未读") ('finished "已读")
               (_ "全部书籍"))))))

;;; Shelf Sidebar

(defun etaf-reader--view-sidebar-item (theme key label count selected on-press
                                             &optional icon badge-colors)
  "Return one sidebar row: KEY, LABEL, COUNT, optional ICON or BADGE-COLORS."
  (etaf-view
   (etaf-button :key key :variant 'ghost :width 'stretch :height '(lh 1)
                :padding '((lh 0) (ch 1))
                :label label :aria-selected (and selected t)
                :on-press on-press
     (flex :width 'stretch :height '(lh 1) :align-items 'center
           :gap '((lh 0) (ch 1))
       (box :width '(px 2) :height '(lh 1) :flex-shrink 0
            :background-color (if selected
                                  (etaf-reader-color :accent theme)
                                (etaf-reader-color :sidebar theme)))
       (expr (when icon
               (etaf-ui-icon icon :min-width 1
                             :color (if selected
                                        (etaf-reader-color :accent-text theme)
                                      (etaf-reader-color :dim theme)))))
       (expr
        (if badge-colors
            (etaf-view
             (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :height '(lh 1) :overflow 'hidden
               (flex :height '(lh 1) :align-items 'center
                 (box :padding '((lh 0) (ch 1)) :height '(lh 1)
                      :background-color (cdr badge-colors)
                   (text :font-weight 'bold :color (car badge-colors)
                         (expr label))))))
          (etaf-view
           (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                :overflow 'hidden :wrap-mode 'none
             (text :font-weight (if selected 'bold 'normal)
                   :color (if selected (etaf-reader-color :accent-text theme)
                            (etaf-reader-color :ink theme))
                   (expr (etaf-reader--clip label (if icon 14 16))))))))
       (expr (when count
               (etaf-view
                (box :flex-shrink 0
                  (text :color (if selected (etaf-reader-color :accent-text theme)
                                 (etaf-reader-color :dim theme))
                        (expr (number-to-string count)))))))))))

(defun etaf-reader--view-sidebar-section (theme title count)
  "Return a sidebar group heading with TITLE and COUNT."
  (etaf-view
   (flex :height '(lh 1) :width 'stretch :align-items 'center
         :padding '((lh 0) (ch 1))
     (box :flex-grow 1 (text :font-weight 'bold
                             :color (etaf-reader-color :dim theme) (expr title)))
     (expr (when count
             (etaf-view
              (text :color (etaf-reader-color :faint theme)
                    (expr (number-to-string count)))))))))

(defun etaf-reader--view-shelf-sidebar (session theme facets)
  "Return SESSION's full-height scrollable shelf sidebar."
  (let* ((filter (etaf-reader--read session :filter))
         (format-facet (etaf-reader--read session :facet-format))
         (author-facet (etaf-reader--read session :facet-author))
         (formats (plist-get facets :formats))
         (authors (plist-get facets :authors))
         (total (or (plist-get facets :total) 0))
         (dir-label (if (and (listp etaf-reader-library-directories)
                             (cdr etaf-reader-library-directories))
                        "多个目录"
                      (abbreviate-file-name
                       (or (car etaf-reader-library-directories) "~/ebooks"))))
         (suffix (format " · %d 本" total))
         (subtitle (concat (etaf-reader--clip
                            dir-label (max 4 (- 22 (string-width suffix))))
                           suffix)))
    (etaf-view
     (flex :flex-direction 'column :width '(ch 26) :height 'stretch
           :flex-shrink 0 :overflow 'hidden
           :background-color (etaf-reader-color :sidebar theme)
           :border-right (etaf-reader--line theme :line)
           :padding '((lh 1) (ch 1) (lh 1) (ch 1)) :gap '((lh 0) (ch 0))
       ;; Pinned library header (aligns with toolbar bottom edge)
       (flex :flex-direction 'column :width 'stretch :height '(lh 2) :flex-shrink 0
             :padding '((lh 0) (ch 1)) :gap '((lh 0) (ch 0))
             :border-bottom (etaf-reader--line theme :line)
         (text :font-weight 'bold "本地书库")
         (box :height '(lh 1) :overflow 'hidden :wrap-mode 'none
              (text :color (etaf-reader-color :muted theme) (expr subtitle))))
       (box :height '(lh 1) :flex-shrink 0)
       ;; Scrollable middle: non-shrinking inner column preserves section headings
       (flex :flex-direction 'column :ref 'shelf-sidebar-scroll :id "shelf-sidebar-scroll"
             :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
             :overflow 'scroll :gap '((lh 0) (ch 0))
             :aria-label "书库导航"
         (column :width 'stretch :flex-shrink 0 :item-gap '(lh 0)
           (expr (etaf-reader--view-sidebar-item
                  theme 'all "全部书籍" total (eq filter 'all)
                  (lambda () (etaf-reader-filter-library
                              session (etaf-reader--read session :shelf-query) 'all))
                  'list))
           (expr (etaf-reader--view-sidebar-item
                  theme 'reading "在读" (plist-get facets :reading) (eq filter 'reading)
                  (lambda () (etaf-reader-filter-library
                              session (etaf-reader--read session :shelf-query) 'reading))
                  'clock))
           (expr (etaf-reader--view-sidebar-item
                  theme 'unread "未读" (plist-get facets :unread) (eq filter 'unread)
                  (lambda () (etaf-reader-filter-library
                              session (etaf-reader--read session :shelf-query) 'unread))
                  'eye))
           (expr (etaf-reader--view-sidebar-item
                  theme 'finished "已读" (plist-get facets :finished) (eq filter 'finished)
                  (lambda () (etaf-reader-filter-library
                              session (etaf-reader--read session :shelf-query) 'finished))
                  'check))
           (box :height '(lh 1))
           (expr (etaf-reader--view-sidebar-section theme "格式" (length formats)))
           (expr (mapcar
                  (lambda (row)
                    (etaf-reader--view-sidebar-item
                     theme (format "format:%s" (car row)) (car row) (cdr row)
                     (equal (car row) format-facet)
                     (lambda () (etaf-reader-set-facet
                                 session 'format
                                 (unless (equal (car row) (etaf-reader--read session :facet-format))
                                   (car row))))
                     nil (etaf-reader-format-colors (car row) theme)))
                  formats))
           (box :height '(lh 1))
           (expr (etaf-reader--view-sidebar-section theme "作者" (length authors)))
           (expr (mapcar
                  (lambda (row)
                    (etaf-reader--view-sidebar-item
                     theme (format "author:%s" (car row)) (car row) (cdr row)
                     (equal (car row) author-facet)
                     (lambda () (etaf-reader-set-facet
                                 session 'author
                                 (unless (equal (car row) (etaf-reader--read session :facet-author))
                                   (car row))))))
                  authors))))
       ;; Pinned bottom actions
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
             :gap '((lh 0) (ch 0))
         (box :height '(lh 1) :width 'stretch
              :border-bottom (etaf-reader--line theme :line))
         (etaf-button :label "扫描书库" :variant 'ghost :width 'stretch :height '(lh 1)
                      :padding '((lh 0) (ch 1))
                      :on-press (lambda () (etaf-reader-refresh-library session))
           (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
             (expr (etaf-ui-icon 'refresh :min-width 1
                                 :color (etaf-reader-color :muted theme)))
             (text :color (etaf-reader-color :muted theme) "扫描书库")))
         (etaf-button :label "阅读设置" :variant 'ghost :width 'stretch :height '(lh 1)
                      :padding '((lh 0) (ch 1))
                      :on-press (lambda () (etaf-reader-show-pane session 'settings))
           (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
             (expr (etaf-ui-icon 'settings :min-width 1
                                 :color (etaf-reader-color :muted theme)))
             (text :color (etaf-reader-color :muted theme) "阅读设置"))))))))

;;; Toolbar, chips, grid, list, footer

(defun etaf-reader--view-shelf-chips (session theme width)
  "Return the shelf's facet chips: reading state, format, author and sort."
  (let* ((filter (etaf-reader--read session :filter))
         (format (etaf-reader--read session :facet-format))
         (author (etaf-reader--read session :facet-author))
         (facets (etaf-reader--library-facets session))
         (query (etaf-reader--read session :shelf-query))
         (sort-key (etaf-reader--read session :shelf-sort))
         (state-label (pcase filter
                        ('reading "在读") ('unread "未读") ('finished "已读")
                        (_ "全部")))
         (sort-caption (pcase sort-key
                         ('title "按书名") ('author "按作者")
                         (_ "按最近阅读 ↓")))
         (has-filter (or format author
                         (not (string-empty-p query))
                         (not (eq filter 'all))))
         (format-items (cons (list :key "all" :label "全部格式")
                             (mapcar (lambda (row)
                                       (list :key (car row)
                                             :label (format "%s · %d" (car row) (cdr row))))
                                     (plist-get facets :formats))))
         (author-items (cons (list :key "all" :label "全部作者")
                             (mapcar (lambda (row)
                                       (list :key (car row)
                                             :label (format "%s · %d" (car row) (cdr row))))
                                     (plist-get facets :authors)))))
    (etaf-view
     (flex :height '(lh 1) :width 'stretch :flex-shrink 0 :align-items 'center
           :padding (if (< width 92) '((lh 0) (ch 1)) '((lh 0) (ch 2)))
           :gap '((lh 0) (ch 1))
       (etaf-menu
        :label (format "状态 · %s" state-label)
        :items (list (list :key 'all :label "全部状态")
                     (list :key 'reading :label "在读")
                     (list :key 'unread :label "未读")
                     (list :key 'finished :label "已读"))
        :on-select (lambda (key)
                     (etaf-reader-filter-library
                      session query (if (eq key 'all) 'all key)
                      (etaf-reader--read session :shelf-sort))))
       (etaf-menu
        :label (format "格式 · %s" (or format "全部"))
        :items format-items
        :on-select (lambda (key)
                     (etaf-reader-set-facet session 'format
                                            (unless (equal key "all") key))))
       (etaf-menu
        :label (format "作者 · %s" (etaf-reader--clip (or author "全部") 12))
        :items author-items
        :on-select (lambda (key)
                     (etaf-reader-set-facet session 'author
                                            (unless (equal key "all") key))))
       (box :flex-grow 1)
       (expr (if has-filter
                 (etaf-view
                  (etaf-button :label "清除筛选" :variant 'ghost
                               :on-press (lambda ()
                                           (etaf-reader-set-facet session 'format nil)
                                           (etaf-reader-set-facet session 'author nil)
                                           (etaf-reader-filter-library session "" 'all))))
               (when (>= width 92)
                 (etaf-view
                  (text :color (etaf-reader-color :dim theme) (expr sort-caption))))))))))

(defun etaf-reader--view-shelf-toolbar (session theme page width)
  "Return SESSION's shelf toolbar for PAGE at viewport WIDTH."
  (let ((narrow (< width 92)))
    (etaf-view
     (flex :height '(lh 3) :width 'stretch :flex-shrink 0 :align-items 'center
           :padding (if narrow '((lh 0) (ch 1)) '((lh 0) (ch 2)))
           :gap '((lh 0) (ch 1))
       (box :overflow 'hidden :wrap-mode 'none :flex-shrink 1 :min-width '(ch 4)
         (text :font-weight 'bold
               (expr (etaf-reader--clip (etaf-reader--shelf-title session)
                                        (if narrow 10 20)))))
       (box :flex-shrink 0
         (text :color (etaf-reader-color :dim theme)
               (expr (format "%d 本" (plist-get page :total)))))
       (box :flex-grow 1)
       (etaf-search-field :if (>= width 136)
                          :value (etaf-reader--read session :shelf-query)
                          :placeholder "搜索书名、作者" :icon t :width '(ch 24)
                          :on-change (lambda (value)
                                       (etaf-reader-filter-library
                                        session value
                                        (etaf-reader--read session :filter))))
       (etaf-segmented :options '((grid . "网格") (list . "列表"))
                       :bind (etaf-reader--ref session :shelf-view))
       (etaf-menu :label "排序"
                  :items '((:key recent :label "最近阅读") (:key title :label "书名")
                           (:key author :label "作者"))
                  :on-select (lambda (key)
                               (etaf-reader-filter-library
                                session (etaf-reader--read session :shelf-query)
                                (etaf-reader--read session :filter) key)))
       (etaf-button :if (>= width 130) :label "详情" :variant 'ghost
                    :aria-selected (and (etaf-reader--read session :detail) t)
                    :on-press (lambda () (etaf-reader--toggle-detail session)))
       (etaf-button :label (if narrow "扫描" "扫描书库") :variant 'primary
                    :on-press (lambda () (etaf-reader-refresh-library session)))))))

(defun etaf-reader--view-shelf-cover (session theme book cover-rows)
  "Return one book standing flush on the shelf board, lifting when selected."
  (let* ((title (or (plist-get book :title) "未命名"))
         (author (etaf-reader--book-author book))
         (selected (equal (plist-get book :id) (etaf-reader--read session :shelf-cursor)))
         (path (etaf-reader--cover-path book))
         (tint (etaf-reader--cover-tint theme title))
         (slot-rows (1+ cover-rows)))
    (etaf-view
     (etaf-button :key (plist-get book :id) :variant 'ghost :pointer 'hand
                  :width (list 'ch etaf-reader--cover-columns)
                  :height (list 'lh slot-rows) :padding '((lh 0) (ch 0))
                  :label (format "《%s》" title)
                  :aria-label (format "《%s》，%s" title author)
                  :help-echo (if selected "再按一次打开这本书" "选中这本书")
                  :on-press (lambda () (etaf-reader-guard
                                        session (lambda () (etaf-reader--press-book session book))))
       (flex :flex-direction 'column :width 'stretch :height (list 'lh slot-rows)
             :gap '((lh 0) (ch 0))
             :justify-content (if selected 'flex-start 'flex-end)
         (box :width 'stretch :height (list 'lh cover-rows)
              :overflow 'hidden :background-color (car tint)
              :border (etaf-reader--line theme (if selected :accent :line))
           (expr (when path
                   (etaf-node 'image
                              (list :src path
                                    :columns etaf-reader--cover-columns
                                    :rows cover-rows)
                              nil)))
           (expr (unless path
                   (etaf-view
                    (flex :flex-direction 'column :width 'stretch
                          :height (list 'lh cover-rows)
                          :overflow 'hidden
                          :padding (if (>= cover-rows 7) '((lh 1) (ch 1)) '((lh 0) (ch 1)))
                          :gap '((lh 0) (ch 0))
                      (box :if (>= cover-rows 7) :height '(lh 1)
                           :overflow 'hidden :wrap-mode 'none
                        (text :color (etaf-reader-color :muted theme)
                              (expr (etaf-reader--clip author (- etaf-reader--cover-columns 2)))))
                      (box :flex-grow 1)
                      (box :width 'stretch :overflow 'hidden
                        (text :font-weight 'bold :color (cdr tint)
                              (expr (etaf-reader--clip title 20))))))))))))))

(defun etaf-reader--meter (theme percent columns)
  "Return a COLUMNS wide two tone line meter at PERCENT."
  (let* ((percent (max 0 (min 100 percent)))
         (filled (round (* percent columns 0.01))))
    (etaf-node 'flex (list :width (list 'ch columns) :height '(lh 1) :flex-shrink 0
                           :align-items 'flex-end)
               (list (etaf-node 'box
                                (list :width (list 'ch filled) :height '(lh 1)
                                      :border-bottom (list '(px 1) 'solid
                                                           (etaf-reader-color :accent theme)))
                                nil)
                     (etaf-node 'box
                                (list :flex-grow 1 :height '(lh 1)
                                      :border-bottom (list '(px 1) 'solid
                                                           (etaf-reader-color :line theme)))
                                nil)))))

(defun etaf-reader--view-shelf-label (session theme book)
  "Return BOOK's title and author under the shelf board."
  (let* ((selected (equal (plist-get book :id) (etaf-reader--read session :shelf-cursor)))
         (title (or (plist-get book :title) "未命名"))
         (author (etaf-reader--book-author book)))
    (etaf-view
     (column :width (list 'ch etaf-reader--cover-columns) :height '(lh 2)
             :item-gap '(lh 0) :overflow 'hidden
       (box :height '(lh 1) :overflow 'hidden :wrap-mode 'none
         (text :font-weight (if selected 'bold 'normal)
               :color (if selected (etaf-reader-color :accent-text theme)
                        (etaf-reader-color :ink theme))
               (expr (etaf-reader--clip title etaf-reader--cover-columns))))
       (box :height '(lh 1) :overflow 'hidden :wrap-mode 'none
         (text :color (etaf-reader-color :dim theme)
               (expr (etaf-reader--clip author etaf-reader--cover-columns))))))))

(defun etaf-reader--view-shelf-board (session theme books)
  "Return the shelf ledge BOOKS stand flush on, with integrated progress rails."
  (let ((count (length books)))
    (etaf-view
     (flex :width 'stretch :height '(lh 1) :align-items 'stretch :gap '((lh 0) (ch 0))
       (expr
        (cl-loop
         for book in books
         for idx from 0
         for last = (= idx (1- count))
         for selected = (equal (plist-get book :id)
                               (etaf-reader--read session :shelf-cursor))
         for percent = (max 0 (min 100 (etaf-reader--book-percent session book)))
         for filled = (if (> percent 0)
                          (max 1 (round (* percent etaf-reader--cover-columns 0.01)))
                        0)
         for rest = (- etaf-reader--cover-columns filled)
         collect
         (etaf-view
          (flex :width (list 'ch (+ etaf-reader--cover-columns
                                    (if last 0 etaf-reader--cell-gap)))
                :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 0))
                :background-color (etaf-reader-color :plank-face theme)
            (box :if (> filled 0) :width (list 'ch filled) :height '(lh 1)
                 :border-top (etaf-reader--line theme :accent)
                 :border-bottom (etaf-reader--line theme (if selected :accent :plank-edge)))
            (box :if (> rest 0) :width (list 'ch rest) :height '(lh 1)
                 :border-top (etaf-reader--line theme :plank-top)
                 :border-bottom (etaf-reader--line theme (if selected :accent :plank-edge)))
            (box :if (not last) :width (list 'ch etaf-reader--cell-gap) :height '(lh 1)
                 :border-top (etaf-reader--line theme :plank-top)
                 :border-bottom (etaf-reader--line theme :plank-edge))))))
       (box :flex-grow 1 :height '(lh 1)
            :background-color (etaf-reader-color :plank-face theme)
            :border-top (etaf-reader--line theme :plank-top)
            :border-bottom (etaf-reader--line theme :plank-edge))))))

(defun etaf-reader--view-shelf-row (session theme books cover-rows &optional row-key)
  "Return one shelf of BOOKS: covers resting flush on the ledge, and labels."
  (let ((slot-rows (1+ cover-rows)))
    (etaf-view
     (column :key row-key :width 'stretch :item-gap '(lh 0)
       (flex :width 'stretch :height (list 'lh slot-rows) :align-items 'flex-end
             :gap (list '(lh 0) (list 'ch etaf-reader--cell-gap))
         (expr (mapcar (lambda (book)
                         (etaf-reader--view-shelf-cover session theme book cover-rows))
                       books)))
       (expr (etaf-reader--view-shelf-board session theme books))
       (flex :width 'stretch :height '(lh 2)
             :gap (list '(lh 0) (list 'ch etaf-reader--cell-gap))
         (expr (mapcar (lambda (book) (etaf-reader--view-shelf-label session theme book))
                       books)))))))

;;; List View (responsive column tiers so Title never collapses)

(defun etaf-reader--list-tier (main-columns)
  "Return responsive column tier (`full', `medium', or `compact') for MAIN-COLUMNS."
  (cond ((>= main-columns 84) 'full)
        ((>= main-columns 58) 'medium)
        (t 'compact)))

(defun etaf-reader--view-shelf-list-header (theme tier)
  "Return the list view's column headings for responsive TIER."
  (etaf-view
   (flex :height '(lh 1) :width 'stretch :align-items 'center
         :gap '((lh 0) (ch 1)) :padding '((lh 0) (px 2) (lh 0) (px 2))
     (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
          (text :color (etaf-reader-color :dim theme) "标题"))
     (box :if (memq tier '(full medium)) :width (if (eq tier 'full) '(ch 14) '(ch 12))
          :flex-shrink 0
          (text :color (etaf-reader-color :dim theme) "作者"))
     (box :width '(ch 5) :flex-shrink 0
          (text :color (etaf-reader-color :dim theme) "格式"))
     (box :if (eq tier 'full) :width '(ch 7) :flex-shrink 0 :text-align 'right
          (text :color (etaf-reader-color :dim theme) "章节"))
     (box :width (pcase tier ('full '(ch 14)) ('medium '(ch 12)) (_ '(ch 5)))
          :flex-shrink 0 :text-align (if (eq tier 'compact) 'right 'left)
          (text :color (etaf-reader-color :dim theme) "进度"))
     (box :if (eq tier 'full) :width '(ch 12) :flex-shrink 0 :text-align 'right
          (text :color (etaf-reader-color :dim theme) "最近阅读")))))

(defun etaf-reader--view-shelf-list-row (session theme book tier title-columns)
  "Return one line of the list view for BOOK at TIER and TITLE-COLUMNS."
  (let* ((id (plist-get book :id))
         (title (or (plist-get book :title) "未命名"))
         (author (etaf-reader--book-author book))
         (selected (equal id (etaf-reader--read session :shelf-cursor)))
         (percent (max 0 (min 100 (etaf-reader--book-percent session book))))
         (format (upcase (or (plist-get book :format) "")))
         (colors (etaf-reader-format-colors format theme))
         (state (etaf-reader-book-state session id))
         (opened (plist-get state :last_read)))
    (etaf-view
     (etaf-button :key id :variant 'ghost :width 'stretch :height '(lh 1)
                  :padding '((lh 0) (ch 0)) :label (format "《%s》" title)
                  :aria-label (format "《%s》，%s" title author)
                  :aria-selected (and selected t)
                  :on-press (lambda () (etaf-reader-guard
                                        session (lambda () (etaf-reader--press-book session book))))
       (flex :width 'stretch :height '(lh 1) :align-items 'center
             :gap '((lh 0) (ch 1)) :padding '((lh 0) (px 2) (lh 0) (px 2))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :overflow 'hidden :wrap-mode 'none
              (text :font-weight (if selected 'bold 'normal)
                    :color (if selected (etaf-reader-color :accent-text theme)
                             (etaf-reader-color :ink theme))
                    (expr (etaf-reader--clip title (max 10 title-columns)))))
         (box :if (memq tier '(full medium))
              :width (if (eq tier 'full) '(ch 14) '(ch 12))
              :flex-shrink 0 :overflow 'hidden :wrap-mode 'none
              (text :color (etaf-reader-color :muted theme)
                    (expr (etaf-reader--clip author (if (eq tier 'full) 14 12)))))
         (box :width '(ch 5) :flex-shrink 0 (text :color (car colors) (expr format)))
         (box :if (eq tier 'full) :width '(ch 7) :flex-shrink 0 :text-align 'right
              (text :color (etaf-reader-color :dim theme)
                    (expr (let ((chapters (plist-get book :chapters)))
                            (if (and chapters (> chapters 0))
                                (format "%d 章" chapters) "—")))))
         (expr
          (if (eq tier 'compact)
              (etaf-view
               (box :width '(ch 5) :flex-shrink 0 :text-align 'right
                 (text :color (if (> percent 0) (etaf-reader-color :muted theme)
                                (etaf-reader-color :dim theme))
                       (expr (if (> percent 0) (format "%d%%" (round percent)) "未读")))))
            (let ((bar-w (if (eq tier 'full) 7 5)))
              (etaf-view
               (flex :width (if (eq tier 'full) '(ch 14) '(ch 12))
                     :flex-shrink 0 :height '(lh 1) :align-items 'center
                     :gap '((lh 0) (ch 1))
                 (expr (etaf-reader--meter theme percent bar-w))
                 (box :width '(ch 5) :flex-shrink 0 :text-align 'right
                      (text :color (if (> percent 0) (etaf-reader-color :muted theme)
                                     (etaf-reader-color :dim theme))
                            (expr (if (> percent 0) (format "%d%%" (round percent)) "未读")))))))))
         (box :if (eq tier 'full) :width '(ch 12) :flex-shrink 0 :text-align 'right
              (text :color (etaf-reader-color :dim theme)
                    (expr (if (and opened (> opened 0))
                              (format-time-string "%m-%d %H:%M" (seconds-to-time opened))
                            "—")))))))))

(defun etaf-reader--view-shelf-list (session theme items main-columns)
  "Return the responsive list view of ITEMS inside MAIN-COLUMNS."
  (let* ((tier (etaf-reader--list-tier main-columns))
         (fixed (pcase tier ('full 60) ('medium 36) (_ 16)))
         (title-columns (max 12 (- main-columns fixed))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       (expr (etaf-reader--view-shelf-list-header theme tier))
       (box :width 'stretch :height '(lh 1)
            :border-bottom (etaf-reader--line theme :line))
       (column :width 'stretch :item-gap '(lh 0)
         (expr (mapcar (lambda (book)
                         (etaf-reader--view-shelf-list-row
                          session theme book tier title-columns))
                       items)))))))

(defun etaf-reader--shelf-groups (items columns)
  "Split ITEMS into rows of COLUMNS books."
  (let (rows)
    (while items
      (push (seq-take items columns) rows)
      (setq items (nthcdr columns items)))
    (nreverse rows)))

(defun etaf-reader--view-shelf-footer (session theme page book width)
  "Return SESSION's shelf footer for PAGE, showing status messages or cursor hint."
  (let* ((narrow (< width 92))
         (msg (etaf-reader--read session :message))
         (hint (cond ((>= width 132)
                      (when book
                        (format "选中《%s》 · 回车打开 · j/k/h/l 移动"
                                (etaf-reader--clip (or (plist-get book :title) "") 18))))
                     ((>= width 92) "回车打开 · j/k/h/l 移动")
                     (t nil)))
         (center (or msg hint)))
    (etaf-view
     (flex :height '(lh 2) :width 'stretch :flex-shrink 0 :align-items 'center
           :padding (if narrow '((lh 0) (ch 1)) '((lh 0) (ch 2)))
           :gap '((lh 0) (ch 1))
           :border-top (etaf-reader--line theme :line)
       (etaf-button :label "上一页" :variant 'ghost
                    :disabled (= (plist-get page :index) 0)
                    :on-press (lambda () (etaf-reader-page-library session -1)))
       (box :flex-shrink 0
         (text :color (etaf-reader-color :muted theme)
               (expr (format "第 %d / %d 页" (1+ (plist-get page :index))
                             (plist-get page :pages)))))
       (etaf-button :label "下一页" :variant 'ghost
                    :disabled (= (1+ (plist-get page :index)) (plist-get page :pages))
                    :on-press (lambda () (etaf-reader-page-library session 1)))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
            :overflow 'hidden :wrap-mode 'none :text-align 'center
         (text :color (if msg (etaf-reader-color :muted theme)
                        (etaf-reader-color :dim theme))
               (expr (or center ""))))
       (box :flex-shrink 0
         (text :color (etaf-reader-color :dim theme)
               (expr (format "共 %d 本" (plist-get page :total)))))))))

;;; Detail panel (Dalibre-style tight grouping + scrollable body + pinned actions)

(defun etaf-reader--format-chars (chars)
  "Format character count CHARS concisely."
  (cond ((or (null chars) (<= chars 0)) nil)
        ((>= chars 10000) (format "%.1f 万字" (/ chars 10000.0)))
        (t (format "%d 字" chars))))

(defun etaf-reader--view-detail (session theme book)
  "Return SESSION's detail panel for BOOK."
  (let* ((title (or (plist-get book :title) "未命名"))
         (author (etaf-reader--book-author book))
         (percent (etaf-reader--book-percent session book))
         (state (etaf-reader-book-state session (plist-get book :id)))
         (opened (plist-get state :last_read))
         (format (upcase (or (plist-get book :format) "")))
         (colors (etaf-reader-format-colors format theme))
         (path (etaf-reader--cover-path book))
         (tint (etaf-reader--cover-tint theme title))
         (chapters (plist-get book :chapters))
         (pages (plist-get book :pages))
         (chars-text (etaf-reader--format-chars (plist-get book :chars)))
         (size (plist-get book :size))
         (notes (etaf-reader--read session :shelf-notes))
         (progress-line
          (cond ((and (> percent 0) opened (> opened 0))
                 (format "已读 %d%% · 上次 %s"
                         (round percent)
                         (format-time-string "%m-%d %H:%M" (seconds-to-time opened))))
                ((> percent 0) (format "已读 %d%%" (round percent)))
                (t "未读"))))
    (etaf-view
     (flex :flex-direction 'column :width '(ch 38) :height 'stretch
           :flex-shrink 0 :overflow 'hidden
           :background-color (etaf-reader-color :panel theme)
           :border-left (etaf-reader--line theme :line)
           :padding '((lh 1) (ch 2) (lh 1) (ch 2)) :gap '((lh 0) (ch 0))
       ;; Scrollable detail content (non-shrinking inner column)
       (flex :flex-direction 'column :ref 'shelf-detail-scroll :id "shelf-detail-scroll"
             :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
             :overflow 'scroll :gap '((lh 0) (ch 0))
             :aria-label "书籍详情"
         (column :width 'stretch :flex-shrink 0 :item-gap '(lh 1)
           ;; Cover + title/author/progress grouped tightly
           (column :width 'stretch :item-gap '(lh 0)
             (flex :flex-direction 'column :width 'stretch :height '(lh 13)
                   :justify-content 'center :align-items 'center :gap '((lh 0) (ch 0))
                   :background-color (etaf-reader-color :subtle theme)
               (box :width '(ch 16) :height '(lh 11) :overflow 'hidden
                    :border (etaf-reader--line theme :line)
                    :background-color (car tint)
                 (expr (when path
                         (etaf-node 'image (list :src path :columns 16 :rows 11) nil)))
                 (expr (unless path
                         (etaf-view
                          (flex :flex-direction 'column :width 'stretch :height 'stretch
                                :overflow 'hidden :justify-content 'center :align-items 'stretch
                                :wrap-mode 'word :padding '((lh 1) (ch 1))
                            (box :width 'stretch :text-align 'center
                              (text :font-weight 'bold :color (cdr tint)
                                    (expr (etaf-reader--clip title 28))))))))))
             (box :height '(lh 1))
             (box :width 'stretch :text-align 'center :overflow 'hidden :wrap-mode 'none
               (text :font-weight 'bold (expr (etaf-reader--clip title 32))))
             (box :width 'stretch :text-align 'center :overflow 'hidden :wrap-mode 'none
               (text :color (etaf-reader-color :accent-text theme)
                     (expr (etaf-reader--clip author 32))))
             (box :width 'stretch :text-align 'center :overflow 'hidden :wrap-mode 'none
               (text :color (etaf-reader-color :dim theme) (expr progress-line))))
           ;; Metadata section (tight rows)
           (column :width 'stretch :item-gap '(lh 0)
             (box :width 'stretch :height '(lh 1)
                  :border-top (etaf-reader--line theme :line)
               (text :font-weight 'bold :color (etaf-reader-color :dim theme) "详情"))
             (expr (etaf-reader--view-detail-row theme "格式" format))
             (expr (when (and chapters (> chapters 0))
                     (etaf-reader--view-detail-row theme "章节" (format "%d 章" chapters))))
             (expr (when (and pages (> pages 0))
                     (etaf-reader--view-detail-row theme "页数" (format "%d 页" pages))))
             (expr (when chars-text
                     (etaf-reader--view-detail-row theme "字数" chars-text)))
             (expr (etaf-reader--view-detail-row theme "大小" (etaf-reader--file-size size))))
           ;; File section (tight)
           (column :width 'stretch :item-gap '(lh 0)
             (box :width 'stretch :height '(lh 1)
                  :border-top (etaf-reader--line theme :line)
               (text :font-weight 'bold :color (etaf-reader-color :dim theme) "文件"))
             (flex :width 'stretch :height '(lh 1) :align-items 'center
                   :gap '((lh 0) (ch 1))
               (box :width '(ch 6) :flex-shrink 0 :height '(lh 1) :text-align 'center
                    :background-color (cdr colors)
                 (text :font-weight 'bold :color (car colors) (expr format)))
               (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                    :overflow 'hidden :wrap-mode 'none
                 (text (expr (etaf-reader--clip
                              (file-name-nondirectory (or (plist-get book :path) ""))
                              26))))))
           ;; Annotations preview
           (expr (etaf-reader--view-detail-notes session theme))))
       ;; Pinned action buttons (centered labels, clean hierarchy)
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
             :gap '((lh 0) (ch 0))
         (box :width 'stretch :height '(lh 1)
              :border-bottom (etaf-reader--line theme :line))
         (etaf-button :label (if (> percent 0) "继续阅读" "开始阅读") :variant 'primary
                      :width 'stretch
                      :on-press (lambda () (etaf-reader-guard
                                            session (lambda () (etaf-reader-open-book session book))))
           (box :width 'stretch :text-align 'center
             (text :font-weight 'bold (expr (if (> percent 0) "继续阅读" "开始阅读")))))
         (etaf-button :label "从头开始" :variant 'secondary :width 'stretch
                      :on-press (lambda () (etaf-reader-guard
                                            session (lambda ()
                                                      (etaf-reader-open-book session book)
                                                      (etaf-reader-goto-percent session 0))))
           (box :width 'stretch :text-align 'center (text "从头开始")))
         (etaf-button :label (if notes
                                 (format "导出笔记（%d 条）" (length notes))
                               "导出笔记")
                      :variant 'ghost :width 'stretch
                      :on-press (lambda ()
                                  (etaf-reader-guard
                                   session
                                   (lambda ()
                                     (etaf-reader--export-book-interactive session book))))
           (box :width 'stretch :text-align 'center
             (text (expr (if notes
                             (format "导出笔记（%d 条）" (length notes))
                           "导出笔记"))))))))))

(defconst etaf-reader--detail-note-limit 3
  "How many annotations the detail panel previews.")

(defun etaf-reader--view-detail-notes (session theme)
  "Return SESSION's annotation preview for the shelf cursor's book."
  (let ((notes (etaf-reader--read session :shelf-notes)))
    (when notes
      (etaf-view
       (column :width 'stretch :item-gap '(lh 0)
         (flex :width 'stretch :height '(lh 1) :align-items 'center
               :border-top (etaf-reader--line theme :line)
           (text :font-weight 'bold :color (etaf-reader-color :dim theme) "标注")
           (box :flex-grow 1)
           (text :color (etaf-reader-color :dim theme)
                 (expr (format "%d 条" (length notes)))))
         (expr (mapcar (lambda (row) (etaf-reader--view-detail-note theme row))
                       (seq-take notes etaf-reader--detail-note-limit)))
         (expr (when (> (length notes) etaf-reader--detail-note-limit)
                 (etaf-view
                  (text :color (etaf-reader-color :dim theme)
                        (expr (format "还有 %d 条"
                                      (- (length notes)
                                         etaf-reader--detail-note-limit))))))))))))

(defun etaf-reader--view-detail-note (theme row)
  "Return one annotation ROW of the detail panel as a quote line."
  (let* ((kind (or (plist-get row :kind) "highlight"))
         (color (etaf-reader--color-key (plist-get row :color)))
         (quote-str (etaf-reader--single-line (plist-get row :quote)))
         (note-str (etaf-reader--single-line (plist-get row :note)))
         (text (cond ((not (string-empty-p note-str))
                      (if (equal kind "note")
                          (format "想法：%s" note-str)
                        (if (string-empty-p quote-str) note-str quote-str)))
                     ((not (string-empty-p quote-str)) quote-str)
                     (t (format "第 %d 章的一处标记"
                                (1+ (or (plist-get row :chapter) 0))))))
         (glyph (pcase kind
                  ("highlight" "▌")
                  ("underline" "─")
                  ("wavy" "~")
                  ("note" "▪")
                  (_ "·"))))
    (etaf-view
     (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
       (text :color (etaf-reader-color color theme) (expr glyph))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :overflow 'hidden :wrap-mode 'none
         (text :color (etaf-reader-color :muted theme)
               (expr (etaf-reader--clip text 30))))))))

(defun etaf-reader--view-detail-row (theme label value)
  "Return one LABEL and VALUE row of the detail panel."
  (etaf-view
   (flex :width 'stretch :height '(lh 1) :align-items 'center
         :gap '((lh 0) (ch 1))
     (box :width '(ch 8) :flex-shrink 0
          (text :color (etaf-reader-color :dim theme) (expr label)))
     (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
          :overflow 'hidden :wrap-mode 'none
          (text (expr (etaf-reader--clip value 24)))))))

(defun etaf-reader--file-size (bytes)
  "Return BYTES as a short human readable size."
  (cond ((null bytes) "—")
        ((>= bytes (* 1024 1024)) (format "%.1f MB" (/ bytes 1048576.0)))
        ((>= bytes 1024) (format "%d KB" (/ bytes 1024)))
        (t (format "%d B" bytes))))

;;; Whole shelf

(defun etaf-reader--view-shelf (session)
  "Return SESSION's shelf: sidebar, grid/list, detail panel.
The grid reflows with the window, and the detail panel is the preview of the
shelf cursor; pressing a cover selects it, pressing it again opens the book."
  (let* ((theme (etaf-reader--read session :theme))
         (page (etaf-reader-library-page session))
         (items (plist-get page :items))
         (grid (etaf-reader--shelf-grid session))
         (columns (max 1 (plist-get grid :columns)))
         (cover-rows (or (plist-get grid :cover-rows) etaf-reader--cover-rows))
         (facets (etaf-reader--library-facets session))
         (sidebar (plist-get grid :sidebar-shown))
         (width (or (let ((shown (etaf-reader--read session :window-columns)))
                      (and shown (> shown 0) shown))
                    160))
         (detail (and (etaf-reader--read session :detail) (>= width 130)))
         (list-p (eq (etaf-reader--read session :shelf-view) 'list))
         (main-columns (max 24 (- width (if sidebar 26 0) (if detail 38 0) 4)))
         (book (or (let ((id (etaf-reader--read session :shelf-cursor)))
                     (when id (seq-find (lambda (row) (equal id (plist-get row :id))) items)))
                   (car items))))
    (etaf-view
     (flex :flex-direction 'row :width 'stretch :height 'stretch
           :background-color (etaf-reader-color :bg theme)
           :color (etaf-reader-color :ink theme)
           :gap '((lh 0) (ch 0))
       (expr (when sidebar (etaf-reader--view-shelf-sidebar session theme facets)))
       (flex :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
             :height 'stretch :overflow 'hidden :gap '((lh 0) (ch 0))
             :keys etaf-reader--wheel-keys
         (expr (etaf-reader--view-shelf-toolbar session theme page width))
         (expr (etaf-reader--view-shelf-chips session theme width))
         (flex :flex-direction 'column :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
               :overflow 'hidden
               :padding (cond (list-p '((lh 1) (ch 2)))
                              ((< width 92) '((lh 0) (ch 1)))
                              (t '((lh 0) (ch 2))))
               :gap '((lh 1) (ch 0))
           (etaf-empty :if (null items)
                       :title (if (and (string-empty-p (etaf-reader--read session :shelf-query))
                                       (null (etaf-reader--read session :facet-format))
                                       (null (etaf-reader--read session :facet-author))
                                       (eq (etaf-reader--read session :filter) 'all))
                                  "书架是空的" "没有找到这本书")
                       :description (if (or (etaf-reader--read session :facet-format)
                                            (etaf-reader--read session :facet-author)
                                            (not (eq (etaf-reader--read session :filter) 'all)))
                                        "换个筛选条件，或按 清除筛选 回到全部书籍"
                                      "把电子书放进 ~/ebooks 后扫描，或换个书名、作者试试"))
           (expr (when items
                   (if list-p
                       (etaf-reader--view-shelf-list session theme items main-columns)
                     (cl-loop for row in (etaf-reader--shelf-groups items columns)
                              for row-idx from 0
                              collect (etaf-reader--view-shelf-row
                                       session theme row cover-rows row-idx))))))
         (expr (etaf-reader--view-shelf-footer session theme page book width)))
       (expr (when (and detail book)
               (etaf-reader--view-detail session theme book)))))))

;;; ---------------------------------------------------------------------------
;;; Navigation and settings panes
;;; ---------------------------------------------------------------------------

(defun etaf-reader--view-settings (session)
  "Return catalog controls for SESSION's persisted reading preferences."
  (let* ((metrics (etaf-reader--read session :metrics))
         (col-val (if (plist-get metrics :manual)
                      (or (plist-get metrics :requested-columns)
                          (plist-get metrics :columns))
                    'auto))
         (col-options (let ((base '((auto . "自适应")
                                    (32 . "窄 32")
                                    (40 . "标准 40")
                                    (48 . "宽 48"))))
                        (if (assq col-val base)
                            base
                          (append base (list (cons col-val (format "%d 列" col-val))))))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 1)
       (etaf-select :label "外观" :presentation 'chips
                    :value (etaf-reader--read session :theme)
                    :options '((dark . "夜间") (light . "明亮") (sepia . "纸色"))
                    :on-change (lambda (value) (etaf-reader-configure session :theme value)))
       (etaf-select :label "阅读" :presentation 'chips
                    :value (etaf-reader--read session :mode)
                    :options '((page . "翻页") (scroll . "滚动"))
                    :on-change (lambda (value) (etaf-reader-configure session :mode value)))
       (etaf-select :label "段落" :presentation 'chips
                    :value (etaf-reader--read session :density)
                    :options '((comfortable . "舒适") (compact . "紧凑"))
                    :on-change (lambda (value) (etaf-reader-configure session :density value)))
       (etaf-select :label "栏宽" :presentation 'chips
                    :value col-val
                    :options col-options
                    :on-change (lambda (value) (etaf-reader-configure session :columns value)))
       (text "设置会自动保存；调整窗口或切换侧栏后保持原来的阅读位置。")))))

(defun etaf-reader--view-pane (session)
  "Return a compact, navigable dialog for SESSION's current pane."
  (let* ((pane (etaf-reader--read session :pane))
         (metrics (etaf-reader--read session :metrics))
         (win-cols (or (etaf-reader--read session :window-columns) 80))
         (width (if (eq (plist-get metrics :layout) 'narrow)
                    (max 28 (min (- win-cols 4) (+ 2 (plist-get metrics :columns))))
                  (min 62 (max 44 (- win-cols 8)))))
         (close (lambda () (etaf-reader--write session :pane nil))))
    (when pane
      (pcase pane
        ('settings
         (etaf-view
          (etaf-dialog :open t :title "阅读设置" :width (list 'ch width)
                       :close-label "关闭" :compact t :on-close close
            (expr (etaf-reader--view-settings session)))))
        (_
         (let* ((items (etaf-reader--pane-items session))
                (size (etaf-reader--pane-page-size session))
                (pages (max 1 (ceiling (length items) size)))
                (page (min (1- pages) (etaf-reader--read session :pane-page)))
                (visible (seq-subseq items (* page size)
                                     (min (length items) (* (1+ page) size))))
                (cur-ch (and (eq pane 'toc)
                             (plist-get (etaf-reader--read session :chapter) :index)))
                (selected (when (and cur-ch
                                     (seq-some (lambda (row)
                                                 (equal (plist-get row :key) cur-ch))
                                               visible))
                            cur-ch))
                (bookmarks (and (eq pane 'bookmarks)
                                (etaf-reader--read session :bookmarks))))
           (etaf-view
            (etaf-dialog :open t :width (list 'ch width)
                         :close-label "关闭" :compact t :on-close close
                         :title (pcase pane ('toc "目录") ('notes "笔记与划线")
                                       ('bookmarks "书签") (_ "搜索结果"))
              (column :width 'stretch :item-gap '(lh 1)
                (etaf-empty :if (null items) :title "这里还没有内容"
                            :description "阅读时可以添加书签、划线，或搜索全书。")
                (etaf-list :if (not (null visible))
                           :items visible
                           :selected selected
                           :on-select (lambda (key)
                                        (etaf-reader--choose-pane-item session key)))
                (etaf-button :if (and (eq pane 'notes) items)
                             :label "导出 Markdown" :variant 'ghost
                             :on-press
                             (lambda ()
                               (let ((file (etaf-call-with-input
                                            (lambda ()
                                              (read-file-name "导出笔记到：" nil nil nil "阅读笔记.md")))))
                                 (etaf-reader-export-notes session file))))
                (etaf-menu :if bookmarks :label "删除书签"
                           :items (cl-loop for row in bookmarks
                                           for index from 1
                                           collect (list :key (plist-get row :id)
                                                         :label (format "%d. %s" index
                                                                        (etaf-reader--clip
                                                                         (etaf-reader--single-line
                                                                          (or (plist-get row :label) ""))
                                                                         36))))
                           :on-select
                           (lambda (id)
                             (etaf-reader-store-delete-bookmark id)
                             (etaf-reader--write session :bookmarks
                                                 (etaf-reader-store-bookmarks
                                                  (plist-get (etaf-reader--read session :book) :id)))))
                (flex :if (> (length items) 0)
                      :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
                  (etaf-button :label "上一页" :variant 'ghost :disabled (= page 0)
                               :on-press (lambda () (etaf-reader--step-pane session -1)))
                  (text (expr (format "%d / %d · %d 项" (1+ page) pages (length items))))
                  (etaf-button :label "下一页" :variant 'ghost :disabled (= (1+ page) pages)
                               :on-press (lambda () (etaf-reader--step-pane session 1)))))))))))))

;;; ---------------------------------------------------------------------------
;;; Whole application
;;; ---------------------------------------------------------------------------

(defun etaf-reader-view (session)
  "Return the View of SESSION."
  ;; Track the repaint trigger: commands that cannot use the retained fast
  ;; path bump it to force an ordinary publication.
  (etaf-reader--read session :revision)
  (let ((view (etaf-reader--read session :view)))
    (etaf-node
     'box
     (list :width 'stretch :height 'stretch :overflow 'hidden
           :aria-label "电子书阅读器"
           :help '("书库扫描本地电子书；进度、书签、划线和阅读设置保存在本地数据库。"
                   "选择文字后可标注或添加想法；标注跟随章节与文字位置，窗口重排不改变锚点。"
                   "目录、笔记、书签与搜索结果支持分页，跳转后可返回原阅读位置。")
           :background-color (etaf-reader-color :bg (etaf-reader--read session :theme)))
     (delq nil
           (if (eq view 'reader)
               (list (etaf-reader--view-reader session)
                     (etaf-reader--view-toolbar session)
                     (etaf-reader--view-pane session))
             (list (etaf-reader--view-shelf session)
                   (etaf-reader--view-pane session)))))))

(provide 'etaf-reader-views)
;;; etaf-reader-views.el ends here
