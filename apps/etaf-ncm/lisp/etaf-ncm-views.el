;;; etaf-ncm-views.el --- Views of the NetEase Cloud Music player -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentation layer of etaf-ncm.  The Components here are internal: they take
;; plain values and callbacks, and never read the player model themselves.  The
;; public `etaf-ncm-app' Component owns that boundary, so a repaint happens in
;; exactly one place and these Views stay independently renderable.
;;
;; Only ETAF hosts and etaf-ui Components are used, and every color comes from
;; `etaf-ncm-color' so both palettes share one layout.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'image)
(declare-function image-size "image.c" (spec &optional pixels frame))
(require 'etaf)
(require 'etaf-ui)
(require 'ebox)
(require 'etaf-ncm-theme)
(require 'etaf-ncm-model)

(etaf-ui-icon-set-register
 'ncm-nav
 '(:kind font :family "monospace" :height 1.0
   ;; The sidebar marks are Han characters: a terminal draws CJK at one exact
   ;; width in its own font, so the category column shares size and alignment.
   :glyphs ((star . "荐") (radio . "台") (heart . "心") (list . "单")
            (disc . "碟") (account . "人") (chart . "榜") (mic . "筒")
            (clock . "近"))
   :fallback ((star . "*") (radio . "~") (heart . "<3") (list . "=")
              (disc . "o") (account . "u") (chart . "=") (mic . "!") (clock . "c"))))

(declare-function etaf-ncm--view-entries "etaf-ncm-app" (model))

;;; ---------------------------------------------------------------------------
;;; Shared geometry
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm--sidebar-width (list 'ch etaf-ncm-layout-sidebar-columns)
  "Width of the library sidebar.")

(defconst etaf-ncm--rail-width (list 'ch etaf-ncm-layout-rail-columns)
  "Width of the glyph-only library rail of a compact layout.")

(defconst etaf-ncm--aside-width (list 'ch etaf-ncm-layout-aside-columns)
  "Width of the lyrics and queue panel.")

(defun etaf-ncm--view-border (_side color)
  "Return the border value of SIDE drawn with COLOR."
  (list '(px 1) 'solid color))

(defun etaf-ncm--hover-surface ()
  "Return the hover declarations of a clickable row.
Ebox hover styles accept colours only, so this is the surface a pointer moves
over, one step above the panel it sits on."
  (list :background-color (etaf-ncm-color :panel2)))

(defun etaf-ncm--view-duration (milliseconds)
  "Return MILLISECONDS as \"M:SS\", or an empty string."
  (etaf-ncm--format-duration milliseconds))

(defun etaf-ncm--lyric-window (lines index size)
  "Return (START . VISIBLE) for a window of SIZE LINES around INDEX."
  (let* ((total (length lines))
         (size (max 0 (min size total)))
         (start (max 0 (min (- index (/ size 3)) (- total size)))))
    (cons start (seq-subseq lines start (+ start size)))))

(defun etaf-ncm--translation-for (trans seconds)
  "Return the translation of SECONDS from TRANS, or nil."
  (cdr (cl-assoc seconds trans :test #'=)))

;;; ---------------------------------------------------------------------------
;;; Primitive Views
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-nav-item
    (&key icon label section entry-key badge on-press chip compact width tight help)
  "Render one library entry, retaining its active paint across navigation.
CHIP renders the glyph-only strip entry of the narrow layout, COMPACT the icon
rail of the medium one.  WIDTH is the chip width in columns.  TIGHT drops the
spacer line so a height-constrained sidebar shows every entry."
  :bindings ((active (etaf-computed (lambda () (eq (etaf-value section) entry-key)))))
  :view
  (flex :width (if chip (list 'ch (or width 5)) 'stretch)
        :height (if (or chip tight) '(lh 1) '(lh 2)) :flex-direction 'column
        :role 'button :tab-index 0
        :aria-current (etaf-value active)
        :aria-label (or help label "音乐库")
        :help-echo (or help label "音乐库")
        :on-press on-press
        ;; The row is a keyboard stop of the sidebar's focus group; RET opens
        ;; the library the focused row names, as a click does.
        :keys (and on-press (list (list "RET" on-press "打开")))
    ;; A callbackless button here would block the cell's inherited keymap.
    (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center
          :justify-content (if (or chip compact) 'center 'start)
          :padding (cond ((and chip width (= width 5)) '((lh 0) (ch 1)))
                         (chip '((lh 0) (ch 0)))
                         (compact '((lh 0) (ch 0)))
                         (t '((lh 0) (ch 2))))
          :hover-style (unless (etaf-value active) (etaf-ncm--hover-surface))
          :background-color (if (etaf-value active) (etaf-ncm-color :accent-soft)
                              (etaf-ncm-color :panel))
          :color (if (etaf-value active) (etaf-ncm-color :ink) (etaf-ncm-color :muted))
          :font-weight 'normal
      (etaf-ui-toggle-icon :value active :off (or icon 'music) :on (or icon 'music)
                           :set (if (display-graphic-p) 'svg 'ncm-nav)
                           :size 1.0 :min-width (if (display-graphic-p) 3 2)
                           :color (etaf-ncm-color :muted)
                           :on-color (etaf-ncm-color :accent))
      (box :if (and (not chip) (not compact)) :flex-grow 1 :flex-basis '(px 0)
           :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-weight 'normal
        (text (expr (or label ""))))
      (box :if (and (not chip) (not compact) badge) :width '(ch 5) :height '(lh 1)
           :text-align 'right
           :font-weight 'normal :color (etaf-ncm-color :dim)
        (text (expr badge))))
    (box :if (not (or chip compact tight)) :height '(lh 1))))

(etaf-define-component etaf-ncm--view-row
    (&key offset row playing selection variant press on-action)
  "Render library ROW number INDEX with content-driven text only.
The selection and playing highlight live on the list's overlay bars, so this
row has no paint bindings to repaint a whole plane.  ROW and PLAYING may be
retained reactive sources; the row reads them inside its Host text bindings,
so a list reply updates prepared values instead of rebuilding the row.
VARIANT selects the columns the layout can afford (see
`etaf-ncm-layout-row-variant'): the name never leaves, `compact' folds the
artist into the name cell, `tiny' drops the badge as well.  PRESS is called
with INDEX when the row is clicked, and ON-ACTION with INDEX plus the action
key (`download' or `queue') of the inline action the reader pressed."
  :bindings ((play-glyph (car (etaf-ui-icon-lines 'play :set 'svg :size 1.0
                                                  :color (etaf-ncm-color :accent))))
             (downloaded (etaf-computed
                          (lambda () (plist-get (etaf-ncm--reactive-text row) :downloaded))))
             (index (etaf-computed
                     (lambda () (or (plist-get (etaf-ncm--reactive-text row) :display-index) 0)))))
  :view
  ;; The list container is the keyboard stop; a row stays a click target.
  (grid :z-index 0
        :width 'stretch :height '(lh 1) :role 'option
        :visibility (if (etaf-ncm--reactive-text row) 'visible 'hidden)
        :grid-template-columns (etaf-ncm-layout-row-columns variant)
        :gap '((lh 0) (ch 1)) :align-items 'center :padding '((lh 0) (ch 1))
        ;; The selection and playing highlight are painted by the list's two
        ;; overlay bars.  The row keeps only content-driven changes, so a
        ;; marker move does not repaint the whole list plane.
        :color (etaf-ncm-color :ink)
        ;; The playing bar behind the row is its own surface, so hover must not
        ;; repaint it; the read stays inside this host binding.
        :hover-style (unless (etaf-ncm--active-value playing)
                       (etaf-ncm--hover-surface))
        :help-echo "播放这一行"
        :on-press (lambda () (when (etaf-ncm--reactive-text row)
                               (funcall press (etaf-ncm--active-value index))))
    (box :width (if (eq variant 'tiny) '(ch 2) '(ch 3)) :height '(lh 1)
         :justify-self 'end
         :color (etaf-ncm-color :dim)
      ;; Both states belong to the same retained text Host. A hidden absolute
      ;; overlay has no initial composition target and poisons the fast cohort.
      (text (expr (let ((active (etaf-ncm--active-value playing))
                        (number (etaf-ncm--active-value index)))
                    (if active play-glyph (format "%2s" number))))))
    (box :height '(lh 1) :overflow 'hidden
      ;; A compact row folds the artist into the name cell instead of
      ;; squeezing the name away: the library row must stay identifiable.
      (text (expr (let* ((data (etaf-ncm--reactive-text row))
                         (title (or (and data (plist-get data :name)) ""))
                         (artist (or (and data (plist-get data :subtitle)) "")))
                    (if (and (memq variant '(compact tiny))
                             (not (string-empty-p artist)))
                        (concat title
                                (propertize (format " · %s" artist)
                                            'face (list :foreground (etaf-ncm-color :dim))))
                      title)))))
    (box :if (memq variant '(full regular)) :height '(lh 1) :overflow 'hidden
         :font-weight 'normal
         :color (etaf-ncm-color :muted)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :subtitle) ""))))
    (box :if (eq variant 'full) :height '(lh 1) :overflow 'hidden :font-weight 'normal
         :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :meta) ""))))
    (box :if (not (eq variant 'tiny)) :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (etaf-ncm-color :gold)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :badge) ""))))
    (box :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :right) ""))))
    (box :height '(lh 1) :justify-self 'center :min-width '(ch 2)
      ;; The download button doubles as the local-library marker: a registered
      ;; song shows a check and stays clickable to refresh the file.  The SVG
      ;; icon keeps the row at one line height.
      (etaf-ui-toggle-icon :value downloaded :off 'download :on 'check
                           :set 'svg :size 1.0 :min-width 2
                           :color (etaf-ncm-color :dim)
                           :on-color (etaf-ncm-color :accent)
                           :help-echo "下载到本地（勾号表示已下载，点击可重新下载）"
                           :tab-index -1
                           :on-press (lambda () (when (etaf-ncm--reactive-text row)
                                                  (funcall on-action (etaf-ncm--active-value index) 'download)))))
    (box :if (eq variant 'full) :height '(lh 1) :justify-self 'center :min-width '(ch 2)
      (etaf-ui-icon :name 'plus :set 'svg :size 1.0 :min-width 2
                    :color (etaf-ncm-color :dim)
                    :help-echo "加入队列" :tab-index -1
                    :on-press (lambda () (when (etaf-ncm--reactive-text row)
                                           (funcall on-action (etaf-ncm--active-value index) 'queue)))))))

(etaf-define-component etaf-ncm--view-note (&key text)
  "Render TEXT as a quiet placeholder filling the content area.
TEXT may be a retained reactive source, so the note updates as prepared text."
  :view
  (box :width 'stretch :height '(lh 6) :text-align 'center
       :color (etaf-ncm-color :dim)
    (text (expr (or (etaf-ncm--reactive-text text) "")))))

(defun etaf-ncm--cover-size (file)
  "Return FILE's (WIDTH . HEIGHT) pixels, or nil when it cannot be read."
  (let ((head (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally file nil 0 16)
                (buffer-string))))
    (ignore-errors
      (let ((image (create-image file (image-type-from-data head) nil)))
        (and image (image-size image t))))))

(defun etaf-ncm--cover-grid (file chars lines)
  "Return the (COLS . ROWS) cell grid for FILE inside a CHARS x LINES cover.
The grid keeps FILE's aspect ratio; Ebox scales the raster to it, so both
dimensions stay cell-aligned and every row is fully covered."
  (let* ((size (etaf-ncm--cover-size file))
         (metrics (etaf-ncm--display-metrics))
         (cell-w (max 1 (plist-get metrics :char-width)))
         ;; A terminal cell is about twice as tall as it is wide, and the text
         ;; image adapter draws two vertical pixels per row with half blocks.
         (cell-h (max 1 (if (display-graphic-p)
                            (plist-get metrics :line-height)
                          2)))
         (image-w (max 1 (or (car-safe size) 1)))
         (image-h (max 1 (or (cdr-safe size) 1)))
         (cols (max 1 (round (/ (* (float lines) cell-h image-w)
                                (* (float image-h) cell-w)))))
         (rows lines))
    (when (> cols chars)
      (setq cols chars
            rows (max 1 (min lines (round (/ (* (float chars) cell-w image-h)
                                              (* (float image-w) cell-h)))))))
    (cons cols rows)))

(etaf-define-component etaf-ncm--view-cover
    (&key size glyph height file (chars 10) (lines 7))
  "Render FILE's album art, or a square placeholder of SIZE characters.
FILE is a reactive source or a literal path; CHARS and LINES bound the area
the art may use.  A usable raster sizes the cover box exactly, so the art
fills it without an empty band above or below.  Without art the box keeps the
standard square cover shape (HEIGHT overrides it), so a cover that is still
downloading does not change the panel height when it arrives."
  :render
  (let* ((value (and file (if (or (etaf-ref-p file) (etaf-computed-p file))
                              (etaf-value file)
                            file)))
         (grid (and (stringp value) (file-readable-p value)
                    (etaf-ncm--cover-grid value chars lines)))
         (square-rows (max 1 (round (/ (* chars (plist-get (etaf-ncm--display-metrics)
                                                          :char-width))
                                       (max 1 (plist-get (etaf-ncm--display-metrics)
                                                         :line-height))))))
         (box-width (if grid (list 'ch (car grid)) size))
         (box-height (cond (grid (list 'lh (cdr grid)))
                           (height height)
                           (t (list 'lh square-rows)))))
    (etaf-view
     (flex :flex-direction 'column :width box-width :height box-height
           :bgcolor (etaf-ncm-color :panel3)
           :align-items 'center :justify-content 'center
       (image :if grid :key value :src value :columns (car grid) :rows (cdr grid))
       (etaf-ui-icon :if (and (not grid) (not glyph)) :name 'music :set 'svg
                     :size 1.0 :min-width 2 :color (etaf-ncm-color :accent))
       (text :if (and (not grid) glyph) :height '(lh 1) :text-align 'center
             (expr glyph))))))

(etaf-define-component etaf-ncm--view-sidebar
    (&key model groups compact height on-locate on-login)
  "Render the library sidebar with MODEL's current SECTION highlighted.
COMPACT renders the glyph-only rail a medium layout has room for.  A HEIGHT
that cannot hold the two-line entries switches the sidebar to a tight
one-line-per-entry form, so every library stays visible in short frames.
The account row is a status line, not a coloured square: the account icon
and the nickname carry the login state, and pressing the row starts the
sign-in when there is no account.  The component reads the session sources
itself, so a library switch repaints the sidebar instead of the whole
application."
  :render
  (let* ((section (etaf-ncm--ref model :section))
         (account (etaf-ncm--read model :account))
         (nick (and account (or (plist-get account :nick) "已登录")))
         (vip (and account (etaf-ncm--truthy-string-p (plist-get account :vip))))
         (rows (and (eq (car-safe height) 'lh) (numberp (cadr height)) (cadr height)))
         (entries (apply #'append (mapcar #'cdr groups)))
         (tight (and rows
                     (< rows (+ 2 (* 2 (length entries))
                                (* 3 (1- (length groups))))))))
    (etaf-view
  (flex :position 'absolute :left '(px 0) :top '(lh 0)
        :flex-direction 'column :focus-group 'vertical
        :width (if compact etaf-ncm--rail-width etaf-ncm--sidebar-width)
        :height height
        :padding '((lh 1) (ch 1)) :gap '((lh 0) (ch 0))
        :background-color (etaf-ncm-color :panel)
        :border-right (etaf-ncm--view-border 'right (etaf-ncm-color :line))
    (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center
          :justify-content (if compact 'center 'start)
          :padding (if compact '((lh 0) (ch 0)) '((lh 0) (ch 1)))
      (etaf-ui-icon :name 'music :set 'svg :size 1.0 :min-width 2
                    :color (etaf-ncm-color :accent))
      (box :if (not compact) :height '(lh 1)
        (text :font-weight 'bold "网易云音乐")))
    (column :for (group groups) :key (car group) :width 'stretch :item-gap '(lh 0)
      ;; A group reads as a section: a blank line, a small bold label, one more
      ;; blank line and then its entries, so the label cannot be mistaken for
      ;; the first entry.
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1))
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1)
           :padding '((lh 0) (ch 2)) :font-size etaf-ncm-font-meta :font-weight 'bold
           :color (etaf-ncm-color :muted)
        (text (expr (format "%s" (car group)))))
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1))
      (etaf-ncm--view-nav-item :for (entry (cdr group)) :key (car entry)
        :icon (nth 2 entry)
        :label (if compact "" (nth 1 entry)) :help (nth 1 entry)
        :compact compact :tight tight
        :section section :entry-key (car entry)
        :on-press (lambda () (funcall on-locate (car entry)))))
    (box :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (flex :width 'stretch :height '(lh 3) :gap '((lh 0) (ch 1)) :align-items 'center
          :padding '((lh 1) (ch 1))
          :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
          :role (and (not account) 'button) :tab-index (and (not account) 0)
          :aria-label "短信登录"
          :help-echo (if account
                          (format "%s%s" nick (if vip " · VIP" ""))
                        "未登录：按 L 登录")
          :on-press (unless account on-login)
      (etaf-ui-icon :name 'account :set 'svg :size 1.0 :min-width 2
                    :color (if account (etaf-ncm-color :ok) (etaf-ncm-color :dim)))
      (box :if (not compact) :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
           :height '(lh 1) :overflow 'hidden
        (text (expr (if account (or nick "已登录") "未登录"))))
      (box :if (and (not compact) account vip) :height '(lh 1) :flex-shrink 0
           :font-weight 'bold :color (etaf-ncm-color :gold)
        (text "VIP"))
      (box :if (and (not compact) (not account)) :height '(lh 1) :flex-shrink 0
           :font-size etaf-ncm-font-meta :color (etaf-ncm-color :dim)
        (text "L 登录")))))))

(etaf-define-component etaf-ncm--view-chips
    (&key model groups columns on-locate)
  "Render the libraries as a strip of glyph chips, as a narrow layout does.
The strip replaces the sidebar: every library stays one press away while the
header keeps showing the current library's name.  COLUMNS is the window
width; the chip size shrinks with it so the strip keeps every library.  The
component reads the session source itself, so a library switch repaints the
chips only."
  :render
  (let* ((section (etaf-ncm--ref model :section))
         (entries (apply #'append (mapcar #'cdr groups)))
         (plan (etaf-ncm-layout-chips columns (length entries)))
         (width (car plan))
         (gap (cdr plan)))
    (etaf-view
     (flex :position 'absolute :z-index 0 :left '(ch 1) :top '(lh 3)
           :width (list 'ch (etaf-ncm-layout-list-columns 'narrow columns))
           :height '(lh 2) :gap (list (list 'lh 0) (list 'ch gap))
           :align-items 'center :overflow 'hidden :focus-group 'horizontal
       (etaf-ncm--view-nav-item :for (entry entries) :key (car entry)
         :chip t :width width :icon (nth 2 entry) :label (nth 1 entry)
         :section section :entry-key (car entry)
         :on-press (lambda () (funcall on-locate (car entry))))))))

(etaf-define-component etaf-ncm--view-header-action
    (&key label primary hidden on-press help)
  "Render one header action with the shared button component.
The button sizes itself from its label, and the wrapper refuses to shrink,
so a cramped row moves the search field instead of clipping the word."
  :view
  (box :flex-shrink 0 :visibility (if hidden 'hidden 'visible)
    (etaf-button :label label
                 :variant (if primary 'primary 'ghost)
                 :pointer (if primary 'hand nil)
                 :help-echo help :on-press on-press)))

(etaf-define-component etaf-ncm--view-header
    (&key model layout columns short on-search on-play-library on-refresh)
  "Render the content header for MODEL's current library.
LAYOUT is the window's tier; a compact one stacks the search field under the
title.  The subtitle only appears when COLUMNS can hold it, and SHORT frames
drop it.  Every width comes from `etaf-ncm-layout': the search field shrinks
toward its minimum while the actions keep their intrinsic width, so a pressed
button can never be clipped into a shorter word.  The component reads the
session sources itself, so a title or loading change repaints the header
instead of the whole application.  The reload action reads `换一批` only on
private FM, where the backend answers with a new batch, and `刷新` elsewhere."
  :bindings ((playable (etaf-ncm--ref model :playable)))
  :render
  (let* ((compact (not (eq layout 'wide)))
         (title (etaf-ncm--ref model :title))
         (subtitle (etaf-ncm--ref model :subtitle))
         (query (etaf-ncm--read model :query))
         ;; Only private FM answers a reload with a different batch, so only
         ;; there does the action promise one; every other library reloads
         ;; itself, because the backend returns the same rows for the same
         ;; request and the daily recommendation is one batch per day.
         (refresh-label (if (eq (etaf-ncm--read model :section) :fm) "换一批" "刷新"))
         (title-min (list 'ch etaf-ncm-layout-title-min-columns))
         (search-min (list 'ch etaf-ncm-layout-search-min-columns))
         (search-width (list 'ch etaf-ncm-layout-search-columns))
         (show-subtitle (and (not short)
                             (etaf-ncm-layout-subtitle-p layout columns))))
    (etaf-view
  (column :position 'absolute :z-index 0
          :left (list 'ch (if compact 1 2)) :top '(lh 0)
          :width (list 'ch (etaf-ncm-layout-list-columns layout columns))
          :height (if compact '(lh 3) '(lh 2)) :item-gap '(lh 0)
    (flex :if compact :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center
      (box :flex-grow 1 :flex-shrink 1 :flex-basis '(px 0) :min-width title-min
           :height '(lh 1) :overflow 'hidden :font-weight 'bold
        (text (expr (or (etaf-value title) ""))))
      (box :if show-subtitle :height '(lh 1) :overflow 'hidden :flex-shrink 0
           :color (etaf-ncm-color :muted) :font-size etaf-ncm-font-meta
        (text (expr (or (etaf-value subtitle) ""))))
      (etaf-ncm--view-header-action
       :label refresh-label :help-echo refresh-label :on-press on-refresh))
    (flex :if compact :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center
      (flex :flex-grow 1 :flex-shrink 1 :flex-basis '(px 0) :min-width search-min
            :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder "搜索歌曲、歌手、歌单或专辑"
                         :hide-label t :on-change on-search))
      (etaf-ncm--view-header-action
       :primary t :label "播放全部" :help-echo "播放整个列表"
       :hidden (not (etaf-value playable)) :on-press on-play-library))
    (column :if (not compact) :width 'stretch :height '(lh 2) :item-gap '(lh 0)
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
            :align-items 'center
        (box :height '(lh 1) :flex-shrink 1 :min-width title-min :overflow 'hidden
             :font-weight 'bold
          (text (expr (or (etaf-value title) ""))))
        ;; The subtitle follows the title on the same row, one gap column
        ;; apart; the row below stays clear so the header keeps its air.
        (box :if show-subtitle :height '(lh 1) :flex-shrink 0 :overflow 'hidden
             :color (etaf-ncm-color :muted) :font-size etaf-ncm-font-meta
          (text (expr (or (etaf-value subtitle) ""))))
        (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1))
        (box :width search-width :height '(lh 1) :flex-shrink 1 :min-width search-min
          (etaf-text-input :value query :label "搜索"
                           :placeholder "搜索歌曲、歌手、歌单或专辑"
                           :hide-label t :on-change on-search))
        (etaf-ncm--view-header-action
         :primary t :label "播放全部" :help-echo "播放整个列表"
         :hidden (not (etaf-value playable)) :on-press on-play-library)
        (etaf-ncm--view-header-action
         :label refresh-label :help-echo refresh-label :on-press on-refresh))
      (box :flex-grow 1 :flex-basis '(lh 0)))))))

(defun etaf-ncm--pane-tab-source (key pane-list lyrics queue)
  "Return KEY's reactive active source among the pane switch flags."
  (pcase key
    ('list pane-list)
    ('lyrics lyrics)
    (_ queue)))

(etaf-define-component etaf-ncm--view-pane-tabs
    (&key pane-list lyrics queue on-pane on-aside)
  "Render the list/lyrics/queue switch a compact layout uses.
PANE-LIST, LYRICS and QUEUE are reactive sources; each tab reads them inside
its Host bindings, so switching a pane publishes retained paint instead of
rebuilding the view."
  :view
  (flex :position 'relative :z-index 2
        :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
        :flex-shrink 0 :align-items 'center :padding '((lh 0) (ch 2))
        :background-color (etaf-ncm-color :panel)
        :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
    (flex :focus-group 'horizontal :height '(lh 1) :gap '((lh 0) (ch 1))
          :flex-shrink 0 :align-items 'center
    (flex :for (tab (list (list 'list "列表")
                          (list 'lyrics "歌词")
                          (list 'queue "队列"))) :key (car tab)
      :width '(ch 8) :height '(lh 1) :flex-grow 0 :flex-shrink 0
      :justify-content 'center :align-items 'center
      :padding '((lh 0) (ch 1)) :role 'tab :tab-index 0
      :aria-selected (etaf-value (etaf-ncm--pane-tab-source
                                  (car tab) pane-list lyrics queue))
      :hover-style (unless (etaf-value (etaf-ncm--pane-tab-source
                                        (car tab) pane-list lyrics queue))
                     (etaf-ncm--hover-surface))
      :help-echo (nth 1 tab)
      :background-color (if (etaf-value (etaf-ncm--pane-tab-source
                                         (car tab) pane-list lyrics queue))
                            (etaf-ncm-color :accent-soft)
                          (etaf-ncm-color :panel))
      :color (if (etaf-value (etaf-ncm--pane-tab-source
                              (car tab) pane-list lyrics queue))
                 (etaf-ncm-color :accent)
               (etaf-ncm-color :muted))
      :font-weight (if (etaf-value (etaf-ncm--pane-tab-source
                                    (car tab) pane-list lyrics queue))
                       'bold 'normal)
      :on-press (if (eq (car tab) 'list)
                    (lambda () (funcall on-pane 'list))
                  (lambda () (funcall on-aside (car tab))))
      (box :height '(lh 1)
        (text (expr (nth 1 tab))))))
    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
         :height '(lh 1) :text-align 'right :color (etaf-ncm-color :dim)
         :font-size etaf-ncm-font-meta :overflow 'hidden
      (text (expr (let ((list-p (etaf-value pane-list))
                        (lyrics-p (etaf-value lyrics))
                        (queue-p (etaf-value queue)))
                    (cond (list-p "↑↓ 选择 · Tab 切换")
                          (queue-p "l 切换面板")
                          (lyrics-p "i 歌词/队列")
                          (t "l 切换面板"))))))))

(etaf-define-component etaf-ncm--view-list
    (&key model compact selection keys direction on-focus on-press on-action)
  "Render MODEL's visible rows through retained row slots and a page footer.
Each visible row keeps its slot identity across library switches, so a reply
updates prepared row text instead of rebuilding the list.  The selection and
playing highlight are two absolute overlay bars whose `:top' is the only
thing that moves; rows stay transparent and content-driven, so moving the
highlight never repaints the whole plane.  The page fills every row the
window budget leaves after the header, the tabs and the player bar, and the
wheel scrolls the window through the loaded rows, so a long library is fully
reachable.  In the card family the list fills the card's content area
instead: no footer, no header, and the page is that content area.
SELECTION is the player's reactive selection source; ON-PRESS is
called with a row's page index when that row is clicked, and ON-ACTION with
that index plus an inline action key.  The list is one keyboard stop: KEYS
are its `:keys', and ON-FOCUS runs when focus enters it."
  :render
  (let* ((slots (plist-get model :row-slots))
         (playing (plist-get model :row-playing))
         (visible (etaf-ncm--ref model :visible-count))
         (count (max 1 (min (etaf-ncm--render-rows model) (length slots))))
         (offsets (number-sequence 0 (1- count)))
         (page-label (etaf-ncm--ref model :page-label))
         (loaded-label (etaf-ncm--ref model :loaded-label))
         (footer-visible (etaf-ncm--ref model :footer-visible))
         (more-visible (etaf-ncm--ref model :more-visible))
         (empty-note (etaf-ncm--ref model :empty-note))
         (layout (etaf-ncm--read model :layout))
         (widget (etaf-ncm-layout-widget-p layout))
         (columns (or (etaf-ncm--read model :columns) 0))
         (window-rows (etaf-ncm--read model :window-rows))
         (variant (etaf-ncm-layout-row-variant layout columns))
         (short (etaf-ncm-layout-short-p window-rows))
         ;; The view lives in the list panel, whose content box starts one
         ;; row below the window top; the layout budget counts from the
         ;; window, hence the conversion.  A card already owns that inset.
         (top (if widget 0 (1- (etaf-ncm-layout-list-top layout))))
         (footer-rows (if widget 0 (etaf-ncm-layout-footer-rows-for window-rows)))
         (hint (cond (widget nil)
                     ((and (not compact) (not short)) "↑↓ 选择 · RET 播放 · a 入队 · d 下载 · / 搜索 · i 歌词 · Tab 切换区域 · ? 帮助")
                     ((and (<= 44 columns) (not short)) "↑↓ 选择 · Tab 切换 · ? 命令")
                     (t nil)))
         (height (cond
                  ;; A card gives the list a flexible region, not a row count:
                  ;; the canvas must fill it and scroll inside it.
                  (widget '(% 100))
                  ((and window-rows (> window-rows 0))
                   ;; The panel inset converts the window-level budget into
                   ;; this view's coordinate: page rows plus the footer
                   ;; reach exactly the bar, so the footer cannot slide
                   ;; under it.
                   (max 1 (- window-rows (1+ top)
                             (etaf-ncm-layout-tabs-rows layout)
                             etaf-ncm-layout-bar-rows)))
                  (t (+ count footer-rows)))))
    (etaf-view
     (flex :position 'absolute :z-index 0
           :left (list 'ch (cond (widget 0) ((eq layout 'wide) 2) (t 1)))
           :top (list 'lh top)
           :flex-direction 'column
           :width (if widget 'stretch
                    (list 'ch (etaf-ncm-layout-list-columns layout columns)))
           :height (if (consp height) height (list 'lh height))
           :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
           :ref 'ncm-list :role 'listbox :aria-label "歌曲列表" :tab-index 0
           :keys keys :on-direction direction :on-focus-enter on-focus
       (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
            :width 'stretch :height '(lh 6)
            :visibility (if (zerop (etaf-value visible)) 'visible 'hidden)
         (etaf-ncm--view-note :text empty-note))
       ;; The rows live in one scrolling canvas, so Ebox scrolls them
       ;; natively: a wheel or trackpad gesture runs continuously and keeps its
       ;; momentum instead of being translated into a page move here.
       (box :ref 'ncm-list-scroll :id "ncm-list-scroll"
            :width 'stretch
            :height (if widget '(% 100) (list 'lh (max 1 (- height footer-rows))))
            :min-height '(lh 0) :flex-shrink 0 :overflow 'scroll
         (box :position 'relative :width 'stretch :height (list 'lh count)
           ;; Two static bars behind the rows: selection first, playing on top.
           ;; The app moves them through retained host geometry (`:top' is
           ;; their only change), so a highlight move never repaints the plane.
           (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh -1)
                :width 'stretch :height '(lh 1)
                :ref 'ncm-list-selection :id "ncm-list-selection"
                :background-color (etaf-ncm-color :panel2))
           (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh -1)
                :width 'stretch :height '(lh 1)
                :ref 'ncm-list-playing :id "ncm-list-playing"
                :background-color (etaf-ncm-color :accent-soft))
           (column :position 'relative :z-index 1 :left '(ch 0) :top '(lh 0)
                   :width 'stretch :item-gap '(lh 0)
             (etaf-ncm--view-row :for (offset offsets) :key offset
               :ref (intern (format "ncm-row-%d" offset))
               :offset offset
               :row (aref slots offset)
               :playing (aref playing offset)
               :selection selection
               :variant variant
               :press on-press
               :on-action on-action))))
       (flex :if (not widget) :position 'relative :z-index 0 :left '(ch 0)
             :flex-direction 'column
             :width 'stretch :height (list 'lh footer-rows)
             :flex-shrink 0 :gap '((lh 0) (px 0))
             :color (etaf-ncm-color :dim) :font-size etaf-ncm-font-meta
         (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
           (box :height '(lh 1) :flex-shrink 0
             ;; The row stays painted and each label reads its own sources
             ;; inside its Host binding: gating the whole row on a
             ;; component-level read left it invisible until some unrelated
             ;; write happened to re-render the list.
             (text (expr (if (etaf-value footer-visible)
                             (or (etaf-ncm--reactive-text page-label) "")
                           ""))))
           (box :if hint :height '(lh 1) :overflow 'hidden
                :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
             (text (expr (or hint "")))))
         (box :if (not short) :height '(lh 1)
           (text (expr (if (and (etaf-value footer-visible)
                                (etaf-value more-visible))
                           (or (etaf-ncm--reactive-text loaded-label) "")
                         "")))))))))

(defun etaf-ncm--notice-lines (text layout columns)
  "Return how many wrapped lines TEXT needs in the library panel.
LAYOUT and COLUMNS come from the session; the result is between one and four
lines, so a long failure stays fully readable without covering the library."
  (let ((width (max 8 (etaf-ncm-layout-list-columns layout columns))))
    (max 1 (min 4 (/ (+ (string-width (or text "")) width -1) width)))))

(etaf-define-component etaf-ncm--view-list-panel
    (&key layout columns window-rows visible)
  "Wrap the library column in an absolute stage panel.
VISIBLE is the reactive source that shows the list; LAYOUT, COLUMNS and
WINDOW-ROWS place and size the panel in the same cells the content budgets
assume, keeping its footer above the pane switch and the player bar.  The
panel is a direct child of the root plane, so the rows inside it keep a
retained canvas and a selection change publishes retained row paint instead
of rebuilding the view."
  :render
  (let* ((columns (or columns 0))
         (wide-p (eq layout 'wide))
         (rows (or window-rows 0))
         (height (and (> rows 0)
                      (max 1 (- rows etaf-ncm-layout-bar-rows
                               (etaf-ncm-layout-tabs-rows layout)))))
         (left (cond (wide-p etaf-ncm-layout-sidebar-columns)
                     ((eq layout 'medium) etaf-ncm-layout-rail-columns)
                     (t 0)))
         (width (+ (etaf-ncm-layout-list-columns layout columns)
                   (if wide-p 4 2))))
    (etaf-view
     (box :position 'absolute :left (list 'ch left) :top '(lh 0)
          :width (list 'ch width) :height (if height (list 'lh height) '(% 100)) :z-index 0
          :visibility (if (etaf-value visible) 'visible 'hidden)
       (flex :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
             :flex-direction 'column
             :width (list 'ch (+ (etaf-ncm-layout-list-columns layout columns)
                                 (if wide-p 4 2)))
             :height 'stretch
             :min-width '(ch 0) :min-height '(lh 0)
             :padding '((lh 1) (ch 0) (lh 0) (ch 0))
             :gap '((lh 1) (px 0))
         (expr (etaf-current-slot 'default)))))))

;;; ---------------------------------------------------------------------------
;;; Lyrics, queue and player
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-tabs (&key kind on-switch)
  "Render the lyrics/queue switch with KIND active.
The active tab is a tinted pill, not an underline: the two tabs keep their
width, so switching cannot shift the row, and the state reads from the
typography and the surface together.  Each aside variant draws its own
static tab row."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
        :align-items 'center :focus-group 'horizontal
        :border-bottom (etaf-ncm--view-border 'bottom (etaf-ncm-color :line))
    (box :height '(lh 1) :padding '((lh 0) (ch 2)) :role 'tab :tab-index 0
         :aria-selected (eq kind 'lyrics)
         :hover-style (unless (eq kind 'lyrics) (etaf-ncm--hover-surface))
         :help-echo "看歌词"
         :font-weight (if (eq kind 'lyrics) 'bold 'normal)
         :background-color (if (eq kind 'lyrics) (etaf-ncm-color :accent-soft)
                             (etaf-ncm-color :panel))
         :color (if (eq kind 'lyrics) (etaf-ncm-color :accent)
                  (etaf-ncm-color :muted))
         :on-press (lambda () (funcall on-switch 'lyrics))
      (text "歌词"))
    (box :height '(lh 1) :padding '((lh 0) (ch 2)) :role 'tab :tab-index 0
         :aria-selected (eq kind 'queue)
         :hover-style (unless (eq kind 'queue) (etaf-ncm--hover-surface))
         :help-echo "看播放队列"
         :font-weight (if (eq kind 'queue) 'bold 'normal)
         :background-color (if (eq kind 'queue) (etaf-ncm-color :accent-soft)
                             (etaf-ncm-color :panel))
         :color (if (eq kind 'queue) (etaf-ncm-color :accent)
                  (etaf-ncm-color :muted))
         :on-press (lambda () (funcall on-switch 'queue))
      (text "播放队列"))))

(defun etaf-ncm--shade (color factor)
  "Return COLOR, a hex string, multiplied by FACTOR.
Used to build the text side's surface out of the cover's own colour: the page
then reads as one picture instead of a black slab beside the artwork."
  (if (and (stringp color)
           (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color)
           (numberp factor))
      (let ((v (string-to-number (substring color 1) 16)))
        (format "#%02x%02x%02x"
                (round (* factor (ash (logand v #xff0000) -16)))
                (round (* factor (ash (logand v #x00ff00) -8)))
                (round (* factor (logand v #x0000ff)))))
    color))

(defun etaf-ncm--now-surface (accent panel-color)
  "Return the playing page's text surface.
On a dark host the surface is the cover's own colour, dimmed, so the page reads
as one picture.  On a light host that same slab is a black block beside a white
window: the surface there is the light palette's panel, which the glyphs already
have ink for."
  (if (eq (etaf-ncm--effective-mode) 'light)
      (etaf-ncm-color :panel)
    (etaf-ncm--shade (or accent panel-color) 0.34)))

(defun etaf-ncm--center-text (text columns)
  "Return TEXT padded to sit centred in COLUMNS cells.
`text-align' is not honoured inside a nested component, so the lyric centres
itself: the padding is part of the string and every glyph stays where it is
put."
  (if (or (not (stringp text)) (not (numberp columns)) (<= columns 0))
      (or text "")
    (let* ((width (string-width text))
           (pad (max 0 (- columns width)))
           (left (/ pad 2)))
      (concat (make-string left ?\s)
              text
              (make-string (- pad left) ?\s)))))

(etaf-define-component etaf-ncm--view-lyric-cell
    (&key projection index (align 'center) (columns 0))
  "Keep one physical lyric row while its text and current-line paint change.
ALIGN centres the line in a small-size card and keeps it left in the panel."
  :bindings ((cell (etaf-computed
                   (lambda () (nth index (plist-get (etaf-value projection) :cells))) :test #'equal)))
  :view
  ;; A stretched row inside an absolutely positioned column resolved against
  ;; the page instead of the column, so every lyric line painted a dark bar
  ;; across the artwork.  Rows take the column's own width instead.
  (box :height '(lh 1) :width (if (> (or columns 0) 0)
                                  (list 'ch columns)
                                'stretch)
       :overflow 'hidden :text-align align
       :color (let ((row (etaf-value cell)))
                (etaf-ncm-color (cond ((plist-get row :current) :accent)
                                      ((plist-get row :translation) :dim) (t :muted))))
       :font-weight (if (plist-get (etaf-value cell) :current) 'bold 'normal)
    ;; A translation is told apart by its colour, not by a smaller face: Ebox
    ;; does not scale text, so a `:height' face on the line drew a stray rule
    ;; through it that read as an underline.
    (text (expr (let* ((row (etaf-value cell))
                       (text (or (plist-get row :text) "")))
                  (if (eq align 'center)
                      (etaf-ncm--center-text text columns)
                    text))))))

(etaf-define-component etaf-ncm--view-lyrics
    (&key title artist album cover projection rows)
  "Render retained metadata and a viewport-sized lyric row pool."
  :render
  (let ((offsets (and (> rows 0) (number-sequence 0 (1- rows))))
        ;; A terminal cell is half-block sized, so the same square cover needs
        ;; more columns there while the graphical frame keeps its 10-char box.
        (cover-chars (if (display-graphic-p) 10 18))
        (cover-lines (if (display-graphic-p) 7 9)))
   (etaf-view
  (flex :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
    (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
      (etaf-ncm--view-cover :size (list 'ch cover-chars) :chars cover-chars
                            :lines cover-lines :file cover)
      (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :item-gap '(lh 0)
        (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
          (text (expr (or (etaf-ncm--reactive-text title) "还没有播放"))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
          (text (expr (or (etaf-ncm--reactive-text artist) ""))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :dim)
             :font-size etaf-ncm-font-meta
          (text (expr (or (etaf-ncm--reactive-text album) ""))))))
    (box :height '(lh 1))
    (flex :flex-direction 'column :width 'stretch :flex-grow 1
          :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
      (etaf-ncm--view-lyric-cell :for (index offsets) :key index :projection projection :index index))
    (box :width 'stretch :height '(lh 1) :color (etaf-ncm-color :dim)
         :font-size etaf-ncm-font-meta :text-align 'center
      (text (expr (let ((data (etaf-value projection)))
                    (if (plist-get data :lines)
                        (format "%s / %s" (or (plist-get data :position) 0) (or (plist-get data :total) 0)) "")))))))))

(etaf-define-component etaf-ncm--view-queue-cell (&key projection index on-jump)
  "Render one retained queue slot, resolving its current identity on activation."
  :bindings ((entry (etaf-computed (lambda () (nth index (plist-get (etaf-value projection) :entries))) :test #'equal))
             (glyph (car (etaf-ui-icon-lines 'play :set 'svg :color (etaf-ncm-color :accent)))))
  :view
  (flex :if (etaf-value entry)
        :width 'stretch :height '(lh 1) :role 'button :tab-index 0
        :ref (intern (format "ncm-queue-cell-%d" index))
        :aria-current (plist-get (etaf-value entry) :current)
        :aria-label (let ((row (etaf-value entry)))
                      (if row (format "队列 %s：%s" (plist-get row :index) (plist-get row :name)) "队列"))
        :visibility (if (etaf-value entry) 'visible 'hidden)
        :help-echo (lambda (&rest _)
                     (let ((row (etaf-value entry)))
                       (when row (format "播放队列第 %s 首：%s" (plist-get row :index) (plist-get row :name)))))
        :hover-style (unless (plist-get (etaf-value entry) :current)
                       (etaf-ncm--hover-surface))
        :gap '((lh 0) (ch 1)) :align-items 'center
        :background-color (if (plist-get (etaf-value entry) :current)
                              (etaf-ncm-color :accent-soft) (etaf-ncm-color :panel))
        :color (if (plist-get (etaf-value entry) :current) (etaf-ncm-color :accent) (etaf-ncm-color :muted))
        :font-weight (if (plist-get (etaf-value entry) :current) 'bold 'normal)
        :on-press (lambda () (when-let* ((row (etaf-value entry))) (funcall on-jump (plist-get row :index))))
        ;; The cell is a keyboard stop of the queue's focus group; RET jumps to
        ;; the entry the focused cell shows, as a click does.
        :keys (list (list "RET" (lambda ()
                                  (when-let* ((row (etaf-value entry)))
                                    (funcall on-jump (plist-get row :index))))
                          "跳转到这首"))
    (box :width '(ch 5) :height '(lh 1) :color (etaf-ncm-color :dim)
      (text (expr (let ((row (etaf-value entry)))
                    (cond ((null row) "") ((plist-get row :current) glyph)
                          (t (format "%s." (plist-get row :index))))))))
    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1) :overflow 'hidden
      (text (expr (or (plist-get (etaf-value entry) :name) ""))))
    (box :width '(ch 5) :height '(lh 1) :text-align 'right :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get (etaf-value entry) :right) ""))))))

(etaf-define-component etaf-ncm--view-queue (&key projection rows keys direction on-jump bare)
  "Render a viewport-sized queue pool without replacing rows on every scroll.
The cells form one vertical focus group entered at the playing entry; KEYS
are the group's `:keys' and DIRECTION moves its selection and scrolls past
the pool's first and last cell.  BARE drops the heading and its count line, so
the pool fills a small-size card's content area."
  :render
  ;; One cell per entry, up to a fixed canvas: the count never changes, so the
  ;; column is not rebuilt when the queue grows.
  (let ((offsets (number-sequence 0 (1- (max etaf-ncm-render-limit (or rows 0))))))
   (etaf-view
  (flex :position 'relative :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
        :ref 'ncm-queue :focus-group 'vertical :keys keys :on-direction direction
    (column :if (not bare) :width 'stretch :height '(lh 2) :item-gap '(lh 0)
      (text :font-weight 'bold "播放队列")
      (text :color (etaf-ncm-color :dim)
            (expr (let* ((data (etaf-value projection)) (entries (plist-get data :entries)))
                    (format "第 %s-%s 首 / 共 %s 首" (or (plist-get (car entries) :index) 0)
                            (or (plist-get (car (last entries)) :index) 0) (or (plist-get data :count) 0))))))
    (box :position 'absolute :z-index 0 :top (list 'lh (if bare 0 2)) :left '(ch 0) :height '(lh 1)
         :visibility (if (plist-get (etaf-value projection) :entries) 'hidden 'visible)
         :color (etaf-ncm-color :dim)
      (text "队列是空的"))
    ;; One scrolling canvas, exactly as the library list is: the wheel scrolls
    ;; it natively, so a gesture runs through the whole queue with momentum.
    (box :ref 'ncm-queue-scroll :id "ncm-queue-scroll"
         :position 'relative :width 'stretch :flex-grow 1 :flex-basis '(px 0)
         :min-height '(lh 0) :overflow 'scroll
      (column :width 'stretch
        (etaf-ncm--view-queue-cell :for (index offsets) :key index
                                   :projection projection :index index
                                   :on-jump on-jump)))))))

(etaf-define-component etaf-ncm--view-aside
    (&key kind visible layout columns window-rows title artist album cover
          projection rows queue-keys queue-direction on-switch on-jump)
  "Render one absolute aside variant: KIND is `lyrics' or `queue'.
Both variants are panels of the root stage; VISIBLE is the reactive source
that reveals this one, so switching panels publishes retained visibility
updates instead of rebuilding the view.  QUEUE-KEYS are the queue's
`:keys'.  LAYOUT and COLUMNS size and place
the panel in the same cells the wheel hit test uses.  The panel ends at the
window bottom; the player bar paints over its last rows, and the row budgets
already stop the content above it."
  :render
  (let* ((columns (or columns 0))
         ;; The panel spans the window; ROWS is the row budget each panel view
         ;; keeps for its own pool, so this local must not shadow that prop.
         (window-height (or window-rows 0))
         (height (and (> window-height 0)
                      (etaf-ncm-layout-aside-rows layout window-height)))
         (left (cond ((eq layout 'wide)
                      (max 0 (- columns etaf-ncm-layout-aside-columns)))
                     ((eq layout 'medium) etaf-ncm-layout-rail-columns)
                     (t 0)))
         (width (cond ((eq layout 'wide) (max 1 etaf-ncm-layout-aside-columns))
                      ((eq layout 'medium) (max 1 (- columns etaf-ncm-layout-rail-columns)))
                      (t (max 1 columns)))))
    (etaf-view
     (box :position 'absolute :left (list 'ch left) :top '(lh 0)
          :width (list 'ch width) :height (if height (list 'lh height) '(% 100)) :z-index 0
          :visibility (if (etaf-value visible) 'visible 'hidden)
          :ref (intern (format "ncm-aside-%s" kind))
          :padding '((lh 1) (ch 2))
          :background-color (etaf-ncm-color :panel)
          :border-left (etaf-ncm--view-border 'left (etaf-ncm-color :line))
       (flex :flex-direction 'column
             :width (list 'ch (max 1 (- width 4))) :height 'stretch
             :min-width '(ch 0) :gap '((lh 0) (px 0))
         (etaf-ncm--view-tabs :kind kind :on-switch on-switch)
         (etaf-ncm--view-lyrics :if (eq kind 'lyrics)
           :title title :artist artist :album album :cover cover
           :projection projection :rows rows)
         (etaf-ncm--view-queue :if (eq kind 'queue)
           :projection projection :rows rows :keys queue-keys :direction queue-direction :on-jump on-jump))))))

(defun etaf-ncm--reactive-text (text)
  "Return TEXT's current string, reading a reactive source in place.
Reading inside the Host expression keeps the dependency on the source instead
of subscribing the rendering Component to it."
  (if (or (etaf-ref-p text) (etaf-computed-p text)) (etaf-value text) text))

(defun etaf-ncm--active-value (active)
  "Return ACTIVE's current boolean for a HOST binding.
A reactive source, ref or computed, is read at the call site, which keeps the
read inside the host property binding instead of subscribing the whole
component.  A computed object is truthy on its own, so failing to read it
would mark every row as playing."
  (if (or (etaf-ref-p active) (etaf-computed-p active)) (etaf-value active) active))

(etaf-define-component etaf-ncm--view-control (&key icon icons glyph label help on-press active value ref)
  "Render one compact player action.
ICON names an `etaf-ui-icon' in the SVG style, so the control keeps one
optical size and never changes the row height.  ICONS, when given, is an
\(OFF . ON) icon-name pair rendered by `etaf-ui-toggle-icon'; VALUE is then the
reactive source that selects the variant, so a state change publishes a
retained Host text update instead of re-rendering the view.  GLYPH is the
plain-text alternative for controls that are words (词 ON) instead of
pictures.  LABEL appends a small count or state next to the icon."
  :view
  (flex :width 'max-content :height '(lh 1) :align-items 'center :flex-shrink 0
        :gap '((lh 0) (ch 1))
    (etaf-ui-toggle-icon :if icons :value (or value active)
                         :off (car icons) :on (cdr icons)
                         :set 'svg :size 1.0
                         :color (etaf-ncm-color :muted)
                         :on-color (etaf-ncm-color :accent)
                         :min-width 3 :help-echo help :on-press on-press :ref ref)
    (etaf-ui-icon :if (and icon (not icons)) :name (or icon 'music) :set 'svg :size 1.0
                  :color (etaf-ncm-color (if active :accent :muted))
                  :min-width 3 :help-echo help :on-press on-press :ref ref)
    (box :if (and (not icon) (not icons) glyph) :height '(lh 1) :role 'button :tab-index 0
         :aria-label help
         :color (etaf-ncm-color (if active :accent :muted))
         :hover-style (etaf-ncm--hover-surface)
         :help-echo help :on-press on-press
      (text (expr (or glyph ""))))
    (box :if label :height '(lh 1) :color (etaf-ncm-color :muted)
      (text (expr (format "%s" (or (etaf-ncm--reactive-text label) "")))))))

(defun etaf-ncm--track-label (title artist vip)
  "Format retained TITLE, ARTIST and VIP without changing dependency branches."
  (let ((name (or (etaf-ncm--reactive-text title) ""))
        (performer (or (etaf-ncm--reactive-text artist) ""))
        (premium (etaf-ncm--active-value vip)))
    (concat (if premium (propertize "VIP " 'face (list :foreground (etaf-ncm-color :accent) :weight 'normal)) "")
            (if (string-empty-p name) "未在播放" name)
            (if (string-empty-p performer) "" (concat " - " performer)))))

(etaf-define-component etaf-ncm--view-track
    (&key title artist vip queue-count compact shuffle message liked cover
          on-cover on-add on-like on-shuffle on-stop on-queue)
  "Render the cover, one-line track identity and the small action row.
Pressing the cover opens the full-page view of the playing song."
  :view
  (grid :width 'stretch :height (if compact '(lh 1) '(lh 3))
        :grid-template-columns (if compact '((fr 1) (ch 24)) '((ch 6) (fr 1)))
        :gap '((lh 0) (ch 1)) :align-items 'center
    (box :if (not compact) :id "ncm-cover" :ref 'ncm-cover :width '(ch 6) :height '(lh 3)
         :role 'button :tab-index 0
         :help-echo "打开播放页"
         :on-press on-cover
      (etaf-ncm--view-cover :size '(ch 6) :height '(lh 3) :chars 6 :lines 3
                            :file (and (not compact) cover)))
    (box :if compact :height '(lh 1) :width 'stretch
         :min-width '(ch 0) :overflow 'hidden :font-weight 'bold
      (text :ref 'ncm-track-title (expr (etaf-ncm--track-label title artist vip))))
    (flex :flex-direction 'column :width 'stretch :min-width '(ch 0)
          :gap '((lh 0) (ch 1)) :justify-content 'center
      (flex :if (not compact) :height '(lh 1) :width 'stretch
            :min-width '(ch 0)
            :gap '((lh 0) (ch 1)) :align-items 'center
        (box :height '(lh 1) :flex-grow 1 :flex-basis '(px 0)
             :min-width '(ch 0) :overflow 'hidden :font-weight 'bold
          (text :ref 'ncm-track-title (expr (etaf-ncm--track-label title artist vip)))))
      (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
            :focus-group 'horizontal
        (etaf-ncm--view-control :ref 'ncm-plus :icon 'plus :help "加入队列 (a)" :on-press on-add)
        (etaf-ncm--view-control :ref 'ncm-like :icons '(heart . heart-filled)
                                :value liked
                                :help "喜欢 / 取消喜欢 (f / F)" :on-press on-like)
        (etaf-ncm--view-control :ref 'ncm-shuffle :icons '(shuffle . shuffle)
                                :value shuffle
                                :help "随机播放 (z)" :on-press on-shuffle)
        (etaf-ncm--view-control :ref 'ncm-stop :icon 'close :help "停止" :on-press on-stop)
        (etaf-ncm--view-control :ref 'ncm-queue :icon 'queue :help "显示播放列表" :on-press on-queue
                                :label queue-count))
      (box :if (not compact) :height '(lh 1) :width 'stretch
           :overflow 'hidden :color (etaf-ncm-color :dim)
        (text (expr (or (etaf-ncm--reactive-text message) "")))))))

(etaf-define-component etaf-ncm--view-transport
    (&key playing repeat liked compact (repeat-control t)
          on-like on-previous on-toggle on-next on-repeat)
  "Render the centred transport with an accent play control.
PLAYING is the reactive boolean that selects the play/pause glyph, and REPEAT
the reactive flag that paints the repeat control; both publish through
retained Host text, so a toggle never rebuilds the bar.  A graphical frame
keeps one artwork icon per button and a three-cell accent pill for the play
control.  A text terminal cannot draw those icons, and its fonts render the
media glyphs at uneven sizes, so it shows the same controls as words: `上一首',
`播放' / `暂停' in the accent colour, `下一首'.  Those name the action instead
of leaning on a font-dependent glyph, and every control stays one line high.
REPEAT-CONTROL nil drops the repeat control, which a small-size card leaves to
its keyboard shortcut."
  :view
  (flex :height (if compact '(lh 1) '(lh 2))
        :gap (if compact '((lh 0) (ch 2)) '((lh 0) (ch 3)))
        :align-items 'center :justify-content 'center :focus-group 'horizontal
    ;; A graphical frame: artwork icons and the accent play pill.  The like
    ;; control sits on the left so the bar balances: previous on one side,
    ;; repeat on the other, and one control beside each of them.
    (etaf-ncm--view-control :if (and (display-graphic-p) on-like) :ref 'ncm-like
                            :icons '(heart . heart-filled) :value liked
                            :help "喜欢 / 取消喜欢 (f / F)" :on-press on-like)
    (etaf-ncm--view-control :if (display-graphic-p) :ref 'ncm-previous
                            :icon 'previous :help "上一首 (p)" :on-press on-previous)
    (box :if (display-graphic-p) :id "ncm-play" :ref 'ncm-play :width '(ch 3)
         :height '(lh 1) :flex-shrink 0
         :role 'button :tab-index 0 :aria-label "播放 / 暂停"
         :help-echo "播放 / 暂停 (SPC)" :on-press on-toggle
         :background-color (etaf-ncm-color :accent)
      (etaf-ui-toggle-icon :value playing :off 'play :on 'pause :set 'svg :size 1.0
                           :color (etaf-ncm-color :accent-fg)
                           :on-color (etaf-ncm-color :accent-fg)
                           ;; Span the whole pill so the glyph centres with one inset on
                           ;; both sides; a narrower icon leaves the right side heavier.
                           :min-width 3
                           :help-echo "播放 / 暂停 (SPC)" :tab-index -1
                           :on-press on-toggle))
    (etaf-ncm--view-control :if (display-graphic-p) :ref 'ncm-next
                            :icon 'next :help "下一首 (n)" :on-press on-next)
    ;; A text terminal: the words name the action.
    (etaf-ncm--view-control :if (not (display-graphic-p)) :ref 'ncm-previous
                            :glyph "上一首" :help "上一首 (p)" :on-press on-previous)
    (box :if (not (display-graphic-p)) :id "ncm-play" :ref 'ncm-play
         :height '(lh 1) :flex-shrink 0
         :role 'button :tab-index 0 :aria-label "播放 / 暂停"
         :color (etaf-ncm-color :accent)
         :hover-style (etaf-ncm--hover-surface)
         :help-echo "播放 / 暂停 (SPC)" :on-press on-toggle
      (text (expr (if (etaf-ncm--active-value playing) "暂停" "播放"))))
    (etaf-ncm--view-control :if (not (display-graphic-p)) :ref 'ncm-next
                            :glyph "下一首" :help "下一首 (n)" :on-press on-next)
    (etaf-ncm--view-control :if repeat-control :ref 'ncm-repeat
                            :icons '(repeat . repeat) :value repeat
                            :help "列表循环 (r)" :on-press on-repeat)
    ;; The text terminal names the action instead of drawing it, and the like
    ;; control keeps the same place on the left.
    (etaf-ncm--view-control :if (and (not (display-graphic-p)) on-like)
                            :glyph "喜欢" :help "喜欢 / 取消喜欢 (f / F)"
                            :on-press on-like)))

(etaf-define-component etaf-ncm--view-progress
    (&key elapsed duration on-seek (prefix "ncm") track-color (visible t))
  "Render elapsed, a draggable progress range and the duration.
Both ELAPSED and DURATION are read by retained Host bindings: the range
clamps a reactive :max itself, so a song change updates the meter in place
instead of re-rendering this Component and republishing the view.  PREFIX
names the retained Hosts, so the player bar and a full-page view can each own a
meter in the same Runtime.  TRACK-COLOR paints the unfilled part; a caller that
sits on a flat panel passes that panel's colour and the track disappears into
it."
  :render
  (let ((elapsed-ref (intern (format "%s-elapsed" prefix)))
        (seek-ref (intern (format "%s-seek" prefix)))
        (meter-ref (intern (format "%s-meter" prefix))))
    (etaf-view
     (flex :if visible :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
       (box :width '(ch 5) :height '(lh 1) :text-align 'right
            :color (etaf-ncm-color :dim) :flex-shrink 0
         (text :ref elapsed-ref :id (format "%s-elapsed" prefix)
               (expr (etaf-ncm--format-seconds (etaf-ncm--active-value elapsed)))))
       (flex :flex-direction 'row :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
             :height '(lh 1)
         (etaf-range :value elapsed :min 0 :max duration
                     :ref seek-ref :fill-ref meter-ref :key-step 5
                     :aria-label "播放进度，点击或拖动跳转"
                     ;; One-pixel rule: a native-style player reads the meter as a
                     ;; hairline inside a full-height hit row, not as a slider bar.
                     :bar-height 8
                     :color (etaf-ncm-color :accent)
                     :track-color (or track-color (etaf-ncm-color :panel3))
                     :on-commit on-seek))
       (box :width '(ch 5) :height '(lh 1) :color (etaf-ncm-color :dim) :flex-shrink 0
         (text (expr (etaf-ncm--format-seconds (etaf-ncm--active-value duration)))))))))

(etaf-define-component etaf-ncm--view-player-tools
    (&key quality lyrics volume compact on-lyrics on-queue on-volume)
  "Render the reported quality, pane controls and a draggable volume range.
Controls sit in separated groups so the right edge reads as three ideas
(quality badge, pane switches, volume) instead of one crowded line."
  :bindings ((muted (etaf-computed
                    (lambda () (zerop (or (etaf-ncm--active-value volume) 0))))))
  :view
  (flex :height '(lh 1) :align-items 'center :flex-shrink 0
        :justify-content 'end :gap (if compact '((lh 0) (ch 0.5)) '((lh 0) (ch 1)))
    (box :if (not compact) :id "ncm-quality" :ref 'ncm-quality :height '(lh 1)
         :visibility (if (etaf-ncm--active-value quality) 'visible 'hidden)
         :flex-shrink 0 :width '(ch 10) :overflow 'hidden
         :help-echo (lambda (&rest _) (etaf-ncm--active-value quality))
         :color (etaf-ncm-color :muted)
      (text (expr (let ((label (etaf-ncm--active-value quality))) (if label (format "[%s]" label) "")))))
    (box :if (not compact) :width '(ch 1) :height '(lh 1) (text " "))
    (flex :height '(lh 1) :align-items 'center :flex-shrink 0 :focus-group 'horizontal
          :gap (if compact '((lh 0) (ch 0.5)) '((lh 0) (ch 1)))
      (etaf-ncm--view-control :ref 'ncm-lyrics :icons '(lyrics . lyrics) :value lyrics
                              :help "显示歌词 (i)" :on-press on-lyrics)
      (etaf-ncm--view-control :ref 'ncm-queue-aside :icon 'queue :help "显示播放列表"
                              :on-press on-queue))
    (box :width '(ch 1) :height '(lh 1) (text " "))
    (etaf-ui-toggle-icon :value muted :off 'volume :on 'volume-mute
                         :set 'svg :size 0.9 :color (etaf-ncm-color :muted) :min-width 2)
    (flex :flex-direction 'row :width (if compact '(ch 8) '(ch 12)) :height '(lh 1)
          :flex-shrink 0
      (etaf-range :value (or volume 0) :min 0 :max 100 :ref 'ncm-volume :key-step 5
                  :fill-ref 'ncm-volume-fill
                  :aria-label "音量，点击或拖动调节"
                  :bar-height 8
                  :color (etaf-ncm-color :accent)
                  :track-color (etaf-ncm-color :panel3)
                  :on-commit on-volume))
    (box :width '(ch 4) :height '(lh 1) :text-align 'right
         :color (etaf-ncm-color :dim)
      (text (expr (format "%d%%" (or (etaf-ncm--active-value volume) 0)))))))

(etaf-define-component etaf-ncm--view-player
    (&key title artist vip quality playing elapsed duration volume shuffle repeat lyrics message
          queue-count compact liked cover on-toggle on-next on-previous on-stop on-like on-add
          on-volume on-seek on-shuffle on-repeat
          on-lyrics on-queue on-cover)
  "Render a native-style three-column bar, or three compact rows.
The bar is an absolutely positioned panel: the app reserves its five lines
with a positioned host, while the panel itself stays a retained publication
address so its controls update without rebuilding the view.  The bar box is
exactly those five rows: one padding row above the content, the three
content rows and the closing padding row that keeps the text one row from
the bottom edge, since the hosting window adds no inset of its own.  It
paints no border of its own: a pixel border would push the box off the row
grid and eat the closing line; the pane tab strip above it carries the
separator where one is drawn."
  :view
  (box :position 'absolute :left '(px 0) :top '(lh 0)
       :width '(% 100) :height '(% 100) :z-index 1
       :padding '((lh 1) (ch 2) (lh 1) (ch 2))
       :background-color (etaf-ncm-color :panel)
    (grid :if (not compact) :width 'stretch :height '(lh 3)
          :grid-template-columns '((fr 1) (fr 1) (fr 1)) :gap '((lh 0) (ch 2))
      (etaf-ncm--view-track :title title :artist artist :vip vip :queue-count queue-count
                            :message message :shuffle shuffle :liked liked :cover cover
                            :on-cover on-cover :on-add on-add
                            :on-like on-like :on-shuffle on-shuffle :on-stop on-stop :on-queue on-queue)
      (flex :flex-direction 'column :width 'stretch :height '(lh 3)
        (etaf-ncm--view-transport :playing playing :repeat repeat :on-like on-like
                                :on-previous on-previous :on-toggle on-toggle :on-next on-next :on-repeat on-repeat)
        (etaf-ncm--view-progress :elapsed elapsed :duration duration
                               :on-seek on-seek))
      (flex :width 'stretch :height '(lh 3) :align-items 'center
        (etaf-ncm--view-player-tools :quality quality :lyrics lyrics :volume volume
                                   :on-lyrics on-lyrics :on-queue on-queue
                                   :on-volume on-volume)))
    (flex :if compact :width 'stretch :height '(lh 3) :flex-direction 'column
      (etaf-ncm--view-track :title title :artist artist :vip vip :queue-count queue-count
                            :compact t :shuffle shuffle :liked liked :cover cover
                            :on-add on-add :on-like on-like
                            :on-shuffle on-shuffle :on-stop on-stop :on-queue on-queue)
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
        (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
          (etaf-ncm--view-transport :playing playing :repeat repeat :compact t :on-like on-like
                                  :on-previous on-previous :on-toggle on-toggle :on-next on-next :on-repeat on-repeat))
        (flex :width '(ch 24) :height '(lh 1) :flex-shrink 0 :flex-direction 'row
          (etaf-ncm--view-player-tools :lyrics lyrics :volume volume :compact t
                                     :on-lyrics on-lyrics :on-queue on-queue
                                     :on-volume on-volume)))
      (etaf-ncm--view-progress :elapsed elapsed :duration duration
                             :on-seek on-seek))))

;;; ---------------------------------------------------------------------------
;;; The small-size card
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-lyric-list
    (&key projection rows (align 'center) (columns 0))
  "Render a viewport-sized lyric pool, centred by default.
The pool keeps one retained Host per row, so the moving current line repaints
its text without rebuilding the card."
  :render
  (let ((offsets (and (> rows 0) (number-sequence 0 (1- rows)))))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :height (list 'lh (max 1 rows))
           :min-height '(lh 0) :gap '((lh 0) (px 0))
           :align-items 'center :justify-content 'center :overflow 'hidden
       (etaf-ncm--view-lyric-cell :for (index offsets) :key index
                                  :projection projection :index index
                                  :align align :columns columns)))))

(etaf-define-component etaf-ncm--view-tile-head
    (&key title artist liked on-like)
  "Render the tile's single header row: the track and the like.
At the smallest size every row belongs to the lyric, so the switch keeps to
its keys and returns as tabs one size up."
  :view
  (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
         :overflow 'hidden :font-weight 'bold
      (text :ref 'ncm-track-title (expr (etaf-ncm--track-label title artist nil))))
    (etaf-ncm--view-control :ref 'ncm-like :icons '(heart . heart-filled) :value liked
                            :help "喜欢 / 取消喜欢 (f / F)" :on-press on-like)))

(etaf-define-component etaf-ncm--view-card-head
    (&key title artist album cover liked on-like on-cover)
  "Render the now-playing identity of a card: the cover, the track and the like.
Pressing the cover opens the full-page view, as the player bar's cover does."
  :view
  (box :width 'stretch
   (flex :width 'stretch :height '(lh 3)
         :gap '((lh 0) (ch 1)) :align-items 'center
     (box :id "ncm-cover" :ref 'ncm-cover :width '(ch 6) :height '(lh 3)
          :role 'button :tab-index 0 :aria-label "打开播放页"
          :help-echo "打开播放页" :on-press on-cover
       (etaf-ncm--view-cover :size '(ch 6) :height '(lh 3) :chars 6 :lines 3 :file cover))
     (flex :flex-direction 'column :flex-grow 1 :flex-basis '(px 0)
           :min-width '(ch 0) :height '(lh 3) :gap '((lh 0) (px 0))
           :justify-content 'center :overflow 'hidden
       (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
         (text :ref 'ncm-track-title (expr (or (etaf-ncm--reactive-text title) "未在播放"))))
       (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
         (text (expr (or (etaf-ncm--reactive-text artist) ""))))
       (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :dim)
             :font-size etaf-ncm-font-meta
         (text (expr (or (etaf-ncm--reactive-text album) "")))))
     (etaf-ncm--view-control :ref 'ncm-like :icons '(heart . heart-filled) :value liked
                             :help "喜欢 / 取消喜欢 (f / F)" :on-press on-like))))

(etaf-define-component etaf-ncm--view-card-tabs
    (&key pane-list section on-library on-aside)
  "Render the one-row switch of the card: two libraries and the panel.
A compact frame shows one pane at a time and is read for two libraries, so
the strip names them instead of a generic list: 收藏 opens the liked songs and
推荐 the daily recommendation, and 歌词 brings the panel.  The panel still
switches between the lyrics and the queue through `i', so the queue keeps its
place without a tab of its own.  Every other library stays its digit key
away; while one of those is in front no tab is marked, because none of the
three names it.  Each tab reads its sources here, and the player re-renders
on a library or pane write, so the mark follows the pane in front."
  :render
  (let* ((list-p (etaf-value pane-list))
         (liked-p (and list-p (eq (etaf-value section) :liked)))
         (daily-p (and list-p (eq (etaf-value section) :daily)))
         (panel-p (not list-p))
         (tabs (list (list :liked "收藏" liked-p)
                     (list :panel "歌词" panel-p)
                     (list :daily "推荐" daily-p))))
    (etaf-view
     (flex :ref 'ncm-card-tabs :width 'stretch :height '(lh 1)
           :gap '((lh 0) (ch 2))
           :align-items 'center :justify-content 'center
           :flex-shrink 0 :overflow 'hidden
           :focus-group 'horizontal
       (box :for (tab tabs)
            :key (car tab)
            :height '(lh 1) :padding '((lh 0) (ch 1))
            :role 'tab :tab-index 0
            :aria-selected (nth 2 tab)
            :hover-style (unless (nth 2 tab) (etaf-ncm--hover-surface))
            :help-echo (nth 1 tab)
            :background-color (if (nth 2 tab)
                                  (etaf-ncm-color :accent-soft)
                                (etaf-ncm-color :panel))
            :color (if (nth 2 tab) (etaf-ncm-color :accent) (etaf-ncm-color :muted))
            :font-weight (if (nth 2 tab) 'bold 'normal)
            :on-press (lambda ()
                        (pcase (car tab)
                          (:panel (funcall on-aside 'lyrics))
                          (library (funcall on-library library))))
         (text (expr (nth 1 tab))))))))

(etaf-define-component etaf-ncm--view-card
    (&key model tile title artist album cover liked projection rows queue-projection
          pane-list lyrics queue section playing elapsed duration error message
          selection list-keys list-direction on-list-focus on-press on-action
          queue-keys queue-direction on-jump
          on-toggle on-next on-previous on-like on-seek on-library on-aside on-cover)
  "Render the small-size player: identity, one content pane, switch, transport.
The card replaces the header, chip strip, panel and player bar a stacked
layout would draw, and keeps only what a small frame is read for: the track,
the lyric or the library, the pane switch and the transport.  One clear row
separates the cover band, the content and the pane switch, so the card never
reads as one dense block.  TILE drops the cover, the album line and the
progress line: at that size the track, the lyric and the three transport
controls are the whole interface.  PANE-LIST, LYRICS and QUEUE are reactive
sources; the three content panes stay mounted and only their visibility
changes, so a switch keeps their retained hosts.  SECTION is the library in
front, which decides whether the switch marks 收藏 or 推荐, and ON-LIBRARY
opens one of those libraries in this pane.  ERROR reveals MESSAGE over the
content, because the card has no banner row."
  :render
  (let ((content-rows (or rows 1)))
    (etaf-view
     (box :position 'absolute :left '(ch 0) :top '(lh 0)
          :width 'stretch :height 'stretch :z-index 1 :overflow 'hidden
          :background-color (etaf-ncm-color :bg)
          :padding (if tile
                       (list '(lh 1) (list 'ch etaf-ncm-layout-tile-pad-columns)
                             '(lh 1) (list 'ch etaf-ncm-layout-tile-pad-columns))
                     (list '(lh 1) (list 'ch etaf-ncm-layout-card-pad-columns)
                           '(lh 1) (list 'ch etaf-ncm-layout-card-pad-columns)))
       (flex :flex-direction 'column :width 'stretch :height 'stretch
             :gap '((lh 0) (px 0)) :min-height '(lh 0)
         (etaf-ncm--view-tile-head
          :if tile :title title :artist artist :liked liked :on-like on-like)
         (etaf-ncm--view-card-head
          :if (not tile) :title title :artist artist :album album :cover cover
          :liked liked :on-like on-like :on-cover on-cover)
         (box :width 'stretch :height '(lh 1) :flex-shrink 0)
         (box :position 'relative :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
              :min-height '(lh 0) :overflow 'hidden
           (box :position 'absolute :left '(ch 0) :top '(lh 0)
                :width 'stretch :height 'stretch :overflow 'hidden
                :visibility (if (etaf-value pane-list) 'visible 'hidden)
             (etaf-ncm--view-list
              :model model :compact t :selection selection
              :keys list-keys :direction list-direction :on-focus on-list-focus
              :on-press on-press :on-action on-action))
           (box :position 'absolute :left '(ch 0) :top '(lh 0)
                :width 'stretch :height 'stretch :overflow 'hidden
                :visibility (if (etaf-value lyrics) 'visible 'hidden)
             (etaf-ncm--view-lyric-list :projection projection :rows content-rows))
           (box :position 'absolute :left '(ch 0) :top '(lh 0)
                :width 'stretch :height 'stretch :overflow 'hidden
                :visibility (if (etaf-value queue) 'visible 'hidden)
             (etaf-ncm--view-queue
              :bare t :projection queue-projection :rows content-rows
              :keys queue-keys :direction queue-direction :on-jump on-jump))
           (box :position 'absolute :z-index 3 :left '(ch 0) :top '(lh 0)
                :width 'stretch :height '(lh 2) :overflow 'hidden
                :visibility (if error 'visible 'hidden)
                :padding '((lh 0) (ch 1))
                :background-color (etaf-ncm-color :danger-bg)
                :color (etaf-ncm-color :danger)
             (box :height 'stretch :overflow 'hidden :wrap-mode 'word
               (text (expr (or (etaf-ncm--reactive-text message) ""))))))
         (box :width 'stretch :height '(lh 1) :flex-shrink 0)
         (etaf-ncm--view-card-tabs
          :if (not tile)
          :pane-list pane-list :section section
          :on-library on-library :on-aside on-aside)
         (box :if (not tile) :width 'stretch :height '(lh 1) :flex-shrink 0)
         (etaf-ncm--view-progress :if (not tile) :elapsed elapsed :duration duration
                                  :on-seek on-seek)
         (etaf-ncm--view-transport
          :compact t :repeat-control nil :playing playing
          :on-previous on-previous :on-toggle on-toggle :on-next on-next))))))

;;; ---------------------------------------------------------------------------
;;; The full-page now-playing view
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm-now-bars 22
  "Spectral columns the now-playing page draws.")

(defconst etaf-ncm-now-bar-rows 4
  "Text rows one spectrum occupies.
A spacer row follows it, because block glyphs are taller than a text row and
would otherwise touch the progress line.")

(defconst etaf-ncm--now-band-max 84
  "Widest picture band, in cells, a wide page gives the cover.")

(defconst etaf-ncm--now-band-max-rows 16
  "Tallest picture band, in rows, a stacked page gives the cover.")

(defconst etaf-ncm--now-panel-min 12
  "Rows a stacked page keeps for the panel under the picture.")

(defconst etaf-ncm--now-content-max 54
  "Widest the page's track column grows, so a huge window stays a page.")

(defconst etaf-ncm--now-glyphs
  [?\s ?▁ ?▂ ?▃ ?▄ ?▅ ?▆ ?▇ ?█]
  "Eighth blocks the spectrum grows through, lowest first.")

(defun etaf-ncm--now-bars-text (levels rows &optional width)
  "Return LEVELS as ROWS lines of eighth-block bars, one gap column apart.
A level is a height from nothing to ROWS whole rows: each finished row is a
full block, and the row the level stops in shows its fraction, so silence
paints nothing instead of a full bar.

WIDTH fills the band: the bars are resampled to `(width + 1) / 2' of them, so
the meter runs from the elapsed time to the duration instead of stopping short
and leaving the right end empty."
  (let* ((count (if (and width (> width 1)) (max 1 (/ (1+ width) 2)) (length levels)))
         (levels (if (and (listp levels) (> (length levels) 0))
                     (cl-loop for index below count
                              collect (nth (min (1- (length levels))
                                                (floor (* index (length levels)) count))
                                           levels))
                   (make-list count 0)))
         (cells (mapcar (lambda (level)
                          ;; One eighth of a row at silence: the band keeps its
                          ;; place on the page instead of appearing when the
                          ;; music starts and pushing the words up.
                          (max 1 (round (* (max 0 (min 1 level)) rows 8))))
                        levels)))
    (mapconcat
     (lambda (row)
       (let ((from-bottom (- rows 1 row)))
         (mapconcat
          (lambda (cell)
            (let ((whole (/ cell 8))
                  (part (% cell 8)))
              (cond ((< from-bottom whole) "█")
                    ((= from-bottom whole)
                     ;; `aref' on the glyph vector returns a character
                     ;; code point, and `mapconcat' needs a string.
                     (if (> part 0)
                         (char-to-string (aref etaf-ncm--now-glyphs part))
                       " "))
                    (t " "))))
          cells " ")))
     (number-sequence 0 (1- rows)) "\n")))

(defconst etaf-ncm-now-modes '(auto immersive split)
  "The page designs: `auto' picks one per window, `immersive' is a poster with
the controls under it, `split' gives the picture and the text one half each.")

(defconst etaf-ncm-now-min-hero 8
  "Fewest rows the picture keeps on a stacked page.
The artwork is the page's subject; a block of words that grew until the picture
was a sliver read as a list with a picture behind it.  Eight rows is where the
cover still reads as a picture.")

(defconst etaf-ncm-now-bottom-margin 1
  "Rows kept clear under the page's content.
The list page keeps the same margin, so the two pages end the same way at any
size.  It is a margin, not a size: the parts decide how tall the page is and
this stays free under them.")

(defun etaf-ncm-now-geometry (columns rows char-width line-height &optional mode spectrum lyric-lines)
  "Return the page's cell geometry for a COLUMNS by ROWS region.
MODE is `auto', `immersive' or `split' (see `etaf-ncm-now-modes') and SPECTRUM,
when non-nil, is the bar text the page has to draw; without it the bars take no
rows, because a block of empty lines under the transport is what a stopped
player looked like.  A wide
window puts the text beside the picture; a narrow or short one stacks them.
The returned plist carries the picture band (`:hero-columns', `:hero-rows'),
the text block (`:panel-left', `:panel-top', `:panel-columns', `:panel-rows',
`:content-columns') and the square the sharp cover keeps (`:art-columns',
`:art-rows', `:art-left', `:art-top')."
  (let* ((columns (max 24 (or columns 0)))
         (rows (max 12 (or rows 0)))
         (char-width (max 1 (or char-width 1)))
         (line-height (max 1 (or line-height 1)))
         (mode (if (memq mode etaf-ncm-now-modes) mode 'auto))
         (wide (and (>= columns 96) (>= rows 22)))
         ;; `auto' splits whenever there is a wide window to split: the picture
         ;; on one side and the text on the other is the design that reads
         ;; best; a narrow page becomes a poster instead.
         ;; A wide page keeps one picture across the window and lays the text
         ;; on its right half, so the artwork runs behind the text instead of
         ;; stopping at a pane edge.
         ;; `auto' opens the split design, where the artwork and the text each
         ;; get a full half.  `immersive' is the poster: one picture across the
         ;; whole page with the text block floating over its faded side.
         (immersive (eq mode 'immersive))
         (half (round (/ columns 2.0)))
         (panel-columns (cond ((not wide) columns)
                              ;; The poster's block is only as wide as its text,
                              ;; so the artwork stays visible around it.
                              ;; The poster's block floats over the picture, so
                              ;; it takes a little over half the page: pressed to
                              ;; one edge it read as a pane with a picture behind
                              ;; it instead of a poster.
                              (immersive (max 26 (min (- columns 8)
                                                      (+ etaf-ncm--now-content-max 8))))
                              (t (- columns half))))
         (hero-columns (cond (immersive columns)
                             (wide half)
                             (t columns)))
         ;; A stacked page gives the controls a fixed slice and leaves the rest
         ;; to the picture: the block needs ten rows for its header, track,
         ;; progress and transport, and anything more is padding nobody reads.
         ;; A window too short for a stack of its own keeps the picture across
         ;; the whole page and floats one row of controls at the bottom, so the
         ;; artwork is as large as the space allows instead of the sliver a
         ;; three-row block would leave it.
         (tiny (and (not wide) (< rows 16)))
         ;; A stacked page shows both halves: the picture takes what the text
         ;; does not need, and the text never grows past its own parts.  Giving
         ;; the text a fixed slice and the rest to the picture left the picture
         ;; a sliver on a tall window, which reads as a dark band on top.
         ;; A stacked page gives the picture its share first, then the text
         ;; gets exactly the rows its own parts need: budgeting the text and
         ;; letting the layout round it off is what left a band of empty
         ;; surface under the transport.
         ;; The picture keeps its floor and the block takes the rest up to what
         ;; its own parts need: no share of the window, no percentage, so every
         ;; size gets the same rule and a tall window grows the words only until
         ;; the lyric cap instead of starving the artwork.
         (panel-max (- rows etaf-ncm-now-min-hero etaf-ncm-now-bottom-margin))
         ;; One query decides both the height and the parts.  Asking twice with
         ;; different row counts made them disagree: the budget was measured with
         ;; the bars in, then the parts were measured without them, so the block
         ;; kept five rows it never drew — blank lines that grew with the window.
         (text-parts (etaf-ncm-now-sections panel-max nil spectrum lyric-lines))
         (text-budget (max 6 (min panel-max (plist-get text-parts :rows))))
         ;; The block takes the share the text was budgeted, and its parts
         ;; centre inside it.  Sizing the block by the parts instead made a
         ;; short block disagree with itself: five rows reported that it held a
         ;; track, then refused to draw it, because a track asks for six.
         ;; Whatever the design, the content ends the same margin above the
         ;; bottom edge: the wide page gives that row up from its pane, the
         ;; stacked one from the picture.
         (panel-rows (cond (wide (- rows etaf-ncm-now-bottom-margin))
                           ;; A floating bar still needs the clear row above it
                           ;; and the transport under it.
                           (tiny 2)
                           (t text-budget)))
         ;; One clear row under the block, the same bottom margin the list page
         ;; keeps: two rows read as leftover space.
         (hero-rows (cond (tiny (- rows panel-rows))
                          ((or immersive wide) rows)
                          (t (- rows panel-rows etaf-ncm-now-bottom-margin))))
         (panel-top (cond (wide 0)
                          (tiny (1- rows))
                          (t (- rows panel-rows))))
         ;; `immersive' keeps the picture across the page but gives the sharp
         ;; cover only the free left side, so the text column beside it never
         ;; covers the artwork; `split' sizes the cover to its own pane.
         ;; The poster's text block floats over the picture, so it may only be
         ;; as tall as its parts need and never taller than fourteen rows: a
         ;; block that grew with the window covered the artwork and read as a
         ;; pane with a picture behind it instead of a poster.  On a small window
         ;; it drops the lyric: the picture is the page there, and words crowded
         ;; into the middle of it read as neither.
         (poster-small (or (< rows 26) (< columns 60)))

         (art-width (if immersive (- hero-columns panel-columns 8) hero-columns))
         (art-height (if (and immersive (not wide)) panel-top hero-rows))
         ;; Whole cells, one in from every edge of the band: the cover keeps a
         ;; margin that stays the same at any size, instead of a share of it.
         (art-pixels (round (* (min (- art-width 2)
                                    (/ (* (- art-height 2) line-height) char-width))
                             char-width)))
         ;; A poster on a small window leaves the rectangle empty so the cover
         ;; centres on the whole picture instead of landing in a corner.
         (art-columns (if poster-small 0
                        (max 6 (min (- art-width 4) (round (/ art-pixels char-width))))))
         (art-rows (if poster-small 0
                     (max 4 (min (- art-height 2) (round (/ art-pixels line-height)))))))
    (list :mode mode
          ;; The parts are measured from the block's own height, so the two can
          ;; never disagree about how many rows exist.
          ;; The parts are measured from the height the block actually paints,
          ;; so the two can never disagree about how many rows exist.  The
          ;; poster's block is the full height of the page now, and on a small
          ;; window it still drops the lyric.
          :sections (etaf-ncm-now-sections panel-rows
                                           (if (and immersive poster-small) 0 nil)
                                           spectrum lyric-lines)
          :floating (or immersive tiny)
          :stacked (not (or wide tiny))
          :hero-columns hero-columns :hero-rows (max 8 hero-rows)
          ;; The poster's block keeps a margin on the right: pressed against
          ;; the edge it reads as a panel bolted on rather than floating over
          ;; the picture.
          ;; The poster's block meets the right edge: a gap there read as a
          ;; pane that had not finished drawing.
          :panel-left (cond (immersive (- columns panel-columns))
                            (wide (- columns half))
                            (t 0))
          ;; The poster's block keeps the right of the page from edge to edge,
          ;; as the split design does: a floating block left a band of picture
          ;; above and below it, and at any size that read as a gap in the pane
          ;; rather than a design.
          :panel-top (if immersive 0 panel-top)
          :panel-columns panel-columns
          :panel-rows (max 1 (if immersive rows panel-rows))
          :content-columns (max 16 (min etaf-ncm--now-content-max
                                        (- panel-columns 4)))
          :art-columns art-columns :art-rows art-rows
          :art-left (max 1 (round (/ (- art-width art-columns) 2)))
          :art-top (max 0 (round (/ (- art-height art-rows) 2)))
          :fade (if (and wide (not immersive)) 'right 'right))))

(defun etaf-ncm-now-sections (rows &optional max-lyrics spectrum lyric-lines)
  "Return the playing page's parts for a window ROWS tall.
MAX-LYRICS caps the lyric block; zero drops it, which is what a poster on a
small window wants: the picture, the track and the controls, without words
crowded into the middle.  LYRIC-LINES answers whether the song has words at all.
SPECTRUM is accepted for callers that still measure with it and does not change
the parts: the meter keeps its rows from the start, so the words are never laid
out over its place and then pushed up.

The page adds a part only at the height where it reads: a short window is the
poster and one row of transport buttons, and each further part — the track, the
artist, the progress line, the spectrum and the lyric — appears at its own
height.  `:rows' is the block all of them occupy, so the page never claims rows
the window does not have."
  (let* ((header (>= rows 22))
         ;; A page tall enough for a line of text names the song: the track is
         ;; the one part a reader looks for, so it comes before the header and
         ;; the artist, not after them.
         (title (if (>= rows 6) 1 0))
         (artist (>= rows 14))
         ;; The progress line comes before the lyric: it tells a reader where the
         ;; song is, which the words alone cannot.  A block of seven rows holds
         ;; the track, the progress and the transport.
         (progress (>= rows 7))
         ;; The transport is one row in a compact bar and two in a full one, and
         ;; the page budgets what it draws.  Counting one row for a two-row bar
         ;; left a row of empty surface under the buttons.
         (transport-rows (if (>= rows 22) 2 1))
         ;; The bars claim rows only when there is a spectrum to draw into them;
         ;; the value stays the row count, because the block adds it up.
         ;; The meter keeps its rows from the start.  Taking them only once the
         ;; first sample arrived made the page lay the words out over the meter's
         ;; place and then shove them up when the music began.
         (_spectrum spectrum)
         (bars (when (and (>= rows 28) etaf-ncm-now-bar-rows)
                 etaf-ncm-now-bar-rows))
         ;; One clear row above the block, then each part.  The row carrying the
         ;; way back to the player is always drawn, so it is always budgeted;
         ;; only the "正在播放" label beside it waits for a taller page.  A second
         ;; row below the block only spent a line the lyric could have used.
         (fixed (+ 1                    ;; the clear row above the block
                    (if header 2 0)     ;; the way back, and a clear row under it
                    title
                    (if artist 1 0)
                    ;; The progress line, its spacer and the transport.
                    (if progress (+ 2 transport-rows) 1)
                    (if bars (+ bars 1) 0)))
         ;; ROWS is what the block may use, so the parts must never claim more
         ;; than that — and `:rows' is exactly what they claim, which is what
         ;; lets the page end one clear row above the bottom edge instead of
         ;; leaving rows it never fills.  Two lines already read as a lyric: the
         ;; one being sung and the one before it.
         (spare (- rows fixed))
         (room (if (and max-lyrics (<= max-lyrics 0)) 0 spare))
         ;; A song with no words leaves no block; a song with words takes every
         ;; row the page has for them.  LYRIC-LINES only answers "are there
         ;; words": it is the projection of the visible window, not the length of
         ;; the song, so using it as a cap showed ten lines in a fifty-row page.
         (room (if (and lyric-lines (<= lyric-lines 0)) 0 room))
         (lyrics (cond ((< room 2) 0)
                       (max-lyrics (min room max-lyrics))
                       (t room))))
    (list :header header :title title :artist artist :progress progress
          :bars bars :lyrics lyrics
          :rows (+ fixed lyrics))))

(etaf-define-component etaf-ncm--view-now
    (&key title artist album cover hero spectrum accent panel playing liked
          elapsed duration projection geometry sections
          on-back on-toggle on-next on-previous on-like on-seek)
  "Render the whole window as the playing song.
The picture is one frame built by `etaf-ncm-hero-file': the cover blurred,
a sharp copy of itself over the part the text does not cover, and a fade into
the panel colour on the edge where the text column starts.  In `immersive' the
picture covers the window and the text column lies over its faded edge; in
`split' the two share the window.  Text always sits on the panel colour, so no
glyph paints a box of its own, and the progress bar tracks that same colour, so
it paints no rail.  GEOMETRY comes from `etaf-ncm-now-geometry' and SECTIONS
from `etaf-ncm-now-sections'."
  :render
  (let* ((panel-color panel)
         (stacked (plist-get geometry :stacked))
         (hero-columns (plist-get geometry :hero-columns))
         (hero-rows (plist-get geometry :hero-rows))
         (panel-rows (plist-get geometry :panel-rows))
         (content (plist-get geometry :content-columns))
         (immersive (eq (plist-get geometry :mode) 'immersive))
         (bars (plist-get sections :bars))
         (lyrics (plist-get sections :lyrics))
         ;; One picture fills the page.  The band is the panel colour until
         ;; the backdrop lands, because a raw cover stretched over the band
         ;; would read as a crop of the artwork instead of a backdrop.
         (picture hero)
         (band
          (etaf-view
           (flex :width (list 'ch hero-columns)
                 :height (list 'lh hero-rows) :flex-shrink 0
                 :overflow 'hidden :bgcolor panel-color
             (image :if (and picture (file-readable-p picture))
                    :src picture :columns hero-columns :rows hero-rows))))
         (column
          (etaf-view
           (flex :flex-direction 'column :width (list 'ch content)
                 :height 'stretch :overflow 'hidden
             ;; The way back sits on the title row, so a short page that drops
             ;; the header still has it.
             ;; The label centres on the whole row and the way back sits over
             ;; its left end.  Laying the two out side by side pushed the label
             ;; half a control to the right, so it never lined up with the track
             ;; under it.
             (box :position 'relative :height '(lh 1) :width 'stretch
                  :flex-shrink 0
               (box :position 'absolute :left '(ch 0) :top '(lh 0)
                    :width '(ch 7) :height '(lh 1)
                    :color (etaf-ncm-color :dim)
                    :ref 'ncm-now-back :role 'button :tab-index 0
                    :aria-label "返回播放器" :help-echo "返回播放器 (Esc / o)"
                    :on-press on-back :on-dismiss on-back
                 (text (expr "← 返回")))
               (box :if (plist-get sections :header)
                    :height '(lh 1) :width 'stretch :text-align 'center
                    :color (etaf-ncm-color :muted)
                 (text (expr "正在播放"))))
             (flex :if (plist-get sections :header) :height '(lh 1) :flex-shrink 0)
             (box :if (plist-get sections :title)
                  :height (list 'lh (plist-get sections :title))
                  :flex-shrink 0
                  :width 'stretch :color (etaf-ncm-color :ink)
                  :text-align 'center
                  :font-weight 'bold :overflow 'hidden :ref 'ncm-now-title
               (text (expr (or (etaf-ncm--reactive-text title) "未在播放"))))
             (box :if (plist-get sections :artist)
                   :height '(lh 1) :flex-shrink 0 :width 'stretch :text-align 'center
                   :color (etaf-ncm-color :muted) :overflow 'hidden
                   :ref 'ncm-now-source
               (text (expr (string-trim
                            (concat (or (etaf-ncm--reactive-text artist) "")
                                    " · "
                                    (or (etaf-ncm--reactive-text album) ""))
                            " ·"))))
             (flex :if (> lyrics 1) :height (list 'lh lyrics) :flex-grow 1
                   :width 'stretch :overflow 'hidden
               (etaf-ncm--view-lyric-list :projection projection :rows lyrics
                                          :columns content))
             (flex :if bars :height (list 'lh bars) :width 'stretch :flex-shrink 0
                   :color accent :overflow 'hidden
               (text :ref 'ncm-now-bars
                     (expr (etaf-ncm--now-bars-text
                            (etaf-ncm--reactive-text spectrum) bars content))))
             (flex :if bars :height '(lh 1))
             ;; The progress line keeps a clear row above it: the bar reads as a
             ;; separate line from the words, and `etaf-ncm-now-sections' counts
             ;; that row in the three it budgets for progress and transport.
             (flex :if (plist-get sections :progress) :height '(lh 1) :flex-shrink 0)
             (etaf-ncm--view-progress :visible (plist-get sections :progress)
                                      :prefix "ncm-now" :track-color panel-color
                                      :elapsed elapsed :duration duration
                                      :on-seek on-seek)
             (etaf-ncm--view-transport :compact (plist-get sections :compact)
                                       :playing playing :repeat nil :liked liked
                                       :on-previous on-previous :on-toggle on-toggle
                                       :on-next on-next :on-repeat #'ignore
                                       :on-like on-like))))
         (panel-node
          (etaf-view
           (flex :flex-direction 'column
                 ;; `immersive' lays the column over the picture, so the page
                 ;; keeps one backdrop from edge to edge; `split' gives it the
                 ;; other half of the window in flow.
                 :position (if (or immersive (plist-get geometry :floating))
                               'absolute 'static)
                 ;; `immersive' keeps the picture behind everything and puts
                 ;; the text on a narrow block at the bottom centre, so the
                 ;; artwork shows on both sides of it instead of under a band
                 ;; across the whole page.
                 :left (if (or immersive (plist-get geometry :floating))
                           (list 'ch (plist-get geometry :panel-left)))
                 :top (if (or immersive (plist-get geometry :floating))
                          (list 'lh (plist-get geometry :panel-top)))
                 :width (list 'ch (plist-get geometry :panel-columns))
                 :height (list 'lh panel-rows)
                 :flex-grow (if (or immersive (plist-get geometry :floating)) 0 1)
                 :flex-basis '(px 0)
                 :flex-shrink 0 :min-width '(px 0)
                 :overflow 'hidden :align-items 'center
                 ;; One clear row above the block and one under the transport:
                 ;; a second row below it reads as leftover space.
                 :gap '((lh 0) (px 3))
                 :padding '((lh 1) (ch 0) (lh 0) (ch 0))
                 ;; The immersive page lets the picture show under the text:
                 ;; no panel colour, only a darker filter over what is already
                 ;; there, so the text sits on the artwork instead of on a
                 ;; band.  The split page gives the text its own pane.
                 ;; No surface behind the text: the picture shows through and
                 ;; only each row of glyphs carries the frame's own background,
                 ;; which is what the first prototype looked like.
                 ;; The text sits on the cover's own colour, not on the panel
                 ;; grey: the two halves then read as one picture instead of a
                 ;; black slab beside the artwork.
                 :bgcolor (etaf-ncm--now-surface accent panel-color)
             (expr column)))))
    (etaf-view
      (flex :ref 'ncm-now
            :flex-direction (if stacked 'column 'row)
            :width 'stretch
            ;; `immersive' lays the band over the whole page and the panel on
            ;; top of it, so the page is exactly the window; only a stacked
            ;; `split' page stacks two bands.
            ;; The page fills the window: the picture, the block and the margin
            ;; under it add up to every row.  A page one row short left that row
            ;; on the frame's own background, which reads as a black band above
            ;; the minibuffer.
            :height (list 'lh (if stacked
                                  (+ hero-rows panel-rows etaf-ncm-now-bottom-margin)
                                (max hero-rows panel-rows)))
            ;; The page floor is the text block's colour: a row the layout
            ;; rounds off then shows the same surface instead of a dark cell in
            ;; the bottom corner.
            :bgcolor (etaf-ncm--now-surface accent panel-color)
            :role 'dialog :aria-label "正在播放"
            :tab-index 0 :on-dismiss on-back
        (expr band)
        (expr panel-node)))))

(provide 'etaf-ncm-views)
;;; etaf-ncm-views.el ends here
