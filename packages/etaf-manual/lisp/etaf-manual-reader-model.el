;;; etaf-manual-reader-model.el --- Session state of the manual reader -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Session state and navigation of the manual reader.  A session is a plist
;; of reactive refs plus a document cache: it owns the language, the current
;; chapter and section, the history both ways and the theme, and it can exist
;; without any buffer, so scripts and tests drive the same model the mounted
;; application uses.
;;
;; All display values are read through `etaf-value' during render, so a
;; chapter change, a language switch or a theme switch repaints exactly the
;; regions that read the changed source.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-manual-book)
(require 'etaf-manual-reader-theme)

(declare-function etaf-manual-book "etaf-manual" (&optional language))
(declare-function etaf-manual-reader-scroll-to-definition
                  "etaf-manual-reader-views" (session name))

(defconst etaf-manual-reader--history-limit 64
  "Maximum remembered positions per direction.")

(defconst etaf-manual-reader--sidebar-default-columns 38
  "Default navigation column width in character cells.")

(defconst etaf-manual-reader--sidebar-min-columns 24
  "Narrowest navigation column in character cells.")

(defconst etaf-manual-reader--sidebar-max-columns 64
  "Widest navigation column in character cells.")

(defconst etaf-manual-reader--outline-min-columns 12
  "Narrowest on-this-page column in character cells.")

(defconst etaf-manual-reader--outline-max-columns 44
  "Widest on-this-page column in character cells.")

(defconst etaf-manual-reader--outline-default-max-columns 30
  "Widest automatic on-this-page width in character cells.")

(defcustom etaf-manual-reader-position-file nil
  "File remembering the reader's last reading position.
The file stores the language, palette, chapter and section as a plist; a
missing, unreadable or malformed file is ignored.  nil uses
`etaf-manual-position.eld' under `user-emacs-directory'."
  :type '(choice (const :tag "Default location" nil) file)
  :group 'etaf-manual)

(defvar etaf-manual-reader--remember-timers (make-hash-table :test 'eq :weakness 'key)
  "SESSION to its pending position save.")

