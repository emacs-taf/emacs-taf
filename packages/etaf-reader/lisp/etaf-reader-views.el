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
;; The selection toolbar is an `etaf-popover' anchored to the line node the
;; selection starts on, which is the WeChat Reading interaction adapted to a
;; keyboard text application: drag or `v' selects, the toolbar floats above or
;; below the line.

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
(declare-function etaf-reader-refresh-library "etaf-reader-model" (session))
(declare-function etaf-reader-open-book "etaf-reader-model" (session book &optional parser))

(defun etaf-reader--color-key (color)
  "Return COLOR (a string like \"red\") as a palette keyword."
  (intern (format ":%s" color)))

(defun etaf-reader--fill-key (color)
  "Return the soft fill keyword of annotation COLOR."
  (intern (format ":%s-soft" color)))

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
        (let ((position (max 0 (min (1- (max 1 length))
                                    (or (plist-get cursor :char) 0)))))
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
                                   ((equal kind "note") :accent)))
                 (decoration-style (cond ((equal kind "wavy") 'wavy)
                                         ((equal kind "note") 'dotted)))
                 (segment (list :text (substring text from to)
                                :bold (string-match-p "bold" style)
                                :italic (string-match-p "italic" style)
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
      (let ((text (copy-sequence (plist-get segment :text))) face)
        (when (or (eq kind 'heading) (plist-get segment :bold))
          (setq face (plist-put face :weight 'bold)))
        (when (plist-get segment :italic)
          (setq face (plist-put face :slant 'italic)))
        (when-let* ((fill (plist-get segment :fill)))
          (setq face (plist-put face :background (etaf-reader-color fill theme))))
        (when-let* ((color (or (plist-get segment :color)
                              (and (eq kind 'hr) :dim))))
          (setq face (plist-put face :foreground (etaf-reader-color color theme))))
        (when-let* ((decoration (plist-get segment :decoration)))
          (setq face
                (plist-put face :underline
                           (list :color (etaf-reader-color decoration theme)
                                 :style (pcase (plist-get segment :decoration-style)
                                          ('wavy 'wave) ('dotted 'dots) (_ 'line))))))
        (when face (put-text-property 0 (length text) 'face face text))
        (when-let* ((annotation (plist-get segment :annotation)))
          (add-text-properties 0 (length text)
                               (list 'reader-annotation (plist-get annotation :id)
                                     'help-echo "点击查看或编辑标注") text))
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
      (let* ((columns (min 40 (max 16 (or (plist-get (etaf-reader--read session :metrics)
                                                     :columns)
                                          40))))
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
                       (max 1 (min 24 (round (/ (* columns char-width (cdr pixels))
                                                (* (car pixels) char-height)))))
                     8)))
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

;;; ---------------------------------------------------------------------------
;;; Selection toolbar
;;; ---------------------------------------------------------------------------

(defun etaf-reader--toolbar-line (session)
  "Return the toolbar's line index, or nil."
  (let ((toolbar (etaf-reader--read session :toolbar)))
    (and toolbar (plist-get toolbar :line))))

(defun etaf-reader--toolbar-button (label color help on-press)
  "Return one ghost button of the annotation toolbar."
  (etaf-view
   (etaf-button :label label :variant 'ghost :pointer 'hand
                :color color :help-echo help :on-press on-press)))

(defun etaf-reader--view-toolbar (session)
  "Return the selection toolbar popover, or nil."
  (let* ((toolbar (etaf-reader--read session :toolbar))
         (theme (etaf-reader--read session :theme)))
    (when toolbar
      (let* ((line (plist-get toolbar :line))
             (top (etaf-reader--read session :line))
             (metrics (etaf-reader--read session :metrics))
             (rows (max 1 (or (plist-get metrics :rows) 20)))
             (page-size (* rows (or (plist-get metrics :spread) 1)))
             (annotation (plist-get toolbar :annotation))
             (closing (lambda () (etaf-reader--write session :toolbar nil)))
             (mark
              (lambda (kind color)
                (etaf-reader-guard
                 session
                 (lambda ()
                   (if annotation
                       (etaf-reader-mark-annotation session (plist-get annotation :id)
                                                    kind color)
                     (etaf-reader-annotate session kind color))
                   (funcall closing)))))
             (choose-color
              (lambda (color)
                (funcall mark (if annotation
                                  (or (plist-get annotation :kind) "highlight")
                                "highlight")
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
                   (etaf-reader-annotation-delete session (plist-get annotation :id)))))))
        (when (and (>= line top) (< (- line top) page-size))
          (etaf-view
           (etaf-popover
               :open t
               :anchor (format "reader-line-%d" (- line top))
               :placement (if (< (% (- line top) rows) (/ rows 2)) 'bottom-start 'top-start)
               :width '(ch 46)
               :on-close closing
             (column :width 'stretch :item-gap '(lh 0) :padding '((lh 0) (ch 1))
               (flex :width 'stretch :align-items 'center :height '(lh 2)
                 (expr (mapcar
                        (lambda (color)
                          (etaf-reader--toolbar-button
                           "●"
                           (etaf-reader-color (etaf-reader--color-key color) theme)
                           (format "用 %s 色标注" color)
                           (lambda () (funcall choose-color color))))
                        (etaf-reader-annotation-color-keys))))
               (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
                     :height '(lh 2)
                 (expr (etaf-reader--toolbar-button
                        "高亮" (etaf-reader-color :ink theme) "高亮显示"
                        (lambda ()
                          (funcall mark "highlight"
                                   (or (and annotation (plist-get annotation :color))
                                       "yellow")))))
                 (expr (etaf-reader--toolbar-button
                        "直线" (etaf-reader-color :ink theme) "直线下划线"
                        (lambda ()
                          (funcall mark "underline"
                                   (or (and annotation (plist-get annotation :color))
                                       "blue")))))
                 (expr (etaf-reader--toolbar-button
                        "波浪" (etaf-reader-color :ink theme) "波浪下划线"
                        (lambda ()
                          (funcall mark "wavy"
                                   (or (and annotation (plist-get annotation :color))
                                       "red"))))))
               (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
                     :height '(lh 2)
                 (expr (etaf-reader--toolbar-button
                        "复制" (etaf-reader-color :ink theme) "复制选中文字" copy))
                 (expr (etaf-reader--toolbar-button
                        "写想法" (etaf-reader-color :ink theme) "为这段写想法" note))
                 (expr (etaf-reader--toolbar-button
                        "搜索" (etaf-reader-color :ink theme) "在本书中搜索" search))
                 (expr (etaf-reader--toolbar-button
                        "删除" (etaf-reader-color :red theme) "删除这条标注" remove)))))))))))

;;; ---------------------------------------------------------------------------
;;; Reader
;;; ---------------------------------------------------------------------------

(defun etaf-reader--column-slices (lines rows spread)
  "Divide LINES into SPREAD columns of ROWS lines each (column-major)."
  (cl-loop for column from 0 below (max 1 spread)
           for from = (* column (max 1 rows))
           for to = (min (length lines) (+ from (max 1 rows)))
           when (< from to)
           collect (seq-subseq lines from to)))

(defun etaf-reader--view-reader-sidebar (session theme chapter rows)
  "Return SESSION's reading sidebar: the book card, chapters and progress.
ROWS bounds how many chapter entries fit under the card."
  (let* ((book (etaf-reader--read session :book))
         (chapters (etaf-reader--read session :chapters))
         (title (or (plist-get book :title) "未命名"))
         (author (or (plist-get book :author) "未知作者"))
         (total (length chapters))
         (index (or (plist-get chapter :index) 0))
         (slots (max 4 (min 14 (- rows 18))))
         (start (max 0 (min (max 0 (- total slots)) (- index (/ slots 2)))))
         (shown (seq-take (nthcdr start chapters) slots))
         (lines (etaf-reader--read session :lines))
         (top (etaf-reader--read session :line))
         (percent (if (> (length lines) 0)
                      (max 0 (min 100 (* 100.0 (/ (float top) (length lines)))))
                    0)))
    (etaf-view
     (column :width (list 'ch 26) :height 'stretch :flex-shrink 0 :overflow 'hidden
             :background-color (etaf-reader-color :sidebar theme)
             :border-right (etaf-reader--line theme :line)
             :padding '((lh 1) (ch 1) (lh 0) (ch 1)) :item-gap '(lh 0)
       (column :width 'stretch :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
         (text :font-weight 'bold (expr (etaf-reader--clip title 21)))
         (text :color (etaf-reader-color :muted theme)
               (expr (etaf-reader--clip (format "%s · %d 章" author total) 21))))
       (box :width 'stretch :height '(lh 1))
       (box :width 'stretch :height '(lh 1)
            :border-bottom (etaf-reader--line theme :line))
       (box :width 'stretch :height '(lh 1))
       (flex :width 'stretch :height '(lh 1) :align-items 'center
         (text :font-weight 'bold :color (etaf-reader-color :dim theme) "目录")
         (box :flex-grow 1)
         (text :color (etaf-reader-color :dim theme)
               (expr (format "%d/%d" (1+ index) total))))
       (expr (cl-loop for row in shown
                      for offset from start
                      collect (etaf-reader--view-reader-chapter
                               session theme row offset (= offset index))))
       (box :flex-grow 1 :height '(lh 1))
       (box :width 'stretch :height '(lh 1)
            :border-bottom (etaf-reader--line theme :line))
       (text :font-weight 'bold :color (etaf-reader-color :dim theme) "阅读进度")
       (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
         (expr (etaf-reader--meter theme percent 16))
         (text :color (etaf-reader-color :muted theme)
               (expr (format "%d%%" (round percent)))))
       (box :width 'stretch :height '(lh 1))
       (etaf-button :label "全部目录" :variant 'ghost :width 'stretch
                    :on-press (lambda () (etaf-reader-show-pane session 'toc)))))))

(defun etaf-reader--view-reader-chapter (session theme row offset current)
  "Return SESSION's sidebar entry for chapter ROW at OFFSET, CURRENT or not."
  (let ((title (or (plist-get row :title) "未命名")))
    (etaf-view
     (etaf-button :variant 'ghost :width 'stretch :height '(lh 1)
                  :padding '((lh 0) (ch 0)) :label "第 %d 章"
                  :aria-label (format "第 %d 章 %s" (1+ offset) title)
                  :aria-selected (and current t)
                  :on-press (lambda () (etaf-reader-open-chapter session offset 0))
       (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
         (box :width '(ch 1) :height '(lh 1)
              (text :color (etaf-reader-color :accent theme)
                    (expr (if current "▌" " "))))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :overflow 'hidden
              (text :font-weight (if current 'bold 'normal)
                    :color (if current (etaf-reader-color :ink theme)
                             (etaf-reader-color :muted theme))
                    (expr (etaf-reader--clip title 19)))))))))

(defun etaf-reader--view-reader (session)
  "Return the reading View of SESSION."
  (let* ((theme (etaf-reader--read session :theme))
         (metrics (etaf-reader--read session :metrics))
         (layout (plist-get metrics :layout))
         (spread (or (plist-get metrics :spread) 1))
         (rows (max 1 (or (plist-get metrics :rows) 20)))
         (columns (max 16 (or (plist-get metrics :columns) 40)))
         (lines (etaf-reader--read session :lines))
         (total (length lines))
         (top (min (etaf-reader--read session :line) (max 0 total)))
         (page-size (* rows spread))
         ;; Slots give every rendered line a stable identity across page
         ;; turns, so Ebox reuses the nodes and only patches their text.
         (remaining (nthcdr top lines))
         (visible (cl-loop for slot below page-size
                           for line = (pop remaining)
                           collect (plist-put (copy-sequence line) :slot slot)))
         (slices (etaf-reader--column-slices visible rows spread))
         (available (- (or (etaf-reader--read session :window-columns) 160)
                       (if (and (etaf-reader--read session :sidebar)
                                (not (eq layout 'narrow)))
                           26 0)))
         (body-columns (+ (* spread (+ columns 5)) (* (1- spread) 2)))
         (body-margin (max 1 (/ (- available body-columns) 2)))
         (chapter (etaf-reader--read session :chapter))
         (book (etaf-reader--read session :book)))
    (etaf-view
     ;; Arrows reach the page wherever point rests, not only inside the body.
     (flex :flex-direction 'row :width 'stretch :height 'stretch
           :on-direction #'etaf-reader--direction
           :background-color (etaf-reader-color :bg theme)
           :color (etaf-reader-color :ink theme) :gap '((lh 0) (ch 0))
       (expr (when (and (etaf-reader--read session :sidebar)
                        (not (eq layout 'narrow)))
               (etaf-reader--view-reader-sidebar session theme chapter rows)))
       (flex :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
             :height 'stretch :gap '((lh 0) (ch 0))
       ;; Running head
       (flex :width 'stretch :height '(lh 3) :flex-shrink 0
             :padding '((lh 0) (ch 2)) :align-items 'center :gap '((lh 0) (ch 1))
             :border-bottom (etaf-reader--line theme :line)
         (etaf-button :label "书库" :variant 'ghost
                      :on-press (lambda () (etaf-reader-show-shelf session)))
         (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                 :item-gap '(lh 0)
           (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
             (text (expr (or (plist-get book :title) ""))))
           (box :height '(lh 1) :overflow 'hidden :color (etaf-reader-color :muted theme)
             (text (expr (format "%s · 第 %d/%d 章"
                                 (or (plist-get chapter :title) "")
                                 (1+ (or (plist-get chapter :index) 0))
                                 (length (etaf-reader--read session :chapters)))))))
         (etaf-button :label "目录" :variant 'ghost
                      :on-press (lambda () (etaf-reader-show-pane session 'toc)))
         (etaf-button :if (not (eq layout 'narrow)) :label "笔记" :variant 'ghost
                      :on-press (lambda () (etaf-reader-show-pane session 'notes)))
         (etaf-button :if (eq layout 'wide) :label "搜索" :variant 'ghost
                      :on-press
                      (lambda ()
                        (let ((query (etaf-call-with-input (lambda () (read-string "搜索全书：")))))
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
                             (:key help :label "快捷键"))
                    :on-select (lambda (key)
                                 (pcase key
                                   ('add-bookmark (etaf-reader-add-bookmark session))
                                   ('back (etaf-reader-jump-back session))
                                   (_ (etaf-reader-show-pane session key))))))
       ;; Body
       (flex :ref 'reader-body :id "reader-body"
             :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
             :min-height '(lh 0) :align-items 'stretch
             :pointer 'text :on-drag (plist-get session :drag-handler)
             :gap (list '(lh 0) (list 'ch 2))
         ;; Fixed margins centre the text block: a growing spacer hands all
         ;; the free space to one side, which put the page against the sidebar.
         (box :width (list 'ch (if (> spread 1) body-margin 0)) :flex-shrink 0)
         (column :for (slice slices) :key (plist-get (car slice) :slot)
                 ;; One cell of slack absorbs sub-cell rounding.
                 :width (list 'ch (+ columns 5)) :flex-shrink 0
                 :item-gap '(lh 0) :padding '((lh 1) (ch 2))
           (expr
            (if (or (etaf-reader--read session :toolbar)
                    (cl-some (lambda (line) (eq (plist-get line :kind) 'img)) slice))
                ;; Line anchors exist only while the nearby toolbar needs one.
                (mapcar (lambda (line)
                          (etaf-reader--view-line session line theme)) slice)
              (let ((id (format "reader-column-%d"
                                (/ (plist-get (car slice) :slot) rows))))
                (etaf-node
                 'box (list :width 'stretch :height (list 'lh rows)
                            :overflow 'hidden :wrap-mode 'none)
                 (list (etaf-node
                        'text (list :ref (intern id) :id id)
                        (list (mapconcat
                               (lambda (line)
                                 (etaf-reader--line-content session line theme))
                               slice "\n")))))))))
         (box :width (list 'ch (if (> spread 1) body-margin 0)) :flex-shrink 0))
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
              :overflow 'hidden :text-align 'center
              :color (etaf-reader-color :dim theme)
           (text (expr (or (etaf-reader--read session :message)
                           (if (eq layout 'wide)
                               "空格 翻页 · v 选择 · s 搜索 · c 目录 · a 笔记 · o 设置"
                             "空格 翻页 · o 设置")))))))))))

;;; ---------------------------------------------------------------------------
;;; Shelf
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Library shell
;;; ---------------------------------------------------------------------------

(defconst etaf-reader--cover-rows 8
  "Text lines a shelf cover occupies.")

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

;;; Sidebar

(defun etaf-reader--view-sidebar-item (theme key label count selected on-press)
  "Return one sidebar row: KEY, LABEL, COUNT and the selected marker."
  (etaf-view
   (etaf-button :key key :variant 'ghost :width 'stretch :padding '((lh 0) (ch 1))
                :label label :aria-selected (and selected t)
                :on-press on-press
     (flex :width 'stretch :height '(lh 1) :align-items 'center
           :gap '((lh 0) (ch 1))
       (box :width '(px 2) :height '(lh 1)
            :background-color (if selected
                                  (etaf-reader-color :accent theme)
                                (etaf-reader-color :sidebar theme)))
       (box :flex-grow 1 :overflow 'hidden
         (text :font-weight (if selected 'bold 'normal)
               :color (if selected (etaf-reader-color :accent-text theme)
                        (etaf-reader-color :ink theme))
               (expr label)))
       (expr (when count
               (etaf-view
                (text :color (if selected (etaf-reader-color :accent-text theme)
                               (etaf-reader-color :dim theme))
                      (expr (number-to-string count))))))))))

(defun etaf-reader--view-sidebar-section (theme title count)
  "Return a sidebar group heading with TITLE and COUNT."
  (etaf-view
   (flex :height '(lh 1) :width 'stretch :align-items 'center
         :padding '((lh 0) (ch 1))
     (box :flex-grow 1 (text :color (etaf-reader-color :dim theme) (expr title)))
     (expr (when count
             (etaf-view
              (text :color (etaf-reader-color :faint theme)
                    (expr (number-to-string count)))))))))

(defun etaf-reader--view-shelf-sidebar (session theme facets)
  "Return SESSION's shelf sidebar with navigation, formats and authors."
  (let* ((filter (etaf-reader--read session :filter))
         (format-facet (etaf-reader--read session :facet-format))
         (author-facet (etaf-reader--read session :facet-author))
         (formats (seq-take (plist-get facets :formats) 5))
         (authors (seq-take (plist-get facets :authors) 6)))
    (etaf-view
     (column :width '(ch 26) :height 'stretch :flex-shrink 0 :overflow 'hidden
             :background-color (etaf-reader-color :sidebar theme)
             :border-right (etaf-reader--line theme :line)
             :item-gap '(lh 0)
             :padding '((lh 1) (ch 1) (lh 1) (ch 1))
       ;; The library header is type and a hairline, not a box: a border at
       ;; this size reads as a button that does nothing.
       (column :width 'stretch :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
         (text :font-weight 'bold (expr "本地书库"))
         (text :color (etaf-reader-color :muted theme)
               (expr (etaf-reader--clip
                      (if (and (listp etaf-reader-library-directories)
                               (cdr etaf-reader-library-directories))
                          "多个目录"
                        (abbreviate-file-name
                         (or (car etaf-reader-library-directories) "~/ebooks")))
                      23))))
       (box :height '(lh 1))
       (box :width 'stretch :height '(lh 1)
            :border-bottom (etaf-reader--line theme :line))
       (box :height '(lh 1))
       (expr (etaf-reader--view-sidebar-item
              theme 'all "全部书籍" (plist-get facets :total)
              (eq filter 'all)
              (lambda () (etaf-reader-filter-library
                          session (etaf-reader--read session :shelf-query) 'all))))
       (expr (etaf-reader--view-sidebar-item
              theme 'reading "在读" (plist-get facets :reading)
              (eq filter 'reading)
              (lambda () (etaf-reader-filter-library
                          session (etaf-reader--read session :shelf-query) 'reading))))
       (expr (etaf-reader--view-sidebar-item
              theme 'unread "未读" (plist-get facets :unread)
              (eq filter 'unread)
              (lambda () (etaf-reader-filter-library
                          session (etaf-reader--read session :shelf-query) 'unread))))
       (expr (etaf-reader--view-sidebar-item
              theme 'finished "已读" (plist-get facets :finished)
              (eq filter 'finished)
              (lambda () (etaf-reader-filter-library
                          session (etaf-reader--read session :shelf-query) 'finished))))
       (box :height '(lh 2))
       (expr (etaf-reader--view-sidebar-section theme "格式" (length formats)))
       (expr (mapcar
              (lambda (row)
                (etaf-reader--view-sidebar-item
                 theme (format "format:%s" (car row)) (car row) (cdr row)
                 (equal (car row) format-facet)
                 (lambda () (etaf-reader-set-facet
                             session 'format
                             (unless (equal (car row) (etaf-reader--read session :facet-format))
                               (car row))))))
              formats))
       (box :height '(lh 2))
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
              authors))
       (box :flex-grow 1)
       (column :item-gap '(lh 0) :width 'stretch
         (box :height '(lh 1) :width 'stretch
              :border-bottom (etaf-reader--line theme :line))
         (etaf-button :label "扫描书库" :variant 'ghost :width 'stretch
                      :padding '((lh 0) (ch 1))
                      :on-press (lambda () (etaf-reader-refresh-library session)))
         (etaf-button :label "阅读设置" :variant 'ghost :width 'stretch
                      :padding '((lh 0) (ch 1))
                      :on-press (lambda () (etaf-reader-show-pane session 'settings))))))))

;;; Toolbar, grid, footer

(defun etaf-reader--view-shelf-chips (session)
  "Return the shelf's facet chips: reading state, format and author."
  (let* ((filter (etaf-reader--read session :filter))
         (format (etaf-reader--read session :facet-format))
         (author (etaf-reader--read session :facet-author))
         (facets (etaf-reader--library-facets session))
         (query (etaf-reader--read session :shelf-query))
         (state-label (pcase filter
                        ('reading "在读") ('unread "未读") ('finished "已读")
                        (_ "全部")))
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
     (flex :height '(lh 1) :width 'stretch :align-items 'center
           :padding '((lh 0) (ch 2)) :gap '((lh 0) (ch 1))
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
        :label (format "作者 · %s" (or author "全部"))
        :items author-items
        :on-select (lambda (key)
                     (etaf-reader-set-facet session 'author
                                            (unless (equal key "all") key))))
       (box :flex-grow 1)
       (expr (when (or format author (not (string-empty-p query)))
               (etaf-view
                (etaf-button :label "清除筛选" :variant 'ghost
                             :on-press (lambda ()
                                         (etaf-reader-set-facet session 'format nil)
                                         (etaf-reader-set-facet session 'author nil)
                                         (etaf-reader-filter-library session "" 'all))))))))))

(defun etaf-reader--view-shelf-toolbar (session theme page)
  "Return SESSION's shelf toolbar for PAGE."
  (etaf-view
   (flex :height '(lh 3) :width 'stretch :align-items 'center
         :padding '((lh 0) (ch 2)) :gap '((lh 0) (ch 1))
     (text :font-weight 'bold (expr (etaf-reader--shelf-title session)))
     (text :color (etaf-reader-color :dim theme)
           (expr (format "%d 本" (plist-get page :total))))
     (box :flex-grow 1)
     (etaf-search-field :if (>= (or (etaf-reader--read session :window-columns) 160) 150)
                        :value (etaf-reader--read session :shelf-query)
                        :placeholder "搜索书名、作者" :width '(ch 24)
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
     (etaf-button :label "详情" :variant 'ghost
                  :aria-selected (and (etaf-reader--read session :detail) t)
                  :on-press (lambda () (etaf-reader--toggle-detail session)))
     (etaf-button :label "扫描书籍" :variant 'primary
                  :on-press (lambda () (etaf-reader-refresh-library session))))))

(defun etaf-reader--view-shelf-cover (session theme book)
  "Return one book standing in the shelf, the way the design lifts a book."
  (let* ((title (or (plist-get book :title) "未命名"))
         (selected (equal (plist-get book :id) (etaf-reader--read session :shelf-cursor)))
         (path (etaf-reader--cover-path book))
         (tint (etaf-reader--cover-tint theme title)))
    (etaf-view
     (etaf-button :key (plist-get book :id) :variant 'ghost :pointer 'hand
                  :width (list 'ch etaf-reader--cover-columns)
                  :height '(lh 9) :padding '((lh 0) (ch 0))
                  :label (format "《%s》" title)
                  :aria-label (format "《%s》，%s" title (or (plist-get book :author) "未知作者"))
                  :help-echo (if selected "再按一次打开这本书" "选中这本书")
                  :on-press (lambda () (etaf-reader-guard
                                        session (lambda () (etaf-reader--press-book session book))))
       (flex :flex-direction 'column :width 'stretch :height '(lh 9) :gap '((lh 0) (ch 0))
             :justify-content (if selected 'flex-start 'flex-end)
         (box :width 'stretch :height (list 'lh etaf-reader--cover-rows)
              :overflow 'hidden :background-color (car tint)
              :border (etaf-reader--line theme :line)
           (expr (when path
                   (etaf-node 'image
                              (list :src path
                                    :columns etaf-reader--cover-columns
                                    :rows etaf-reader--cover-rows)
                              nil)))
           (expr (unless path
                   (etaf-view
                    (flex :flex-direction 'column :width 'stretch
                          :height (list 'lh etaf-reader--cover-rows)
                          :overflow 'hidden :justify-content 'flex-end
                          :padding '((lh 1) (ch 1))
                      (text :font-weight 'bold :color (cdr tint) (expr title))))))))))))

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

(defun etaf-reader--view-shelf-progress (session theme book)
  "Return BOOK's reading meter: a three pixel line under its cover."
  (etaf-view
   (expr (etaf-reader--meter theme (etaf-reader--book-percent session book)
                            etaf-reader--cover-columns))))

(defun etaf-reader--view-shelf-label (session theme book)
  "Return BOOK's title and author under the shelf board."
  (let* ((selected (equal (plist-get book :id) (etaf-reader--read session :shelf-cursor)))
         (title (or (plist-get book :title) "未命名")))
    (etaf-view
     (column :width (list 'ch etaf-reader--cover-columns) :height '(lh 2)
             :item-gap '(lh 0) :overflow 'hidden
       (box :height '(lh 1) :overflow 'hidden
         (text :font-weight (if selected 'bold 'normal)
               :color (if selected (etaf-reader-color :accent-text theme)
                        (etaf-reader-color :ink theme))
               (expr title)))
       (box :height '(lh 1) :overflow 'hidden
         (text :color (etaf-reader-color :dim theme)
               (expr (or (plist-get book :author) "未知作者"))))))))

(defun etaf-reader--view-shelf-board (session theme books)
  "Return the board the shelf's books stand on, with the selected marker."
  (etaf-view
   (flex :width 'stretch :height '(lh 1) :align-items 'stretch
     (expr (mapcar
            (lambda (book)
              (let ((selected (equal (plist-get book :id)
                                     (etaf-reader--read session :shelf-cursor))))
                (etaf-view
                 (box :width (list 'ch (+ etaf-reader--cover-columns etaf-reader--cell-gap))
                      :height '(lh 1)
                      :background-color (etaf-reader-color :plank-face theme)
                      :border-top (etaf-reader--line theme :plank-top)
                      :border-bottom (etaf-reader--line theme :plank-edge)
                   (expr (when selected
                           (etaf-view
                            (box :width '(ch 4) :height '(lh 1)
                                 :margin-left '(ch 4)
                                 :border-bottom (list '(px 1) 'solid
                                                      (etaf-reader-color :accent theme))))))))))
            books))
     (box :flex-grow 1 :height '(lh 1)
          :background-color (etaf-reader-color :plank-face theme)
          :border-top (etaf-reader--line theme :plank-top)
          :border-bottom (etaf-reader--line theme :plank-edge)))))

(defun etaf-reader--view-shelf-row (session theme books)
  "Return one shelf of BOOKS: covers, meters, board and labels."
  (etaf-view
   (column :width 'stretch :item-gap '(lh 0)
     (flex :width 'stretch :height '(lh 9) :align-items 'flex-end
           :gap (list '(lh 0) (list 'ch etaf-reader--cell-gap))
       (expr (mapcar (lambda (book) (etaf-reader--view-shelf-cover session theme book)) books)))
     (flex :width 'stretch :height '(lh 1)
           :gap (list '(lh 0) (list 'ch etaf-reader--cell-gap))
       (expr (mapcar (lambda (book) (etaf-reader--view-shelf-progress session theme book))
                     books)))
     (expr (etaf-reader--view-shelf-board session theme books))
     (flex :width 'stretch :height '(lh 2)
           :gap (list '(lh 0) (list 'ch etaf-reader--cell-gap))
       (expr (mapcar (lambda (book) (etaf-reader--view-shelf-label session theme book))
                     books))))))

(defun etaf-reader--clip (string cells)
  "Return STRING clipped to CELLS character cells, ending in an ellipsis."
  (truncate-string-to-width (or string "") cells nil nil "…"))

(defun etaf-reader--view-shelf-list-header (theme)
  "Return the list view's column headings."
  (etaf-view
   (flex :height '(lh 1) :width 'stretch :align-items 'center
         :gap '((lh 0) (ch 1)) :padding '((lh 0) (px 2) (lh 0) (px 2))
     (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
          (text :color (etaf-reader-color :dim theme) "标题"))
     (box :width '(ch 14) :flex-shrink 0
          (text :color (etaf-reader-color :dim theme) "作者"))
     (box :width '(ch 5) :flex-shrink 0
          (text :color (etaf-reader-color :dim theme) "格式"))
     (box :width '(ch 7) :flex-shrink 0 :text-align 'right
          (text :color (etaf-reader-color :dim theme) "章节"))
     (box :width '(ch 15) :flex-shrink 0
          (text :color (etaf-reader-color :dim theme) "进度"))
     (box :width '(ch 14) :flex-shrink 0 :text-align 'right
          (text :color (etaf-reader-color :dim theme) "最近阅读")))))

(defun etaf-reader--view-shelf-list-row (session theme book &optional title-columns)
  "Return one line of the list view for BOOK, TITLE-COLUMNS wide."
  (let* ((id (plist-get book :id))
         (title (or (plist-get book :title) "未命名"))
         (selected (equal id (etaf-reader--read session :shelf-cursor)))
         (percent (max 0 (min 100 (etaf-reader--book-percent session book))))
         (format (upcase (or (plist-get book :format) "")))
         (colors (etaf-reader-format-colors format theme))
         (state (etaf-reader-book-state session id))
         (opened (plist-get state :last_read)))
    (etaf-view
     (etaf-button :key id :variant 'ghost :width 'stretch :height '(lh 1)
                  :padding '((lh 0) (ch 0)) :label "打开这本书"
                  :aria-label (format "《%s》，%s" title
                                      (or (plist-get book :author) "未知作者"))
                  :aria-selected (and selected t)
                  :on-press (lambda () (etaf-reader-guard
                                        session (lambda () (etaf-reader--press-book session book))))
       (flex :width 'stretch :height '(lh 1) :align-items 'center
             :gap '((lh 0) (ch 1)) :padding '((lh 0) (px 2) (lh 0) (px 2))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :overflow 'hidden
              (text :font-weight (if selected 'bold 'normal)
                    :color (if selected (etaf-reader-color :ink theme)
                             (etaf-reader-color :muted theme))
                    (expr (etaf-reader--clip title (max 8 (or title-columns 40))))))
         (box :width '(ch 14) :flex-shrink 0 :overflow 'hidden
              (text :color (etaf-reader-color :muted theme)
                    (expr (etaf-reader--clip (or (plist-get book :author) "未知作者")
                                             14))))
         (box :width '(ch 5) :flex-shrink 0 (text :color (car colors) (expr format)))
         (box :width '(ch 7) :flex-shrink 0 :text-align 'right
              (text :color (etaf-reader-color :dim theme)
                    (expr (let ((chapters (plist-get book :chapters)))
                            (if (and chapters (> chapters 0))
                                (format "%d 章" chapters) "—")))))
         (flex :width '(ch 15) :flex-shrink 0 :height '(lh 1) :align-items 'center
               :gap '((lh 0) (ch 1))
           (expr (etaf-reader--meter theme percent 8))
           (box :width '(ch 4) :flex-shrink 0 :text-align 'right
                (text :color (etaf-reader-color :dim theme)
                      (expr (if (> percent 0) (format "%d%%" (round percent)) "未读")))))
         (box :width '(ch 14) :flex-shrink 0 :text-align 'right
              (text :color (etaf-reader-color :dim theme)
                    (expr (if (and opened (> opened 0))
                              (format-time-string "%m-%d %H:%M" (seconds-to-time opened))
                            "—")))))))))

(defun etaf-reader--view-shelf-list (session theme items &optional title-columns)
  "Return the list view of ITEMS, with TITLE-COLUMNS for each title."
  (etaf-view
   (column :width 'stretch :item-gap '(lh 0)
     (expr (etaf-reader--view-shelf-list-header theme))
     (box :width 'stretch :height '(lh 1)
          :border-bottom (etaf-reader--line theme :line))
     (column :width 'stretch :item-gap '(lh 0)
       (expr (mapcar (lambda (book)
                       (etaf-reader--view-shelf-list-row session theme book title-columns))
                     items))))))

(defun etaf-reader--shelf-groups (items columns)
  "Split ITEMS into rows of COLUMNS books."
  (let (rows)
    (while items
      (push (seq-take items columns) rows)
      (setq items (nthcdr columns items)))
    (nreverse rows)))

(defun etaf-reader--view-shelf-footer (session theme page)
  "Return SESSION's shelf footer for PAGE."
  (etaf-view
   (flex :height '(lh 3) :width 'stretch :align-items 'center
         :padding '((lh 0) (ch 2))
         :border-top (etaf-reader--line theme :line)
     (etaf-button :label "上一页" :variant 'ghost
                  :disabled (= (plist-get page :index) 0)
                  :on-press (lambda () (etaf-reader-page-library session -1)))
     (text :color (etaf-reader-color :muted theme)
           (expr (format "第 %d / %d 页" (1+ (plist-get page :index))
                         (plist-get page :pages))))
     (etaf-button :label "下一页" :variant 'ghost
                  :disabled (= (1+ (plist-get page :index)) (plist-get page :pages))
                  :on-press (lambda () (etaf-reader-page-library session 1)))
     (box :flex-grow 1)
     (text :color (etaf-reader-color :dim theme)
           (expr (format "共 %d 本" (plist-get page :total)))))))

;;; Detail panel

(defun etaf-reader--view-detail (session theme book)
  "Return SESSION's detail panel for BOOK."
  (let* ((title (or (plist-get book :title) "未命名"))
         (percent (etaf-reader--book-percent session book))
         (format (upcase (or (plist-get book :format) "")))
         (colors (etaf-reader-format-colors format theme))
         (path (etaf-reader--cover-path book))
         (tint (etaf-reader--cover-tint theme title))
         (chapters (plist-get book :chapters))
         (pages (plist-get book :pages))
         (size (plist-get book :size)))
    (etaf-view
     (column :width '(ch 38) :height 'stretch :flex-shrink 0 :overflow 'hidden
             :background-color (etaf-reader-color :panel theme)
             :border-left (etaf-reader--line theme :line)
             :padding '((lh 1) (ch 2) (lh 1) (ch 2)) :item-gap '(lh 1)
       (flex :flex-direction 'column :width 'stretch :height '(lh 14)
             :justify-content 'center :align-items 'center :gap '((lh 0) (ch 0))
             :background-color (etaf-reader-color :subtle theme)
         (box :width '(ch 18) :height '(lh 12) :overflow 'hidden
              :border (etaf-reader--line theme :line)
              :background-color (car tint)
           (expr (when path
                   (etaf-node 'image (list :src path :columns 18 :rows 12) nil)))
           (expr (unless path
                   (etaf-view
                    (flex :flex-direction 'column :width 'stretch :height 'stretch
                          :overflow 'hidden :justify-content 'center :align-items 'stretch
                          :wrap-mode 'word :padding '((lh 1) (ch 1))
                      (box :width 'stretch :text-align 'center
                        (text :font-weight 'bold :color (cdr tint) (expr title)))))))))
       (box :width 'stretch :text-align 'center :overflow 'hidden
         (text :font-weight 'bold (expr title)))
       (box :width 'stretch :text-align 'center :overflow 'hidden
         (text :color (etaf-reader-color :muted theme)
               (expr (or (plist-get book :author) "未知作者"))))
       (box :width 'stretch :text-align 'center
         (text :color (etaf-reader-color :dim theme)
               (expr (if (> percent 0) (format "已读 %d%%" (round percent)) "未读"))))
       (box :width 'stretch :height '(lh 1) :border-bottom (etaf-reader--line theme :line))
       (text :font-weight 'bold :color (etaf-reader-color :dim theme) "详情")
       (expr (etaf-reader--view-detail-row theme "格式" format))
       (expr (etaf-reader--view-detail-row
              theme "页数" (if (and pages (> pages 0)) (format "%d 页" pages) "未分页")))
       (expr (etaf-reader--view-detail-row
              theme "章节" (if (and chapters (> chapters 0)) (format "%d 章" chapters) "—")))
       (expr (etaf-reader--view-detail-row theme "大小" (etaf-reader--file-size size)))
       (box :width 'stretch :height '(lh 1) :border-bottom (etaf-reader--line theme :line))
       (text :font-weight 'bold :color (etaf-reader-color :dim theme) "文件")
       (flex :width 'stretch :height '(lh 1) :align-items 'center
             :gap '((lh 0) (ch 1))
         (box :width '(ch 6) :flex-shrink 0 :height '(lh 1) :text-align 'center
              :background-color (cdr colors)
           (text :color (car colors) (expr format)))
         (box :flex-grow 1 :overflow 'hidden
           (text (expr (file-name-nondirectory (or (plist-get book :path) ""))))))
       (expr (etaf-reader--view-detail-notes session theme))
       (box :flex-grow 1)
       (etaf-button :label (if (> percent 0) "继续阅读" "开始阅读") :variant 'primary
                    :width 'stretch
                    :on-press (lambda () (etaf-reader-guard
                                          session (lambda () (etaf-reader-open-book session book)))))
       (etaf-button :label "从头开始" :variant 'secondary :width 'stretch
                    :on-press (lambda () (etaf-reader-guard
                                          session (lambda ()
                                                    (etaf-reader-open-book session book)
                                                    (etaf-reader-goto-percent session 0)))))
       (etaf-button :label "导出笔记" :variant 'ghost :width 'stretch
                    :on-press (lambda () (etaf-reader-export-command)))))))

(defconst etaf-reader--detail-note-limit 3
  "How many annotations the detail panel previews.")

(defun etaf-reader--view-detail-notes (session theme)
  "Return SESSION's annotation preview for the shelf cursor's book."
  (let ((notes (etaf-reader--read session :shelf-notes)))
    (when notes
      (etaf-view
       (column :width 'stretch :item-gap '(lh 0)
         (box :width 'stretch :height '(lh 1)
              :border-bottom (etaf-reader--line theme :line))
         (flex :width 'stretch :height '(lh 1) :align-items 'center
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
  (let* ((kind (plist-get row :kind))
         (text (or (let ((quote (plist-get row :quote))
                         (note (plist-get row :note)))
                     (cond ((and quote (not (string-empty-p quote))) quote)
                           ((and note (not (string-empty-p note))) note)))
                   (format "第 %d 章的一处标记" (1+ (or (plist-get row :chapter) 0)))))
         (glyph (pcase kind ('highlight "▌") ('note "▪") (_ "·"))))
    (etaf-view
     (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
       (text :color (pcase kind ('highlight (etaf-reader-color :accent theme))
                      ('note (etaf-reader-color :accent-text theme))
                      (_ (etaf-reader-color :muted theme)))
             (expr glyph))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :overflow 'hidden
         (text :color (etaf-reader-color :muted theme)
               (expr (etaf-reader--clip
                      (replace-regexp-in-string "[\n\r\t ]+" " " text) 30))))))))

(defun etaf-reader--view-detail-row (theme label value)
  "Return one LABEL and VALUE row of the detail panel."
  (etaf-view
   (flex :width 'stretch :height '(lh 1) :align-items 'center
         :gap '((lh 0) (ch 1))
     (box :width '(ch 8) (text :color (etaf-reader-color :dim theme) (expr label)))
     (box :flex-grow 1 :overflow 'hidden (text (expr value))))))

(defun etaf-reader--file-size (bytes)
  "Return BYTES as a short human readable size."
  (cond ((null bytes) "—")
        ((>= bytes (* 1024 1024)) (format "%.1f MB" (/ bytes 1048576.0)))
        ((>= bytes 1024) (format "%d KB" (/ bytes 1024)))
        (t (format "%d B" bytes))))

;;; Whole shelf

(defun etaf-reader--view-shelf (session)
  "Return SESSION's shelf: sidebar, grid, detail panel.
The grid reflows with the window, and the detail panel is the preview of the
shelf cursor; pressing a cover selects it, pressing it again opens the book."
  (let* ((theme (etaf-reader--read session :theme))
         (page (etaf-reader-library-page session))
         (items (plist-get page :items))
         (grid (etaf-reader--shelf-grid session))
         (columns (max 1 (plist-get grid :columns)))
         (facets (etaf-reader--library-facets session))
         (sidebar (etaf-reader--read session :sidebar))
         (width (or (let ((shown (etaf-reader--read session :window-columns)))
                      (and shown (> shown 0) shown))
                    160))
         (detail (and (etaf-reader--read session :detail) (>= width 130)))
         ;; The middle column is sized from the window instead of growing:
         ;; a long list row would otherwise widen it past the detail panel.
         (main-columns (max 24 (- width (if sidebar 26 0) (if detail 38 0))))
         ;; The grid area spans the window minus the toolbar, the chips and the
         ;; footer, so the footer stays at the bottom on every height.
         (grid-rows (max 4 (- (or (etaf-reader--read session :window-rows) 24) 7)))
         (book (or (let ((id (etaf-reader--read session :shelf-cursor)))
                     (when id (seq-find (lambda (row) (equal id (plist-get row :id))) items)))
                   (car items))))
    (etaf-view
     (flex :flex-direction 'row :width 'stretch :height 'stretch
           :background-color (etaf-reader-color :bg theme)
           :color (etaf-reader-color :ink theme)
           :gap '((lh 0) (ch 0))
       (expr (when sidebar (etaf-reader--view-shelf-sidebar session theme facets)))
       (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
               :height 'stretch :item-gap '(lh 0) :overflow 'hidden
         (expr (etaf-reader--view-shelf-toolbar session theme page))
         (expr (etaf-reader--view-shelf-chips session))
         (column :height (list 'lh grid-rows) :flex-shrink 0 :overflow 'hidden
                 :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
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
           (expr (if (eq (etaf-reader--read session :shelf-view) 'list)
                     (etaf-reader--view-shelf-list
                      session theme items (max 8 (- main-columns 72)))
                   (mapcar (lambda (row) (etaf-reader--view-shelf-row session theme row))
                           (etaf-reader--shelf-groups items columns)))))
         (expr (etaf-reader--view-shelf-footer session theme page)))
       (expr (when (and detail book)
               (etaf-reader--view-detail session theme book)))))))

;;; ---------------------------------------------------------------------------
;;; Navigation and settings panes
;;; ---------------------------------------------------------------------------

(defun etaf-reader--view-settings (session)
  "Return catalog controls for SESSION's persisted reading preferences."
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
     (etaf-menu :label "阅读栏宽"
                :items '((:key auto :label "自适应窗口") (:key 32 :label "窄栏")
                         (:key 40 :label "标准") (:key 48 :label "宽栏"))
                :on-select (lambda (value) (etaf-reader-configure session :columns value)))
     (text "设置会自动保存；调整窗口后继续原来的阅读位置。"))))

(defun etaf-reader--view-pane (session)
  "Return a bounded, navigable dialog for SESSION's current pane."
  (let* ((pane (etaf-reader--read session :pane))
         (metrics (etaf-reader--read session :metrics))
         (width (if (eq (plist-get metrics :layout) 'narrow)
                    (max 28 (+ 2 (plist-get metrics :columns))) 60))
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
                                    (min (length items) (* (1+ page) size)))))
           (etaf-view
            (etaf-dialog :open t :width (list 'ch width)
                         :height (list 'lh (+ 8 (* size 3)
                                             (if (memq pane '(notes bookmarks)) 3 0)))
                         :close-label "关闭" :compact t :on-close close
                         :title (pcase pane ('toc "目录") ('notes "笔记与划线")
                                       ('bookmarks "书签") (_ "搜索结果"))
              (column :width 'stretch :item-gap '(lh 1)
                (etaf-empty :if (null items) :title "这里还没有内容"
                            :description "阅读时可以添加书签、划线，或搜索全书。")
                (etaf-list :items visible
                           :on-select (lambda (key)
                                        (etaf-reader--choose-pane-item session key)))
                (etaf-button :if (eq pane 'notes) :label "导出 Markdown" :variant 'ghost
                             :on-press
                             (lambda ()
                               (let ((file (etaf-call-with-input
                                            (lambda ()
                                              (read-file-name "导出笔记到：" nil nil nil "阅读笔记.md")))))
                                 (etaf-reader-export-notes session file))))
                (etaf-menu :if (eq pane 'bookmarks) :label "删除书签"
                           :items (cl-loop for row in (etaf-reader--read session :bookmarks)
                                           for index from 1
                                           collect (list :key (plist-get row :id)
                                                         :label (format "%d. %s" index
                                                                        (truncate-string-to-width
                                                                         (or (plist-get row :label) "") 36 nil nil "…"))))
                           :on-select
                           (lambda (id)
                             (etaf-reader-store-delete-bookmark id)
                             (etaf-reader--write session :bookmarks
                                                 (etaf-reader-store-bookmarks
                                                  (plist-get (etaf-reader--read session :book) :id)))))
                (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
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
