;;; etaf-reader-navigation.el --- Library and reading navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; User-facing library queries, bounded navigation lists, reading preferences
;; and return-to-position history. Views consume cached session values only.

;;; Code:
(require 'etaf-reader-model)

(defun etaf-reader--preference-values (session)
  "Return SESSION's serializable reading preferences."
  (let ((metrics (etaf-reader--read session :metrics)))
    (list :theme (symbol-name (etaf-reader--read session :theme))
          :mode (symbol-name (etaf-reader--read session :mode))
          :density (symbol-name (etaf-reader--read session :density))
          :columns (if (plist-get metrics :manual)
                       (or (plist-get metrics :requested-columns)
                           (plist-get metrics :columns)) 0))))

(defun etaf-reader--apply-preferences (session options)
  "Apply validated OPTIONS to SESSION without storage access."
  (etaf-batch
    (dolist (key '(:theme :mode :density))
      (when (plist-member options key)
        (etaf-reader--write session key (plist-get options key))))
    (when (plist-member options :columns)
      (let ((metrics (copy-sequence (etaf-reader--read session :metrics)))
            (columns (plist-get options :columns)))
        (setq metrics (plist-put metrics :manual (not (eq columns 'auto))))
        (unless (eq columns 'auto)
          (setq metrics (plist-put metrics :columns columns))
          (setq metrics (plist-put metrics :requested-columns columns)))
        (etaf-reader--write session :metrics metrics)))
    (etaf-reader-sync-metrics session)
    (etaf-reader-reflow session)))

(defun etaf-reader-configure (session &rest options)
  "Set and persist reading OPTIONS for SESSION.
Accept :theme dark/light/sepia, :mode page/scroll, :density compact/comfortable,
and :columns auto or an integer from 24 through 72. Validate all options before
changing anything. Return the saved preference plist."
  (unless (and (proper-list-p options) (zerop (% (length options) 2)))
    (signal 'etaf-reader-error '("设置必须是成对的选项和值")))
  (cl-loop for (key value) on options by #'cddr
           unless (pcase key
                    (:theme (memq value '(dark light sepia)))
                    (:mode (memq value '(page scroll)))
                    (:density (memq value '(compact comfortable)))
                    (:columns (or (eq value 'auto)
                                  (and (integerp value) (<= 24 value 72)))))
           do (signal 'etaf-reader-error (list "无效阅读设置" key value)))
  (etaf-reader--apply-preferences session options)
  (let ((preferences (etaf-reader--preference-values session))
        (etaf-reader-store-file (plist-get session :store-file)))
    (etaf-reader-store-put-preferences preferences)
    preferences))

(defun etaf-reader--restore-preferences (session)
  "Restore saved preferences before mounting SESSION."
  (when-let* ((saved (etaf-reader-store-preferences)))
    (let (options)
      (dolist (key '(:theme :mode :density))
        (when-let* ((value (plist-get saved key)))
          (setq options (plist-put options key (intern value)))))
      (let ((columns (or (plist-get saved :columns) 0)))
        (setq options (plist-put options :columns (if (> columns 0) columns 'auto))))
      (etaf-reader--apply-preferences session options))))

(defun etaf-reader-filter-library (session query &optional filter sort)
  "Filter SESSION's library by QUERY and optional FILTER and SORT.
FILTER is all, reading, unread or finished. SORT is recent, title or author.
A changed query resets the displayed library page. Return matching books."
  (unless (and (stringp query) (memq filter '(nil all reading unread finished))
               (memq sort '(nil recent title author)))
    (signal 'etaf-reader-error '("无效书库筛选条件")))
  (etaf-batch
    (etaf-reader--write session :shelf-query (string-trim query))
    (when filter (etaf-reader--write session :filter filter))
    (when sort (etaf-reader--write session :shelf-sort sort))
    (etaf-reader--write session :shelf-page 0))
  (etaf-reader-books session))

(defconst etaf-reader--cell-columns 12
  "Character columns of one shelf cell.")

(defconst etaf-reader--cell-gap 2
  "Character columns between two shelf cells.")

(defun etaf-reader--shelf-grid (session)
  "Return (:columns :rows :page-size) of SESSION's shelf grid.
The grid follows the mounted window: wider windows fit more cells per shelf,
and the page size is exactly the cells that fit, so a page never leaves a
hole. Sidebar and detail width come from what the shelf actually shows."
  (let* ((metrics (etaf-reader--read session :metrics))
         (shown-width (etaf-reader--read session :window-columns))
         (shown-height (etaf-reader--read session :window-rows))
         (width (or (and shown-width (> shown-width 0) shown-width)
                    (+ (* (or (plist-get metrics :columns) 40)
                          (or (plist-get metrics :spread) 1))
                       8)))
         (height (or (and shown-height (> shown-height 0) shown-height)
                     (plist-get metrics :rows) 30))
         (sidebar (if (etaf-reader--read session :sidebar) 27 0))
         (detail (if (and (etaf-reader--read session :detail) (>= width 130)) 39 0))
         (content (max 24 (- width sidebar detail 4)))
         (columns (max 2 (min 12 (/ (+ content etaf-reader--cell-gap)
                                    (+ etaf-reader--cell-columns etaf-reader--cell-gap)))))
         (rows (max 1 (min 4 (/ (- height 8) 14)))))
    (list :columns columns :rows rows :page-size (max 1 (* columns rows))
          :list-size (max 3 (- height 10)))))

(defun etaf-reader-library-page (session)
  "Return SESSION's library page as :items, :index, :pages and :total.
The zero-based page index is clamped to the current filtered result, and the
page size is the shelf grid's capacity for the current window."
  (let* ((books (etaf-reader-books session))
         (grid (etaf-reader--shelf-grid session))
         (size (or (if (eq (etaf-reader--read session :shelf-view) 'list)
                       (plist-get grid :list-size)
                     (plist-get grid :page-size))
                   18))
         (pages (max 1 (ceiling (length books) size)))
         (page (min (1- pages) (max 0 (etaf-reader--read session :shelf-page)))))
    (list :items (seq-subseq books (* page size) (min (length books) (* (1+ page) size)))
          :index page :pages pages :total (length books))))

(defun etaf-reader-page-library (session delta)
  "Move SESSION's library by DELTA pages and return its resulting page."
  (let* ((page (etaf-reader-library-page session))
         (next (max 0 (min (1- (plist-get page :pages))
                           (+ (plist-get page :index) delta)))))
    (etaf-reader--write session :shelf-page next)
    (etaf-reader-library-page session)))

(defun etaf-reader--library-facets (session)
  "Return the shelf sidebar's counts for SESSION's whole library.
Counting runs over the cached rows, so it never touches the store during a
publication. Formats and authors come sorted by count, then name."
  (let ((books (etaf-reader--read session :books))
        (states (etaf-reader--read session :states))
        (total 0) (reading 0) (unread 0) (finished 0)
        (formats (make-hash-table :test #'equal))
        (authors (make-hash-table :test #'equal)))
    (dolist (book books)
      (setq total (1+ total))
      (let* ((state (and (hash-table-p states) (gethash (plist-get book :id) states)))
             (opened (or (plist-get state :last_read) 0))
             (percent (or (plist-get state :percent) 0))
             (format (upcase (or (plist-get book :format) "")))
             (author (or (plist-get book :author) "")))
        (cond ((>= percent 99.9) (setq finished (1+ finished)))
              ((> opened 0) (setq reading (1+ reading)))
              (t (setq unread (1+ unread))))
        (unless (string-empty-p format)
          (puthash format (1+ (gethash format formats 0)) formats))
        (unless (string-empty-p author)
          (puthash author (1+ (gethash author authors 0)) authors))))
    (list :total total :reading reading :unread unread :finished finished
          :formats (etaf-reader--sorted-counts formats)
          :authors (etaf-reader--sorted-counts authors))))

(defun etaf-reader--sorted-counts (table)
  "Return TABLE as (NAME . COUNT) sorted by count, then by name."
  (let (rows)
    (maphash (lambda (name count) (push (cons name count) rows)) table)
    (sort rows (lambda (a b)
                 (if (= (cdr a) (cdr b))
                     (string-lessp (car a) (car b))
                   (> (cdr a) (cdr b)))))))

(defun etaf-reader--shelf-cursor-index (session)
  "Return the position of SESSION's shelf cursor within the shown page."
  (let* ((page (etaf-reader-library-page session))
         (items (plist-get page :items))
         (cursor (etaf-reader--read session :shelf-cursor))
         (index (and cursor (cl-position cursor items
                                         :key (lambda (book) (plist-get book :id))
                                         :test #'equal))))
    (cond (index index)
          ((null items) nil)
          (t 0))))

(defun etaf-reader--set-shelf-cursor (session index)
  "Put SESSION's shelf cursor on the book at INDEX of the shown page.
The detail panel previews the cursor's annotations, so they are read here,
outside the render pass, and cached for the View."
  (let* ((items (plist-get (etaf-reader-library-page session) :items))
         (book (nth (max 0 (min (1- (length items)) index)) items))
         (etaf-reader-store-file (plist-get session :store-file)))
    (etaf-batch
      (etaf-reader--write session :shelf-cursor (and book (plist-get book :id)))
      (etaf-reader--write session :shelf-notes
                          (and book (etaf-reader-store-annotations
                                     (plist-get book :id)))))
    book))

(defun etaf-reader--shelf-move (session dx dy)
  "Move SESSION's shelf cursor by DX cells and DY shelves."
  (let* ((grid (etaf-reader--shelf-grid session))
         (columns (max 1 (plist-get grid :columns)))
         (page (etaf-reader-library-page session))
         (items (plist-get page :items))
         (index (or (etaf-reader--shelf-cursor-index session) 0))
         (target (+ index (* dx 1) (* dy columns))))
    (cond
     ((null items) nil)
     ((and (< target 0) (or (< dy 0) (< dx 0)))
      (etaf-reader-page-library session -1)
      (let ((moved (plist-get (etaf-reader-library-page session) :items)))
        (etaf-reader--set-shelf-cursor session (1- (length moved)))))
     ((>= target (length items))
      (etaf-reader-page-library session 1)
      (etaf-reader--set-shelf-cursor session 0))
     (t (etaf-reader--set-shelf-cursor session target)))))

(defun etaf-reader--press-book (session book)
  "Select BOOK on the shelf, or open it when it is already selected.
A second press opens, which is the keyboard and mouse equivalent of the
double click the design calls for without counting clicks."
  (if (equal (plist-get book :id) (etaf-reader--read session :shelf-cursor))
      (etaf-reader-open-book session book)
    (let ((etaf-reader-store-file (plist-get session :store-file)))
      (etaf-batch
        (etaf-reader--write session :shelf-cursor (plist-get book :id))
        (etaf-reader--write session :shelf-notes
                            (etaf-reader-store-annotations (plist-get book :id)))))
    book))

(defun etaf-reader-set-facet (session kind value)
  "Narrow the shelf to books whose KIND equals VALUE.
KIND is `format' or `author'; VALUE nil clears that facet. The library page
returns to its first page so the change is visible."
  (unless (memq kind '(format author))
    (signal 'etaf-reader-error (list "未知分类" kind)))
  (etaf-batch
    (etaf-reader--write session (if (eq kind 'format) :facet-format :facet-author)
                        (and value (not (string-empty-p value)) value))
    (etaf-reader--write session :shelf-page 0))
  (etaf-reader-books session))

(defun etaf-reader--toggle-detail (session)
  "Show or hide SESSION's detail panel."
  (etaf-reader--write session :detail (not (etaf-reader--read session :detail))))

(defun etaf-reader--toggle-sidebar (session)
  "Show or hide SESSION's sidebar."
  (etaf-reader--write session :sidebar (not (etaf-reader--read session :sidebar))))

(defun etaf-reader-show-pane (session pane)
  "Show PANE in SESSION, or close it when nil or already open.
PANE is toc, notes, bookmarks, search, settings or help. Data is loaded before
publication; long lists are paged rather than clipped. Help requires a mounted
reader and opens the shared modal without replacing the navigation pane.
Nil also closes help."
  (unless (memq pane '(nil toc notes bookmarks search settings help))
    (signal 'etaf-reader-error '("未知阅读面板")))
  (when (and (memq pane '(toc notes bookmarks search))
             (null (etaf-reader--read session :book)))
    (signal 'etaf-reader-error '("请先打开一本书")))
  (let* ((buffer (plist-get session :buffer))
         (runtime (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer))))
    (if (eq pane 'help)
        (if runtime
            (etaf-help runtime)
          (signal 'etaf-reader-error '("请先打开阅读器再查看帮助")))
      (when (and (null pane) runtime) (etaf-help-close runtime))
      (let ((etaf-reader-store-file (plist-get session :store-file)))
        (etaf-batch
          (pcase pane
            ('notes
             (etaf-reader--write session :book-notes
                                 (etaf-reader-store-annotations
                                  (plist-get (etaf-reader--read session :book) :id))))
            ('bookmarks
             (etaf-reader--write session :bookmarks
                                 (etaf-reader-store-bookmarks
                                  (plist-get (etaf-reader--read session :book) :id)))))
          (etaf-reader--write session :pane-page
                              (if (eq pane 'toc)
                                  (/ (or (plist-get (etaf-reader--read session :chapter) :index) 0)
                                     (etaf-reader--pane-page-size session)) 0))
          (etaf-reader--write session :pane
                              (unless (eq pane (etaf-reader--read session :pane)) pane)))))))

(defun etaf-reader--remember-position (session)
  "Push SESSION's current reading position onto bounded navigation history."
  (when (etaf-reader--read session :chapter)
    (let* ((line (nth (etaf-reader--read session :line) (etaf-reader-lines session)))
           (location (cons (plist-get (etaf-reader--read session :chapter) :index)
                           (or (plist-get line :start) 0)))
           (history (plist-get session :history)))
      (unless (equal location (car history))
        (plist-put session :history (seq-take (cons location history) 100))))))

(defun etaf-reader-jump (session chapter offset)
  "Open CHAPTER at OFFSET and remember the previous position in SESSION."
  (etaf-reader--remember-position session)
  (etaf-batch
    (etaf-reader-open-chapter session chapter offset)
    (etaf-reader--write session :pane nil)))

(defun etaf-reader-jump-back (session)
  "Return SESSION to its position before the last navigation jump."
  (if-let* ((history (plist-get session :history)))
      (progn
        (plist-put session :history (cdr history))
        (etaf-batch
          (etaf-reader-open-chapter session (caar history) (cdar history))
          (etaf-reader--write session :pane nil)))
    (etaf-reader-message session "没有更早的跳转位置")))

(defun etaf-reader--pane-items (session)
  "Return the current navigation list as catalog List items."
  (pcase (etaf-reader--read session :pane)
    ('toc
     (mapcar (lambda (chapter)
               (list :key (plist-get chapter :idx)
                     :title (or (plist-get chapter :title) "未命名章节")
                     :description (format "第 %d 章" (1+ (plist-get chapter :idx)))))
             (etaf-reader--read session :chapters)))
    ('notes
     (mapcar (lambda (note)
               (list :key (plist-get note :id)
                     :title (truncate-string-to-width (or (plist-get note :quote) "") 44 nil nil "…")
                     :description (if (string-empty-p (or (plist-get note :note) ""))
                                      (format "第 %d 章 · %s" (1+ (plist-get note :chapter))
                                              (pcase (plist-get note :kind)
                                                ("wavy" "波浪线") ("underline" "下划线") (_ "划线")))
                                    (truncate-string-to-width (plist-get note :note) 44 nil nil "…"))))
             (etaf-reader--read session :book-notes)))
    ('bookmarks
     (mapcar (lambda (row)
               (list :key (plist-get row :id)
                     :title (format "第 %d 章" (1+ (plist-get row :chapter)))
                     :description (truncate-string-to-width (or (plist-get row :label) "") 44 nil nil "…")))
             (etaf-reader--read session :bookmarks)))
    ('search
     (cl-loop for match in (plist-get (etaf-reader--read session :search) :matches)
              for index from 0
              collect (list :key index
                            :title (format "第 %d 章 · 结果 %d" (1+ (plist-get match :chapter)) (1+ index))
                            :description (truncate-string-to-width (or (plist-get match :context) "") 44 nil nil "…"))))))

(defun etaf-reader--pane-page-size (session)
  "Return the bounded navigation list size for SESSION's viewport."
  (max 1 (min 4 (/ (max 0 (- (or (plist-get (etaf-reader--read session :metrics) :rows) 20) 8)) 3))))

(defun etaf-reader--step-pane (session delta)
  "Move the current navigation list by DELTA pages."
  (let* ((size (etaf-reader--pane-page-size session))
         (pages (max 1 (ceiling (length (etaf-reader--pane-items session)) size))))
    (etaf-reader--write session :pane-page
                        (max 0 (min (1- pages)
                                    (+ (etaf-reader--read session :pane-page) delta))))))

(defun etaf-reader--choose-pane-item (session key)
  "Activate navigation item KEY in SESSION."
  (pcase (etaf-reader--read session :pane)
    ('toc (etaf-reader-jump session key 0))
    ('notes
     (when-let* ((note (seq-find (lambda (row) (equal (plist-get row :id) key))
                                (etaf-reader--read session :book-notes))))
       (etaf-reader--remember-position session)
       (etaf-reader-goto-annotation session note)
       (etaf-reader-show-annotation-toolbar session key)))
    ('bookmarks
     (when-let* ((row (seq-find (lambda (item) (equal (plist-get item :id) key))
                               (etaf-reader--read session :bookmarks))))
       (etaf-reader-jump session (plist-get row :chapter) (plist-get row :offset))))
    ('search
     (etaf-reader--remember-position session)
     (etaf-batch
       (etaf-reader--write session :pane nil)
       (etaf-reader-goto-match session key)))))

(provide 'etaf-reader-navigation)
;;; etaf-reader-navigation.el ends here
