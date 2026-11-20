;;; etaf-reader-model.el --- Session state and reading logic -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A session is a plist of reactive refs that exists without any buffer, so
;; scripts and tests drive the same model the mounted application uses.  All
;; display values are read through `etaf-reader--read' during render, so
;; writing a ref repaints the mounted reader.
;;
;; Reading is line based: the current chapter's block text is wrapped into
;; lines once per (chapter, columns), and every position is a line index plus
;; a character offset inside that line.  Annotations anchor on
;; (chapter index, code point range) in the chapter's plain-text projection,
;; so they survive re-wrapping, font changes and window resizes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'etaf)
(require 'etaf-reader-theme)
(require 'etaf-reader-store)
(require 'etaf-reader-library)

(declare-function etaf-reader--line-content "etaf-reader-views" (session line theme))
(declare-function etaf-reader--restore-preferences "etaf-reader-navigation" (session))

(defcustom etaf-reader-font-size nil
  "Optional text size override (CSS pixels) for the reading column."
  :type '(choice (const :tag "Theme default" nil) integer)
  :group 'etaf-reader)

(defcustom etaf-reader-remember-positions t
  "Whether reading positions are stored and restored per book."
  :type 'boolean
  :group 'etaf-reader)

(defcustom etaf-reader-track-reading-time t
  "Whether the reader accumulates per-book reading time."
  :type 'boolean
  :group 'etaf-reader)

(defcustom etaf-reader-save-delay 2.0
  "Seconds of quiet before the reading position is written."
  :type 'number
  :group 'etaf-reader)

(defcustom etaf-reader-search-limit 200
  "Maximum matches collected by one in-book search."
  :type 'integer
  :group 'etaf-reader)

;;; ---------------------------------------------------------------------------
;;; Refs
;;; ---------------------------------------------------------------------------

(defun etaf-reader--ref (session key)
  "Return SESSION's reactive source named KEY."
  (plist-get session key))

(defun etaf-reader--read (session key)
  "Return SESSION's current value for KEY, tracked while rendering.
`:line' is a plain field: the page-turn fast path moves the visible window
through retained Hosts without an ordinary publication, so its authoritative
value must not be a reactive source."
  (if (eq key :line)
      (plist-get session :line)
    (etaf-value (etaf-reader--ref session key))))

(defun etaf-reader--write (session key value)
  "Publish VALUE as SESSION's value for KEY and return VALUE.
Writes to `:line' stay plain; use `etaf-reader-repaint' when the change needs
an ordinary publication (a chapter, a styled window or a reflow)."
  (if (eq key :line)
      (setf (plist-get session :line) value)
    (let ((ref (etaf-reader--ref session key)))
      (when ref
        (unless (equal (etaf-value ref) value)
          (etaf-set-value ref value)))))
  value)

(defun etaf-reader-repaint (session)
  "Repaint the mounted reader with an ordinary publication."
  (etaf-reader--write session :revision
                      (1+ (or (etaf-reader--read session :revision) 0))))

;;; ---------------------------------------------------------------------------
;;; Session
;;; ---------------------------------------------------------------------------

