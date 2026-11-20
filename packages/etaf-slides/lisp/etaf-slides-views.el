;;; etaf-slides-views.el --- Views for etaf-slides -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentation only.  Every function here turns session values into ETAF
;; nodes: no buffer, no timer, no storage and no network.  Colors come from the
;; session's palette through `etaf-slides-color', so one layout serves both
;; appearances.
;;
;; The stage is an aspect-preserving 16:9 surface centered in the window; the
;; slide body is rendered by the shared `etaf-ui' markdown renderer, so tables,
;; lists, quotes and code blocks follow the catalog instead of a second
;; implementation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'image)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-slides-theme)
(require 'etaf-slides-model)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function browse-url "browse-url" (url &rest args))

(defconst etaf-slides-keys
  '(("SPC" etaf-slides-next-slide "下一页")
    ("n" etaf-slides-next-slide "下一页")
    ("DEL" etaf-slides-previous-slide "上一页")
    ("p" etaf-slides-previous-slide "上一页")
    ("RET" etaf-slides-next-slide "下一页")
    ("o" etaf-slides-toggle-overview "幻灯片总览")
    ("t" etaf-slides-next-theme "切换主题")
    ("s" etaf-slides-toggle-notes "演讲者备注")
    ("c" etaf-slides-toggle-clock "演示计时")
    ("f" etaf-slides-toggle-fullscreen "整屏")
    ("g" etaf-slides-first-slide "第一页")
    ("G" etaf-slides-last-slide "最后一页")
    ("#" etaf-slides-goto-slide "跳到第 N 页")
    ("+" etaf-slides-zoom-in "放大字号")
    ("-" etaf-slides-zoom-out "缩小字号")
    ("0" etaf-slides-zoom-reset "还原字号")
    ("e" etaf-slides-edit-source "编辑源码")
    ("q" etaf-slides-close "关闭"))
  "Keys of the slide application, as the root Host declares them.
The help view reads these labels, so every entry carries a Chinese one.")

;;; Palette and geometry helpers

(defun etaf-slides--c (palette key)
  "Return PALETTE's color for KEY."
  (etaf-slides-color palette key))

(defun etaf-slides--geometry (session)
  "Return SESSION's stage geometry for the current viewport and metrics."
  (let* ((viewport (etaf-slides--read session :viewport))
         (metrics (etaf-display-metrics))
         (char-width (plist-get metrics :char-width))
         (line-height (plist-get metrics :line-height)))
    (etaf-slides-stage (car viewport) (cdr viewport) char-width line-height)))

(defun etaf-slides--inset (geometry)
  "Return the horizontal stage inset in columns for GEOMETRY."
  (max 2 (min 6 (floor (plist-get geometry :columns) 24))))

(defun etaf-slides--content-columns (geometry)
  "Return the columns available to slide content for GEOMETRY."
  (max 8 (- (plist-get geometry :columns) (* 2 (etaf-slides--inset geometry)))))

(defun etaf-slides--hairline (palette &optional columns)
  "Return a hairline rule in PALETTE, COLUMNS wide when given.
The rule is the bottom border of a one-row box: an Ebox box takes row units
only, so a border on a reserved row is how a hairline stays inside the budget."
  (etaf-node 'box
             (append (list :height '(lh 1)
                           :border-bottom (list '(px 1) 'solid
                                                (etaf-slides--c palette :border)))
                     (when columns (list :width (list 'ch columns))))
             nil))

;;; Slide body

(defun etaf-slides--markdown-env (palette columns)
  "Return the markdown rendering environment for PALETTE and COLUMNS."
  (list :palette (mapcar (lambda (pair)
                           (cons (car pair) (etaf-slides--c palette (car pair))))
                         '((:ink) (:muted) (:faint) (:heading) (:accent)
                           (:accent-soft) (:panel) (:code-bg) (:border)
                           (:quote-bg) (:quote-bar) (:table-header)
                           (:table-stripe) (:heading-rule) (:ok) (:ok-soft)
                           (:warn) (:warn-soft) (:danger) (:danger-soft)
                           (:important) (:important-soft)))
        :render-media (lambda (kind node env)
                        (etaf-slides--media kind node env palette columns))
        :open-link (lambda (url) (browse-url url))))

(defun etaf-slides--media (kind node _env palette columns)
  "Return the view of media KIND NODE in PALETTE, at most COLUMNS wide.
A local image is drawn through ETAF's image Host when its pixel size is known;
anything else becomes a labeled card, so a missing file never breaks a slide."
  (let* ((url (plist-get node :url))
         (caption (or (plist-get node :alt) url))
         (path (and url (not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" url))
                    (expand-file-name url)))
         (size (and path (file-readable-p path)
                    (ignore-errors (image-size (create-image path nil nil) t))))
         (metrics (ignore-errors (etaf-display-metrics)))
         (cell-width (max 1 (or (plist-get metrics :char-width) 8)))
         (cell-height (max 1 (or (plist-get metrics :line-height) 17)))
         (width (max 12 (min (- columns 4) 56)))
         (rows (if size
                   (min 18 (max 3 (round (/ (* width cell-width (cdr size))
                                            (* (car size) cell-height 1.0)))))
                 6)))
    (if (and size (eq kind 'image))
        (etaf-node 'image (list :src path :columns width :rows rows) nil)
      (etaf-node 'column (list :width (list 'ch width) :item-gap '(lh 0))
                 (list (etaf-node 'box
                                  (list :width 'stretch
                                        :height (list 'lh 1)
                                        :padding (list '(lh 0) (list 'ch 1))
                                        :background-color (etaf-slides--c palette :panel)
                                        :border (list '(px 1) 'solid
                                                      (etaf-slides--c palette :border)))
                                  (list (etaf-node 'text
                                                   (list :color (etaf-slides--c palette :muted))
                                                   (list (format "图片：%s" caption)))))
                       (etaf-node 'box (list :height (list 'lh (1- rows))) nil))))))

;;; Slide layouts

(defun etaf-slides--title-band (slide palette)
  "Return the title band of SLIDE in PALETTE."
  (etaf-node 'column (list :width 'stretch :item-gap '(lh 0))
             (list (etaf-node 'box
                              (list :width 'stretch :height '(lh 1)
                                    :wrap-mode 'none :overflow 'hidden)
                              (list (etaf-node 'text
                                               (list :color (etaf-slides--c palette :ink)
                                                     :font-weight 'bold)
                                               (list (plist-get slide :title)))))
                   (etaf-node 'box (list :height '(lh 1)) nil))))

(defun etaf-slides--content (slide palette geometry)
  "Return the content layout of SLIDE in PALETTE for GEOMETRY."
  (let* ((columns (etaf-slides--content-columns geometry))
         (body-rows (max 1 (- (plist-get geometry :body-rows) 2))))
    (etaf-node 'column (list :width 'stretch)
               (list (etaf-slides--title-band slide palette)
                     (etaf-node 'box
                                (list :width 'stretch
                                      :height (list 'lh body-rows)
                                      :overflow 'hidden)
                                (list (etaf-node 'column
                                                 (list :width 'stretch :item-gap '(lh 0))
                                                 (etaf-ui-markdown-view-blocks
                                                  (plist-get slide :blocks)
                                                  (etaf-slides--markdown-env
                                                   palette columns)))))))))

(defun etaf-slides--centered (slide palette geometry)
  "Return the centered title layout of SLIDE in PALETTE for GEOMETRY."
  (let* ((rows (plist-get geometry :rows))
         (subtitle (etaf-slides--blocks-text (plist-get slide :blocks))))
    (etaf-node 'flex
               (list :flex-direction 'column
                     :width 'stretch
                     :height (list 'lh (max 4 (- rows 4)))
                     :justify-content 'center :align-items 'center
                     :row-gap '(lh 0))
               (append
                (list (etaf-node 'box (list :height '(lh 1)) nil)
                      (etaf-node 'box
                                 (list :width 'stretch :wrap-mode 'word
                                       :text-align 'center)
                                 (list (etaf-node 'text
                                                  (list :color (etaf-slides--c palette :ink)
                                                        :font-weight 'bold)
                                                  (list (plist-get slide :title)))))
                      (etaf-node 'box (list :height '(lh 1)) nil))
                (when (and subtitle (not (string-empty-p subtitle)))
                  (list (etaf-node 'box
                                   (list :width 'stretch :wrap-mode 'word
                                         :text-align 'center)
                                   (list (etaf-node 'text
                                                    (list :color (etaf-slides--c palette :muted))
                                                    (list subtitle))))))))))

(defun etaf-slides--stage (session palette geometry)
  "Return the stage of SESSION in PALETTE for GEOMETRY."
  (let* ((slide (etaf-slides-current session))
         (columns (plist-get geometry :columns))
         (rows (plist-get geometry :rows))
         (inset (etaf-slides--inset geometry)))
    (etaf-node 'box
               (list :key (plist-get slide :index)
                     :width (list 'ch columns)
                     :height (list 'lh rows)
                     :background-color (etaf-slides--c palette :surface)
                     :border (list '(px 1) 'solid (etaf-slides--c palette :border))
                     :padding (list '(lh 2) (list 'ch inset))
                     :overflow 'hidden)
               (list (if (memq (plist-get slide :layout) '(cover section))
                         (etaf-slides--centered slide palette geometry)
                       (etaf-slides--content slide palette geometry))))))

;;; Shell

(defun etaf-slides--footer (session palette geometry)
  "Return the footer of SESSION in PALETTE for GEOMETRY."
  (let* ((columns (plist-get geometry :columns))
         (index (etaf-slides--read session :index))
         (count (length (plist-get session :slides)))
         (slide (etaf-slides-current session))
         (left (format "%s · %d / %d%s"
                       (plist-get session :title)
                       (1+ index) count
                       (if (plist-get slide :notes-p) " · 备注" "")))
         (clock (etaf-slides--read session :clock)))
    (etaf-node 'flex
               (list :flex-direction 'row
                     :width (list 'ch columns) :height '(lh 1)
                     :padding (list '(lh 0) (list 'ch (etaf-slides--inset geometry)))
                     :justify-content 'space-between :align-items 'center)
               (list (etaf-node 'text
                                (list :color (etaf-slides--c palette :muted))
                                (list left))
                     (etaf-node 'text
                                (list :color (etaf-slides--c palette :faint))
                                (list (or clock "")))))))

(defun etaf-slides--notes-band (session palette geometry)
  "Return the speaker notes band of SESSION in PALETTE for GEOMETRY."
  (let* ((columns (plist-get geometry :columns))
         (inset (etaf-slides--inset geometry))
         (slide (etaf-slides-current session))
         (notes (or (plist-get slide :notes) "这一页没有备注")))
    (etaf-node 'column
               (list :width (list 'ch columns)
                     :padding (list '(lh 0) (list 'ch inset))
                     :item-gap '(lh 0))
               (list (etaf-slides--hairline palette)
                     (etaf-node 'box
                                (list :width 'stretch :height '(lh 1)
                                      :wrap-mode 'none :overflow 'hidden)
                                (list (etaf-node 'text
                                                 (list :color (etaf-slides--c palette :muted))
                                                 (list (format "备注：%s" notes)))))))))

(defun etaf-slides--overview-row (session slide index current palette overflow)
  "Return the overview row of SLIDE at INDEX in PALETTE.
CURRENT is the displayed index and OVERFLOW the indices that do not fit the
stage.  A row paints its own selection and hover, so the selected row keeps one
presentation and never stacks a hover fill on top of it.  The row is one text
line built from runs: an inner flex container would be taller than the row and
would shift the text against its own highlight."
  (let* ((selected (eq index current))
         (meta (string-join
                (delq nil
                      (list (and (plist-get slide :notes-p) "备注")
                            (and (memq index overflow) "内容可能超出")))
                " · ")))
    (etaf-node 'box
               (list :key index
                     :width 'stretch :height '(lh 1)
                     :padding (list '(lh 0) (list 'ch 1))
                     :wrap-mode 'none :overflow 'hidden
                     :role 'button :tab-index 0
                     :aria-label (plist-get slide :title)
                     :border-left (if selected
                                      (list '(px 3) 'solid (etaf-slides--c palette :accent))
                                    (list '(px 3) 'solid (etaf-slides--c palette :bg)))
                     :background-color (unless selected
                                         (etaf-slides--c palette :bg))
                     :color (if selected
                                (etaf-slides--c palette :ink)
                              (etaf-slides--c palette :muted))
                     :hover-style (unless selected
                                    (list :background-color
                                          (etaf-slides--c palette :panel)))
                     :on-press (lambda () (etaf-slides-show session index)))
               (list (etaf-node 'text
                                (list :color (if selected
                                                 (etaf-slides--c palette :accent)
                                               (etaf-slides--c palette :faint)))
                                (list (format "%02d  " (1+ index))))
                     (etaf-node 'text
                                (list :color (if selected
                                                 (etaf-slides--c palette :ink)
                                               (etaf-slides--c palette :muted)))
                                (list (plist-get slide :title)))
                     (etaf-node 'text
                                (list :color (etaf-slides--c palette :faint))
                                (list (if (string-empty-p meta)
                                          ""
                                        (concat "   " meta))))))))

(defun etaf-slides--overview (session palette geometry)
  "Return the slide overview of SESSION in PALETTE for GEOMETRY."
  (let* ((slides (plist-get session :slides))
         (index (etaf-slides--read session :index))
         (overflow (etaf-slides--overflow session geometry))
         (width (min 96 (plist-get geometry :columns)))
         (head (etaf-node 'flex
                          (list :flex-direction 'row :width 'stretch
                                :justify-content 'space-between)
                          (list (etaf-node 'text
                                           (list :color (etaf-slides--c palette :ink)
                                                 :font-weight 'bold)
                                           (list (format "全部幻灯片 · %d" (length slides))))
                                (etaf-node 'text
                                           (list :color (etaf-slides--c palette :faint))
                                           (list "RET 放映 · o 返回")))))
         (rows (cl-loop for slide in slides
                        for each from 0
                        collect (etaf-slides--overview-row
                                 session slide each index palette overflow))))
    (etaf-node 'column
               (list :width 'stretch
                     :padding (list '(lh 1) (list 'ch 3))
                     :item-gap '(lh 0))
               (list head
                     (etaf-node 'box (list :height '(lh 1)) nil)
                     (etaf-node 'column
                                (list :width (list 'ch width) :item-gap '(lh 0))
                                rows)))))

(defun etaf-slides--overflow (session geometry)
  "Return the indices of SESSION's slides that do not fit GEOMETRY."
  (cl-loop for slide in (plist-get session :slides)
           for index from 0
           when (> (etaf-slides-lines slide (plist-get geometry :columns))
                   (plist-get geometry :body-rows))
           collect index))

(defun etaf-slides--frame (session palette)
  "Return the whole application of SESSION in PALETTE."
  (let* ((geometry (etaf-slides--geometry session))
         (mode (etaf-slides--read session :mode))
         (notes (etaf-slides--read session :notes)))
    (etaf-node 'flex
               (list :flex-direction 'column :align-items 'center
                     :width 'stretch :height 'stretch
                     :background-color (etaf-slides--c palette :bg)
                     :color (etaf-slides--c palette :ink)
                     :keys etaf-slides-keys)
               (if (eq mode 'overview)
                   (list (etaf-slides--overview session palette geometry))
                 (append
                  (list (etaf-node 'box (list :flex-grow 1 :flex-basis '(px 0)
                                              :min-height '(lh 0))
                                   nil)
                        (etaf-slides--stage session palette geometry)
                        (etaf-node 'box (list :height '(lh 1)) nil))
                  (when notes
                    (list (etaf-slides--notes-band session palette geometry)
                          (etaf-node 'box (list :height '(lh 1)) nil)))
                  (list (etaf-node 'column
                                   (list :width 'stretch :cross-align 'center)
                                   (list (etaf-slides--footer session palette geometry)))
                        (etaf-node 'box (list :height '(lh 1)) nil)))))))

(provide 'etaf-slides-views)
;;; etaf-slides-views.el ends here