(defun etaf-manual-reader--default-language ()
  "Return the default reader language."
  (if (boundp 'etaf-manual-reader-language)
      (symbol-value 'etaf-manual-reader-language)
    "zh-CN"))

;;;; Session

(cl-defun etaf-manual-reader-create (&key language theme chapter)
  "Create a headless manual reader session and return it.
LANGUAGE defaults to `etaf-manual-reader-language', THEME to the frame's own
background mode, and CHAPTER to the manual's first chapter.  CHAPTER is a
chapter identifier, which is a symbol, or its name as a string.  An unknown
chapter signals `etaf-manual-error' here, so a caller cannot mount a reader
that has no chapter to show.  The session owns no buffer, so it is a complete
headless reader for scripts and tests."
  (let* ((language (or language (etaf-manual-reader--default-language)))
         (book (etaf-manual-book language))
         (chapter (and chapter (etaf-manual-reader--chapter-id
                                (etaf-manual-reader--book-chapters book) chapter))))
    (list
     :language (etaf-ref language :name 'etaf-manual-reader-language)
     :theme (etaf-ref (or theme 'auto)
                      :name 'etaf-manual-reader-theme)
     :chapter (etaf-ref (or chapter
                            (etaf-manual-reader--book-default-chapter book))
                        :name 'etaf-manual-reader-chapter)
     :node (etaf-ref nil :name 'etaf-manual-reader-node)
     :back (etaf-ref nil :name 'etaf-manual-reader-back)
     :forward (etaf-ref nil :name 'etaf-manual-reader-forward)
     :toc (etaf-ref nil :name 'etaf-manual-reader-toc-visible)
     :message (etaf-ref nil :name 'etaf-manual-reader-message)
     :extent (etaf-ref nil :name 'etaf-manual-reader-extent)
     :search (etaf-ref nil :name 'etaf-manual-reader-search)
     :focus (etaf-ref nil :name 'etaf-manual-reader-focus)
     :editing (etaf-ref nil :name 'etaf-manual-reader-editing)
     :drafts (etaf-ref nil :name 'etaf-manual-reader-drafts)
     :sidebar-width (etaf-ref nil :name 'etaf-manual-reader-sidebar-width)
     :outline-width (etaf-ref nil :name 'etaf-manual-reader-outline-width)
     :documents (make-hash-table :test #'equal)
     :buffer nil)))

(defun etaf-manual-reader--book-default-chapter (book)
  "Return BOOK's first reading-order chapter identifier."
  (let ((chapter (or (cl-find-if (lambda (entry) (eq (plist-get entry :kind) 'chapter))
                                 (plist-get book :chapters))
                     (car (plist-get book :chapters)))))
    (plist-get chapter :id)))

(defun etaf-manual-reader--ref (session key)
  "Return SESSION's reactive source named KEY."
  (plist-get session key))

(defun etaf-manual-reader--read (session key)
  "Return SESSION's current value for KEY."
  (etaf-value (etaf-manual-reader--ref session key)))

(defun etaf-manual-reader--write (session key value)
  "Publish VALUE as SESSION's new value for KEY and return VALUE."
  (let ((ref (etaf-manual-reader--ref session key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value))
    value))

;;;; Book access

(defun etaf-manual-reader--book (session)
  "Return SESSION's book in its current language."
  (etaf-manual-book (etaf-manual-reader--read session :language)))

(defun etaf-manual-reader--book-chapters (book)
  "Return BOOK's chapters in reading order."
  (plist-get book :chapters))

(defun etaf-manual-reader--chapter-id (chapters chapter)
  "Return CHAPTER as the identifier CHAPTERS carries.
CHAPTER is that identifier or its name string; anything else, including a
name the book does not know, signals `etaf-manual-error'."
  (let* ((id (if (stringp chapter) (intern chapter) chapter))
         (known (and (symbolp id)
                     (cl-find id chapters :key (lambda (entry) (plist-get entry :id))))))
    (or known
        (signal 'etaf-manual-error
                (list (format "Unknown chapter: %S" chapter))))
    id))

(defun etaf-manual-reader--chapters (session)
  "Return SESSION's chapters in reading order."
  (plist-get (etaf-manual-reader--book session) :chapters))

(defun etaf-manual-reader--chapter (session &optional id)
  "Return SESSION's chapter for ID, defaulting to the current chapter."
  (let ((id (or id (etaf-manual-reader--read session :chapter))))
    (cl-find id (etaf-manual-reader--chapters session)
             :key (lambda (chapter) (plist-get chapter :id)))))

(defun etaf-manual-reader--chapter-title (session &optional id)
  "Return the display title of SESSION's chapter ID."
  (let ((chapter (etaf-manual-reader--chapter session id)))
    (when chapter
      (if-let* ((number (plist-get chapter :number)))
          (format "%s %s" number (plist-get chapter :title))
        (plist-get chapter :title)))))

(defun etaf-manual-reader--part (session &optional id)
  "Return the part of SESSION that owns chapter ID."
  (let ((id (or id (etaf-manual-reader--read session :chapter))))
    (cl-find-if (lambda (part) (memq id (plist-get part :chapters)))
                (plist-get (etaf-manual-reader--book session) :parts))))

(defun etaf-manual-reader--nodes (session &optional id)
  "Return SESSION's section nodes of chapter ID."
  (let ((chapter (etaf-manual-reader--chapter session id)))
    (plist-get chapter :nodes)))

(defun etaf-manual-reader--node-at (session index &optional id)
  "Return SESSION's node at INDEX of chapter ID, or nil for the chapter top."
  (when index
    (nth index (etaf-manual-reader--nodes session id))))

(defun etaf-manual-reader--position-title (session)
  "Return a breadcrumb title for SESSION's current position."
  (let* ((chapter (etaf-manual-reader--read session :chapter))
         (node (etaf-manual-reader--read session :node))
         (node-title (plist-get (etaf-manual-reader--node-at session node) :title)))
    (if node-title
        (format "%s › %s" (etaf-manual-reader--chapter-title session chapter)
                node-title)
      (etaf-manual-reader--chapter-title session chapter))))

;;;; Documents

(defun etaf-manual-reader--chapter-text (chapter)
  "Return CHAPTER's markdown text.
Generated chapters carry their text as `:content'; written chapters are read
from their `:file'."
  (or (plist-get chapter :content)
      (with-temp-buffer
        (insert-file-contents (plist-get chapter :file))
        (buffer-string))))

(defun etaf-manual-reader-document (session &optional id)
  "Return SESSION's parsed markdown document of chapter ID.
The document is cached per language and chapter; the cache is not reactive,
but callers read the chapter before asking, so a chapter change re-parses."
  (let* ((language (etaf-manual-reader--read session :language))
         (id (or id (etaf-manual-reader--read session :chapter)))
         (chapter (etaf-manual-reader--chapter session id))
         (key (cons language id))
         (cache (plist-get session :documents)))
    (when chapter
      (or (gethash key cache)
          (puthash key
                   (etaf-ui-markdown-parse
                    (etaf-manual-reader--chapter-text chapter))
                   cache)))))

(defun etaf-manual-reader--document-blocks (session &optional id)
  "Return the top-level blocks of SESSION's current document."
  (plist-get (etaf-manual-reader-document session id) :children))

(defun etaf-manual-reader--chapter-examples (session &optional id)
  "Return SESSION's runnable examples of chapter ID, in document order."
  (plist-get (etaf-manual-reader--chapter session id) :examples))

(defun etaf-manual-reader--chapter-figures (session &optional id)
  "Return SESSION's inline figures of chapter ID, in document order."
  (plist-get (etaf-manual-reader--chapter session id) :figures))

(defun etaf-manual-reader--chapter-definitions (session &optional id)
  "Return SESSION's definition entries of chapter ID, in document order."
  (plist-get (etaf-manual-reader--chapter session id) :definitions))

(defun etaf-manual-reader--definition-table (session)
  "Return SESSION's definition entries as a NAME string hash table.
The table is built once per language; the first entry of a name wins."
  (let* ((language (etaf-manual-reader--read session :language))
         (key (list 'definitions language))
         (cache (plist-get session :documents)))
    (or (gethash key cache)
        (puthash key
                 (let ((table (make-hash-table :test #'equal)))
                   (dolist (chapter (etaf-manual-reader--chapters session))
                     (dolist (definition (plist-get chapter :definitions))
                       (let ((name (format "%s" (plist-get definition :name))))
                         (unless (gethash name table)
                           (puthash name definition table)))))
                   table)
                 cache))))

(defun etaf-manual-reader--node-for-line (session line &optional id)
  "Return SESSION's section index containing LINE of chapter ID, or nil.
The section is the last section node that starts at or before LINE."
  (when (numberp line)
    (let ((index nil))
      (cl-loop for node in (etaf-manual-reader--nodes session id)
               for position from 0
               do (when (and (plist-get node :line)
                             (<= (plist-get node :line) line))
                    (setq index position)))
      index)))

;;;; Jump targets

(defun etaf-manual-reader--chapter-kind-label (chapter)
  "Return CHAPTER's completion label prefix."
  (pcase (plist-get chapter :kind)
    ('appendix "附录")
    ('index "索引")
    (_ "章")))

(defun etaf-manual-reader-jump-targets (session)
  "Return SESSION's jump targets as a list of (LABEL . TARGET) pairs.
LABEL names the target for completion; TARGET is a plist with `:chapter'
and one of `:node' (a zero-based section index), `:definition' (a symbol)
or `:anchor' (a section anchor), or only `:chapter' for the chapter itself.
Chapters, their sections, definition entries and index terms all appear in
reading order."
  (let (targets)
    (dolist (chapter (etaf-manual-reader--chapters session))
      (let* ((id (plist-get chapter :id))
             (title (etaf-manual-reader--chapter-title session id))
             (prefix (etaf-manual-reader--chapter-kind-label chapter)))
        (push (cons (format "%s · %s" prefix title)
                    (list :chapter id))
              targets)
        (cl-loop for node in (plist-get chapter :nodes)
                 for index from 0
                 do (push (cons (format "节 · %s › %s" title (plist-get node :title))
                                (list :chapter id :node index))
                          targets))
        (dolist (definition (plist-get chapter :definitions))
          (push (cons (format "定义 · %s（%s）— %s"
                              (plist-get definition :name)
                              (plist-get definition :kind)
                              title)
                      (list :chapter id
                            :node (etaf-manual-reader--node-for-line
                                   session (plist-get definition :line) id)
                            :definition (plist-get definition :name)))
                targets))
        (dolist (entry (plist-get chapter :index))
          (push (cons (format "术语 · %s — %s" (plist-get entry :term) title)
                      (list :chapter id :anchor (plist-get entry :anchor)))
                targets))))
    (nreverse targets)))

;;;; Search

(defun etaf-manual-reader--inline-text (nodes)
  "Return the plain text of inline NODES."
  (mapconcat (lambda (node)
               (concat (or (plist-get node :text) "")
                       (etaf-manual-reader--inline-text (plist-get node :children))))
             nodes ""))

(defun etaf-manual-reader--block-text (block)
  "Return the plain text of BLOCK."
  (pcase (plist-get block :type)
    ('list (mapconcat (lambda (item)
                        (mapconcat (lambda (child)
                                     (etaf-manual-reader--block-text child))
                                   (plist-get item :children) " "))
                      (plist-get block :items) " "))
    ('table (mapconcat (lambda (row)
                         (mapconcat #'etaf-manual-reader--inline-text row " "))
                       (append (list (plist-get block :header))
                               (plist-get block :rows))
                       " "))
    ((or 'blockquote 'footnote-def)
     (mapconcat #'etaf-manual-reader--block-text (plist-get block :children) " "))
    (_ (concat (or (plist-get block :text) "")
               (etaf-manual-reader--inline-text (plist-get block :children))))))

(defun etaf-manual-reader--search-entries (session chapter-id)
  "Return SESSION's searchable text of CHAPTER-ID, in document order.
Each entry is `(:chapter ID :node NIL-or-INDEX :definition NAME :text
STRING)'; NODE is nil before the first section and NAME is the definition
entry the block belongs to, if any."
  (let* ((language (etaf-manual-reader--read session :language))
         (key (list 'search language chapter-id))
         (cache (plist-get session :documents)))
    (or (gethash key cache)
        (puthash key
                 (let ((node -1) (definition nil) entries)
                   (dolist (block (plist-get (etaf-manual-reader-document session chapter-id)
                                             :children))
                     (let* ((heading (eq (plist-get block :type) 'heading))
                            (level (and heading (plist-get block :level)))
                            (text (etaf-manual-reader--block-text block)))
                       (cond
                        ((memq level '(2 3)) (cl-incf node) (setq definition nil))
                        ((= (or level 0) 4)
                         (setq definition
                               (and (string-match
                                     "\\`[A-Za-z]+: \\([^ \t\n]+\\)"
                                     (string-trim text))
                                    (intern (match-string 1 (string-trim text)))))))
                       (unless (string-empty-p text)
                         (push (list :chapter chapter-id
                                     :node (and (>= node 0) node)
                                     :definition definition
                                     :text text)
                               entries))))
                   (nreverse entries))
                 cache))))

(defun etaf-manual-reader--match-order (session match)
  "Return (CHAPTER-INDEX . NODE) ordering key of MATCH in SESSION."
  (cons (or (cl-position (plist-get match :chapter)
                         (etaf-manual-reader--chapters session)
                         :key (lambda (chapter) (plist-get chapter :id)))
            0)
        (or (plist-get match :node) -1)))

(defun etaf-manual-reader--record-order (session)
  "Return SESSION's reading position as an ordering key."
  (cons (or (etaf-manual-reader--chapter-index session) 0)
        (or (etaf-manual-reader--read session :node) -1)))

(defun etaf-manual-reader--order-before-p (a b)
  "Return non-nil when ordering key A precedes B."
  (or (< (car a) (car b))
      (and (= (car a) (car b)) (< (cdr a) (cdr b)))))

(defun etaf-manual-reader--search-matches (session query)
  "Return SESSION's sections containing QUERY, in reading order.
A section contributes one match per definition entry and one for its own
text, so repeated occurrences do not repeat the jump."
  (let ((case-fold-search t)
        (pattern (regexp-quote query))
        matches)
    (dolist (chapter (etaf-manual-reader--chapters session))
      (let ((seen (make-hash-table :test #'equal)))
        (dolist (entry (etaf-manual-reader--search-entries session (plist-get chapter :id)))
          (when (string-match-p pattern (plist-get entry :text))
            (let ((key (list (plist-get entry :node) (plist-get entry :definition))))
              (unless (gethash key seen)
                (puthash key t seen)
                (push (list :chapter (plist-get entry :chapter)
                            :node (plist-get entry :node)
                            :definition (plist-get entry :definition))
                      matches)))))))
    (nreverse matches)))

(defun etaf-manual-reader--goto-match (session match)
  "Move SESSION to MATCH and reveal its definition entry when it has one."
  (etaf-manual-reader-goto session (plist-get match :chapter) (plist-get match :node))
  (when-let* ((name (plist-get match :definition)))
    (etaf-manual-reader-reveal-definition session name)))

(defun etaf-manual-reader--search-state (session)
  "Return SESSION's search state, or nil."
  (etaf-manual-reader--read session :search))

(defun etaf-manual-reader-search (session query)
  "Search SESSION's book for QUERY and move to the first matching section.
Matching ignores case and starts after the reading position, wrapping to
the first result when the search reaches the end.  Store the result list
for `etaf-manual-reader-search-next' and `-search-previous'.  Return the
number of matching sections, or 0 when nothing matches; an empty QUERY
signals `user-error'."
  (unless (and (stringp query) (not (string-empty-p query)))
    (user-error "搜索词不能为空"))
  (let* ((matches (etaf-manual-reader--search-matches session query))
         (count (length matches)))
    (if (zerop count)
        (progn
          (etaf-manual-reader--write session :search nil)
          0)
      (let* ((current (etaf-manual-reader--record-order session))
             (index (or (cl-position-if (lambda (match)
                                          (etaf-manual-reader--order-before-p
                                           current
                                           (etaf-manual-reader--match-order session match)))
                                        matches)
                        0)))
        (etaf-manual-reader--write
         session :search (list :query query :matches matches :index index))
        (etaf-manual-reader--goto-match session (nth index matches))
        count))))

(defun etaf-manual-reader-search-next (session)
  "Move SESSION to its next search result and return that match.
Signal `user-error' without searching or at the last result."
  (let* ((search (etaf-manual-reader--search-state session))
         (matches (plist-get search :matches)))
    (unless matches
      (user-error "尚未搜索"))
    (let ((index (1+ (plist-get search :index))))
      (when (>= index (length matches))
        (user-error "已是最后一条结果"))
      (etaf-manual-reader--write session :search
                                 (plist-put (copy-sequence search) :index index))
      (etaf-manual-reader--goto-match session (nth index matches))
      (nth index matches))))

(defun etaf-manual-reader-search-previous (session)
  "Move SESSION to its previous search result and return that match.
Signal `user-error' without searching or at the first result."
  (let* ((search (etaf-manual-reader--search-state session))
         (matches (plist-get search :matches)))
    (unless matches
      (user-error "尚未搜索"))
    (let ((index (1- (plist-get search :index))))
      (when (< index 0)
        (user-error "已是第一条结果"))
      (etaf-manual-reader--write session :search
                                 (plist-put (copy-sequence search) :index index))
      (etaf-manual-reader--goto-match session (nth index matches))
      (nth index matches))))

(defun etaf-manual-reader-search-match (session)
  "Return SESSION's current search result as a plist, or nil.
The result has `:chapter', `:node' and `:definition' (the symbol of the
definition entry the match belongs to, or nil)."
  (when-let* ((search (etaf-manual-reader--search-state session)))
    (nth (plist-get search :index) (plist-get search :matches))))

;;;; Column widths

(defun etaf-manual-reader--sidebar-columns (session)
  "Return SESSION's navigation column width in character cells."
  (or (etaf-manual-reader--read session :sidebar-width)
      etaf-manual-reader--sidebar-default-columns))

(defun etaf-manual-reader--outline-columns (session)
  "Return SESSION's on-this-page column width in character cells.
A caller-set width wins; otherwise the column hugs the current chapter's
widest section title between the default bounds."
  (or (etaf-manual-reader--read session :outline-width)
      (let ((needs (mapcar (lambda (node)
                             (+ (string-width (or (plist-get node :title) ""))
                                (if (eql (plist-get node :level) 3) 6 4)))
                           (etaf-manual-reader--nodes session))))
        (max etaf-manual-reader--outline-min-columns
             (min etaf-manual-reader--outline-default-max-columns
                  (apply #'max 0 needs))))))

(defun etaf-manual-reader-set-sidebar-width (session columns)
  "Set SESSION's navigation column width to COLUMNS character cells.
COLUMNS is clamped to the supported range; nil restores the default.
Return SESSION."
  (etaf-manual-reader--write
   session :sidebar-width
   (when columns
     (max etaf-manual-reader--sidebar-min-columns
          (min etaf-manual-reader--sidebar-max-columns (round columns)))))
  session)

(defun etaf-manual-reader-set-outline-width (session columns)
  "Set SESSION's on-this-page column width to COLUMNS character cells.
COLUMNS is clamped to the supported range; nil restores the width that
hugs the chapter's section titles.  Return SESSION."
  (etaf-manual-reader--write
   session :outline-width
   (when columns
     (max etaf-manual-reader--outline-min-columns
          (min etaf-manual-reader--outline-max-columns (round columns)))))
  session)

;;;; Reading position memory

(defun etaf-manual-reader--position-file ()
  "Return the file remembering the reading position."
  (or etaf-manual-reader-position-file
      (locate-user-emacs-file "etaf-manual-position.eld")))

(defun etaf-manual-reader--position ()
  "Return the remembered reading position as a plist, or nil."
  (let ((file (etaf-manual-reader--position-file)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (let ((value (read (current-buffer))))
              (and (listp value) (plist-get value :chapter) value)))
        (error nil)))))

(defun etaf-manual-reader-remember (session)
  "Remember SESSION's reading position for `etaf-manual-reader-restore'.
Write language, palette, chapter and section to
`etaf-manual-reader-position-file' and return non-nil when the write
succeeded; write errors are ignored.  A displayed session also saves by
itself a moment after each navigation."
  (let ((file (etaf-manual-reader--position-file)))
    (condition-case nil
        (progn
          (write-region
           (let ((print-length nil) (print-level nil))
             (prin1-to-string
              (list :language (etaf-manual-reader--read session :language)
                    :theme (etaf-manual-reader--read session :theme)
                    :chapter (etaf-manual-reader--read session :chapter)
                    :node (etaf-manual-reader--read session :node)
                    :sidebar-width (etaf-manual-reader--read session :sidebar-width)
                    :outline-width (etaf-manual-reader--read session :outline-width))))
           nil file nil 'silent)
          t)
      (error nil))))

(defun etaf-manual-reader-restore (session)
  "Apply the remembered reading position to SESSION and return it.
Reads `etaf-manual-reader-position-file'; a missing, unreadable, malformed
or stale entry leaves the corresponding setting untouched.  Return
non-nil when a chapter was applied."
  (when-let* ((saved (etaf-manual-reader--position)))
    (let ((language (plist-get saved :language)))
      (when (member language '("en" "zh-CN"))
        (etaf-manual-book language)
        (etaf-manual-reader--write session :language language)))
    (let ((theme (plist-get saved :theme)))
      (when (memq theme '(light auto dark))
        (etaf-manual-reader--write session :theme theme)))
    (when (numberp (plist-get saved :sidebar-width))
      (etaf-manual-reader-set-sidebar-width session (plist-get saved :sidebar-width)))
    (when (numberp (plist-get saved :outline-width))
      (etaf-manual-reader-set-outline-width session (plist-get saved :outline-width)))
    (let* ((chapter (plist-get saved :chapter))
           (entry (and (symbolp chapter)
                       (cl-find chapter (plist-get (etaf-manual-reader--book session)
                                                   :chapters)
                                :key (lambda (item) (plist-get item :id))))))
      (when entry
        (let ((node (plist-get saved :node)))
          (etaf-manual-reader--jump
           session chapter
           (when (and (integerp node) (>= node 0)
                      (< node (length (plist-get entry :nodes))))
             node))))
      entry)))

(defun etaf-manual-reader--schedule-remember (session)
  "Remember SESSION's position a moment after the current navigation."
  (when (plist-get session :buffer)
    (when-let* ((timer (gethash session etaf-manual-reader--remember-timers)))
      (cancel-timer timer))
    (puthash session
             (run-with-idle-timer 0.5 nil #'etaf-manual-reader-remember session)
             etaf-manual-reader--remember-timers)))

;;;; Navigation

(defun etaf-manual-reader--record (session)
  "Return SESSION's current position as (CHAPTER . NODE)."
  (cons (etaf-manual-reader--read session :chapter)
        (etaf-manual-reader--read session :node)))

(defun etaf-manual-reader--jump (session chapter &optional node)
  "Move SESSION to CHAPTER and NODE without recording history."
  (etaf-batch
    (let ((same (eq chapter (etaf-manual-reader--read session :chapter))))
      (etaf-manual-reader--write session :chapter chapter)
      (etaf-manual-reader--write session :node node)
      (etaf-manual-reader--reveal session (or node 0) (not same))))
  session)

;;;; Progressive rendering
;;
;; A displayed reader renders a chapter's sections up to its extent: the
;; sections through the reading position and about one screen more.  Idle
;; time then extends the extent a screenful at a time until the chapter is
;; complete, so a jump into a long chapter shows its target at once and
;; keystrokes never wait for the rest.  A session without a buffer renders
;; every section, which keeps headless readers and tests complete.

(defconst etaf-manual-reader--extent-step 60
  "Section weight one extension adds: blocks, list items and table rows.")

(defvar etaf-manual-reader--growth (make-hash-table :test 'eq :weakness 'key)
  "SESSION to its pending idle extension timer.")

(defun etaf-manual-reader--block-weight (block)
  "Return BLOCK's rendering weight: its list items or table rows, else 1."
  (max 1 (pcase (plist-get block :type)
           ('list (length (plist-get block :items)))
           ('table (length (plist-get block :rows)))
           (_ 1))))

(defun etaf-manual-reader--section-weights (session)
  "Return the weights of SESSION's current chapter sections, in order.
Sections begin at level-2 and level-3 headings, like the chapter's nodes."
  (let* ((key (list 'weights (etaf-manual-reader--read session :language)
                    (etaf-manual-reader--read session :chapter)))
         (cache (plist-get session :documents)))
    (or (gethash key cache)
        (puthash key
                 (let (weights)
                   (dolist (block (plist-get (etaf-manual-reader-document session)
                                             :children))
                     (if (and (eq (plist-get block :type) 'heading)
                              (memq (plist-get block :level) '(2 3)))
                         (push 1 weights)
                       (when weights
                         (cl-incf (car weights)
                                  (etaf-manual-reader--block-weight block)))))
                   (vconcat (nreverse weights)))
                 cache))))

(defun etaf-manual-reader--extent-after (session start)
  "Return the section count that covers START and one step of weight more.
Nil means every section of SESSION's chapter."
  (let* ((weights (etaf-manual-reader--section-weights session))
         (count (length weights))
         (end (min count (1+ start)))
         (weight 0))
    (while (and (< end count) (< weight etaf-manual-reader--extent-step))
      (cl-incf weight (aref weights end))
      (cl-incf end))
    (and (< end count) end)))

(defun etaf-manual-reader--reveal (session section &optional reset)
  "Extend SESSION's rendered extent to cover SECTION and a screen more.
RESET starts over for a new chapter.  Only a displayed session renders
progressively; it then completes the rest when Emacs is idle."
  (when (plist-get session :buffer)
    (let ((current (etaf-manual-reader--read session :extent)))
      (when (or reset current)
        (let ((wanted (etaf-manual-reader--extent-after session section)))
          (etaf-manual-reader--write
           session :extent
           (and wanted (if (and current (not reset)) (max current wanted) wanted)))
          (etaf-manual-reader--schedule-growth session))))))

(defun etaf-manual-reader--schedule-growth (session)
  "Extend SESSION's extent once Emacs is idle, while it is partial."
  (let ((timer (gethash session etaf-manual-reader--growth)))
    (when timer (cancel-timer timer)))
  (remhash session etaf-manual-reader--growth)
  (when (etaf-manual-reader--read session :extent)
    (puthash session
             (run-with-idle-timer 0 nil #'etaf-manual-reader--grow session)
             etaf-manual-reader--growth)))

(defun etaf-manual-reader--grow (session)
  "Render one more step of SESSION's chapter and schedule the next."
  (remhash session etaf-manual-reader--growth)
  (let ((buffer (plist-get session :buffer))
        (extent (etaf-manual-reader--read session :extent)))
    (when (and extent buffer (buffer-live-p buffer))
      (etaf-batch
        (etaf-manual-reader--write
         session :extent
         (etaf-manual-reader--extent-after session extent)))
      (etaf-manual-reader--schedule-growth session))))

(defun etaf-manual-reader-reveal-definition (session name)
  "Render SESSION's current chapter through the definition entry of NAME."
  (let ((pattern (concat "\\`[A-Za-z]+: " (regexp-quote (format "%s" name))
                         "\\(?:[ \t]\\|\\'\\)"))
        (section -1))
    (catch 'found
      (dolist (block (plist-get (etaf-manual-reader-document session) :children))
        (when (eq (plist-get block :type) 'heading)
          (pcase (plist-get block :level)
            ((or 2 3) (cl-incf section))
            (4 (when (string-match-p
                      pattern
                      (string-trim
                       (mapconcat (lambda (node) (or (plist-get node :text) ""))
                                  (plist-get block :children) "")))
                 (throw 'found nil)))))))
    (etaf-batch (etaf-manual-reader--reveal session (max section 0)))))

(defun etaf-manual-reader-goto (session chapter &optional node)
  "Move SESSION to CHAPTER and NODE, recording the previous position.
CHAPTER is a chapter identifier or its name as a string; an unknown chapter
signals `etaf-manual-error' and leaves SESSION where it was.  NODE is a
zero-based index into the chapter's nodes, or nil for the chapter top.
Return SESSION."
  (let* ((chapter (etaf-manual-reader--chapter-id
                   (etaf-manual-reader--chapters session) chapter))
         (target (cons chapter node)))
    (etaf-batch
      (unless (equal (etaf-manual-reader--record session) target)
        (etaf-manual-reader--write
         session :back
         (cons (etaf-manual-reader--record session)
               (seq-take (etaf-manual-reader--read session :back)
                         (1- etaf-manual-reader--history-limit))))
        (etaf-manual-reader--write session :forward nil))
      (etaf-manual-reader--jump session chapter node))))

(defun etaf-manual-reader--chapter-index (session &optional id)
  "Return the reading-order index of chapter ID in SESSION's book."
  (cl-position (or id (etaf-manual-reader--read session :chapter))
               (etaf-manual-reader--chapters session)
               :key (lambda (chapter) (plist-get chapter :id))))

(defun etaf-manual-reader--chapter-at (session index)
  "Return the chapter identifier at reading-order INDEX, or nil.
INDEX outside the book returns nil, so the end-of-book checks never read a
neighbouring chapter through a negative index."
  (when (>= index 0)
    (plist-get (nth index (etaf-manual-reader--chapters session)) :id)))

(defun etaf-manual-reader--goto-anchor (session anchor)
  "Move SESSION to the section whose anchor is ANCHOR."
  (let ((index (cl-position anchor (etaf-manual-reader--nodes session)
                            :key (lambda (node) (plist-get node :anchor))
                            :test #'equal)))
    (if index
        (etaf-manual-reader-goto session
                                 (etaf-manual-reader--read session :chapter)
                                 index)
      (etaf-manual-reader-message session (format "找不到锚点 #%s" anchor)))))

(defun etaf-manual-reader--follow-symbol (session name)
  "Move SESSION to the definition entry of symbol NAME, or report it."
  (let ((definition (gethash name (etaf-manual-reader--definition-table session))))
    (if (not definition)
        (etaf-manual-reader-message session (format "手册里没有 %s 的定义" name))
      (etaf-manual-reader-goto
       session (plist-get definition :chapter)
       (etaf-manual-reader--node-for-line session (plist-get definition :line)
                                          (plist-get definition :chapter)))
      (etaf-manual-reader-scroll-to-definition session (plist-get definition :name))
      (etaf-manual-reader-message
       session (format "已跳转：%s 的定义" (plist-get definition :name))))))

(defun etaf-manual-reader-follow (session url)
  "Open URL from SESSION's document.
In-document anchors, links to another chapter and symbol links stay inside
the reader; anything else goes to the browser."
  (cond
   ((string-prefix-p "manual-symbol:" url)
    (etaf-manual-reader--follow-symbol session (substring url (length "manual-symbol:"))))
   ((string-prefix-p "#" url)
    (etaf-manual-reader--goto-anchor session (substring url 1)))
   ((string-match "\\`\\([^#]+\\)\\(?:#\\(.*\\)\\)?\\'" url)
    (let* ((file (match-string 1 url))
           (anchor (match-string 2 url))
           (id (intern (file-name-base file))))
      (cond
       ((etaf-manual-reader--chapter session id)
        (etaf-manual-reader-goto session id)
        (when (and anchor (not (string-empty-p anchor)))
          (etaf-manual-reader--goto-anchor session anchor)))
       ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" url)
        (browse-url url))
       (t (etaf-manual-reader-message session (format "找不到章节 %s" file))))))
   (t (browse-url url))))

(defun etaf-manual-reader-next (session)
  "Move SESSION to the next section, rolling into the next chapter."
  (let* ((chapter (etaf-manual-reader--read session :chapter))
         (nodes (etaf-manual-reader--nodes session))
         (node (etaf-manual-reader--read session :node)))
    (cond
     ((null node) (if nodes
                      (etaf-manual-reader-goto session chapter 0)
                    (etaf-manual-reader-next-chapter session)))
     ((< node (1- (length nodes)))
      (etaf-manual-reader-goto session chapter (1+ node)))
     (t (etaf-manual-reader-next-chapter session)))))

(defun etaf-manual-reader-previous (session)
  "Move SESSION to the previous section, rolling into the previous chapter."
  (let* ((chapter (etaf-manual-reader--read session :chapter))
         (node (etaf-manual-reader--read session :node)))
    (if (or (null node) (zerop node))
        (etaf-manual-reader-previous-chapter session)
      (etaf-manual-reader-goto session chapter (1- node)))))

(defun etaf-manual-reader-next-chapter (session)
  "Move SESSION to the first section of the next chapter."
  (let ((index (etaf-manual-reader--chapter-index session)))
    (if-let* ((id (etaf-manual-reader--chapter-at session (1+ index))))
        (etaf-manual-reader-goto session id
                                 (when (etaf-manual-reader--nodes session id) 0))
      (user-error "This is the last chapter"))))

(defun etaf-manual-reader-previous-chapter (session)
  "Move SESSION to the last section of the previous chapter."
  (let ((index (etaf-manual-reader--chapter-index session)))
    (if-let* ((id (etaf-manual-reader--chapter-at session (1- index))))
        (let ((nodes (etaf-manual-reader--nodes session id)))
          (etaf-manual-reader-goto session id (when nodes (1- (length nodes)))))
      (user-error "This is the first chapter"))))

(defun etaf-manual-reader-up (session)
  "Move SESSION one level up: level 3 to its section, a section to the top."
  (let* ((chapter (etaf-manual-reader--read session :chapter))
         (nodes (etaf-manual-reader--nodes session))
         (node (etaf-manual-reader--read session :node)))
    (cond
     ((null node) (user-error "Already at the chapter top"))
     ((= (plist-get (nth node nodes) :level) 2)
      (etaf-manual-reader-goto session chapter nil))
     (t (let ((parent (cl-loop for index from (1- node) downto 0
                               when (= (plist-get (nth index nodes) :level) 2)
                               return index)))
          (etaf-manual-reader-goto session chapter parent))))))

(defun etaf-manual-reader-back (session)
  "Return SESSION to the previous position in its history."
  (let ((back (etaf-manual-reader--read session :back)))
    (unless back
      (user-error "No earlier position"))
    (etaf-batch
      (etaf-manual-reader--write session :forward
                                 (cons (etaf-manual-reader--record session)
                                       (etaf-manual-reader--read session :forward)))
      (etaf-manual-reader--write session :back (cdr back))
      (etaf-manual-reader--jump session (car (car back)) (cdr (car back))))))

(defun etaf-manual-reader-forward (session)
  "Move SESSION to the next position in its history."
  (let ((forward (etaf-manual-reader--read session :forward)))
    (unless forward
      (user-error "No later position"))
    (etaf-batch
      (etaf-manual-reader--write session :back
                                 (cons (etaf-manual-reader--record session)
                                       (etaf-manual-reader--read session :back)))
      (etaf-manual-reader--write session :forward (cdr forward))
      (etaf-manual-reader--jump session (car (car forward)) (cdr (car forward))))))

(defun etaf-manual-reader-last-chapter-p (session)
  "Return non-nil when SESSION is at the last chapter."
  (= (etaf-manual-reader--chapter-index session)
     (1- (length (etaf-manual-reader--chapters session)))))

(defun etaf-manual-reader-first-chapter-p (session)
  "Return non-nil when SESSION is at the first chapter."
  (zerop (etaf-manual-reader--chapter-index session)))

;;;; Language, theme and messages

(defun etaf-manual-reader-set-language (session language)
  "Read SESSION in LANGUAGE, keeping the chapter and the nearest section."
  (etaf-manual-book language)
  (let ((node (etaf-manual-reader--read session :node)))
    (etaf-batch
      (etaf-manual-reader--write session :language language)
      (let ((nodes (etaf-manual-reader--nodes session)))
        (etaf-manual-reader--write
         session :node
         (when (and node nodes)
           (min node (1- (length nodes))))))
      (etaf-manual-reader--reveal
       session (or (etaf-manual-reader--read session :node) 0) t)))
  session)

(defun etaf-manual-reader-set-theme (session theme)
  "Show SESSION with palette THEME.
THEME is `light', `dark' or `auto', where `auto' follows the appearance the
host provides and the Emacs theme in a standalone reader."
  (etaf-manual-reader--write session :theme theme)
  session)

(defun etaf-manual-reader-toggle-theme (session)
  "Switch SESSION between the light and dark palettes and return the new one.
An `auto' reader pins the opposite of the appearance it resolves to; the
title bar of a panel framing the reader offers `auto' again after that."
  (let ((theme (if (eq (etaf-manual-reader--resolved
                        (etaf-manual-reader--read session :theme))
                       'dark)
                   'light
                 'dark)))
    (etaf-manual-reader-set-theme session theme)
    theme))

(defun etaf-manual-reader-message (session text)
  "Show TEXT in SESSION's status area."
  (etaf-manual-reader--write session :message text))

;;;; Outline and state

(defun etaf-manual-reader-toc (session)
  "Return SESSION's navigation outline as a list of part plists.
Each part has `:number', `:title' and `:chapters'; each chapter has `:id',
`:number', `:title', `:kind', `:current' and, for the current chapter,
`:nodes' with `:title', `:level', `:anchor' and `:current'."
  (let ((current (etaf-manual-reader--read session :chapter))
        (node (etaf-manual-reader--read session :node)))
    (cl-loop for part in (plist-get (etaf-manual-reader--book session) :parts)
             collect
             (list :number (plist-get part :number)
                   :title (plist-get part :title)
                   :chapters
                   (cl-loop for id in (plist-get part :chapters)
                            for chapter = (etaf-manual-reader--chapter session id)
                            for current-p = (eq id current)
                            collect
                            (list :id id
                                  :number (plist-get chapter :number)
                                  :title (plist-get chapter :title)
                                  :kind (plist-get chapter :kind)
                                  :current current-p
                                  :nodes
                                  (when current-p
                                    (cl-loop for entry in (plist-get chapter :nodes)
                                             for index from 0
                                             collect
                                             (list :title (plist-get entry :title)
                                                   :level (plist-get entry :level)
                                                   :anchor (plist-get entry :anchor)
                                                   :index index
                                                   :current (eql index node))))))))))

(defun etaf-manual-reader-state (session)
  "Return a detached snapshot of SESSION's reading state.
Keys are `:language', `:theme' (`light', `auto' or `dark'), `:chapter',
`:chapter-title', `:part',
`:node', `:node-title', `:nodes' (titles in order), `:position' (zero-based
chapter index), `:chapters' (count), `:can-back' and `:can-forward'."
  (let ((chapter (etaf-manual-reader--chapter session))
        (node (etaf-manual-reader--read session :node)))
    (list :language (etaf-manual-reader--read session :language)
          :theme (etaf-manual-reader--read session :theme)
          :chapter (etaf-manual-reader--read session :chapter)
          :chapter-title (plist-get chapter :title)
          :part (plist-get (etaf-manual-reader--part session) :title)
          :node node
          :node-title (plist-get (etaf-manual-reader--node-at session node) :title)
          :nodes (mapcar (lambda (entry) (plist-get entry :title))
                         (plist-get chapter :nodes))
          :position (etaf-manual-reader--chapter-index session)
          :chapters (length (etaf-manual-reader--chapters session))
          :can-back (and (etaf-manual-reader--read session :back) t)
          :can-forward (and (etaf-manual-reader--read session :forward) t)
          :sidebar-width (etaf-manual-reader--sidebar-columns session)
          :outline-width (etaf-manual-reader--outline-columns session))))

(provide 'etaf-manual-reader-model)
;;; etaf-manual-reader-model.el ends here