(cl-defun etaf-reader-create (&key parser theme)
  "Create a headless reader session and return it.
PARSER defaults to the `ebook-parse' backend; THEME defaults to
`etaf-reader-theme'."
  (let ((session (list
                  :parser (or parser etaf-reader-default-parser)
                  :store-file etaf-reader-store-file
                  :cache-directory etaf-reader-cache-directory
                  :history nil
                  :buffer nil
                  :view (etaf-ref 'shelf :name 'etaf-reader-view)
                  :message (etaf-ref nil :name 'etaf-reader-message)
                  :books (etaf-ref nil :name 'etaf-reader-books)
                  :states (etaf-ref nil :name 'etaf-reader-states)
                  :filter (etaf-ref 'all :name 'etaf-reader-filter)
                  :shelf-query (etaf-ref "" :name 'etaf-reader-shelf-query)
                  :shelf-sort (etaf-ref 'recent :name 'etaf-reader-shelf-sort)
                  :shelf-page (etaf-ref 0 :name 'etaf-reader-shelf-page)
                  :shelf-cursor (etaf-ref nil :name 'etaf-reader-shelf-cursor)
                  :facet-format (etaf-ref nil :name 'etaf-reader-facet-format)
                  :facet-author (etaf-ref nil :name 'etaf-reader-facet-author)
                  :shelf-notes (etaf-ref nil :name 'etaf-reader-shelf-notes)
                  :shelf-view (etaf-ref 'grid :name 'etaf-reader-shelf-view)
                  :detail (etaf-ref t :name 'etaf-reader-detail)
                  :sidebar (etaf-ref t :name 'etaf-reader-sidebar)
                  :pane-page (etaf-ref 0 :name 'etaf-reader-pane-page)
                  :bookmarks (etaf-ref nil :name 'etaf-reader-bookmarks)
                  :density (etaf-ref 'comfortable :name 'etaf-reader-density)
                  :book (etaf-ref nil :name 'etaf-reader-book)
                  :chapters (etaf-ref nil :name 'etaf-reader-chapters)
                  :chapter (etaf-ref nil :name 'etaf-reader-chapter)
                  :annotations (etaf-ref nil :name 'etaf-reader-annotations)
                  :book-notes (etaf-ref nil :name 'etaf-reader-book-notes)
                  :lines (etaf-ref nil :name 'etaf-reader-lines)
                  :line 0
                  :revision (etaf-ref 0 :name 'etaf-reader-revision)
                  :mode (etaf-ref 'page :name 'etaf-reader-mode)
                  :metrics (etaf-ref (list :columns 40 :rows 20 :spread 1
                                           :layout 'medium :mode 'page)
                                     :name 'etaf-reader-metrics)
                  :window-rows (etaf-ref 0 :name 'etaf-reader-window-rows)
                  :window-columns (etaf-ref 0 :name 'etaf-reader-window-columns)
                  :cursor (etaf-ref nil :name 'etaf-reader-cursor)
                  :selection (etaf-ref nil :name 'etaf-reader-selection)
                  :toolbar (etaf-ref nil :name 'etaf-reader-toolbar)
                  :pane (etaf-ref nil :name 'etaf-reader-pane)
                  :search (etaf-ref nil :name 'etaf-reader-search)
                  :theme (etaf-ref (or theme etaf-reader-theme)
                                   :name 'etaf-reader-theme)
                  :save-timer nil
                  :reading-start (float-time))))
    ;; One drag closure for the whole session: a fresh lambda per line per
    ;; render would replace every line Behavior on each page turn.
    (plist-put session :drag-handler
               (lambda (gesture) (etaf-reader--drag session gesture)))
    (etaf-reader--restore-preferences session)
    (when theme (etaf-reader--write session :theme theme))
    session))

(defun etaf-reader-state (session)
  "Return SESSION's state as a detached plist snapshot."
  (list :view (etaf-reader--read session :view)
        :book (plist-get (etaf-reader--read session :book) :title)
        :chapters (length (etaf-reader--read session :chapters))
        :chapter (plist-get (etaf-reader--read session :chapter) :index)
        :lines (length (etaf-reader--read session :lines))
        :line (etaf-reader--read session :line)
        :mode (etaf-reader--read session :mode)
        :theme (etaf-reader--read session :theme)
        :density (etaf-reader--read session :density)
        :pane (etaf-reader--read session :pane)
        :percent (etaf-reader-percent session)
        :annotations (length (etaf-reader--read session :annotations))
        :selection (etaf-reader--read session :selection)
        :message (etaf-reader--read session :message)))

(defun etaf-reader-message (session text)
  "Show TEXT in SESSION's status line."
  (etaf-reader--write session :message text))

;;; ---------------------------------------------------------------------------
;;; Layout metrics
;;; ---------------------------------------------------------------------------

(defun etaf-reader--window (session)
  "Return the window showing SESSION, or nil."
  (let ((buffer (plist-get session :buffer)))
    (and (buffer-live-p buffer)
         (or (get-buffer-window buffer t)
             (and (eq (current-buffer) buffer) (selected-window))))))

(defun etaf-reader--metrics-for (width height mode)
  "Return the reading metrics for WIDTH columns and HEIGHT rows."
  (let* ((layout (cond ((>= width 104) 'wide)
                       ((>= width 68) 'medium)
                       (t 'narrow)))
         (spread (if (eq layout 'wide) 2 1))
         (available (- width (+ (* spread 5) (* (1+ spread) 2) 4)))
         (columns (max 16 (min 48 (/ available spread))))
         (rows (max 4 (- height 7))))
    (list :columns columns :rows rows :spread spread :layout layout
          :mode mode)))

(defun etaf-reader-reflow (session)
  "Re-wrap the current chapter for the session's current columns.
Keeps the reading position by offset."
  (let* ((chapter (etaf-reader--read session :chapter))
         (lines (etaf-reader--read session :lines))
         (line (etaf-reader--read session :line))
         (columns (or (plist-get (etaf-reader--read session :metrics) :columns) 40)))
    (when chapter
      (let* ((entry (nth (min line (max 0 (1- (length lines)))) lines))
             (offset (or (plist-get entry :start) 0))
             (new-lines (etaf-reader--wrap-chapter
                         chapter columns (eq (etaf-reader--read session :density)
                                             'comfortable))))
        (etaf-batch
          (etaf-reader--write session :line
                              (etaf-reader--line-for-offset new-lines offset))
          (etaf-reader--write session :lines new-lines))))))

(defun etaf-reader-sync-metrics (session &optional width height)
  "Recompute SESSION's metrics from its window (or WIDTH/HEIGHT).
When the column count changes the current chapter is re-wrapped, so a window
resize or width change never leaves stale line breaks."
  (let* ((window (unless (and width height) (etaf-reader--window session)))
         (width (or width (and (window-live-p window) (window-body-width window)) 80))
         (height (or height (and (window-live-p window) (window-body-height window)) 24))
         (previous (etaf-reader--read session :metrics))
         (manual (plist-get previous :manual))
         (metrics (etaf-reader--metrics-for width height
                                            (etaf-reader--read session :mode))))
    (when (and manual
               (= (or (plist-get previous :spread) 1)
                  (or (plist-get metrics :spread) 1)))
      (let ((requested (or (plist-get previous :requested-columns)
                           (plist-get previous :columns) 40)))
        (plist-put metrics :columns
                   (min requested
                        (max 16 (/ (- width (+ (* (plist-get metrics :spread) 5)
                                               (* (1+ (plist-get metrics :spread)) 2) 4))
                                   (plist-get metrics :spread)))))
        (setq metrics (plist-put metrics :requested-columns requested))
        (setq metrics (plist-put metrics :manual t))))
    (etaf-batch
      (etaf-reader--write session :window-rows height)
      (etaf-reader--write session :window-columns width)
      (etaf-reader--write session :metrics metrics)
      (unless (equal (plist-get previous :columns) (plist-get metrics :columns))
        (etaf-reader-reflow session)))
    metrics))

(defun etaf-reader--page-size (session)
  "Return how many lines one page shows."
  (let ((metrics (etaf-reader--read session :metrics)))
    (* (or (plist-get metrics :rows) 20)
       (or (plist-get metrics :spread) 1))))

(defun etaf-reader-set-metrics (session columns rows spread layout mode)
  "Set SESSION's layout explicitly and re-wrap the current chapter.
Use this from scripts and tests to drive a headless session at a chosen
geometry; a mounted reader gets its metrics from its window instead."
  (etaf-batch
    (etaf-reader--write session :metrics
                        (list :columns columns :rows rows :spread spread
                              :layout layout :mode mode))
    (etaf-reader--write session :mode mode)
    (etaf-reader-reflow session)))

;;; ---------------------------------------------------------------------------
;;; Wrapping
;;; ---------------------------------------------------------------------------

(defun etaf-reader--trim-line (text start end indent)
  "Return (STRING START TRIMMED-END) for TEXT[START,END) with INDENT."
  (let ((trimmed end))
    (while (and (> trimmed start)
                (memq (aref text (1- trimmed)) '(?\s ?\t)))
      (setq trimmed (1- trimmed)))
    (list (concat indent (substring text start trimmed)) start trimmed)))

(defun etaf-reader--wrap-segment (text from to columns indent)
  "Wrap TEXT[FROM,TO) into (STRING START END) lines no wider than COLUMNS.
INDENT is prepended to the first produced line but keeps source offsets; its
own display width counts against the first line."
  (let ((lines nil) (position from) (start from)
        (width (if indent
                   (cl-loop for character across indent
                            sum (char-width character))
                 0))
        (pending indent))
    (while (< position to)
      (let* ((character (aref text position))
             (character-width (char-width character)))
        (when (and (> (+ width character-width) columns)
                   (> position start))
          (push (etaf-reader--trim-line text start position pending) lines)
          (setq start position width 0 pending nil)
          (while (and (< start to) (memq (aref text start) '(?\s ?\t)))
            (setq start (1+ start))
            (setq position (max position start))))
        (setq width (+ width character-width))
        (setq position (1+ position))))
    (when (or (> to from) (null lines))
      (push (etaf-reader--trim-line text start to pending) lines))
    (nreverse lines)))

(defun etaf-reader--wrap-text (text columns &optional indent)
  "Wrap TEXT into (STRING START END) lines, honoring explicit newlines."
  (let ((segments nil) (index 0) (length (length (or text ""))))
    (while (< index length)
      (let ((newline (or (cl-position ?\n text :start index) length)))
        (setq segments (nconc segments
                              (etaf-reader--wrap-segment
                               text index newline columns
                               (and (= index 0) indent))))
        (setq index (1+ newline))))
    segments))

(defun etaf-reader--block-kind (type)
  "Return the line kind and indent of block TYPE as a cons."
  (pcase type
    ((or "h1" "h2" "h3" "h4" "h5" "h6") '(heading . nil))
    ("quote" '(quote . nil))
    ("pre" '(pre . nil))
    (_ '(body . "  "))))

(defun etaf-reader--line-styles (block line-start line-end shift)
  "Return styled ranges of one line from BLOCK's runs.
SHIFT is how many display characters (indent/prefix) precede the source text."
  (let ((runs (plist-get block :runs)) (styles nil))
    (dolist (run runs)
      (let* ((start (max line-start (or (plist-get run :start) 0)))
             (end (min line-end (or (plist-get run :end) 0))))
        (when (< start end)
          (push (list (+ shift (- start line-start)) (+ shift (- end line-start))
                      (or (plist-get run :style) ""))
                styles))))
    (nreverse styles)))

(defun etaf-reader--wrap-chapter (chapter columns &optional paragraph-gaps)
  "Return CHAPTER's wrapped lines for COLUMNS.
Each line is a plist: `:key' `:start' `:end' `:text' `:kind' `:styles' `:src'."
  (let ((blocks (plist-get chapter :blocks))
        (text (or (plist-get chapter :text) ""))
        (lines nil)
        (key 0))
    (cl-labels ((emit (line-text start end kind styles src)
                  (push (list :key key :start start :end end :text line-text
                              :kind kind :styles styles :src src)
                        lines)
                  (setq key (1+ key)))
                (wrap-block (block)
                  (let* ((type (or (plist-get block :type) "p"))
                         (block-text (or (plist-get block :text) ""))
                         (base (or (plist-get block :start) 0))
                         (kind (car (etaf-reader--block-kind type)))
                         (indent (cdr (etaf-reader--block-kind type)))
                         (prefix (and (eq kind 'quote) "▎ ")))
                    (cond
                     ((equal type "img")
                      (emit (format "[图片%s]"
                                    (let ((alt (plist-get block :alt)))
                                      (if (and alt (not (string-empty-p alt)))
                                          (format "：%s" alt) "")))
                            base base 'img nil (plist-get block :src)))
                     ((equal type "hr")
                      (emit "· · ·" base base 'hr nil nil))
                     (t
                      (dolist (segment (etaf-reader--wrap-text block-text columns indent))
                        (let* ((shift (length (or indent "")))
                               (line-text (nth 0 segment))
                               (start (nth 1 segment))
                               (end (nth 2 segment)))
                          (when prefix
                            (setq line-text (concat prefix line-text))
                            (setq shift (+ shift (length prefix))))
                          (emit line-text (+ base start) (+ base end) kind
                                (etaf-reader--line-styles block start end shift)
                                nil))))))))
      (if blocks
          (dolist (block blocks)
            (when (and paragraph-gaps lines)
              (let ((offset (or (plist-get block :start) 0)))
                (emit "" offset offset 'gap nil nil)))
            (wrap-block block))
        (dolist (segment (etaf-reader--wrap-text text columns))
          (emit (nth 0 segment) (nth 1 segment) (nth 2 segment) 'body nil nil))))
    (nreverse lines)))

(defun etaf-reader--chapter-id (book index)
  "Return the chapter identity of BOOK's chapter INDEX."
  (format "%s#%d" book index))

(defun etaf-reader-chapter-summaries (book)
  "Return BOOK's chapter summaries from the store."
  (etaf-reader-store-chapters book))

(defun etaf-reader--chapter-start (session index)
  "Return how many characters precede chapter INDEX in SESSION's book."
  (let ((total 0))
    (dolist (chapter (etaf-reader--read session :chapters) total)
      (when (< (or (plist-get chapter :idx) 0) index)
        (setq total (+ total (or (plist-get chapter :chars) 0)))))))

(defun etaf-reader-load-chapter (session index &optional offset)
  "Load chapter INDEX of SESSION's book into the session and return it.
OFFSET positions the window inside the chapter before the single publication
that shows it.  Signals `etaf-reader-error' when the chapter is not stored."
  (let* ((book (etaf-reader--read session :book))
         (book-id (plist-get book :id))
         (summaries (etaf-reader--read session :chapters))
         (summary (seq-find (lambda (row) (= (or (plist-get row :idx) -1) index))
                            summaries))
         (chapter-id (etaf-reader--chapter-id book-id index))
         (content (etaf-reader-store-content chapter-id)))
    (unless (and summary content)
      (signal 'etaf-reader-error
              (list (format "章节未导入：第 %d 章" index))))
    (let* ((chapter (list :index index
                          :title (or (plist-get summary :title) "")
                          :chars (or (plist-get summary :chars) 0)
                          :text (or (plist-get content :text) "")
                          :blocks (etaf-reader--parse-blocks
                                   (plist-get content :blocks))
                          :start (etaf-reader--chapter-start session index)))
           (metrics (etaf-reader--read session :metrics))
           (lines (etaf-reader--wrap-chapter
                   chapter (or (plist-get metrics :columns) 40)
                   (eq (etaf-reader--read session :density) 'comfortable))))
      ;; Plain write: the batch below publishes this position with the text.
      (etaf-reader--write session :line
                          (if (and offset (> (or offset 0) 0))
                              (etaf-reader--line-for-offset lines offset)
                            0))
      (etaf-batch
        (etaf-reader--write session :chapter chapter)
        (etaf-reader--write session :lines lines)
        (etaf-reader--write session :annotations
                            (etaf-reader-store-annotations book-id index))
        (etaf-reader--write session :selection nil)
        (etaf-reader--write session :cursor nil)
        (etaf-reader--write session :toolbar nil))
      chapter)))

(defun etaf-reader--parse-blocks (json)
  "Parse stored block JSON, returning nil for empty or broken data."
  (when (and json (stringp json) (not (string-empty-p json)))
    (condition-case nil
        (let ((value (json-parse-string json :object-type 'plist
                                        :array-type 'list
                                        :null-object nil :false-object nil)))
          (and (listp value) value))
      (error nil))))

(defun etaf-reader-open-chapter (session index &optional offset)
  "Open chapter INDEX positioned at character OFFSET (or line 0)."
  (let* ((summaries (etaf-reader--read session :chapters))
         (count (length summaries))
         (index (max 0 (min (1- (max 1 count)) index)))
         (title (or (plist-get (etaf-reader--read session :book) :title) "")))
    (etaf-reader-save-quiet session)
    ;; One batch, one publication: the message, the chapter and the window.
    (etaf-batch
      (etaf-reader--write session :message
                          (format "%s · 第 %d/%d 章" title (1+ index) count))
      (etaf-reader-load-chapter session index offset))
    (etaf-reader-schedule-save session)))

(defun etaf-reader--line-for-offset (lines offset)
  "Return the first line index whose end is past OFFSET."
  (let ((index 0) (found nil))
    (while (and lines (not found))
      (if (>= (or (plist-get (car lines) :end) 0) offset)
          (setq found index)
        (setq lines (cdr lines) index (1+ index))))
    (or found 0)))

;;; ---------------------------------------------------------------------------
;;; Navigation
;;; ---------------------------------------------------------------------------

(defun etaf-reader-lines (session)
  "Return the wrapped lines of SESSION's current chapter."
  (etaf-reader--read session :lines))

(defun etaf-reader-annotations (session &optional chapter)
  "Return SESSION's annotations.
Without CHAPTER return the current chapter's annotations; with it, return the
stored annotations of that chapter index."
  (if chapter
      (etaf-reader-store-annotations
       (plist-get (etaf-reader--read session :book) :id) chapter)
    (etaf-reader--read session :annotations)))

(defun etaf-reader-set-filter (session filter)
  "Show rows matching FILTER: all, reading, unread or finished."
  (unless (memq filter '(all reading unread finished))
    (signal 'etaf-reader-error '("无效阅读状态筛选")))
  (etaf-batch
    (etaf-reader--write session :filter filter)
    (etaf-reader--write session :shelf-page 0))
  filter)

(defun etaf-reader--clamp-line (session line)
  "Clamp LINE to SESSION's current chapter."
  (max 0 (min (max 0 (1- (length (etaf-reader--read session :lines)))) line)))

(defun etaf-reader--display-window (session)
  "Replace the visible line texts and status through retained Hosts.
Return non-nil when the retained update committed; nil when the caller must
publish ordinarily instead."
  (let* ((buffer (plist-get session :buffer))
         (runtime (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
         (lines (etaf-reader--read session :lines))
         (metrics (etaf-reader--read session :metrics))
         (top (etaf-reader--read session :line))
         (rows (max 1 (or (plist-get metrics :rows) 20)))
         (spread (max 1 (or (plist-get metrics :spread) 1)))
         (window (nthcdr top lines))
         (theme (etaf-reader--read session :theme)))
    (when (and runtime (etaf-runtime-mounted-p runtime)
               (eq (etaf-reader--read session :view) 'reader)
               (null (etaf-reader--read session :pane))
               (null (etaf-reader--read session :toolbar))
               ;; Columns holding a picture render line by line instead of
               ;; one retained text slot, on the new page or the shown one.
               (not (cl-some (lambda (line) (eq (plist-get line :kind) 'img))
                             (seq-take window (* rows spread))))
               (cl-loop for column below spread
                        always (etaf-runtime-host-props-for
                                runtime (intern (format "reader-column-%d" column)))))
      (let ((updates (list (cons 'reader-page
                                 (concat (etaf-reader--page-label session) " · "
                                         (etaf-reader-percent-text session))))))
        (dotimes (column spread)
          (push (cons (intern (format "reader-column-%d" column))
                      (mapconcat
                       #'identity
                       (cl-loop repeat rows
                                collect (etaf-reader--line-content
                                         session (pop window) theme))
                       "\n"))
                updates))
        (etaf-runtime-update-host-contents runtime updates)
        t))))

(defun etaf-reader-goto-line (session line)
  "Move SESSION's top line to LINE.
Mounted pages use fixed retained text slots, including titles and annotations.
An open dialog or toolbar instead receives an ordinary publication."
  (let* ((line (etaf-reader--clamp-line session line))
         (previous (etaf-reader--read session :line)))
    (unless (equal previous line)
      (etaf-reader--write session :line line)
      (condition-case error-data
          (unless (etaf-reader--display-window session)
            (etaf-reader-repaint session))
        (error
         (etaf-reader--write session :line previous)
         (signal (car error-data) (cdr error-data)))))
    (etaf-reader-schedule-save session)))

(defun etaf-reader-next-page (session)
  "Turn to the next page, moving into the next chapter at the end."
  (let* ((page (etaf-reader--page-size session))
         (current (etaf-reader--read session :line))
         (total (length (etaf-reader--read session :lines))))
    (if (>= (+ current page) total)
        (etaf-reader-next-chapter session)
      (etaf-reader-goto-line session (+ current page)))))

(defun etaf-reader-previous-page (session)
  "Turn to the previous page, moving into the previous chapter at the start."
  (let* ((page (etaf-reader--page-size session))
         (current (etaf-reader--read session :line)))
    (if (<= current 0)
        (etaf-reader-previous-chapter session)
      (etaf-reader-goto-line session (max 0 (- current page))))))

(defun etaf-reader-scroll-lines (session delta)
  "Scroll SESSION by DELTA lines."
  (etaf-reader-goto-line session (+ (etaf-reader--read session :line) delta)))

(defun etaf-reader-next-chapter (session)
  "Open the next chapter."
  (let* ((chapter (etaf-reader--read session :chapter))
         (index (or (plist-get chapter :index) 0))
         (count (length (etaf-reader--read session :chapters))))
    (if (< index (1- count))
        (etaf-reader-open-chapter session (1+ index) 0)
      (etaf-reader-message session "已经是最后一章"))))

(defun etaf-reader-previous-chapter (session)
  "Open the previous chapter."
  (let* ((chapter (etaf-reader--read session :chapter))
         (index (or (plist-get chapter :index) 0)))
    (if (> index 0)
        (etaf-reader-open-chapter session (1- index) 0)
      (etaf-reader-message session "已经是第一章"))))

(defun etaf-reader-goto-percent (session percent)
  "Move SESSION to PERCENT (0-100) of the book."
  (let* ((percent (max 0 (min 100 (round percent))))
         (book (etaf-reader--read session :book))
         (total (max 1 (or (plist-get book :chars) 0)))
         (target (floor (* total (/ percent 100.0))))
         (summaries (etaf-reader--read session :chapters))
         (index 0) (accumulated 0) (found nil))
    (dolist (chapter summaries)
      (unless found
        (let ((chars (or (plist-get chapter :chars) 0)))
          (if (<= target (+ accumulated chars))
              (setq found (or (plist-get chapter :idx) 0))
            (setq accumulated (+ accumulated chars))))))
    (setq index (or found 0))
    (etaf-reader-open-chapter session index (- target accumulated))
    (etaf-reader-message session (format "已到 %d%%" percent))))

(defun etaf-reader-percent (session)
  "Return SESSION's reading progress in percent."
  (let* ((book (etaf-reader--read session :book))
         (total (max 1 (or (plist-get book :chars) 0)))
         (chapter (etaf-reader--read session :chapter))
         (lines (etaf-reader--read session :lines))
         (line (etaf-reader--read session :line))
         (entry (nth (min (max 0 line) (max 0 (1- (length lines)))) lines))
         (offset (+ (or (plist-get chapter :start) 0)
                    (or (plist-get entry :start) 0))))
    (min 100.0 (* 100.0 (/ (float offset) total)))))

(defun etaf-reader--page-label (session)
  "Return SESSION's position label for the status line."
  (let* ((metrics (etaf-reader--read session :metrics))
         (rows (or (plist-get metrics :rows) 20))
         (spread (or (plist-get metrics :spread) 1))
         (page-size (max 1 (* rows spread)))
         (total (length (etaf-reader--read session :lines)))
         (top (etaf-reader--read session :line)))
    (if (eq (etaf-reader--read session :mode) 'page)
        (format "第 %d/%d 页"
                (1+ (/ top page-size))
                (max 1 (ceiling (/ (float total) page-size))))
      (format "第 %d/%d 行" (1+ top) total))))

(defun etaf-reader-percent-text (session)
  "Return SESSION's progress as a display string."
  (format "%.1f%%" (etaf-reader-percent session)))

;;; ---------------------------------------------------------------------------
;;; Selection
;;; ---------------------------------------------------------------------------

(defun etaf-reader--offset-at (session line char)
  "Return the chapter offset for LINE and CHAR in SESSION."
  (let* ((lines (etaf-reader--read session :lines))
         (entry (nth (max 0 (min (1- (max 1 (length lines))) line)) lines)))
    (if (null entry)
        0
      (+ (or (plist-get entry :start) 0)
         (max 0 (min (or char 0) (length (or (plist-get entry :text) ""))))))))

(defun etaf-reader--line-and-char-for-offset (session offset)
  "Return (LINE . CHAR) addressing OFFSET in SESSION's chapter."
  (let ((lines (etaf-reader--read session :lines))
        (index 0) (result nil) (previous nil))
    (while (and lines (not result))
      (let ((entry (car lines)))
        (if (>= (or (plist-get entry :end) 0) offset)
            (setq result (cons index (max 0 (- offset (or (plist-get entry :start) 0)))))
          (setq previous index)
          (setq lines (cdr lines) index (1+ index)))))
    (or result (cons (or previous 0) 0))))

(defun etaf-reader-selection (session)
  "Return SESSION's selection as (START . END), or nil."
  (let ((selection (etaf-reader--read session :selection)))
    (when selection
      (cons (plist-get selection :start) (plist-get selection :end)))))

(defun etaf-reader-set-selection (session start end)
  "Set SESSION's selection to the ordered range START..END."
  (let ((start (max 0 (min start end)))
        (end (max start end)))
    (if (= start end)
        (etaf-reader-clear-selection session)
      (etaf-reader--write session :selection (list :start start :end end)))
    (etaf-reader--read session :selection)))

(defun etaf-reader-clear-selection (session)
  "Clear SESSION's selection, cursor and toolbar."
  (etaf-batch
    (etaf-reader--write session :selection nil)
    (etaf-reader--write session :cursor nil)
    (etaf-reader--write session :toolbar nil))
  nil)

(defun etaf-reader-selection-active (session)
  "Return non-nil when SESSION has an active selection or cursor."
  (or (etaf-reader--read session :selection)
      (etaf-reader--read session :cursor)))

(defun etaf-reader-begin-selection (session line char)
  "Start a selection at LINE and CHAR."
  (let ((offset (etaf-reader--offset-at session line char)))
    (etaf-reader--write session :cursor (list :line line :char char :anchor offset))
    (etaf-reader--write session :selection nil)
    offset))

(defun etaf-reader-extend-selection (session line char)
  "Extend the selection started with `etaf-reader-begin-selection' to LINE/CHAR."
  (let* ((cursor (etaf-reader--read session :cursor))
         (anchor (or (plist-get cursor :anchor)
                     (etaf-reader-begin-selection session line char)))
         (offset (etaf-reader--offset-at session line char)))
    (etaf-reader--write session :cursor
                        (list :line line :char char :anchor anchor))
    (etaf-reader--write session :selection
                        (list :start (min anchor offset) :end (max anchor offset)))
    offset))

(defun etaf-reader-selection-text (session)
  "Return the selected text of SESSION, or an empty string."
  (let* ((range (etaf-reader-selection session))
         (chapter (etaf-reader--read session :chapter)))
    (if (null range)
        ""
      (let ((text (or (plist-get chapter :text) "")))
        (substring text (max 0 (car range))
                   (min (length text) (cdr range)))))))

(defun etaf-reader-selection-line (session)
  "Return the line index the selection starts on."
  (let ((range (etaf-reader-selection session)))
    (and range (car (etaf-reader--line-and-char-for-offset session (car range))))))

;;; ---------------------------------------------------------------------------
;;; Annotations
;;; ---------------------------------------------------------------------------

(defun etaf-reader--annotation-id (book chapter start end)
  "Return the identity of one annotation range."
  (secure-hash 'md5 (format "%s:%d:%d:%d" book chapter start end)))

(defun etaf-reader-annotate (session kind color)
  "Apply annotation KIND in COLOR to SESSION's selection.
KIND is `highlight', `underline', `wavy' or `note'."
  (let ((range (etaf-reader-selection session)))
    (if (null range)
        (progn (etaf-reader-message session "先选中一段文字")
               nil)
      (let* ((book (etaf-reader--read session :book))
             (chapter (etaf-reader--read session :chapter))
           (book-id (plist-get book :id))
           (index (or (plist-get chapter :index) 0))
           (text (or (plist-get chapter :text) ""))
           (start (car range))
           (end (min (cdr range) (length text)))
           (id (etaf-reader--annotation-id book-id index start end))
           (now (floor (float-time)))
           (existing (seq-find (lambda (row) (equal (plist-get row :id) id))
                               (etaf-reader--read session :annotations))))
      (etaf-reader-store-put-annotation
       (list :id id :book book-id :chapter index :start start :end end
             :kind kind :color color
             :quote (substring text start end)
             :note (or (plist-get existing :note) "")
             :created (or (plist-get existing :created) now)
             :updated now))
      (etaf-batch
        (etaf-reader--write session :annotations
                            (etaf-reader-store-annotations book-id index))
        (etaf-reader--write session :book-notes
                            (etaf-reader-store-annotations book-id))
        (etaf-reader--write session :selection nil)
        (etaf-reader--write session :cursor nil)
        (etaf-reader--write session :toolbar nil))
      (etaf-reader-message session
                           (format "已标注：%s" (substring text start (min end (+ start 12)))))
      id))))

(defun etaf-reader-annotation-note (session id note)
  "Attach NOTE to the annotation ID."
  (let* ((book (etaf-reader--read session :book))
         (rows (etaf-reader--read session :annotations))
         (existing (seq-find (lambda (row) (equal (plist-get row :id) id)) rows)))
    (unless existing
      (signal 'etaf-reader-error (list "标注不存在")))
    (etaf-reader-store-put-annotation
     (list :id (plist-get existing :id)
           :book (plist-get existing :book)
           :chapter (plist-get existing :chapter)
           :start (plist-get existing :start)
           :end (plist-get existing :end)
           :kind (plist-get existing :kind)
           :color (plist-get existing :color)
           :quote (plist-get existing :quote)
           :note (or note "")
           :created (plist-get existing :created)
           :updated (floor (float-time))))
    (etaf-batch
      (etaf-reader--write session :annotations
                          (etaf-reader-store-annotations (plist-get book :id)
                                                         (plist-get existing :chapter)))
      (etaf-reader--write session :book-notes
                          (etaf-reader-store-annotations (plist-get book :id))))
    (etaf-reader-message session "想法已保存")
    (plist-get existing :id)))

(defun etaf-reader-annotation-delete (session id)
  "Delete the annotation ID."
  (let ((book (etaf-reader--read session :book)))
    (etaf-reader-store-delete-annotation id)
    (etaf-batch
      (etaf-reader--write session :annotations
                          (etaf-reader-store-annotations
                           (plist-get book :id)
                           (or (plist-get (etaf-reader--read session :chapter) :index) 0)))
      (etaf-reader--write session :book-notes
                          (etaf-reader-store-annotations (plist-get book :id)))
      (etaf-reader--write session :toolbar nil))
    (etaf-reader-message session "已删除标注")
    nil))

(defun etaf-reader-annotation-at-offset (session offset)
  "Return the annotation covering OFFSET in the current chapter, or nil."
  (seq-find (lambda (row)
              (and (<= (or (plist-get row :start) 0) offset)
                   (< offset (or (plist-get row :end) 0))))
            (etaf-reader--read session :annotations)))

;;; ---------------------------------------------------------------------------
;;; Search
;;; ---------------------------------------------------------------------------

(defun etaf-reader-search-book (session query)
  "Search the whole book for QUERY, starting at the current chapter.
Return a plist `(:query :matches :index)' and jump to the first match."
  (let* ((book (etaf-reader--read session :book))
         (summaries (etaf-reader--read session :chapters))
         (start-index (or (plist-get (etaf-reader--read session :chapter) :index) 0))
         (ordered (append (seq-drop summaries start-index)
                          (seq-take summaries start-index)))
         (found nil))
    (dolist (summary (append ordered nil))
      (when (< (length found) etaf-reader-search-limit)
        (let* ((index (or (plist-get summary :idx) 0))
               (content (etaf-reader-store-content
                         (etaf-reader--chapter-id (plist-get book :id) index))))
          (when content
            (let ((text (or (plist-get content :text) ""))
                  (position 0)
                  match)
              (while (and (< (length found) etaf-reader-search-limit)
                          (setq match (let ((case-fold-search t))
                                        (string-match (regexp-quote query)
                                                      text position))))
                (push (list :chapter index :start match
                            :end (+ match (length query))
                            :context (replace-regexp-in-string
                                      "[\n\r]+" " "
                                      (substring text (max 0 (- match 12))
                                                 (min (length text) (+ match (length query) 32)))))
                      found)
                (setq position (+ match (max 1 (length query))))))))))
    (setq found (nreverse found))
    (let ((state (list :query query :matches found :index 0)))
      (etaf-reader--write session :search state)
      (if found
          (progn (etaf-reader-goto-match session 0)
                 (etaf-reader-message session
                                      (format "共 %d 处匹配" (length found))))
        (etaf-reader-message session "没有找到匹配"))
      state)))

(defun etaf-reader-goto-match (session index)
  "Jump to match INDEX of the active search."
  (let* ((state (etaf-reader--read session :search))
         (matches (plist-get state :matches))
         (count (length matches)))
    (when (> count 0)
      (let* ((index (mod index count))
             (match (nth index matches))
             (chapter (plist-get match :chapter))
             (current (or (plist-get (etaf-reader--read session :chapter) :index) 0)))
        (when (/= chapter current)
          (etaf-reader-load-chapter session chapter))
        (let* ((lines (etaf-reader--read session :lines))
               (line (etaf-reader--line-for-offset lines (plist-get match :start))))
          (etaf-reader-goto-line session line)
          (etaf-reader-set-selection session (plist-get match :start)
                                     (plist-get match :end))
          (etaf-reader--write session :search
                              (plist-put (copy-sequence state) :index index))
          (etaf-reader-message session
                               (format "%d/%d 处：第 %d 章"
                                       (1+ index) count (1+ chapter))))))))

(defun etaf-reader-search-next (session &optional backward)
  "Jump to the next (or previous) search match."
  (let* ((state (etaf-reader--read session :search)))
    (if (or (null state) (null (plist-get state :matches)))
        (etaf-reader-message session "先搜索（按 s）")
      (etaf-reader-goto-match session
                              (+ (or (plist-get state :index) 0)
                                 (if backward -1 1))))))

;;; ---------------------------------------------------------------------------
;;; Books
;;; ---------------------------------------------------------------------------

(defun etaf-reader-open-book (session book &optional parser)
  "Open BOOK in SESSION, importing it first when needed."
  (let* ((book (etaf-reader-library-ensure book (or parser (plist-get session :parser))))
         (book (plist-put (copy-sequence book) :title (etaf-reader--book-title book)))
         (chapters (etaf-reader-chapter-summaries (plist-get book :id)))
         (state (and etaf-reader-remember-positions
                     (etaf-reader-store-state (plist-get book :id)))))
    (when (= (length chapters) 0)
      (signal 'etaf-reader-error
              (list (format "这本书没有可读章节：%s" (plist-get book :title)))))
    ;; Save against the previous book before changing its identity.
    (etaf-reader-save-now session)
    (plist-put session :history nil)
    (etaf-reader-store-put-book
     (plist-put (copy-sequence book) :opened (floor (float-time))))
    (etaf-batch
      (etaf-reader-sync-metrics session)
      (etaf-reader--write session :book
                          (plist-put (copy-sequence book) :opened (floor (float-time))))
      (etaf-reader--write session :book-notes
                          (etaf-reader-store-annotations (plist-get book :id)))
      (etaf-reader--write session :chapters chapters)
      (etaf-reader--write session :view 'reader)
      (etaf-reader--write session :pane nil)
      (etaf-reader--write session :selection nil)
      (etaf-reader-load-chapter session (or (plist-get state :chapter) 0)
                                (plist-get state :offset)))
    (etaf-reader-schedule-save session)
    book))

(defun etaf-reader-show-shelf (session)
  "Return SESSION to its shelf."
  (etaf-reader-save-now session)
  (etaf-batch
    (etaf-reader--write session :books (etaf-reader-store-books))
    (etaf-reader--write session :view 'shelf)
    (etaf-reader--write session :pane nil)
    (etaf-reader-message session nil))
  (etaf-reader-refresh-states session))

(defun etaf-reader-refresh-states (session)
  "Cache every book's reading state in SESSION, keyed by book id."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (row (etaf-reader-store-states))
      (puthash (plist-get row :book) row table))
    (etaf-reader--write session :states table)
    table))

(defun etaf-reader-book-state (session book-id)
  "Return BOOK-ID's cached reading state row, or nil."
  (let ((table (etaf-reader--read session :states)))
    (and (hash-table-p table) (gethash book-id table))))

(defun etaf-reader-refresh-library (session)
  "Rescan the library and refresh SESSION's shelf rows."
  (let ((report (etaf-reader-library-scan :parser (plist-get session :parser))))
    (etaf-reader--write session :books (etaf-reader-store-books))
    (etaf-reader-refresh-states session)
    (etaf-reader-message session
                         (format "书库：共 %d 本，新增 %d，更新 %d，失败 %d"
                                 (plist-get report :total)
                                 (plist-get report :new)
                                 (plist-get report :changed)
                                 (plist-get report :failed)))
    report))

(defun etaf-reader-books (session)
  "Return SESSION's shelf rows filtered by the current filter.
Reads the cached rows, never the store: the shelf View runs during ETAF's
publication, where touching a Data Controller is a render side effect."
  (let ((books (mapcar (lambda (book)
                        (plist-put (copy-sequence book) :title (etaf-reader--book-title book)))
                      (etaf-reader--read session :books)))
        (filter (etaf-reader--read session :filter))
        (facet-format (etaf-reader--read session :facet-format))
        (facet-author (etaf-reader--read session :facet-author)))
    (let* ((query (downcase (etaf-reader--read session :shelf-query)))
           (sort-key (etaf-reader--read session :shelf-sort))
           (filtered
            (cl-remove-if-not
             (lambda (book)
               (let* ((state (etaf-reader-book-state session (plist-get book :id)))
                      (opened (or (plist-get state :last_read) 0))
                      (percent (or (plist-get state :percent) 0)))
                 (and (string-match-p
                       (regexp-quote query)
                       (downcase (concat (or (plist-get book :title) "") " "
                                         (or (plist-get book :author) ""))))
                      (pcase filter
                        ('reading (and (> opened 0) (< percent 99.9)))
                        ('unread (= opened 0))
                        ('finished (>= percent 99.9))
                        (_ t))
                      (or (null facet-format)
                          (equal (upcase (or (plist-get book :format) "")) facet-format))
                      (or (null facet-author)
                          (equal (or (plist-get book :author) "") facet-author)))))
             books)))
      (sort filtered
            (lambda (a b)
              (pcase sort-key
                ((or 'title 'author)
                 (string-lessp (or (plist-get a (if (eq sort-key 'title) :title :author)) "")
                               (or (plist-get b (if (eq sort-key 'title) :title :author)) "")))
                (_ (> (or (plist-get (etaf-reader-book-state session (plist-get a :id)) :last_read) 0)
                      (or (plist-get (etaf-reader-book-state session (plist-get b :id)) :last_read) 0)))))))))

;;; ---------------------------------------------------------------------------
;;; Progress persistence
;;; ---------------------------------------------------------------------------

(defun etaf-reader--state-row (session)
  "Return SESSION's current reading state row."
  (let* ((book (etaf-reader--read session :book))
         (chapter (etaf-reader--read session :chapter))
         (lines (etaf-reader--read session :lines))
         (line (etaf-reader--read session :line))
         (entry (nth (min (max 0 line) (max 0 (1- (length lines)))) lines)))
    (when (and book chapter)
      (list :book (plist-get book :id)
            :chapter (or (plist-get chapter :index) 0)
            :offset (or (plist-get entry :start) 0)
            :percent (etaf-reader-percent session)
            :seconds 0
            :last_read (floor (float-time))))))

(defun etaf-reader-save-now (session)
  "Write SESSION's reading position and time to the store."
  (when (and (etaf-reader--read session :book)
             (etaf-reader--read session :chapter))
    (let* ((row (etaf-reader--state-row session))
           (existing (and row (etaf-reader-store-state (plist-get row :book))))
           (elapsed (if etaf-reader-track-reading-time
                        (max 0 (round (- (float-time)
                                         (or (plist-get session :reading-start)
                                             (float-time)))))
                      0)))
      (when row
        (etaf-reader-store-put-state
         (plist-put row :seconds (+ (or (plist-get existing :seconds) 0) elapsed)))
        (plist-put session :reading-start (float-time))
        (etaf-reader--write session :books (etaf-reader-store-books))
        (etaf-reader-refresh-states session)))
    nil))

(defun etaf-reader-save-quiet (session)
  "Cancel the pending save and write the state now when an position is known."
  (when-let* ((timer (plist-get session :save-timer)))
    (cancel-timer timer)
    (plist-put session :save-timer nil))
  (ignore-errors (etaf-reader-save-now session)))

(defun etaf-reader-schedule-save (session)
  "Schedule SESSION's position save after `etaf-reader-save-delay'."
  (when (plist-get session :buffer)
    (when-let* ((timer (plist-get session :save-timer)))
      (cancel-timer timer))
    (let ((store-file etaf-reader-store-file))
      (plist-put session :save-timer
                 (run-at-time etaf-reader-save-delay nil
                              (lambda ()
                                (let ((etaf-reader-store-file store-file))
                                  (plist-put session :save-timer nil)
                                  (condition-case error-data
                                      (etaf-reader-save-now session)
                                    (error
                                     (etaf-reader-message
                                      session (format "保存失败：%s"
                                                      (error-message-string error-data))))))))))))

;;; ---------------------------------------------------------------------------
;;; Notes export
;;; ---------------------------------------------------------------------------

(defun etaf-reader-export-notes (session file)
  "Write SESSION's annotations of the current book to FILE as Markdown."
  (let* ((book (etaf-reader--read session :book))
         (rows (etaf-reader-store-annotations (plist-get book :id)))
         (chapters (etaf-reader--read session :chapters))
         (title (or (plist-get book :title) "未命名")))
    (with-temp-buffer
      (insert (format "# %s\n\n" title))
      (insert (format "作者：%s\n\n" (or (plist-get book :author) "佚名")))
      (dolist (row rows)
        (let* ((index (or (plist-get row :chapter) 0))
               (chapter (seq-find (lambda (entry)
                                    (= (or (plist-get entry :idx) -1) index))
                                  chapters)))
          (insert (format "## 第 %d 章 %s\n\n" (1+ index)
                          (or (plist-get chapter :title) "")))
          (insert (format "> %s\n\n" (or (plist-get row :quote) "")))
          (unless (string-empty-p (or (plist-get row :note) ""))
            (insert (format "%s\n\n" (plist-get row :note))))
          (insert (format "`%s`\n\n" (or (plist-get row :kind) "")))))
      (write-region (point-min) (point-max) file nil 'silent))
    (etaf-reader-message session (format "笔记已导出：%s" file))
    file))

;;; ---------------------------------------------------------------------------
;;; Guarded actions
;;; ---------------------------------------------------------------------------

(defun etaf-reader-guard (session function)
  "Run FUNCTION reporting any failure in SESSION's status line."
  (condition-case error
      (funcall function)
    (etaf-reader-error
     (etaf-reader-message session (error-message-string error)))
    (error
     (etaf-reader-message session (format "出错：%s" error)))))

(defun etaf-reader-goto-annotation (session annotation)
  "Jump to ANNOTATION, select its text and close the pane."
  (let ((chapter (or (plist-get annotation :chapter) 0)))
    (etaf-reader-open-chapter session chapter (plist-get annotation :start))
    (etaf-reader-set-selection session (plist-get annotation :start)
                               (plist-get annotation :end))
    (etaf-reader--write session :pane nil)
    (etaf-reader-message session (or (plist-get annotation :quote) "标注"))))

(defun etaf-reader--gesture-point (session gesture)
  "Return the (LINE . CHAR) a drag GESTURE points at, or nil.
Source coordinates are carried by the displayed text, so two columns and
prefixes do not get confused with physical buffer lines."
  (ignore session)
  (let* ((buffer (plist-get gesture :buffer))
         (event (plist-get gesture :event))
         (position (and event (posn-point (event-start event)))))
    (when (and (buffer-live-p buffer) (integerp position))
      (with-current-buffer buffer
        (when (and (<= (point-min) position) (< position (point-max)))
          (when-let* ((line (get-text-property position 'reader-line)))
            (cons line (- position
                          (previous-single-property-change
                           (1+ position) 'reader-line nil (point-min))))))))))

(defun etaf-reader--drag (session gesture)
  "Handle a native drag GESTURE for SESSION's text selection."
  (let ((point (etaf-reader--gesture-point session gesture)))
    (when point
      (pcase (plist-get gesture :phase)
        ('start
         (etaf-reader-begin-selection session (car point) (cdr point)))
        ((or 'move 'end)
         (etaf-reader-extend-selection session (car point) (cdr point))
         (when (eq (plist-get gesture :phase) 'end)
           (if (etaf-reader-selection session)
               (etaf-reader-show-toolbar session)
             (etaf-reader-clear-selection session)
             (let* ((event (plist-get gesture :event))
                    (position (and event (posn-point (event-start event))))
                    (buffer (plist-get gesture :buffer))
                    (id (and (buffer-live-p buffer) (integerp position)
                             (with-current-buffer buffer
                               (get-text-property position 'reader-annotation)))))
               (when id (etaf-reader-show-annotation-toolbar session id))))))))))

(defun etaf-reader-show-toolbar (session)
  "Show the selection toolbar anchored at the selection's first line."
  (let ((line (etaf-reader-selection-line session)))
    (when line
      (etaf-reader--write session :toolbar (list :line line :annotation nil)))))

(defun etaf-reader-show-annotation-toolbar (session id)
  "Show the toolbar for the annotation ID, scrolling it into view."
  (let* ((rows (etaf-reader--read session :annotations))
         (row (seq-find (lambda (entry) (equal (plist-get entry :id) id)) rows)))
    (when row
      (let* ((lines (etaf-reader--read session :lines))
             (line (etaf-reader--line-for-offset lines (or (plist-get row :start) 0)))
             (top (etaf-reader--read session :line))
             (page (max 1 (etaf-reader--page-size session))))
        (unless (and (>= line top) (< line (+ top page)))
          (etaf-reader-goto-line session (- line (mod line page))))
        (etaf-reader--write session :toolbar (list :line line :annotation row))))))

(defun etaf-reader-mark-annotation (session id kind color)
  "Change the annotation ID to KIND and COLOR."
  (let* ((rows (etaf-reader--read session :annotations))
         (row (seq-find (lambda (entry) (equal (plist-get entry :id) id)) rows))
         (book (etaf-reader--read session :book)))
    (unless row
      (signal 'etaf-reader-error (list "标注不存在")))
    (etaf-reader-store-put-annotation
     (list :id (plist-get row :id) :book (plist-get row :book)
           :chapter (plist-get row :chapter) :start (plist-get row :start)
           :end (plist-get row :end) :kind kind :color color
           :quote (plist-get row :quote) :note (or (plist-get row :note) "")
           :created (plist-get row :created) :updated (floor (float-time))))
    (etaf-batch
      (etaf-reader--write session :annotations
                          (etaf-reader-store-annotations
                           (plist-get book :id) (plist-get row :chapter)))
      (etaf-reader--write session :book-notes
                          (etaf-reader-store-annotations (plist-get book :id))))
    (etaf-reader-message session "标注已更新")
    id))

(defun etaf-reader-write-note (session &optional annotation-id)
  "Edit the thought attached to ANNOTATION-ID, or to the current selection."
  (let* ((rows (etaf-reader--read session :annotations))
         (annotation (or (and annotation-id
                              (seq-find (lambda (row)
                                          (equal (plist-get row :id) annotation-id))
                                        rows))
                         (seq-find (lambda (row)
                                     (equal (plist-get row :id)
                                            (and (etaf-reader-selection session)
                                                 (etaf-reader--annotation-id
                                                  (plist-get (etaf-reader--read session :book) :id)
                                                  (or (plist-get (etaf-reader--read session :chapter) :index) 0)
                                                  (car (etaf-reader-selection session))
                                                  (cdr (etaf-reader-selection session))))))
                                   rows))))
    (if (not (or annotation (etaf-reader-selection session)))
        (progn (etaf-reader-message session "先选中一段文字")
               nil)
      (let ((buffer (get-buffer-create "*etaf-reader 想法*"))
            (session session)
            (annotation annotation))
        (with-current-buffer buffer
          (erase-buffer)
          (insert (or (and annotation (plist-get annotation :note)) ""))
          (text-mode)
          (setq-local header-line-format "C-c C-c 保存 · C-c C-k 取消")
          (local-set-key (kbd "C-c C-c")
                         (lambda ()
                           (interactive)
                           (etaf-reader--save-note-buffer session buffer annotation)))
          (local-set-key (kbd "C-c C-k")
                         (lambda ()
                           (interactive)
                           (kill-buffer buffer))))
        (pop-to-buffer buffer)))))

(defun etaf-reader--save-note-buffer (session buffer annotation)
  "Save the note in BUFFER to ANNOTATION (creating one when needed)."
  (let ((note (string-trim (with-current-buffer buffer (buffer-string)))))
    (if annotation
        (etaf-reader-annotation-note session (plist-get annotation :id) note)
      (let ((id (etaf-reader-annotate session "note" "blue")))
        (when id (etaf-reader-annotation-note session id note))))
    (kill-buffer buffer)
    (etaf-reader--write session :toolbar nil)))

(defun etaf-reader-add-bookmark (session)
  "Bookmark the top line of the current page."
  (let* ((chapter (etaf-reader--read session :chapter))
         (lines (etaf-reader--read session :lines))
         (line (etaf-reader--read session :line))
         (entry (nth (min line (max 0 (1- (length lines)))) lines))
         (offset (or (plist-get entry :start) 0))
         (book (etaf-reader--read session :book))
         (id (secure-hash 'md5 (format "%s:%d:%d" (plist-get book :id)
                                       (or (plist-get chapter :index) 0) offset))))
    (etaf-reader-store-put-bookmark
     (list :id id :book (plist-get book :id)
           :chapter (or (plist-get chapter :index) 0)
           :offset offset
           :label (or (plist-get entry :text) "")
           :created (floor (float-time))))
    (etaf-reader-message session "已加书签")))

(provide 'etaf-reader-model)
;;; etaf-reader-model.el ends here
